package admin_test

import (
	"bytes"
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"testing"

	"github.com/onion-coding/marbles-game2/server/admin"
	"github.com/onion-coding/marbles-game2/server/replay"
	"github.com/onion-coding/marbles-game2/server/rgs"
	"github.com/onion-coding/marbles-game2/server/sim"
)

// ── test wiring ──────────────────────────────────────────────────────────────

// fakeSim writes a minimal replay file and returns a fixed winner.
type fakeSim struct{ winner int }

func (f *fakeSim) run(ctx context.Context, req sim.Request) (sim.Result, error) {
	_ = os.MkdirAll(req.WorkDir, 0o755)
	rp := filepath.Join(req.WorkDir, "replay.bin")
	// Minimal v3 header bytes — enough for replay.Store.Save.
	hdr := []byte{
		3,                   // protocol version
		0, 0, 0, 0, 0, 0, 0, 0, // round_id (8 bytes LE)
		60, 0, 0, 0, // tick_rate_hz
		0,           // seed len
		0,           // hash len
		30, 0, 0, 0, // slot_count
		1,           // track_id
		0, 0, 0, 0, // client_seeds count
		0, 0, 0, 0, // frame_count
	}
	_ = os.WriteFile(rp, hdr, 0o644)
	return sim.Result{
		RoundID:           req.RoundID,
		WinnerMarbleIndex: f.winner,
		FinishTick:        42,
		PickupTier2Marble: -1,
		ProtocolVersion:   3,
		ReplayPath:        rp,
		TickRateHz:        60,
	}, nil
}

func newTestEnv(t *testing.T, winner int) (*rgs.Manager, *rgs.MockWallet, *admin.Handler, *admin.AuditLog) {
	t.Helper()
	dir := t.TempDir()

	store, err := replay.New(filepath.Join(dir, "replays"))
	if err != nil {
		t.Fatalf("replay.New: %v", err)
	}
	wallet := rgs.NewMockWallet()
	fs := &fakeSim{winner: winner}
	mgr, err := rgs.NewManager(rgs.ManagerConfig{
		Wallet:     wallet,
		Store:      store,
		Sim:        fs.run,
		WorkRoot:   filepath.Join(dir, "work"),
		BuyIn:      100,
		RTPBps:     9500,
		MaxMarbles: 30,
		TrackPool:  []uint8{1, 2, 3},
	})
	if err != nil {
		t.Fatalf("NewManager: %v", err)
	}

	auditLog, err := admin.NewAuditLog(filepath.Join(dir, "audit"))
	if err != nil {
		t.Fatalf("NewAuditLog: %v", err)
	}
	t.Cleanup(func() { _ = auditLog.Close() })

	h, err := admin.NewHandler(admin.Config{
		Manager:  mgr,
		Wallet:   wallet,
		Auth:     nil, // no auth in tests
		AuditLog: auditLog,
	})
	if err != nil {
		t.Fatalf("admin.NewHandler: %v", err)
	}
	return mgr, wallet, h, auditLog
}

func doJSON(t *testing.T, h http.Handler, method, path string, body any) *httptest.ResponseRecorder {
	t.Helper()
	var buf bytes.Buffer
	if body != nil {
		if err := json.NewEncoder(&buf).Encode(body); err != nil {
			t.Fatalf("encode body: %v", err)
		}
	}
	req := httptest.NewRequest(method, path, &buf)
	req.Header.Set("Content-Type", "application/json")
	w := httptest.NewRecorder()
	h.ServeHTTP(w, req)
	return w
}

func mustDecodeJSON(t *testing.T, w *httptest.ResponseRecorder, dst any) {
	t.Helper()
	if err := json.NewDecoder(w.Body).Decode(dst); err != nil {
		t.Fatalf("decode response (status %d body %q): %v", w.Code, w.Body.String(), err)
	}
}

// ── TestAdmin_PauseResume ─────────────────────────────────────────────────────

func TestAdmin_PauseResume(t *testing.T) {
	mgr, wallet, h, _ := newTestEnv(t, 0)
	wallet.SetBalance("alice", 1000)

	// Verify initially running.
	if mgr.IsPaused() {
		t.Fatal("manager should not be paused initially")
	}

	// Pause via admin endpoint.
	w := doJSON(t, h, "POST", "/admin/rounds/pause", nil)
	if w.Code != http.StatusOK {
		t.Fatalf("pause status %d, want 200: %s", w.Code, w.Body)
	}

	if !mgr.IsPaused() {
		t.Fatal("manager should be paused after POST /admin/rounds/pause")
	}

	// RunNextRound must return ErrManagerPaused.
	sess, _ := mgr.OpenSession("alice")
	_ = wallet // already set above
	_, err := mgr.PlaceBet(sess.ID, 100, rgs.DefaultCurrency)
	if err != nil {
		t.Fatalf("PlaceBet: %v", err)
	}
	_, _, _, runErr := mgr.RunNextRound(context.Background())
	if runErr == nil {
		t.Fatal("RunNextRound should return error while paused")
	}
	if runErr.Error() != rgs.ErrManagerPaused.Error() {
		t.Fatalf("expected ErrManagerPaused, got %v", runErr)
	}

	// Resume via admin endpoint.
	w = doJSON(t, h, "POST", "/admin/rounds/resume", nil)
	if w.Code != http.StatusOK {
		t.Fatalf("resume status %d, want 200: %s", w.Code, w.Body)
	}
	if mgr.IsPaused() {
		t.Fatal("manager should not be paused after resume")
	}

	// RunNextRound now succeeds (bet was held in pending queue).
	_, _, _, runErr = mgr.RunNextRound(context.Background())
	if runErr != nil {
		t.Fatalf("RunNextRound after resume: %v", runErr)
	}
}

// ── TestAdmin_ManualCreditDebit_AuditLogged ────────────────────────────────

func TestAdmin_ManualCreditDebit_AuditLogged(t *testing.T) {
	_, wallet, h, auditLog := newTestEnv(t, 0)
	wallet.SetBalance("bob", 500)

	// Manual credit.
	w := doJSON(t, h, "POST", "/admin/wallets/bob/credit", map[string]any{"amount": 200, "reason": "promo"})
	if w.Code != http.StatusOK {
		t.Fatalf("credit status %d: %s", w.Code, w.Body)
	}
	var creditResp struct {
		PlayerID string  `json:"player_id"`
		Balance  float64 `json:"balance"`
	}
	mustDecodeJSON(t, w, &creditResp)
	if creditResp.Balance != 7.00 { // 500+200 = 700 units = 7.00
		t.Fatalf("balance after credit: got %.2f, want 7.00", creditResp.Balance)
	}

	// Manual debit.
	w = doJSON(t, h, "POST", "/admin/wallets/bob/debit", map[string]any{"amount": 100, "reason": "correction"})
	if w.Code != http.StatusOK {
		t.Fatalf("debit status %d: %s", w.Code, w.Body)
	}
	var debitResp struct {
		Balance float64 `json:"balance"`
	}
	mustDecodeJSON(t, w, &debitResp)
	if debitResp.Balance != 6.00 { // 700-100 = 600 units = 6.00
		t.Fatalf("balance after debit: got %.2f, want 6.00", debitResp.Balance)
	}

	// Both operations must appear in the audit log.
	events := auditLog.List(0, 50)
	if len(events) < 2 {
		t.Fatalf("audit log has %d events, want at least 2", len(events))
	}
	actions := make(map[string]bool)
	for _, ev := range events {
		actions[ev.Action] = true
	}
	if !actions["wallet.credit"] {
		t.Error("audit log missing wallet.credit event")
	}
	if !actions["wallet.debit"] {
		t.Error("audit log missing wallet.debit event")
	}
}

// ── TestAdmin_RTPHotUpdate ────────────────────────────────────────────────────

func TestAdmin_RTPHotUpdate(t *testing.T) {
	mgr, _, h, _ := newTestEnv(t, 0)

	// Confirm initial RTP.
	initialCfg := mgr.Config()
	if initialCfg.RTPBps != 9500 {
		t.Fatalf("initial RTPBps %d, want 9500", initialCfg.RTPBps)
	}

	// Update via admin endpoint.
	w := doJSON(t, h, "POST", "/admin/config/rtp-bps", map[string]any{"rtp_bps": 9200})
	if w.Code != http.StatusOK {
		t.Fatalf("set-rtp status %d: %s", w.Code, w.Body)
	}
	var cfgResp struct {
		RTPBps uint32 `json:"rtp_bps"`
	}
	mustDecodeJSON(t, w, &cfgResp)
	if cfgResp.RTPBps != 9200 {
		t.Fatalf("response rtp_bps %d, want 9200", cfgResp.RTPBps)
	}

	// Manager config must reflect the change.
	if mgr.Config().RTPBps != 9200 {
		t.Fatalf("manager RTPBps %d after update, want 9200", mgr.Config().RTPBps)
	}

	// GET /admin/config must also reflect it.
	wGet := doJSON(t, h, "GET", "/admin/config", nil)
	if wGet.Code != http.StatusOK {
		t.Fatalf("get-config status %d: %s", wGet.Code, wGet.Body)
	}
	var snap struct {
		RTPBps uint32 `json:"rtp_bps"`
	}
	mustDecodeJSON(t, wGet, &snap)
	if snap.RTPBps != 9200 {
		t.Fatalf("config endpoint rtp_bps %d, want 9200", snap.RTPBps)
	}
}

// ── TestAdmin_AuditLogPersistence ─────────────────────────────────────────────

func TestAdmin_AuditLogPersistence(t *testing.T) {
	dir := t.TempDir()
	auditDir := filepath.Join(dir, "audit")

	// Write events to the first log instance.
	log1, err := admin.NewAuditLog(auditDir)
	if err != nil {
		t.Fatalf("NewAuditLog: %v", err)
	}
	log1.Record(admin.AuditEvent{Actor: "ops", Action: "rounds.pause", Details: "test event 1"})
	log1.Record(admin.AuditEvent{Actor: "ops", Action: "rounds.resume", Details: "test event 2"})
	if err := log1.Close(); err != nil {
		t.Fatalf("Close log1: %v", err)
	}

	// Open a fresh log instance over the same directory and load from file.
	log2, err := admin.NewAuditLog("") // in-memory, no write
	if err != nil {
		t.Fatalf("NewAuditLog log2: %v", err)
	}
	if err := log2.LoadFromFile(filepath.Join(auditDir, "admin_audit.jsonl")); err != nil {
		t.Fatalf("LoadFromFile: %v", err)
	}

	total := log2.Total()
	if total < 2 {
		t.Fatalf("loaded %d events, want at least 2", total)
	}

	events := log2.List(0, 10)
	actions := make(map[string]bool)
	for _, ev := range events {
		actions[ev.Action] = true
	}
	if !actions["rounds.pause"] {
		t.Error("persisted log missing rounds.pause event")
	}
	if !actions["rounds.resume"] {
		t.Error("persisted log missing rounds.resume event")
	}
}

// ── TestAdmin_Health ──────────────────────────────────────────────────────────

func TestAdmin_Health(t *testing.T) {
	_, _, h, _ := newTestEnv(t, 0)
	w := doJSON(t, h, "GET", "/admin/health", nil)
	if w.Code != http.StatusOK {
		t.Fatalf("health status %d, want 200", w.Code)
	}
}

// ── TestAdmin_WalletList ──────────────────────────────────────────────────────

func TestAdmin_WalletList(t *testing.T) {
	_, wallet, h, _ := newTestEnv(t, 0)
	wallet.SetBalance("alice", 1000)
	wallet.SetBalance("bob", 500)

	w := doJSON(t, h, "GET", "/admin/wallets", nil)
	if w.Code != http.StatusOK {
		t.Fatalf("wallets status %d: %s", w.Code, w.Body)
	}
	var list []struct {
		PlayerID string  `json:"player_id"`
		Balance  float64 `json:"balance"`
	}
	mustDecodeJSON(t, w, &list)
	if len(list) < 2 {
		t.Fatalf("expected at least 2 players, got %d", len(list))
	}
}

// ── TestAdmin_ConfigEndpoint ──────────────────────────────────────────────────

func TestAdmin_ConfigEndpoint(t *testing.T) {
	mgr, _, h, _ := newTestEnv(t, 0)
	w := doJSON(t, h, "GET", "/admin/config", nil)
	if w.Code != http.StatusOK {
		t.Fatalf("config status %d: %s", w.Code, w.Body)
	}
	var snap struct {
		RTPBps     uint32 `json:"rtp_bps"`
		MaxMarbles int    `json:"max_marbles"`
		Paused     bool   `json:"paused"`
	}
	mustDecodeJSON(t, w, &snap)
	if snap.RTPBps != mgr.Config().RTPBps {
		t.Fatalf("rtp_bps mismatch: got %d, want %d", snap.RTPBps, mgr.Config().RTPBps)
	}
	if snap.MaxMarbles != 30 {
		t.Fatalf("max_marbles %d, want 30", snap.MaxMarbles)
	}
	if snap.Paused {
		t.Fatal("paused should be false initially")
	}
}
