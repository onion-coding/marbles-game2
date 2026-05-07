package rgs

import (
	"context"
	"log/slog"
	"sync"
	"sync/atomic"
	"time"

	"github.com/onion-coding/marbles-game2/server/replay"
)

// SchedulerPhase describes what the scheduler loop is currently doing.
type SchedulerPhase string

const (
	// PhaseIdle is the initial state before the first round begins, and
	// also the transient state between BetWindow and round execution
	// when the scheduler is paused.
	PhaseIdle SchedulerPhase = "idle"

	// PhaseBetWindow is the window in which players may place bets against
	// the pre-minted round spec. Lasts BetWindowSec after GenerateRoundSpec.
	PhaseBetWindow SchedulerPhase = "bet_window"

	// PhaseRunning is active while RunNextRound is executing (sim + settle).
	PhaseRunning SchedulerPhase = "running"

	// PhaseCooldown is the pause between a completed round and the start of
	// the next bet window. Lasts BetweenRounds.
	PhaseCooldown SchedulerPhase = "cooldown"

	// PhaseStopped is set after Stop() has been called and the goroutine
	// has exited.
	PhaseStopped SchedulerPhase = "stopped"
)

// SchedulerConfig holds all the wiring needed to drive the Scheduler.
type SchedulerConfig struct {
	// Mgr is the Manager the scheduler will call GenerateRoundSpec /
	// RunNextRound on. Required.
	Mgr *Manager

	// BetWindowSec is how long the scheduler waits after minting a round
	// spec before triggering RunNextRound. During this window callers may
	// POST /v1/rounds/{round_id}/bets. Defaults to 10s.
	BetWindowSec time.Duration

	// BetweenRounds is the cooldown between a finished round and the next
	// bet-window open. Defaults to 5s.
	BetweenRounds time.Duration

	// Logger is the structured logger. When nil, slog.Default() is used.
	Logger *slog.Logger

	// OnRoundStarted is called (in the scheduler goroutine) immediately
	// after a round spec is minted. Safe to leave nil.
	OnRoundStarted func(roundID uint64, trackID uint8)

	// OnRoundFinished is called (in the scheduler goroutine) immediately
	// after RunNextRound returns successfully. Safe to leave nil.
	OnRoundFinished func(manifest *replay.Manifest, outcomes []SettlementOutcome)
}

// SchedulerStatus is the read-only view of the scheduler returned by Status().
type SchedulerStatus struct {
	// Enabled is always true when retrieved from a running Scheduler.
	Enabled bool `json:"enabled"`

	// Paused mirrors Manager.IsPaused().
	Paused bool `json:"paused"`

	// CurrentPhase is the scheduler loop's current phase.
	CurrentPhase SchedulerPhase `json:"current_phase"`

	// CurrentRoundID is the round_id of the spec minted for the current
	// bet window, or 0 when none is active.
	CurrentRoundID uint64 `json:"current_round_id"`

	// NextRoundAt is the time at which the next phase transition is
	// expected. Zero when stopped or unknown.
	NextRoundAt time.Time `json:"next_round_at"`
}

// Scheduler drives the round loop automatically. A single goroutine runs
// the state machine:
//
//	GenerateRoundSpec
//	   → sleep BetWindowSec     (bet window open — players place bets)
//	   → RunNextRound           (sim + settle)
//	   → sleep BetweenRounds    (cooldown)
//	   → repeat
//
// If Manager.IsPaused() returns true at any check point, the loop spins
// on a 200ms polling interval until the manager is resumed — the goroutine
// stays alive, no bets are lost.
//
// Stop() cancels the driving context; the goroutine exits cleanly after
// the current blocking call (sleep or RunNextRound) finishes.
type Scheduler struct {
	cfg    SchedulerConfig
	logger *slog.Logger

	// mutable phase state — guarded by mu
	mu             sync.Mutex
	phase          SchedulerPhase
	currentRoundID uint64
	nextRoundAt    time.Time

	// stop/done machinery
	cancel  context.CancelFunc
	stopped atomic.Bool
	done    chan struct{}
}

// NewScheduler constructs a Scheduler from cfg. The scheduler is dormant
// until Start() is called.
func NewScheduler(cfg SchedulerConfig) *Scheduler {
	if cfg.Mgr == nil {
		panic("rgs: SchedulerConfig.Mgr is required")
	}
	if cfg.BetWindowSec <= 0 {
		cfg.BetWindowSec = 10 * time.Second
	}
	if cfg.BetweenRounds <= 0 {
		cfg.BetweenRounds = 5 * time.Second
	}
	logger := cfg.Logger
	if logger == nil {
		logger = slog.Default()
	}
	return &Scheduler{
		cfg:    cfg,
		logger: logger,
		phase:  PhaseIdle,
		done:   make(chan struct{}),
	}
}

// Start launches the scheduler goroutine and blocks until ctx is
// cancelled (or Stop() is called). Callers that want fire-and-forget
// should run Start in their own goroutine.
//
// Returns nil when the scheduler exits cleanly (ctx done or Stop called).
// A non-nil error is returned only for programming mistakes (e.g. calling
// Start twice on the same Scheduler).
func (s *Scheduler) Start(ctx context.Context) error {
	// Derive a cancellable child context so Stop() can cancel us
	// independently from the parent.
	innerCtx, cancel := context.WithCancel(ctx)
	s.cancel = cancel

	go s.loop(innerCtx)

	// Block until the goroutine signals done.
	<-s.done
	return nil
}

// Stop signals the scheduler to stop and waits for the goroutine to exit.
// It is safe to call Stop more than once.
func (s *Scheduler) Stop() {
	if s.stopped.CompareAndSwap(false, true) {
		if s.cancel != nil {
			s.cancel()
		}
	}
	<-s.done
}

// Status returns a point-in-time snapshot of the scheduler state.
func (s *Scheduler) Status() SchedulerStatus {
	s.mu.Lock()
	defer s.mu.Unlock()
	return SchedulerStatus{
		Enabled:        true,
		Paused:         s.cfg.Mgr.IsPaused(),
		CurrentPhase:   s.phase,
		CurrentRoundID: s.currentRoundID,
		NextRoundAt:    s.nextRoundAt,
	}
}

// ── internal ─────────────────────────────────────────────────────────────────

// setPhase updates the mutable phase fields atomically. Called only from
// the loop goroutine, but reads happen from any goroutine via Status.
func (s *Scheduler) setPhase(phase SchedulerPhase, roundID uint64, nextAt time.Time) {
	s.mu.Lock()
	s.phase = phase
	s.currentRoundID = roundID
	s.nextRoundAt = nextAt
	s.mu.Unlock()
}

// loop is the scheduler goroutine. It runs until ctx is cancelled.
func (s *Scheduler) loop(ctx context.Context) {
	defer func() {
		s.setPhase(PhaseStopped, 0, time.Time{})
		close(s.done)
	}()

	for {
		// Respect pause: spin-poll until manager is resumed or ctx done.
		if !s.waitIfPaused(ctx) {
			return // ctx cancelled while waiting
		}

		// ── Phase 1: mint a round spec ────────────────────────────────────
		spec, err := s.cfg.Mgr.GenerateRoundSpec()
		if err != nil {
			s.logger.Error("scheduler: GenerateRoundSpec failed", "err", err)
			// Brief back-off so we don't spin on a persistent failure.
			if !s.sleepOrDone(ctx, time.Second) {
				return
			}
			continue
		}

		s.logger.Info("scheduler: bet window open",
			"round_id", spec.RoundID,
			"track_id", spec.TrackID,
			"duration", s.cfg.BetWindowSec)

		betWindowEnd := time.Now().Add(s.cfg.BetWindowSec)
		s.setPhase(PhaseBetWindow, spec.RoundID, betWindowEnd)

		if s.cfg.OnRoundStarted != nil {
			s.cfg.OnRoundStarted(spec.RoundID, spec.TrackID)
		}

		// ── Phase 2: wait for bet window ─────────────────────────────────
		if !s.sleepOrDone(ctx, s.cfg.BetWindowSec) {
			return
		}

		// Respect pause again after bet window — before we run the round.
		if !s.waitIfPaused(ctx) {
			return
		}

		// ── Phase 3: run the round ────────────────────────────────────────
		s.setPhase(PhaseRunning, spec.RoundID, time.Time{})
		s.logger.Info("scheduler: running round", "round_id", spec.RoundID)

		manifest, outcomes, _, err := s.cfg.Mgr.RunNextRound(ctx)
		if err != nil {
			s.logger.Error("scheduler: RunNextRound failed",
				"round_id", spec.RoundID, "err", err)
			// Fall through to cooldown so we don't storm-retry on a
			// persistent error (e.g. sim subprocess crash).
		} else {
			s.logger.Info("scheduler: round settled",
				"round_id", manifest.RoundID,
				"winner", manifest.Winner.MarbleIndex,
				"outcomes", len(outcomes))

			if s.cfg.OnRoundFinished != nil {
				s.cfg.OnRoundFinished(manifest, outcomes)
			}
		}

		// ── Phase 4: cooldown between rounds ─────────────────────────────
		cooldownEnd := time.Now().Add(s.cfg.BetweenRounds)
		s.setPhase(PhaseCooldown, 0, cooldownEnd)

		if !s.sleepOrDone(ctx, s.cfg.BetweenRounds) {
			return
		}
	}
}

// sleepOrDone sleeps for d, but returns false immediately if ctx is
// cancelled before the sleep expires. Returns true when the full sleep
// elapsed.
func (s *Scheduler) sleepOrDone(ctx context.Context, d time.Duration) bool {
	t := time.NewTimer(d)
	defer t.Stop()
	select {
	case <-t.C:
		return true
	case <-ctx.Done():
		return false
	}
}

// waitIfPaused blocks until Manager.IsPaused() returns false or ctx is
// cancelled. Returns false if ctx was cancelled; true if the manager is
// (or became) unpaused.
func (s *Scheduler) waitIfPaused(ctx context.Context) bool {
	for s.cfg.Mgr.IsPaused() {
		s.mu.Lock()
		s.phase = PhaseIdle
		s.mu.Unlock()

		if !s.sleepOrDone(ctx, 200*time.Millisecond) {
			return false
		}
	}
	return true
}
