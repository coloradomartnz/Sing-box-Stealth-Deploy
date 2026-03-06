package main

import (
	"context"
	"fmt"
	"io"
	"log/slog"
	"math/rand/v2"
	"net/http"
	"net/url"
	"os"
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
	cfg    Config
	client *http.Client
}

func NewChecker(cfg Config) *Checker {
	return &Checker{
		cfg: cfg,
		client: &http.Client{
			Timeout: 7 * time.Second,
			// Do not follow redirects; a redirect response still proves reachability.
			CheckRedirect: func(req *http.Request, via []*http.Request) error {
				return http.ErrUseLastResponse
			},
		},
	}
}

// Check verifies proxy reachability via net/http HEAD requests.
// Returns nil on the first reachable target.
func (c *Checker) Check(ctx context.Context) error {
	for _, target := range c.cfg.ProxyTargets {
		req, err := http.NewRequestWithContext(ctx, http.MethodHead, target, nil)
		if err != nil {
			continue
		}
		resp, err := c.client.Do(req)
		if err == nil {
			resp.Body.Close()
			return nil // Success on first reachable target
		}
		if ctx.Err() != nil {
			return ctx.Err()
		}
	}
	return fmt.Errorf("all proxy targets unreachable")
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
		switch cb.State() {
		case StateOpen:
			slog.Warn("circuit breaker OPEN, skipping proactive check", "wait", cfg.CBResetTimeout)
			select {
			case <-ctx.Done():
				slog.Info("Received shutdown signal, exiting gracefully")
				return
			case <-time.After(cfg.CBResetTimeout):
			}
			continue
		case StateHalfOpen:
			slog.Info("circuit breaker HALF-OPEN, running probe check")
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
	// 从 Systemd Credentials 目录读取 secret（LoadCredential 注入）；
	// 回退到 DASHBOARD_SECRET 环境变量（兼容旧部署）。
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

	req, err := http.NewRequestWithContext(ctx, http.MethodPut, apiURL,
		strings.NewReader(body))
	if err != nil {
		slog.Error("Failed to build API request", "error", err)
		return
	}
	req.Header.Set("Authorization", "Bearer "+secret)
	req.Header.Set("Content-Type", "application/json")

	client := &http.Client{Timeout: 5 * time.Second}
	resp, err := client.Do(req)
	if err != nil {
		slog.Error("Failed to trigger API fallback", "error", err, "group", proxyGroup, "node", fallbackNode)
		return
	}
	defer resp.Body.Close()
	io.Copy(io.Discard, resp.Body)

	if resp.StatusCode >= 200 && resp.StatusCode < 300 {
		slog.Info("Successfully triggered fallback node selection.", "group", proxyGroup, "node", fallbackNode)
	} else {
		slog.Error("API fallback returned non-2xx", "status", resp.StatusCode, "group", proxyGroup)
	}
}
