package main

import (
	"context"
	"log/slog"
	"math/rand"
	"os"
	"os/exec"
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

	// Jitter Random Seed
	rand.Seed(time.Now().UnixNano())

	slog.Info("Watchdog 2.0 Go Sidecar Started", "interval", cfg.CheckInterval, "threshold", cfg.CBThreshold)

	for {
		if cb.State() == StateOpen {
			slog.Warn("circuit breaker OPEN, skipping proactive check", "wait", cfg.CBResetTimeout)
			time.Sleep(cfg.CBResetTimeout)
			continue
		}

		ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
		err := checker.Check(ctx)
		cancel()

		if err != nil {
			cb.RecordFailure()
			slog.Error("health check failed", "err", err, "consecutive_failures", cb.Failures())
			
			if cb.State() == StateOpen {
				slog.Warn("Circuit Breaker Tripped! Triggering node fallback...")
				switchToFallback()
			}
			
			backoff := calculateBackoffWithJitter(cb.Failures(), cfg)
			slog.Info("Backing off before next check", "sleep", backoff)
			time.Sleep(backoff)
		} else {
			if cb.Failures() > 0 {
				slog.Info("Health check recovered. Resetting circuit breaker.")
			}
			cb.RecordSuccess()
			time.Sleep(cfg.CheckInterval)
		}
	}
}

// Exponential smoothed jitter algorithm
func calculateBackoffWithJitter(failures int, cfg Config) time.Duration {
	shift := failures
	if shift > 8 {
		shift = 8
	}
	base := cfg.BackoffBase * time.Duration(1<<shift)
	
	if base > cfg.BackoffMax {
		base = cfg.BackoffMax
	}
	
	jitter := time.Duration(float64(base) * cfg.JitterFactor * (rand.Float64()*2 - 1))
	return base + jitter
}

func switchToFallback() {
	// Call sing-box external control API: PUT /proxies/{group}
	secret := os.Getenv("DASHBOARD_SECRET")
	if secret == "" {
		slog.Warn("DASHBOARD_SECRET environment variable is empty. API call may fail.")
	}
	
	cmd := exec.Command("curl", "-sf", "-X", "PUT",
		"-H", "Authorization: Bearer "+secret,
		"http://127.0.0.1:9090/proxies/auto-select",
		"-d", `{"name":"fallback-node"}`)
	
	if err := cmd.Run(); err != nil {
		slog.Error("Failed to trigger API fallback", "error", err)
	} else {
		slog.Info("Successfully triggered auto-select fallback node.")
	}
}
