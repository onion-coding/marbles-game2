// Package middleware contains the cross-cutting HTTP wrappers shared by
// every public-facing daemon (rgsd today; replayd next). Each middleware
// is a `func(http.Handler) http.Handler` so they compose with the
// standard library and don't drag in a third-party router.
//
// What's here:
//   - RequestID:  attaches a stable id to every request via context +
//                 X-Request-ID header so logs and panics can be
//                 correlated across services.
//   - Logging:    structured slog access log (method, path, status,
//                 duration, request_id). Writes one line per request.
//   - HMAC:       header-signed request authenticator. Rejects requests
//                 missing / mismatching the signature. Skipped for
//                 health / metrics paths so probes don't need keys.
//   - Recovery:   converts panics in downstream handlers into 500s with
//                 the request_id surfaced for triage.
//
// Order matters: in cmd/rgsd we wrap as
//
//	Logging( Recovery( RequestID( HMAC( handler ) ) ) )
//
// so the access log line carries the request_id but auth still happens
// before the handler is invoked, and any panic still becomes a 500
// instead of crashing the process.
package middleware

import (
	"context"
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"runtime/debug"
	"strconv"
	"strings"
	"time"
)

// ─── Request ID ──────────────────────────────────────────────────────────

type ctxKey int

const (
	ctxKeyRequestID ctxKey = iota
)

const HeaderRequestID = "X-Request-ID"

// RequestID middleware. Honors an inbound X-Request-ID if present (so
// upstream LBs / API gateways can dictate the id); otherwise generates
// one. The id is stashed in request context and echoed in the response
// header.
func RequestID(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		id := r.Header.Get(HeaderRequestID)
		if id == "" {
			id = newRequestID()
		}
		ctx := context.WithValue(r.Context(), ctxKeyRequestID, id)
		w.Header().Set(HeaderRequestID, id)
		next.ServeHTTP(w, r.WithContext(ctx))
	})
}

// RequestIDFromContext returns the id stashed by RequestID, or "" if the
// request didn't go through the middleware (e.g. background work).
func RequestIDFromContext(ctx context.Context) string {
	v, _ := ctx.Value(ctxKeyRequestID).(string)
	return v
}

func newRequestID() string {
	var b [8]byte
	_, _ = rand.Read(b[:])
	return "req_" + hex.EncodeToString(b[:])
}

// ─── Access logging ──────────────────────────────────────────────────────

// statusRecorder wraps a ResponseWriter to capture the eventual status
// code and bytes-written so the access log can include them.
type statusRecorder struct {
	http.ResponseWriter
	status int
	bytes  int
}

func (s *statusRecorder) WriteHeader(code int) {
	s.status = code
	s.ResponseWriter.WriteHeader(code)
}

func (s *statusRecorder) Write(b []byte) (int, error) {
	if s.status == 0 {
		s.status = http.StatusOK
	}
	n, err := s.ResponseWriter.Write(b)
	s.bytes += n
	return n, err
}

// Logging emits one access log line per request via the supplied
// slog.Logger. If logger is nil, slog.Default() is used.
func Logging(logger *slog.Logger) func(http.Handler) http.Handler {
	if logger == nil {
		logger = slog.Default()
	}
	return func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			start := time.Now()
			rec := &statusRecorder{ResponseWriter: w}
			next.ServeHTTP(rec, r)
			logger.LogAttrs(r.Context(), slog.LevelInfo, "http",
				slog.String("method", r.Method),
				slog.String("path", r.URL.Path),
				slog.Int("status", rec.status),
				slog.Int("bytes", rec.bytes),
				slog.Duration("duration", time.Since(start)),
				slog.String("request_id", RequestIDFromContext(r.Context())),
			)
		})
	}
}

// ─── Recovery ────────────────────────────────────────────────────────────

// Recovery converts panics into 500s with the request_id in the response
// body so triage can correlate the log line.
func Recovery(logger *slog.Logger) func(http.Handler) http.Handler {
	if logger == nil {
		logger = slog.Default()
	}
	return func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			defer func() {
				if rec := recover(); rec != nil {
					id := RequestIDFromContext(r.Context())
					logger.LogAttrs(r.Context(), slog.LevelError, "panic",
						slog.Any("panic", rec),
						slog.String("request_id", id),
						slog.String("stack", string(debug.Stack())),
					)
					w.Header().Set("Content-Type", "application/json")
					w.WriteHeader(http.StatusInternalServerError)
					_, _ = io.WriteString(w, fmt.Sprintf(`{"error":"internal error","request_id":%q}`, id))
				}
			}()
			next.ServeHTTP(w, r)
		})
	}
}

// ─── HMAC auth ───────────────────────────────────────────────────────────

const (
	HeaderSignature = "X-Signature"
	HeaderTimestamp = "X-Timestamp"
)

// HMACConfig configures the HMAC middleware.
type HMACConfig struct {
	// Secret is the shared HMAC key. Length should be >= 32 random bytes.
	// The middleware computes HMAC-SHA256(method | "\n" | path | "\n" |
	// timestamp | "\n" | body).
	Secret []byte
	// MaxClockSkew is the largest delta between the request's X-Timestamp
	// header and server time we accept; bigger drifts get rejected as
	// replay attacks. 5 minutes is a reasonable default.
	MaxClockSkew time.Duration
	// SkipPaths is a list of HTTP path prefixes that bypass auth (e.g.
	// "/v1/health", "/metrics"). Probes don't carry signing keys.
	SkipPaths []string
}

// HMAC middleware. Rejects requests with 401 unless they carry a valid
// X-Signature for the given Secret. Time-skewed requests get 401 too.
func HMAC(cfg HMACConfig) func(http.Handler) http.Handler {
	if cfg.MaxClockSkew == 0 {
		cfg.MaxClockSkew = 5 * time.Minute
	}
	return func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			if shouldSkipAuth(r.URL.Path, cfg.SkipPaths) {
				next.ServeHTTP(w, r)
				return
			}
			if err := verifyHMAC(r, cfg); err != nil {
				w.Header().Set("Content-Type", "application/json")
				w.WriteHeader(http.StatusUnauthorized)
				_, _ = io.WriteString(w, fmt.Sprintf(`{"error":%q}`, err.Error()))
				return
			}
			next.ServeHTTP(w, r)
		})
	}
}

func shouldSkipAuth(path string, skips []string) bool {
	for _, p := range skips {
		if strings.HasPrefix(path, p) {
			return true
		}
	}
	return false
}

func verifyHMAC(r *http.Request, cfg HMACConfig) error {
	sig := r.Header.Get(HeaderSignature)
	if sig == "" {
		return errors.New("missing X-Signature")
	}
	ts := r.Header.Get(HeaderTimestamp)
	if ts == "" {
		return errors.New("missing X-Timestamp")
	}
	tsInt, err := strconv.ParseInt(ts, 10, 64)
	if err != nil {
		return fmt.Errorf("invalid X-Timestamp: %w", err)
	}
	skew := time.Since(time.Unix(tsInt, 0))
	if skew < 0 {
		skew = -skew
	}
	if skew > cfg.MaxClockSkew {
		return fmt.Errorf("X-Timestamp skew %v exceeds max %v", skew, cfg.MaxClockSkew)
	}

	body, err := io.ReadAll(r.Body)
	if err != nil {
		return fmt.Errorf("read body: %w", err)
	}
	// Restore the body so downstream handlers can still read it.
	r.Body = io.NopCloser(strings.NewReader(string(body)))

	expected := computeSignature(cfg.Secret, r.Method, r.URL.Path, ts, body)
	if !hmac.Equal([]byte(expected), []byte(sig)) {
		return errors.New("signature mismatch")
	}
	return nil
}

// SignRequest is the client-side helper: returns the signature an
// outbound request should set in X-Signature given the same key,
// method, path, timestamp, and body. Exposed so the demo MockOperator
// can authenticate against an HMAC-protected rgsd.
func SignRequest(secret []byte, method, path, timestamp string, body []byte) string {
	return computeSignature(secret, method, path, timestamp, body)
}

func computeSignature(secret []byte, method, path, timestamp string, body []byte) string {
	mac := hmac.New(sha256.New, secret)
	_, _ = io.WriteString(mac, method)
	_, _ = io.WriteString(mac, "\n")
	_, _ = io.WriteString(mac, path)
	_, _ = io.WriteString(mac, "\n")
	_, _ = io.WriteString(mac, timestamp)
	_, _ = io.WriteString(mac, "\n")
	_, _ = mac.Write(body)
	return hex.EncodeToString(mac.Sum(nil))
}
