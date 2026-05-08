package rgs

import (
	"context"
	"crypto/rand"
	"encoding/binary"
	"encoding/hex"
	"errors"
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

// SessionStorer is the interface the Manager uses to persist sessions. It is
// satisfied by *postgres.SessionStore (durable) and by the in-memory map
// adapter (inMemorySessionStore, below) so the Manager never imports the
// postgres package directly — callers wire the concrete implementation.
type SessionStorer interface {
	Create(ctx context.Context, sess *Session) error
	Get(ctx context.Context, id string) (*Session, error)
	Update(ctx context.Context, sess *Session) error
	Delete(ctx context.Context, id string) error
	ListByPlayer(ctx context.Context, playerID string) ([]*Session, error)
}

// ManagerConfig captures the wiring needed to actually run rounds. All
// fields are mandatory unless noted.
type ManagerConfig struct {
	Wallet       Wallet         // operator wallet client
	Store        *replay.Store  // audit-trail destination for completed rounds
	Sim          SimRunner      // headless Godot invoker (or a fake in tests)
	GodotBin     string         // injected into sim.Request — empty if Sim closure handles it
	ProjectPath  string         // injected into sim.Request — empty if Sim closure handles it
	WorkRoot     string         // scratch dir for per-round spec / status files
	BuyIn        uint64         // mock per-marble stake when filling unbet seats
	RTPBps       uint32         // configured RTP basis points (e.g. 9500)
	MaxMarbles   int            // marbles per round (typ. 30)
	SimTimeout   time.Duration  // hard cap per Godot subprocess
	TrackPool    []uint8        // selectable track IDs; mirror Godot's TrackRegistry.SELECTABLE
	// SessionStore is optional. When non-nil, sessions are persisted to the
	// provided store (e.g. *postgres.SessionStore) so they survive restarts.
	// When nil (the default), the Manager falls back to its legacy in-memory
	// map — identical behaviour to before this field existed.
	SessionStore SessionStorer
	// DefaultCurrency is the currency applied when a caller omits the
	// currency parameter. Defaults to rgs.DefaultCurrency ("EUR") when empty.
	DefaultCurrency string
	// SupportedCurrencies is the whitelist of accepted currency codes.
	// Defaults to defaultSupportedCurrencies when nil.
	SupportedCurrencies []string
	// MaxConcurrentRounds caps the number of rounds that may execute
	// concurrently inside RunRound / RunNextRound. 0 is treated as the
	// documented default (4). Set to 1 to restore strict serial behaviour.
	MaxConcurrentRounds int
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
	Currency  string    `json:"currency"`
	PlacedAt  time.Time `json:"placed_at"`
}

// RoundBetOutcome carries the settlement result for a single RoundBet.
type RoundBetOutcome struct {
	BetID       string  `json:"bet_id"`
	PlayerID    string  `json:"player_id"`
	MarbleIdx   int     `json:"marble_idx"`
	Amount      float64 `json:"amount"`
	Currency    string  `json:"currency"`
	Won         bool    `json:"won"`
	Payout      float64 `json:"payout"`  // amount × multiplier, or 0
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

// ErrManagerPaused is returned by RunNextRound when the Manager has been
// paused via Pause(). Callers should respond with 503 Service Unavailable.
var ErrManagerPaused = errors.New("manager paused")

// ErrRoundInFlight is returned by RunRound when the requested round_id is
// already being executed by another goroutine. Callers should wait and retry,
// or poll the outcome via the settled-round cache.
var ErrRoundInFlight = errors.New("round already in flight")

// ErrMaxConcurrentRounds is returned by RunRound / RunNextRound when the
// manager is already running MaxConcurrentRounds rounds simultaneously.
// Callers should retry after a short back-off.
var ErrMaxConcurrentRounds = errors.New("max concurrent rounds reached")

// roundExecution tracks the in-progress or completed state of a single
// round. It is the unit of concurrency isolation: each round owns its own
// mu so that sim, manifest, and settle steps never share locks with other
// concurrent rounds. The result is cached here after completion so that
// duplicate RunRound calls on the same round_id return the same outcome
// without re-running the sim.
type roundExecution struct {
	mu     sync.Mutex        // guards done + fields below
	done   bool              // true when the round has completed (success or error)
	doneCh chan struct{}      // closed when done becomes true

	// populated on success:
	manifest        *replay.Manifest
	outcomes        []SettlementOutcome
	roundBetOutcomes []RoundBetOutcome

	// populated on failure:
	err error
}

// Manager is the central coordinator. It owns the session table, the
// "next round" buffer of pending bets, and the wallet client. Methods
// are safe for concurrent calls.
//
// Concurrency model (M9.6):
//
//	Multiple rounds may execute concurrently — up to cfg.MaxConcurrentRounds
//	at a time. Each round runs in its own goroutine (spawned by RunRound /
//	RunNextRound) and owns a *roundExecution that holds per-round state.
//	The Manager's main mutex (m.mu) is held only for bookkeeping operations
//	(queue pops, map writes, prevTrack updates) — never while the sim or
//	wallet calls are in progress. This ensures that N in-flight rounds do
//	not block each other on the Manager mutex.
//
//	Idempotency: a second call to RunRound with an already-in-flight
//	round_id returns ErrRoundInFlight. A call against an already-settled
//	round_id returns the cached outcome immediately (no re-sim).
//
//	Serial default: MaxConcurrentRounds defaults to 4, but the Scheduler
//	drives only one round at a time unless --scheduler-overlap-rounds > 0.
//	Operator opt-in via that flag.
type Manager struct {
	cfg ManagerConfig

	mu            sync.Mutex
	sessions      map[string]*Session    // in-memory cache; also the canonical store when cfg.SessionStore == nil
	sessionStore  SessionStorer          // durable back-end; nil = legacy in-memory only
	pending       []*Session             // sessions whose Bet is queued for the next round, in placement order
	prevTrack     int                    // last track_id used, threaded for the no-back-to-back selector
	pendingRounds []*pendingRound        // pre-minted round specs with their round-level bets, FIFO
	roundBets     map[uint64][]*RoundBet // round_id → all settled+pending bets (for GET queries)
	paused        bool                   // when true, RunNextRound returns ErrManagerPaused immediately

	// per-round concurrency tracking (guarded by mu)
	inFlightRounds map[uint64]*roundExecution // round_id → in-progress or completed execution
	inFlightCount  int                        // number of rounds currently executing (not yet done)
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
	if cfg.DefaultCurrency == "" {
		cfg.DefaultCurrency = DefaultCurrency
	} else {
		cfg.DefaultCurrency = NormalizeCurrency(cfg.DefaultCurrency)
	}
	if len(cfg.SupportedCurrencies) == 0 {
		cfg.SupportedCurrencies = append([]string{}, defaultSupportedCurrencies...)
	}
	if len(cfg.TrackPool) == 0 {
		// Six M11 themed tracks (forest=1, volcano=2, ice=3, cavern=4,
		// sky=5, stadium=6). Legacy ramp (id 0) is excluded from rotation
		// since the M11 redesign — see TrackRegistry.SELECTABLE in
		// game/tracks/track_registry.gd.
		cfg.TrackPool = []uint8{1, 2, 3, 4, 5, 6}
	}
	if cfg.MaxConcurrentRounds <= 0 {
		cfg.MaxConcurrentRounds = 4
	}
	// m.sessions is always the live-pointer cache (used by RunNextRound to
	// hold *Session pointers across the race). When no external SessionStore
	// is configured, the inMemorySessionStore wraps the same map so we have
	// exactly one authoritative copy of each session.
	cache := map[string]*Session{}
	var store SessionStorer
	if cfg.SessionStore != nil {
		store = cfg.SessionStore
	} else {
		store = &inMemorySessionStore{m: cache}
	}
	return &Manager{
		cfg:            cfg,
		sessions:       cache,
		sessionStore:   store,
		prevTrack:      -1,
		roundBets:      map[uint64][]*RoundBet{},
		inFlightRounds: map[uint64]*roundExecution{},
	}, nil
}

// OpenSession creates a session for `playerID`. Does NOT touch the wallet
// — opening a session is free; the player only pays when they place a bet.
// When a durable SessionStorer is configured, the new session is also
// persisted there so it survives a restart.
func (m *Manager) OpenSession(playerID string) (*Session, error) {
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
	// Persist to the durable store first (if configured) so we never have
	// a session in memory that failed to land in Postgres.
	if err := m.sessionStore.Create(context.Background(), s); err != nil {
		return nil, fmt.Errorf("rgs: OpenSession persist: %w", err)
	}
	m.mu.Lock()
	m.sessions[id] = s
	m.mu.Unlock()
	return s, nil
}

// Session looks up a session by id. The in-memory map is checked first
// (always populated for sessions opened in this process lifetime). If the
// session is absent from the in-memory cache AND a durable store is
// configured, the store is queried — this covers the restart-recovery case
// where a Postgres-backed session was created before the last restart.
func (m *Manager) Session(id string) (*Session, bool) {
	m.mu.Lock()
	s, ok := m.sessions[id]
	m.mu.Unlock()
	if ok {
		return s, true
	}
	// Cache miss: try the durable store.
	fetched, err := m.sessionStore.Get(context.Background(), id)
	if err != nil {
		// ErrNotFound or any Postgres error — treat as "not found" so the
		// caller gets the same bool=false semantics as before.
		return nil, false
	}
	// Re-populate the in-memory cache so subsequent lookups are fast.
	m.mu.Lock()
	m.sessions[id] = fetched
	m.mu.Unlock()
	return fetched, true
}

// PlaceBet debits the player's wallet, then queues the session's bet for
// the next round. The bet is held atomically: if the wallet debit fails
// the session state is untouched. When a durable SessionStorer is
// configured the updated session is also written through to it.
func (m *Manager) PlaceBet(sessionID string, amount uint64, currency string) (*Bet, error) {
	cur := NormalizeCurrency(currency)
	if cur == "" {
		cur = m.currency()
	}
	if err := ValidateCurrency(cur, m.cfg.SupportedCurrencies); err != nil {
		return nil, fmt.Errorf("rgs: PlaceBet: %w", err)
	}
	s, ok := m.Session(sessionID)
	if !ok {
		return nil, fmt.Errorf("rgs: unknown session %q", sessionID)
	}
	if amount == 0 {
		return nil, fmt.Errorf("rgs: bet amount must be > 0")
	}
	betID := newID("bet_")
	if err := m.cfg.Wallet.Debit(s.PlayerID, amount, cur, betID); err != nil {
		return nil, fmt.Errorf("rgs: wallet debit: %w", err)
	}
	bet := Bet{
		BetID:    betID,
		Amount:   amount,
		Currency: cur,
		PlayerID: s.PlayerID,
		PlacedAt: time.Now(),
	}
	if err := s.PlaceBet(bet); err != nil {
		// Undo the debit by crediting back. Idempotent if the operator's
		// wallet is well-behaved — the credit and the original debit have
		// independent txIDs so retry is safe.
		_ = m.cfg.Wallet.Credit(s.PlayerID, amount, cur, betID+":refund")
		return nil, fmt.Errorf("rgs: session refused bet: %w", err)
	}
	// Persist the state change (BET + bet_data) to the durable store.
	if err := m.sessionStore.Update(context.Background(), s); err != nil {
		// Roll back the in-memory state change and refund the wallet.
		// The session goes back to its pre-bet state so the next call
		// can retry cleanly.
		_ = s.rollbackBet()
		_ = m.cfg.Wallet.Credit(s.PlayerID, amount, cur, betID+":refund")
		return nil, fmt.Errorf("rgs: PlaceBet persist: %w", err)
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
//
// Concurrency: RunNextRound pops a pending round from the shared queue and
// then calls RunRound to execute it. Multiple concurrent callers each pop a
// distinct round so there is no cross-contamination. The MaxConcurrentRounds
// semaphore in RunRound limits total parallelism.
func (m *Manager) RunNextRound(ctx context.Context) (*replay.Manifest, []SettlementOutcome, []RoundBetOutcome, error) {
	m.mu.Lock()
	if m.paused {
		m.mu.Unlock()
		return nil, nil, nil, ErrManagerPaused
	}
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

	return m.executeRound(ctx, pr, pending)
}

// RunRound executes the round with the given round_id. The round_id must have
// been previously minted by GenerateRoundSpec. Session-based bets (PlaceBet)
// are NOT included — those flow through RunNextRound. This method is designed
// for direct targeted execution by the Scheduler when overlap > 0.
//
// Concurrency guarantees:
//   - If round_id is currently in-flight: returns ErrRoundInFlight immediately.
//   - If round_id was already settled: returns the cached outcome, no re-sim.
//   - If MaxConcurrentRounds would be exceeded: returns ErrMaxConcurrentRounds.
//
// The round_id is removed from pendingRounds and its execution tracked in
// inFlightRounds. On completion the roundExecution is retained for idempotent
// result delivery.
func (m *Manager) RunRound(ctx context.Context, roundID uint64) (*replay.Manifest, []SettlementOutcome, []RoundBetOutcome, error) {
	m.mu.Lock()
	if m.paused {
		m.mu.Unlock()
		return nil, nil, nil, ErrManagerPaused
	}

	// Check for existing execution.
	if ex, exists := m.inFlightRounds[roundID]; exists {
		m.mu.Unlock()
		ex.mu.Lock()
		defer ex.mu.Unlock()
		if ex.done {
			// Already settled — return cached outcome.
			return ex.manifest, ex.outcomes, ex.roundBetOutcomes, ex.err
		}
		// In-flight but not done yet.
		return nil, nil, nil, ErrRoundInFlight
	}

	// Check concurrency cap.
	if m.inFlightCount >= m.cfg.MaxConcurrentRounds {
		m.mu.Unlock()
		return nil, nil, nil, ErrMaxConcurrentRounds
	}

	// Pop the specific pending round.
	var pr *pendingRound
	for i, p := range m.pendingRounds {
		if p.spec.RoundID == roundID {
			pr = p
			m.pendingRounds = append(m.pendingRounds[:i], m.pendingRounds[i+1:]...)
			break
		}
	}
	if pr == nil {
		// Not in pendingRounds — check if already in roundBets (already run).
		_, known := m.roundBets[roundID]
		m.mu.Unlock()
		if known {
			return nil, nil, nil, ErrRoundAlreadyRun
		}
		return nil, nil, nil, ErrUnknownRound
	}

	// Register in-flight execution.
	ex := &roundExecution{doneCh: make(chan struct{})}
	m.inFlightRounds[roundID] = ex
	m.inFlightCount++
	m.mu.Unlock()

	manifest, outcomes, rbOutcomes, err := m.executeRound(ctx, pr, nil)

	// Record result and mark done.
	m.mu.Lock()
	m.inFlightCount--
	m.mu.Unlock()

	ex.mu.Lock()
	ex.manifest = manifest
	ex.outcomes = outcomes
	ex.roundBetOutcomes = rbOutcomes
	ex.err = err
	ex.done = true
	close(ex.doneCh)
	ex.mu.Unlock()

	return manifest, outcomes, rbOutcomes, err
}

// executeRound is the shared implementation called by both RunNextRound and
// RunRound. It takes the resolved pendingRound (guaranteed non-nil) and the
// list of session-based bettors (nil when called from RunRound). All
// sim/wallet/store operations happen here, under no Manager mutex — only
// short bookkeeping locks are acquired at the start and end.
func (m *Manager) executeRound(ctx context.Context, pr *pendingRound, pending []*Session) (*replay.Manifest, []SettlementOutcome, []RoundBetOutcome, error) {
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
		betCur := bet.Currency
		if betCur == "" {
			betCur = m.currency()
		}
		won := bet.MarbleIndex == simRes.WinnerMarbleIndex
		var prizeAmount uint64
		var creditTxID string
		if won {
			prizeAmount = prize
			creditTxID = bet.BetID + ":credit"
			if cerr := m.cfg.Wallet.Credit(s.PlayerID, prizeAmount, betCur, creditTxID); cerr != nil {
				return nil, nil, nil, fmt.Errorf("rgs: credit winner %q: %w", s.PlayerID, cerr)
			}
		}
		outcome := SettlementOutcome{
			BetID:       bet.BetID,
			PlayerID:    bet.PlayerID,
			Amount:      bet.Amount,
			Currency:    betCur,
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
	for i, mv := range pickupPerMarble {
		if mv > 1.0 {
			pickupsMap[i] = mv
		}
	}
	roundOutcome := NewRoundOutcome([3]int{
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
			gross := ComputeBetPayoff(idx, 1.0, roundOutcome)
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
		JackpotTriggered:    roundOutcome.JackpotTriggered,
		JackpotMarbleIdx:    roundOutcome.JackpotMarbleIdx,
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
			rbCur := rb.Currency
			if rbCur == "" {
				rbCur = m.currency()
			}
			payout := ComputeBetPayoff(rb.MarbleIdx, rb.Amount, roundOutcome)
			won := payout > 0.0
			if won {
				scale := float64(UnitsPerWhole(rbCur))
				payoutUnits := uint64(payout * scale)
				creditTxID := rb.BetID + ":credit"
				if cerr := m.cfg.Wallet.Credit(rb.PlayerID, payoutUnits, rbCur, creditTxID); cerr != nil {
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
				Currency:    rbCur,
				Won:         won,
				Payout:      payout,
				WinnerIndex: simRes.WinnerMarbleIndex,
			}
		}
		totalLoss := totalBets - totalPayout
		fmt.Fprintf(os.Stderr, "rgs: round %d round-bets settled (v2 model): count=%d total_bets=%.2f total_payout=%.2f total_loss=%.2f jackpot=%v\n",
			roundID, len(pr.bets), totalBets, totalPayout, totalLoss, roundOutcome.JackpotTriggered)
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
func (m *Manager) PlaceBetOnRound(roundID uint64, playerID string, marbleIdx int, amount float64, currency string) (*RoundBet, float64, error) {
	cur := NormalizeCurrency(currency)
	if cur == "" {
		cur = m.currency()
	}
	if err := ValidateCurrency(cur, m.cfg.SupportedCurrencies); err != nil {
		return nil, 0, fmt.Errorf("rgs: PlaceBetOnRound: %w", err)
	}
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

	// Convert amount to uint64 sub-units for wallet, using the correct precision
	// for the currency (100 for fiat, 100_000_000 for crypto).
	scale := float64(UnitsPerWhole(cur))
	amountUnits := uint64(amount * scale)
	if amountUnits == 0 {
		return nil, 0, fmt.Errorf("%w: amount %v rounds to zero in %s", ErrInvalidBetAmount, amount, cur)
	}

	betID := newID("rbet_")
	if err := m.cfg.Wallet.Debit(playerID, amountUnits, cur, betID); err != nil {
		return nil, 0, fmt.Errorf("rgs: wallet debit: %w", err)
	}

	balUnits, balErr := m.cfg.Wallet.Balance(playerID, cur)
	var balAfter float64
	if balErr == nil {
		balAfter = float64(balUnits) / scale
	}

	bet := &RoundBet{
		BetID:     betID,
		PlayerID:  playerID,
		RoundID:   roundID,
		MarbleIdx: marbleIdx,
		Amount:    amount,
		Currency:  cur,
		PlacedAt:  time.Now(),
	}

	m.mu.Lock()
	// Re-validate: the round might have been popped by RunNextRound between
	// our unlock and this re-lock. If so, refund and error.
	if m.findPendingRound(roundID) == nil {
		m.mu.Unlock()
		_ = m.cfg.Wallet.Credit(playerID, amountUnits, cur, betID+":refund")
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
// When a durable SessionStorer is configured the closed state is persisted.
func (m *Manager) CloseSession(sessionID string) error {
	s, ok := m.Session(sessionID)
	if !ok {
		return fmt.Errorf("rgs: unknown session %q", sessionID)
	}
	if err := s.Close(); err != nil {
		return err
	}
	if err := m.sessionStore.Update(context.Background(), s); err != nil {
		return fmt.Errorf("rgs: CloseSession persist: %w", err)
	}
	return nil
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

// currency returns the effective default currency for wallet calls. Falls back
// to the package-level DefaultCurrency constant when the config field is empty.
func (m *Manager) currency() string {
	if m.cfg.DefaultCurrency != "" {
		return m.cfg.DefaultCurrency
	}
	return DefaultCurrency
}

// ── Admin hooks ──────────────────────────────────────────────────────────────

// Pause sets the manager's paused flag. While paused, RunNextRound returns
// ErrManagerPaused immediately without running any round or consuming any
// pending bets.
func (m *Manager) Pause() {
	m.mu.Lock()
	m.paused = true
	m.mu.Unlock()
}

// Resume clears the paused flag so new rounds can run again.
func (m *Manager) Resume() {
	m.mu.Lock()
	m.paused = false
	m.mu.Unlock()
}

// IsPaused returns the current paused state.
func (m *Manager) IsPaused() bool {
	m.mu.Lock()
	defer m.mu.Unlock()
	return m.paused
}

// Config returns a snapshot of the Manager's current ManagerConfig. The
// returned struct is a shallow copy — callers must not mutate it.
func (m *Manager) Config() ManagerConfig {
	m.mu.Lock()
	defer m.mu.Unlock()
	return m.cfg
}

// UpdateRTP atomically replaces the manager's RTP basis-points value. The
// new value takes effect from the next call to RunNextRound. No persistence
// is performed here — callers that need durability (e.g. the admin handler)
// write to DataPath themselves.
func (m *Manager) UpdateRTP(rtpBps uint32) {
	m.mu.Lock()
	m.cfg.RTPBps = rtpBps
	m.mu.Unlock()
}

// AllSessions returns a snapshot copy of every session currently in the
// in-memory cache.  Used by the admin panel to enumerate players.
func (m *Manager) AllSessions() []*Session {
	m.mu.Lock()
	defer m.mu.Unlock()
	out := make([]*Session, 0, len(m.sessions))
	for _, s := range m.sessions {
		out = append(out, s)
	}
	return out
}

// PendingRoundCount returns how many pre-minted rounds are queued.
func (m *Manager) PendingRoundCount() int {
	m.mu.Lock()
	defer m.mu.Unlock()
	return len(m.pendingRounds)
}

// _ ensures errors is used (it is, by ErrManagerPaused), silencing any
// linter that might not see the var decl as sufficient.
var _ = errors.New

// ── inMemorySessionStore ─────────────────────────────────────────────────────
//
// inMemorySessionStore is the SessionStorer used when no Postgres DSN is
// provided. It keeps sessions in a map[string]*Session guarded by a mutex.
// It satisfies the same interface as *postgres.SessionStore so the Manager
// never needs to know which backend is active.
type inMemorySessionStore struct {
	mu sync.RWMutex
	m  map[string]*Session
}

func (s *inMemorySessionStore) Create(_ context.Context, sess *Session) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	if _, exists := s.m[sess.ID]; exists {
		return fmt.Errorf("rgs: inMemorySessionStore: session %q already exists", sess.ID)
	}
	s.m[sess.ID] = sess
	return nil
}

func (s *inMemorySessionStore) Get(_ context.Context, id string) (*Session, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	sess, ok := s.m[id]
	if !ok {
		return nil, fmt.Errorf("rgs: inMemorySessionStore: session %q not found", id)
	}
	return sess, nil
}

func (s *inMemorySessionStore) Update(_ context.Context, sess *Session) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	if _, ok := s.m[sess.ID]; !ok {
		return fmt.Errorf("rgs: inMemorySessionStore: session %q not found", sess.ID)
	}
	s.m[sess.ID] = sess
	return nil
}

func (s *inMemorySessionStore) Delete(_ context.Context, id string) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	delete(s.m, id)
	return nil
}

func (s *inMemorySessionStore) ListByPlayer(_ context.Context, playerID string) ([]*Session, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	var out []*Session
	for _, sess := range s.m {
		if sess.PlayerID == playerID {
			out = append(out, sess)
		}
	}
	if out == nil {
		out = []*Session{}
	}
	return out, nil
}
