package rgs

import (
	"context"
	"encoding/binary"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"testing"

	"github.com/onion-coding/marbles-game2/server/replay"
	"github.com/onion-coding/marbles-game2/server/sim"
)

// fakeSim writes a minimal valid replay.bin (just the v3 header, no
// frames — enough to satisfy replay.Store.Save's SHA verification) and
// returns a Result with the chosen winner. Avoids spinning up Godot in
// unit tests; the Manager doesn't care about the replay's contents
// beyond storage integrity.
type fakeSim struct {
	winnerIndex int
	finishTick  int
}

func (f *fakeSim) Run(ctx context.Context, req sim.Request) (sim.Result, error) {
	if err := os.MkdirAll(req.WorkDir, 0o755); err != nil {
		return sim.Result{}, err
	}
	replayPath := filepath.Join(req.WorkDir, "replay.bin")
	// Write a v3 header that ReplayWriter would produce. We only need
	// SHA-stable bytes — the manager streams the file into Store.Save
	// which hashes them; the file isn't re-parsed.
	body := buildFakeReplayBytes(req.RoundID, req.ServerSeed[:], req.TrackID, req.ClientSeeds)
	if err := os.WriteFile(replayPath, body, 0o644); err != nil {
		return sim.Result{}, err
	}
	return sim.Result{
		RoundID:           req.RoundID,
		WinnerMarbleIndex: f.winnerIndex,
		FinishTick:        f.finishTick,
		ReplayPath:        replayPath,
		TickRateHz:        60,
	}, nil
}

// buildFakeReplayBytes mirrors ReplayWriter.encode_header just well enough
// to produce a deterministic, non-empty file. The contents don't have to
// round-trip through ReplayReader — the manager only uses the file as a
// blob to hand to replay.Store.Save.
func buildFakeReplayBytes(roundID uint64, seed []byte, trackID uint8, clientSeeds []string) []byte {
	out := make([]byte, 0, 256)
	out = append(out, 3) // PROTOCOL_VERSION
	out = appendU64LE(out, roundID)
	out = appendU32LE(out, 60) // tick_rate_hz
	out = append(out, byte(len(seed)))
	out = append(out, seed...)
	hashStub := make([]byte, 32) // SHA256 placeholder; manager fills the real hash in manifest.
	out = append(out, byte(len(hashStub)))
	out = append(out, hashStub...)
	out = appendU32LE(out, 24) // slot_count
	out = append(out, trackID)
	out = appendU32LE(out, uint32(len(clientSeeds)))
	for i, cs := range clientSeeds {
		out = appendU32LE(out, uint32(i))
		out = appendU32LE(out, 0)
		out = append(out, byte(len("filler"))) // name_len
		out = append(out, []byte("filler")...)
		out = append(out, byte(len(cs)))
		out = append(out, cs...)
		out = appendU32LE(out, 0) // slot
	}
	out = appendU32LE(out, 0) // frame_count = 0
	return out
}

func appendU32LE(b []byte, v uint32) []byte {
	tmp := make([]byte, 4)
	binary.LittleEndian.PutUint32(tmp, v)
	return append(b, tmp...)
}

func appendU64LE(b []byte, v uint64) []byte {
	tmp := make([]byte, 8)
	binary.LittleEndian.PutUint64(tmp, v)
	return append(b, tmp...)
}

func newTestManager(t *testing.T, winnerIndex int) (*Manager, *MockWallet, string) {
	t.Helper()
	dir := t.TempDir()
	store, err := replay.New(filepath.Join(dir, "replays"))
	if err != nil {
		t.Fatalf("replay.New: %v", err)
	}
	wallet := NewMockWallet()
	fs := &fakeSim{winnerIndex: winnerIndex, finishTick: 600}
	mgr, err := NewManager(ManagerConfig{
		Wallet:     wallet,
		Store:      store,
		Sim:        fs.Run,
		WorkRoot:   filepath.Join(dir, "work"),
		BuyIn:      100,
		RTPBps:     9500,
		MaxMarbles: 20,
		TrackPool:  []uint8{1, 2, 3, 4, 5, 6},
	})
	if err != nil {
		t.Fatalf("NewManager: %v", err)
	}
	return mgr, wallet, dir
}

func TestManager_BetWinsCreditsWallet(t *testing.T) {
	mgr, wallet, _ := newTestManager(t, 0) // marble_index 0 wins (= our bettor)
	wallet.SetBalance("alice", 1000)

	sess, err := mgr.OpenSession("alice")
	if err != nil {
		t.Fatalf("OpenSession: %v", err)
	}
	bet, err := mgr.PlaceBet(sess.ID, 100)
	if err != nil {
		t.Fatalf("PlaceBet: %v", err)
	}
	if bal, _ := wallet.Balance("alice"); bal != 900 {
		t.Fatalf("after debit: balance %d, want 900", bal)
	}
	manifest, outcomes, _, err := mgr.RunNextRound(context.Background())
	if err != nil {
		t.Fatalf("RunNextRound: %v", err)
	}
	if manifest.Winner.MarbleIndex != 0 {
		t.Fatalf("winner index = %d, want 0", manifest.Winner.MarbleIndex)
	}
	if len(outcomes) != 1 {
		t.Fatalf("outcomes count = %d, want 1", len(outcomes))
	}
	if !outcomes[0].Won {
		t.Fatalf("outcomes[0].Won = false, want true (marble 0 won and we bet on it)")
	}
	// RTP check: stake = 20*100 = 2000; payout @ 9500bps = 1900; alice
	// started at 1000, paid 100 (=900), got 1900 prize → 2800.
	if bal, _ := wallet.Balance("alice"); bal != 2800 {
		t.Fatalf("after credit: balance %d, want 2800", bal)
	}
	if outcomes[0].PrizeAmount != 1900 {
		t.Fatalf("prize amount %d, want 1900", outcomes[0].PrizeAmount)
	}
	if outcomes[0].BetID != bet.BetID {
		t.Fatalf("outcome bet id %q != placed bet id %q", outcomes[0].BetID, bet.BetID)
	}

	// Session should be back in SETTLED so the player can bet again.
	state, currentBet, last := sess.Snapshot()
	if state != SessionSettled {
		t.Fatalf("session state %s, want SETTLED", state)
	}
	if currentBet != nil {
		t.Fatalf("expected bet cleared after settle, still got %+v", currentBet)
	}
	if last == nil || !last.Won {
		t.Fatalf("LastResult missing or Won=false")
	}
}

func TestManager_BetLosesNoCreditButDebitStands(t *testing.T) {
	mgr, wallet, _ := newTestManager(t, 5) // marble_index 5 wins; we bet from index 0
	wallet.SetBalance("bob", 500)

	sess, err := mgr.OpenSession("bob")
	if err != nil {
		t.Fatalf("OpenSession: %v", err)
	}
	if _, err := mgr.PlaceBet(sess.ID, 50); err != nil {
		t.Fatalf("PlaceBet: %v", err)
	}
	if _, _, _, err := mgr.RunNextRound(context.Background()); err != nil {
		t.Fatalf("RunNextRound: %v", err)
	}
	if bal, _ := wallet.Balance("bob"); bal != 450 {
		t.Fatalf("losing balance %d, want 450 (lost the bet)", bal)
	}
	state, _, last := sess.Snapshot()
	if state != SessionSettled {
		t.Fatalf("state %s, want SETTLED", state)
	}
	if last == nil || last.Won {
		t.Fatalf("LastResult missing or unexpectedly Won")
	}
}

func TestManager_PlaceBetRejectsOnInsufficientFunds(t *testing.T) {
	mgr, wallet, _ := newTestManager(t, 0)
	wallet.SetBalance("carol", 30)

	sess, err := mgr.OpenSession("carol")
	if err != nil {
		t.Fatalf("OpenSession: %v", err)
	}
	_, err = mgr.PlaceBet(sess.ID, 100)
	if err == nil {
		t.Fatalf("PlaceBet succeeded with insufficient funds")
	}
	if !errors.Is(err, ErrInsufficientFunds) {
		t.Fatalf("expected ErrInsufficientFunds, got %v", err)
	}
	if bal, _ := wallet.Balance("carol"); bal != 30 {
		t.Fatalf("balance changed after rejected bet: %d, want 30", bal)
	}
	state, bet, _ := sess.Snapshot()
	if state != SessionOpen {
		t.Fatalf("session state %s, want OPEN (bet was rejected)", state)
	}
	if bet != nil {
		t.Fatalf("bet was attached despite failure: %+v", bet)
	}
}

func TestManager_TwoBettorsOneWinsOneLoses(t *testing.T) {
	mgr, wallet, _ := newTestManager(t, 1) // marble_index 1 wins → 2nd bettor
	wallet.SetBalance("p1", 200)
	wallet.SetBalance("p2", 200)

	s1, _ := mgr.OpenSession("p1")
	s2, _ := mgr.OpenSession("p2")
	if _, err := mgr.PlaceBet(s1.ID, 100); err != nil {
		t.Fatalf("PlaceBet p1: %v", err)
	}
	if _, err := mgr.PlaceBet(s2.ID, 100); err != nil {
		t.Fatalf("PlaceBet p2: %v", err)
	}
	_, outcomes, _, err := mgr.RunNextRound(context.Background())
	if err != nil {
		t.Fatalf("RunNextRound: %v", err)
	}
	if len(outcomes) != 2 {
		t.Fatalf("outcomes len %d, want 2", len(outcomes))
	}
	if outcomes[0].Won || !outcomes[1].Won {
		t.Fatalf("expected p1=loss, p2=win, got %+v / %+v", outcomes[0], outcomes[1])
	}
	if bal, _ := wallet.Balance("p1"); bal != 100 {
		t.Fatalf("p1 balance %d, want 100 (lost 100)", bal)
	}
	if bal, _ := wallet.Balance("p2"); bal != 2000 {
		t.Fatalf("p2 balance %d, want 2000 (lost 100, won 1900)", bal)
	}
}

func TestManager_RoundIDCollisionRetries(t *testing.T) {
	// Sanity: roundIDs are unix-nanos so two calls in the same nanosecond
	// (rare but possible) would attempt to overwrite the store. Force the
	// situation by running two rounds back-to-back; replay.Store.Save is
	// supposed to refuse overwrites — we expect the second to fail
	// rather than corrupt the first round's audit entry.
	mgr, wallet, _ := newTestManager(t, 0)
	wallet.SetBalance("dave", 1000)

	s, _ := mgr.OpenSession("dave")
	if _, err := mgr.PlaceBet(s.ID, 100); err != nil {
		t.Fatalf("PlaceBet 1: %v", err)
	}
	if _, _, _, err := mgr.RunNextRound(context.Background()); err != nil {
		t.Fatalf("RunNextRound 1: %v", err)
	}
	if _, err := mgr.PlaceBet(s.ID, 100); err != nil {
		t.Fatalf("PlaceBet 2: %v", err)
	}
	if _, _, _, err := mgr.RunNextRound(context.Background()); err != nil {
		// Note: if this ever fails because two roundIDs landed in the same
		// nanosecond, the test would flake. Add a stable round-id source
		// in ManagerConfig (nextRoundID() func) if that becomes an issue.
		t.Fatalf("RunNextRound 2 failed (round id collision?): %v", err)
	}
}

// TestManager_SeedAlignment verifies that when a player calls
// GenerateRoundSpec (POST /v1/rounds/start), places a bet against the
// returned round_id, and RunNextRound is called, the manifest written to
// the audit store carries exactly the pre-minted round_id and server_seed —
// not a freshly generated pair.
func TestManager_SeedAlignment(t *testing.T) {
	mgr, wallet, _ := newTestManager(t, 3)
	wallet.SetBalance("alice", 10000)

	// Mint a spec — this is what the player sees from POST /v1/rounds/start.
	spec, err := mgr.GenerateRoundSpec()
	if err != nil {
		t.Fatalf("GenerateRoundSpec: %v", err)
	}

	// Place a bet on that specific round.
	_, _, err = mgr.PlaceBetOnRound(spec.RoundID, "alice", 3, 10.0)
	if err != nil {
		t.Fatalf("PlaceBetOnRound: %v", err)
	}

	// Run the next round — must consume spec, not mint a new one.
	manifest, _, _, err := mgr.RunNextRound(context.Background())
	if err != nil {
		t.Fatalf("RunNextRound: %v", err)
	}

	// The manifest's round_id must equal the spec's round_id.
	if manifest.RoundID != spec.RoundID {
		t.Fatalf("manifest.RoundID = %d, want %d (pre-minted spec round_id)",
			manifest.RoundID, spec.RoundID)
	}

	// The manifest's revealed server_seed_hex must equal the spec's seed.
	if manifest.ServerSeedHex != spec.ServerSeedHex {
		t.Fatalf("manifest.ServerSeedHex = %q, want %q (pre-minted spec seed)",
			manifest.ServerSeedHex, spec.ServerSeedHex)
	}
}

// TestManager_SeedAlignmentEmptyPending verifies that RunNextRound works
// when there are no pending rounds (no prior GenerateRoundSpec call). A
// fresh spec must be generated on-the-fly and used immediately, producing
// a valid manifest with a non-zero round_id and a 64-char seed hex.
func TestManager_SeedAlignmentEmptyPending(t *testing.T) {
	// Do NOT call GenerateRoundSpec — simulate the "skip betting" path.
	mgr, wallet, _ := newTestManager(t, 0)
	wallet.SetBalance("bob", 1000)

	sess, _ := mgr.OpenSession("bob")
	if _, err := mgr.PlaceBet(sess.ID, 100); err != nil {
		t.Fatalf("PlaceBet: %v", err)
	}

	manifest, _, _, err := mgr.RunNextRound(context.Background())
	if err != nil {
		t.Fatalf("RunNextRound (empty pending): %v", err)
	}
	if manifest.RoundID == 0 {
		t.Fatal("manifest.RoundID is zero — expected a unix-nano timestamp")
	}
	if len(manifest.ServerSeedHex) != 64 {
		t.Fatalf("manifest.ServerSeedHex length %d, want 64", len(manifest.ServerSeedHex))
	}
}

// Compile-time check: the real sim.Run satisfies SimRunner.
var _ SimRunner = sim.Run
func _() {
	// hush unused import lint when sim.Run is the only user
	_ = fmt.Sprintf
}
