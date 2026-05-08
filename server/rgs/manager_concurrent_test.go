package rgs

// Tests for multi-round concurrency (M9.6).
//
// Coverage:
//   - TestManager_ConcurrentRounds        — 4 rounds in parallel, no cross-contamination
//   - TestManager_RunRoundIdempotent       — duplicate call returns cached outcome
//   - TestManager_RunRoundInFlight         — concurrent duplicate call → ErrRoundInFlight
//   - TestManager_RunRoundUnknown          — unknown round_id → ErrUnknownRound
//   - TestManager_RunRoundAlreadyRun       — post-settlement cached call returns outcome
//   - TestManager_MaxConcurrentRounds      — concurrency cap is enforced
//   - TestScheduler_OverlappingRounds      — scheduler overlap=2 keeps ≥2 rounds in flight
//   - BenchmarkManager_ConcurrentSettlement— N goroutines run RunRound in parallel

import (
	"context"
	"errors"
	"fmt"
	"path/filepath"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/onion-coding/marbles-game2/server/replay"
	"github.com/onion-coding/marbles-game2/server/sim"
)

// ── shared helpers ────────────────────────────────────────────────────────────

// newConcurrentTestManager builds a Manager wired with the standard fakeSim
// and a configurable MaxConcurrentRounds.
func newConcurrentTestManager(tb testing.TB, winnerIndex, maxConcurrent int) (*Manager, *MockWallet) {
	tb.Helper()
	dir := tb.TempDir()
	store, err := replay.New(filepath.Join(dir, "replays"))
	if err != nil {
		tb.Fatalf("replay.New: %v", err)
	}
	wallet := NewMockWallet()
	fs := &fakeSim{winnerIndex: winnerIndex, finishTick: 600}
	mgr, err := NewManager(ManagerConfig{
		Wallet:              wallet,
		Store:               store,
		Sim:                 fs.Run,
		WorkRoot:            filepath.Join(dir, "work"),
		BuyIn:               100,
		RTPBps:              9500,
		MaxMarbles:          30,
		TrackPool:           []uint8{1, 2, 3, 4, 5, 6},
		MaxConcurrentRounds: maxConcurrent,
	})
	if err != nil {
		tb.Fatalf("NewManager: %v", err)
	}
	return mgr, wallet
}

// newBlockingSimManager returns a Manager whose sim blocks until `released` is
// closed, signalling `simEntered` on the first invocation.
func newBlockingSimManager(t *testing.T, released <-chan struct{}, simEntered chan<- struct{}) (*Manager, *MockWallet) {
	t.Helper()
	dir := t.TempDir()
	store, err := replay.New(filepath.Join(dir, "replays"))
	if err != nil {
		t.Fatalf("replay.New: %v", err)
	}
	wallet := NewMockWallet()
	fs := &fakeSim{winnerIndex: 0, finishTick: 600}
	var once sync.Once

	blockingSim := SimRunner(func(ctx context.Context, req sim.Request) (sim.Result, error) {
		once.Do(func() {
			select {
			case simEntered <- struct{}{}:
			default:
			}
		})
		// Block until released or context cancelled.
		select {
		case <-released:
		case <-ctx.Done():
			return sim.Result{}, ctx.Err()
		}
		// After release, delegate to the fake sim for a valid result.
		return fs.Run(ctx, req)
	})

	mgr, err := NewManager(ManagerConfig{
		Wallet:              wallet,
		Store:               store,
		Sim:                 blockingSim,
		WorkRoot:            filepath.Join(dir, "work"),
		BuyIn:               100,
		RTPBps:              9500,
		MaxMarbles:          30,
		TrackPool:           []uint8{1, 2, 3, 4, 5, 6},
		MaxConcurrentRounds: 4,
	})
	if err != nil {
		t.Fatalf("NewManager: %v", err)
	}
	return mgr, wallet
}

// concurrentPlayerName returns a predictable player id for index i.
func concurrentPlayerName(i int) string {
	return fmt.Sprintf("concplayer_%02d", i)
}

// ── tests ─────────────────────────────────────────────────────────────────────

// TestManager_ConcurrentRounds mints 4 rounds, seeds 4 players betting on the
// winning marble, and executes all rounds concurrently via RunRound.
// Verifies no cross-contamination and that each player receives exactly the
// correct credit.
func TestManager_ConcurrentRounds(t *testing.T) {
	const n = 4
	mgr, wallet := newConcurrentTestManager(t, 0, n) // marble 0 wins

	for i := 0; i < n; i++ {
		wallet.SetBalance(concurrentPlayerName(i), 10_000)
	}

	specs := make([]*RoundSpec, n)
	for i := 0; i < n; i++ {
		spec, err := mgr.GenerateRoundSpec()
		if err != nil {
			t.Fatalf("GenerateRoundSpec %d: %v", i, err)
		}
		specs[i] = spec
		if _, _, err := mgr.PlaceBetOnRound(spec.RoundID, concurrentPlayerName(i), 0, 10.0, ""); err != nil {
			t.Fatalf("PlaceBetOnRound %d: %v", i, err)
		}
		// Small sleep so time.Now().UnixNano() produces distinct round IDs on
		// fast machines where nanosecond resolution is coarser than the loop.
		time.Sleep(time.Millisecond)
	}

	type result struct {
		manifest *replay.Manifest
		err      error
	}
	results := make([]result, n)
	var wg sync.WaitGroup
	for i := 0; i < n; i++ {
		i := i
		wg.Add(1)
		go func() {
			defer wg.Done()
			m, _, _, err := mgr.RunRound(context.Background(), specs[i].RoundID)
			results[i] = result{m, err}
		}()
	}
	wg.Wait()

	// All 4 rounds settled without error, with distinct round_ids.
	seen := make(map[uint64]bool, n)
	for i, res := range results {
		if res.err != nil {
			t.Errorf("round %d error: %v", i, res.err)
			continue
		}
		if res.manifest == nil {
			t.Errorf("round %d: nil manifest", i)
			continue
		}
		if res.manifest.RoundID != specs[i].RoundID {
			t.Errorf("round %d: manifest.RoundID %d != spec.RoundID %d",
				i, res.manifest.RoundID, specs[i].RoundID)
		}
		if seen[res.manifest.RoundID] {
			t.Errorf("duplicate round_id %d", res.manifest.RoundID)
		}
		seen[res.manifest.RoundID] = true
	}

	// Each player bet 10.0 on marble 0 (winner). Payout = 10 × PodiumPayout1st.
	// wallet: 10_000 − 1_000 + payout_units.
	payoutUnits := uint64(10.0 * PodiumPayout1st * 100) // 100 units/EUR
	wantBal := uint64(10_000) - 1_000 + payoutUnits
	for i := 0; i < n; i++ {
		pid := concurrentPlayerName(i)
		bal, err := wallet.Balance(pid, DefaultCurrency)
		if err != nil {
			t.Errorf("Balance(%s): %v", pid, err)
			continue
		}
		if bal != wantBal {
			t.Errorf("player %s balance %d, want %d", pid, bal, wantBal)
		}
	}
}

// TestManager_RunRoundIdempotent calls RunRound twice on the same settled
// round_id. The second call must return the cached outcome without re-running
// the sim or double-crediting the wallet.
func TestManager_RunRoundIdempotent(t *testing.T) {
	mgr, wallet := newConcurrentTestManager(t, 3, 4) // marble 3 wins
	wallet.SetBalance("alice", 10_000)

	spec, err := mgr.GenerateRoundSpec()
	if err != nil {
		t.Fatalf("GenerateRoundSpec: %v", err)
	}
	if _, _, err := mgr.PlaceBetOnRound(spec.RoundID, "alice", 3, 5.0, ""); err != nil {
		t.Fatalf("PlaceBetOnRound: %v", err)
	}

	// First call — executes the round.
	m1, _, rbo1, err := mgr.RunRound(context.Background(), spec.RoundID)
	if err != nil {
		t.Fatalf("RunRound (first): %v", err)
	}

	// Second call on same round_id — must return cached outcome (no re-sim).
	m2, _, rbo2, err := mgr.RunRound(context.Background(), spec.RoundID)
	if err != nil {
		t.Fatalf("RunRound (second/cached): %v", err)
	}

	if m1.RoundID != m2.RoundID {
		t.Errorf("manifest RoundID mismatch: %d vs %d", m1.RoundID, m2.RoundID)
	}
	if m1.ServerSeedHex != m2.ServerSeedHex {
		t.Errorf("manifest ServerSeedHex mismatch")
	}
	if len(rbo1) != len(rbo2) {
		t.Errorf("roundBetOutcomes length: %d vs %d", len(rbo1), len(rbo2))
	}

	// Wallet must not have been credited twice.
	// alice: 10_000 − 500 (5.0 × 100) + payout (5.0 × PodiumPayout1st × 100).
	payoutUnits := uint64(5.0 * PodiumPayout1st * 100)
	wantBal := uint64(10_000) - 500 + payoutUnits
	bal, _ := wallet.Balance("alice", DefaultCurrency)
	if bal != wantBal {
		t.Errorf("balance %d, want %d (second call must not double-credit)", bal, wantBal)
	}
}

// TestManager_RunRoundInFlight verifies that a second concurrent call to
// RunRound on a round_id that is already executing returns ErrRoundInFlight.
func TestManager_RunRoundInFlight(t *testing.T) {
	released := make(chan struct{})
	simEntered := make(chan struct{}, 1)
	mgr, wallet := newBlockingSimManager(t, released, simEntered)
	wallet.SetBalance("bob", 10_000)

	spec, _ := mgr.GenerateRoundSpec()
	if _, _, err := mgr.PlaceBetOnRound(spec.RoundID, "bob", 0, 1.0, ""); err != nil {
		t.Fatalf("PlaceBetOnRound: %v", err)
	}

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	// Start first RunRound in background — will block in sim.
	firstDone := make(chan error, 1)
	go func() {
		_, _, _, err := mgr.RunRound(ctx, spec.RoundID)
		firstDone <- err
	}()

	// Wait until sim is entered (round is now in-flight).
	select {
	case <-simEntered:
	case <-time.After(3 * time.Second):
		t.Fatal("sim not entered within 3s")
	}

	// Second call on same round_id must return ErrRoundInFlight.
	_, _, _, err := mgr.RunRound(ctx, spec.RoundID)
	if !errors.Is(err, ErrRoundInFlight) {
		t.Errorf("second RunRound: got %v, want ErrRoundInFlight", err)
	}

	// Release the sim so the first goroutine can finish cleanly.
	close(released)
	if err := <-firstDone; err != nil && !errors.Is(err, context.DeadlineExceeded) {
		// Context cancellation is acceptable if the deadline fires; the only
		// thing we required was ErrRoundInFlight on the duplicate.
		t.Logf("first RunRound returned: %v (acceptable)", err)
	}
}

// TestManager_RunRoundUnknown verifies ErrUnknownRound for a round_id that
// was never minted by GenerateRoundSpec.
func TestManager_RunRoundUnknown(t *testing.T) {
	mgr, _ := newConcurrentTestManager(t, 0, 4)
	_, _, _, err := mgr.RunRound(context.Background(), 999_999_999_001)
	if !errors.Is(err, ErrUnknownRound) {
		t.Errorf("got %v, want ErrUnknownRound", err)
	}
}

// TestManager_RunRoundAlreadyRun confirms that after a round settles, a
// second RunRound call returns the cached result (not an error), because the
// Manager retains inFlightRounds entries after completion for idempotency.
func TestManager_RunRoundAlreadyRun(t *testing.T) {
	mgr, wallet := newConcurrentTestManager(t, 2, 4)
	wallet.SetBalance("carol", 5_000)

	spec, _ := mgr.GenerateRoundSpec()
	if _, _, err := mgr.PlaceBetOnRound(spec.RoundID, "carol", 2, 1.0, ""); err != nil {
		t.Fatalf("PlaceBetOnRound: %v", err)
	}

	// First run — OK.
	m1, _, _, err := mgr.RunRound(context.Background(), spec.RoundID)
	if err != nil {
		t.Fatalf("first RunRound: %v", err)
	}

	// Second call — returns cached (done=true) result.
	m2, _, _, err := mgr.RunRound(context.Background(), spec.RoundID)
	if err != nil {
		t.Errorf("second RunRound: got %v, want nil (cached)", err)
	}
	if m1.RoundID != m2.RoundID {
		t.Errorf("cached manifest RoundID mismatch")
	}
}

// TestManager_MaxConcurrentRounds verifies that when MaxConcurrentRounds=1
// and one round is already in flight, a RunRound call for a second distinct
// round_id returns ErrMaxConcurrentRounds.
func TestManager_MaxConcurrentRounds(t *testing.T) {
	released := make(chan struct{})
	simEntered := make(chan struct{}, 1)
	mgr, wallet := newBlockingSimManager(t, released, simEntered)
	mgr.cfg.MaxConcurrentRounds = 1
	wallet.SetBalance("dave", 10_000)

	spec1, _ := mgr.GenerateRoundSpec()
	time.Sleep(time.Millisecond) // ensure distinct round IDs on fast machines
	spec2, _ := mgr.GenerateRoundSpec()
	if _, _, err := mgr.PlaceBetOnRound(spec1.RoundID, "dave", 0, 1.0, ""); err != nil {
		t.Fatalf("PlaceBetOnRound spec1: %v", err)
	}

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	// Round 1 in background — will block in sim.
	done1 := make(chan error, 1)
	go func() {
		_, _, _, err := mgr.RunRound(ctx, spec1.RoundID)
		done1 <- err
	}()

	// Wait for sim to be entered.
	select {
	case <-simEntered:
	case <-time.After(3 * time.Second):
		t.Fatal("sim not entered within 3s")
	}

	// Round 2 must fail because the cap is 1.
	_, _, _, err := mgr.RunRound(ctx, spec2.RoundID)
	if !errors.Is(err, ErrMaxConcurrentRounds) {
		t.Errorf("got %v, want ErrMaxConcurrentRounds", err)
	}

	// Release so round 1 finishes.
	close(released)
	<-done1
}

// TestScheduler_OverlappingRounds verifies that with OverlapRounds=2 the
// scheduler concurrently executes at least 2 rounds simultaneously (measured
// as the peak in-flight count between OnRoundStarted and OnRoundFinished).
func TestScheduler_OverlappingRounds(t *testing.T) {
	const betWindow = 40 * time.Millisecond
	const cooldown = 5 * time.Millisecond
	const wantMinOverlap = 2
	const wantRounds = 4

	var (
		mu           sync.Mutex
		inFlight     int
		peakInFlight int
		finishedIDs  []uint64
	)

	mgr, _, _ := newTestManager(t, 0)

	sched := NewScheduler(SchedulerConfig{
		Mgr:           mgr,
		BetWindowSec:  betWindow,
		BetweenRounds: cooldown,
		OverlapRounds: wantMinOverlap,
		OnRoundStarted: func(roundID uint64, _ uint8) {
			mu.Lock()
			inFlight++
			if inFlight > peakInFlight {
				peakInFlight = inFlight
			}
			mu.Unlock()
		},
		OnRoundFinished: func(m *replay.Manifest, _ []SettlementOutcome) {
			mu.Lock()
			inFlight--
			finishedIDs = append(finishedIDs, m.RoundID)
			mu.Unlock()
		},
	})

	ctx, cancel := context.WithCancel(context.Background())
	var wg sync.WaitGroup
	wg.Add(1)
	go func() {
		defer wg.Done()
		_ = sched.Start(ctx)
	}()

	deadline := time.Now().Add(10 * time.Second)
	for time.Now().Before(deadline) {
		mu.Lock()
		n := len(finishedIDs)
		mu.Unlock()
		if n >= wantRounds {
			break
		}
		time.Sleep(10 * time.Millisecond)
	}
	cancel()
	wg.Wait()

	mu.Lock()
	peak := peakInFlight
	got := len(finishedIDs)
	ids := append([]uint64{}, finishedIDs...)
	mu.Unlock()

	if got < wantRounds {
		t.Fatalf("%d rounds finished, want >= %d", got, wantRounds)
	}
	if peak < wantMinOverlap {
		t.Fatalf("peak concurrent in-flight = %d, want >= %d (overlap not observed)", peak, wantMinOverlap)
	}

	// Each round_id must be unique in the finished list.
	seen := make(map[uint64]bool, len(ids))
	for _, id := range ids {
		if seen[id] {
			t.Errorf("duplicate round_id %d in finished list", id)
		}
		seen[id] = true
	}
}

// BenchmarkManager_ConcurrentSettlement runs N goroutines each spinning
// through GenerateRoundSpec → PlaceBetOnRound → RunRound in parallel. The
// sim is the cheap in-memory fakeSim, so the bottleneck is Manager lock
// contention and bookkeeping.
//
// Each goroutine uses its own dedicated wallet player to avoid cross-goroutine
// wallet contention and to prevent the bench from being gated by shared state.
// Specs are generated sequentially inside each goroutine — there is no shared
// GenerateRoundSpec contention — so this stresses the RunRound concurrent
// execution path.
func BenchmarkManager_ConcurrentSettlement(b *testing.B) {
	mgr, wallet := newConcurrentTestManager(b, 0, 16)

	// Pre-fund enough players for GOMAXPROCS goroutines.
	const maxGoroutines = 64
	for i := 0; i < maxGoroutines; i++ {
		wallet.SetBalance(fmt.Sprintf("bench_%d", i), 1_000_000_000)
	}

	var goroutineID atomic.Int32

	b.ResetTimer()
	b.RunParallel(func(pb *testing.PB) {
		id := int(goroutineID.Add(1) - 1)
		player := fmt.Sprintf("bench_%d", id%maxGoroutines)
		for pb.Next() {
			spec, err := mgr.GenerateRoundSpec()
			if err != nil {
				b.Errorf("GenerateRoundSpec: %v", err)
				return
			}
			if _, _, err := mgr.PlaceBetOnRound(spec.RoundID, player, 0, 1.0, ""); err != nil {
				// ErrInsufficientFunds shouldn't happen at this balance, but
				// skip rather than failing the bench if it does.
				continue
			}
			if _, _, _, err := mgr.RunRound(b.Context(), spec.RoundID); err != nil {
				// ErrRoundInFlight can occur if two goroutines somehow land on
				// the same round_id (nano-timestamp collision). Skip rather than
				// failing — the point is throughput, not 100% success rate.
				if errors.Is(err, ErrRoundInFlight) || errors.Is(err, ErrRoundAlreadyRun) {
					continue
				}
				b.Errorf("RunRound: %v", err)
			}
		}
	})
}

