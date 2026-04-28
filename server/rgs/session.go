package rgs

import (
	"errors"
	"fmt"
	"sync"
	"time"
)

// SessionState moves through these phases:
//
//	OPEN     → just created; no bet yet
//	BET      → operator placed a bet, debit succeeded; waiting for next round
//	RACING   → round started; bet locked in
//	SETTLED  → round complete; if winning, credit applied; bet cleared
//	CLOSED   → operator explicitly closed the session
//
// A new bet can be placed only from OPEN or SETTLED. Closing is allowed
// from any state but BET / RACING (must wait for settlement first to
// avoid orphaned funds).
type SessionState int

const (
	SessionOpen SessionState = iota
	SessionBet
	SessionRacing
	SessionSettled
	SessionClosed
)

func (s SessionState) String() string {
	switch s {
	case SessionOpen:
		return "OPEN"
	case SessionBet:
		return "BET"
	case SessionRacing:
		return "RACING"
	case SessionSettled:
		return "SETTLED"
	case SessionClosed:
		return "CLOSED"
	default:
		return fmt.Sprintf("UNKNOWN(%d)", int(s))
	}
}

var (
	ErrWrongState   = errors.New("session in wrong state")
	ErrBetExists    = errors.New("session already has a bet")
	ErrNoBet        = errors.New("session has no active bet")
	ErrSessionClosed = errors.New("session closed")
)

// Bet captures everything the operator committed for the upcoming round.
// MarbleIndex is assigned at race-start time when the participants list is
// finalised — see Manager.StartRace.
type Bet struct {
	BetID       string    // operator-supplied unique id, used as wallet txID
	Amount      uint64
	PlayerID    string
	PlacedAt    time.Time
	MarbleIndex int       // -1 until the race starts
}

// SettlementOutcome is what gets returned to the operator after the round.
// PrizeAmount is 0 for losing bets. The credit txID is the bet's id with
// a `:credit` suffix — operators can correlate it with their wallet logs.
type SettlementOutcome struct {
	BetID       string
	PlayerID    string
	Amount      uint64    // original stake
	Won         bool
	PrizeAmount uint64    // 0 if !Won
	WinnerIndex int       // marble that won (might or might not be ours)
	CreditTxID  string    // wallet txID used for the credit (empty if not won)
	SettledAt   time.Time
}

// Session is one player-bound view onto the rounds the server is running.
// One player can have multiple sessions; each session has at most one
// active bet at a time. Sessions are NOT shared across players (each
// holds exactly one PlayerID).
type Session struct {
	mu sync.Mutex

	ID         string
	PlayerID   string
	State      SessionState
	OpenedAt   time.Time
	UpdatedAt  time.Time
	Bet        *Bet               // nil unless State in {BET, RACING}
	LastResult *SettlementOutcome // populated on transition to SETTLED
}

// PlaceBet validates the state transition and records the bet (without
// touching the wallet — that's Manager.PlaceBet's job, this only owns
// session-state correctness).
func (s *Session) PlaceBet(bet Bet) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.State == SessionClosed {
		return ErrSessionClosed
	}
	if s.State != SessionOpen && s.State != SessionSettled {
		return fmt.Errorf("%w: PlaceBet requires OPEN or SETTLED, was %s", ErrWrongState, s.State)
	}
	if s.Bet != nil {
		return ErrBetExists
	}
	bet.MarbleIndex = -1
	s.Bet = &bet
	s.State = SessionBet
	s.UpdatedAt = time.Now()
	return nil
}

// AssignMarble is called by the manager when the race starts and the
// session's bet is locked into a specific marble_index slot.
func (s *Session) AssignMarble(index int) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.State != SessionBet {
		return fmt.Errorf("%w: AssignMarble requires BET, was %s", ErrWrongState, s.State)
	}
	if s.Bet == nil {
		return ErrNoBet
	}
	s.Bet.MarbleIndex = index
	s.State = SessionRacing
	s.UpdatedAt = time.Now()
	return nil
}

// Settle is the terminal transition for a bet. Records the outcome and
// frees the bet slot so the player can place another bet on a future
// round without opening a new session.
func (s *Session) Settle(outcome SettlementOutcome) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.State != SessionRacing {
		return fmt.Errorf("%w: Settle requires RACING, was %s", ErrWrongState, s.State)
	}
	s.LastResult = &outcome
	s.Bet = nil
	s.State = SessionSettled
	s.UpdatedAt = time.Now()
	return nil
}

// Close marks the session terminal. Reject if there's an unsettled bet
// — the operator must wait for race resolution to avoid orphaned funds.
func (s *Session) Close() error {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.State == SessionBet || s.State == SessionRacing {
		return fmt.Errorf("%w: cannot close while bet is %s", ErrWrongState, s.State)
	}
	s.State = SessionClosed
	s.UpdatedAt = time.Now()
	return nil
}

// Snapshot returns a copy of the public-facing session state so callers
// can inspect without holding the lock. Bet and LastResult are deep
// copied so future mutations don't leak.
func (s *Session) Snapshot() (state SessionState, bet *Bet, last *SettlementOutcome) {
	s.mu.Lock()
	defer s.mu.Unlock()
	state = s.State
	if s.Bet != nil {
		b := *s.Bet
		bet = &b
	}
	if s.LastResult != nil {
		o := *s.LastResult
		last = &o
	}
	return
}
