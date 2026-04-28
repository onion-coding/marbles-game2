package middleware

import (
	"bytes"
	"context"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"strconv"
	"testing"
	"time"
)

func TestRequestID_GeneratesIfMissing(t *testing.T) {
	h := RequestID(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		id := RequestIDFromContext(r.Context())
		if id == "" {
			t.Fatalf("expected request id in context, got empty")
		}
		_, _ = io.WriteString(w, id)
	}))
	req := httptest.NewRequest("GET", "/x", nil)
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, req)
	if rec.Header().Get(HeaderRequestID) == "" {
		t.Fatalf("response header missing X-Request-ID")
	}
}

func TestRequestID_PreservesInbound(t *testing.T) {
	const want = "req_abcd"
	var got string
	h := RequestID(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		got = RequestIDFromContext(r.Context())
	}))
	req := httptest.NewRequest("GET", "/x", nil)
	req.Header.Set(HeaderRequestID, want)
	h.ServeHTTP(httptest.NewRecorder(), req)
	if got != want {
		t.Fatalf("inbound id not preserved: got %q want %q", got, want)
	}
}

func TestLogging_EmitsOneLinePerRequest(t *testing.T) {
	var buf bytes.Buffer
	logger := slog.New(slog.NewTextHandler(&buf, &slog.HandlerOptions{Level: slog.LevelDebug}))
	h := Logging(logger)(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(201)
		_, _ = io.WriteString(w, "hi")
	}))
	req := httptest.NewRequest("POST", "/foo", nil)
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, req)
	logged := buf.String()
	for _, want := range []string{"method=POST", "path=/foo", "status=201"} {
		if !contains(logged, want) {
			t.Fatalf("log line missing %q: %s", want, logged)
		}
	}
}

func TestRecovery_ConvertsPanicTo500(t *testing.T) {
	var buf bytes.Buffer
	logger := slog.New(slog.NewTextHandler(&buf, nil))
	h := RequestID(Recovery(logger)(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		panic("boom")
	})))
	req := httptest.NewRequest("GET", "/x", nil)
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, req)
	if rec.Code != 500 {
		t.Fatalf("status %d, want 500", rec.Code)
	}
	if !contains(rec.Body.String(), "request_id") {
		t.Fatalf("body missing request_id: %s", rec.Body.String())
	}
	if !contains(buf.String(), "panic") {
		t.Fatalf("log missing panic line: %s", buf.String())
	}
}

func TestHMAC_AcceptsSignedRequest(t *testing.T) {
	secret := []byte("supersecretkey")
	body := []byte(`{"hello":"world"}`)
	ts := strconv.FormatInt(time.Now().Unix(), 10)
	sig := SignRequest(secret, "POST", "/v1/x", ts, body)

	served := false
	h := HMAC(HMACConfig{Secret: secret})(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		served = true
		// Read body to verify the middleware restored it.
		got, _ := io.ReadAll(r.Body)
		if string(got) != string(body) {
			t.Fatalf("body not restored: got %q want %q", got, body)
		}
	}))
	req := httptest.NewRequest("POST", "/v1/x", bytes.NewReader(body))
	req.Header.Set(HeaderSignature, sig)
	req.Header.Set(HeaderTimestamp, ts)
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, req)
	if !served {
		t.Fatalf("handler not reached; status=%d body=%s", rec.Code, rec.Body.String())
	}
}

func TestHMAC_RejectsMissingSignature(t *testing.T) {
	h := HMAC(HMACConfig{Secret: []byte("k")})(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		t.Fatalf("handler should not run")
	}))
	req := httptest.NewRequest("POST", "/v1/x", nil)
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, req)
	if rec.Code != 401 {
		t.Fatalf("status %d, want 401", rec.Code)
	}
}

func TestHMAC_RejectsClockSkew(t *testing.T) {
	secret := []byte("k")
	ts := strconv.FormatInt(time.Now().Add(-1*time.Hour).Unix(), 10)
	sig := SignRequest(secret, "POST", "/v1/x", ts, nil)
	h := HMAC(HMACConfig{Secret: secret, MaxClockSkew: time.Minute})(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		t.Fatalf("handler should not run")
	}))
	req := httptest.NewRequest("POST", "/v1/x", nil)
	req.Header.Set(HeaderSignature, sig)
	req.Header.Set(HeaderTimestamp, ts)
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, req)
	if rec.Code != 401 {
		t.Fatalf("status %d, want 401", rec.Code)
	}
}

func TestHMAC_SkipPathsBypass(t *testing.T) {
	served := false
	h := HMAC(HMACConfig{Secret: []byte("k"), SkipPaths: []string{"/v1/health"}})(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		served = true
	}))
	req := httptest.NewRequest("GET", "/v1/health", nil)
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, req)
	if !served {
		t.Fatalf("health bypass didn't reach handler; status=%d", rec.Code)
	}
}

// Convenience for substring checks; avoids dragging in strings.Contains-
// style imports inline at every assertion.
func contains(haystack, needle string) bool {
	for i := 0; i+len(needle) <= len(haystack); i++ {
		if haystack[i:i+len(needle)] == needle {
			return true
		}
	}
	return false
}

// Compile-time check: the middleware can be threaded through.
var _ = func() http.Handler {
	mux := http.NewServeMux()
	return RequestID(Logging(slog.Default())(Recovery(slog.Default())(HMAC(HMACConfig{Secret: []byte("x")})(mux))))
}

// Avoid unused import warnings.
var (
	_ = context.Background
	_ = fmt.Sprintf
)
