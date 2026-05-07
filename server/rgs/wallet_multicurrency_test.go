package rgs

// wallet_multicurrency_test.go — multi-currency tests for MockWallet,
// MockRemoteWallet/HTTPWallet, Manager settlement, and the snapshot/restore
// round-trip.
//
// New test functions:
//   TestWallet_MultiCurrency_RoundTrip
//   TestBet_CurrencyValidation
//   TestSettle_PreservesCurrency
//   TestSnapshot_MultiCurrency_Roundtrip
//   TestHTTP_WalletBalance_CurrencyParam
//   TestHTTP_WalletBalance_UnsupportedCurrency
//   TestHTTP_PlaceRoundBet_Currency
//   TestHTTP_PlaceRoundBet_UnsupportedCurrency
//   TestMockWallet_MultiCurrency_Contract
//   TestHTTPWallet_MultiCurrency_Contract

import (
	"context"
	"errors"
	"fmt"
	"net/http"
	"testing"
)

// ─── 1. TestWallet_MultiCurrency_RoundTrip ──────────────────────────────────
//
// Verifies that MockWallet maintains independent balances per (player, currency)
// tuple and that Debit/Credit in one currency do not affect another.
func TestWallet_MultiCurrency_RoundTrip(t *testing.T) {
	w := NewMockWallet()
	w.SetBalanceCurrency("alice", "EUR", 10_000)
	w.SetBalanceCurrency("alice", "BTC", 500_000_000) // 5.00 BTC

	// Debit EUR.
	if err := w.Debit("alice", 1_000, "EUR", "tx_eur_debit"); err != nil {
		t.Fatalf("Debit EUR: %v", err)
	}
	// Debit BTC.
	if err := w.Debit("alice", 100_000_000, "BTC", "tx_btc_debit"); err != nil {
		t.Fatalf("Debit BTC: %v", err)
	}

	eurBal, _ := w.Balance("alice", "EUR")
	btcBal, _ := w.Balance("alice", "BTC")

	if eurBal != 9_000 {
		t.Errorf("EUR balance = %d, want 9000", eurBal)
	}
	if btcBal != 400_000_000 {
		t.Errorf("BTC balance = %d, want 400_000_000", btcBal)
	}

	// Credit USD into a new account.
	if err := w.Credit("alice", 5_000, "USD", "tx_usd_credit"); err != nil {
		t.Fatalf("Credit USD: %v", err)
	}
	usdBal, err := w.Balance("alice", "USD")
	if err != nil {
		t.Fatalf("Balance USD: %v", err)
	}
	if usdBal != 5_000 {
		t.Errorf("USD balance = %d, want 5000", usdBal)
	}

	// EUR must still be unchanged from the USD credit.
	eurBal2, _ := w.Balance("alice", "EUR")
	if eurBal2 != eurBal {
		t.Errorf("EUR balance changed after USD credit: %d → %d", eurBal, eurBal2)
	}
}

// ─── 2. TestBet_CurrencyValidation ─────────────────────────────────────────
//
// Verifies that PlaceBet and PlaceBetOnRound reject unknown currencies.
func TestBet_CurrencyValidation(t *testing.T) {
	mgr, wallet, _ := newTestManager(t, 0)
	wallet.SetBalance("alice", 10_000)

	sess, _ := mgr.OpenSession("alice")

	// Unknown currency on session bet.
	_, err := mgr.PlaceBet(sess.ID, 100, "XYZ")
	if err == nil {
		t.Fatal("PlaceBet with unknown currency: expected error, got nil")
	}
	if !errors.Is(err, ErrUnsupportedCurrency) {
		t.Fatalf("expected ErrUnsupportedCurrency, got %v", err)
	}

	// Balance must be unchanged.
	bal, _ := wallet.Balance("alice", DefaultCurrency)
	if bal != 10_000 {
		t.Errorf("balance changed after rejected bet: %d, want 10000", bal)
	}

	// Same for PlaceBetOnRound.
	spec, _ := mgr.GenerateRoundSpec()
	wallet.SetBalanceCurrency("alice", "EUR", 10_000) // refresh
	_, _, err = mgr.PlaceBetOnRound(spec.RoundID, "alice", 0, 1.0, "FAKE")
	if err == nil {
		t.Fatal("PlaceBetOnRound with unknown currency: expected error, got nil")
	}
	if !errors.Is(err, ErrUnsupportedCurrency) {
		t.Fatalf("PlaceBetOnRound: expected ErrUnsupportedCurrency, got %v", err)
	}
}

// ─── 3. TestSettle_PreservesCurrency ───────────────────────────────────────
//
// Verifies that settlement credits back in the same currency the bet was
// placed in, not in the manager's default currency.
func TestSettle_PreservesCurrency(t *testing.T) {
	// Build a manager whose DefaultCurrency is EUR but the bet is placed in USD.
	mgr, wallet, _ := newTestManagerCurrency(t, 0, "EUR", []string{"EUR", "USD", "BTC"})
	wallet.SetBalanceCurrency("alice", "USD", 10_000) // 100.00 USD

	spec, err := mgr.GenerateRoundSpec()
	if err != nil {
		t.Fatalf("GenerateRoundSpec: %v", err)
	}

	// Place bet in USD.
	_, _, err = mgr.PlaceBetOnRound(spec.RoundID, "alice", 0, 1.0, "USD")
	if err != nil {
		t.Fatalf("PlaceBetOnRound USD: %v", err)
	}

	// USD balance deducted: 10000 - 100 = 9900.
	usdBal, _ := wallet.Balance("alice", "USD")
	if usdBal != 9_900 {
		t.Errorf("USD after bet: %d, want 9900", usdBal)
	}

	// Run round (winner = marble 0 → alice wins).
	_, _, roundOutcomes, err := mgr.RunNextRound(context.Background())
	if err != nil {
		t.Fatalf("RunNextRound: %v", err)
	}
	if len(roundOutcomes) != 1 || !roundOutcomes[0].Won {
		t.Fatalf("expected alice to win, outcomes: %+v", roundOutcomes)
	}

	// Payout currency in the outcome must be USD, not EUR.
	if roundOutcomes[0].Currency != "USD" {
		t.Errorf("outcome currency = %q, want USD", roundOutcomes[0].Currency)
	}

	// Payout credited in USD: 1.0 × 9 (PodiumPayout1st) × 100 = 900 units.
	usdAfter, _ := wallet.Balance("alice", "USD")
	want := uint64(9_900) + uint64(1.0*PodiumPayout1st*100)
	if usdAfter != want {
		t.Errorf("USD after win: %d, want %d", usdAfter, want)
	}

	// EUR balance must be untouched (alice had no EUR).
	_, errEUR := wallet.Balance("alice", "EUR")
	if errEUR == nil {
		t.Error("alice should have no EUR balance; expected ErrUnknownPlayer")
	}
}

// ─── 4. TestSnapshot_MultiCurrency_Roundtrip ───────────────────────────────
//
// Verifies MockWallet.Snapshot / Restore preserves all (player, currency)
// entries, and that RestoreFromLegacy migrates old single-currency data.
func TestSnapshot_MultiCurrency_Roundtrip(t *testing.T) {
	w := NewMockWallet()
	w.SetBalanceCurrency("alice", "EUR", 1_000)
	w.SetBalanceCurrency("alice", "BTC", 500_000_000)
	w.SetBalanceCurrency("bob", "USD", 2_500)

	snap := w.Snapshot()

	// Verify snapshot contents.
	if snap["alice"]["EUR"] != 1_000 {
		t.Errorf("snap alice EUR = %d, want 1000", snap["alice"]["EUR"])
	}
	if snap["alice"]["BTC"] != 500_000_000 {
		t.Errorf("snap alice BTC = %d, want 500_000_000", snap["alice"]["BTC"])
	}
	if snap["bob"]["USD"] != 2_500 {
		t.Errorf("snap bob USD = %d, want 2500", snap["bob"]["USD"])
	}

	// Restore into a fresh wallet.
	w2 := NewMockWallet()
	w2.Restore(snap)

	bal, err := w2.Balance("alice", "EUR")
	if err != nil || bal != 1_000 {
		t.Errorf("restored alice EUR: bal=%d err=%v, want 1000 nil", bal, err)
	}
	bal, err = w2.Balance("alice", "BTC")
	if err != nil || bal != 500_000_000 {
		t.Errorf("restored alice BTC: bal=%d err=%v", bal, err)
	}
	bal, err = w2.Balance("bob", "USD")
	if err != nil || bal != 2_500 {
		t.Errorf("restored bob USD: bal=%d err=%v", bal, err)
	}

	// Legacy migration: old single-currency snapshot (player → balance).
	legacy := map[string]uint64{"carol": 8_000, "dave": 3_000}
	w3 := NewMockWallet()
	w3.RestoreFromLegacy(legacy, "EUR")
	carolBal, err := w3.Balance("carol", "EUR")
	if err != nil || carolBal != 8_000 {
		t.Errorf("legacy carol EUR: bal=%d err=%v", carolBal, err)
	}
	daveBal, _ := w3.Balance("dave", "EUR")
	if daveBal != 3_000 {
		t.Errorf("legacy dave EUR: %d, want 3000", daveBal)
	}
	// carol should NOT have a BTC balance.
	_, errBTC := w3.Balance("carol", "BTC")
	if !errors.Is(errBTC, ErrUnknownPlayer) {
		t.Errorf("legacy carol BTC: expected ErrUnknownPlayer, got %v", errBTC)
	}
}

// ─── 5. TestHTTP_WalletBalance_CurrencyParam ────────────────────────────────
//
// Verifies GET /v1/wallets/{player_id}/balance?currency=BTC returns the BTC
// balance, while the default (no param) returns EUR.
func TestHTTP_WalletBalance_CurrencyParam(t *testing.T) {
	url, wallet, _, cleanup := httpFixture(t, 0)
	defer cleanup()
	wallet.SetBalanceCurrency("mc_player", "EUR", 1_000)
	wallet.SetBalanceCurrency("mc_player", "BTC", 100_000_000)

	// Default (EUR).
	resp, err := http.Get(url + "/v1/wallets/mc_player/balance")
	if err != nil {
		t.Fatalf("GET default balance: %v", err)
	}
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("default currency status %d, want 200", resp.StatusCode)
	}
	var body struct {
		PlayerID string  `json:"player_id"`
		Currency string  `json:"currency"`
		Balance  float64 `json:"balance"`
	}
	decodeBody(t, resp, &body)
	if body.Currency != "EUR" {
		t.Errorf("default currency = %q, want EUR", body.Currency)
	}
	if body.Balance != 10.00 {
		t.Errorf("default balance = %.2f, want 10.00", body.Balance)
	}

	// Explicit BTC (8 decimals: 100_000_000 units = 1.0 BTC).
	resp, err = http.Get(url + "/v1/wallets/mc_player/balance?currency=BTC")
	if err != nil {
		t.Fatalf("GET BTC balance: %v", err)
	}
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("BTC status %d, want 200", resp.StatusCode)
	}
	decodeBody(t, resp, &body)
	if body.Currency != "BTC" {
		t.Errorf("BTC currency field = %q, want BTC", body.Currency)
	}
	if body.Balance != 1.0 {
		t.Errorf("BTC balance = %.8f, want 1.0", body.Balance)
	}
}

// ─── 6. TestHTTP_WalletBalance_UnsupportedCurrency ──────────────────────────
//
// Verifies GET /v1/wallets/{player_id}/balance?currency=XYZ returns 400.
func TestHTTP_WalletBalance_UnsupportedCurrency(t *testing.T) {
	url, wallet, _, cleanup := httpFixture(t, 0)
	defer cleanup()
	wallet.SetBalance("mc2_player", 500)

	resp, err := http.Get(url + "/v1/wallets/mc2_player/balance?currency=FAKE")
	if err != nil {
		t.Fatalf("GET: %v", err)
	}
	if resp.StatusCode != http.StatusBadRequest {
		t.Fatalf("status %d, want 400", resp.StatusCode)
	}
}

// ─── 7. TestHTTP_PlaceRoundBet_Currency ─────────────────────────────────────
//
// Verifies that a round bet placed with currency="USD" returns the currency
// in the response body and debits the USD balance.
func TestHTTP_PlaceRoundBet_Currency(t *testing.T) {
	url, wallet, _, cleanup := httpFixture(t, 0)
	defer cleanup()
	wallet.SetBalanceCurrency("usd_player", "USD", 5_000)

	startResp := postJSON(t, url+"/v1/rounds/start", nil)
	var spec RoundSpec
	decodeBody(t, startResp, &spec)

	resp := postJSON(t, fmt.Sprintf("%s/v1/rounds/%d/bets", url, spec.RoundID),
		placeRoundBetRequest{PlayerID: "usd_player", MarbleIdx: 0, Amount: 1.0, Currency: "USD"})
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("place round bet USD: status %d, want 200", resp.StatusCode)
	}
	var betResp placeRoundBetResponse
	decodeBody(t, resp, &betResp)
	if betResp.Currency != "USD" {
		t.Errorf("response currency = %q, want USD", betResp.Currency)
	}
	// 1.0 USD × 100 units = 100 debited; 5000 - 100 = 4900.
	usdBal, _ := wallet.Balance("usd_player", "USD")
	if usdBal != 4_900 {
		t.Errorf("USD balance after bet: %d, want 4900", usdBal)
	}
}

// ─── 8. TestHTTP_PlaceRoundBet_UnsupportedCurrency ──────────────────────────
//
// Verifies that POST /v1/rounds/{id}/bets with an unsupported currency returns
// 400 and leaves the wallet unchanged.
func TestHTTP_PlaceRoundBet_UnsupportedCurrency(t *testing.T) {
	url, wallet, _, cleanup := httpFixture(t, 0)
	defer cleanup()
	wallet.SetBalance("curr_player", 5_000)

	startResp := postJSON(t, url+"/v1/rounds/start", nil)
	var spec RoundSpec
	decodeBody(t, startResp, &spec)

	resp := postJSON(t, fmt.Sprintf("%s/v1/rounds/%d/bets", url, spec.RoundID),
		placeRoundBetRequest{PlayerID: "curr_player", MarbleIdx: 0, Amount: 1.0, Currency: "FAKE"})
	if resp.StatusCode != http.StatusBadRequest {
		t.Fatalf("status %d, want 400", resp.StatusCode)
	}
	// Balance must be unchanged.
	bal, _ := wallet.Balance("curr_player", DefaultCurrency)
	if bal != 5_000 {
		t.Errorf("balance changed after rejected bet: %d, want 5000", bal)
	}
}

// ─── 9. TestMockWallet_MultiCurrency_IsolationSmoke ────────────────────────
//
// Quick smoke: verifies that balance in one currency does not bleed into
// another. Does not reuse runWalletContractSuite because that suite seeds
// and checks in DefaultCurrency (EUR) — this test isolates the multi-key
// semantics independently.
func TestMockWallet_MultiCurrency_IsolationSmoke(t *testing.T) {
	w := NewMockWallet()
	w.SetBalanceCurrency("p", "EUR", 500)
	w.SetBalanceCurrency("p", "USD", 300)

	// Debit EUR only.
	if err := w.Debit("p", 100, "EUR", "tx_smoke_eur"); err != nil {
		t.Fatalf("Debit EUR: %v", err)
	}

	eurBal, _ := w.Balance("p", "EUR")
	usdBal, _ := w.Balance("p", "USD")

	if eurBal != 400 {
		t.Errorf("EUR after debit: %d, want 400", eurBal)
	}
	if usdBal != 300 {
		t.Errorf("USD unaffected: %d, want 300", usdBal)
	}

	// Credit USD only.
	if err := w.Credit("p", 50, "USD", "tx_smoke_usd"); err != nil {
		t.Fatalf("Credit USD: %v", err)
	}
	usdBal2, _ := w.Balance("p", "USD")
	eurBal2, _ := w.Balance("p", "EUR")
	if usdBal2 != 350 {
		t.Errorf("USD after credit: %d, want 350", usdBal2)
	}
	if eurBal2 != eurBal {
		t.Errorf("EUR changed after USD credit: %d → %d", eurBal, eurBal2)
	}
}

// ─── 10. TestHTTPWallet_MultiCurrency_Contract ──────────────────────────────
//
// Runs a focused multi-currency debit/credit/balance round-trip over the
// HTTPWallet → MockRemoteWallet path, verifying the currency field is
// forwarded correctly on the wire.
func TestHTTPWallet_MultiCurrency_Contract(t *testing.T) {
	tests := []struct {
		name     string
		currency string
		seedAmt  uint64
		debit    uint64
		credit   uint64
		wantBal  uint64
	}{
		{"EUR fiat", "EUR", 1_000, 200, 50, 850},
		{"USD fiat", "USD", 2_000, 500, 100, 1_600},
		{"BTC crypto", "BTC", 100_000_000, 10_000_000, 5_000_000, 95_000_000},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			remote := NewMockRemoteWallet(nil)
			t.Cleanup(remote.Close)
			remote.SetBalanceCurrency("mc_user", tc.currency, tc.seedAmt)

			w := NewHTTPWallet(HTTPWalletConfig{
				BaseURL:         remote.URL(),
				MaxRetries:      0,
				IdempotencyKeys: true,
			})

			if err := w.Debit("mc_user", tc.debit, tc.currency, "tx_mc_debit"); err != nil {
				t.Fatalf("Debit: %v", err)
			}
			if err := w.Credit("mc_user", tc.credit, tc.currency, "tx_mc_credit"); err != nil {
				t.Fatalf("Credit: %v", err)
			}
			bal, err := w.Balance("mc_user", tc.currency)
			if err != nil {
				t.Fatalf("Balance: %v", err)
			}
			if bal != tc.wantBal {
				t.Errorf("balance = %d, want %d", bal, tc.wantBal)
			}
		})
	}
}

// ─── helpers ─────────────────────────────────────────────────────────────────

// newTestManagerCurrency mirrors newTestManager but lets the caller set
// DefaultCurrency and SupportedCurrencies, enabling multi-currency settle tests.
func newTestManagerCurrency(t *testing.T, winnerIndex int, defaultCur string, supported []string) (*Manager, *MockWallet, string) {
	t.Helper()
	mgr, wallet, dir := newTestManager(t, winnerIndex)
	// Patch the config fields that newTestManager doesn't expose.
	mgr.cfg.DefaultCurrency = NormalizeCurrency(defaultCur)
	if len(supported) > 0 {
		mgr.cfg.SupportedCurrencies = supported
	}
	return mgr, wallet, dir
}
