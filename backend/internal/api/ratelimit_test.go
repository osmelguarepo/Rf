package api

import (
	"testing"
	"time"
)

func TestKeyedLimiterRefillsAndIsPerKey(t *testing.T) {
	now := time.Date(2026, 1, 1, 0, 0, 0, 0, time.UTC)
	l := newKeyedLimiter(60, time.Minute, 3, func() time.Time { return now }) // 1 per second, burst 3
	for i := 0; i < 3; i++ {
		if ok, _ := l.Allow("a"); !ok {
			t.Fatalf("burst %d refused", i)
		}
	}
	ok, wait := l.Allow("a")
	if ok || wait <= 0 || wait > 2*time.Second {
		t.Fatalf("4th: %v %v", ok, wait)
	}
	if ok, _ := l.Allow("b"); !ok {
		t.Fatal("another key has its own bucket")
	}
	now = now.Add(1500 * time.Millisecond)
	if ok, _ := l.Allow("a"); !ok {
		t.Fatal("one token after 1.5 s")
	}
	if ok, _ := l.Allow("a"); ok {
		t.Fatal("only one token was refilled")
	}
}

func TestKeyedLimiterForgetsIdleKeys(t *testing.T) {
	now := time.Date(2026, 1, 1, 0, 0, 0, 0, time.UTC)
	l := newKeyedLimiter(10, time.Minute, 5, func() time.Time { return now })
	for i := 0; i < 100; i++ {
		l.Allow(string(rune('a'+i%26)) + string(rune('a'+i/26)))
	}
	if l.Size() != 100 {
		t.Fatalf("size %d", l.Size())
	}
	now = now.Add(time.Hour)
	for i := 0; i < 300; i++ {
		l.Allow("active")
	}
	if l.Size() > 2 {
		t.Fatalf("idle keys must be dropped, size %d", l.Size())
	}
}
