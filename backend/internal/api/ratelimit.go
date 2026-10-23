package api

import (
	"sync"
	"time"

	"golang.org/x/time/rate"
)

// keyedLimiter is a token bucket per key (an IP, an account) kept in memory. Idle keys are dropped so the map cannot
// grow without bound. Nothing here is persisted: IP addresses live only in this process (SPEC_ONLINE 16.3).
type keyedLimiter struct {
	mu      sync.Mutex
	limit   rate.Limit
	burst   int
	idleFor time.Duration
	entries map[string]*limiterEntry
	calls   int
	now     func() time.Time
}

type limiterEntry struct {
	l    *rate.Limiter
	seen time.Time
}

// newKeyedLimiter allows `burst` requests at once and `perInterval` per `interval` on average, per key.
func newKeyedLimiter(perInterval int, interval time.Duration, burst int, now func() time.Time) *keyedLimiter {
	if burst < 1 {
		burst = 1
	}
	return &keyedLimiter{
		limit:   rate.Every(interval / time.Duration(perInterval)),
		burst:   burst,
		idleFor: 10 * time.Minute,
		entries: map[string]*limiterEntry{},
		now:     now,
	}
}

// Allow takes one token for the key. It returns false, and how long to wait, when the bucket is empty.
func (k *keyedLimiter) Allow(key string) (bool, time.Duration) {
	k.mu.Lock()
	defer k.mu.Unlock()
	now := k.now()
	k.calls++
	if k.calls%256 == 0 {
		for key, e := range k.entries {
			if now.Sub(e.seen) > k.idleFor {
				delete(k.entries, key)
			}
		}
	}
	e, ok := k.entries[key]
	if !ok {
		e = &limiterEntry{l: rate.NewLimiter(k.limit, k.burst)}
		k.entries[key] = e
	}
	e.seen = now
	r := e.l.ReserveN(now, 1)
	if !r.OK() {
		return false, time.Minute
	}
	if d := r.DelayFrom(now); d > 0 {
		r.CancelAt(now)
		return false, d
	}
	return true, 0
}

// Size is the number of keys in memory (for tests).
func (k *keyedLimiter) Size() int {
	k.mu.Lock()
	defer k.mu.Unlock()
	return len(k.entries)
}
