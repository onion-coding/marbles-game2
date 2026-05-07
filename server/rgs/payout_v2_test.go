// Tests for the M18 payout v2 settle path.
//
// These tests use a richSim that returns a fully-populated sim.Result —
// podium top-3 + pickup tiers — so the manager's settle logic exercises
// ComputeBetPayoff, the jackpot rule, and the Tier 2 active gate. They
// complement the existing fakeSim-based tests (which still validate
// the v3 backward-compat path).
package rgs

import (
	"context"
	"math"
	"os"
	"path/filepath"
	"testing"

	"github.com/onion-coding/marbles-game2/server/replay"
	"github.com/onion-coding/marbles-game2/server/sim"
)

// richSim returns a deterministic sim.Result with podium + pickup data
// populated, simulating a real Godot v4 sim run. Used to exercise the
// payout v2 settle path in unit tests.
type richSim struct {
	podium       [3]int   // 1°/2°/3° marble indices
	tier1Marbles []int    // marbles that picked up 2×
	tier2Marble  int      // marble that picked up 3× (or -1)
	finishTicks  [3]int
}

func (r *richSim) Run(_ context.Context, req sim.Request) (sim.Result, error) {
	if err := os.MkdirAll(req.WorkDir, 0o755); err != nil {
		return sim.Result{}, err
	}
	replayPath := filepath.Join(req.WorkDir, "replay.bin")
	body := buildFakeReplayBytes(req.RoundID, req.ServerSeed[:], req.TrackID, req.ClientSeeds)
	if err := os.WriteFile(replayPath, body, 0o644); err != nil {
		return sim.Result{}, err
	}
	return sim.Result{
		RoundID:             req.RoundID,
		WinnerMarbleIndex:   r.podium[0],
		FinishTick:          r.finishTicks[0],
		PodiumMarbleIndices: r.podium,
		PodiumFinishTicks:   r.finishTicks,
		PickupTier1Marbles:  append([]int{}, r.tier1Marbles...),
		PickupTier2Marble:   r.tier2Marble,
		ProtocolVersion:     4,
		ReplayPath:          replayPath,
		TickRateHz:          60,
	}, nil
}

// newRichTestManager builds a Manager wired to a richSim. Mirrors
// newTestManager's setup but accepts a fully-specified outcome.
func newRichTestManager(t *testing.T, podium [3]int, tier1 []int, tier2 int) (*Manager, *MockWallet, string) {
	t.Helper()
	dir := t.TempDir()
	store, err := replay.New(filepath.Join(dir, "replays"))
	if err != nil {
		t.Fatalf("replay.New: %v", err)
	}
	wallet := NewMockWallet()
	rs := &richSim{
		podium:       podium,
		tier1Marbles: tier1,
		tier2Marble:  tier2,
		finishTicks:  [3]int{600, 612, 625},
	}
	mgr, err := NewManager(ManagerConfig{
		Wallet:     wallet,
		Store:      store,
		Sim:        rs.Run,
		WorkRoot:   filepath.Join(dir, "work"),
		BuyIn:      100,
		RTPBps:     9500,
		MaxMarbles: 30,
		TrackPool:  []uint8{1, 2, 3, 4, 5, 6},
	})
	if err != nil {
		t.Fatalf("NewManager: %v", err)
	}
	return mgr, wallet, dir
}

// helper to bet + run + assert payout for the marble we bet on.
func runRoundBet(t *testing.T, mgr *Manager, wallet *MockWallet,
	playerID string, betMarble int, stake float64) (balanceAfterRound uint64) {
	t.Helper()
	wallet.SetBalance(playerID, 100_000) // 1000.00 to cover all stakes
	spec, err := mgr.GenerateRoundSpec()
	if err != nil {
		t.Fatalf("GenerateRoundSpec: %v", err)
	}
	if _, _, err := mgr.PlaceBetOnRound(spec.RoundID, playerID, betMarble, stake, ""); err != nil {
		t.Fatalf("PlaceBetOnRound: %v", err)
	}
	if _, _, _, err := mgr.RunNextRound(context.Background()); err != nil {
		t.Fatalf("RunNextRound: %v", err)
	}
	bal, _ := wallet.Balance(playerID, DefaultCurrency)
	return bal
}

// Test 1: bet on 1° marble with no pickup → payoff = 9× stake.
func TestPayoutV2_Podium1stNoPickup(t *testing.T) {
	mgr, wallet, _ := newRichTestManager(t,
		[3]int{5, 7, 12}, // podium 1°=5, 2°=7, 3°=12
		[]int{},          // no Tier 1
		-1,               // no Tier 2
	)
	stake := 10.0
	bal := runRoundBet(t, mgr, wallet, "alice", 5, stake) // bet on 1°

	// Pre-round: 100,000. Debit 1000 (= stake×100). Credit 9× × stake × 100 = 9000.
	// Final: 100,000 - 1000 + 9000 = 108,000.
	want := uint64(108_000)
	if bal != want {
		t.Errorf("bet on 1° + no pickup: balance %d, want %d", bal, want)
	}
}

// Test 2: bet on 2° marble with no pickup → 4.5× stake.
func TestPayoutV2_Podium2ndNoPickup(t *testing.T) {
	mgr, wallet, _ := newRichTestManager(t,
		[3]int{5, 7, 12},
		[]int{},
		-1,
	)
	bal := runRoundBet(t, mgr, wallet, "alice", 7, 10.0) // bet on 2°
	// 100,000 - 1000 + 4500 = 103,500
	want := uint64(103_500)
	if bal != want {
		t.Errorf("bet on 2° + no pickup: balance %d, want %d", bal, want)
	}
}

// Test 3: bet on 3° marble with no pickup → 3× stake.
func TestPayoutV2_Podium3rdNoPickup(t *testing.T) {
	mgr, wallet, _ := newRichTestManager(t,
		[3]int{5, 7, 12},
		[]int{},
		-1,
	)
	bal := runRoundBet(t, mgr, wallet, "alice", 12, 10.0) // bet on 3°
	// 100,000 - 1000 + 3000 = 102,000
	want := uint64(102_000)
	if bal != want {
		t.Errorf("bet on 3° + no pickup: balance %d, want %d", bal, want)
	}
}

// Test 4: bet on non-podium marble with Tier 1 pickup → pays 2× stake even
// without finishing in the top 3 (the "pickup wins even without podium" rule).
func TestPayoutV2_PickupOnlyTier1(t *testing.T) {
	mgr, wallet, _ := newRichTestManager(t,
		[3]int{5, 7, 12}, // podium
		[]int{0, 1, 2, 3}, // 4 Tier 1 pickups, none on podium
		-1,
	)
	bal := runRoundBet(t, mgr, wallet, "alice", 0, 10.0) // bet on Tier 1 marble
	// 100,000 - 1000 + 2× × 10 × 100 = 100,000 - 1000 + 2000 = 101,000
	want := uint64(101_000)
	if bal != want {
		t.Errorf("bet on Tier 1 (non-podium): balance %d, want %d", bal, want)
	}
}

// Test 5: bet on 1° with Tier 1 pickup → stack = 9×2 = 18× stake.
// Note: this only triggers when the winner has Tier 1 (NOT Tier 2 — that's
// the jackpot). Stake debited 1000, credited 18000. Net +17000.
func TestPayoutV2_StackPodium1stTier1(t *testing.T) {
	mgr, wallet, _ := newRichTestManager(t,
		[3]int{5, 7, 12},
		[]int{5}, // 1° marble has Tier 1
		-1,
	)
	bal := runRoundBet(t, mgr, wallet, "alice", 5, 10.0)
	// 100,000 - 1000 + 18000 = 117,000
	want := uint64(117_000)
	if bal != want {
		t.Errorf("bet on 1° + Tier 1 stack: balance %d, want %d", bal, want)
	}
}

// Test 6: marble didn't podium and didn't pickup → loss (stake gone, no
// credit). Pick a valid marble (in [0, 20)) that isn't in the podium and
// isn't in the pickup list.
func TestPayoutV2_LossNoPodiumNoPickup(t *testing.T) {
	mgr, wallet, _ := newRichTestManager(t,
		[3]int{5, 7, 12}, // podium occupies 5/7/12
		[]int{},          // no pickups
		-1,
	)
	bal := runRoundBet(t, mgr, wallet, "alice", 9, 10.0) // marble 9: not in podium, no pickup
	// 100,000 - 1000 (stake debited at placement) + 0 (no credit) = 99,000.
	want := uint64(99_000)
	if bal != want {
		t.Errorf("bet on loser: balance %d, want %d", bal, want)
	}
}

// Helper: assert two floats are within tolerance.
func nearlyEqual(a, b, tolerance float64) bool {
	return math.Abs(a-b) < tolerance
}

// Test 7: ComputeBetPayoff is the canonical math used by settle. This is a
// pure-function smoke that mirrors what the manager does internally —
// useful for triaging if a settle test fails (is the issue in the manager
// or in the math?).
func TestPayoutV2_DirectMath(t *testing.T) {
	tests := []struct {
		name     string
		bet      int
		podium   [3]int
		pickups  map[int]float64
		stake    float64
		expected float64
	}{
		{"1st no pickup", 5, [3]int{5, 7, 12}, nil, 10.0, 90.0},
		{"2nd no pickup", 7, [3]int{5, 7, 12}, nil, 10.0, 45.0},
		{"3rd no pickup", 12, [3]int{5, 7, 12}, nil, 10.0, 30.0},
		{"Tier 1 only no podium", 0, [3]int{5, 7, 12},
			map[int]float64{0: 2.0}, 10.0, 20.0},
		{"Tier 2 only no podium", 0, [3]int{5, 7, 12},
			map[int]float64{0: 3.0}, 10.0, 30.0},
		{"1st + Tier 1 stack", 5, [3]int{5, 7, 12},
			map[int]float64{5: 2.0}, 10.0, 180.0},
		{"jackpot: 1st + Tier 2 → 100×", 5, [3]int{5, 7, 12},
			map[int]float64{5: 3.0}, 10.0, 1000.0},
		{"loser", 9, [3]int{5, 7, 12}, nil, 10.0, 0.0},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			outcome := NewRoundOutcome(tc.podium, tc.pickups)
			got := ComputeBetPayoff(tc.bet, tc.stake, outcome)
			if !nearlyEqual(got, tc.expected, 1e-9) {
				t.Errorf("got %f, want %f", got, tc.expected)
			}
		})
	}
}
