// Package round implements the per-round state machine:
//
//	WAITING -> BUY_IN -> RACING -> SETTLE
//
// This package is intentionally pure: no timers, no goroutines, no I/O.
// A coordinator (see cmd/roundd) drives transitions by calling the methods
// below in response to wall-clock deadlines and events (sim completion, etc).
// Keeping it pure makes the state transitions trivially testable and keeps
// the "what the protocol does" concerns separate from "when it fires".
//
// The fairness guarantees (commit before buy-in closes, seed revealed only
// in SETTLE, participants locked before RACING) are enforced here — callers
// cannot skip or reorder phases, only request valid transitions. See
// docs/fairness.md for the protocol.
package round

import (
	"crypto/sha256"
	"errors"
	"fmt"
	"time"
)

type Phase int

const (
	PhaseWaiting Phase = iota
	PhaseBuyIn
	PhaseRacing
	PhaseSettle
)

func (p Phase) String() string {
	switch p {
	case PhaseWaiting:
		return "WAITING"
	case PhaseBuyIn:
		return "BUY_IN"
	case PhaseRacing:
		return "RACING"
	case PhaseSettle:
		return "SETTLE"
	}
	return fmt.Sprintf("Phase(%d)", int(p))
}

// Participant is one marble in the round. The server assigns MarbleIndex
// in the order participants join; ClientSeed is optional user-provided
// entropy mixed into that marble's hash (see docs/fairness.md).
type Participant struct {
	MarbleIndex int
	Name        string
	ClientSeed  string
}

// Result is written when the sim reports a finish.
type Result struct {
	WinnerIndex int
	FinishedAt  time.Time
}

// Round is the in-memory state for one race. Not safe for concurrent use
// — wrap it in the coordinator's single-goroutine loop.
type Round struct {
	ID uint64

	serverSeed     [32]byte
	serverSeedHash [32]byte

	phase      Phase
	phaseStart time.Time

	participants []Participant
	maxMarbles   int

	result   Result
	hasResult bool
}

// New creates a round in PhaseWaiting. The server_seed is supplied by the
// caller so seed management (generation, escrow, audit log) stays out of this
// package — we only own the lifecycle once the seed is committed.
func New(id uint64, serverSeed [32]byte, maxMarbles int, now time.Time) *Round {
	return &Round{
		ID:             id,
		serverSeed:     serverSeed,
		serverSeedHash: sha256.Sum256(serverSeed[:]),
		phase:          PhaseWaiting,
		phaseStart:     now,
		maxMarbles:     maxMarbles,
	}
}

// Phase reports the current phase.
func (r *Round) Phase() Phase { return r.phase }

// PhaseStart reports when the current phase started (for timer logic).
func (r *Round) PhaseStart() time.Time { return r.phaseStart }

// CommitHash is the public SHA-256(serverSeed). Safe to publish at any time
// — it's the whole point of the commit/reveal scheme.
func (r *Round) CommitHash() [32]byte { return r.serverSeedHash }

// Participants returns a copy of the participant list.
func (r *Round) Participants() []Participant {
	out := make([]Participant, len(r.participants))
	copy(out, r.participants)
	return out
}

// RevealedSeed returns the server seed — ONLY after SETTLE. Callers must
// check ok; returning the seed earlier would break the fairness protocol.
func (r *Round) RevealedSeed() (seed [32]byte, ok bool) {
	if r.phase != PhaseSettle {
		return [32]byte{}, false
	}
	return r.serverSeed, true
}

// Result returns the race result if one has been recorded.
func (r *Round) Result() (Result, bool) {
	return r.result, r.hasResult
}

var (
	ErrWrongPhase    = errors.New("round: wrong phase for this operation")
	ErrRoundFull     = errors.New("round: marble cap reached")
	ErrEmptyName     = errors.New("round: participant name required")
	ErrTimeGoesBack  = errors.New("round: now < phase start")
	ErrResultMissing = errors.New("round: finish race requires a result")
)

// OpenBuyIn transitions WAITING -> BUY_IN. Called once the WAITING timer
// elapses or immediately at startup.
func (r *Round) OpenBuyIn(now time.Time) error {
	if r.phase != PhaseWaiting {
		return fmt.Errorf("%w: OpenBuyIn requires WAITING, got %s", ErrWrongPhase, r.phase)
	}
	return r.advance(PhaseBuyIn, now)
}

// AddParticipant registers a marble. Only valid during BUY_IN.
// The MarbleIndex on the input is ignored and reassigned by join order to
// keep the fairness order invariant (see docs/fairness.md §Order invariant).
func (r *Round) AddParticipant(p Participant) error {
	if r.phase != PhaseBuyIn {
		return fmt.Errorf("%w: AddParticipant requires BUY_IN, got %s", ErrWrongPhase, r.phase)
	}
	if len(r.participants) >= r.maxMarbles {
		return ErrRoundFull
	}
	if p.Name == "" {
		return ErrEmptyName
	}
	p.MarbleIndex = len(r.participants)
	r.participants = append(r.participants, p)
	return nil
}

// StartRace transitions BUY_IN -> RACING and locks the participant list.
// The sim is launched by the caller after this returns; no participants
// can be added once the phase advances.
func (r *Round) StartRace(now time.Time) error {
	if r.phase != PhaseBuyIn {
		return fmt.Errorf("%w: StartRace requires BUY_IN, got %s", ErrWrongPhase, r.phase)
	}
	return r.advance(PhaseRacing, now)
}

// FinishRace transitions RACING -> SETTLE and records the result. Reveal
// of the server seed becomes legal once this returns (see RevealedSeed).
func (r *Round) FinishRace(result Result, now time.Time) error {
	if r.phase != PhaseRacing {
		return fmt.Errorf("%w: FinishRace requires RACING, got %s", ErrWrongPhase, r.phase)
	}
	if result.FinishedAt.IsZero() {
		return ErrResultMissing
	}
	r.result = result
	r.hasResult = true
	return r.advance(PhaseSettle, now)
}

func (r *Round) advance(next Phase, now time.Time) error {
	if now.Before(r.phaseStart) {
		return ErrTimeGoesBack
	}
	r.phase = next
	r.phaseStart = now
	return nil
}
