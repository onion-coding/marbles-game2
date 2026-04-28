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
	MaxMarbles  int            // marbles per round (typ. 20)
	SimTimeout  time.Duration  // hard cap per Godot subprocess
	TrackPool   []uint8        // selectable track IDs; mirror Godot's TrackRegistry.SELECTABLE
}

// SimRunner is the surface rgs needs from the sim package — small enough
// that tests can stub it without spinning up Godot. The real implementation
// is sim.Run.
type SimRunner func(ctx context.Context, req sim.Request) (sim.Result, error)

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

	mu       sync.Mutex
	sessions map[string]*Session
	pending  []*Session // sessions whose Bet is queued for the next round, in placement order
	prevTrack int        // last track_id used, threaded for the no-back-to-back selector
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
		cfg.MaxMarbles = 20
	}
	if cfg.SimTimeout == 0 {
		cfg.SimTimeout = 60 * time.Second
	}
	if len(cfg.TrackPool) == 0 {
		cfg.TrackPool = []uint8{0, 1, 2, 3, 4, 5}
	}
	return &Manager{
		cfg:       cfg,
		sessions:  map[string]*Session{},
		prevTrack: -1,
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
// Returns the manifest as written to disk + a per-bet outcome list.
func (m *Manager) RunNextRound(ctx context.Context) (*replay.Manifest, []SettlementOutcome, error) {
	m.mu.Lock()
	pending := m.pending
	m.pending = nil
	prevTrack := m.prevTrack
	m.mu.Unlock()

	// 1. Fresh seed + round id.
	var seed [32]byte
	if _, err := rand.Read(seed[:]); err != nil {
		return nil, nil, fmt.Errorf("rgs: seed: %w", err)
	}
	roundID := uint64(time.Now().UnixNano())
	now := time.Now()
	r := round.New(roundID, seed, m.cfg.MaxMarbles, now)
	if err := r.OpenBuyIn(now); err != nil {
		return nil, nil, fmt.Errorf("rgs: OpenBuyIn: %w", err)
	}

	// 2. Add real bettors as participants in the order they queued. Their
	//    MarbleIndex equals their position in the participants list (round
	//    package assigns it on AddParticipant — see docs/fairness.md §Order
	//    invariant). After the bettors, we pad with synthetic player_NN to
	//    reach MaxMarbles so the race always has the same field size for
	//    fairness-symmetry; the synthetics never bet, never get paid.
	for _, s := range pending {
		if err := r.AddParticipant(round.Participant{Name: s.PlayerID}); err != nil {
			return nil, nil, fmt.Errorf("rgs: add bettor %q: %w", s.PlayerID, err)
		}
	}
	for i := len(pending); i < m.cfg.MaxMarbles; i++ {
		if err := r.AddParticipant(round.Participant{Name: fmt.Sprintf("filler_%02d", i)}); err != nil {
			return nil, nil, fmt.Errorf("rgs: add filler %d: %w", i, err)
		}
	}

	// 3. Lock the marble_index assignment in each session.
	for i, s := range pending {
		if err := s.AssignMarble(i); err != nil {
			return nil, nil, fmt.Errorf("rgs: assign marble %d to session %q: %w", i, s.ID, err)
		}
	}

	// 4. Pick a track. selectTrack hashes the round id; same algorithm
	//    roundd uses, kept in sync via TrackPool.
	trackID := m.selectTrack(roundID, prevTrack)

	// 5. Run the race.
	if err := r.StartRace(time.Now()); err != nil {
		return nil, nil, fmt.Errorf("rgs: StartRace: %w", err)
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
		return nil, nil, fmt.Errorf("rgs: sim: %w", err)
	}

	finish := time.Now()
	if err := r.FinishRace(round.Result{WinnerIndex: simRes.WinnerMarbleIndex, FinishedAt: finish}, finish); err != nil {
		return nil, nil, fmt.Errorf("rgs: FinishRace: %w", err)
	}
	revealed, ok := r.RevealedSeed()
	if !ok {
		return nil, nil, fmt.Errorf("rgs: seed unexpectedly not revealed")
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
		return nil, nil, fmt.Errorf("rgs: rtp.Settle: %w", err)
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
				return nil, nil, fmt.Errorf("rgs: credit winner %q: %w", s.PlayerID, cerr)
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
			return nil, nil, fmt.Errorf("rgs: session %q Settle: %w", s.ID, err)
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
	manifest := &replay.Manifest{
		RoundID:           roundID,
		ProtocolVersion:   3,
		TickRateHz:        simRes.TickRateHz,
		TrackID:           trackID,
		ServerSeedHashHex: hex.EncodeToString(commit[:]),
		ServerSeedHex:     hex.EncodeToString(revealed[:]),
		Participants:      storeParts,
		Winner:            replay.Winner{MarbleIndex: simRes.WinnerMarbleIndex, FinishTick: simRes.FinishTick},
	}
	replayFile, err := os.Open(simRes.ReplayPath)
	if err != nil {
		return nil, nil, fmt.Errorf("rgs: open replay: %w", err)
	}
	defer replayFile.Close()
	if err := m.cfg.Store.Save(manifest, replayFile); err != nil {
		return nil, nil, fmt.Errorf("rgs: store.Save: %w", err)
	}

	m.mu.Lock()
	m.prevTrack = int(trackID)
	m.mu.Unlock()
	return manifest, outcomes, nil
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
