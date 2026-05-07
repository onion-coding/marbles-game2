package rgs

// wallet_http_test.go — contract test suite for the Wallet interface.
//
// runWalletContractSuite is a helper (not a test function itself) that any
// Wallet implementation must pass to be drop-in compatible with
// rgs.Manager. It defines 12 behavioural invariants; each invariant is a
// sub-test so failures are reported independently.
//
// The suite is run twice:
//  1. Against MockWallet (in-memory reference — must always pass).
//  2. Against HTTPWallet talking to MockRemoteWallet over a local
//     httptest.Server (exercises real HTTP + serialisation).
//
// Adding a new operator wallet implementation? Call:
//
//	runWalletContractSuite(t, func() (Wallet, func(string,uint64)) { ... })
//
// and all 12 cases will be validated automatically.

import (
	"errors"
	"fmt"
	"net/http"
	"net/http/httptest"
	"sync"
	"testing"
)

// ─── contract helper ──────────────────────────────────────────────────────────

// runWalletContractSuite runs the full conformance suite against any Wallet
// implementation. makeWallet is a factory called once per sub-test; it
// returns both the Wallet under test and a seed function that sets a
// player's balance directly (bypassing Debit/Credit, for test setup).
//
// Call this from a real Test* function:
//
//	func TestMyWallet_Contract(t *testing.T) {
//	    runWalletContractSuite(t, func() (Wallet, func(string, uint64)) { ... })
//	}
//
// The 12 contracts:
//
//  1. Balance of unknown player returns ErrUnknownPlayer.
//  2. Debit reduces balance by exactly amount.
//  3. Credit increases balance by exactly amount.
//  4. Debit with insufficient funds returns ErrInsufficientFunds; balance unchanged.
//  5. Credit on unknown player creates the account (balance = amount).
//  6. Idempotent Debit: same tx_id is a no-op; balance not double-charged.
//  7. Idempotent Credit: same tx_id is a no-op; balance not double-credited.
//  8. Concurrent Debit calls are safe (no lost-update, no overdraft).
//  9. Empty playerID returns an error from Debit, Credit, Balance.
// 10. Zero amount returns an error from Debit and Credit.
// 11. Empty txID returns an error from Debit and Credit.
// 12. tx_id used in a Debit cannot be replayed as a Credit without error.
func runWalletContractSuite(t *testing.T, makeWallet func() (Wallet, func(string, uint64))) {
	t.Helper()

	// ── 1. Balance unknown player ─────────────────────────────────────────
	t.Run("balance_unknown_player_errors", func(t *testing.T) {
		w, _ := makeWallet()
		_, err := w.Balance("nobody_xq7")
		if err == nil {
			t.Fatal("expected error for unknown player, got nil")
		}
		if !errors.Is(err, ErrUnknownPlayer) {
			t.Fatalf("expected ErrUnknownPlayer, got %v", err)
		}
	})

	// ── 2. Debit reduces balance ──────────────────────────────────────────
	t.Run("debit_reduces_balance", func(t *testing.T) {
		w, seed := makeWallet()
		seed("c2_player", 1000)
		if err := w.Debit("c2_player", 300, "tx_c2_debit"); err != nil {
			t.Fatalf("Debit: %v", err)
		}
		bal, err := w.Balance("c2_player")
		if err != nil {
			t.Fatalf("Balance: %v", err)
		}
		if bal != 700 {
			t.Fatalf("balance after debit: got %d, want 700", bal)
		}
	})

	// ── 3. Credit increases balance ───────────────────────────────────────
	t.Run("credit_increases_balance", func(t *testing.T) {
		w, seed := makeWallet()
		seed("c3_player", 500)
		if err := w.Credit("c3_player", 200, "tx_c3_credit"); err != nil {
			t.Fatalf("Credit: %v", err)
		}
		bal, err := w.Balance("c3_player")
		if err != nil {
			t.Fatalf("Balance: %v", err)
		}
		if bal != 700 {
			t.Fatalf("balance after credit: got %d, want 700", bal)
		}
	})

	// ── 4. Debit insufficient funds ───────────────────────────────────────
	t.Run("debit_insufficient_funds", func(t *testing.T) {
		w, seed := makeWallet()
		seed("c4_player", 50)
		err := w.Debit("c4_player", 100, "tx_c4_over")
		if err == nil {
			t.Fatal("expected ErrInsufficientFunds, got nil")
		}
		if !errors.Is(err, ErrInsufficientFunds) {
			t.Fatalf("expected ErrInsufficientFunds, got %v", err)
		}
		bal, _ := w.Balance("c4_player")
		if bal != 50 {
			t.Fatalf("balance changed after rejected debit: got %d, want 50", bal)
		}
	})

	// ── 5. Credit unknown player creates account ──────────────────────────
	t.Run("credit_unknown_creates_account", func(t *testing.T) {
		w, _ := makeWallet()
		if err := w.Credit("c5_new_player", 999, "tx_c5_create"); err != nil {
			t.Fatalf("Credit on unknown player: %v", err)
		}
		bal, err := w.Balance("c5_new_player")
		if err != nil {
			t.Fatalf("Balance after credit-create: %v", err)
		}
		if bal != 999 {
			t.Fatalf("balance after credit-create: got %d, want 999", bal)
		}
	})

	// ── 6. Idempotent Debit ───────────────────────────────────────────────
	t.Run("idempotent_debit", func(t *testing.T) {
		w, seed := makeWallet()
		seed("c6_player", 1000)
		if err := w.Debit("c6_player", 400, "tx_c6_idem"); err != nil {
			t.Fatalf("first Debit: %v", err)
		}
		if err := w.Debit("c6_player", 400, "tx_c6_idem"); err != nil {
			t.Fatalf("idempotent Debit replay: %v", err)
		}
		bal, _ := w.Balance("c6_player")
		if bal != 600 {
			t.Fatalf("balance after idempotent replay: got %d, want 600", bal)
		}
	})

	// ── 7. Idempotent Credit ──────────────────────────────────────────────
	t.Run("idempotent_credit", func(t *testing.T) {
		w, seed := makeWallet()
		seed("c7_player", 100)
		if err := w.Credit("c7_player", 250, "tx_c7_idem"); err != nil {
			t.Fatalf("first Credit: %v", err)
		}
		if err := w.Credit("c7_player", 250, "tx_c7_idem"); err != nil {
			t.Fatalf("idempotent Credit replay: %v", err)
		}
		bal, _ := w.Balance("c7_player")
		if bal != 350 {
			t.Fatalf("balance after idempotent replay: got %d, want 350", bal)
		}
	})

	// ── 8. Concurrent Debit safety ────────────────────────────────────────
	t.Run("concurrent_debit_safe", func(t *testing.T) {
		w, seed := makeWallet()
		const goroutines = 20
		const debitAmount = uint64(10)
		seed("c8_player", uint64(goroutines)*debitAmount)

		var wg sync.WaitGroup
		errs := make([]error, goroutines)
		for i := 0; i < goroutines; i++ {
			wg.Add(1)
			go func(idx int) {
				defer wg.Done()
				errs[idx] = w.Debit("c8_player", debitAmount, fmt.Sprintf("tx_c8_%02d", idx))
			}(i)
		}
		wg.Wait()

		var succeeded int
		for _, e := range errs {
			if e == nil {
				succeeded++
			}
		}
		if succeeded != goroutines {
			t.Fatalf("concurrent debit: %d/%d succeeded (want all)", succeeded, goroutines)
		}
		bal, err := w.Balance("c8_player")
		if err != nil {
			t.Fatalf("Balance after concurrent debit: %v", err)
		}
		if bal != 0 {
			t.Fatalf("balance after draining concurrent debits: got %d, want 0", bal)
		}
	})

	// ── 9. Empty playerID returns error ──────────────────────────────────
	t.Run("empty_player_id_errors", func(t *testing.T) {
		w, _ := makeWallet()
		if err := w.Debit("", 100, "tx_c9_debit"); err == nil {
			t.Fatal("Debit with empty playerID: expected error, got nil")
		}
		if err := w.Credit("", 100, "tx_c9_credit"); err == nil {
			t.Fatal("Credit with empty playerID: expected error, got nil")
		}
		if _, err := w.Balance(""); err == nil {
			t.Fatal("Balance with empty playerID: expected error, got nil")
		}
	})

	// ── 10. Zero amount returns error ─────────────────────────────────────
	t.Run("zero_amount_errors", func(t *testing.T) {
		w, seed := makeWallet()
		seed("c10_player", 500)
		if err := w.Debit("c10_player", 0, "tx_c10_debit"); err == nil {
			t.Fatal("Debit with amount=0: expected error, got nil")
		}
		if err := w.Credit("c10_player", 0, "tx_c10_credit"); err == nil {
			t.Fatal("Credit with amount=0: expected error, got nil")
		}
	})

	// ── 11. Empty txID returns error ──────────────────────────────────────
	t.Run("empty_txid_errors", func(t *testing.T) {
		w, seed := makeWallet()
		seed("c11_player", 500)
		if err := w.Debit("c11_player", 100, ""); err == nil {
			t.Fatal("Debit with empty txID: expected error, got nil")
		}
		if err := w.Credit("c11_player", 100, ""); err == nil {
			t.Fatal("Credit with empty txID: expected error, got nil")
		}
	})

	// ── 12. tx_id cross-operation collision ───────────────────────────────
	t.Run("txid_cross_operation_collision_errors", func(t *testing.T) {
		w, seed := makeWallet()
		seed("c12_player", 1000)
		if err := w.Debit("c12_player", 100, "tx_c12_shared"); err != nil {
			t.Fatalf("initial Debit: %v", err)
		}
		// Replaying the same tx_id as Credit must fail (ledger sees a signed
		// -100 entry but caller is requesting +100 — mismatch).
		err := w.Credit("c12_player", 100, "tx_c12_shared")
		if err == nil {
			t.Fatal("Credit with tx_id previously used for Debit: expected error, got nil")
		}
		// Balance must reflect only the initial debit.
		bal, _ := w.Balance("c12_player")
		if bal != 900 {
			t.Fatalf("balance after cross-op collision: got %d, want 900", bal)
		}
	})
}

// ─── MockWallet contract run ──────────────────────────────────────────────────

// TestMockWallet_Contract runs the full 12-case contract suite against the
// in-memory MockWallet. This is the reference run and must always pass.
func TestMockWallet_Contract(t *testing.T) {
	runWalletContractSuite(t, func() (Wallet, func(string, uint64)) {
		w := NewMockWallet()
		return w, func(playerID string, amount uint64) {
			w.SetBalance(playerID, amount)
		}
	})
}

// ─── HTTPWallet contract run ──────────────────────────────────────────────────

// TestHTTPWallet_Contract runs the same 12-case suite against an HTTPWallet
// talking to a MockRemoteWallet over a local httptest.Server. Validates
// serialisation, HTTP error mapping, and idempotency handling end-to-end.
func TestHTTPWallet_Contract(t *testing.T) {
	runWalletContractSuite(t, func() (Wallet, func(string, uint64)) {
		remote := NewMockRemoteWallet(nil)
		t.Cleanup(remote.Close)

		w := NewHTTPWallet(HTTPWalletConfig{
			BaseURL:         remote.URL(),
			MaxRetries:      0,
			IdempotencyKeys: true,
		})
		return w, func(playerID string, amount uint64) {
			remote.SetBalance(playerID, amount)
		}
	})
}

// ─── HTTPWallet-specific tests ────────────────────────────────────────────────

// TestHTTPWallet_HMACSigningSetsHeaders verifies that when HMACSecret is
// configured the HTTPWallet sets X-Timestamp and X-Signature headers, and
// that the signature is a valid 64-char hex string (SHA-256 output).
func TestHTTPWallet_HMACSigningSetsHeaders(t *testing.T) {
	var seenTS, seenSig string

	remote := NewMockRemoteWallet(map[string]uint64{"hmac_player": 500})
	t.Cleanup(remote.Close)

	// Wrap the remote handler to capture headers before forwarding.
	captureHandler := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		seenTS = r.Header.Get("X-Timestamp")
		seenSig = r.Header.Get("X-Signature")
		remote.Handler().ServeHTTP(w, r)
	})
	captureSrv := httptest.NewServer(captureHandler)
	t.Cleanup(captureSrv.Close)

	w := NewHTTPWallet(HTTPWalletConfig{
		BaseURL:    captureSrv.URL,
		HMACSecret: []byte("test-hmac-secret"),
		MaxRetries: 0,
	})

	if _, err := w.Balance("hmac_player"); err != nil {
		t.Fatalf("Balance: %v", err)
	}
	if seenTS == "" {
		t.Fatal("X-Timestamp header not set by HTTPWallet")
	}
	if seenSig == "" {
		t.Fatal("X-Signature header not set by HTTPWallet")
	}
	if len(seenSig) != 64 {
		t.Fatalf("X-Signature length %d, want 64 (hex SHA-256)", len(seenSig))
	}
}

// TestHTTPWallet_IdempotencyKeyHeader verifies the Idempotency-Key header is
// set on debit when IdempotencyKeys is enabled.
func TestHTTPWallet_IdempotencyKeyHeader(t *testing.T) {
	var capturedKey string

	remote := NewMockRemoteWallet(map[string]uint64{"idem_player": 1000})
	t.Cleanup(remote.Close)

	captureHandler := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/wallet/debit" {
			capturedKey = r.Header.Get("Idempotency-Key")
		}
		remote.Handler().ServeHTTP(w, r)
	})
	captureSrv := httptest.NewServer(captureHandler)
	t.Cleanup(captureSrv.Close)

	w := NewHTTPWallet(HTTPWalletConfig{
		BaseURL:         captureSrv.URL,
		MaxRetries:      0,
		IdempotencyKeys: true,
	})

	if err := w.Debit("idem_player", 100, "tx_idem_key"); err != nil {
		t.Fatalf("Debit: %v", err)
	}
	if capturedKey != "tx_idem_key" {
		t.Fatalf("Idempotency-Key: got %q, want %q", capturedKey, "tx_idem_key")
	}
}

// TestHTTPWallet_RetryOn500 verifies that HTTPWallet retries on 5xx and
// succeeds once the fault clears.
func TestHTTPWallet_RetryOn500(t *testing.T) {
	remote := NewMockRemoteWallet(map[string]uint64{"retry_player": 500})
	t.Cleanup(remote.Close)

	attempts := 0
	faultyHandler := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		attempts++
		if attempts <= 2 {
			remoteWriteError(w, http.StatusInternalServerError, "transient error")
			return
		}
		remote.Handler().ServeHTTP(w, r)
	})
	faultySrv := httptest.NewServer(faultyHandler)
	t.Cleanup(faultySrv.Close)

	w := NewHTTPWallet(HTTPWalletConfig{
		BaseURL:    faultySrv.URL,
		MaxRetries: 3,
	})

	bal, err := w.Balance("retry_player")
	if err != nil {
		t.Fatalf("Balance after retry: %v", err)
	}
	if bal != 500 {
		t.Fatalf("balance: got %d, want 500", bal)
	}
	if attempts != 3 {
		t.Fatalf("attempts: got %d, want 3", attempts)
	}
}

// TestHTTPWallet_ExhaustedRetriesError verifies that once all retries are
// exhausted an error is surfaced.
func TestHTTPWallet_ExhaustedRetriesError(t *testing.T) {
	alwaysFail := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		remoteWriteError(w, http.StatusInternalServerError, "permanent error")
	})
	failSrv := httptest.NewServer(alwaysFail)
	t.Cleanup(failSrv.Close)

	w := NewHTTPWallet(HTTPWalletConfig{
		BaseURL:    failSrv.URL,
		MaxRetries: 1,
	})

	_, err := w.Balance("any_player")
	if err == nil {
		t.Fatal("expected error after exhausted retries, got nil")
	}
}

// TestMockRemoteWallet_FaultInjection verifies FaultMode semantics via the
// HTTPWallet client.
func TestMockRemoteWallet_FaultInjection(t *testing.T) {
	remote := NewMockRemoteWallet(map[string]uint64{"fault_player": 1000})
	t.Cleanup(remote.Close)

	w := NewHTTPWallet(HTTPWalletConfig{
		BaseURL:    remote.URL(),
		MaxRetries: 0,
	})

	// Normal first.
	if err := w.Debit("fault_player", 100, "tx_fault_pre"); err != nil {
		t.Fatalf("pre-fault Debit: %v", err)
	}

	// 500 fault.
	remote.SetFault(RemoteFaultServer500)
	if _, err := w.Balance("fault_player"); err == nil {
		t.Fatal("expected error during 500 fault, got nil")
	}

	// Insufficient-funds fault.
	remote.SetFault(RemoteFaultInsufficientFunds)
	err := w.Debit("fault_player", 1, "tx_fault_insuf")
	if !errors.Is(err, ErrInsufficientFunds) {
		t.Fatalf("expected ErrInsufficientFunds from fault, got %v", err)
	}

	// Clear fault — normal operation resumes.
	remote.SetFault(RemoteFaultNone)
	if _, err := w.Balance("fault_player"); err != nil {
		t.Fatalf("post-fault Balance: %v", err)
	}
}

// TestHTTPWallet_NoIdempotencyKeyWhenDisabled verifies the header is absent
// when IdempotencyKeys is false (the default).
func TestHTTPWallet_NoIdempotencyKeyWhenDisabled(t *testing.T) {
	var capturedKey string
	remote := NewMockRemoteWallet(map[string]uint64{"nokey_player": 1000})
	t.Cleanup(remote.Close)

	captureHandler := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		capturedKey = r.Header.Get("Idempotency-Key")
		remote.Handler().ServeHTTP(w, r)
	})
	captureSrv := httptest.NewServer(captureHandler)
	t.Cleanup(captureSrv.Close)

	w := NewHTTPWallet(HTTPWalletConfig{
		BaseURL:         captureSrv.URL,
		IdempotencyKeys: false,
	})

	if err := w.Debit("nokey_player", 50, "tx_nokey"); err != nil {
		t.Fatalf("Debit: %v", err)
	}
	if capturedKey != "" {
		t.Fatalf("Idempotency-Key should be absent, got %q", capturedKey)
	}
}
