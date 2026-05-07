// Package postgres tests. These tests require a running Postgres instance.
//
// # Running locally
//
// Option A — Docker one-liner:
//
//	docker run --rm -p 5432:5432 \
//	  -e POSTGRES_USER=test -e POSTGRES_PASSWORD=test -e POSTGRES_DB=test \
//	  postgres:16-alpine
//
// Then export the DSN and run the tests:
//
//	export POSTGRES_TEST_DSN="postgres://test:test@localhost:5432/test?sslmode=disable"
//	go test ./postgres/...
//
// Option B — use the project's docker-compose stack:
//
//	make docker-up   # starts postgres:16-alpine on the configured POSTGRES_PORT (default 5432)
//	export POSTGRES_TEST_DSN="postgres://marbles:change-me-locally@localhost:5432/marbles?sslmode=disable"
//	go test ./postgres/...
//
// If POSTGRES_TEST_DSN is not set the tests are skipped automatically so
// the standard `go test ./...` run (no Postgres available) stays green.
package postgres_test

import (
	"context"
	"encoding/binary"
	"fmt"
	"os"
	"path/filepath"
	"sync"
	"testing"
	"time"

	"github.com/onion-coding/marbles-game2/server/postgres"
	"github.com/onion-coding/marbles-game2/server/replay"
	"github.com/onion-coding/marbles-game2/server/rgs"
	"github.com/onion-coding/marbles-game2/server/sim"
)

// ── fake sim (mirrors rgs/manager_test.go's fakeSim) ─────────────────────────

type fakeSim struct{ winnerIndex int }

func (f *fakeSim) Run(_ context.Context, req sim.Request) (sim.Result, error) {
	if err := os.MkdirAll(req.WorkDir, 0o755); err != nil {
		return sim.Result{}, err
	}
	path := filepath.Join(req.WorkDir, "replay.bin")
	if err := os.WriteFile(path, buildFakeReplay(req.RoundID, req.ServerSeed[:], req.TrackID, req.ClientSeeds), 0o644); err != nil {
		return sim.Result{}, err
	}
	return sim.Result{
		RoundID:            req.RoundID,
		WinnerMarbleIndex:  f.winnerIndex,
		FinishTick:         600,
		PickupTier1Marbles: nil,
		PickupTier2Marble:  -1,
		ProtocolVersion:    3,
		ReplayPath:         path,
		TickRateHz:         60,
	}, nil
}

func buildFakeReplay(roundID uint64, seed []byte, trackID uint8, clientSeeds []string) []byte {
	u32 := func(b []byte, v uint32) []byte {
		tmp := make([]byte, 4)
		binary.LittleEndian.PutUint32(tmp, v)
		return append(b, tmp...)
	}
	u64 := func(b []byte, v uint64) []byte {
		tmp := make([]byte, 8)
		binary.LittleEndian.PutUint64(tmp, v)
		return append(b, tmp...)
	}
	out := []byte{3} // protocol version
	out = u64(out, roundID)
	out = u32(out, 60) // tick_rate_hz
	out = append(out, byte(len(seed)))
	out = append(out, seed...)
	hash := make([]byte, 32)
	out = append(out, byte(len(hash)))
	out = append(out, hash...)
	out = u32(out, 32) // slot_count
	out = append(out, trackID)
	out = u32(out, uint32(len(clientSeeds)))
	for i, cs := range clientSeeds {
		out = u32(out, uint32(i))
		out = u32(out, 0)
		out = append(out, byte(len("filler")))
		out = append(out, []byte("filler")...)
		out = append(out, byte(len(cs)))
		out = append(out, cs...)
		out = u32(out, 0)
	}
	out = u32(out, 0) // frame_count
	return out
}

// newTestManagerWithStore creates a Manager backed by the given SessionStorer.
func newTestManagerWithStore(t *testing.T, winnerIndex int, store rgs.SessionStorer) (*rgs.Manager, *rgs.MockWallet, string) {
	t.Helper()
	dir := t.TempDir()
	replayStore, err := replay.New(filepath.Join(dir, "replays"))
	if err != nil {
		t.Fatalf("replay.New: %v", err)
	}
	wallet := rgs.NewMockWallet()
	fs := &fakeSim{winnerIndex: winnerIndex}
	mgr, err := rgs.NewManager(rgs.ManagerConfig{
		Wallet:       wallet,
		Store:        replayStore,
		Sim:          fs.Run,
		WorkRoot:     filepath.Join(dir, "work"),
		BuyIn:        100,
		RTPBps:       9500,
		MaxMarbles:   30,
		TrackPool:    []uint8{1, 2, 3, 4, 5, 6},
		SessionStore: store,
	})
	if err != nil {
		t.Fatalf("NewManager: %v", err)
	}
	return mgr, wallet, dir
}

// testDSN returns the test DSN or skips the test if none is configured.
func testDSN(t *testing.T) string {
	t.Helper()
	dsn := os.Getenv("POSTGRES_TEST_DSN")
	if dsn == "" {
		t.Skip("POSTGRES_TEST_DSN not set — skipping Postgres integration tests")
	}
	return dsn
}

// openStore applies migrations and returns a ready SessionStore. The store
// is closed via t.Cleanup.
func openStore(t *testing.T) *postgres.SessionStore {
	t.Helper()
	dsn := testDSN(t)
	ctx := context.Background()

	if err := postgres.RunMigrations(ctx, dsn); err != nil {
		t.Fatalf("RunMigrations: %v", err)
	}

	store, err := postgres.NewSessionStore(ctx, dsn)
	if err != nil {
		t.Fatalf("NewSessionStore: %v", err)
	}
	t.Cleanup(store.Close)
	return store
}

// newSess is a convenience helper that builds a fresh *rgs.Session without
// going through the Manager — we test the store in isolation here.
func newSess(playerID string) *rgs.Session {
	now := time.Now().UTC().Truncate(time.Microsecond) // Postgres stores µs
	return rgs.NewSessionRaw(
		fmt.Sprintf("sess_test_%d", now.UnixNano()),
		playerID,
		rgs.SessionOpen,
		now,
		now,
	)
}

// TestSessionStore_Create_Get_Update_Delete exercises the full CRUD cycle.
func TestSessionStore_Create_Get_Update_Delete(t *testing.T) {
	store := openStore(t)
	ctx := context.Background()

	sess := newSess("player_crud")

	// --- Create ---
	if err := store.Create(ctx, sess); err != nil {
		t.Fatalf("Create: %v", err)
	}

	// Duplicate create must error.
	if err := store.Create(ctx, sess); err == nil {
		t.Fatal("second Create on same id: expected error, got nil")
	}

	// --- Get ---
	got, err := store.Get(ctx, sess.ID)
	if err != nil {
		t.Fatalf("Get: %v", err)
	}
	if got.ID != sess.ID {
		t.Errorf("Get: id mismatch: got %q, want %q", got.ID, sess.ID)
	}
	if got.PlayerID != sess.PlayerID {
		t.Errorf("Get: player_id mismatch: got %q, want %q", got.PlayerID, sess.PlayerID)
	}
	if gotState, _, _ := got.Snapshot(); gotState != rgs.SessionOpen {
		t.Errorf("Get: state mismatch: got %v, want OPEN", gotState)
	}

	// --- Get missing ---
	_, err = store.Get(ctx, "sess_does_not_exist")
	if err == nil {
		t.Fatal("Get missing id: expected ErrNotFound, got nil")
	}

	// --- Update: attach a bet ---
	bet := rgs.Bet{
		BetID:       "bet_test_001",
		Amount:      500,
		PlayerID:    "player_crud",
		PlacedAt:    time.Now().UTC().Truncate(time.Microsecond),
		MarbleIndex: -1,
	}
	rgs.AttachBetRaw(sess, bet)
	// Manually set state to BET to simulate what session.PlaceBet would do.
	*sess = *rgs.NewSessionRaw(sess.ID, sess.PlayerID, rgs.SessionBet, sess.OpenedAt, time.Now().UTC().Truncate(time.Microsecond))
	rgs.AttachBetRaw(sess, bet)

	if err := store.Update(ctx, sess); err != nil {
		t.Fatalf("Update: %v", err)
	}

	got2, err := store.Get(ctx, sess.ID)
	if err != nil {
		t.Fatalf("Get after Update: %v", err)
	}
	state2, betGot, _ := got2.Snapshot()
	if state2 != rgs.SessionBet {
		t.Errorf("after Update: state = %v, want BET", state2)
	}
	if betGot == nil {
		t.Fatal("after Update: bet is nil, want non-nil")
	}
	if betGot.BetID != bet.BetID {
		t.Errorf("after Update: bet_id = %q, want %q", betGot.BetID, bet.BetID)
	}
	if betGot.Amount != bet.Amount {
		t.Errorf("after Update: amount = %d, want %d", betGot.Amount, bet.Amount)
	}

	// --- Delete ---
	if err := store.Delete(ctx, sess.ID); err != nil {
		t.Fatalf("Delete: %v", err)
	}

	// Deleting again (missing row) must be silent.
	if err := store.Delete(ctx, sess.ID); err != nil {
		t.Fatalf("Delete missing row: %v", err)
	}

	// Get after delete returns ErrNotFound.
	_, err = store.Get(ctx, sess.ID)
	if err == nil {
		t.Fatal("Get after Delete: expected ErrNotFound, got nil")
	}
}

// TestSessionStore_PlayerListing verifies ListByPlayer returns all sessions
// for a player and nothing for another.
func TestSessionStore_PlayerListing(t *testing.T) {
	store := openStore(t)
	ctx := context.Background()

	const player = "player_list"
	const other = "player_other"

	// Create 3 sessions for `player` and 1 for `other`.
	created := make([]*rgs.Session, 3)
	for i := range created {
		s := newSess(player)
		// Stagger the clock so ordering is deterministic.
		time.Sleep(time.Millisecond)
		if err := store.Create(ctx, s); err != nil {
			t.Fatalf("Create[%d]: %v", i, err)
		}
		created[i] = s
	}
	otherSess := newSess(other)
	if err := store.Create(ctx, otherSess); err != nil {
		t.Fatalf("Create other: %v", err)
	}
	t.Cleanup(func() {
		for _, s := range created {
			_ = store.Delete(ctx, s.ID)
		}
		_ = store.Delete(ctx, otherSess.ID)
	})

	list, err := store.ListByPlayer(ctx, player)
	if err != nil {
		t.Fatalf("ListByPlayer: %v", err)
	}
	if len(list) != 3 {
		t.Fatalf("ListByPlayer count = %d, want 3", len(list))
	}
	for _, s := range list {
		if s.PlayerID != player {
			t.Errorf("ListByPlayer: got player_id %q, want %q", s.PlayerID, player)
		}
	}

	// Player with no sessions → empty slice, not nil, no error.
	empty, err := store.ListByPlayer(ctx, "player_nobody")
	if err != nil {
		t.Fatalf("ListByPlayer empty: %v", err)
	}
	if len(empty) != 0 {
		t.Errorf("ListByPlayer empty: got %d, want 0", len(empty))
	}
}

// TestSessionStore_ConcurrentAccess fires 20 goroutines each creating,
// getting, and updating a distinct session. Verifies there are no data races
// (run with -race) and that all operations complete without error.
func TestSessionStore_ConcurrentAccess(t *testing.T) {
	store := openStore(t)
	ctx := context.Background()

	const n = 20
	var wg sync.WaitGroup
	errs := make([]error, n)

	for i := 0; i < n; i++ {
		wg.Add(1)
		go func(idx int) {
			defer wg.Done()
			s := newSess(fmt.Sprintf("concurrent_player_%d", idx))
			if err := store.Create(ctx, s); err != nil {
				errs[idx] = fmt.Errorf("Create: %w", err)
				return
			}
			defer func() { _ = store.Delete(ctx, s.ID) }()

			got, err := store.Get(ctx, s.ID)
			if err != nil {
				errs[idx] = fmt.Errorf("Get: %w", err)
				return
			}

			// Simulate a state transition: mark CLOSED.
			updated := rgs.NewSessionRaw(got.ID, got.PlayerID, rgs.SessionClosed,
				got.OpenedAt, time.Now().UTC().Truncate(time.Microsecond))
			if err := store.Update(ctx, updated); err != nil {
				errs[idx] = fmt.Errorf("Update: %w", err)
			}
		}(i)
	}
	wg.Wait()

	for i, err := range errs {
		if err != nil {
			t.Errorf("goroutine %d: %v", i, err)
		}
	}
}

// TestManager_PostgresSessionStore verifies that Manager wired with a
// *postgres.SessionStore has the same observable behaviour as the default
// in-memory path. Uses a real DB.
func TestManager_PostgresSessionStore(t *testing.T) {
	dsn := testDSN(t)
	ctx := context.Background()

	if err := postgres.RunMigrations(ctx, dsn); err != nil {
		t.Fatalf("RunMigrations: %v", err)
	}
	pgStore, err := postgres.NewSessionStore(ctx, dsn)
	if err != nil {
		t.Fatalf("NewSessionStore: %v", err)
	}
	defer pgStore.Close()

	// Build a Manager identical to the ones in manager_test.go but wired
	// with the Postgres session store.
	mgr, wallet, _ := newTestManagerWithStore(t, 0 /*winnerIndex*/, pgStore)
	wallet.SetBalance("pg_alice", 1000)

	// --- OpenSession ---
	sess, err := mgr.OpenSession("pg_alice")
	if err != nil {
		t.Fatalf("OpenSession: %v", err)
	}

	// Session must be retrievable.
	got, ok := mgr.Session(sess.ID)
	if !ok {
		t.Fatal("Session: not found after OpenSession")
	}
	if got.PlayerID != "pg_alice" {
		t.Errorf("Session: player_id = %q, want pg_alice", got.PlayerID)
	}

	// --- PlaceBet ---
	bet, err := mgr.PlaceBet(sess.ID, 100)
	if err != nil {
		t.Fatalf("PlaceBet: %v", err)
	}
	if bet.BetID == "" {
		t.Error("PlaceBet: empty BetID")
	}

	// State must be persisted to Postgres.
	persisted, err := pgStore.Get(ctx, sess.ID)
	if err != nil {
		t.Fatalf("pgStore.Get after PlaceBet: %v", err)
	}
	persistedState, persistedBet, _ := persisted.Snapshot()
	if persistedState != rgs.SessionBet {
		t.Errorf("persisted state = %v, want BET", persistedState)
	}
	if persistedBet == nil {
		t.Fatal("persisted bet is nil")
	}

	// --- RunNextRound (wins; marble 0 = our bettor) ---
	manifest, outcomes, _, err := mgr.RunNextRound(ctx)
	if err != nil {
		t.Fatalf("RunNextRound: %v", err)
	}
	if manifest.Winner.MarbleIndex != 0 {
		t.Errorf("winner index = %d, want 0", manifest.Winner.MarbleIndex)
	}
	if len(outcomes) != 1 || !outcomes[0].Won {
		t.Errorf("outcomes: %+v — expected 1 winning outcome", outcomes)
	}

	// --- CloseSession ---
	if err := mgr.CloseSession(sess.ID); err != nil {
		t.Fatalf("CloseSession: %v", err)
	}

	// Verify closed state is durable.
	closed, err := pgStore.Get(ctx, sess.ID)
	if err != nil {
		t.Fatalf("pgStore.Get after CloseSession: %v", err)
	}
	closedState, _, _ := closed.Snapshot()
	if closedState != rgs.SessionClosed {
		t.Errorf("closed state = %v, want CLOSED", closedState)
	}

	// Cleanup.
	_ = pgStore.Delete(ctx, sess.ID)
}
