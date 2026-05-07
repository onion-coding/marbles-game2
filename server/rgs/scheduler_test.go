package rgs

import (
	"context"
	"errors"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/onion-coding/marbles-game2/server/replay"
)

// newTestScheduler builds a Scheduler wired to a test Manager with
// caller-supplied durations so tests can use very short windows.
func newTestScheduler(t *testing.T, betWindow, betweenRounds time.Duration, winnerIdx int) (*Scheduler, *Manager, *MockWallet) {
	t.Helper()
	mgr, wallet, _ := newTestManager(t, winnerIdx)
	sched := NewScheduler(SchedulerConfig{
		Mgr:           mgr,
		BetWindowSec:  betWindow,
		BetweenRounds: betweenRounds,
	})
	return sched, mgr, wallet
}

// runSchedulerBackground starts the scheduler in a goroutine and returns
// a stop function that cancels the context and waits for the goroutine.
func runSchedulerBackground(t *testing.T, sched *Scheduler) (stop func()) {
	t.Helper()
	ctx, cancel := context.WithCancel(context.Background())
	var wg sync.WaitGroup
	wg.Add(1)
	go func() {
		defer wg.Done()
		_ = sched.Start(ctx)
	}()
	stopped := false
	return func() {
		if !stopped {
			stopped = true
			cancel()
			wg.Wait()
		}
	}
}

// ─────────────────────────────────────────────────────────────────────────────

// TestScheduler_RunsRoundsContinuously verifies that the scheduler
// automatically runs multiple rounds back-to-back without any manual
// trigger. We count OnRoundFinished callbacks and assert >= 3 rounds.
func TestScheduler_RunsRoundsContinuously(t *testing.T) {
	const wantRounds = 3
	const betWindow = 30 * time.Millisecond
	const cooldown = 10 * time.Millisecond

	var (
		mu       sync.Mutex
		finished []uint64 // round_ids in completion order
	)

	sched, _, _ := newTestScheduler(t, betWindow, cooldown, 0)
	sched.cfg.OnRoundFinished = func(m *replay.Manifest, _ []SettlementOutcome) {
		mu.Lock()
		finished = append(finished, m.RoundID)
		mu.Unlock()
	}

	stop := runSchedulerBackground(t, sched)
	defer stop()

	deadline := time.Now().Add(5 * time.Second)
	for time.Now().Before(deadline) {
		mu.Lock()
		n := len(finished)
		mu.Unlock()
		if n >= wantRounds {
			break
		}
		time.Sleep(10 * time.Millisecond)
	}

	stop()

	mu.Lock()
	got := len(finished)
	ids := append([]uint64{}, finished...)
	mu.Unlock()

	if got < wantRounds {
		t.Fatalf("scheduler ran %d rounds, want >= %d", got, wantRounds)
	}

	// Verify each settled round_id appears exactly once.
	seen := make(map[uint64]struct{}, got)
	for _, id := range ids {
		if _, dup := seen[id]; dup {
			t.Fatalf("duplicate round_id %d in finished list", id)
		}
		seen[id] = struct{}{}
	}
}

// TestScheduler_RespectsPause verifies that while Manager.Pause() is
// active the scheduler does not start new rounds; after Manager.Resume()
// it resumes normally.
func TestScheduler_RespectsPause(t *testing.T) {
	const betWindow = 20 * time.Millisecond
	const cooldown = 10 * time.Millisecond

	var roundsRun atomic.Int32

	sched, mgr, _ := newTestScheduler(t, betWindow, cooldown, 0)
	sched.cfg.OnRoundFinished = func(_ *replay.Manifest, _ []SettlementOutcome) {
		roundsRun.Add(1)
	}

	// Pause BEFORE starting so the scheduler never runs a round while paused.
	mgr.Pause()

	stop := runSchedulerBackground(t, sched)
	defer stop()

	// Wait long enough that the scheduler would have completed at least one
	// round if it were not paused (betWindow+cooldown = 30ms; 200ms >> 6 cycles).
	time.Sleep(200 * time.Millisecond)

	if n := roundsRun.Load(); n != 0 {
		t.Fatalf("scheduler ran %d rounds while paused, want 0", n)
	}

	// Resume and expect at least one round to complete.
	mgr.Resume()

	deadline := time.Now().Add(3 * time.Second)
	for time.Now().Before(deadline) {
		if roundsRun.Load() >= 1 {
			break
		}
		time.Sleep(10 * time.Millisecond)
	}

	stop()

	if roundsRun.Load() < 1 {
		t.Fatal("scheduler ran no rounds after manager.Resume()")
	}
}

// TestScheduler_BetWindowAllowsBets verifies that a bet placed during the
// bet window is accepted, and that the same round_id is rejected with
// ErrRoundAlreadyRun after RunNextRound has consumed it.
func TestScheduler_BetWindowAllowsBets(t *testing.T) {
	// Long enough bet window to reliably place a bet before it closes.
	const betWindow = 300 * time.Millisecond
	const cooldown = 10 * time.Millisecond

	roundFinished := make(chan uint64, 1)

	sched, mgr, wallet := newTestScheduler(t, betWindow, cooldown, 2)
	wallet.SetBalance("testplayer", 100_000)

	var capturedRoundID atomic.Uint64
	sched.cfg.OnRoundStarted = func(roundID uint64, _ uint8) {
		capturedRoundID.CompareAndSwap(0, roundID) // capture first round only
	}
	sched.cfg.OnRoundFinished = func(m *replay.Manifest, _ []SettlementOutcome) {
		select {
		case roundFinished <- m.RoundID:
		default:
		}
	}

	stop := runSchedulerBackground(t, sched)
	defer stop()

	// Wait for the scheduler to open the first bet window.
	var roundID uint64
	deadline := time.Now().Add(2 * time.Second)
	for time.Now().Before(deadline) {
		if id := capturedRoundID.Load(); id != 0 {
			roundID = id
			break
		}
		time.Sleep(5 * time.Millisecond)
	}
	if roundID == 0 {
		t.Fatal("scheduler did not open a bet window within 2s")
	}

	// Place a bet DURING the bet window — must succeed.
	_, _, err := mgr.PlaceBetOnRound(roundID, "testplayer", 2, 1.0, "")
	if err != nil {
		t.Fatalf("PlaceBetOnRound during window: %v", err)
	}

	// Wait for the round to settle.
	select {
	case finID := <-roundFinished:
		if finID != roundID {
			t.Fatalf("finished round_id %d != opened round_id %d", finID, roundID)
		}
	case <-time.After(3 * time.Second):
		t.Fatal("round did not finish within 3s")
	}

	// Attempt to bet on the SAME round after it has run — must be refused.
	_, _, err = mgr.PlaceBetOnRound(roundID, "testplayer", 2, 1.0, "")
	if err == nil {
		t.Fatal("PlaceBetOnRound after round ran: expected error, got nil")
	}
	if !errors.Is(err, ErrRoundAlreadyRun) && !strings.Contains(err.Error(), ErrRoundAlreadyRun.Error()) {
		t.Fatalf("expected ErrRoundAlreadyRun, got: %v", err)
	}

	stop()
}

// TestScheduler_GracefulStop verifies that cancelling the context (or
// calling Stop()) causes Start() to return promptly and the phase
// transitions to PhaseStopped.
func TestScheduler_GracefulStop(t *testing.T) {
	const betWindow = 50 * time.Millisecond
	const cooldown = 50 * time.Millisecond

	sched, _, _ := newTestScheduler(t, betWindow, cooldown, 0)

	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan struct{})
	go func() {
		defer close(done)
		_ = sched.Start(ctx)
	}()

	// Let the scheduler run at least one complete cycle.
	time.Sleep(200 * time.Millisecond)

	// Cancel the context — Start should return promptly.
	cancel()

	select {
	case <-done:
		// scheduler exited cleanly
	case <-time.After(3 * time.Second):
		t.Fatal("scheduler did not stop within 3s after context cancellation")
	}

	if sched.Status().CurrentPhase != PhaseStopped {
		t.Fatalf("phase after stop = %q, want %q",
			sched.Status().CurrentPhase, PhaseStopped)
	}
}

// TestScheduler_StatusReflectsPhase is a lightweight smoke-test that
// Status() returns sensible data while the scheduler is live.
func TestScheduler_StatusReflectsPhase(t *testing.T) {
	const betWindow = 150 * time.Millisecond
	const cooldown = 50 * time.Millisecond

	sched, _, _ := newTestScheduler(t, betWindow, cooldown, 0)

	// Before start: phase is idle.
	if st := sched.Status(); st.CurrentPhase != PhaseIdle {
		t.Fatalf("initial phase %q, want %q", st.CurrentPhase, PhaseIdle)
	}

	stop := runSchedulerBackground(t, sched)
	defer stop()

	// Scheduler should enter PhaseBetWindow shortly after starting.
	deadline := time.Now().Add(2 * time.Second)
	var sawBetWindow bool
	for time.Now().Before(deadline) {
		if sched.Status().CurrentPhase == PhaseBetWindow {
			sawBetWindow = true
			break
		}
		time.Sleep(5 * time.Millisecond)
	}
	if !sawBetWindow {
		t.Fatalf("never observed PhaseBetWindow within 2s")
	}

	st := sched.Status()
	if !st.Enabled {
		t.Fatal("Status().Enabled = false, want true")
	}
	if st.CurrentRoundID == 0 {
		t.Fatal("Status().CurrentRoundID = 0 during bet window")
	}
	if st.NextRoundAt.IsZero() {
		t.Fatal("Status().NextRoundAt is zero during bet window")
	}

	stop()
}

// TestScheduler_DefaultConfig verifies that zero-value durations in
// SchedulerConfig are replaced with the documented defaults (10s / 5s).
func TestScheduler_DefaultConfig(t *testing.T) {
	mgr, _, _ := newTestManager(t, 0)
	sched := NewScheduler(SchedulerConfig{
		Mgr:           mgr,
		BetWindowSec:  0, // should default to 10s
		BetweenRounds: 0, // should default to 5s
	})
	if sched.cfg.BetWindowSec != 10*time.Second {
		t.Fatalf("default BetWindowSec = %v, want 10s", sched.cfg.BetWindowSec)
	}
	if sched.cfg.BetweenRounds != 5*time.Second {
		t.Fatalf("default BetweenRounds = %v, want 5s", sched.cfg.BetweenRounds)
	}
}
