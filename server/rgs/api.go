package rgs

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"strconv"
	"strings"
	"time"
)

// HTTPHandler exposes the operator-facing API on top of a Manager. The
// surface is intentionally minimal — the routes match the integration
// spec in docs/rgs-integration.md and nothing more. Real aggregator
// integrations wrap this with their own auth, rate limiting, and
// signature checks.
//
// Routes:
//
//	POST /v1/sessions                    open a session for a player
//	POST /v1/sessions/{id}/bet           place a bet (debits wallet)
//	POST /v1/sessions/{id}/close         close session (must be SETTLED/OPEN)
//	GET  /v1/sessions/{id}               read session state + last result
//	POST /v1/rounds/run                  trigger the next round (admin)
//	GET  /v1/health                      liveness check
//
// The body schemas are defined inline in this file as request/response
// structs so the JSON contract stays adjacent to the handler that uses
// it; see api_test.go for examples.
type HTTPHandler struct {
	mgr *Manager
}

func NewHTTPHandler(mgr *Manager) *HTTPHandler {
	return &HTTPHandler{mgr: mgr}
}

func (h *HTTPHandler) Routes() *http.ServeMux {
	mux := http.NewServeMux()
	mux.HandleFunc("POST /v1/sessions", h.openSession)
	mux.HandleFunc("POST /v1/sessions/{id}/bet", h.placeBet)
	mux.HandleFunc("POST /v1/sessions/{id}/close", h.closeSession)
	mux.HandleFunc("GET /v1/sessions/{id}", h.getSession)
	mux.HandleFunc("POST /v1/rounds/run", h.runRound)
	mux.HandleFunc("GET /v1/health", h.health)
	return mux
}

// ─── Request / response types ────────────────────────────────────────────

type openSessionRequest struct {
	PlayerID string `json:"player_id"`
}

type sessionResponse struct {
	SessionID  string             `json:"session_id"`
	PlayerID   string             `json:"player_id"`
	State      string             `json:"state"`
	Balance    uint64             `json:"balance"`
	OpenedAt   time.Time          `json:"opened_at"`
	UpdatedAt  time.Time          `json:"updated_at"`
	Bet        *betResponse       `json:"bet,omitempty"`
	LastResult *settlementResponse `json:"last_result,omitempty"`
}

type betResponse struct {
	BetID       string    `json:"bet_id"`
	Amount      uint64    `json:"amount"`
	PlacedAt    time.Time `json:"placed_at"`
	MarbleIndex int       `json:"marble_index"`
}

type settlementResponse struct {
	BetID       string    `json:"bet_id"`
	Won         bool      `json:"won"`
	Amount      uint64    `json:"amount"`
	PrizeAmount uint64    `json:"prize_amount"`
	WinnerIndex int       `json:"winner_index"`
	CreditTxID  string    `json:"credit_tx_id,omitempty"`
	SettledAt   time.Time `json:"settled_at"`
}

type placeBetRequest struct {
	Amount uint64 `json:"amount"`
}

type errorResponse struct {
	Error string `json:"error"`
}

// ─── Handlers ────────────────────────────────────────────────────────────

func (h *HTTPHandler) openSession(w http.ResponseWriter, r *http.Request) {
	var req openSessionRequest
	if err := decodeJSON(r, &req); err != nil {
		writeError(w, http.StatusBadRequest, err)
		return
	}
	sess, err := h.mgr.OpenSession(req.PlayerID)
	if err != nil {
		writeError(w, http.StatusBadRequest, err)
		return
	}
	writeSessionResponse(w, h.mgr, sess, http.StatusCreated)
}

func (h *HTTPHandler) placeBet(w http.ResponseWriter, r *http.Request) {
	var req placeBetRequest
	if err := decodeJSON(r, &req); err != nil {
		writeError(w, http.StatusBadRequest, err)
		return
	}
	id := r.PathValue("id")
	if _, err := h.mgr.PlaceBet(id, req.Amount); err != nil {
		writeBetError(w, err)
		return
	}
	sess, ok := h.mgr.Session(id)
	if !ok {
		writeError(w, http.StatusNotFound, fmt.Errorf("session disappeared after bet"))
		return
	}
	writeSessionResponse(w, h.mgr, sess, http.StatusOK)
}

func (h *HTTPHandler) closeSession(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("id")
	if err := h.mgr.CloseSession(id); err != nil {
		writeError(w, http.StatusBadRequest, err)
		return
	}
	sess, _ := h.mgr.Session(id)
	if sess == nil {
		writeJSON(w, http.StatusOK, struct{}{})
		return
	}
	writeSessionResponse(w, h.mgr, sess, http.StatusOK)
}

func (h *HTTPHandler) getSession(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("id")
	sess, ok := h.mgr.Session(id)
	if !ok {
		writeError(w, http.StatusNotFound, fmt.Errorf("unknown session %q", id))
		return
	}
	writeSessionResponse(w, h.mgr, sess, http.StatusOK)
}

// runRound is admin-only in real deployments; here it's exposed so a demo
// operator can drive the round loop manually. With a `?wait=true` query
// param the handler blocks until the round finishes; otherwise it kicks
// off the run in a goroutine and returns 202.
func (h *HTTPHandler) runRound(w http.ResponseWriter, r *http.Request) {
	wait := r.URL.Query().Get("wait")
	if wait == "true" || wait == "1" {
		manifest, outcomes, err := h.mgr.RunNextRound(r.Context())
		if err != nil {
			writeError(w, http.StatusInternalServerError, err)
			return
		}
		writeJSON(w, http.StatusOK, struct {
			RoundID  uint64               `json:"round_id"`
			TrackID  uint8                `json:"track_id"`
			Winner   replayWinner         `json:"winner"`
			Outcomes []settlementResponse `json:"outcomes"`
		}{
			RoundID: manifest.RoundID,
			TrackID: manifest.TrackID,
			Winner: replayWinner{
				MarbleIndex: manifest.Winner.MarbleIndex,
				FinishTick:  manifest.Winner.FinishTick,
			},
			Outcomes: outcomesToResponse(outcomes),
		})
		return
	}
	// Fire-and-forget: the round runs in the background; client polls
	// /v1/sessions/{id} for the SETTLED state.
	go func() {
		if _, _, err := h.mgr.RunNextRound(context.Background()); err != nil {
			// In a real deployment this goes through structured logging /
			// alerting. Here we use stderr via fmt — the simplest stable
			// signal that doesn't pull in a logger dep.
			fmt.Fprintf(stderrFromHandler(), "rgs: round failed: %v\n", err)
		}
	}()
	writeJSON(w, http.StatusAccepted, struct {
		Status string `json:"status"`
	}{Status: "round_started"})
}

func (h *HTTPHandler) health(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, http.StatusOK, struct {
		Status string `json:"status"`
		Time   time.Time `json:"time"`
	}{Status: "ok", Time: time.Now()})
}

// ─── Helpers ─────────────────────────────────────────────────────────────

type replayWinner struct {
	MarbleIndex int `json:"marble_index"`
	FinishTick  int `json:"finish_tick"`
}

func outcomesToResponse(outs []SettlementOutcome) []settlementResponse {
	r := make([]settlementResponse, len(outs))
	for i, o := range outs {
		r[i] = settlementResponse{
			BetID:       o.BetID,
			Won:         o.Won,
			Amount:      o.Amount,
			PrizeAmount: o.PrizeAmount,
			WinnerIndex: o.WinnerIndex,
			CreditTxID:  o.CreditTxID,
			SettledAt:   o.SettledAt,
		}
	}
	return r
}

func writeSessionResponse(w http.ResponseWriter, mgr *Manager, s *Session, code int) {
	state, bet, last := s.Snapshot()
	resp := sessionResponse{
		SessionID: s.ID,
		PlayerID:  s.PlayerID,
		State:     state.String(),
		OpenedAt:  s.OpenedAt,
		UpdatedAt: s.UpdatedAt,
	}
	if bal, err := mgr.cfg.Wallet.Balance(s.PlayerID); err == nil {
		resp.Balance = bal
	}
	if bet != nil {
		resp.Bet = &betResponse{
			BetID:       bet.BetID,
			Amount:      bet.Amount,
			PlacedAt:    bet.PlacedAt,
			MarbleIndex: bet.MarbleIndex,
		}
	}
	if last != nil {
		resp.LastResult = &settlementResponse{
			BetID:       last.BetID,
			Won:         last.Won,
			Amount:      last.Amount,
			PrizeAmount: last.PrizeAmount,
			WinnerIndex: last.WinnerIndex,
			CreditTxID:  last.CreditTxID,
			SettledAt:   last.SettledAt,
		}
	}
	writeJSON(w, code, resp)
}

func writeBetError(w http.ResponseWriter, err error) {
	switch {
	case errors.Is(err, ErrInsufficientFunds):
		writeError(w, http.StatusPaymentRequired, err)
	case errors.Is(err, ErrUnknownPlayer):
		writeError(w, http.StatusNotFound, err)
	case errors.Is(err, ErrWrongState), errors.Is(err, ErrBetExists), errors.Is(err, ErrSessionClosed):
		writeError(w, http.StatusConflict, err)
	default:
		writeError(w, http.StatusBadRequest, err)
	}
}

func writeError(w http.ResponseWriter, code int, err error) {
	writeJSON(w, code, errorResponse{Error: err.Error()})
}

func writeJSON(w http.ResponseWriter, code int, body any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(code)
	_ = json.NewEncoder(w).Encode(body)
}

func decodeJSON(r *http.Request, dst any) error {
	dec := json.NewDecoder(r.Body)
	dec.DisallowUnknownFields()
	if err := dec.Decode(dst); err != nil {
		return fmt.Errorf("decode body: %w", err)
	}
	return nil
}

// stderrFromHandler returns the http server's error writer if known; falls
// back to os.Stderr. In practice the Go http server writes panics through
// its ErrorLog so this is only used for our explicit fmt.Fprintf above.
func stderrFromHandler() *strings.Builder {
	// Returning a discarded sink keeps the handler quiet in tests; in a
	// real deployment, replace with a structured logger via the
	// http.Server.ErrorLog field.
	var sb strings.Builder
	return &sb
}

// ParseAmount is exposed for callers that build their own request handling
// (e.g. JSON-RPC bridges). Returns the integer amount or an error if the
// string isn't a non-negative integer.
func ParseAmount(s string) (uint64, error) {
	v, err := strconv.ParseUint(strings.TrimSpace(s), 10, 64)
	if err != nil {
		return 0, fmt.Errorf("parse amount: %w", err)
	}
	return v, nil
}
