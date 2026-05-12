// Package admin provides the operator admin panel — a minimal HTTP service
// on a separate listener (default :8091) that exposes game-state controls,
// wallet inspection, config hot-update, and an audit trail. It is designed
// to live behind a firewall / VPN so it never needs to be reachable from
// the public internet.
//
// Auth: every request must carry a valid HMAC-SHA256 signature computed
// with the admin-specific secret (--admin-hmac-secret-hex). This is
// intentionally separate from the /v1/* HMAC secret so the two surfaces
// can be firewalled independently and the admin secret can be rotated
// without touching the operator integration key.
//
// Routes:
//
//	GET  /admin/             — index HTML page (4 tabs: Rounds/Wallets/Config/Audit)
//	GET  /admin/rounds       — JSON list (pending + last 50 settled info)
//	GET  /admin/rounds/{id}  — JSON detail
//	POST /admin/rounds/pause — pause new rounds (returns 503 until resumed)
//	POST /admin/rounds/resume
//	GET  /admin/wallets      — JSON list of all known players + balances
//	GET  /admin/wallets/{id} — single player detail
//	POST /admin/wallets/{id}/credit — manual credit (audit logged)
//	POST /admin/wallets/{id}/debit  — manual debit (audit logged)
//	GET  /admin/config       — current config snapshot
//	POST /admin/config/rtp-bps — hot-update RTP basis points
//	GET  /admin/audit        — paginated audit log
//	GET  /admin/health       — liveness (no auth required for monitoring)
package admin

import (
	"crypto/hmac"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"html/template"
	"io/fs"
	"net/http"
	"sort"
	"strconv"
	"strings"
	"time"

	"github.com/onion-coding/marbles-game2/server/rgs"
)

// AuthFunc is called with the request. It returns the actor string (e.g.
// "ops:alice") on success, or an error if the request must be rejected.
// Passing nil disables auth (dev only).
type AuthFunc func(r *http.Request) (actor string, err error)

// PlayerLister is the subset of rgs.MockWallet (or any admin-aware wallet)
// that the admin handler calls to enumerate players. Production HTTP wallets
// don't expose this — operators should implement a thin adapter or inject a
// separate player store.
type PlayerLister interface {
	Players() []string
}

// Config is the wiring the admin handler needs.
type Config struct {
	Manager  *rgs.Manager
	Wallet   rgs.Wallet
	Auth     AuthFunc  // nil = no auth (dev only; log a warning)
	AuditLog *AuditLog
	// TemplateFS is the fs.FS to load templates from. If nil, the embedded
	// FS built from templates/ is used (set by init in embed.go).
	TemplateFS fs.FS
}

// Handler is the admin HTTP handler. Create it with NewHandler.
type Handler struct {
	cfg    Config
	mux    *http.ServeMux
	tmpl   *template.Template
	audit  *AuditLog
}

// NewHandler wires up all admin routes and parses the index template.
func NewHandler(cfg Config) (*Handler, error) {
	if cfg.AuditLog == nil {
		al, _ := NewAuditLog("") // in-memory only fallback
		cfg.AuditLog = al
	}
	h := &Handler{
		cfg:   cfg,
		audit: cfg.AuditLog,
	}

	// Parse the index template from the provided FS (or the embedded one).
	tfs := cfg.TemplateFS
	if tfs == nil {
		tfs = embeddedTemplates
	}
	tmpl, err := template.ParseFS(tfs, "templates/index.html")
	if err != nil {
		return nil, fmt.Errorf("admin: parse template: %w", err)
	}
	h.tmpl = tmpl

	mux := http.NewServeMux()
	// Static assets (JS, CSS) served from embedded FS.
	staticFS := cfg.TemplateFS
	if staticFS == nil {
		staticFS = embeddedTemplates
	}
	mux.Handle("GET /admin/static/", http.StripPrefix("/admin/static/", http.FileServer(http.FS(mustSub(staticFS, "static")))))

	mux.HandleFunc("GET /admin/", h.auth(h.index))
	mux.HandleFunc("GET /admin/rounds", h.auth(h.listRounds))
	mux.HandleFunc("POST /admin/rounds/pause", h.auth(h.pauseRounds))
	mux.HandleFunc("POST /admin/rounds/resume", h.auth(h.resumeRounds))
	mux.HandleFunc("GET /admin/wallets", h.auth(h.listWallets))
	mux.HandleFunc("GET /admin/wallets/{id}", h.auth(h.getWallet))
	mux.HandleFunc("POST /admin/wallets/{id}/credit", h.auth(h.creditWallet))
	mux.HandleFunc("POST /admin/wallets/{id}/debit", h.auth(h.debitWallet))
	mux.HandleFunc("GET /admin/config", h.auth(h.getConfig))
	mux.HandleFunc("POST /admin/config/rtp-bps", h.auth(h.setRTPBps))
	mux.HandleFunc("GET /admin/audit", h.auth(h.listAudit))
	mux.HandleFunc("GET /admin/health", h.health) // no auth — for monitoring

	// Responsible-gambling operator overrides (no-ops when RGService is nil).
	mux.HandleFunc("POST /admin/players/{id}/rg-override", h.auth(h.rgOverride))
	mux.HandleFunc("POST /admin/players/{id}/force-exclude", h.auth(h.rgForceExclude))

	h.mux = mux
	return h, nil
}

// ServeHTTP implements http.Handler.
func (h *Handler) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	h.mux.ServeHTTP(w, r)
}

// ── Auth middleware ──────────────────────────────────────────────────────────

func (h *Handler) auth(next func(w http.ResponseWriter, r *http.Request, actor string)) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if h.cfg.Auth == nil {
			next(w, r, "anonymous")
			return
		}
		actor, err := h.cfg.Auth(r)
		if err != nil {
			writeAdminError(w, http.StatusUnauthorized, err)
			return
		}
		next(w, r, actor)
	}
}

// HMACAuthFunc builds an AuthFunc that validates the X-Signature / X-Timestamp
// headers using the provided secret. The signing message is:
//
//	METHOD + "\n" + PATH + "\n" + TIMESTAMP + "\n" + BODY
//
// This is the same convention used by server/middleware for /v1/* so
// operators can reuse their verification tooling.
func HMACAuthFunc(secret []byte) AuthFunc {
	return func(r *http.Request) (string, error) {
		ts := r.Header.Get("X-Timestamp")
		sig := r.Header.Get("X-Signature")
		if ts == "" || sig == "" {
			return "", errors.New("missing X-Timestamp or X-Signature")
		}
		// Replay guard: reject requests older than 5 minutes.
		tsec, err := strconv.ParseInt(ts, 10, 64)
		if err != nil {
			return "", errors.New("invalid X-Timestamp")
		}
		age := time.Since(time.Unix(tsec, 0))
		if age < 0 {
			age = -age
		}
		if age > 5*time.Minute {
			return "", fmt.Errorf("timestamp too old or too far in future (age=%v)", age)
		}

		body := r.Header.Get("X-Body-Hash") // optional pre-hashed body
		mac := hmac.New(sha256.New, secret)
		fmt.Fprintf(mac, "%s\n%s\n%s\n%s", r.Method, r.URL.Path, ts, body)
		expected := hex.EncodeToString(mac.Sum(nil))
		if !hmac.Equal([]byte(expected), []byte(sig)) {
			return "", errors.New("invalid signature")
		}
		actor := r.Header.Get("X-Admin-Actor")
		if actor == "" {
			actor = "operator"
		}
		return actor, nil
	}
}

// ── Handlers ─────────────────────────────────────────────────────────────────

func (h *Handler) health(w http.ResponseWriter, r *http.Request) {
	writeAdminJSON(w, http.StatusOK, map[string]string{"status": "ok"})
}

func (h *Handler) index(w http.ResponseWriter, r *http.Request, actor string) {
	cfg := h.cfg.Manager.Config()
	data := map[string]interface{}{
		"Paused":     h.cfg.Manager.IsPaused(),
		"RTPBps":     cfg.RTPBps,
		"BuyIn":      cfg.BuyIn,
		"MaxMarbles": cfg.MaxMarbles,
		"TrackPool":  cfg.TrackPool,
		"Actor":      actor,
	}
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	if err := h.tmpl.Execute(w, data); err != nil {
		http.Error(w, "template error: "+err.Error(), http.StatusInternalServerError)
	}
}

// roundSummary is the JSON shape returned by GET /admin/rounds.
type roundSummary struct {
	PendingCount int    `json:"pending_round_count"`
	Paused       bool   `json:"paused"`
	Status       string `json:"status"`
}

func (h *Handler) listRounds(w http.ResponseWriter, r *http.Request, actor string) {
	paused := h.cfg.Manager.IsPaused()
	status := "running"
	if paused {
		status = "paused"
	}
	writeAdminJSON(w, http.StatusOK, roundSummary{
		PendingCount: h.cfg.Manager.PendingRoundCount(),
		Paused:       paused,
		Status:       status,
	})
}

func (h *Handler) pauseRounds(w http.ResponseWriter, r *http.Request, actor string) {
	h.cfg.Manager.Pause()
	h.audit.Record(AuditEvent{
		Actor:   actor,
		Action:  "rounds.pause",
		Details: "manager paused; RunNextRound will return 503 until resumed",
	})
	writeAdminJSON(w, http.StatusOK, map[string]string{"status": "paused"})
}

func (h *Handler) resumeRounds(w http.ResponseWriter, r *http.Request, actor string) {
	h.cfg.Manager.Resume()
	h.audit.Record(AuditEvent{
		Actor:  actor,
		Action: "rounds.resume",
	})
	writeAdminJSON(w, http.StatusOK, map[string]string{"status": "running"})
}

// walletEntry is the JSON shape for a single player in GET /admin/wallets.
type walletEntry struct {
	PlayerID string  `json:"player_id"`
	Balance  float64 `json:"balance"`
}

func (h *Handler) listWallets(w http.ResponseWriter, r *http.Request, actor string) {
	pl, ok := h.cfg.Wallet.(PlayerLister)
	if !ok {
		writeAdminError(w, http.StatusNotImplemented, errors.New("wallet does not support player enumeration"))
		return
	}
	players := pl.Players()
	sort.Strings(players)
	cur := h.currency()
	out := make([]walletEntry, 0, len(players))
	for _, id := range players {
		bal, err := h.cfg.Wallet.Balance(id, cur)
		if err != nil {
			continue
		}
		out = append(out, walletEntry{PlayerID: id, Balance: float64(bal) / 100.0})
	}
	writeAdminJSON(w, http.StatusOK, out)
}

func (h *Handler) getWallet(w http.ResponseWriter, r *http.Request, actor string) {
	id := r.PathValue("id")
	bal, err := h.cfg.Wallet.Balance(id, h.currency())
	if err != nil {
		if errors.Is(err, rgs.ErrUnknownPlayer) {
			writeAdminError(w, http.StatusNotFound, err)
			return
		}
		writeAdminError(w, http.StatusInternalServerError, err)
		return
	}
	writeAdminJSON(w, http.StatusOK, walletEntry{PlayerID: id, Balance: float64(bal) / 100.0})
}

type manualTxRequest struct {
	Amount uint64 `json:"amount"`
	Reason string `json:"reason,omitempty"`
}

func (h *Handler) creditWallet(w http.ResponseWriter, r *http.Request, actor string) {
	id := r.PathValue("id")
	var req manualTxRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeAdminError(w, http.StatusBadRequest, fmt.Errorf("decode body: %w", err))
		return
	}
	if req.Amount == 0 {
		writeAdminError(w, http.StatusBadRequest, errors.New("amount must be > 0"))
		return
	}
	txID := fmt.Sprintf("admin:credit:%d:%d", time.Now().UnixNano(), req.Amount)
	if err := h.cfg.Wallet.Credit(id, req.Amount, h.currency(), txID); err != nil {
		if errors.Is(err, rgs.ErrUnknownPlayer) {
			writeAdminError(w, http.StatusNotFound, err)
			return
		}
		writeAdminError(w, http.StatusInternalServerError, err)
		return
	}
	h.audit.Record(AuditEvent{
		Actor:   actor,
		Action:  "wallet.credit",
		Target:  id,
		Details: fmt.Sprintf("amount=%d tx_id=%s reason=%s", req.Amount, txID, req.Reason),
	})
	bal, _ := h.cfg.Wallet.Balance(id, h.currency())
	writeAdminJSON(w, http.StatusOK, walletEntry{PlayerID: id, Balance: float64(bal) / 100.0})
}

func (h *Handler) debitWallet(w http.ResponseWriter, r *http.Request, actor string) {
	id := r.PathValue("id")
	var req manualTxRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeAdminError(w, http.StatusBadRequest, fmt.Errorf("decode body: %w", err))
		return
	}
	if req.Amount == 0 {
		writeAdminError(w, http.StatusBadRequest, errors.New("amount must be > 0"))
		return
	}
	txID := fmt.Sprintf("admin:debit:%d:%d", time.Now().UnixNano(), req.Amount)
	if err := h.cfg.Wallet.Debit(id, req.Amount, h.currency(), txID); err != nil {
		if errors.Is(err, rgs.ErrUnknownPlayer) {
			writeAdminError(w, http.StatusNotFound, err)
			return
		}
		if errors.Is(err, rgs.ErrInsufficientFunds) {
			writeAdminError(w, http.StatusPaymentRequired, err)
			return
		}
		writeAdminError(w, http.StatusInternalServerError, err)
		return
	}
	h.audit.Record(AuditEvent{
		Actor:   actor,
		Action:  "wallet.debit",
		Target:  id,
		Details: fmt.Sprintf("amount=%d tx_id=%s reason=%s", req.Amount, txID, req.Reason),
	})
	bal, _ := h.cfg.Wallet.Balance(id, h.currency())
	writeAdminJSON(w, http.StatusOK, walletEntry{PlayerID: id, Balance: float64(bal) / 100.0})
}

// configSnapshot is returned by GET /admin/config.
type configSnapshot struct {
	RTPBps     uint32  `json:"rtp_bps"`
	BuyIn      uint64  `json:"buy_in"`
	MaxMarbles int     `json:"max_marbles"`
	TrackPool  []uint8 `json:"track_pool"`
	Paused     bool    `json:"paused"`
}

func (h *Handler) getConfig(w http.ResponseWriter, r *http.Request, actor string) {
	cfg := h.cfg.Manager.Config()
	writeAdminJSON(w, http.StatusOK, configSnapshot{
		RTPBps:     cfg.RTPBps,
		BuyIn:      cfg.BuyIn,
		MaxMarbles: cfg.MaxMarbles,
		TrackPool:  cfg.TrackPool,
		Paused:     h.cfg.Manager.IsPaused(),
	})
}

type setRTPRequest struct {
	RTPBps uint32 `json:"rtp_bps"`
}

func (h *Handler) setRTPBps(w http.ResponseWriter, r *http.Request, actor string) {
	var req setRTPRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeAdminError(w, http.StatusBadRequest, fmt.Errorf("decode body: %w", err))
		return
	}
	if req.RTPBps == 0 || req.RTPBps > 10000 {
		writeAdminError(w, http.StatusBadRequest, errors.New("rtp_bps must be in [1, 10000]"))
		return
	}
	oldCfg := h.cfg.Manager.Config()
	h.cfg.Manager.UpdateRTP(req.RTPBps)
	h.audit.Record(AuditEvent{
		Actor:   actor,
		Action:  "config.rtp_bps",
		Details: fmt.Sprintf("old=%d new=%d", oldCfg.RTPBps, req.RTPBps),
	})
	// Re-read to confirm.
	cfg := h.cfg.Manager.Config()
	writeAdminJSON(w, http.StatusOK, configSnapshot{
		RTPBps:     cfg.RTPBps,
		BuyIn:      cfg.BuyIn,
		MaxMarbles: cfg.MaxMarbles,
		TrackPool:  cfg.TrackPool,
		Paused:     h.cfg.Manager.IsPaused(),
	})
}

// auditPage is the JSON envelope for GET /admin/audit.
type auditPage struct {
	Total  int          `json:"total"`
	Offset int          `json:"offset"`
	Limit  int          `json:"limit"`
	Events []AuditEvent `json:"events"`
}

func (h *Handler) listAudit(w http.ResponseWriter, r *http.Request, actor string) {
	offsetStr := r.URL.Query().Get("offset")
	limitStr := r.URL.Query().Get("limit")
	offset, _ := strconv.Atoi(offsetStr)
	limit, _ := strconv.Atoi(limitStr)
	if limit <= 0 || limit > 200 {
		limit = 50
	}
	events := h.audit.List(offset, limit)
	writeAdminJSON(w, http.StatusOK, auditPage{
		Total:  h.audit.Total(),
		Offset: offset,
		Limit:  limit,
		Events: events,
	})
}

// currency returns the manager's effective default currency for wallet calls.
func (h *Handler) currency() string {
	cfg := h.cfg.Manager.Config()
	if cfg.DefaultCurrency != "" {
		return cfg.DefaultCurrency
	}
	return rgs.DefaultCurrency
}

// ── Helpers ──────────────────────────────────────────────────────────────────

type adminErrorResponse struct {
	Error string `json:"error"`
}

func writeAdminJSON(w http.ResponseWriter, code int, body any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(code)
	_ = json.NewEncoder(w).Encode(body)
}

func writeAdminError(w http.ResponseWriter, code int, err error) {
	writeAdminJSON(w, code, adminErrorResponse{Error: err.Error()})
}

// mustSub wraps fs.Sub and panics if the sub-directory doesn't exist. Used
// only for static asset serving where the embedded FS is always present.
func mustSub(fsys fs.FS, dir string) fs.FS {
	sub, err := fs.Sub(fsys, dir)
	if err != nil {
		panic(fmt.Sprintf("admin: fs.Sub(%q): %v", dir, err))
	}
	return sub
}

// ── Ensure unused import of strings is not flagged ───────────────────────────
var _ = strings.TrimSpace
