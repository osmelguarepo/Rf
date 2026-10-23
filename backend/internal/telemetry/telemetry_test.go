package telemetry

import (
	"strings"
	"testing"
)

func TestPrometheusText(t *testing.T) {
	r := New()
	r.Inc("fr_a_total", "A things.", "kind", "x")
	r.Inc("fr_a_total", "A things.", "kind", "x")
	r.Add("fr_a_total", "A things.", 3, "kind", `we"ird`+"\n")
	r.Add("fr_a_total", "A things.", -1, "kind", "x") // ignored
	r.Inc("fr_plain_total", "Plain.")
	r.Observe("fr_wait_seconds", "Waits.", []float64{1, 5, 10}, 0.5)
	r.Observe("fr_wait_seconds", "Waits.", []float64{1, 5, 10}, 5)
	r.Observe("fr_wait_seconds", "Waits.", []float64{1, 5, 10}, 99)
	r.Gauge("fr_size", "Size.", func() float64 { return 7 })

	if r.Counter("fr_a_total", "kind", "x") != 2 || r.HistogramCount("fr_wait_seconds") != 3 {
		t.Fatal("reads")
	}
	var b strings.Builder
	r.WritePrometheus(&b)
	out := b.String()
	for _, want := range []string{
		"# TYPE fr_a_total counter", `fr_a_total{kind="x"} 2`, `fr_a_total{kind="we\"ird\n"} 3`, "fr_plain_total 1",
		"# TYPE fr_wait_seconds histogram", `fr_wait_seconds_bucket{le="1"} 1`, `fr_wait_seconds_bucket{le="5"} 2`,
		`fr_wait_seconds_bucket{le="10"} 2`, `fr_wait_seconds_bucket{le="+Inf"} 3`, "fr_wait_seconds_sum 104.5", "fr_wait_seconds_count 3",
		"# TYPE fr_size gauge", "fr_size 7",
	} {
		if !strings.Contains(out, want) {
			t.Errorf("missing %q in:\n%s", want, out)
		}
	}
	// Stable output.
	var b2 strings.Builder
	r.WritePrometheus(&b2)
	if b2.String() != out {
		t.Error("output must be stable between scrapes")
	}
	var nilReg *Registry
	nilReg.Inc("x", "y") // must not panic
}
