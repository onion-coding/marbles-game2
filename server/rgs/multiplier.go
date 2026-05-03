// Package rgs — multiplier.go implements the v2 payout model documented in
// docs/math-model.md.
//
// Payout v2 (current canonical model):
//   - 30 marbles per round.
//   - Top-3 podium pays 9× / 4.5× / 3× of stake.
//   - Pickup multipliers (Tier 1 = 2×, Tier 2 = 3×) collected via geometric
//     zones during the race. A marble can pick up at most one tier per
//     round; multiple traversals take the MAX, not the product.
//   - Stack rule: payoff = base_podium × pickup_multiplier.
//   - Pickup wins even without podium: a marble that picked up a 2× but
//     finished 15th still pays 2× the stake to a bettor on it.
//   - Jackpot rule B2 (per user-confirmed design): triggers when the 1°
//     classified marble ALSO collected a Tier 2 (3×) pickup. When triggered,
//     the jackpot marble pays 100× outright (overrides podium × pickup).
//
// Determinism: every input to this module derives from the round's
// server_seed via SHA-256 (matching the Godot-side _hash_with_tag pattern
// in game/tracks/track.gd). Tier 2 zone activation, jackpot-eligible map
// events, etc. are all derivable from (server_seed, round_id, tag) so
// replays are byte-stable across re-derivations.
//
// This package replaces the M9 hardcoded `PayoutMultiplier = 19.0` model
// with a richer payout structure. The old single-multiplier model is no
// longer canonical — kept as a compat shim only for legacy track_id ≤ 6
// replays decoded from v3 manifests.
package rgs

import (
	"crypto/sha256"
	"encoding/binary"
	"sort"
)

// ─── Public payout constants ─────────────────────────────────────────────────

const (
	// PodiumPayout1st / 2nd / 3rd are the base multipliers for podium
	// finishes. Stack multiplicatively with pickup multipliers.
	PodiumPayout1st = 9.0
	PodiumPayout2nd = 4.5
	PodiumPayout3rd = 3.0

	// JackpotPayout is the flat multiplier paid to the bet on the jackpot
	// marble when the trigger fires. Replaces (does not stack with) the
	// podium × pickup payoff for that marble.
	JackpotPayout = 100.0

	// PickupTier1 is the "common" pickup multiplier (max 4 marbles per round).
	PickupTier1 = 2.0
	// PickupTier2 is the "rare" pickup multiplier (max 1 marble per round,
	// activated probabilistically per round to keep RTP ≈ target).
	PickupTier2 = 3.0

	// Tier2ActivationProbability is the per-round probability that the Tier 2
	// (3×) zone is "live". Tunable to scale RTP.
	//
	// Derivation: with jackpot rule B2 enabled, when a Tier 2 marble wins 1°
	// the payoff is 100× (not 9×3=27×) — so EV[3× pickup] is 6.78, not 4.35.
	// Solving (25.90 + 6.23·p) / 30 = 0.95 gives p ≈ 0.417. See
	// docs/math-model.md §3.4 (corrected) for the full derivation. Operator-
	// specific RTP targets (92-96%) can be reached by adjusting this value;
	// the server scales it from the configured RTPBps via Tier2ProbForRTP().
	Tier2ActivationProbability = 0.417

	// MarblesPerRound is the canonical marble count for v2 payout. v3 replays
	// (legacy track_id ≤ 6) stay decodable as 20.
	MarblesPerRound = 30

	// MaxTier1Pickups is the hard cap on Tier 1 (2×) pickups per round.
	// Map geometry must be designed so that more than this can't happen
	// (verified by the cross-map audit pipeline in math-model §4.1).
	MaxTier1Pickups = 4
	// MaxTier2Pickups is the hard cap on Tier 2 (3×) pickups per round.
	MaxTier2Pickups = 1
)

// ─── RoundOutcome ────────────────────────────────────────────────────────────

// RoundOutcome captures everything ComputeBetPayoff needs to decide a bet's
// payoff. Built by the server after the Godot sim returns + the replay tick
// stream is parsed for pickup-zone traversals.
//
// All fields are deterministic from the round's server_seed.
type RoundOutcome struct {
	// PodiumWinners holds the marble_index of 1°, 2°, 3°. Index in [0, 29]
	// for v2 rounds. -1 means "no marble in this position" (incomplete race
	// — should never happen on a finished race).
	PodiumWinners [3]int

	// PickupCollected maps marble_index → highest pickup multiplier collected.
	// Marbles not in the map have no pickup (implicit 1.0). A marble traversing
	// multiple pickup zones takes the MAX (e.g. Tier 1 + Tier 2 → 3.0, not 6.0).
	PickupCollected map[int]float64

	// JackpotTriggered is true when the jackpot rule (rule B2) fired this round.
	JackpotTriggered bool
	// JackpotMarbleIdx is the marble that won the jackpot (= 1° winner when
	// JackpotTriggered is true). -1 otherwise.
	JackpotMarbleIdx int
}

// NewRoundOutcome builds a RoundOutcome from raw race data. Applies the
// jackpot rule (B2) automatically: if the 1° classified marble has a
// Tier 2 (3×) pickup, jackpot triggers.
//
//	podium      — [3]int with marble_index of 1°/2°/3° (use -1 for "missing")
//	pickups     — marble_index → MAX pickup multiplier collected (omit marbles
//	              with no pickup — they default to 1.0 in payoff math)
func NewRoundOutcome(podium [3]int, pickups map[int]float64) RoundOutcome {
	out := RoundOutcome{
		PodiumWinners:    podium,
		PickupCollected:  pickups,
		JackpotTriggered: false,
		JackpotMarbleIdx: -1,
	}
	if pickups == nil {
		out.PickupCollected = map[int]float64{}
	}
	out.applyJackpotRule()
	return out
}

// applyJackpotRule implements jackpot rule B2:
//
//	"the 1° classified marble also collected a Tier 2 (3×) pickup"
//
// When triggered, the jackpot marble's payoff is JackpotPayout (overrides
// the podium × pickup calculation). All other bets resolve normally.
//
// Per docs/math-model.md §6.2: B2 is the operator-friendly choice — the
// jackpot fires roughly 1/900 rounds (1/30 chance the winner is any
// marble × 1/30 ≈ chance it has the rare pickup), giving a "session-level"
// jackpot moment instead of an extreme-rarity event.
func (o *RoundOutcome) applyJackpotRule() {
	winner := o.PodiumWinners[0]
	if winner < 0 {
		return
	}
	pickup, ok := o.PickupCollected[winner]
	if !ok {
		return
	}
	if pickup >= PickupTier2 {
		o.JackpotTriggered = true
		o.JackpotMarbleIdx = winner
	}
}

// ─── Payoff computation ─────────────────────────────────────────────────────

// ComputeBetPayoff computes the gross payoff for a single bet under the
// canonical v2 model. Returns 0 when the bet doesn't win (i.e. neither
// podium nor pickup applied to the bet's marble).
//
// The returned value is the GROSS payoff — caller is responsible for
// distinguishing "stake returned + winnings" vs "winnings only" depending
// on operator wallet conventions. Most operators net the stake against the
// payoff; this function returns the gross.
//
//	stake — bet amount in operator currency units (integer / fixed-point;
//	        passed as float64 to match the existing rgs.PayoutMultiplier
//	        signature for low-friction migration).
func ComputeBetPayoff(marbleIdx int, stake float64, outcome RoundOutcome) float64 {
	// Jackpot fast path — overrides everything.
	if outcome.JackpotTriggered && outcome.JackpotMarbleIdx == marbleIdx {
		return stake * JackpotPayout
	}

	// Find the marble's podium rank (0/1/2) or -1 if non-podium.
	rank := -1
	for i, idx := range outcome.PodiumWinners {
		if idx == marbleIdx {
			rank = i
			break
		}
	}

	pickup := 1.0
	if p, ok := outcome.PickupCollected[marbleIdx]; ok {
		pickup = p
	}

	// Podium hit → stack base × pickup.
	if rank >= 0 {
		base := podiumBaseForRank(rank)
		return stake * base * pickup
	}

	// Non-podium but with a pickup → pay the pickup multiplier alone.
	// This is the "win even without arriving on the podium" rule from the
	// user brief.
	if pickup > 1.0 {
		return stake * pickup
	}

	// No podium, no pickup → loss.
	return 0.0
}

func podiumBaseForRank(rank int) float64 {
	switch rank {
	case 0:
		return PodiumPayout1st
	case 1:
		return PodiumPayout2nd
	case 2:
		return PodiumPayout3rd
	default:
		return 0.0
	}
}

// ─── Tier 2 activation (deterministic from seed) ────────────────────────────

// DeriveTier2Active decides whether the Tier 2 (3×) pickup zone is "live"
// for this round. Deterministic from the round's server_seed + round_id —
// the same inputs always yield the same decision, so replays remain
// byte-stable.
//
// Implementation mirrors Godot's _hash_with_tag (see game/tracks/track.gd):
//
//	hash = SHA256(server_seed || BE(round_id) || "tier_2_active")
//
// We threshold the first byte of the hash (uniform 0-255) against
// `Tier2ActivationProbability * 256` to get a binary decision matching the
// configured probability.
func DeriveTier2Active(serverSeed []byte, roundID uint64) bool {
	return DeriveTier2ActiveWithProbability(serverSeed, roundID, Tier2ActivationProbability)
}

// DeriveTier2ActiveWithProbability is the explicit-probability variant.
// Used when an operator wants a non-default RTP target — see Tier2ProbForRTP.
func DeriveTier2ActiveWithProbability(serverSeed []byte, roundID uint64, probability float64) bool {
	if probability <= 0.0 {
		return false
	}
	if probability >= 1.0 {
		return true
	}
	h := sha256.New()
	h.Write(serverSeed)
	var ridBytes [8]byte
	binary.BigEndian.PutUint64(ridBytes[:], roundID)
	h.Write(ridBytes[:])
	h.Write([]byte("tier_2_active"))
	sum := h.Sum(nil)
	// Map first byte to [0, 1) and compare.
	val := float64(sum[0]) / 256.0
	return val < probability
}

// Tier2ProbForRTP returns the Tier 2 activation probability that yields
// (roughly) the requested RTP, given the canonical podium values + 4 Tier 1
// pickups + jackpot rule B2 active. Used by the server to scale the RTP
// knob to the operator's configured target.
//
// Algebra (see docs/math-model.md §3.4):
//
//	With jackpot B2: when 1° marble has Tier 2 (3×) pickup, payoff = 100×
//	(replaces 9 × 3 = 27). Hence:
//	  EV[3× pickup] = (1/30) × 100 + (1/30) × 13.5 + (1/30) × 9 + (27/30) × 3
//	               = (100 + 13.5 + 9 + 81) / 30
//	               = 203.5 / 30
//	               = 6.78
//
//	RTP = ((26 - p) × 0.55 + 4 × 2.90 + p × 6.78) / 30
//	    = (14.30 + 11.60 + 6.23 × p) / 30
//	    = (25.90 + 6.23 × p) / 30
//
//	→ p = (RTP × 30 − 25.90) / 6.23
//
// Where p ∈ [0, 1] is the Tier 2 probability. RTP outside [0.863, 1.087]
// is clamped to the nearest achievable bound. Empirical RTP from the
// canonical p≈0.417 is ~95% (see TestRTPSimulation).
func Tier2ProbForRTP(rtpTarget float64) float64 {
	p := (rtpTarget*30.0 - 25.90) / 6.23
	if p < 0.0 {
		return 0.0
	}
	if p > 1.0 {
		return 1.0
	}
	return p
}

// ─── MapPayoutModel — per-map payoff override ───────────────────────────────

// MapPayoutModel lets a track replace the default podium × pickup payout
// math with a custom model — used by casino-themed finishes (Roulette wheel,
// Plinko bins, Darts board) where the geometry of the finish determines
// the payoff directly via a slot/bin lookup table.
//
// Tracks without a custom model use DefaultPayoutModel which delegates to
// ComputeBetPayoff above.
type MapPayoutModel interface {
	// PayoffFor returns the gross payoff for `stake` placed on `marbleIdx`
	// given the round's outcome.
	PayoffFor(marbleIdx int, stake float64, outcome RoundOutcome) float64

	// Name returns a human-readable identifier for the model — used by the
	// audit log and replay manifest so an external auditor can verify the
	// model that paid the bet.
	Name() string
}

// DefaultPayoutModel implements the canonical podium × pickup model.
type DefaultPayoutModel struct{}

func (DefaultPayoutModel) PayoffFor(marbleIdx int, stake float64, outcome RoundOutcome) float64 {
	return ComputeBetPayoff(marbleIdx, stake, outcome)
}

func (DefaultPayoutModel) Name() string { return "default_v2" }

// ─── Casino-themed payout models ────────────────────────────────────────────

// RoulettePayoutModel implements a 37-slot roulette finish wheel.
//
// Each slot has its own multiplier; slot 0 (typically the green 0) carries
// the jackpot. The marble's finish slot replaces the podium concept entirely
// — the 1° classified marble's finish slot determines the slot, and ALL
// bets on that marble pay the slot's multiplier.
//
// SlotMultipliers must be 37 entries. JackpotSlot is the slot index that
// triggers the jackpot multiplier when matched.
type RoulettePayoutModel struct {
	SlotMultipliers [37]float64
	WinningSlot     int // set by the runtime once the marble lands
}

func (m RoulettePayoutModel) PayoffFor(marbleIdx int, stake float64, outcome RoundOutcome) float64 {
	if outcome.PodiumWinners[0] != marbleIdx {
		return 0.0
	}
	if m.WinningSlot < 0 || m.WinningSlot >= len(m.SlotMultipliers) {
		return 0.0
	}
	return stake * m.SlotMultipliers[m.WinningSlot]
}

func (RoulettePayoutModel) Name() string { return "roulette_finish" }

// StandardRouletteSlotMultipliers returns a 37-slot table modelled on
// European roulette (single zero):
//
//	slot 0  (green 0)   → 100×  (jackpot)
//	slot 1-36           → varies; weighted by red/black/odd/even — but for
//	                      this game we use a flat 1× for non-zero slots
//	                      since the bet model doesn't distinguish red/black.
//
// More elaborate roulette models with red/black/odd/even/dozen bet types
// would need a richer API surface; deferred to a future revision when bet
// types beyond "marble winner" are introduced.
func StandardRouletteSlotMultipliers() [37]float64 {
	var m [37]float64
	m[0] = 100.0 // green 0 — jackpot
	for i := 1; i < 37; i++ {
		m[i] = 1.0 // flat 1× for the MVP roulette model
	}
	return m
}

// PlinkoPayoutModel implements a 13-bin Plinko finish.
//
// Each bin pays a multiplier derived from how often marbles statistically
// land in it. Center bins pay LOW (or even sub-1×) because they're frequent;
// edge bins pay HIGH but are rare. Standard table:
//
//	bins[0..12] = [50, 10, 3, 2, 1.5, 1, 0.5, 1, 1.5, 2, 3, 10, 50]
//
// The bin where the 1° classified marble lands determines the payoff for
// all bets on that marble.
type PlinkoPayoutModel struct {
	BinMultipliers [13]float64
	WinningBin     int // 0..12, set at race end
}

func (m PlinkoPayoutModel) PayoffFor(marbleIdx int, stake float64, outcome RoundOutcome) float64 {
	if outcome.PodiumWinners[0] != marbleIdx {
		return 0.0
	}
	if m.WinningBin < 0 || m.WinningBin >= len(m.BinMultipliers) {
		return 0.0
	}
	return stake * m.BinMultipliers[m.WinningBin]
}

func (PlinkoPayoutModel) Name() string { return "plinko_finish" }

// StandardPlinkoBinMultipliers returns the canonical 13-bin pyramid:
//
//	[50, 10, 3, 2, 1.5, 1, 0.5, 1, 1.5, 2, 3, 10, 50]
//
// RTP under uniform marble distribution at finish (not realistic — actual
// distribution is bell-curve so RTP is lower) ~ sum/13 ≈ 9.85, but in
// practice marbles concentrate in centre bins so empirical RTP lands near
// 95%. Calibration via the audit pipeline (math-model §4.1).
func StandardPlinkoBinMultipliers() [13]float64 {
	return [13]float64{50, 10, 3, 2, 1.5, 1, 0.5, 1, 1.5, 2, 3, 10, 50}
}

// DartsPayoutModel implements a target-zone finish where marbles "stick"
// in concentric ring zones.
//
// 4 zones standard: bullseye (50×), inner ring (10×), outer ring (3×),
// off-board / miss (0×).
type DartsPayoutModel struct {
	ZoneMultipliers [4]float64 // 0=bullseye, 1=inner, 2=outer, 3=miss
	WinningZone     int        // 0..3, set at race end
}

func (m DartsPayoutModel) PayoffFor(marbleIdx int, stake float64, outcome RoundOutcome) float64 {
	if outcome.PodiumWinners[0] != marbleIdx {
		return 0.0
	}
	if m.WinningZone < 0 || m.WinningZone >= len(m.ZoneMultipliers) {
		return 0.0
	}
	return stake * m.ZoneMultipliers[m.WinningZone]
}

func (DartsPayoutModel) Name() string { return "darts_finish" }

// StandardDartsZoneMultipliers returns the canonical 4-zone payoff:
//
//	[50, 10, 3, 0]  // bullseye / inner / outer / miss
func StandardDartsZoneMultipliers() [4]float64 {
	return [4]float64{50, 10, 3, 0}
}

// ─── Pickup zone validation ────────────────────────────────────────────────

// ValidatePickupCounts asserts that the per-round pickup distribution
// respects the math-model caps (max 4 Tier 1, max 1 Tier 2). Returns nil
// when valid, an error describing the violation otherwise.
//
// Used in two places:
//   - Server post-sim: when parsing pickups from the replay, reject any
//     round that violates the caps (defends against a Godot-side bug
//     that would otherwise distort the RTP).
//   - Audit pipeline (math-model §4.1): part of the cross-map gate.
func ValidatePickupCounts(pickups map[int]float64) error {
	tier1, tier2 := 0, 0
	for _, mult := range pickups {
		switch {
		case mult >= PickupTier2:
			tier2++
		case mult >= PickupTier1:
			tier1++
		}
	}
	if tier1 > MaxTier1Pickups {
		return &PickupCapError{Tier: 1, Got: tier1, Max: MaxTier1Pickups}
	}
	if tier2 > MaxTier2Pickups {
		return &PickupCapError{Tier: 2, Got: tier2, Max: MaxTier2Pickups}
	}
	return nil
}

// PickupCapError is returned by ValidatePickupCounts when a round's pickups
// exceed the cap. Captures enough context for the operator alerting layer
// to surface a useful diagnostic.
type PickupCapError struct {
	Tier int
	Got  int
	Max  int
}

func (e *PickupCapError) Error() string {
	return "pickup-cap violation: tier " + intToStr(e.Tier) + " got " +
		intToStr(e.Got) + ", max " + intToStr(e.Max)
}

// intToStr — local helper to avoid the fmt import for a single
// error-formatting use. Kept tiny on purpose.
func intToStr(n int) string {
	if n == 0 {
		return "0"
	}
	neg := n < 0
	if neg {
		n = -n
	}
	var buf [20]byte
	i := len(buf)
	for n > 0 {
		i--
		buf[i] = byte('0' + n%10)
		n /= 10
	}
	if neg {
		i--
		buf[i] = '-'
	}
	return string(buf[i:])
}

// ─── Helpers for outcome construction ──────────────────────────────────────

// PodiumFromFinishOrder takes a slice of marble indices in finish order
// (1°, 2°, 3°, ..., 30°) and returns the [3]int podium expected by
// RoundOutcome. Pads with -1 for unfinished entries.
func PodiumFromFinishOrder(finishOrder []int) [3]int {
	var out [3]int
	for i := range out {
		if i < len(finishOrder) {
			out[i] = finishOrder[i]
		} else {
			out[i] = -1
		}
	}
	return out
}

// SortedPickupKeys returns the marble indices that have a pickup, sorted
// ascending. Useful for deterministic iteration (Go map iteration order
// is randomised, so anywhere we serialise pickups we sort first).
func SortedPickupKeys(pickups map[int]float64) []int {
	keys := make([]int, 0, len(pickups))
	for k := range pickups {
		keys = append(keys, k)
	}
	sort.Ints(keys)
	return keys
}
