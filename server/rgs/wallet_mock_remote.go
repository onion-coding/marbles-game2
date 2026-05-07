package rgs

// MockRemoteWallet is an in-process HTTP server that exposes the generic
// wallet REST protocol (POST /wallet/balance, /wallet/debit, /wallet/credit).
// It is used exclusively in tests so the contract suite can exercise HTTPWallet
// over real TCP without needing an external service.
//
// Features:
//   - Thread-safe in-memory ledger (same semantics as MockWallet)
//   - Idempotent operations: same tx_id → no-op, same balance
//   - Configurable fault injection via FaultMode
//   - Exposes helpers (SetBalance, GetBalance) for test setup/assertion

import (
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"sync"
)

// RemoteFaultMode controls how MockRemoteWallet misbehaves for resilience
// tests. Zero value means normal operation.
type RemoteFaultMode int

const (
	// RemoteFaultNone is the default: no injected errors.
	RemoteFaultNone RemoteFaultMode = iota
	// RemoteFaultServer500 makes every request return HTTP 500 regardless
	// of the payload. Useful for testing retry/backoff logic.
	RemoteFaultServer500
	// RemoteFaultInsufficientFunds makes every debit return 402. Useful
	// for testing that HTTPWallet correctly surfaces ErrInsufficientFunds.
	RemoteFaultInsufficientFunds
)

// remoteWalletKey is the composite key used by MockRemoteWallet's balance map.
type remoteWalletKey struct {
	playerID string
	currency string
}

// MockRemoteWallet is the in-memory server side. Start it with NewMockRemoteWallet
// or attach its Handler to any *httptest.Server you create yourself.
type MockRemoteWallet struct {
	mu        sync.Mutex
	balances  map[remoteWalletKey]uint64
	applied   map[string]int64 // txID → signed amount (negative=debit, positive=credit)
	faultMode RemoteFaultMode

	// Server is only set when constructed via NewMockRemoteWallet; callers
	// that bring their own httptest.Server leave this nil.
	Server *httptest.Server
}

// NewMockRemoteWallet creates and starts an httptest.Server backed by a
// MockRemoteWallet, pre-seeded with the given player balances in
// DefaultCurrency (pass nil for an empty ledger). Call Close() when done.
func NewMockRemoteWallet(initial map[string]uint64) *MockRemoteWallet {
	m := &MockRemoteWallet{
		balances: make(map[remoteWalletKey]uint64),
		applied:  make(map[string]int64),
	}
	if initial != nil {
		for k, v := range initial {
			m.balances[remoteWalletKey{k, DefaultCurrency}] = v
		}
	}
	m.Server = httptest.NewServer(m.Handler())
	return m
}

// Close shuts down the embedded httptest.Server (if any).
func (m *MockRemoteWallet) Close() {
	if m.Server != nil {
		m.Server.Close()
	}
}

// URL returns the base URL of the embedded httptest.Server. Panics if
// NewMockRemoteWallet was not used (Server is nil).
func (m *MockRemoteWallet) URL() string {
	if m.Server == nil {
		panic("MockRemoteWallet: no embedded server; use NewMockRemoteWallet or set Server manually")
	}
	return m.Server.URL
}

// SetBalance sets a player's balance in DefaultCurrency directly (test
// helper — bypasses debit/credit logic). Creates the player entry if it
// doesn't exist. Mirrors MockWallet.SetBalance for drop-in compatibility.
func (m *MockRemoteWallet) SetBalance(playerID string, amount uint64) {
	m.SetBalanceCurrency(playerID, DefaultCurrency, amount)
}

// SetBalanceCurrency sets a player's balance in the specified currency.
func (m *MockRemoteWallet) SetBalanceCurrency(playerID, currency string, amount uint64) {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.balances[remoteWalletKey{playerID, NormalizeCurrency(currency)}] = amount
}

// GetBalance returns the raw balance for a player in DefaultCurrency.
// Returns 0,false if the player doesn't exist.
func (m *MockRemoteWallet) GetBalance(playerID string) (uint64, bool) {
	return m.GetBalanceCurrency(playerID, DefaultCurrency)
}

// GetBalanceCurrency returns the raw balance for (player, currency).
func (m *MockRemoteWallet) GetBalanceCurrency(playerID, currency string) (uint64, bool) {
	m.mu.Lock()
	defer m.mu.Unlock()
	v, ok := m.balances[remoteWalletKey{playerID, NormalizeCurrency(currency)}]
	return v, ok
}

// SetFault configures fault injection. Thread-safe.
func (m *MockRemoteWallet) SetFault(mode RemoteFaultMode) {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.faultMode = mode
}

// Handler returns an http.Handler that serves the three wallet endpoints.
// Mount it anywhere — the embedded httptest.Server mounts it at "/".
func (m *MockRemoteWallet) Handler() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("/wallet/balance", m.handleBalance)
	mux.HandleFunc("/wallet/debit", m.handleDebit)
	mux.HandleFunc("/wallet/credit", m.handleCredit)
	return mux
}

// ─── internal helpers ─────────────────────────────────────────────────────────

func (m *MockRemoteWallet) fault() RemoteFaultMode {
	m.mu.Lock()
	defer m.mu.Unlock()
	return m.faultMode
}

// remoteWriteJSON writes a JSON body with the given status code.
// Named with a "remote" prefix to avoid collision with writeJSON in api.go.
func remoteWriteJSON(w http.ResponseWriter, status int, body any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(body)
}

// remoteWriteError writes a {"error": msg} JSON response.
func remoteWriteError(w http.ResponseWriter, status int, msg string) {
	remoteWriteJSON(w, status, map[string]string{"error": msg})
}

type remoteWalletReq struct {
	PlayerID string `json:"player_id"`
	Amount   uint64 `json:"amount"`
	Currency string `json:"currency"`
	TxID     string `json:"tx_id"`
}

func decodeReq(r *http.Request, dst *remoteWalletReq) bool {
	if err := json.NewDecoder(r.Body).Decode(dst); err != nil {
		return false
	}
	return true
}

// effectiveCurrency returns the currency from the request, defaulting to
// DefaultCurrency when the field is empty.
func effectiveCurrency(req *remoteWalletReq) string {
	if req.Currency == "" {
		return DefaultCurrency
	}
	return NormalizeCurrency(req.Currency)
}

// ─── handlers ─────────────────────────────────────────────────────────────────

func (m *MockRemoteWallet) handleBalance(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		remoteWriteError(w, http.StatusMethodNotAllowed, "POST required")
		return
	}
	if f := m.fault(); f == RemoteFaultServer500 {
		remoteWriteError(w, http.StatusInternalServerError, "injected server error")
		return
	}

	var req remoteWalletReq
	if !decodeReq(r, &req) {
		remoteWriteError(w, http.StatusBadRequest, "invalid JSON")
		return
	}
	if req.PlayerID == "" {
		remoteWriteError(w, http.StatusBadRequest, "player_id required")
		return
	}

	cur := effectiveCurrency(&req)
	key := remoteWalletKey{req.PlayerID, cur}

	m.mu.Lock()
	defer m.mu.Unlock()
	bal, ok := m.balances[key]
	if !ok {
		remoteWriteError(w, http.StatusNotFound, fmt.Sprintf("unknown player %q in %s", req.PlayerID, cur))
		return
	}
	remoteWriteJSON(w, http.StatusOK, map[string]uint64{"balance": bal})
}

func (m *MockRemoteWallet) handleDebit(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		remoteWriteError(w, http.StatusMethodNotAllowed, "POST required")
		return
	}
	switch m.fault() {
	case RemoteFaultServer500:
		remoteWriteError(w, http.StatusInternalServerError, "injected server error")
		return
	case RemoteFaultInsufficientFunds:
		remoteWriteError(w, http.StatusPaymentRequired, "injected insufficient funds")
		return
	}

	var req remoteWalletReq
	if !decodeReq(r, &req) {
		remoteWriteError(w, http.StatusBadRequest, "invalid JSON")
		return
	}
	if req.PlayerID == "" {
		remoteWriteError(w, http.StatusBadRequest, "player_id required")
		return
	}
	if req.TxID == "" {
		remoteWriteError(w, http.StatusBadRequest, "tx_id required")
		return
	}
	if req.Amount == 0 {
		remoteWriteError(w, http.StatusBadRequest, "amount must be > 0")
		return
	}

	cur := effectiveCurrency(&req)
	key := remoteWalletKey{req.PlayerID, cur}

	m.mu.Lock()
	defer m.mu.Unlock()

	bal, ok := m.balances[key]
	if !ok {
		remoteWriteError(w, http.StatusNotFound, fmt.Sprintf("unknown player %q in %s", req.PlayerID, cur))
		return
	}

	// Idempotency check.
	if prev, seen := m.applied[req.TxID]; seen {
		if prev != -int64(req.Amount) {
			remoteWriteError(w, http.StatusBadRequest,
				fmt.Sprintf("tx_id %q reused for different operation", req.TxID))
			return
		}
		// Idempotent replay — return 409 Conflict with current balance.
		remoteWriteJSON(w, http.StatusConflict, map[string]uint64{"balance": bal})
		return
	}

	if bal < req.Amount {
		remoteWriteError(w, http.StatusPaymentRequired,
			fmt.Sprintf("insufficient funds: balance=%d wanted=%d currency=%s", bal, req.Amount, cur))
		return
	}

	m.balances[key] -= req.Amount
	m.applied[req.TxID] = -int64(req.Amount)
	remoteWriteJSON(w, http.StatusOK, map[string]uint64{"balance": m.balances[key]})
}

func (m *MockRemoteWallet) handleCredit(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		remoteWriteError(w, http.StatusMethodNotAllowed, "POST required")
		return
	}
	if f := m.fault(); f == RemoteFaultServer500 {
		remoteWriteError(w, http.StatusInternalServerError, "injected server error")
		return
	}

	var req remoteWalletReq
	if !decodeReq(r, &req) {
		remoteWriteError(w, http.StatusBadRequest, "invalid JSON")
		return
	}
	if req.PlayerID == "" {
		remoteWriteError(w, http.StatusBadRequest, "player_id required")
		return
	}
	if req.TxID == "" {
		remoteWriteError(w, http.StatusBadRequest, "tx_id required")
		return
	}
	if req.Amount == 0 {
		remoteWriteError(w, http.StatusBadRequest, "amount must be > 0")
		return
	}

	cur := effectiveCurrency(&req)
	key := remoteWalletKey{req.PlayerID, cur}

	m.mu.Lock()
	defer m.mu.Unlock()

	// Credit creates the player account in this currency if it doesn't exist.
	if _, ok := m.balances[key]; !ok {
		m.balances[key] = 0
	}

	// Idempotency check.
	if prev, seen := m.applied[req.TxID]; seen {
		if prev != int64(req.Amount) {
			remoteWriteError(w, http.StatusBadRequest,
				fmt.Sprintf("tx_id %q reused for different operation", req.TxID))
			return
		}
		// Idempotent replay.
		remoteWriteJSON(w, http.StatusConflict, map[string]uint64{"balance": m.balances[key]})
		return
	}

	m.balances[key] += req.Amount
	m.applied[req.TxID] = int64(req.Amount)
	remoteWriteJSON(w, http.StatusOK, map[string]uint64{"balance": m.balances[key]})
}
