// Package rgs is the operator-facing layer (Remote Game Server). It bridges
// "a player wants to bet on a marble" (operator semantics) to "let's run a
// deterministic round and audit it" (everything else in this server).
//
// The package is deliberately a thin orchestration shell over the existing
// round / sim / replay / rtp packages — it doesn't reimplement game logic,
// it just decides when to call them and how to talk to whoever's holding
// the player's wallet.
//
// Wallet flow (simplified, see docs/rgs-integration.md for full spec):
//
//	1. Operator opens a session for player P.
//	2. Operator places a bet for player P on the next round.
//	   → rgs.Manager calls Wallet.Debit(P, amount).
//	3. Round runs (sim → replay → rtp).
//	4. rgs.Manager settles the round:
//	   → for every winning bet, Wallet.Credit(P, prize).
//	   → on any wallet-side error, the bet is held in a "pending" state and
//	     the operator must call /session/{id}/reconcile to retry.
//	5. Round audit entry persists exactly as before — adding a `bets` field
//	   so a regulator can re-derive every player's expected payout from the
//	   manifest alone.
//
// Wallet is the interface the rgs package consumes; operators bring their
// own implementation (typically an HTTP client to their RGS aggregator).
// In tests / demo runs, MockWallet is the in-memory reference impl.
package rgs

import (
	"errors"
	"fmt"
	"sync"
)

// Wallet is the operator-side ledger. Implementations are expected to be
// safe for concurrent calls; rgs.Manager may call Debit / Credit from
// multiple goroutines (e.g. settlement of N bets in parallel).
//
// Amount is in the smallest denomination the operator uses — cents,
// satoshis, USDC-6, whatever — and is treated as opaque integer money
// throughout the server (currency conversion is operator-side).
//
// Errors:
//   - ErrInsufficientFunds when Debit would drive a balance below zero.
//   - ErrUnknownPlayer when the player_id isn't recognised.
//   - Anything else is treated as transient by the manager: settlement
//     marks the bet "pending" so the operator can retry.
type Wallet interface {
	// Debit removes `amount` from `playerID`'s balance. Idempotency key
	// `txID` is provided by the manager so an operator can dedupe retries
	// (the same bet committed twice would otherwise charge the player
	// twice). Implementations SHOULD return success on duplicate txID
	// rather than error.
	Debit(playerID string, amount uint64, txID string) error

	// Credit adds `amount` to `playerID`'s balance. Same idempotency
	// contract as Debit.
	Credit(playerID string, amount uint64, txID string) error

	// Balance returns the current balance for `playerID`. Used by the
	// session state endpoint so a UI can display "you have N left".
	Balance(playerID string) (uint64, error)
}

var (
	ErrInsufficientFunds = errors.New("insufficient funds")
	ErrUnknownPlayer     = errors.New("unknown player")
	ErrDuplicateTxID     = errors.New("duplicate tx id") // returned by impls that want strict dedup; rgs.Manager treats any error here as "retry safely"
)

// MockWallet is the in-memory reference implementation. Used in tests and
// the rgsd demo binary. Tracks per-player balances and records every
// applied transaction so a test can assert on the ledger.
type MockWallet struct {
	mu       sync.Mutex
	balances map[string]uint64
	applied  map[string]int64 // txID → amount (positive = credit, negative = debit). Lets us dedupe.
}

func NewMockWallet() *MockWallet {
	return &MockWallet{
		balances: map[string]uint64{},
		applied:  map[string]int64{},
	}
}

// SetBalance is a test helper — bumps a player's balance directly without
// going through Debit/Credit. Production wallets would never expose this.
func (w *MockWallet) SetBalance(playerID string, amount uint64) {
	w.mu.Lock()
	defer w.mu.Unlock()
	w.balances[playerID] = amount
}

func (w *MockWallet) Debit(playerID string, amount uint64, txID string) error {
	w.mu.Lock()
	defer w.mu.Unlock()
	if playerID == "" {
		return fmt.Errorf("%w: empty playerID", ErrUnknownPlayer)
	}
	if amount == 0 {
		return fmt.Errorf("rgs: MockWallet.Debit: amount must be > 0")
	}
	if txID == "" {
		return fmt.Errorf("rgs: MockWallet.Debit: txID must be non-empty")
	}
	if _, ok := w.balances[playerID]; !ok {
		return fmt.Errorf("%w: %q", ErrUnknownPlayer, playerID)
	}
	if prev, ok := w.applied[txID]; ok {
		// Idempotent replay: the original debit was -amount; assert the
		// caller is asking for the same operation, then return success.
		if prev != -int64(amount) {
			return fmt.Errorf("txID %q reused for different operation (was %d, now -%d)", txID, prev, amount)
		}
		return nil
	}
	if w.balances[playerID] < amount {
		return fmt.Errorf("%w: player=%q balance=%d wanted=%d", ErrInsufficientFunds, playerID, w.balances[playerID], amount)
	}
	w.balances[playerID] -= amount
	w.applied[txID] = -int64(amount)
	return nil
}

func (w *MockWallet) Credit(playerID string, amount uint64, txID string) error {
	w.mu.Lock()
	defer w.mu.Unlock()
	if playerID == "" {
		return fmt.Errorf("%w: empty playerID", ErrUnknownPlayer)
	}
	if amount == 0 {
		return fmt.Errorf("rgs: MockWallet.Credit: amount must be > 0")
	}
	if txID == "" {
		return fmt.Errorf("rgs: MockWallet.Credit: txID must be non-empty")
	}
	// Auto-create account on first credit — mirrors what operator wallets do
	// (a credit that arrives before any debit opens the account implicitly).
	if _, ok := w.balances[playerID]; !ok {
		w.balances[playerID] = 0
	}
	if prev, ok := w.applied[txID]; ok {
		if prev != int64(amount) {
			return fmt.Errorf("txID %q reused for different operation (was %d, now +%d)", txID, prev, amount)
		}
		return nil
	}
	w.balances[playerID] += amount
	w.applied[txID] = int64(amount)
	return nil
}

func (w *MockWallet) Balance(playerID string) (uint64, error) {
	w.mu.Lock()
	defer w.mu.Unlock()
	if playerID == "" {
		return 0, fmt.Errorf("%w: empty playerID", ErrUnknownPlayer)
	}
	bal, ok := w.balances[playerID]
	if !ok {
		return 0, fmt.Errorf("%w: %q", ErrUnknownPlayer, playerID)
	}
	return bal, nil
}

// AppliedAmount returns the signed amount the wallet recorded for `txID`,
// or 0 / false if no such tx exists. Test-only helper; production wallets
// don't typically expose ledger lookups by txID.
func (w *MockWallet) AppliedAmount(txID string) (int64, bool) {
	w.mu.Lock()
	defer w.mu.Unlock()
	v, ok := w.applied[txID]
	return v, ok
}
