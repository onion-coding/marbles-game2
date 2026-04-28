// Package metrics is a tiny hand-rolled counter / histogram registry +
// Prometheus-format exporter. We don't pull in a Prometheus client lib
// to keep dependency count small — this package is enough for the
// counters and histograms an MVP rgsd needs to expose to a scrape job.
//
// Surface:
//
//	c := metrics.NewCounter("rgsd_rounds_total", "rounds completed")
//	c.Inc()
//	h := metrics.NewHistogram("rgsd_round_duration_seconds", []float64{0.1, 1, 10})
//	h.Observe(elapsed.Seconds())
//	http.Handle("/metrics", metrics.Handler())
//
// Output looks like Prometheus text exposition format 0.0.4 — `# HELP`,
// `# TYPE`, then one line per metric. No labels in v1 (each metric gets
// its own name); labels are easy to add by extending Counter / Histogram
// with a label-tuple key when the need arises.
package metrics

import (
	"fmt"
	"io"
	"net/http"
	"sort"
	"sync"
	"sync/atomic"
)

// registry holds every metric registered in the process. Global state
// is the simplest API for an MVP — no point passing a registry through
// every call site when there's only ever one metrics endpoint.
var (
	registryMu sync.Mutex
	registry   = map[string]metric{}
)

type metric interface {
	name() string
	help() string
	mtype() string
	emit(w io.Writer)
}

// ─── Counter ─────────────────────────────────────────────────────────────

// Counter is a monotonically-increasing uint64. Safe for concurrent use.
type Counter struct {
	n        uint64
	nameStr  string
	helpStr  string
}

func NewCounter(name, help string) *Counter {
	c := &Counter{nameStr: name, helpStr: help}
	register(name, c)
	return c
}

func (c *Counter) Inc()                  { atomic.AddUint64(&c.n, 1) }
func (c *Counter) Add(delta uint64)      { atomic.AddUint64(&c.n, delta) }
func (c *Counter) Value() uint64         { return atomic.LoadUint64(&c.n) }
func (c *Counter) name() string          { return c.nameStr }
func (c *Counter) help() string          { return c.helpStr }
func (c *Counter) mtype() string         { return "counter" }
func (c *Counter) emit(w io.Writer) {
	fmt.Fprintf(w, "%s %d\n", c.nameStr, c.Value())
}

// ─── Histogram ───────────────────────────────────────────────────────────

// Histogram is a static-bucket histogram. Buckets are upper bounds; the
// trailing +Inf bucket is added implicitly so total observation counts
// land somewhere.
type Histogram struct {
	mu       sync.Mutex
	buckets  []float64
	counts   []uint64 // len = len(buckets) + 1 (last is +Inf)
	sum      float64
	count    uint64
	nameStr  string
	helpStr  string
}

func NewHistogram(name, help string, buckets []float64) *Histogram {
	// Defensive copy; sort ascending; reject duplicates.
	bs := append([]float64(nil), buckets...)
	sort.Float64s(bs)
	h := &Histogram{
		buckets: bs,
		counts:  make([]uint64, len(bs)+1),
		nameStr: name,
		helpStr: help,
	}
	register(name, h)
	return h
}

func (h *Histogram) Observe(v float64) {
	h.mu.Lock()
	defer h.mu.Unlock()
	h.sum += v
	h.count++
	for i, b := range h.buckets {
		if v <= b {
			h.counts[i]++
			return
		}
	}
	h.counts[len(h.counts)-1]++
}

func (h *Histogram) name() string  { return h.nameStr }
func (h *Histogram) help() string  { return h.helpStr }
func (h *Histogram) mtype() string { return "histogram" }
func (h *Histogram) emit(w io.Writer) {
	h.mu.Lock()
	defer h.mu.Unlock()
	cumulative := uint64(0)
	for i, b := range h.buckets {
		cumulative += h.counts[i]
		fmt.Fprintf(w, "%s_bucket{le=\"%g\"} %d\n", h.nameStr, b, cumulative)
	}
	cumulative += h.counts[len(h.counts)-1]
	fmt.Fprintf(w, "%s_bucket{le=\"+Inf\"} %d\n", h.nameStr, cumulative)
	fmt.Fprintf(w, "%s_sum %g\n", h.nameStr, h.sum)
	fmt.Fprintf(w, "%s_count %d\n", h.nameStr, h.count)
}

// ─── Registry / handler ─────────────────────────────────────────────────

func register(name string, m metric) {
	registryMu.Lock()
	defer registryMu.Unlock()
	if _, exists := registry[name]; exists {
		panic(fmt.Sprintf("metrics: duplicate registration for %q", name))
	}
	registry[name] = m
}

// Handler returns the http.Handler that serves the Prometheus-format
// exposition document. Mount at /metrics in the daemon.
func Handler() http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/plain; version=0.0.4")
		registryMu.Lock()
		// Sorted output so diffing two scrapes is sane.
		names := make([]string, 0, len(registry))
		for n := range registry {
			names = append(names, n)
		}
		registryMu.Unlock()
		sort.Strings(names)
		for _, n := range names {
			registryMu.Lock()
			m := registry[n]
			registryMu.Unlock()
			fmt.Fprintf(w, "# HELP %s %s\n", m.name(), m.help())
			fmt.Fprintf(w, "# TYPE %s %s\n", m.name(), m.mtype())
			m.emit(w)
		}
	})
}

// ResetForTest clears the registry. Test-only escape hatch since
// double-registration panics; production code should never call this.
func ResetForTest() {
	registryMu.Lock()
	defer registryMu.Unlock()
	registry = map[string]metric{}
}
