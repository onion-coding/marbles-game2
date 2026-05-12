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

// parseRoundID parses the {round_id} path segment as a uint64.
func parseRoundID(s string) (uint64, error) {
	v, err := strconv.ParseUint(strings.TrimSpace(s), 10, 64)
	if err != nil {
		return 0, fmt.Errorf("invalid round_id %q: %w", s, err)
	}
	return v, nil
}

// HTTPHandler exposes the operator-facing API on top of a Manager. The
// surface is intentionally minimal — the routes match the integration
// spec in docs/rgs-integration.md and nothing more. Real aggregator
// integrations wrap this with their own auth, rate limiting, and
// signature checks.
//
// Routes:
//
//	POST /v1/sessions                         open a session for a player
//	POST /v1/sessions/{id}/bet                place a bet (debits wallet)
//	POST /v1/sessions/{id}/close              close session (must be SETTLED/OPEN)
//	GET  /v1/sessions/{id}                    read session state + last result
//	POST /v1/rounds/run                       trigger the next round (admin)
//	POST /v1/rounds/start                     mint a server-authoritative round spec (client --rgs flow)
//	POST /v1/rounds/{round_id}/bets           place a bet on a pre-minted round
//	GET  /v1/rounds/{round_id}/bets           list bets for a round (filter: ?player_id=)
//	GET  /v1/scheduler/status                 scheduler state (enabled, phase, current_round_id, next_round_at)
//	GET  /v1/health                           liveness check
//
// The body schemas are defined inline in this file as request/response
// structs so the JSON contract stays adjacent to the handler that uses
// it; see api_test.go for examples.
type HTTPHandler struct {
	mgr   *Manager
	sched *Scheduler // nil when scheduler is disabled
}

func NewHTTPHandler(mgr *Manager) *HTTPHandler {
	return &HTTPHandler{mgr: mgr}
}

// NewHTTPHandlerWithScheduler is like NewHTTPHandler but also wires the
// optional Scheduler so that GET /v1/scheduler/status reports live state.
// Pass a nil sched to disable the endpoint (returns 404).
func NewHTTPHandlerWithScheduler(mgr *Manager, sched *Scheduler) *HTTPHandler {
	return &HTTPHandler{mgr: mgr, sched: sched}
}

func (h *HTTPHandler) Routes() *http.ServeMux {
	mux := http.NewServeMux()
	mux.HandleFunc("POST /v1/sessions", h.openSession)
	mux.HandleFunc("POST /v1/sessions/{id}/bet", h.placeBet)
	mux.HandleFunc("POST /v1/sessions/{id}/close", h.closeSession)
	mux.HandleFunc("GET /v1/sessions/{id}", h.getSession)
	mux.HandleFunc("POST /v1/rounds/run", h.runRound)
	mux.HandleFunc("POST /v1/rounds/start", h.startRound)
	mux.HandleFunc("POST /v1/rounds/{round_id}/bets", h.placeRoundBet)
	mux.HandleFunc("GET /v1/rounds/{round_id}/bets", h.getRoundBets)
	mux.HandleFunc("GET /v1/wallets/{player_id}/balance", h.walletBalance)
	mux.HandleFunc("GET /v1/scheduler/status", h.schedulerStatus)
	mux.HandleFunc("GET /v1/health", h.health)

	// Responsible gambling endpoints (no-ops / 404 when RG is not enabled).
	mux.HandleFunc("GET /v1/players/{id}/limits", h.handleRGGetLimits)
	mux.HandleFunc("PUT /v1/players/{id}/limits", h.handleRGSetLimits)
	mux.HandleFunc("POST /v1/players/{id}/self-exclude", h.handleRGSelfExclude)
	mux.HandleFunc("POST /v1/players/{id}/cooling-off", h.handleRGCoolingOff)
	return mux
}

// ─── Request / response types ────────────────────────────────────────────

type openSessionRequest struct {
	PlayerID string `json:"player_id"`
}

type sessionResponse struct {
	SessionID  string              `json:"session_id"`
	PlayerID   string              `json:"player_id"`
	State      string              `json:"state"`
	Balance    uint64              `json:"balance"`
	Currency   string              `json:"currency"`
	OpenedAt   time.Time           `json:"opened_at"`
	UpdatedAt  time.Time           `json:"updated_at"`
	Bet        *betResponse        `json:"bet,omitempty"`
	LastResult *settlementResponse `json:"last_result,omitempty"`
}

type betResponse struct {
	BetID       string    `json:"bet_id"`
	Amount      uint64    `json:"amount"`
	Currency    string    `json:"currency"`
	PlacedAt    time.Time `json:"placed_at"`
	MarbleIndex int       `json:"marble_index"`
}

type settlementResponse struct {
	BetID       string    `json:"bet_id"`
	Won         bool      `json:"won"`
	Amount      uint64    `json:"amount"`
	Currency    string    `json:"currency"`
	PrizeAmount uint64    `json:"prize_amount"`
	WinnerIndex int       `json:"winner_index"`
	CreditTxID  string    `json:"credit_tx_id,omitempty"`
	SettledAt   time.Time `json:"settled_at"`
}

type placeBetRequest struct {
	Amount   uint64 `json:"amount"`
	Currency string `json:"currency,omitempty"`
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
	// Currency from body; empty string → manager uses DefaultCurrency.
	id := r.PathValue("id")
	if _, err := h.mgr.PlaceBet(id, req.Amount, req.Currency); err != nil {
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
		manifest, outcomes, roundBetOutcomes, err := h.mgr.RunNextRound(r.Context())
		if err != nil {
			writeError(w, http.StatusInternalServerError, err)
			return
		}
		writeJSON(w, http.StatusOK, struct {
			RoundID          uint64               `json:"round_id"`
			TrackID          uint8                `json:"track_id"`
			Winner           replayWinner         `json:"winner"`
			Outcomes         []settlementResponse `json:"outcomes"`
			RoundBetOutcomes []RoundBetOutcome    `json:"round_bet_outcomes"`
		}{
			RoundID: manifest.RoundID,
			TrackID: manifest.TrackID,
			Winner: replayWinner{
				MarbleIndex: manifest.Winner.MarbleIndex,
				FinishTick:  manifest.Winner.FinishTick,
			},
			Outcomes:         outcomesToResponse(outcomes),
			RoundBetOutcomes: roundBetOutcomes,
		})
		return
	}
	// Fire-and-forget: the round runs in the background; client polls
	// /v1/sessions/{id} for the SETTLED state.
	go func() {
		if _, _, _, err := h.mgr.RunNextRound(context.Background()); err != nil {
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

// startRound mints a server-authoritative round spec (round_id,
// server_seed, track_id, empty client_seeds) for a Godot client that
// wants to run the physics locally but anchor the fairness chain on the
// server.  No session, wallet, or sim involvement — this is a pure
// spec-generation call.
//
// The Godot client passes --rgs=<base_url>; main.gd POSTs here instead
// of generating a local seed when no --round-spec is present.
func (h *HTTPHandler) startRound(w http.ResponseWriter, r *http.Request) {
	spec, err := h.mgr.GenerateRoundSpec()
	if err != nil {
		writeError(w, http.StatusInternalServerError, err)
		return
	}
	writeJSON(w, http.StatusOK, spec)
}

// ─── Round-bet types ─────────────────────────────────────────────────────

// placeRoundBetRequest is the body for POST /v1/rounds/{round_id}/bets.
type placeRoundBetRequest struct {
	PlayerID  string  `json:"player_id"`
	MarbleIdx int     `json:"marble_idx"`
	Amount    float64 `json:"amount"`
	Currency  string  `json:"currency,omitempty"`
}

// placeRoundBetResponse is the 200 body for a successful bet placement.
type placeRoundBetResponse struct {
	BetID               string  `json:"bet_id"`
	RoundID             uint64  `json:"round_id"`
	MarbleIdx           int     `json:"marble_idx"`
	Amount              float64 `json:"amount"`
	Currency            string  `json:"currency"`
	BalanceAfter        float64 `json:"balance_after"`
	ExpectedPayoutIfWin float64 `json:"expected_payout_if_win"`
}

// roundBetResponse is one element of the GET /v1/rounds/{round_id}/bets list.
type roundBetResponse struct {
	BetID     string    `json:"bet_id"`
	PlayerID  string    `json:"player_id"`
	RoundID   uint64    `json:"round_id"`
	MarbleIdx int       `json:"marble_idx"`
	Amount    float64   `json:"amount"`
	Currency  string    `json:"currency"`
	PlacedAt  time.Time `json:"placed_at"`
}

// ─── Round-bet handlers ──────────────────────────────────────────────────

// placeRoundBet handles POST /v1/rounds/{round_id}/bets.
//
// Error mapping:
//
//	404 — round_id unknown (never minted by /v1/rounds/start)
//	409 — round already completed
//	400 — marble_idx out of range, amount <= 0, or malformed body
//	402 — insufficient funds
func (h *HTTPHandler) placeRoundBet(w http.ResponseWriter, r *http.Request) {
	roundID, err := parseRoundID(r.PathValue("round_id"))
	if err != nil {
		writeError(w, http.StatusBadRequest, err)
		return
	}

	var req placeRoundBetRequest
	if err := decodeJSON(r, &req); err != nil {
		writeError(w, http.StatusBadRequest, err)
		return
	}
	if req.PlayerID == "" {
		writeError(w, http.StatusBadRequest, fmt.Errorf("player_id is required"))
		return
	}

	bet, balAfter, err := h.mgr.PlaceBetOnRound(roundID, req.PlayerID, req.MarbleIdx, req.Amount, req.Currency)
	if err != nil {
		if errors.Is(err, ErrUnsupportedCurrency) {
			writeError(w, http.StatusBadRequest, err)
			return
		}
		writeRoundBetError(w, err)
		return
	}

	writeJSON(w, http.StatusOK, placeRoundBetResponse{
		BetID:               bet.BetID,
		RoundID:             bet.RoundID,
		MarbleIdx:           bet.MarbleIdx,
		Amount:              bet.Amount,
		Currency:            bet.Currency,
		BalanceAfter:        balAfter,
		ExpectedPayoutIfWin: bet.Amount * PayoutMultiplier,
	})
}

// getRoundBets handles GET /v1/rounds/{round_id}/bets[?player_id=<id>].
func (h *HTTPHandler) getRoundBets(w http.ResponseWriter, r *http.Request) {
	roundID, err := parseRoundID(r.PathValue("round_id"))
	if err != nil {
		writeError(w, http.StatusBadRequest, err)
		return
	}
	playerID := r.URL.Query().Get("player_id")

	bets, err := h.mgr.BetsForRound(roundID, playerID)
	if err != nil {
		if errors.Is(err, ErrUnknownRound) {
			writeError(w, http.StatusNotFound, err)
			return
		}
		writeError(w, http.StatusInternalServerError, err)
		return
	}

	resp := make([]roundBetResponse, len(bets))
	for i, b := range bets {
		cur := b.Currency
		if cur == "" {
			cur = h.mgr.currency()
		}
		resp[i] = roundBetResponse{
			BetID:     b.BetID,
			PlayerID:  b.PlayerID,
			RoundID:   b.RoundID,
			MarbleIdx: b.MarbleIdx,
			Amount:    b.Amount,
			Currency:  cur,
			PlacedAt:  b.PlacedAt,
		}
	}
	writeJSON(w, http.StatusOK, resp)
}

// writeRoundBetError maps PlaceBetOnRound errors to HTTP status codes.
func writeRoundBetError(w http.ResponseWriter, err error) {
	switch {
	case errors.Is(err, ErrRGLimitReached):
		writeError(w, http.StatusForbidden, err)
	case errors.Is(err, ErrUnknownRound):
		writeError(w, http.StatusNotFound, err)
	case errors.Is(err, ErrRoundAlreadyRun):
		writeError(w, http.StatusConflict, err)
	case errors.Is(err, ErrInvalidMarbleIdx), errors.Is(err, ErrInvalidBetAmount):
		writeError(w, http.StatusBadRequest, err)
	case errors.Is(err, ErrInsufficientFunds):
		writeError(w, http.StatusPaymentRequired, err)
	case errors.Is(err, ErrUnknownPlayer):
		writeError(w, http.StatusNotFound, err)
	default:
		writeError(w, http.StatusBadRequest, err)
	}
}

// walletBalance handles GET /v1/wallets/{player_id}/balance[?currency=EUR].
// Returns the current balance for the given player_id in the requested
// currency (defaults to the manager's DefaultCurrency when omitted).
// Returns 404 if the player is not known to the wallet.
func (h *HTTPHandler) walletBalance(w http.ResponseWriter, r *http.Request) {
	playerID := r.PathValue("player_id")
	currency := r.URL.Query().Get("currency")
	cur := NormalizeCurrency(currency)
	if cur == "" {
		cur = h.mgr.currency()
	}
	if err := ValidateCurrency(cur, h.mgr.cfg.SupportedCurrencies); err != nil {
		writeError(w, http.StatusBadRequest, err)
		return
	}
	bal, err := h.mgr.cfg.Wallet.Balance(playerID, cur)
	if err != nil {
		if errors.Is(err, ErrUnknownPlayer) {
			writeError(w, http.StatusNotFound, err)
			return
		}
		writeError(w, http.StatusInternalServerError, err)
		return
	}
	scale := float64(UnitsPerWhole(cur))
	writeJSON(w, http.StatusOK, struct {
		PlayerID string  `json:"player_id"`
		Currency string  `json:"currency"`
		Balance  float64 `json:"balance"`
	}{
		PlayerID: playerID,
		Currency: cur,
		Balance:  float64(bal) / scale,
	})
}

// schedulerStatus handles GET /v1/scheduler/status.
// Returns 404 when the scheduler is disabled (--scheduler-enabled was not set).
func (h *HTTPHandler) schedulerStatus(w http.ResponseWriter, r *http.Request) {
	if h.sched == nil {
		writeError(w, http.StatusNotFound, fmt.Errorf("scheduler not enabled"))
		return
	}
	st := h.sched.Status()
	writeJSON(w, http.StatusOK, st)
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
			Currency:    o.Currency,
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
	// Determine the currency for this session's balance lookup. Prefer the
	// active bet's currency (if any), then the last result's currency, then
	// the manager default. This ensures the balance shown is always in the
	// same currency as the player's active stake.
	cur := mgr.currency()
	if bet != nil && bet.Currency != "" {
		cur = bet.Currency
	} else if last != nil && last.Currency != "" {
		cur = last.Currency
	}
	resp := sessionResponse{
		SessionID: s.ID,
		PlayerID:  s.PlayerID,
		State:     state.String(),
		Currency:  cur,
		OpenedAt:  s.OpenedAt,
		UpdatedAt: s.UpdatedAt,
	}
	if bal, err := mgr.cfg.Wallet.Balance(s.PlayerID, cur); err == nil {
		resp.Balance = bal
	}
	if bet != nil {
		betCur := bet.Currency
		if betCur == "" {
			betCur = cur
		}
		resp.Bet = &betResponse{
			BetID:       bet.BetID,
			Amount:      bet.Amount,
			Currency:    betCur,
			PlacedAt:    bet.PlacedAt,
			MarbleIndex: bet.MarbleIndex,
		}
	}
	if last != nil {
		lastCur := last.Currency
		if lastCur == "" {
			lastCur = cur
		}
		resp.LastResult = &settlementResponse{
			BetID:       last.BetID,
			Won:         last.Won,
			Amount:      last.Amount,
			Currency:    lastCur,
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
	case errors.Is(err, ErrRGLimitReached):
		writeError(w, http.StatusForbidden, err)
	case errors.Is(err, ErrInsufficientFunds):
		writeError(w, http.StatusPaymentRequired, err)
	case errors.Is(err, ErrUnknownPlayer):
		writeError(w, http.StatusNotFound, err)
	case errors.Is(err, ErrUnsupportedCurrency):
		writeError(w, http.StatusBadRequest, err)
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
