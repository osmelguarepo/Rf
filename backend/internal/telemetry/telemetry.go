// Package telemetry is a small in-process metrics registry that writes the Prometheus text format (version 0.0.4).
// It has counters and histograms with labels and gauges read from callbacks at scrape time. Nothing is stored: a restart
// starts the counters again, which Prometheus handles as a counter reset.
package telemetry

import (
	"fmt"
	"io"
	"math"
	"sort"
	"strings"
	"sync"
)

// Registry holds every metric.
type Registry struct {
	mu       sync.Mutex
	counters map[string]*family
	hists    map[string]*histFamily
	gauges   []gauge
}

type family struct {
	help   string
	values map[string]float64 // label string -> value
}

type histFamily struct {
	help    string
	buckets []float64
	series  map[string]*histSeries
}

type histSeries struct {
	counts []uint64 // per bucket, not cumulative
	sum    float64
	n      uint64
}

type gauge struct {
	name, help string
	fn         func() float64
}

// New makes an empty registry.
func New() *Registry {
	return &Registry{counters: map[string]*family{}, hists: map[string]*histFamily{}}
}

// Inc adds 1 to a counter. labels are alternating names and values.
func (r *Registry) Inc(name, help string, labels ...string) { r.Add(name, help, 1, labels...) }

// Add adds v (not negative) to a counter.
func (r *Registry) Add(name, help string, v float64, labels ...string) {
	if r == nil || v < 0 {
		return
	}
	key := labelString(labels)
	r.mu.Lock()
	defer r.mu.Unlock()
	f := r.counters[name]
	if f == nil {
		f = &family{help: help, values: map[string]float64{}}
		r.counters[name] = f
	}
	f.values[key] += v
}

// Counter reads a counter (for tests and the admin tool).
func (r *Registry) Counter(name string, labels ...string) float64 {
	r.mu.Lock()
	defer r.mu.Unlock()
	if f := r.counters[name]; f != nil {
		return f.values[labelString(labels)]
	}
	return 0
}

// Observe records a value in a histogram with the given upper bounds (ascending; +Inf is implicit).
func (r *Registry) Observe(name, help string, buckets []float64, v float64, labels ...string) {
	if r == nil {
		return
	}
	key := labelString(labels)
	r.mu.Lock()
	defer r.mu.Unlock()
	h := r.hists[name]
	if h == nil {
		h = &histFamily{help: help, buckets: buckets, series: map[string]*histSeries{}}
		r.hists[name] = h
	}
	s := h.series[key]
	if s == nil {
		s = &histSeries{counts: make([]uint64, len(h.buckets)+1)}
		h.series[key] = s
	}
	i := sort.SearchFloat64s(h.buckets, v) // first bucket with bound >= v
	s.counts[i]++
	s.sum += v
	s.n++
}

// HistogramCount is the number of observations of a series (for tests).
func (r *Registry) HistogramCount(name string, labels ...string) uint64 {
	r.mu.Lock()
	defer r.mu.Unlock()
	if h := r.hists[name]; h != nil {
		if s := h.series[labelString(labels)]; s != nil {
			return s.n
		}
	}
	return 0
}

// Gauge registers a value computed when the metrics are scraped.
func (r *Registry) Gauge(name, help string, fn func() float64) {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.gauges = append(r.gauges, gauge{name, help, fn})
}

func labelString(labels []string) string {
	if len(labels) == 0 {
		return ""
	}
	var b strings.Builder
	for i := 0; i+1 < len(labels); i += 2 {
		if i > 0 {
			b.WriteByte(',')
		}
		fmt.Fprintf(&b, `%s="%s"`, labels[i], escape(labels[i+1]))
	}
	return b.String()
}

func escape(s string) string {
	s = strings.ReplaceAll(s, `\`, `\\`)
	s = strings.ReplaceAll(s, "\n", `\n`)
	return strings.ReplaceAll(s, `"`, `\"`)
}

func braces(l string) string {
	if l == "" {
		return ""
	}
	return "{" + l + "}"
}

func num(v float64) string {
	if math.IsInf(v, 1) {
		return "+Inf"
	}
	return fmt.Sprintf("%g", v)
}

// WritePrometheus writes every metric in the Prometheus text format, sorted by name so the output is stable.
func (r *Registry) WritePrometheus(w io.Writer) {
	r.mu.Lock()
	gauges := append([]gauge(nil), r.gauges...)
	r.mu.Unlock()
	// Gauge callbacks run without the lock: they may call back into other components.
	type gval struct {
		gauge
		v float64
	}
	gv := make([]gval, len(gauges))
	for i, g := range gauges {
		gv[i] = gval{g, g.fn()}
	}
	r.mu.Lock()
	defer r.mu.Unlock()
	names := make([]string, 0, len(r.counters))
	for n := range r.counters {
		names = append(names, n)
	}
	sort.Strings(names)
	for _, n := range names {
		f := r.counters[n]
		fmt.Fprintf(w, "# HELP %s %s\n# TYPE %s counter\n", n, f.help, n)
		keys := sortedKeys(f.values)
		for _, k := range keys {
			fmt.Fprintf(w, "%s%s %s\n", n, braces(k), num(f.values[k]))
		}
	}
	names = names[:0]
	for n := range r.hists {
		names = append(names, n)
	}
	sort.Strings(names)
	for _, n := range names {
		h := r.hists[n]
		fmt.Fprintf(w, "# HELP %s %s\n# TYPE %s histogram\n", n, h.help, n)
		keys := make([]string, 0, len(h.series))
		for k := range h.series {
			keys = append(keys, k)
		}
		sort.Strings(keys)
		for _, k := range keys {
			s := h.series[k]
			var cum uint64
			for i, b := range h.buckets {
				cum += s.counts[i]
				fmt.Fprintf(w, "%s_bucket%s %d\n", n, braces(join(k, `le="`+num(b)+`"`)), cum)
			}
			cum += s.counts[len(h.buckets)]
			fmt.Fprintf(w, "%s_bucket%s %d\n", n, braces(join(k, `le="+Inf"`)), cum)
			fmt.Fprintf(w, "%s_sum%s %s\n%s_count%s %d\n", n, braces(k), num(s.sum), n, braces(k), s.n)
		}
	}
	sort.Slice(gv, func(i, j int) bool { return gv[i].name < gv[j].name })
	for _, g := range gv {
		fmt.Fprintf(w, "# HELP %s %s\n# TYPE %s gauge\n%s %s\n", g.name, g.help, g.name, g.name, num(g.v))
	}
}

func join(a, b string) string {
	if a == "" {
		return b
	}
	return a + "," + b
}

func sortedKeys(m map[string]float64) []string {
	keys := make([]string, 0, len(m))
	for k := range m {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	return keys
}

// Common bucket sets.
var (
	WaitBuckets    = []float64{1, 2, 5, 10, 15, 20, 30, 45, 60, 120, 300}
	LatencyBuckets = []float64{0.001, 0.005, 0.01, 0.05, 0.1, 0.5, 1}
)
