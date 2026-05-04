package rgs

import (
	"context"
	"crypto/rand"
	"encoding/binary"
	"encoding/hex"
	"fmt"
	"hash/fnv"
	"os"
	"path/filepath"
	"sync"
	"time"

	"github.com/onion-coding/marbles-game2/server/replay"
	"github.com/onion-coding/marbles-game2/server/round"
	"github.com/onion-coding/marbles-game2/server/rtp"
	"github.com/onion-coding/marbles-game2/server/sim"
)

// ManagerConfig captures the wiring needed to actually run rounds. All
// fields are mandatory unless noted.
type ManagerConfig struct {
	Wallet      Wallet         // operator wallet client
	Store       *replay.Store  // audit-trail destination for completed rounds
	Sim         SimRunner      // headless Godot invoker (or a fake in tests)
	GodotBin    string         // injected into sim.Request — empty if Sim closure handles it
	ProjectPath string         // injected into sim.Request — empty if Sim closure handles it
	WorkRoot    string         // scratch dir for per-round spec / status files
	BuyIn       uint64         // mock per-marble stake when filling unbet seats
	RTPBps      uint32         // configured RTP basis points (e.g. 9500)
	MaxMarbles  int            // marbles per round (typ. 30)
	SimTimeout  time.Duration  // hard cap per Godot subprocess
	TrackPool   []uint8        // selectable track IDs; mirror Godot's TrackRegistry.SELECTABLE
}

// SimRunner is the surface rgs needs from the sim package — small enough
// that tests can stub it without spinning up Godot. The real implementation
// is sim.Run.
type SimRunner func(ctx context.Context, req sim.Request) (sim.Result, error)

// PayoutMultiplier is RETAINED as a display-only "expected payoff if win"
// hint shown to the player before they place a bet. As of M18 the actual
// settle payoff is computed by ComputeBetPayoff() under the v2 model, so
// this constant is no longer the canonical multiplier — keep it equal to
// the v2 podium 1° payoff so the displayed "if you win 1st place" estimate
// roughly matches what the player will receive for a podium win without
// pickup.
//
// History: prior to M18 this was the actual flat payoff multiplier (19×,
// matching 95% RTP under uniform 30 marbles). The v2 model replaces that
// with a podium + pickup + jackpot stack — see docs/math-model.md.
const PayoutMultiplier = PodiumPayout1st

// RoundBet is a bet placed directly against a pre-minted round (the
// POST /v1/rounds/{round_id}/bets flow). It is distinct from the
// session-based Bet used by PlaceBet — here the caller picks a specific
// marble and the debit happens immediately; the credit is issued after
// RunNextRound resolves the winner.
type RoundBet struct {
	BetID     string    `json:"bet_id"`
	PlayerID  string    `json:"player_id"`
	RoundID   uint64    `json:"round_id"`
	MarbleIdx int       `json:"marble_idx"`
	Amount    float64   `json:"amount"`
	PlacedAt  time.Time `json:"placed_at"`
}

// RoundBetOutcome carries the settlement result for a single RoundBet.
type RoundBetOutcome struct {
	BetID       string  `json:"bet_id"`
	PlayerID    string  `json:"player_id"`
	MarbleIdx   int     `json:"marble_idx"`
	Amount      float64 `json:"amount"`
	Won         bool    `json:"won"`
	Payout      float64 `json:"payout"`       // amount × PayoutMultiplier, or 0
	WinnerIndex int     `json:"winner_index"`
}

// pendingRound groups the spec minted by GenerateRoundSpec together with
// any RoundBets placed before the round is actually run. RunNextRound picks
// up the first entry in m.pendingRounds, if any, so the round_id visible
// to bettors matches the one in the outcome.
//
// Open item: persistence — pendingRounds live only in memory. A server
// restart loses all queued bets; add Postgres-backed storage (M9.x).
type pendingRound struct {
	spec *RoundSpec
	bets []*RoundBet
}

// Manager is the central coordinator. It owns the session table, the
// "next round" buffer of pending bets, and the wallet client. Methods
// are safe for concurrent calls.
//
// Lifecycle (synchronous, one round at a time, MVP):
//
//	OpenSession → PlaceBet → RunNextRound → settlement → SETTLED state
//
// Multi-round-at-once / lobby semantics are M9.x; this MVP runs one round
// in process, blocking, with deterministic settlement.
type Manager struct {
	cfg ManagerConfig

	mu            sync.Mutex
	sessions      map[string]*Session
	pending       []*Session    // sessions whose Bet is queued for the next round, in placement order
	prevTrack     int           // last track_id used, threaded for the no-back-to-back selector
	pendingRounds []*pendingRound // pre-minted round specs with their round-level bets, FIFO
	roundBets     map[uint64][]*RoundBet // round_id → all settled+pending bets (for GET queries)
}

func NewManager(cfg ManagerConfig) (*Manager, error) {
	if cfg.Wallet == nil {
		return nil, fmt.Errorf("rgs: ManagerConfig.Wallet required")
	}
	if cfg.Store == nil {
		return nil, fmt.Errorf("rgs: ManagerConfig.Store required")
	}
	if cfg.Sim == nil {
		return nil, fmt.Errorf("rgs: ManagerConfig.Sim required")
	}
	if cfg.MaxMarbles <= 0 {
		cfg.MaxMarbles = 30
	}
	if cfg.SimTimeout == 0 {
		cfg.SimTimeout = 60 * time.Second
	}
	if len(cfg.TrackPool) == 0 {
		// Six M11 themed tracks (forest=1, volcano=2, ice=3, cavern=4,
		// sky=5, stadium=6). Legacy ramp (id 0) is excluded from rotation
		// since the M11 redesign — see TrackRegistry.SELECTABLE in
		// game/tracks/track_registry.gd.
		cfg.TrackPool = []uint8{1, 2, 3, 4, 5, 6}
	}
	return &Manager{
		cfg:       cfg,
		sessions:  map[string]*Session{},
		prevTrack: -1,
		roundBets: map[uint64][]*RoundBet{},
	}, nil
}

// OpenSession creates a session for `playerID`. Does NOT touch the wallet
// — opening a session is free; the player only pays when they place a bet.
func (m *Manager) OpenSession(playerID string) (*Session, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	if playerID == "" {
		return nil, fmt.Errorf("rgs: empty playerID")
	}
	id := newID("sess_")
	now := time.Now()
	s := &Session{
		ID:        id,
		PlayerID:  playerID,
		State:     SessionOpen,
		OpenedAt:  now,
		UpdatedAt: now,
	}
	m.sessions[id] = s
	return s, nil
}

// Session looks up a session by id.
func (m *Manager) Session(id string) (*Session, bool) {
	m.mu.Lock()
	defer m.mu.Unlock()
	s, ok := m.sessions[id]
	return s, ok
}

// PlaceBet debits the player's wallet, then queues the session's bet for
// the next round. The bet is held atomically: if the wallet debit fails
// the session state is untouched.
func (m *Manager) PlaceBet(sessionID string, amount uint64) (*Bet, error) {
	m.mu.Lock()
	s, ok := m.sessions[sessionID]
	m.mu.Unlock()
	if !ok {
		return nil, fmt.Errorf("rgs: unknown session %q", sessionID)
	}
	if amount == 0 {
		return nil, fmt.Errorf("rgs: bet amount must be > 0")
	}
	betID := newID("bet_")
	if err := m.cfg.Wallet.Debit(s.PlayerID, amount, betID); err != nil {
		return nil, fmt.Errorf("rgs: wallet debit: %w", err)
	}
	bet := Bet{
		BetID:    betID,
		Amount:   amount,
		PlayerID: s.PlayerID,
		PlacedAt: time.Now(),
	}
	if err := s.PlaceBet(bet); err != nil {
		// Undo the debit by crediting back. Idempotent if the operator's
		// wallet is well-behaved — the credit and the original debit have
		// independent txIDs so retry is safe.
		_ = m.cfg.Wallet.Credit(s.PlayerID, amount, betID+":refund")
		return nil, fmt.Errorf("rgs: session refused bet: %w", err)
	}
	m.mu.Lock()
	m.pending = append(m.pending, s)
	m.mu.Unlock()
	return &bet, nil
}

// RunNextRound runs one full round end-to-end: takes the queued bets,
// fills empty seats with synthetic non-bet participants if needed,
// invokes the sim, persists the audit entry, and settles each bet.
//
// Seed alignment: RunNextRound consumes the oldest pendingRound (FIFO)
// and uses its pre-minted round_id, server_seed, and track_id so that
// bettors who called POST /v1/rounds/start before placing their bets see
// the same round_id and seed in the audit manifest. If no pendingRound
// exists (the "no-bet" path), a fresh spec is generated on-the-fly and
// consumed immediately.
//
// Returns the manifest as written to disk, a per-session-bet outcome list, and
// the per-round-bet outcome list (bets placed via POST /v1/rounds/{id}/bets).
func (m *Manager) RunNextRound(ctx context.Context) (*replay.Manifest, []SettlementOutcome, []RoundBetOutcome, error) {
	m.mu.Lock()
	pending := m.pending
	m.pending = nil

	// 1. Consume the oldest pre-minted pending round, or generate one now.
	var pr *pendingRound
	if len(m.pendingRounds) > 0 {
		pr = m.pendingRounds[0]
		m.pendingRounds = m.pendingRounds[1:]
	}
	prevTrack := m.prevTrack
	m.mu.Unlock()

	if pr == nil {
		// No pre-minted spec: generate a fresh one on-the-fly and use it
		// immediately (the caller skipped POST /v1/rounds/start).
		var rawSeed [32]byte
		if _, err := rand.Read(rawSeed[:]); err != nil {
			return nil, nil, nil, fmt.Errorf("rgs: seed: %w", err)
		}
		freshID := uint64(time.Now().UnixNano())
		m.mu.Lock()
		trackID := m.selectTrack(freshID, prevTrack)
		m.mu.Unlock()
		pr = &pendingRound{
			spec: &RoundSpec{
				RoundID:       freshID,
				ServerSeedHex: hex.EncodeToString(rawSeed[:]),
				TrackID:       trackID,
			},
		}
		// Register in roundBets so BetsForRound is aware of this round_id.
		m.mu.Lock()
		m.roundBets[freshID] = nil
		m.mu.Unlock()
	}

	// Decode the seed from the spec's hex string.
	seedBytes, err := hex.DecodeString(pr.spec.ServerSeedHex)
	if err != nil {
		return nil, nil, nil, fmt.Errorf("rgs: decode server seed: %w", err)
	}
	var seed [32]byte
	copy(seed[:], seedBytes)

	roundID := pr.spec.RoundID
	trackID := pr.spec.TrackID

	now := time.Now()
	r := round.New(roundID, seed, m.cfg.MaxMarbles, now)
	if err := r.OpenBuyIn(now); err != nil {
		return nil, nil, nil, fmt.Errorf("rgs: OpenBuyIn: %w", err)
	}

	// 2. Add real bettors as participants in the order they queued. Their
	//    MarbleIndex equals their position in the participants list (round
	//    package assigns it on AddParticipant — see docs/fairness.md §Order
	//    invariant). After the bettors, we pad with synthetic player_NN to
	//    reach MaxMarbles so the race always has the same field size for
	//    fairness-symmetry; the synthetics never bet, never get paid.
	for _, s := range pending {
		if err := r.AddParticipant(round.Participant{Name: s.PlayerID}); err != nil {
			return nil, nil, nil, fmt.Errorf("rgs: add bettor %q: %w", s.PlayerID, err)
		}
	}
	for i := len(pending); i < m.cfg.MaxMarbles; i++ {
		if err := r.AddParticipant(round.Participant{Name: fmt.Sprintf("filler_%02d", i)}); err != nil {
			return nil, nil, nil, fmt.Errorf("rgs: add filler %d: %w", i, err)
		}
	}

	// 3. Lock the marble_index assignment in each session.
	for i, s := range pending {
		if err := s.AssignMarble(i); err != nil {
			return nil, nil, nil, fmt.Errorf("rgs: assign marble %d to session %q: %w", i, s.ID, err)
		}
	}

	// 4. trackID comes from the consumed spec (set above). Update prevTrack
	//    after the round completes (step 9) so the next selectTrack call
	//    respects the no-back-to-back invariant.

	// 5. Run the race.
	if err := r.StartRace(time.Now()); err != nil {
		return nil, nil, nil, fmt.Errorf("rgs: StartRace: %w", err)
	}
	parts := r.Participants()
	clientSeeds := make([]string, len(parts))
	for i, p := range parts {
		clientSeeds[i] = p.ClientSeed
	}
	workDir := filepath.Join(m.cfg.WorkRoot, fmt.Sprintf("round-%d", roundID))
	simReq := sim.Request{
		GodotBin:    m.cfg.GodotBin,
		ProjectPath: m.cfg.ProjectPath,
		WorkDir:     workDir,
		RoundID:     roundID,
		ServerSeed:  seed,
		ClientSeeds: clientSeeds,
		TrackID:     trackID,
		Timeout:     m.cfg.SimTimeout,
		Stderr:      os.Stderr,
	}
	simRes, err := m.cfg.Sim(ctx, simReq)
	if err != nil {
		return nil, nil, nil, fmt.Errorf("rgs: sim: %w", err)
	}

	finish := time.Now()
	if err := r.FinishRace(round.Result{WinnerIndex: simRes.WinnerMarbleIndex, FinishedAt: finish}, finish); err != nil {
		return nil, nil, nil, fmt.Errorf("rgs: FinishRace: %w", err)
	}
	revealed, ok := r.RevealedSeed()
	if !ok {
		return nil, nil, nil, fmt.Errorf("rgs: seed unexpectedly not revealed")
	}

	// 6. Compute payouts. RTP applies to total stake including filler
	//    seats — the operator's house cut is invariant to whether seats
	//    were taken by real bettors or fillers. The PRIZE goes to the
	//    winning marble. If that marble is a real bettor, they get the
	//    prize as a credit. If it's a filler, the prize is *retained
	//    by the house as additional rake* (no real player to pay).
	stakes := make([]uint64, m.cfg.MaxMarbles)
	for i := range stakes {
		stakes[i] = m.cfg.BuyIn
	}
	prize, _, err := rtp.Settle(rtp.Config{RTPBasisPoints: m.cfg.RTPBps}, stakes, simRes.WinnerMarbleIndex)
	if err != nil {
		return nil, nil, nil, fmt.Errorf("rgs: rtp.Settle: %w", err)
	}

	// 7. Per-bet settlement.
	outcomes := make([]SettlementOutcome, len(pending))
	for i, s := range pending {
		bet := s.Bet // captured before Settle clears it
		won := bet.MarbleIndex == simRes.WinnerMarbleIndex
		var prizeAmount uint64
		var creditTxID string
		if won {
			prizeAmount = prize
			creditTxID = bet.BetID + ":credit"
			if cerr := m.cfg.Wallet.Credit(s.PlayerID, prizeAmount, creditTxID); cerr != nil {
				return nil, nil, nil, fmt.Errorf("rgs: credit winner %q: %w", s.PlayerID, cerr)
			}
		}
		outcome := SettlementOutcome{
			BetID:       bet.BetID,
			PlayerID:    bet.PlayerID,
			Amount:      bet.Amount,
			Won:         won,
			PrizeAmount: prizeAmount,
			WinnerIndex: simRes.WinnerMarbleIndex,
			CreditTxID:  creditTxID,
			SettledAt:   time.Now(),
		}
		if err := s.Settle(outcome); err != nil {
			return nil, nil, nil, fmt.Errorf("rgs: session %q Settle: %w", s.ID, err)
		}
		outcomes[i] = outcome
	}

	// 8. Persist the audit entry. Manifest carries the full participant
	//    list including filler tags; replay store is the single source of
	//    truth for compliance.
	storeParts := make([]replay.Participant, len(parts))
	for i, p := range parts {
		storeParts[i] = replay.Participant{
			MarbleIndex: p.MarbleIndex,
			Name:        p.Name,
			ClientSeed:  p.ClientSeed,
		}
	}
	commit := r.CommitHash()
	// Build the v4 manifest. ProtocolVersion follows the sim's version
	// (3 = legacy single-winner; 4 = podium-aware). For v3 sims the
	// podium array isn't populated, so we backfill slot 0 from the single
	// WinnerMarbleIndex and mark slots 1/2 as missing (-1). For v4 sims
	// we trust the podium array directly.
	pv := simRes.ProtocolVersion
	if pv == 0 {
		pv = 3
	}
	var podium [3]replay.PodiumEntry
	if pv >= 4 {
		for i := 0; i < 3; i++ {
			podium[i] = replay.PodiumEntry{
				MarbleIndex: simRes.PodiumMarbleIndices[i],
				FinishTick:  simRes.PodiumFinishTicks[i],
			}
		}
	} else {
		// v3 sim or test fakeSim: only the winner is known. Sentinel -1
		// for the other two slots so payoff math doesn't accidentally
		// award podium 2°/3° to marble 0 just because the default-zeroed
		// sim.Result puts a 0 there.
		podium[0] = replay.PodiumEntry{
			MarbleIndex: simRes.WinnerMarbleIndex,
			FinishTick:  simRes.FinishTick,
		}
		podium[1] = replay.PodiumEntry{MarbleIndex: -1, FinishTick: -1}
		podium[2] = replay.PodiumEntry{MarbleIndex: -1, FinishTick: -1}
	}

	// Tier 2 activation — deterministic from server_seed + round_id.
	// Computed here (and stored in the manifest) so an external auditor
	// can re-derive: same seed → same flag → same payoffs every replay.
	tier2Active := DeriveTier2Active(revealed[:], roundID)

	// Build PickupPerMarble convenience array. Length = participants count.
	// Default 1.0 (no pickup); Tier 1 marbles get 2.0; Tier 2 marble gets
	// 3.0 ONLY if Tier 2 was active this round. The MAX rule from
	// math-model §2.1 means Tier 2 overrides Tier 1 for the same marble.
	pickupPerMarble := make([]float64, len(storeParts))
	for i := range pickupPerMarble {
		pickupPerMarble[i] = 1.0
	}
	for _, idx := range simRes.PickupTier1Marbles {
		if idx >= 0 && idx < len(pickupPerMarble) {
			pickupPerMarble[idx] = PickupTier1
		}
	}
	tier2Idx := simRes.PickupTier2Marble
	if tier2Active && tier2Idx >= 0 && tier2Idx < len(pickupPerMarble) {
		pickupPerMarble[tier2Idx] = PickupTier2
	}

	// Apply jackpot rule B2: 1° marble has Tier 2 pickup → jackpot fires.
	// Uses the same outcome model the payoff calc reads from.
	pickupsMap := map[int]float64{}
	for i, m := range pickupPerMarble {
		if m > 1.0 {
			pickupsMap[i] = m
		}
	}
	outcome := NewRoundOutcome([3]int{
		podium[0].MarbleIndex, podium[1].MarbleIndex, podium[2].MarbleIndex,
	}, pickupsMap)

	// Tier1Marbles slice is captured for the manifest separately so the
	// raw "what physics produced" data is preserved even if the operator
	// later changes the Tier 2 activation rule.
	tier1Snapshot := append([]int{}, simRes.PickupTier1Marbles...)

	// ── v4 fields ────────────────────────────────────────────────────────

	// PickupPerMarbleTier: canonical uint8 tier array for certification
	// auditors. Maps float64 multiplier → tier byte (0/1/2).
	pickupPerMarbleTier := make([]uint8, len(pickupPerMarble))
	for i, mult := range pickupPerMarble {
		switch {
		case mult >= PickupTier2:
			pickupPerMarbleTier[i] = 2
		case mult >= PickupTier1:
			pickupPerMarbleTier[i] = 1
		default:
			pickupPerMarbleTier[i] = 0
		}
	}

	// PodiumPayouts: gross payoff in cents for a 1-unit stake on each podium
	// position. Auditor can verify: stake × PodiumPayouts[rank] / 100 = payoff.
	// For the jackpot marble (1° + Tier 2) ComputeBetPayoff returns 100×, so
	// PodiumPayouts[0] reflects the jackpot rule automatically.
	// Stored as a pointer so JSON omitempty can distinguish nil (v3 absent)
	// from a legitimately all-zero array.
	var podiumPayoutsArr [3]uint64
	for rank := 0; rank < 3; rank++ {
		idx := podium[rank].MarbleIndex
		if idx >= 0 {
			gross := ComputeBetPayoff(idx, 1.0, outcome)
			podiumPayoutsArr[rank] = uint64(gross * 100)
		}
	}
	podiumPayouts := &podiumPayoutsArr

	// FinishOrder: full sorted finish order from the sim. For v4 sims the
	// podium top-3 are known; for v3 sims only slot [0] is available.
	// We build as much as we can from the podium array.
	var finishOrder []int
	if pv >= 4 {
		for _, pe := range podium {
			if pe.MarbleIndex >= 0 {
				finishOrder = append(finishOrder, pe.MarbleIndex)
			}
		}
	} else if simRes.WinnerMarbleIndex >= 0 {
		finishOrder = []int{simRes.WinnerMarbleIndex}
	}

	manifest := &replay.Manifest{
		RoundID:             roundID,
		ProtocolVersion:     replay.ProtocolVersion4,
		TickRateHz:          simRes.TickRateHz,
		TrackID:             trackID,
		ServerSeedHashHex:   hex.EncodeToString(commit[:]),
		ServerSeedHex:       hex.EncodeToString(revealed[:]),
		Participants:        storeParts,
		Winner:              replay.Winner{MarbleIndex: simRes.WinnerMarbleIndex, FinishTick: simRes.FinishTick},
		Podium:              podium,
		MarbleCount:         uint8(m.cfg.MaxMarbles),
		PodiumPayouts:       podiumPayouts,
		PickupTier1Marbles:  tier1Snapshot,
		PickupTier2Marble:   simRes.PickupTier2Marble,
		Tier2Active:         tier2Active,
		PickupPerMarble:     pickupPerMarble,
		PickupPerMarbleTier: pickupPerMarbleTier,
		JackpotTriggered:    outcome.JackpotTriggered,
		JackpotMarbleIdx:    outcome.JackpotMarbleIdx,
		FinishOrder:         finishOrder,
	}
	replayFile, err := os.Open(simRes.ReplayPath)
	if err != nil {
		return nil, nil, nil, fmt.Errorf("rgs: open replay: %w", err)
	}
	defer replayFile.Close()
	if err := m.cfg.Store.Save(manifest, replayFile); err != nil {
		return nil, nil, nil, fmt.Errorf("rgs: store.Save: %w", err)
	}

	// 9. Settle round-level bets (POST /v1/rounds/{round_id}/bets flow).
	//    pr was popped from pendingRounds at the top of this function, so
	//    pr.bets contains every RoundBet placed against the same round_id
	//    and seed that the sim just ran. Seed alignment is guaranteed:
	//    the manifest's round_id and server_seed_hex match what bettors
	//    received from POST /v1/rounds/start.
	//
	// M18 — payoff is now ComputeBetPayoff(marble, stake, outcome) instead
	// of the legacy flat 19× rule. The same `outcome` built above (jackpot
	// rule applied, Tier 2 active flag respected) is reused so the manifest
	// + payoff are derived from the same inputs. Bets that don't podium and
	// don't have a pickup pay 0 (= loss); bets that do, pay the v2 model's
	// stack-aware payoff, capped at 100× via the jackpot rule.
	var roundBetOutcomes []RoundBetOutcome
	if pr != nil {
		var totalBets, totalPayout float64
		roundBetOutcomes = make([]RoundBetOutcome, len(pr.bets))
		for i, rb := range pr.bets {
			payout := ComputeBetPayoff(rb.MarbleIdx, rb.Amount, outcome)
			won := payout > 0.0
			if won {
				payoutUnits := uint64(payout * 100)
				creditTxID := rb.BetID + ":credit"
				if cerr := m.cfg.Wallet.Credit(rb.PlayerID, payoutUnits, creditTxID); cerr != nil {
					// Surface the error rather than silently swallowing — the
					// caller (handler) must decide whether to retry. Pending
					// credit recovery is M9.x (see docs/rgs-integration.md).
					return nil, nil, nil, fmt.Errorf("rgs: credit round-bet winner %q: %w", rb.PlayerID, cerr)
				}
				totalPayout += payout
			}
			totalBets += rb.Amount
			roundBetOutcomes[i] = RoundBetOutcome{
				BetID:       rb.BetID,
				PlayerID:    rb.PlayerID,
				MarbleIdx:   rb.MarbleIdx,
				Amount:      rb.Amount,
				Won:         won,
				Payout:      payout,
				WinnerIndex: simRes.WinnerMarbleIndex,
			}
		}
		totalLoss := totalBets - totalPayout
		fmt.Fprintf(os.Stderr, "rgs: round %d round-bets settled (v2 model): count=%d total_bets=%.2f total_payout=%.2f total_loss=%.2f jackpot=%v\n",
			roundID, len(pr.bets), totalBets, totalPayout, totalLoss, outcome.JackpotTriggered)
	}
	m.mu.Lock()
	m.prevTrack = int(trackID)
	m.mu.Unlock()
	return manifest, outcomes, roundBetOutcomes, nil
}

// RoundSpec is the minimal payload the Godot client needs to run a
// deterministic round locally.  It is server-authored (server_seed,
// round_id, track_id) so the fairness chain is always server-rooted.
// client_seeds are empty in the current MVP (no per-player seed mixing yet).
type RoundSpec struct {
	RoundID       uint64   `json:"round_id"`
	ServerSeedHex string   `json:"server_seed_hex"`
	TrackID       uint8    `json:"track_id"`
	ClientSeeds   []string `json:"client_seeds"`
}

// GenerateRoundSpec mints a fresh RoundSpec and registers it as a pending
// round so that bets can be placed against it via PlaceBetOnRound. The spec
// is also suitable for returning to a Godot client that wants a
// server-authoritative seed / track while running the physics locally
// (the --rgs client flow).
//
// The track is selected with the same no-back-to-back rotation used by
// RunNextRound, so the track sequence is consistent whether a full server
// round or a local-physics spec round is in progress.
func (m *Manager) GenerateRoundSpec() (*RoundSpec, error) {
	var seed [32]byte
	if _, err := rand.Read(seed[:]); err != nil {
		return nil, fmt.Errorf("rgs: GenerateRoundSpec seed: %w", err)
	}
	roundID := uint64(time.Now().UnixNano())

	m.mu.Lock()
	prevTrack := m.prevTrack
	trackID := m.selectTrack(roundID, prevTrack)
	m.prevTrack = int(trackID)
	m.mu.Unlock()

	clientSeeds := make([]string, m.cfg.MaxMarbles)
	for i := range clientSeeds {
		clientSeeds[i] = ""
	}

	spec := &RoundSpec{
		RoundID:       roundID,
		ServerSeedHex: hex.EncodeToString(seed[:]),
		TrackID:       trackID,
		ClientSeeds:   clientSeeds,
	}

	m.mu.Lock()
	m.pendingRounds = append(m.pendingRounds, &pendingRound{spec: spec})
	m.roundBets[roundID] = nil // register round_id as known, bets populated later
	m.mu.Unlock()

	return spec, nil
}

// PlaceBetOnRound places a bet directly on a pre-minted round (one that was
// returned by GenerateRoundSpec / POST /v1/rounds/start). The player's
// wallet is debited immediately; the credit is applied after RunNextRound
// resolves the winner for that round.
//
// Errors:
//   - ErrUnknownRound if round_id was never minted by GenerateRoundSpec.
//   - ErrRoundAlreadyRun if the round has already been executed.
//   - ErrInvalidMarbleIdx if marble_idx is outside [0, MaxMarbles).
//   - ErrInvalidBetAmount if amount <= 0.
//   - ErrInsufficientFunds / ErrUnknownPlayer propagated from wallet.Debit.
func (m *Manager) PlaceBetOnRound(roundID uint64, playerID string, marbleIdx int, amount float64) (*RoundBet, float64, error) {
	if marbleIdx < 0 || marbleIdx >= m.cfg.MaxMarbles {
		return nil, 0, fmt.Errorf("%w: marble_idx %d, valid range [0,%d)", ErrInvalidMarbleIdx, marbleIdx, m.cfg.MaxMarbles)
	}
	if amount <= 0 {
		return nil, 0, fmt.Errorf("%w: amount must be > 0, got %v", ErrInvalidBetAmount, amount)
	}

	m.mu.Lock()
	pr := m.findPendingRound(roundID)
	m.mu.Unlock()

	if pr == nil {
		// Check if it was already run (present in roundBets but no pending entry).
		m.mu.Lock()
		_, known := m.roundBets[roundID]
		m.mu.Unlock()
		if known {
			return nil, 0, ErrRoundAlreadyRun
		}
		return nil, 0, ErrUnknownRound
	}

	// Convert amount to uint64 micro-units for wallet (× 100 to preserve 2
	// decimal places while staying on the integer wallet interface).
	amountUnits := uint64(amount * 100)
	if amountUnits == 0 {
		return nil, 0, fmt.Errorf("%w: amount %v rounds to zero", ErrInvalidBetAmount, amount)
	}

	betID := newID("rbet_")
	if err := m.cfg.Wallet.Debit(playerID, amountUnits, betID); err != nil {
		return nil, 0, fmt.Errorf("rgs: wallet debit: %w", err)
	}

	balUnits, balErr := m.cfg.Wallet.Balance(playerID)
	var balAfter float64
	if balErr == nil {
		balAfter = float64(balUnits) / 100.0
	}

	bet := &RoundBet{
		BetID:     betID,
		PlayerID:  playerID,
		RoundID:   roundID,
		MarbleIdx: marbleIdx,
		Amount:    amount,
		PlacedAt:  time.Now(),
	}

	m.mu.Lock()
	// Re-validate: the round might have been popped by RunNextRound between
	// our unlock and this re-lock. If so, refund and error.
	if m.findPendingRound(roundID) == nil {
		m.mu.Unlock()
		_ = m.cfg.Wallet.Credit(playerID, amountUnits, betID+":refund")
		return nil, 0, ErrRoundAlreadyRun
	}
	pr.bets = append(pr.bets, bet)
	m.roundBets[roundID] = append(m.roundBets[roundID], bet)
	m.mu.Unlock()

	return bet, balAfter, nil
}

// BetsForRound returns the recorded bets for a round, optionally filtered to
// a single playerID (empty string = return all). The round must have been
// minted by GenerateRoundSpec. Returns nil, ErrUnknownRound if not found.
func (m *Manager) BetsForRound(roundID uint64, playerID string) ([]*RoundBet, error) {
	m.mu.Lock()
	bets, ok := m.roundBets[roundID]
	m.mu.Unlock()
	if !ok {
		return nil, ErrUnknownRound
	}
	if playerID == "" {
		cp := make([]*RoundBet, len(bets))
		copy(cp, bets)
		return cp, nil
	}
	var out []*RoundBet
	for _, b := range bets {
		if b.PlayerID == playerID {
			out = append(out, b)
		}
	}
	return out, nil
}

// findPendingRound returns the pendingRound for the given roundID, or nil.
// Caller must hold m.mu.
func (m *Manager) findPendingRound(roundID uint64) *pendingRound {
	for _, pr := range m.pendingRounds {
		if pr.spec.RoundID == roundID {
			return pr
		}
	}
	return nil
}

// CloseSession marks a session terminal. Reject when there's an unsettled
// bet — the caller must wait for the next RunNextRound to settle it.
func (m *Manager) CloseSession(sessionID string) error {
	m.mu.Lock()
	s, ok := m.sessions[sessionID]
	m.mu.Unlock()
	if !ok {
		return fmt.Errorf("rgs: unknown session %q", sessionID)
	}
	return s.Close()
}

// selectTrack mirrors cmd/roundd/main.go's policy. Kept identical so a
// regulator inspecting either coordinator's output sees the same track
// rotation.
func (m *Manager) selectTrack(roundID uint64, previousTrack int) uint8 {
	pool := m.cfg.TrackPool
	if len(pool) == 1 {
		return pool[0]
	}
	h := fnv.New64a()
	_ = binary.Write(h, binary.BigEndian, roundID)
	candidate := int(h.Sum64() % uint64(len(pool)))
	if int(pool[candidate]) == previousTrack {
		candidate = (candidate + 1) % len(pool)
	}
	return pool[candidate]
}

// newID generates a short, unique-enough identifier for sessions / bets.
// Format: <prefix><16 hex chars from crypto/rand>. Not a UUID but easier
// to read in logs and unique within any plausibly-sized server run.
func newID(prefix string) string {
	var b [8]byte
	_, _ = rand.Read(b[:])
	return prefix + hex.EncodeToString(b[:])
}
