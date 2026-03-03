package main

import (
	"sync"
	"time"
)

type State int

const (
	StateClosed State = iota
	StateHalfOpen
	StateOpen
)

type CircuitBreaker struct {
	mu           sync.Mutex
	failures     int
	threshold    int
	lastOpenedAt time.Time
	resetTimeout time.Duration
	state        State
}

func NewCircuitBreaker(threshold int, resetTimeout time.Duration) *CircuitBreaker {
	return &CircuitBreaker{
		threshold:    threshold,
		resetTimeout: resetTimeout,
		state:        StateClosed,
	}
}

func (cb *CircuitBreaker) RecordFailure() {
	cb.mu.Lock()
	defer cb.mu.Unlock()

	cb.failures++
	if cb.failures >= cb.threshold && cb.state != StateOpen {
		cb.state = StateOpen
		cb.lastOpenedAt = time.Now()
	}
}

func (cb *CircuitBreaker) RecordSuccess() {
	cb.mu.Lock()
	defer cb.mu.Unlock()

	cb.failures = 0
	cb.state = StateClosed
}

func (cb *CircuitBreaker) State() State {
	cb.mu.Lock()
	defer cb.mu.Unlock()

	if cb.state == StateOpen && time.Since(cb.lastOpenedAt) > cb.resetTimeout {
		// Transition to Half-Open after the reset timeout expires
		cb.state = StateHalfOpen
	}
	return cb.state
}

func (cb *CircuitBreaker) Failures() int {
	cb.mu.Lock()
	defer cb.mu.Unlock()
	return cb.failures
}
