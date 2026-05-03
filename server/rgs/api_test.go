package rgs

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"testing"
)

// httpFixture brings up an httptest.Server backed by a Manager whose sim
// is the same fakeSim used in manager_test.go. Tests drive the full HTTP
// surface without spinning up Godot.
func httpFixture(t *testing.T, winnerIndex int) (string, *MockWallet, *Manager, func()) {
	t.Helper()
	mgr, wallet, _ := newTestManager(t, winnerIndex)
	srv := httptest.NewServer(NewHTTPHandler(mgr).Routes())
	return srv.URL, wallet, mgr, srv.Close
}

func postJSON(t *testing.T, url string, body any) *http.Response {
	t.Helper()
	var buf bytes.Buffer
	if body != nil {
		if err := json.NewEncoder(&buf).Encode(body); err != nil {
			t.Fatalf("encode body: %v", err)
		}
	}
	resp, err := http.Post(url, "application/json", &buf)
	if err != nil {
		t.Fatalf("POST %s: %v", url, err)
	}
	return resp
}

func decodeBody(t *testing.T, resp *http.Response, dst any) {
	t.Helper()
	defer resp.Body.Close()
	if err := json.NewDecoder(resp.Body).Decode(dst); err != nil {
		t.Fatalf("decode response: %v", err)
	}
}

func TestHTTP_Health(t *testing.T) {
	url, _, _, cleanup := httpFixture(t, 0)
	defer cleanup()
	resp, err := http.Get(url + "/v1/health")
	if err != nil {
		t.Fatalf("GET /v1/health: %v", err)
	}
	if resp.StatusCode != 200 {
		t.Fatalf("status %d, want 200", resp.StatusCode)
	}
}

func TestHTTP_OpenSessionThenBetThenRunRound(t *testing.T) {
	url, wallet, _, cleanup := httpFixture(t, 0) // marble 0 wins
	defer cleanup()
	wallet.SetBalance("alice", 1000)

	// 1. Open session.
	resp := postJSON(t, url+"/v1/sessions", openSessionRequest{PlayerID: "alice"})
	if resp.StatusCode != http.StatusCreated {
		t.Fatalf("open session: status %d", resp.StatusCode)
	}
	var sess sessionResponse
	decodeBody(t, resp, &sess)
	if sess.State != "OPEN" {
		t.Fatalf("session state %q, want OPEN", sess.State)
	}
	if sess.Balance != 1000 {
		t.Fatalf("session balance %d, want 1000", sess.Balance)
	}

	// 2. Place bet.
	resp = postJSON(t, fmt.Sprintf("%s/v1/sessions/%s/bet", url, sess.SessionID), placeBetRequest{Amount: 100})
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("place bet: status %d", resp.StatusCode)
	}
	var afterBet sessionResponse
	decodeBody(t, resp, &afterBet)
	if afterBet.State != "BET" {
		t.Fatalf("session state after bet %q, want BET", afterBet.State)
	}
	if afterBet.Bet == nil || afterBet.Bet.Amount != 100 {
		t.Fatalf("bet not attached or wrong amount: %+v", afterBet.Bet)
	}
	if afterBet.Balance != 900 {
		t.Fatalf("balance after bet %d, want 900", afterBet.Balance)
	}

	// 3. Run a round (sync).
	resp = postJSON(t, url+"/v1/rounds/run?wait=true", nil)
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("run round: status %d", resp.StatusCode)
	}
	var roundResp struct {
		RoundID  uint64               `json:"round_id"`
		TrackID  uint8                `json:"track_id"`
		Winner   replayWinner         `json:"winner"`
		Outcomes []settlementResponse `json:"outcomes"`
	}
	decodeBody(t, resp, &roundResp)
	if roundResp.Winner.MarbleIndex != 0 {
		t.Fatalf("winner marble %d, want 0", roundResp.Winner.MarbleIndex)
	}
	if len(roundResp.Outcomes) != 1 || !roundResp.Outcomes[0].Won {
		t.Fatalf("expected 1 winning outcome, got %+v", roundResp.Outcomes)
	}
	if roundResp.Outcomes[0].PrizeAmount != 2850 {
		t.Fatalf("prize %d, want 2850", roundResp.Outcomes[0].PrizeAmount)
	}

	// 4. Verify session shows SETTLED + last result via GET.
	getResp, err := http.Get(fmt.Sprintf("%s/v1/sessions/%s", url, sess.SessionID))
	if err != nil {
		t.Fatalf("GET session: %v", err)
	}
	var final sessionResponse
	decodeBody(t, getResp, &final)
	if final.State != "SETTLED" {
		t.Fatalf("post-round state %q, want SETTLED", final.State)
	}
	if final.LastResult == nil || !final.LastResult.Won {
		t.Fatalf("LastResult missing or Won=false: %+v", final.LastResult)
	}
	if final.Balance != 3750 {
		t.Fatalf("post-round balance %d, want 3750", final.Balance)
	}
}

func TestHTTP_PlaceBetInsufficientFundsReturns402(t *testing.T) {
	url, wallet, _, cleanup := httpFixture(t, 0)
	defer cleanup()
	wallet.SetBalance("bob", 30)

	openResp := postJSON(t, url+"/v1/sessions", openSessionRequest{PlayerID: "bob"})
	var sess sessionResponse
	decodeBody(t, openResp, &sess)

	resp := postJSON(t, fmt.Sprintf("%s/v1/sessions/%s/bet", url, sess.SessionID), placeBetRequest{Amount: 100})
	if resp.StatusCode != http.StatusPaymentRequired {
		t.Fatalf("status %d, want 402 (insufficient funds)", resp.StatusCode)
	}
	var errResp errorResponse
	decodeBody(t, resp, &errResp)
	if errResp.Error == "" {
		t.Fatalf("error message missing")
	}
}

func TestHTTP_GetUnknownSessionReturns404(t *testing.T) {
	url, _, _, cleanup := httpFixture(t, 0)
	defer cleanup()
	resp, err := http.Get(url + "/v1/sessions/sess_does_not_exist")
	if err != nil {
		t.Fatalf("GET: %v", err)
	}
	if resp.StatusCode != http.StatusNotFound {
		t.Fatalf("status %d, want 404", resp.StatusCode)
	}
}

func TestHTTP_CloseSessionSucceedsFromOpen(t *testing.T) {
	url, _, mgr, cleanup := httpFixture(t, 0)
	defer cleanup()

	openResp := postJSON(t, url+"/v1/sessions", openSessionRequest{PlayerID: "carol"})
	var sess sessionResponse
	decodeBody(t, openResp, &sess)

	resp := postJSON(t, fmt.Sprintf("%s/v1/sessions/%s/close", url, sess.SessionID), nil)
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("close: status %d", resp.StatusCode)
	}
	// Verify state transitioned to CLOSED via mgr.
	s, _ := mgr.Session(sess.SessionID)
	state, _, _ := s.Snapshot()
	if state != SessionClosed {
		t.Fatalf("state %s, want CLOSED", state)
	}
}

func TestHTTP_RunRoundAsyncReturns202(t *testing.T) {
	url, _, _, cleanup := httpFixture(t, 0)
	defer cleanup()
	resp := postJSON(t, url+"/v1/rounds/run", nil)
	if resp.StatusCode != http.StatusAccepted {
		t.Fatalf("status %d, want 202", resp.StatusCode)
	}
	// Wait briefly for the goroutine. The fakeSim is fast (<10ms) but we
	// don't have a notification mechanism — give it a short window.
	// In production, clients poll /v1/sessions/{id} for SETTLED.
	// Avoid sleep flakiness: just confirm the 202 fired.
	_ = context.Background()
}

func TestHTTP_StartRoundReturnsSpec(t *testing.T) {
	url, _, _, cleanup := httpFixture(t, 0)
	defer cleanup()

	resp := postJSON(t, url+"/v1/rounds/start", nil)
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("start round: status %d, want 200", resp.StatusCode)
	}
	var spec RoundSpec
	decodeBody(t, resp, &spec)

	if spec.RoundID == 0 {
		t.Fatalf("round_id is zero — expected a unix-nano timestamp")
	}
	if len(spec.ServerSeedHex) != 64 {
		t.Fatalf("server_seed_hex length %d, want 64 (32-byte hex)", len(spec.ServerSeedHex))
	}
	if len(spec.ClientSeeds) != 30 { // MaxMarbles = 30 in test fixture
		t.Fatalf("client_seeds count %d, want 30", len(spec.ClientSeeds))
	}
	// All client seeds are empty strings in MVP.
	for i, cs := range spec.ClientSeeds {
		if cs != "" {
			t.Fatalf("client_seeds[%d] = %q, want empty string", i, cs)
		}
	}
}

func TestHTTP_StartRoundTracksRotation(t *testing.T) {
	// Two consecutive /v1/rounds/start calls must not return the same
	// track_id (the no-back-to-back invariant from selectTrack).
	// This can only be guaranteed when the pool has > 1 entry, which
	// the test fixture configures (pool = [0,1,2,3,4,5]).
	url, _, _, cleanup := httpFixture(t, 0)
	defer cleanup()

	var spec1, spec2 RoundSpec
	decodeBody(t, postJSON(t, url+"/v1/rounds/start", nil), &spec1)
	decodeBody(t, postJSON(t, url+"/v1/rounds/start", nil), &spec2)
	if spec1.TrackID == spec2.TrackID {
		t.Fatalf("back-to-back /start calls returned same track_id %d", spec1.TrackID)
	}
}
