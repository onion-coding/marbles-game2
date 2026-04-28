package metrics

import (
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func TestCounter_Counts(t *testing.T) {
	ResetForTest()
	c := NewCounter("test_total", "tests")
	c.Inc()
	c.Inc()
	c.Add(3)
	if got := c.Value(); got != 5 {
		t.Fatalf("counter value %d, want 5", got)
	}
}

func TestHistogram_BucketsAreCumulativeInOutput(t *testing.T) {
	ResetForTest()
	h := NewHistogram("test_seconds", "tests", []float64{0.1, 1.0, 10.0})
	for _, v := range []float64{0.05, 0.5, 5.0, 50.0} {
		h.Observe(v)
	}
	srv := httptest.NewServer(Handler())
	defer srv.Close()
	resp, err := srv.Client().Get(srv.URL)
	if err != nil {
		t.Fatalf("GET: %v", err)
	}
	defer resp.Body.Close()
	body := readAll(t, resp)
	for _, want := range []string{
		`test_seconds_bucket{le="0.1"} 1`,
		`test_seconds_bucket{le="1"} 2`,
		`test_seconds_bucket{le="10"} 3`,
		`test_seconds_bucket{le="+Inf"} 4`,
		`test_seconds_count 4`,
	} {
		if !strings.Contains(body, want) {
			t.Fatalf("scrape body missing %q\nfull body:\n%s", want, body)
		}
	}
}

func TestHandler_EmitsCounterLine(t *testing.T) {
	ResetForTest()
	c := NewCounter("rounds_total", "rounds completed")
	c.Add(7)
	srv := httptest.NewServer(Handler())
	defer srv.Close()
	resp, err := srv.Client().Get(srv.URL)
	if err != nil {
		t.Fatalf("GET: %v", err)
	}
	body := readAll(t, resp)
	for _, want := range []string{
		"# HELP rounds_total rounds completed",
		"# TYPE rounds_total counter",
		"rounds_total 7",
	} {
		if !strings.Contains(body, want) {
			t.Fatalf("scrape body missing %q\nfull body:\n%s", want, body)
		}
	}
}

func TestRegister_PanicsOnDuplicate(t *testing.T) {
	ResetForTest()
	NewCounter("dup", "")
	defer func() {
		if r := recover(); r == nil {
			t.Fatalf("expected panic on duplicate registration")
		}
	}()
	NewCounter("dup", "")
}

func readAll(t *testing.T, resp *http.Response) string {
	t.Helper()
	b, err := io.ReadAll(resp.Body)
	if err != nil {
		t.Fatalf("read body: %v", err)
	}
	return string(b)
}
