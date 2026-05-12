// Package rgs — Responsible Gambling scaffolding.
//
// This file implements the RGService interface that enforces player-protection
// limits required by regulated jurisdictions (UKGC, MGA, Spain DGOJ, Italy
// ADM, Germany GlüNeuRStV). Operators configure limits via the /v1/players/*
// endpoints; the Manager enforces them before every wallet debit.
//
// Architecture
//
//   - RGLimits is the canonical per-player limit record (deposit/loss caps,
//     session timer, reality-check frequency, self-exclusion, cooling-off).
//   - RGService is the interface; InMemoryRGService is the default impl.
//     A Postgres-backed impl can be wired by satisfying the same interface.
//   - CheckCanBet is called by PlaceBet / PlaceBetOnRound before any wallet
//     debit. It evaluates all relevant limits and returns an RGCheck.
//   - RecordSession / SelfExclude / SetCoolingOff update stored state.
//   - InMemoryRGService is safe for concurrent calls (sync.RWMutex).
//
// Open items (see docs/rgs-integration.md)
//   - Real GamStop (UK) integration — need TLS client cert + national
//     exclusion API call in SelfExclude or a separate reconciliation job.
//   - DGOJ (Spain) exclusion register API.
//   - Postgres-backed impl: satisfied via NewPostgresRGService (M9.x).
//   - Rolling-window loss accumulator: current impl is a naive per-day
//     accumulator; a sliding 24h window is more accurate but requires
//     a sorted event log per player.
//   - Reality-check delivery: RGLimits.RealityCheckMin is stored and
//     returned in session responses so the browser SDK can pop the modal;
//     no server-push yet.

package rgs

import (
	"errors"
	"fmt"
	"sync"
	"time"
)

// ErrRGLimitReached is returned by CheckCanBet when a player-protection
// limit blocks the bet. Callers map this to HTTP 403 Forbidden.
var ErrRGLimitReached = errors.New("rg limit reached")

// ErrRGIncreaseDenied is returned by SetLimits when the caller tries to
// relax a limit (increase a cap or clear an exclusion). Relaxation requires
// operator approval via the admin override endpoint.
var ErrRGIncreaseDenied = errors.New("rg limit increase denied: operator approval required")

// RGLimits captures all responsible-gambling settings for a single player.
// Zero values mean "no limit" for cap fields, zero Time for exclusion fields
// means "not excluded". All monetary amounts are in the smallest denomination
// of the operator's reporting currency (typically cents = EUR×100).
type RGLimits struct {
	PlayerID string `json:"player_id"`

	// Deposit caps (0 = no cap).
	DepositDailyMax  uint64 `json:"deposit_daily_max"`
	DepositWeeklyMax uint64 `json:"deposit_weekly_max"`
	DepositMonthMax  uint64 `json:"deposit_monthly_max"`

	// Net loss caps (0 = no cap). Net loss = sum of debits − sum of credits
	// in the rolling window.
	LossDailyMax  uint64 `json:"loss_daily_max"`
	LossWeeklyMax uint64 `json:"loss_weekly_max"`
	LossMonthMax  uint64 `json:"loss_monthly_max"`

	// SessionTimeoutMin: hard close after this many minutes of continuous
	// play. 0 = no forced timeout.
	SessionTimeoutMin int `json:"session_timeout_min"`

	// RealityCheckMin: the operator's SDK should pop a "you've been playing
	// for N minutes" modal every RealityCheckMin minutes. Display-only —
	// no server-side enforcement beyond recording the setting.
	RealityCheckMin int `json:"reality_check_min"`

	// SelfExcludedUntil: if non-zero and in the future, all bets are blocked.
	SelfExcludedUntil time.Time `json:"self_excluded_until,omitempty"`

	// CoolingOffUntil: shorter mandatory break (hours vs months). Same
	// bet-block semantics as self-exclusion but operator can lift it.
	CoolingOffUntil time.Time `json:"cooling_off_until,omitempty"`

	UpdatedAt time.Time `json:"updated_at"`
}

// RGCheck is the result of CheckCanBet.
type RGCheck struct {
	PlayerID string `json:"player_id"`
	Allowed  bool   `json:"allowed"`
	// Reason is non-empty when Allowed = false. It is suitable for logging
	// and for structured error responses (e.g. "self_excluded", "loss_daily").
	Reason string `json:"reason,omitempty"`
	// Until is populated for time-bounded blocks (self-exclusion,
	// cooling-off). Zero value when not applicable.
	Until time.Time `json:"until,omitempty"`
}

// sessionRecord tracks the start time and running loss accumulation for an
// active or recent session. It is keyed by session-open timestamp bucket.
type sessionRecord struct {
	PlayerID  string
	StartedAt time.Time
	EndedAt   time.Time // zero while session still open
}

// playerAccumulators holds rolling financial sums per player. Amounts are in
// the same unit as RGLimits (cents / satoshis — whatever the operator uses).
type playerAccumulators struct {
	// dailyLoss / weeklyLoss / monthlyLoss are naive calendar-day sums.
	// They are re-zeroed when the window rolls over at CheckCanBet time.
	dailyLoss   uint64
	weeklyLoss  uint64
	monthlyLoss uint64

	lastDayReset   time.Time
	lastWeekReset  time.Time
	lastMonthReset time.Time
}

// RGService is the responsible-gambling enforcement interface. All methods
// are safe for concurrent calls.
type RGService interface {
	// GetLimits returns the current RGLimits for playerID. If the player
	// has never had limits set, a zero-value RGLimits with PlayerID filled
	// in is returned (no error).
	GetLimits(playerID string) (*RGLimits, error)

	// SetLimits persists new limits for playerID. Limits can only become
	// more restrictive via this method; any attempt to relax a cap (increase
	// a daily/weekly/monthly max, or push SelfExcludedUntil/CoolingOffUntil
	// backwards) returns ErrRGIncreaseDenied. Operator-side relaxation is
	// done via AdminOverrideLimits.
	SetLimits(playerID string, limits RGLimits) error

	// AdminOverrideLimits allows an operator (admin panel) to relax a limit.
	// Unlike SetLimits, it accepts any change. The caller is responsible for
	// audit-logging the override before calling this.
	AdminOverrideLimits(playerID string, limits RGLimits) error

	// CheckCanBet returns whether the player is allowed to place a bet of
	// the given amount. It checks self-exclusion, cooling-off, and loss caps.
	// amount is in the same sub-unit denomination as limits (cents, etc.).
	// currency is informational (RG limits are always in the operator's
	// single reporting currency in this scaffolding; M9.x adds FX conversion).
	CheckCanBet(playerID string, amount uint64, currency string) RGCheck

	// RecordSession is called by the Manager goroutine when a session opens
	// (endedAt zero) or closes. It is used by the session-timeout enforcer.
	RecordSession(playerID string, startedAt, endedAt time.Time)

	// RecordLoss is called after a settled round where the player lost
	// (debit > credit). amount is the net loss in reporting-currency units.
	RecordLoss(playerID string, amount uint64)

	// SelfExclude sets SelfExcludedUntil = now + days. It always succeeds
	// (self-exclusion cannot be blocked).
	SelfExclude(playerID string, until time.Time)

	// SetCoolingOff sets CoolingOffUntil = now + hours.
	SetCoolingOff(playerID string, until time.Time)

	// ActiveSessionsExceedingTimeout returns player IDs whose open sessions
	// have exceeded their SessionTimeoutMin. Called by the enforcement
	// goroutine every tick.
	ActiveSessionsExceedingTimeout(now time.Time) []string
}

// InMemoryRGService is the reference implementation. It is safe for
// concurrent use.
type InMemoryRGService struct {
	mu    sync.RWMutex
	limits map[string]*RGLimits          // playerID → limits
	accum  map[string]*playerAccumulators // playerID → rolling sums
	// openSessions tracks sessions that have been opened but not yet closed.
	// Key: playerID; Value: list of session start times. A single player may
	// have multiple concurrent sessions (multi-device).
	openSessions map[string][]time.Time
}

// NewInMemoryRGService constructs a ready-to-use in-memory RG service.
func NewInMemoryRGService() *InMemoryRGService {
	return &InMemoryRGService{
		limits:       make(map[string]*RGLimits),
		accum:        make(map[string]*playerAccumulators),
		openSessions: make(map[string][]time.Time),
	}
}

// GetLimits implements RGService.
func (s *InMemoryRGService) GetLimits(playerID string) (*RGLimits, error) {
	s.mu.RLock()
	l, ok := s.limits[playerID]
	s.mu.RUnlock()
	if !ok {
		return &RGLimits{PlayerID: playerID, UpdatedAt: time.Now()}, nil
	}
	cp := *l
	return &cp, nil
}

// SetLimits implements RGService. Only tightening (decreasing caps, extending
// exclusions) is allowed. For each limit field that changes, the new value
// must be <= the current value (or the current value is 0 = no limit, in
// which case any new non-zero value is accepted as a tightening).
func (s *InMemoryRGService) SetLimits(playerID string, newLimits RGLimits) error {
	s.mu.Lock()
	defer s.mu.Unlock()

	cur, ok := s.limits[playerID]
	if !ok {
		// First time setting limits: allow anything.
		cp := newLimits
		cp.PlayerID = playerID
		cp.UpdatedAt = time.Now()
		s.limits[playerID] = &cp
		return nil
	}

	// Validate that each non-zero new cap is <= current cap (0 means
	// "no limit"; going from 0 to non-zero is tightening and is allowed).
	if err := validateTightening("deposit_daily_max", cur.DepositDailyMax, newLimits.DepositDailyMax); err != nil {
		return err
	}
	if err := validateTightening("deposit_weekly_max", cur.DepositWeeklyMax, newLimits.DepositWeeklyMax); err != nil {
		return err
	}
	if err := validateTightening("deposit_monthly_max", cur.DepositMonthMax, newLimits.DepositMonthMax); err != nil {
		return err
	}
	if err := validateTightening("loss_daily_max", cur.LossDailyMax, newLimits.LossDailyMax); err != nil {
		return err
	}
	if err := validateTightening("loss_weekly_max", cur.LossWeeklyMax, newLimits.LossWeeklyMax); err != nil {
		return err
	}
	if err := validateTightening("loss_monthly_max", cur.LossMonthMax, newLimits.LossMonthMax); err != nil {
		return err
	}
	if err := validateTimeExtension("self_excluded_until", cur.SelfExcludedUntil, newLimits.SelfExcludedUntil); err != nil {
		return err
	}
	if err := validateTimeExtension("cooling_off_until", cur.CoolingOffUntil, newLimits.CoolingOffUntil); err != nil {
		return err
	}

	cp := newLimits
	cp.PlayerID = playerID
	cp.UpdatedAt = time.Now()
	s.limits[playerID] = &cp
	return nil
}

// AdminOverrideLimits implements RGService. Bypasses the tightening check so
// operators can relax limits (e.g. after a UKGC 7-day cooling-off expires
// and the player requests reinstatement). Caller MUST audit-log before calling.
func (s *InMemoryRGService) AdminOverrideLimits(playerID string, limits RGLimits) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	cp := limits
	cp.PlayerID = playerID
	cp.UpdatedAt = time.Now()
	s.limits[playerID] = &cp
	return nil
}

// CheckCanBet implements RGService.
func (s *InMemoryRGService) CheckCanBet(playerID string, amount uint64, _ string) RGCheck {
	s.mu.RLock()
	l, hasLimits := s.limits[playerID]
	acc, hasAcc := s.accum[playerID]
	s.mu.RUnlock()

	now := time.Now()

	if hasLimits {
		// 1. Self-exclusion (hardest block).
		if !l.SelfExcludedUntil.IsZero() && now.Before(l.SelfExcludedUntil) {
			return RGCheck{
				PlayerID: playerID,
				Allowed:  false,
				Reason:   "self_excluded",
				Until:    l.SelfExcludedUntil,
			}
		}
		// 2. Cooling-off.
		if !l.CoolingOffUntil.IsZero() && now.Before(l.CoolingOffUntil) {
			return RGCheck{
				PlayerID: playerID,
				Allowed:  false,
				Reason:   "cooling_off",
				Until:    l.CoolingOffUntil,
			}
		}
		// 3. Loss caps: check if adding `amount` to the running loss total
		//    would exceed the cap. We use the stored accumulated loss (which
		//    RecordLoss populates after each round) so we only block when the
		//    player has already hit the threshold; this bet's potential loss
		//    is not pre-counted here (it would double-count with RecordLoss).
		if hasAcc {
			if l.LossDailyMax > 0 && acc.dailyLoss >= l.LossDailyMax {
				return RGCheck{
					PlayerID: playerID,
					Allowed:  false,
					Reason:   fmt.Sprintf("loss_daily_max=%d reached", l.LossDailyMax),
				}
			}
			if l.LossWeeklyMax > 0 && acc.weeklyLoss >= l.LossWeeklyMax {
				return RGCheck{
					PlayerID: playerID,
					Allowed:  false,
					Reason:   fmt.Sprintf("loss_weekly_max=%d reached", l.LossWeeklyMax),
				}
			}
			if l.LossMonthMax > 0 && acc.monthlyLoss >= l.LossMonthMax {
				return RGCheck{
					PlayerID: playerID,
					Allowed:  false,
					Reason:   fmt.Sprintf("loss_monthly_max=%d reached", l.LossMonthMax),
				}
			}
		}
		// 4. Deposit caps (deposit cap = bet cap in a non-bonus model).
		if l.DepositDailyMax > 0 && amount > l.DepositDailyMax {
			return RGCheck{
				PlayerID: playerID,
				Allowed:  false,
				Reason:   fmt.Sprintf("deposit_daily_max=%d exceeded by amount=%d", l.DepositDailyMax, amount),
			}
		}
		if l.DepositWeeklyMax > 0 && amount > l.DepositWeeklyMax {
			return RGCheck{
				PlayerID: playerID,
				Allowed:  false,
				Reason:   fmt.Sprintf("deposit_weekly_max=%d exceeded by amount=%d", l.DepositWeeklyMax, amount),
			}
		}
		if l.DepositMonthMax > 0 && amount > l.DepositMonthMax {
			return RGCheck{
				PlayerID: playerID,
				Allowed:  false,
				Reason:   fmt.Sprintf("deposit_monthly_max=%d exceeded by amount=%d", l.DepositMonthMax, amount),
			}
		}
	}

	return RGCheck{PlayerID: playerID, Allowed: true}
}

// RecordSession implements RGService.
func (s *InMemoryRGService) RecordSession(playerID string, startedAt, endedAt time.Time) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if endedAt.IsZero() {
		// Session opened: track start time.
		s.openSessions[playerID] = append(s.openSessions[playerID], startedAt)
		return
	}
	// Session closed: remove the matching start time.
	starts := s.openSessions[playerID]
	for i, t := range starts {
		if t.Equal(startedAt) {
			s.openSessions[playerID] = append(starts[:i], starts[i+1:]...)
			return
		}
	}
	// If not found by exact match, remove the oldest.
	if len(starts) > 0 {
		s.openSessions[playerID] = starts[1:]
	}
}

// RecordLoss implements RGService. Called after a bet settles as a loss.
func (s *InMemoryRGService) RecordLoss(playerID string, amount uint64) {
	if amount == 0 {
		return
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	acc := s.ensureAccum(playerID)
	now := time.Now()
	s.rollWindows(acc, now)
	acc.dailyLoss += amount
	acc.weeklyLoss += amount
	acc.monthlyLoss += amount
}

// SelfExclude implements RGService.
func (s *InMemoryRGService) SelfExclude(playerID string, until time.Time) {
	s.mu.Lock()
	defer s.mu.Unlock()
	l := s.ensureLimits(playerID)
	l.SelfExcludedUntil = until
	l.UpdatedAt = time.Now()
}

// SetCoolingOff implements RGService.
func (s *InMemoryRGService) SetCoolingOff(playerID string, until time.Time) {
	s.mu.Lock()
	defer s.mu.Unlock()
	l := s.ensureLimits(playerID)
	l.CoolingOffUntil = until
	l.UpdatedAt = time.Now()
}

// ActiveSessionsExceedingTimeout implements RGService. Returns playerIDs
// whose oldest open session start time is more than SessionTimeoutMin minutes
// ago. Only players that have a positive SessionTimeoutMin are included.
func (s *InMemoryRGService) ActiveSessionsExceedingTimeout(now time.Time) []string {
	s.mu.RLock()
	defer s.mu.RUnlock()
	var out []string
	for playerID, starts := range s.openSessions {
		if len(starts) == 0 {
			continue
		}
		l, ok := s.limits[playerID]
		if !ok || l.SessionTimeoutMin <= 0 {
			continue
		}
		limit := time.Duration(l.SessionTimeoutMin) * time.Minute
		// Use the oldest open session start to check timeout.
		oldest := starts[0]
		for _, t := range starts[1:] {
			if t.Before(oldest) {
				oldest = t
			}
		}
		if now.Sub(oldest) >= limit {
			out = append(out, playerID)
		}
	}
	return out
}

// ─── internal helpers ────────────────────────────────────────────────────────

// ensureLimits returns (and creates if needed) the limits entry for playerID.
// Caller must hold s.mu write lock.
func (s *InMemoryRGService) ensureLimits(playerID string) *RGLimits {
	l, ok := s.limits[playerID]
	if !ok {
		l = &RGLimits{PlayerID: playerID, UpdatedAt: time.Now()}
		s.limits[playerID] = l
	}
	return l
}

// ensureAccum returns (and creates if needed) the accumulator for playerID.
// Caller must hold s.mu write lock.
func (s *InMemoryRGService) ensureAccum(playerID string) *playerAccumulators {
	acc, ok := s.accum[playerID]
	if !ok {
		now := time.Now()
		acc = &playerAccumulators{
			lastDayReset:   now,
			lastWeekReset:  now,
			lastMonthReset: now,
		}
		s.accum[playerID] = acc
	}
	return acc
}

// rollWindows resets accumulator buckets when the calendar window has rolled
// over. Caller must hold s.mu write lock.
func (s *InMemoryRGService) rollWindows(acc *playerAccumulators, now time.Time) {
	if !sameCalendarDay(acc.lastDayReset, now) {
		acc.dailyLoss = 0
		acc.lastDayReset = now
	}
	if !sameCalendarWeek(acc.lastWeekReset, now) {
		acc.weeklyLoss = 0
		acc.lastWeekReset = now
	}
	if !sameCalendarMonth(acc.lastMonthReset, now) {
		acc.monthlyLoss = 0
		acc.lastMonthReset = now
	}
}

// validateTightening returns ErrRGIncreaseDenied if the new cap is LESS
// restrictive than the current one. Rules:
//   - current == 0 (no limit): new must be 0 (no change) or > 0 (tightening).
//     In both cases allowed.
//   - current > 0: new must be > 0 and <= current. New == 0 would mean
//     "no limit" which is a relaxation → denied.
func validateTightening(field string, current, newVal uint64) error {
	if current == 0 {
		// No existing cap → anything goes (including keeping it 0).
		return nil
	}
	// current > 0: a new value of 0 means "remove limit" = relaxation.
	if newVal == 0 {
		return fmt.Errorf("%w: field=%s current=%d new=0 (removing a limit is not allowed via player self-service)", ErrRGIncreaseDenied, field, current)
	}
	if newVal > current {
		return fmt.Errorf("%w: field=%s current=%d new=%d", ErrRGIncreaseDenied, field, current, newVal)
	}
	return nil
}

// validateTimeExtension returns ErrRGIncreaseDenied if the new time moves
// the exclusion/cooling-off BACKWARD (earlier). Moving it forward or keeping
// it the same is always allowed (tightening).
func validateTimeExtension(field string, current, newVal time.Time) error {
	if current.IsZero() {
		// No existing exclusion → anything allowed.
		return nil
	}
	if newVal.IsZero() {
		// Clearing an exclusion is a relaxation → denied via self-service.
		return fmt.Errorf("%w: field=%s clearing exclusion is not allowed via player self-service", ErrRGIncreaseDenied, field)
	}
	if newVal.Before(current) {
		return fmt.Errorf("%w: field=%s current=%s new=%s (shortening exclusion not allowed via player self-service)", ErrRGIncreaseDenied, field, current.Format(time.RFC3339), newVal.Format(time.RFC3339))
	}
	return nil
}

// ─── calendar helpers ────────────────────────────────────────────────────────

func sameCalendarDay(a, b time.Time) bool {
	ya, ma, da := a.Date()
	yb, mb, db := b.Date()
	return ya == yb && ma == mb && da == db
}

func sameCalendarWeek(a, b time.Time) bool {
	ya, wa := a.ISOWeek()
	yb, wb := b.ISOWeek()
	return ya == yb && wa == wb
}

func sameCalendarMonth(a, b time.Time) bool {
	ya, ma, _ := a.Date()
	yb, mb, _ := b.Date()
	return ya == yb && ma == mb
}

// ─── RGConfig for Manager wiring ────────────────────────────────────────────

// RGConfig holds the responsible-gambling settings injected into the Manager.
// All fields are optional; zero values disable enforcement.
type RGConfig struct {
	// Service is the RGService implementation. When nil, RG checks are
	// skipped entirely (backward-compatible default).
	Service RGService

	// DefaultSessionTimeoutMin is applied to new players that have not
	// explicitly set a session timeout. 0 = no default timeout.
	DefaultSessionTimeoutMin int

	// DefaultRealityCheckMin is the default pop-up interval for new players.
	DefaultRealityCheckMin int

	// EnforcementTickInterval is how often the Manager's enforcement goroutine
	// polls for timed-out sessions and expired cooling-off periods. Defaults
	// to 1 minute when zero.
	EnforcementTickInterval time.Duration
}
