package casino

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"html/template"
	"io/fs"
	"log/slog"
	"net/http"
	"time"
)

// Config wires the casino handler. M29 (Phase 1) only needs an SFU; later
// phases will add a Manager (for round-flow integration), Wallet (for the
// betting overlay), and a metadata publisher (for HUD coords / minimap).
type Config struct {
	SFU *SFU
	// Logger is optional. Defaults to slog.Default().
	Logger *slog.Logger
	// TemplateFS overrides the embedded templates (tests).
	TemplateFS fs.FS
}

// Handler exposes the casino routes. Build with NewHandler and mount on
// rgsd's public listener at "/casino/" (no HMAC — same rationale as the
// previous casino handler, see package doc).
type Handler struct {
	cfg  Config
	mux  *http.ServeMux
	tmpl *template.Template
	log  *slog.Logger
}

// NewHandler wires up routes and parses the index template.
func NewHandler(cfg Config) (*Handler, error) {
	if cfg.SFU == nil {
		return nil, errors.New("casino: Config.SFU is required")
	}
	if cfg.Logger == nil {
		cfg.Logger = slog.Default()
	}
	tfs := cfg.TemplateFS
	if tfs == nil {
		tfs = embedded
	}
	tmpl, err := template.ParseFS(tfs, "templates/index.html")
	if err != nil {
		return nil, fmt.Errorf("casino: parse template: %w", err)
	}

	h := &Handler{cfg: cfg, tmpl: tmpl, log: cfg.Logger}

	mux := http.NewServeMux()
	staticSub, err := fs.Sub(tfs, "static")
	if err != nil {
		return nil, fmt.Errorf("casino: fs.Sub(static): %w", err)
	}
	mux.Handle("GET /casino/static/", http.StripPrefix("/casino/static/", http.FileServer(http.FS(staticSub))))
	mux.HandleFunc("GET /casino/", h.serveIndex)
	mux.HandleFunc("POST /casino/api/offer", h.serveOffer)
	mux.HandleFunc("GET /casino/api/health", h.serveHealth)
	h.mux = mux
	return h, nil
}

func (h *Handler) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	h.mux.ServeHTTP(w, r)
}

// ── index ───────────────────────────────────────────────────────────────

func (h *Handler) serveIndex(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	w.Header().Set("Cache-Control", "no-store")
	if err := h.tmpl.Execute(w, nil); err != nil {
		http.Error(w, "casino: template execute: "+err.Error(), http.StatusInternalServerError)
	}
}

// ── /casino/api/offer ───────────────────────────────────────────────────

// offerRequest carries the browser's SDP offer. Plain text, but JSON
// envelope keeps consistent shape if we add fields (player_id, etc.) later.
type offerRequest struct {
	SDP string `json:"sdp"`
}

type offerResponse struct {
	PeerID string `json:"peer_id"`
	SDP    string `json:"sdp"`
}

func (h *Handler) serveOffer(w http.ResponseWriter, r *http.Request) {
	var req offerRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, "decode body: "+err.Error())
		return
	}
	if req.SDP == "" {
		writeError(w, http.StatusBadRequest, ErrNoSDP.Error())
		return
	}
	// Cap the SDP exchange so a slow / wedged ICE gather doesn't tie up
	// rgsd's request goroutine indefinitely. Pion typically finishes host-
	// candidate gathering in <50 ms on LAN.
	ctx, cancel := context.WithTimeout(r.Context(), 5*time.Second)
	defer cancel()
	peerID, answer, err := h.cfg.SFU.AddSubscriber(ctx, req.SDP)
	if err != nil {
		h.log.Error("casino: AddSubscriber", "err", err)
		writeError(w, http.StatusInternalServerError, err.Error())
		return
	}
	h.log.Info("casino: subscriber attached", "peer_id", peerID)
	writeJSON(w, http.StatusOK, offerResponse{PeerID: peerID, SDP: answer})
}

// ── /casino/api/health ──────────────────────────────────────────────────

type healthResponse struct {
	Status      string `json:"status"`
	Subscribers int    `json:"subscribers"`
}

func (h *Handler) serveHealth(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, http.StatusOK, healthResponse{
		Status:      "ok",
		Subscribers: h.cfg.SFU.SubscriberCount(),
	})
}

// ── helpers ─────────────────────────────────────────────────────────────

type errorBody struct {
	Error string `json:"error"`
}

func writeJSON(w http.ResponseWriter, code int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(code)
	_ = json.NewEncoder(w).Encode(v)
}

func writeError(w http.ResponseWriter, code int, msg string) {
	writeJSON(w, code, errorBody{Error: msg})
}
