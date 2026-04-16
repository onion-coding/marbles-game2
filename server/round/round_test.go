package round

import (
	"crypto/sha256"
	"errors"
	"testing"
	"time"
)

func newTestRound(t *testing.T) (*Round, time.Time) {
	t.Helper()
	var seed [32]byte
	for i := range seed {
		seed[i] = byte(i)
	}
	now := time.Date(2026, 4, 16, 12, 0, 0, 0, time.UTC)
	return New(42, seed, 20, now), now
}

func TestCommitHashIsSHA256OfSeed(t *testing.T) {
	r, _ := newTestRound(t)
	var seed [32]byte
	for i := range seed {
		seed[i] = byte(i)
	}
	want := sha256.Sum256(seed[:])
	if r.CommitHash() != want {
		t.Fatalf("commit hash mismatch: got %x want %x", r.CommitHash(), want)
	}
}

func TestSeedNotRevealedBeforeSettle(t *testing.T) {
	r, now := newTestRound(t)
	if _, ok := r.RevealedSeed(); ok {
		t.Fatal("seed revealed in WAITING — must not be")
	}
	_ = r.OpenBuyIn(now)
	if _, ok := r.RevealedSeed(); ok {
		t.Fatal("seed revealed in BUY_IN — must not be")
	}
	_ = r.AddParticipant(Participant{Name: "alice"})
	_ = r.StartRace(now.Add(time.Second))
	if _, ok := r.RevealedSeed(); ok {
		t.Fatal("seed revealed in RACING — must not be")
	}
	_ = r.FinishRace(Result{WinnerIndex: 0, FinishedAt: now.Add(2 * time.Second)}, now.Add(2*time.Second))
	seed, ok := r.RevealedSeed()
	if !ok {
		t.Fatal("seed not revealed in SETTLE")
	}
	var want [32]byte
	for i := range want {
		want[i] = byte(i)
	}
	if seed != want {
		t.Fatalf("revealed seed wrong: got %x want %x", seed, want)
	}
}

func TestPhaseTransitionOrder(t *testing.T) {
	r, now := newTestRound(t)
	if r.Phase() != PhaseWaiting {
		t.Fatalf("initial phase: got %s want WAITING", r.Phase())
	}

	// Skipping BUY_IN is rejected.
	if err := r.StartRace(now); !errors.Is(err, ErrWrongPhase) {
		t.Fatalf("StartRace from WAITING: got %v want ErrWrongPhase", err)
	}

	_ = r.OpenBuyIn(now)
	if r.Phase() != PhaseBuyIn {
		t.Fatalf("phase after OpenBuyIn: got %s want BUY_IN", r.Phase())
	}

	// Opening twice is rejected.
	if err := r.OpenBuyIn(now); !errors.Is(err, ErrWrongPhase) {
		t.Fatalf("OpenBuyIn twice: got %v want ErrWrongPhase", err)
	}

	_ = r.AddParticipant(Participant{Name: "a"})
	_ = r.StartRace(now.Add(time.Second))
	if r.Phase() != PhaseRacing {
		t.Fatalf("phase after StartRace: got %s want RACING", r.Phase())
	}

	// Adding a participant after the race started is rejected.
	if err := r.AddParticipant(Participant{Name: "late"}); !errors.Is(err, ErrWrongPhase) {
		t.Fatalf("AddParticipant in RACING: got %v want ErrWrongPhase", err)
	}

	_ = r.FinishRace(Result{WinnerIndex: 0, FinishedAt: now.Add(2 * time.Second)}, now.Add(2*time.Second))
	if r.Phase() != PhaseSettle {
		t.Fatalf("phase after FinishRace: got %s want SETTLE", r.Phase())
	}
}

func TestAddParticipantAssignsIndexByJoinOrder(t *testing.T) {
	r, now := newTestRound(t)
	_ = r.OpenBuyIn(now)

	names := []string{"alice", "bob", "carol"}
	for _, n := range names {
		if err := r.AddParticipant(Participant{Name: n, ClientSeed: "seed-" + n, MarbleIndex: 999}); err != nil {
			t.Fatalf("AddParticipant(%q): %v", n, err)
		}
	}
	parts := r.Participants()
	if len(parts) != len(names) {
		t.Fatalf("participant count: got %d want %d", len(parts), len(names))
	}
	for i, p := range parts {
		if p.MarbleIndex != i {
			t.Errorf("participant %d: MarbleIndex got %d want %d", i, p.MarbleIndex, i)
		}
		if p.Name != names[i] {
			t.Errorf("participant %d: Name got %q want %q", i, p.Name, names[i])
		}
	}
}

func TestRoundFull(t *testing.T) {
	var seed [32]byte
	r := New(1, seed, 2, time.Now())
	_ = r.OpenBuyIn(r.PhaseStart())
	_ = r.AddParticipant(Participant{Name: "a"})
	_ = r.AddParticipant(Participant{Name: "b"})
	if err := r.AddParticipant(Participant{Name: "c"}); !errors.Is(err, ErrRoundFull) {
		t.Fatalf("3rd participant in cap=2: got %v want ErrRoundFull", err)
	}
}

func TestEmptyNameRejected(t *testing.T) {
	r, now := newTestRound(t)
	_ = r.OpenBuyIn(now)
	if err := r.AddParticipant(Participant{Name: ""}); !errors.Is(err, ErrEmptyName) {
		t.Fatalf("empty name: got %v want ErrEmptyName", err)
	}
}

func TestPhaseStartAdvancesMonotonically(t *testing.T) {
	r, now := newTestRound(t)
	_ = r.OpenBuyIn(now.Add(time.Second))
	if !r.PhaseStart().Equal(now.Add(time.Second)) {
		t.Fatalf("phase start: got %v want %v", r.PhaseStart(), now.Add(time.Second))
	}
	// Going backwards is rejected.
	if err := r.StartRace(now); !errors.Is(err, ErrTimeGoesBack) {
		t.Fatalf("backwards time: got %v want ErrTimeGoesBack", err)
	}
}

func TestFinishRaceRequiresNonZeroTime(t *testing.T) {
	r, now := newTestRound(t)
	_ = r.OpenBuyIn(now)
	_ = r.AddParticipant(Participant{Name: "a"})
	_ = r.StartRace(now.Add(time.Second))
	if err := r.FinishRace(Result{WinnerIndex: 0}, now.Add(2*time.Second)); !errors.Is(err, ErrResultMissing) {
		t.Fatalf("zero finish time: got %v want ErrResultMissing", err)
	}
}
