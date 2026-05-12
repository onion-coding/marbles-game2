package rgs

// RG HTTP handlers — responsible-gambling player endpoints.
//
// Routes (registered in HTTPHandler.Routes):
//
//	GET  /v1/players/{id}/limits        — return current RGLimits JSON
//	PUT  /v1/players/{id}/limits        — player sets / tightens limits
//	POST /v1/players/{id}/self-exclude  — {"days": N} → SelfExcludedUntil
//	POST /v1/players/{id}/cooling-off   — {"hours": N} → CoolingOffUntil

import (
	"errors"
	"fmt"
	"net/http"
	"time"
)

// rgLimitsRequest is the PUT /v1/players/{id}/limits body.
// All fields are optional; zero values are treated as "unchanged" on the
// server side — the RGService.SetLimits call will reject any relaxation
// attempt and return 409.
type rgLimitsRequest struct {
	DepositDailyMax   uint64 `json:"deposit_daily_max"`
	DepositWeeklyMax  uint64 `json:"deposit_weekly_max"`
	DepositMonthlyMax uint64 `json:"deposit_monthly_max"`
	LossDailyMax      uint64 `json:"loss_daily_max"`
	LossWeeklyMax     uint64 `json:"loss_weekly_max"`
	LossMonthlyMax    uint64 `json:"loss_monthly_max"`
	SessionTimeoutMin int    `json:"session_timeout_min"`
	RealityCheckMin   int    `json:"reality_check_min"`
}

// rgSelfExcludeRequest is the POST /v1/players/{id}/self-exclude body.
type rgSelfExcludeRequest struct {
	Days int `json:"days"`
}

// rgCoolingOffRequest is the POST /v1/players/{id}/cooling-off body.
type rgCoolingOffRequest struct {
	Hours int `json:"hours"`
}

// ─── Handler methods (wired by HTTPHandler.Routes) ──────────────────────────

// handleRGGetLimits handles GET /v1/players/{id}/limits.
func (h *HTTPHandler) handleRGGetLimits(w http.ResponseWriter, r *http.Request) {
	if h.mgr.cfg.RG == nil {
		writeError(w, http.StatusNotFound, fmt.Errorf("responsible gambling not enabled"))
		return
	}
	playerID := r.PathValue("id")
	limits, err := h.mgr.cfg.RG.Service.GetLimits(playerID)
	if err != nil {
		writeError(w, http.StatusInternalServerError, err)
		return
	}
	writeJSON(w, http.StatusOK, limits)
}

// handleRGSetLimits handles PUT /v1/players/{id}/limits.
// Only tightening operations are allowed. A 409 Conflict is returned when
// the player attempts to relax any limit.
func (h *HTTPHandler) handleRGSetLimits(w http.ResponseWriter, r *http.Request) {
	if h.mgr.cfg.RG == nil {
		writeError(w, http.StatusNotFound, fmt.Errorf("responsible gambling not enabled"))
		return
	}
	playerID := r.PathValue("id")

	var req rgLimitsRequest
	if err := decodeJSON(r, &req); err != nil {
		writeError(w, http.StatusBadRequest, err)
		return
	}

	newLimits := RGLimits{
		PlayerID:          playerID,
		DepositDailyMax:   req.DepositDailyMax,
		DepositWeeklyMax:  req.DepositWeeklyMax,
		DepositMonthMax:   req.DepositMonthlyMax,
		LossDailyMax:      req.LossDailyMax,
		LossWeeklyMax:     req.LossWeeklyMax,
		LossMonthMax:      req.LossMonthlyMax,
		SessionTimeoutMin: req.SessionTimeoutMin,
		RealityCheckMin:   req.RealityCheckMin,
	}

	if err := h.mgr.cfg.RG.Service.SetLimits(playerID, newLimits); err != nil {
		if errors.Is(err, ErrRGIncreaseDenied) {
			writeError(w, http.StatusConflict, err)
			return
		}
		writeError(w, http.StatusInternalServerError, err)
		return
	}

	limits, _ := h.mgr.cfg.RG.Service.GetLimits(playerID)
	writeJSON(w, http.StatusOK, limits)
}

// handleRGSelfExclude handles POST /v1/players/{id}/self-exclude.
func (h *HTTPHandler) handleRGSelfExclude(w http.ResponseWriter, r *http.Request) {
	if h.mgr.cfg.RG == nil {
		writeError(w, http.StatusNotFound, fmt.Errorf("responsible gambling not enabled"))
		return
	}
	playerID := r.PathValue("id")

	var req rgSelfExcludeRequest
	if err := decodeJSON(r, &req); err != nil {
		writeError(w, http.StatusBadRequest, err)
		return
	}
	if req.Days <= 0 {
		writeError(w, http.StatusBadRequest, fmt.Errorf("days must be > 0"))
		return
	}

	until := time.Now().Add(time.Duration(req.Days) * 24 * time.Hour)
	h.mgr.cfg.RG.Service.SelfExclude(playerID, until)

	limits, _ := h.mgr.cfg.RG.Service.GetLimits(playerID)
	writeJSON(w, http.StatusOK, limits)
}

// handleRGCoolingOff handles POST /v1/players/{id}/cooling-off.
func (h *HTTPHandler) handleRGCoolingOff(w http.ResponseWriter, r *http.Request) {
	if h.mgr.cfg.RG == nil {
		writeError(w, http.StatusNotFound, fmt.Errorf("responsible gambling not enabled"))
		return
	}
	playerID := r.PathValue("id")

	var req rgCoolingOffRequest
	if err := decodeJSON(r, &req); err != nil {
		writeError(w, http.StatusBadRequest, err)
		return
	}
	if req.Hours <= 0 {
		writeError(w, http.StatusBadRequest, fmt.Errorf("hours must be > 0"))
		return
	}

	until := time.Now().Add(time.Duration(req.Hours) * time.Hour)
	h.mgr.cfg.RG.Service.SetCoolingOff(playerID, until)

	limits, _ := h.mgr.cfg.RG.Service.GetLimits(playerID)
	writeJSON(w, http.StatusOK, limits)
}
