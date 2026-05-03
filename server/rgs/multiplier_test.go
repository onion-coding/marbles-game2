package rgs

import (
	"math"
	"testing"
)

// TestComputeBetPayoff_Podium covers the three podium-only cases:
// no pickup, betting on 1°/2°/3° pays the base multiplier exactly.
func TestComputeBetPayoff_Podium(t *testing.T) {
	tests := []struct {
		name      string
		marbleIdx int
		podium    [3]int
		expected  float64
	}{
		{"1st place pays 9x", 7, [3]int{7, 12, 3}, 9.0},
		{"2nd place pays 4.5x", 12, [3]int{7, 12, 3}, 4.5},
		{"3rd place pays 3x", 3, [3]int{7, 12, 3}, 3.0},
		{"non-podium pays 0", 99, [3]int{7, 12, 3}, 0.0},
		{"missing podium slot doesn't crash", 7, [3]int{-1, -1, -1}, 0.0},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			outcome := NewRoundOutcome(tc.podium, nil)
			got := ComputeBetPayoff(tc.marbleIdx, 1.0, outcome)
			if math.Abs(got-tc.expected) > 1e-9 {
				t.Errorf("got %f, want %f", got, tc.expected)
			}
		})
	}
}

// TestComputeBetPayoff_PickupOnly covers the "pickup wins even without
// podium" rule from the user brief: a marble with a 2× pickup that finishes
// 15th still pays 2× the stake.
func TestComputeBetPayoff_PickupOnly(t *testing.T) {
	pickups := map[int]float64{
		8: PickupTier1, // 2× pickup
	}
	outcome := NewRoundOutcome([3]int{1, 2, 3}, pickups)

	// Marble 8 has 2× pickup but didn't podium → pays 2×.
	got := ComputeBetPayoff(8, 10.0, outcome)
	if math.Abs(got-20.0) > 1e-9 {
		t.Errorf("pickup-only payoff: got %f, want 20.0", got)
	}

	// Marble 99 has no pickup and no podium → 0.
	got = ComputeBetPayoff(99, 10.0, outcome)
	if got != 0.0 {
		t.Errorf("non-pickup non-podium payoff: got %f, want 0.0", got)
	}
}

// TestComputeBetPayoff_Stack verifies the multiplicative stack rule:
// podium × pickup = composed payoff.
func TestComputeBetPayoff_Stack(t *testing.T) {
	pickups := map[int]float64{
		7: PickupTier1, // 2× pickup on 1° marble
		3: PickupTier1, // 2× pickup on 3° marble
		// 12 (2nd place) has no pickup → just 4.5×
	}
	// IMPORTANT: this outcome would normally trigger jackpot if 7 had a
	// Tier 2 pickup; here we use Tier 1 so jackpot stays off.
	outcome := NewRoundOutcome([3]int{7, 12, 3}, pickups)

	if outcome.JackpotTriggered {
		t.Fatal("jackpot should not trigger on Tier 1 pickup")
	}

	tests := []struct {
		name      string
		marbleIdx int
		expected  float64 // for stake = 1.0
	}{
		{"1st + 2x pickup = 18x", 7, 9.0 * 2.0},
		{"2nd no pickup = 4.5x", 12, 4.5},
		{"3rd + 2x pickup = 6x", 3, 3.0 * 2.0},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			got := ComputeBetPayoff(tc.marbleIdx, 1.0, outcome)
			if math.Abs(got-tc.expected) > 1e-9 {
				t.Errorf("got %f, want %f", got, tc.expected)
			}
		})
	}
}

// TestJackpotRule_B2 verifies jackpot trigger rule B2: 1° classified marble
// AND it collected a Tier 2 (3×) pickup.
func TestJackpotRule_B2(t *testing.T) {
	tests := []struct {
		name           string
		podium         [3]int
		pickups        map[int]float64
		wantTriggered  bool
		wantMarbleIdx  int
		wantPayoff_1st float64 // payoff for the 1° marble at stake=1
	}{
		{
			name:           "winner has Tier 2 → jackpot fires",
			podium:         [3]int{7, 12, 3},
			pickups:        map[int]float64{7: PickupTier2}, // 3× on winner
			wantTriggered:  true,
			wantMarbleIdx:  7,
			wantPayoff_1st: JackpotPayout, // 100×
		},
		{
			name:           "winner has Tier 1 → no jackpot, normal stack",
			podium:         [3]int{7, 12, 3},
			pickups:        map[int]float64{7: PickupTier1}, // 2× only
			wantTriggered:  false,
			wantMarbleIdx:  -1,
			wantPayoff_1st: 9.0 * 2.0,
		},
		{
			name:           "winner has no pickup → no jackpot, plain podium",
			podium:         [3]int{7, 12, 3},
			pickups:        map[int]float64{},
			wantTriggered:  false,
			wantMarbleIdx:  -1,
			wantPayoff_1st: 9.0,
		},
		{
			name:           "non-winner has Tier 2 → no jackpot",
			podium:         [3]int{7, 12, 3},
			pickups:        map[int]float64{12: PickupTier2}, // 3× on 2nd
			wantTriggered:  false,
			wantMarbleIdx:  -1,
			wantPayoff_1st: 9.0, // 1st marble has no pickup
		},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			outcome := NewRoundOutcome(tc.podium, tc.pickups)
			if outcome.JackpotTriggered != tc.wantTriggered {
				t.Errorf("triggered: got %v, want %v", outcome.JackpotTriggered, tc.wantTriggered)
			}
			if outcome.JackpotMarbleIdx != tc.wantMarbleIdx {
				t.Errorf("marble idx: got %d, want %d", outcome.JackpotMarbleIdx, tc.wantMarbleIdx)
			}
			payoff := ComputeBetPayoff(tc.podium[0], 1.0, outcome)
			if math.Abs(payoff-tc.wantPayoff_1st) > 1e-9 {
				t.Errorf("payoff for 1st: got %f, want %f", payoff, tc.wantPayoff_1st)
			}
		})
	}
}

// TestDeriveTier2Active_Determinism verifies that the derivation is
// byte-stable: same seed + round_id → same decision, every time.
func TestDeriveTier2Active_Determinism(t *testing.T) {
	seed := []byte("test-seed-bytes-32-chars-padded!")
	for round := uint64(0); round < 100; round++ {
		first := DeriveTier2Active(seed, round)
		// Re-derive 5 times — must always match.
		for trial := 0; trial < 5; trial++ {
			again := DeriveTier2Active(seed, round)
			if again != first {
				t.Errorf("round %d trial %d: drift (got %v, expected %v)",
					round, trial, again, first)
			}
		}
	}
}

// TestDeriveTier2Active_Distribution sanity-checks that across many seeds,
// the activation probability lands within tolerance of the configured value.
// Not a strict statistical test — just a smoke check.
func TestDeriveTier2Active_Distribution(t *testing.T) {
	const trials = 10000
	seed := []byte("statistical-test-seed-fixed-32!!")
	active := 0
	for round := uint64(0); round < trials; round++ {
		if DeriveTier2Active(seed, round) {
			active++
		}
	}
	got := float64(active) / float64(trials)
	tolerance := 0.03 // ±3% empirical — generous
	if math.Abs(got-Tier2ActivationProbability) > tolerance {
		t.Errorf("Tier 2 activation rate: got %.4f, want %.4f ± %.2f",
			got, Tier2ActivationProbability, tolerance)
	}
}

// TestTier2ProbForRTP verifies the inverse formula maps target RTPs to
// reasonable Tier 2 probabilities.
//
// With jackpot rule B2, EV[3× pickup] = 6.78, so:
//   p = (rtp · 30 − 25.90) / 6.23
//
// Spot checks for representative target RTPs:
//   0.95 → 0.417 (canonical sweet spot)
//   0.92 → (27.6 − 25.90) / 6.23 ≈ 0.273
//   0.99 → (29.7 − 25.90) / 6.23 ≈ 0.610
//   1.05 → clamped to 1.0
//   0.50 → clamped to 0.0
func TestTier2ProbForRTP(t *testing.T) {
	tests := []struct {
		rtp     float64
		wantMin float64 // expected p in [wantMin, wantMax]
		wantMax float64
	}{
		{0.95, 0.40, 0.44}, // canonical sweet spot ~0.417
		{0.92, 0.25, 0.30}, // ~0.273
		{0.99, 0.59, 0.63}, // ~0.610
		{0.86, 0.0, 0.02},  // very low RTP → near-0 (math-model floor)
		{0.50, 0.0, 0.0},   // far below floor → clamped to 0
		{1.50, 1.0, 1.0},   // far above ceiling → clamped to 1
	}
	for _, tc := range tests {
		t.Run("", func(t *testing.T) {
			got := Tier2ProbForRTP(tc.rtp)
			if got < tc.wantMin || got > tc.wantMax {
				t.Errorf("RTP %.2f → p %.4f, want in [%.2f, %.2f]",
					tc.rtp, got, tc.wantMin, tc.wantMax)
			}
		})
	}
}

// TestValidatePickupCounts checks the cap enforcement.
func TestValidatePickupCounts(t *testing.T) {
	tests := []struct {
		name    string
		pickups map[int]float64
		wantErr bool
	}{
		{"empty is valid", map[int]float64{}, false},
		{"4 tier1 + 1 tier2 is the cap", map[int]float64{
			0: 2.0, 1: 2.0, 2: 2.0, 3: 2.0, 4: 3.0,
		}, false},
		{"5 tier1 violates cap", map[int]float64{
			0: 2.0, 1: 2.0, 2: 2.0, 3: 2.0, 4: 2.0,
		}, true},
		{"2 tier2 violates cap", map[int]float64{
			0: 3.0, 1: 3.0,
		}, true},
		{"4 tier1 (no tier2) valid", map[int]float64{
			0: 2.0, 1: 2.0, 2: 2.0, 3: 2.0,
		}, false},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			err := ValidatePickupCounts(tc.pickups)
			if (err != nil) != tc.wantErr {
				t.Errorf("got err=%v, want wantErr=%v", err, tc.wantErr)
			}
		})
	}
}

// TestRTPSimulation runs a Monte-Carlo style estimate of the RTP under
// the canonical config (n2=4, n3 with prob ~0.685, podium 9/4.5/3) and
// asserts it lands near the documented 95% target.
//
// Methodology:
//   - 50 000 rounds.
//   - Each round: 30 marbles, uniform random podium (1° = random index),
//     n2=4 random distinct marbles get 2×, optionally one more gets 3×
//     based on the probabilistic seed-derived rule.
//   - Bet 1 unit on a random marble each round.
//   - Sum payoffs / total stake = empirical RTP.
//
// We use a deterministic-but-uniform PRNG (math/rand seeded) to avoid
// flaky CI runs. The point is to sanity-check the math, not to test
// fairness — the actual game uses SHA-256 derivation that's tested
// separately.
func TestRTPSimulation(t *testing.T) {
	const rounds = 50000
	const seedBase = 0xC0FFEE
	totalStake := 0.0
	totalPayoff := 0.0

	// Use a PRNG seeded deterministically so the test is reproducible.
	// Stdlib math/rand has good enough uniformity for this estimate.
	rng := newDeterministicRNG(seedBase)

	for r := 0; r < rounds; r++ {
		// Build a random podium (3 distinct marble indices).
		podium := [3]int{
			rng.intn(MarblesPerRound),
			-1, -1,
		}
		for i := 1; i < 3; i++ {
			for {
				cand := rng.intn(MarblesPerRound)
				if cand != podium[0] && cand != podium[1] {
					podium[i] = cand
					break
				}
			}
		}

		// 4 distinct Tier 1 pickups.
		pickups := map[int]float64{}
		for len(pickups) < MaxTier1Pickups {
			cand := rng.intn(MarblesPerRound)
			if _, ok := pickups[cand]; !ok {
				pickups[cand] = PickupTier1
			}
		}

		// 1 Tier 2 pickup with probability ~0.685, on a marble that doesn't
		// already have a pickup (or replaces a Tier 1 — we use replace-or-skip).
		if rng.float64() < Tier2ActivationProbability {
			for {
				cand := rng.intn(MarblesPerRound)
				if _, ok := pickups[cand]; !ok {
					pickups[cand] = PickupTier2
					break
				}
			}
		}

		outcome := NewRoundOutcome(podium, pickups)
		stake := 1.0
		bet := rng.intn(MarblesPerRound)
		payoff := ComputeBetPayoff(bet, stake, outcome)
		totalStake += stake
		totalPayoff += payoff
	}

	rtp := totalPayoff / totalStake
	const targetRTP = 0.95
	const tolerance = 0.02 // ±2% — generous for 50k samples
	if math.Abs(rtp-targetRTP) > tolerance {
		t.Errorf("empirical RTP: got %.4f, want %.4f ± %.2f", rtp, targetRTP, tolerance)
	}
	t.Logf("empirical RTP over %d rounds: %.4f (target %.4f)", rounds, rtp, targetRTP)
}

// deterministicRNG is a tiny xorshift64* PRNG used only by the RTP
// simulation test. Avoids the math/rand import for one test and gives
// fully reproducible output across Go versions.
type deterministicRNG struct {
	state uint64
}

func newDeterministicRNG(seed uint64) *deterministicRNG {
	if seed == 0 {
		seed = 0x9E3779B97F4A7C15
	}
	return &deterministicRNG{state: seed}
}

func (r *deterministicRNG) next() uint64 {
	r.state ^= r.state >> 12
	r.state ^= r.state << 25
	r.state ^= r.state >> 27
	return r.state * 0x2545F4914F6CDD1D
}

func (r *deterministicRNG) intn(n int) int {
	if n <= 0 {
		return 0
	}
	return int(r.next() % uint64(n))
}

func (r *deterministicRNG) float64() float64 {
	return float64(r.next()>>11) / float64(uint64(1)<<53)
}

// TestCasinoModels — smoke that the casino-themed payout models compute
// reasonable payoffs for a winning marble landing on the right slot.
func TestCasinoModels(t *testing.T) {
	t.Run("Roulette green 0 pays 100x", func(t *testing.T) {
		m := RoulettePayoutModel{
			SlotMultipliers: StandardRouletteSlotMultipliers(),
			WinningSlot:     0, // green
		}
		outcome := NewRoundOutcome([3]int{5, 10, 15}, nil)
		payoff := m.PayoffFor(5, 1.0, outcome)
		if payoff != 100.0 {
			t.Errorf("Roulette green 0 winner: got %f, want 100.0", payoff)
		}
		// Bet on non-winner pays 0.
		payoff = m.PayoffFor(10, 1.0, outcome)
		if payoff != 0.0 {
			t.Errorf("Roulette non-winner: got %f, want 0.0", payoff)
		}
	})

	t.Run("Plinko centre bin pays 0.5x", func(t *testing.T) {
		m := PlinkoPayoutModel{
			BinMultipliers: StandardPlinkoBinMultipliers(),
			WinningBin:     6, // centre = 0.5x
		}
		outcome := NewRoundOutcome([3]int{5, 10, 15}, nil)
		payoff := m.PayoffFor(5, 10.0, outcome)
		if payoff != 5.0 {
			t.Errorf("Plinko centre bin: got %f, want 5.0", payoff)
		}
	})

	t.Run("Plinko edge bin pays 50x", func(t *testing.T) {
		m := PlinkoPayoutModel{
			BinMultipliers: StandardPlinkoBinMultipliers(),
			WinningBin:     0, // edge = 50x
		}
		outcome := NewRoundOutcome([3]int{5, 10, 15}, nil)
		payoff := m.PayoffFor(5, 1.0, outcome)
		if payoff != 50.0 {
			t.Errorf("Plinko edge bin: got %f, want 50.0", payoff)
		}
	})

	t.Run("Darts bullseye pays 50x", func(t *testing.T) {
		m := DartsPayoutModel{
			ZoneMultipliers: StandardDartsZoneMultipliers(),
			WinningZone:     0, // bullseye
		}
		outcome := NewRoundOutcome([3]int{5, 10, 15}, nil)
		payoff := m.PayoffFor(5, 2.0, outcome)
		if payoff != 100.0 {
			t.Errorf("Darts bullseye 2x stake: got %f, want 100.0", payoff)
		}
	})

	t.Run("Darts miss pays 0", func(t *testing.T) {
		m := DartsPayoutModel{
			ZoneMultipliers: StandardDartsZoneMultipliers(),
			WinningZone:     3, // miss
		}
		outcome := NewRoundOutcome([3]int{5, 10, 15}, nil)
		payoff := m.PayoffFor(5, 1.0, outcome)
		if payoff != 0.0 {
			t.Errorf("Darts miss: got %f, want 0.0", payoff)
		}
	})

	t.Run("Default model name", func(t *testing.T) {
		if (DefaultPayoutModel{}).Name() != "default_v2" {
			t.Errorf("default name mismatch")
		}
	})
}
