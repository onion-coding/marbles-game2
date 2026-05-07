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
//  1. Operator opens a session for player P.
//  2. Operator places a bet for player P on the next round.
//     → rgs.Manager calls Wallet.Debit(P, amount, currency, txID).
//  3. Round runs (sim → replay → rtp).
//  4. rgs.Manager settles the round:
//     → for every winning bet, Wallet.Credit(P, prize, currency, txID).
//     → on any wallet-side error, the bet is held in a "pending" state and
//     the operator must call /session/{id}/reconcile to retry.
//  5. Round audit entry persists exactly as before — adding a `bets` field
//     so a regulator can re-derive every player's expected payout from the
//     manifest alone.
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
// Amount is in the smallest denomination for the given currency:
//   - Fiat (EUR/USD/GBP): cents — 1.00 = 100 units
//   - Crypto (BTC/ETH/USDT): satoshi-style — 1.00000000 = 100_000_000 units
//
// Currency conversion is operator-side; the server treats amounts as opaque
// integers within a given currency and never converts between currencies.
//
// Errors:
//   - ErrInsufficientFunds when Debit would drive a balance below zero.
//   - ErrUnknownPlayer when the player_id isn't recognised.
//   - ErrUnsupportedCurrency when the currency code is not in the whitelist.
//   - Anything else is treated as transient by the manager: settlement
//     marks the bet "pending" so the operator can retry.
type Wallet interface {
	// Debit removes `amount` from `playerID`'s balance in `currency`.
	// Idempotency key `txID` is provided by the manager so an operator can
	// dedupe retries. Implementations SHOULD return success on duplicate
	// txID rather than error.
	Debit(playerID string, amount uint64, currency, txID string) error

	// Credit adds `amount` to `playerID`'s balance in `currency`. Same
	// idempotency contract as Debit.
	Credit(playerID string, amount uint64, currency, txID string) error

	// Balance returns the current balance for `playerID` in `currency`.
	// Used by the session state endpoint and the wallet-balance API.
	Balance(playerID, currency string) (uint64, error)

	// Snapshot returns a full read of the ledger as
	// player → {currency → balance}. Used by persist.go and tests.
	Snapshot() map[string]map[string]uint64

	// Restore replaces the entire ledger with the provided snapshot. Old
	// single-currency snapshots are handled via RestoreFromLegacy (MockWallet).
	Restore(map[string]map[string]uint64)
}

var (
	ErrInsufficientFunds = errors.New("insufficient funds")
	ErrUnknownPlayer     = errors.New("unknown player")
	ErrDuplicateTxID     = errors.New("duplicate tx id") // returned by impls that want strict dedup; rgs.Manager treats any error here as "retry safely"
)

// walletKey is the composite key used by MockWallet's balance map.
type walletKey struct {
	playerID string
	currency string
}

// MockWallet is the in-memory reference implementation. Used in tests and
// the rgsd demo binary. Tracks per-(player,currency) balances and records
// every applied transaction so a test can assert on the ledger.
//
// Backward compatibility: SetBalance / Balance (without currency arg) still
// work via the DefaultCurrency ("EUR") shim so existing single-currency
// callers compile and run unchanged.
type MockWallet struct {
	mu       sync.Mutex
	balances map[walletKey]uint64
	applied  map[string]int64 // txID → amount (positive = credit, negative = debit). Lets us dedupe.
}

func NewMockWallet() *MockWallet {
	return &MockWallet{
		balances: map[walletKey]uint64{},
		applied:  map[string]int64{},
	}
}

// SetBalance is a test helper — bumps a player's balance in DefaultCurrency
// ("EUR") directly without going through Debit/Credit. Existing tests that
// call SetBalance("alice", 1000) continue to work unchanged.
func (w *MockWallet) SetBalance(playerID string, amount uint64) {
	w.SetBalanceCurrency(playerID, DefaultCurrency, amount)
}

// SetBalanceCurrency is the currency-aware variant of SetBalance.
func (w *MockWallet) SetBalanceCurrency(playerID, currency string, amount uint64) {
	w.mu.Lock()
	defer w.mu.Unlock()
	w.balances[walletKey{playerID, NormalizeCurrency(currency)}] = amount
}

func (w *MockWallet) Debit(playerID string, amount uint64, currency, txID string) error {
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
	cur := NormalizeCurrency(currency)
	key := walletKey{playerID, cur}
	if _, ok := w.balances[key]; !ok {
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
	if w.balances[key] < amount {
		return fmt.Errorf("%w: player=%q currency=%s balance=%d wanted=%d",
			ErrInsufficientFunds, playerID, cur, w.balances[key], amount)
	}
	w.balances[key] -= amount
	w.applied[txID] = -int64(amount)
	return nil
}

func (w *MockWallet) Credit(playerID string, amount uint64, currency, txID string) error {
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
	cur := NormalizeCurrency(currency)
	key := walletKey{playerID, cur}
	// Auto-create account on first credit — mirrors what operator wallets do.
	if _, ok := w.balances[key]; !ok {
		w.balances[key] = 0
	}
	if prev, ok := w.applied[txID]; ok {
		if prev != int64(amount) {
			return fmt.Errorf("txID %q reused for different operation (was %d, now +%d)", txID, prev, amount)
		}
		return nil
	}
	w.balances[key] += amount
	w.applied[txID] = int64(amount)
	return nil
}

// Balance returns the balance for playerID in the given currency.
func (w *MockWallet) Balance(playerID, currency string) (uint64, error) {
	w.mu.Lock()
	defer w.mu.Unlock()
	if playerID == "" {
		return 0, fmt.Errorf("%w: empty playerID", ErrUnknownPlayer)
	}
	cur := NormalizeCurrency(currency)
	key := walletKey{playerID, cur}
	bal, ok := w.balances[key]
	if !ok {
		return 0, fmt.Errorf("%w: %q", ErrUnknownPlayer, playerID)
	}
	return bal, nil
}

// Snapshot returns a deep copy of the ledger: player → {currency → balance}.
func (w *MockWallet) Snapshot() map[string]map[string]uint64 {
	w.mu.Lock()
	defer w.mu.Unlock()
	out := make(map[string]map[string]uint64)
	for k, bal := range w.balances {
		if _, ok := out[k.playerID]; !ok {
			out[k.playerID] = make(map[string]uint64)
		}
		out[k.playerID][k.currency] = bal
	}
	return out
}

// Restore replaces the entire ledger with the provided snapshot. The applied
// (tx dedup) map is cleared — Restore is a startup operation where old tx
// IDs are no longer in scope.
func (w *MockWallet) Restore(snap map[string]map[string]uint64) {
	w.mu.Lock()
	defer w.mu.Unlock()
	w.balances = make(map[walletKey]uint64, len(snap))
	w.applied = make(map[string]int64)
	for playerID, currencies := range snap {
		for cur, bal := range currencies {
			w.balances[walletKey{playerID, NormalizeCurrency(cur)}] = bal
		}
	}
}

// RestoreFromLegacy loads a legacy single-currency snapshot
// (player → balance) into the wallet, assigning all balances to
// defaultCurrency. Used for backward-compat when reading old persisted state
// that predates multi-currency support.
func (w *MockWallet) RestoreFromLegacy(legacy map[string]uint64, defaultCurrency string) {
	cur := NormalizeCurrency(defaultCurrency)
	snap := make(map[string]map[string]uint64, len(legacy))
	for playerID, bal := range legacy {
		snap[playerID] = map[string]uint64{cur: bal}
	}
	w.Restore(snap)
}

// Players returns the deduplicated list of all player IDs known to the wallet
// across all currencies. Satisfies admin.PlayerLister so the admin panel can
// enumerate wallets without knowing which currencies are in use.
func (w *MockWallet) Players() []string {
	w.mu.Lock()
	defer w.mu.Unlock()
	seen := make(map[string]struct{}, len(w.balances))
	for k := range w.balances {
		seen[k.playerID] = struct{}{}
	}
	out := make([]string, 0, len(seen))
	for id := range seen {
		out = append(out, id)
	}
	return out
}

// AppliedAmount returns the signed amount the wallet recorded for `txID`,
// or 0 / false if no such tx exists. Test-only helper.
func (w *MockWallet) AppliedAmount(txID string) (int64, bool) {
	w.mu.Lock()
	defer w.mu.Unlock()
	v, ok := w.applied[txID]
	return v, ok
}
