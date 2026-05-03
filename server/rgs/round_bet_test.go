package rgs

import (
	"context"
	"errors"
	"fmt"
	"net/http"
	"testing"
)

// ─── Manager-level tests ─────────────────────────────────────────────────────

// TestBet_PlaceSuccess verifies the happy path: a player places a bet on a
// pre-minted round, wallet is debited, and the returned bet has correct fields.
func TestBet_PlaceSuccess(t *testing.T) {
	mgr, wallet, _ := newTestManager(t, 3)
	wallet.SetBalance("alice", 5000) // 50.00 in 2-decimal units

	spec, err := mgr.GenerateRoundSpec()
	if err != nil {
		t.Fatalf("GenerateRoundSpec: %v", err)
	}

	bet, balAfter, err := mgr.PlaceBetOnRound(spec.RoundID, "alice", 3, 10.0)
	if err != nil {
		t.Fatalf("PlaceBetOnRound: %v", err)
	}
	if bet.BetID == "" {
		t.Fatal("bet_id is empty")
	}
	if bet.RoundID != spec.RoundID {
		t.Fatalf("bet.RoundID %d, want %d", bet.RoundID, spec.RoundID)
	}
	if bet.MarbleIdx != 3 {
		t.Fatalf("bet.MarbleIdx %d, want 3", bet.MarbleIdx)
	}
	if bet.Amount != 10.0 {
		t.Fatalf("bet.Amount %.2f, want 10.00", bet.Amount)
	}
	// wallet: 5000 units - 1000 units (10.00 × 100) = 4000 units = 40.00
	wantBal := 40.0
	if balAfter != wantBal {
		t.Fatalf("balAfter %.2f, want %.2f", balAfter, wantBal)
	}
	rawBal, _ := wallet.Balance("alice")
	if rawBal != 4000 {
		t.Fatalf("wallet balance %d, want 4000", rawBal)
	}
}

// TestBet_InsufficientFunds verifies ErrInsufficientFunds is surfaced and
// the wallet is left unchanged.
func TestBet_InsufficientFunds(t *testing.T) {
	mgr, wallet, _ := newTestManager(t, 0)
	wallet.SetBalance("bob", 500) // 5.00

	spec, _ := mgr.GenerateRoundSpec()

	_, _, err := mgr.PlaceBetOnRound(spec.RoundID, "bob", 0, 10.0)
	if err == nil {
		t.Fatal("expected error, got nil")
	}
	if !errors.Is(err, ErrInsufficientFunds) {
		t.Fatalf("expected ErrInsufficientFunds, got %v", err)
	}
	bal, _ := wallet.Balance("bob")
	if bal != 500 {
		t.Fatalf("balance changed to %d after rejected bet, want 500", bal)
	}
}

// TestBet_InvalidMarbleIdx verifies 0-19 is the valid range (MaxMarbles=20).
func TestBet_InvalidMarbleIdx(t *testing.T) {
	mgr, wallet, _ := newTestManager(t, 0)
	wallet.SetBalance("carol", 10000)

	spec, _ := mgr.GenerateRoundSpec()

	for _, idx := range []int{-1, 20, 99} {
		_, _, err := mgr.PlaceBetOnRound(spec.RoundID, "carol", idx, 5.0)
		if err == nil {
			t.Fatalf("marble_idx %d: expected error, got nil", idx)
		}
		if !errors.Is(err, ErrInvalidMarbleIdx) {
			t.Fatalf("marble_idx %d: expected ErrInvalidMarbleIdx, got %v", idx, err)
		}
	}
}

// TestBet_AmountZeroOrNegative verifies ErrInvalidBetAmount for bad amounts.
func TestBet_AmountZeroOrNegative(t *testing.T) {
	mgr, wallet, _ := newTestManager(t, 0)
	wallet.SetBalance("dave", 10000)

	spec, _ := mgr.GenerateRoundSpec()

	for _, amt := range []float64{0, -1.0, -100.0} {
		_, _, err := mgr.PlaceBetOnRound(spec.RoundID, "dave", 0, amt)
		if err == nil {
			t.Fatalf("amount %.2f: expected error, got nil", amt)
		}
		if !errors.Is(err, ErrInvalidBetAmount) {
			t.Fatalf("amount %.2f: expected ErrInvalidBetAmount, got %v", amt, err)
		}
	}
}

// TestBet_UnknownRoundID verifies ErrUnknownRound for a round_id that was
// never minted.
func TestBet_UnknownRoundID(t *testing.T) {
	mgr, wallet, _ := newTestManager(t, 0)
	wallet.SetBalance("eve", 10000)

	_, _, err := mgr.PlaceBetOnRound(999999999, "eve", 0, 5.0)
	if err == nil {
		t.Fatal("expected error, got nil")
	}
	if !errors.Is(err, ErrUnknownRound) {
		t.Fatalf("expected ErrUnknownRound, got %v", err)
	}
}

// TestBet_RoundAlreadyRun verifies ErrRoundAlreadyRun once RunNextRound has
// consumed the pendingRound.
func TestBet_RoundAlreadyRun(t *testing.T) {
	mgr, wallet, _ := newTestManager(t, 0)
	wallet.SetBalance("frank", 10000)

	spec, _ := mgr.GenerateRoundSpec()
	// Place one bet so the round isn't empty.
	_, _, err := mgr.PlaceBetOnRound(spec.RoundID, "frank", 0, 5.0)
	if err != nil {
		t.Fatalf("first PlaceBetOnRound: %v", err)
	}

	// Run the round — this pops the pendingRound.
	if _, _, _, err := mgr.RunNextRound(context.Background()); err != nil {
		t.Fatalf("RunNextRound: %v", err)
	}

	// Any subsequent bet on the same round_id should be rejected.
	_, _, err = mgr.PlaceBetOnRound(spec.RoundID, "frank", 1, 5.0)
	if err == nil {
		t.Fatal("expected error after round ran, got nil")
	}
	if !errors.Is(err, ErrRoundAlreadyRun) {
		t.Fatalf("expected ErrRoundAlreadyRun, got %v", err)
	}
}

// TestBet_PayoutOnlyWinner places 3 bets on different marbles, runs the round
// (winner = marble 7), and verifies ONLY the marble-7 bettor gets credited.
func TestBet_PayoutOnlyWinner(t *testing.T) {
	const winner = 7
	mgr, wallet, _ := newTestManager(t, winner)
	wallet.SetBalance("p1", 10000) // picks marble 2
	wallet.SetBalance("p2", 10000) // picks marble 7 (winner)
	wallet.SetBalance("p3", 10000) // picks marble 15

	spec, _ := mgr.GenerateRoundSpec()

	if _, _, err := mgr.PlaceBetOnRound(spec.RoundID, "p1", 2, 10.0); err != nil {
		t.Fatalf("PlaceBetOnRound p1: %v", err)
	}
	if _, _, err := mgr.PlaceBetOnRound(spec.RoundID, "p2", winner, 10.0); err != nil {
		t.Fatalf("PlaceBetOnRound p2: %v", err)
	}
	if _, _, err := mgr.PlaceBetOnRound(spec.RoundID, "p3", 15, 10.0); err != nil {
		t.Fatalf("PlaceBetOnRound p3: %v", err)
	}

	// Wallets debited: each down 1000 units (10.00).
	for _, pid := range []string{"p1", "p2", "p3"} {
		bal, _ := wallet.Balance(pid)
		if bal != 9000 {
			t.Fatalf("%s balance after bet: %d, want 9000", pid, bal)
		}
	}

	if _, _, _, err := mgr.RunNextRound(context.Background()); err != nil {
		t.Fatalf("RunNextRound: %v", err)
	}

	// p1 and p3 lost: balance stays at 9000.
	for _, pid := range []string{"p1", "p3"} {
		bal, _ := wallet.Balance(pid)
		if bal != 9000 {
			t.Fatalf("%s (loser) balance %d, want 9000", pid, bal)
		}
	}

	// p2 won 1° place. Under the M18 v2 payout model (no pickup, no
	// jackpot — fakeSim doesn't populate them), the payoff for a podium
	// 1° finish is 9× the stake. So p2 ends up with 9000 (post-debit
	// balance) + 10.00 × 9× × 100 = 9000 + 9000 = 18000 units.
	// PayoutMultiplier is now an alias for PodiumPayout1st (= 9.0), so
	// the wantPayout formula stays valid post-M18.
	p2bal, _ := wallet.Balance("p2")
	want := uint64(9000 + int(10.0*PayoutMultiplier*100))
	if p2bal != want {
		t.Fatalf("p2 (winner) balance %d, want %d", p2bal, want)
	}
}

// TestBet_BetsForRound verifies the query helper filters by player_id correctly.
func TestBet_BetsForRound(t *testing.T) {
	mgr, wallet, _ := newTestManager(t, 0)
	wallet.SetBalance("alice", 10000)
	wallet.SetBalance("bob", 10000)

	spec, _ := mgr.GenerateRoundSpec()
	mgr.PlaceBetOnRound(spec.RoundID, "alice", 0, 5.0)
	mgr.PlaceBetOnRound(spec.RoundID, "alice", 1, 3.0)
	mgr.PlaceBetOnRound(spec.RoundID, "bob", 2, 7.0)

	// All bets.
	all, err := mgr.BetsForRound(spec.RoundID, "")
	if err != nil {
		t.Fatalf("BetsForRound all: %v", err)
	}
	if len(all) != 3 {
		t.Fatalf("all bets count %d, want 3", len(all))
	}

	// Filtered to alice.
	aliceBets, err := mgr.BetsForRound(spec.RoundID, "alice")
	if err != nil {
		t.Fatalf("BetsForRound alice: %v", err)
	}
	if len(aliceBets) != 2 {
		t.Fatalf("alice bets count %d, want 2", len(aliceBets))
	}

	// Unknown round.
	_, err = mgr.BetsForRound(999, "")
	if !errors.Is(err, ErrUnknownRound) {
		t.Fatalf("expected ErrUnknownRound for unknown round, got %v", err)
	}
}

// ─── HTTP-layer tests ─────────────────────────────────────────────────────────

// TestHTTP_PlaceRoundBetSuccess exercises the full HTTP path for a successful bet.
func TestHTTP_PlaceRoundBetSuccess(t *testing.T) {
	url, wallet, _, cleanup := httpFixture(t, 0)
	defer cleanup()
	wallet.SetBalance("alice", 5000)

	// Mint a round.
	startResp := postJSON(t, url+"/v1/rounds/start", nil)
	var spec RoundSpec
	decodeBody(t, startResp, &spec)

	// Place bet.
	resp := postJSON(t, fmt.Sprintf("%s/v1/rounds/%d/bets", url, spec.RoundID),
		placeRoundBetRequest{PlayerID: "alice", MarbleIdx: 0, Amount: 10.0})
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("place round bet: status %d, want 200", resp.StatusCode)
	}
	var betResp placeRoundBetResponse
	decodeBody(t, resp, &betResp)

	if betResp.BetID == "" {
		t.Fatal("bet_id empty")
	}
	if betResp.RoundID != spec.RoundID {
		t.Fatalf("round_id %d, want %d", betResp.RoundID, spec.RoundID)
	}
	if betResp.MarbleIdx != 0 {
		t.Fatalf("marble_idx %d, want 0", betResp.MarbleIdx)
	}
	if betResp.Amount != 10.0 {
		t.Fatalf("amount %.2f, want 10.00", betResp.Amount)
	}
	if betResp.BalanceAfter != 40.0 {
		t.Fatalf("balance_after %.2f, want 40.00", betResp.BalanceAfter)
	}
	wantPayout := 10.0 * PayoutMultiplier
	if betResp.ExpectedPayoutIfWin != wantPayout {
		t.Fatalf("expected_payout_if_win %.2f, want %.2f", betResp.ExpectedPayoutIfWin, wantPayout)
	}
}

// TestHTTP_PlaceRoundBetInsufficientFunds verifies 402 from the HTTP layer.
func TestHTTP_PlaceRoundBetInsufficientFunds(t *testing.T) {
	url, wallet, _, cleanup := httpFixture(t, 0)
	defer cleanup()
	wallet.SetBalance("bob", 200) // 2.00

	startResp := postJSON(t, url+"/v1/rounds/start", nil)
	var spec RoundSpec
	decodeBody(t, startResp, &spec)

	resp := postJSON(t, fmt.Sprintf("%s/v1/rounds/%d/bets", url, spec.RoundID),
		placeRoundBetRequest{PlayerID: "bob", MarbleIdx: 5, Amount: 10.0})
	if resp.StatusCode != http.StatusPaymentRequired {
		t.Fatalf("status %d, want 402", resp.StatusCode)
	}
}

// TestHTTP_PlaceRoundBetInvalidMarble verifies 400 for marble_idx out of range.
func TestHTTP_PlaceRoundBetInvalidMarble(t *testing.T) {
	url, wallet, _, cleanup := httpFixture(t, 0)
	defer cleanup()
	wallet.SetBalance("carol", 10000)

	startResp := postJSON(t, url+"/v1/rounds/start", nil)
	var spec RoundSpec
	decodeBody(t, startResp, &spec)

	resp := postJSON(t, fmt.Sprintf("%s/v1/rounds/%d/bets", url, spec.RoundID),
		placeRoundBetRequest{PlayerID: "carol", MarbleIdx: 25, Amount: 5.0})
	if resp.StatusCode != http.StatusBadRequest {
		t.Fatalf("status %d, want 400", resp.StatusCode)
	}
}

// TestHTTP_PlaceRoundBetRoundNotFound verifies 404 for an unknown round_id.
func TestHTTP_PlaceRoundBetRoundNotFound(t *testing.T) {
	url, wallet, _, cleanup := httpFixture(t, 0)
	defer cleanup()
	wallet.SetBalance("dave", 10000)

	resp := postJSON(t, fmt.Sprintf("%s/v1/rounds/%d/bets", url, uint64(12345)),
		placeRoundBetRequest{PlayerID: "dave", MarbleIdx: 0, Amount: 5.0})
	if resp.StatusCode != http.StatusNotFound {
		t.Fatalf("status %d, want 404", resp.StatusCode)
	}
}

// TestHTTP_PlaceRoundBetRoundAlreadyCompleted verifies 409 once the round ran.
func TestHTTP_PlaceRoundBetRoundAlreadyCompleted(t *testing.T) {
	url, wallet, _, cleanup := httpFixture(t, 0)
	defer cleanup()
	wallet.SetBalance("eve", 10000)

	startResp := postJSON(t, url+"/v1/rounds/start", nil)
	var spec RoundSpec
	decodeBody(t, startResp, &spec)

	// Place an initial bet so the pending round exists.
	postJSON(t, fmt.Sprintf("%s/v1/rounds/%d/bets", url, spec.RoundID),
		placeRoundBetRequest{PlayerID: "eve", MarbleIdx: 0, Amount: 5.0})

	// Run the round.
	runResp := postJSON(t, url+"/v1/rounds/run?wait=true", nil)
	if runResp.StatusCode != http.StatusOK {
		t.Fatalf("run round: status %d", runResp.StatusCode)
	}
	runResp.Body.Close()

	// Now try to bet again on the same round_id.
	resp := postJSON(t, fmt.Sprintf("%s/v1/rounds/%d/bets", url, spec.RoundID),
		placeRoundBetRequest{PlayerID: "eve", MarbleIdx: 1, Amount: 5.0})
	if resp.StatusCode != http.StatusConflict {
		t.Fatalf("status %d, want 409", resp.StatusCode)
	}
}

// TestHTTP_GetRoundBetsFiltersPlayer verifies the GET endpoint and player_id filter.
func TestHTTP_GetRoundBetsFiltersPlayer(t *testing.T) {
	url, wallet, _, cleanup := httpFixture(t, 0)
	defer cleanup()
	wallet.SetBalance("alice", 20000)
	wallet.SetBalance("bob", 20000)

	startResp := postJSON(t, url+"/v1/rounds/start", nil)
	var spec RoundSpec
	decodeBody(t, startResp, &spec)

	postJSON(t, fmt.Sprintf("%s/v1/rounds/%d/bets", url, spec.RoundID),
		placeRoundBetRequest{PlayerID: "alice", MarbleIdx: 0, Amount: 5.0})
	postJSON(t, fmt.Sprintf("%s/v1/rounds/%d/bets", url, spec.RoundID),
		placeRoundBetRequest{PlayerID: "bob", MarbleIdx: 1, Amount: 5.0})

	// All bets.
	allResp, _ := http.Get(fmt.Sprintf("%s/v1/rounds/%d/bets", url, spec.RoundID))
	if allResp.StatusCode != http.StatusOK {
		t.Fatalf("GET all bets: status %d", allResp.StatusCode)
	}
	var all []roundBetResponse
	decodeBody(t, allResp, &all)
	if len(all) != 2 {
		t.Fatalf("all bets: got %d, want 2", len(all))
	}

	// Filtered to alice.
	filtResp, _ := http.Get(fmt.Sprintf("%s/v1/rounds/%d/bets?player_id=alice", url, spec.RoundID))
	if filtResp.StatusCode != http.StatusOK {
		t.Fatalf("GET alice bets: status %d", filtResp.StatusCode)
	}
	var aliceBets []roundBetResponse
	decodeBody(t, filtResp, &aliceBets)
	if len(aliceBets) != 1 {
		t.Fatalf("alice bets: got %d, want 1", len(aliceBets))
	}
	if aliceBets[0].PlayerID != "alice" {
		t.Fatalf("player_id %q, want alice", aliceBets[0].PlayerID)
	}
}

// TestHTTP_GetRoundBetsUnknownRound verifies 404 for unknown round_id.
func TestHTTP_GetRoundBetsUnknownRound(t *testing.T) {
	url, _, _, cleanup := httpFixture(t, 0)
	defer cleanup()

	resp, _ := http.Get(fmt.Sprintf("%s/v1/rounds/%d/bets", url, uint64(999)))
	if resp.StatusCode != http.StatusNotFound {
		t.Fatalf("status %d, want 404", resp.StatusCode)
	}
}

// ─── Wallet balance endpoint tests ───────────────────────────────────────────

// TestHTTP_WalletBalance_KnownPlayer verifies 200 + correct balance for a
// player whose balance has been set in the MockWallet.
func TestHTTP_WalletBalance_KnownPlayer(t *testing.T) {
	url, wallet, _, cleanup := httpFixture(t, 0)
	defer cleanup()
	wallet.SetBalance("alice", 1240) // 12.40 in 2-decimal units

	resp, err := http.Get(url + "/v1/wallets/alice/balance")
	if err != nil {
		t.Fatalf("GET balance: %v", err)
	}
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("status %d, want 200", resp.StatusCode)
	}
	var body struct {
		PlayerID string  `json:"player_id"`
		Balance  float64 `json:"balance"`
	}
	decodeBody(t, resp, &body)
	if body.PlayerID != "alice" {
		t.Fatalf("player_id %q, want alice", body.PlayerID)
	}
	// 1240 units / 100 = 12.40
	if body.Balance != 12.40 {
		t.Fatalf("balance %.2f, want 12.40", body.Balance)
	}
}

// TestHTTP_WalletBalance_UnknownPlayer verifies 404 for a player_id that was
// never registered in the wallet.
func TestHTTP_WalletBalance_UnknownPlayer(t *testing.T) {
	url, _, _, cleanup := httpFixture(t, 0)
	defer cleanup()

	resp, err := http.Get(url + "/v1/wallets/nobody/balance")
	if err != nil {
		t.Fatalf("GET balance: %v", err)
	}
	if resp.StatusCode != http.StatusNotFound {
		t.Fatalf("status %d, want 404", resp.StatusCode)
	}
}
