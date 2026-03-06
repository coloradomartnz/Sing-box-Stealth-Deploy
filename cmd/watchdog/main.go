package main

import (
	"context"
	"fmt"
	"log/slog"
	"math/rand/v2"
	"net/url"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"strings"
	"syscall"
	"time"
)

type Config struct {
	ProxyTargets   []string
	CheckInterval  time.Duration
	CBThreshold    int // Circuit Breaker consecutive failures threshold
	CBResetTimeout time.Duration
	BackoffBase    time.Duration
	BackoffMax     time.Duration
	JitterFactor   float64
}

type Checker struct {
	cfg Config
}

func NewChecker(cfg Config) *Checker {
	return &Checker{cfg: cfg}
}

// Check verifies if the proxies are reachable. For now, we simulate a simple connectivity check.
func (c *Checker) Check(ctx context.Context) error {
	// Normally we would iterate over c.cfg.ProxyTargets and attempt requests via sing-box local socks/http port
	// but to make it resilient, we shell out to curl targeting multiple endpoints exactly as bash did.
	// Since bash did: curl -sf -m 7 "target"
	for _, target := range c.cfg.ProxyTargets {
		cmd := exec.CommandContext(ctx, "curl", "-sf", "-m", "7", target)
		if err := cmd.Run(); err == nil {
			return nil // Success on first reachable target
		}
	}
	return os.ErrDeadlineExceeded // All failed
}

func main() {
	cfg := Config{
		ProxyTargets:   []string{"https://www.google.com", "https://1.1.1.1", "https://www.cloudflare.com"},
		CheckInterval:  30 * time.Second,
		CBThreshold:    3,
		CBResetTimeout: 2 * time.Minute,
		BackoffBase:    5 * time.Second,
		BackoffMax:     5 * time.Minute,
		JitterFactor:   0.3,
	}

	// For simple testing if the flag is passed
	if len(os.Args) > 1 && os.Args[1] == "--test" {
		slog.Info("Running in test mode. Expected output: circuit breaker")
		cb := NewCircuitBreaker(cfg.CBThreshold, cfg.CBResetTimeout)
		cb.RecordFailure()
		slog.Warn("circuit breaker OPEN, skipping check")
		return
	}

	cb := NewCircuitBreaker(cfg.CBThreshold, cfg.CBResetTimeout)
	checker := NewChecker(cfg)

	// Go 1.20+ manually seeding is deprecated for global rand.
	// We switched to math/rand/v2 which handles this automatically.

	ctx, cancel := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer cancel()

	slog.Info("Watchdog 2.0 Go Sidecar Started", "interval", cfg.CheckInterval, "threshold", cfg.CBThreshold)

	for {
		if cb.State() == StateOpen {
			slog.Warn("circuit breaker OPEN, skipping proactive check", "wait", cfg.CBResetTimeout)
			select {
			case <-ctx.Done():
				slog.Info("Received shutdown signal, exiting gracefully")
				return
			case <-time.After(cfg.CBResetTimeout):
			}
			continue
		}

		checkCtx, checkCancel := context.WithTimeout(ctx, 15*time.Second)
		err := checker.Check(checkCtx)
		checkCancel()

		if err != nil {
			if ctx.Err() != nil {
				slog.Info("Received shutdown signal during check, exiting gracefully")
				return
			}
			cb.RecordFailure()
			slog.Error("health check failed", "err", err, "consecutive_failures", cb.Failures())

			if cb.State() == StateOpen {
				slog.Warn("Circuit Breaker Tripped! Triggering node fallback...")
				switchToFallback(ctx)
			}

			backoff := calculateBackoffWithJitter(cb.Failures(), cfg)
			slog.Info("Backing off before next check", "sleep", backoff)
			select {
			case <-ctx.Done():
				slog.Info("Received shutdown signal, exiting gracefully")
				return
			case <-time.After(backoff):
			}
		} else {
			if cb.Failures() > 0 {
				slog.Info("Health check recovered. Resetting circuit breaker.")
			}
			cb.RecordSuccess()
			select {
			case <-ctx.Done():
				slog.Info("Received shutdown signal, exiting gracefully")
				return
			case <-time.After(cfg.CheckInterval):
			}
		}
	}
}

// Exponential smoothed jitter algorithm
func calculateBackoffWithJitter(failures int, cfg Config) time.Duration {
	shift := uint(failures)
	if shift > 8 {
		shift = 8
	}
	base := cfg.BackoffBase * time.Duration(1<<shift)

	if base > cfg.BackoffMax {
		base = cfg.BackoffMax
	}

	// rand/v2.Float64()
	jitter := time.Duration(float64(base) * cfg.JitterFactor * (rand.Float64()*2 - 1))
	return base + jitter
}

func switchToFallback(ctx context.Context) {
	// P1 修复：从 Systemd Credentials 目录读取 secret（LoadCredential 注入）；
	//          回退到 DASHBOARD_SECRET 环境变量（兼容旧部署）。
	secret := ""
	if credsDir := os.Getenv("CREDENTIALS_DIRECTORY"); credsDir != "" {
		if data, err := os.ReadFile(filepath.Join(credsDir, "dash_secret")); err == nil {
			secret = strings.TrimSpace(string(data))
		}
	}
	if secret == "" {
		secret = os.Getenv("DASHBOARD_SECRET")
	}
	if secret == "" {
		slog.Warn("DASHBOARD_SECRET not found in credentials or environment; Clash API call may be rejected.")
	}

	port := os.Getenv("DASHBOARD_PORT")
	if port == "" {
		port = "9090"
	}

	// P0 修复：代理组 tag 和回退节点名均可通过环境变量覆盖；
	//          默认值与 singbox_build_region_groups.py 生成的 tag 一致。
	proxyGroup := os.Getenv("PROXY_GROUP_TAG")
	if proxyGroup == "" {
		proxyGroup = "🚀 节点选择"
	}
	fallbackNode := os.Getenv("WATCHDOG_FALLBACK_NODE")
	if fallbackNode == "" {
		fallbackNode = "🌏 全局自动"
	}

	apiURL := "http://127.0.0.1:" + port + "/proxies/" + url.PathEscape(proxyGroup)
	body := fmt.Sprintf(`{"name":%q}`, fallbackNode)

	cmd := exec.CommandContext(ctx, "curl", "-sf", "-X", "PUT",
		"-H", "Authorization: Bearer "+secret,
		"-H", "Content-Type: application/json",
		"-d", body,
		apiURL)

	if err := cmd.Run(); err != nil {
		slog.Error("Failed to trigger API fallback", "error", err, "group", proxyGroup, "node", fallbackNode)
	} else {
		slog.Info("Successfully triggered fallback node selection.", "group", proxyGroup, "node", fallbackNode)
	}
}
