package admin

// Responsible-gambling admin handlers.
//
//	POST /admin/players/{id}/rg-override  — operator relaxes a player limit
//	                                        (audit logged + reason required)
//	POST /admin/players/{id}/force-exclude — emergency self-exclusion imposed
//	                                        by operator (e.g. GamStop integration)
//
// Both endpoints are no-ops (returning 501) when the Manager's RGService is
// not configured, so the admin panel compiles and runs regardless of whether
// the --rg-enabled flag is set.

import (
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"time"

	"github.com/onion-coding/marbles-game2/server/rgs"
)

// rgOverrideRequest is the body for POST /admin/players/{id}/rg-override.
// Reason is mandatory so there is always an audit trail explaining why the
// limit was relaxed.
type rgOverrideRequest struct {
	Reason            string `json:"reason"`
	DepositDailyMax   uint64 `json:"deposit_daily_max"`
	DepositWeeklyMax  uint64 `json:"deposit_weekly_max"`
	DepositMonthlyMax uint64 `json:"deposit_monthly_max"`
	LossDailyMax      uint64 `json:"loss_daily_max"`
	LossWeeklyMax     uint64 `json:"loss_weekly_max"`
	LossMonthlyMax    uint64 `json:"loss_monthly_max"`
	SessionTimeoutMin int    `json:"session_timeout_min"`
	RealityCheckMin   int    `json:"reality_check_min"`
	// ClearSelfExclusion lifts a self-exclusion when true (requires reason).
	ClearSelfExclusion bool `json:"clear_self_exclusion"`
	// ClearCoolingOff lifts a cooling-off period when true.
	ClearCoolingOff bool `json:"clear_cooling_off"`
}

// rgForceExcludeRequest is the body for POST /admin/players/{id}/force-exclude.
type rgForceExcludeRequest struct {
	Days   int    `json:"days"`
	Reason string `json:"reason"`
}

// rgOverride handles POST /admin/players/{id}/rg-override.
// Operators can use this to relax a player limit that was set too tightly,
// or to reinstate a player after an operator-imposed exclusion. Every call is
// audit-logged with the actor and reason.
func (h *Handler) rgOverride(w http.ResponseWriter, r *http.Request, actor string) {
	rgSvc := h.rgService()
	if rgSvc == nil {
		writeAdminError(w, http.StatusNotImplemented, errors.New("responsible gambling service not configured"))
		return
	}

	playerID := r.PathValue("id")
	var req rgOverrideRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeAdminError(w, http.StatusBadRequest, fmt.Errorf("decode body: %w", err))
		return
	}
	if req.Reason == "" {
		writeAdminError(w, http.StatusBadRequest, errors.New("reason is required for admin RG override"))
		return
	}

	// Fetch current limits so we can merge changes rather than replace wholesale.
	current, err := rgSvc.GetLimits(playerID)
	if err != nil {
		writeAdminError(w, http.StatusInternalServerError, err)
		return
	}

	// Build the new limit record. Fields left at zero in the request body
	// retain their current value so operators only need to send the fields
	// they want to change.
	newLimits := rgs.RGLimits{
		PlayerID:          playerID,
		DepositDailyMax:   coalesceUint64(req.DepositDailyMax, current.DepositDailyMax),
		DepositWeeklyMax:  coalesceUint64(req.DepositWeeklyMax, current.DepositWeeklyMax),
		DepositMonthMax:   coalesceUint64(req.DepositMonthlyMax, current.DepositMonthMax),
		LossDailyMax:      coalesceUint64(req.LossDailyMax, current.LossDailyMax),
		LossWeeklyMax:     coalesceUint64(req.LossWeeklyMax, current.LossWeeklyMax),
		LossMonthMax:      coalesceUint64(req.LossMonthlyMax, current.LossMonthMax),
		SessionTimeoutMin: coalesceInt(req.SessionTimeoutMin, current.SessionTimeoutMin),
		RealityCheckMin:   coalesceInt(req.RealityCheckMin, current.RealityCheckMin),
		SelfExcludedUntil: current.SelfExcludedUntil,
		CoolingOffUntil:   current.CoolingOffUntil,
	}
	if req.ClearSelfExclusion {
		newLimits.SelfExcludedUntil = time.Time{}
	}
	if req.ClearCoolingOff {
		newLimits.CoolingOffUntil = time.Time{}
	}

	if err := rgSvc.AdminOverrideLimits(playerID, newLimits); err != nil {
		writeAdminError(w, http.StatusInternalServerError, err)
		return
	}

	h.audit.Record(AuditEvent{
		Actor:   actor,
		Action:  "rg.override",
		Target:  playerID,
		Details: fmt.Sprintf("reason=%q clear_excl=%v clear_cooling=%v", req.Reason, req.ClearSelfExclusion, req.ClearCoolingOff),
	})

	updated, _ := rgSvc.GetLimits(playerID)
	writeAdminJSON(w, http.StatusOK, updated)
}

// rgForceExclude handles POST /admin/players/{id}/force-exclude.
// Used for emergency operator-imposed self-exclusion (e.g. GamStop match,
// fraud trigger, or at-risk player identified by support staff).
func (h *Handler) rgForceExclude(w http.ResponseWriter, r *http.Request, actor string) {
	rgSvc := h.rgService()
	if rgSvc == nil {
		writeAdminError(w, http.StatusNotImplemented, errors.New("responsible gambling service not configured"))
		return
	}

	playerID := r.PathValue("id")
	var req rgForceExcludeRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeAdminError(w, http.StatusBadRequest, fmt.Errorf("decode body: %w", err))
		return
	}
	if req.Days <= 0 {
		writeAdminError(w, http.StatusBadRequest, errors.New("days must be > 0"))
		return
	}
	if req.Reason == "" {
		writeAdminError(w, http.StatusBadRequest, errors.New("reason is required for operator force-exclude"))
		return
	}

	until := time.Now().Add(time.Duration(req.Days) * 24 * time.Hour)
	rgSvc.SelfExclude(playerID, until)

	h.audit.Record(AuditEvent{
		Actor:   actor,
		Action:  "rg.force_exclude",
		Target:  playerID,
		Details: fmt.Sprintf("days=%d until=%s reason=%q", req.Days, until.Format(time.RFC3339), req.Reason),
	})

	updated, _ := rgSvc.GetLimits(playerID)
	writeAdminJSON(w, http.StatusOK, updated)
}

// rgService returns the RGService from the Manager config, or nil if RG is
// not configured. Admin handlers use this so they compile and run safely even
// when --rg-enabled=false.
func (h *Handler) rgService() rgs.RGService {
	cfg := h.cfg.Manager.Config()
	if cfg.RG == nil {
		return nil
	}
	return cfg.RG.Service
}

// coalesceUint64 returns a if a != 0, else b.
func coalesceUint64(a, b uint64) uint64 {
	if a != 0 {
		return a
	}
	return b
}

// coalesceInt returns a if a != 0, else b.
func coalesceInt(a, b int) int {
	if a != 0 {
		return a
	}
	return b
}
