package api

import (
	"bytes"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/onion-coding/marbles-game2/server/replay"
)

func newTestServer(t *testing.T) (*Server, *replay.Store) {
	t.Helper()
	store, err := replay.New(t.TempDir())
	if err != nil {
		t.Fatalf("replay.New: %v", err)
	}
	return New(store), store
}

func saveRound(t *testing.T, store *replay.Store, id uint64, payload []byte) {
	t.Helper()
	m := &replay.Manifest{
		RoundID:           id,
		ProtocolVersion:   2,
		TickRateHz:        60,
		ServerSeedHashHex: strings.Repeat("ab", 32),
		ServerSeedHex:     strings.Repeat("cd", 32),
		Participants:      []replay.Participant{{MarbleIndex: 0, Name: "alice"}},
		Winner:            replay.Winner{MarbleIndex: 0, FinishTick: 100},
	}
	if err := store.Save(m, bytes.NewReader(payload)); err != nil {
		t.Fatalf("Save round %d: %v", id, err)
	}
}

func TestListRoundsReturnsAscending(t *testing.T) {
	s, store := newTestServer(t)
	for _, id := range []uint64{100, 5, 50} {
		saveRound(t, store, id, []byte("x"))
	}

	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodGet, "/rounds", nil)
	s.Handler().ServeHTTP(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("status: got %d want 200, body=%s", rec.Code, rec.Body.String())
	}
	// IDs are serialized as strings to preserve precision for clients that
	// parse JSON numbers as float64 (Godot, browsers).
	var got struct {
		RoundIDs []string `json:"round_ids"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &got); err != nil {
		t.Fatalf("decode: %v", err)
	}
	want := []string{"5", "50", "100"}
	if len(got.RoundIDs) != len(want) {
		t.Fatalf("got %v want %v", got.RoundIDs, want)
	}
	for i, id := range want {
		if got.RoundIDs[i] != id {
			t.Errorf("[%d]: got %q want %q", i, got.RoundIDs[i], id)
		}
	}
}

func TestGetManifest(t *testing.T) {
	s, store := newTestServer(t)
	saveRound(t, store, 42, []byte("replay-payload"))

	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodGet, "/rounds/42", nil)
	s.Handler().ServeHTTP(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("status: got %d want 200, body=%s", rec.Code, rec.Body.String())
	}
	var m replay.Manifest
	if err := json.Unmarshal(rec.Body.Bytes(), &m); err != nil {
		t.Fatalf("decode: %v", err)
	}
	if m.RoundID != 42 {
		t.Errorf("RoundID: got %d want 42", m.RoundID)
	}
	if m.ReplaySHA256Hex == "" {
		t.Error("ReplaySHA256Hex not populated")
	}
	if len(m.Participants) != 1 || m.Participants[0].Name != "alice" {
		t.Errorf("participants not preserved: %+v", m.Participants)
	}
}

func TestGetReplayStreamsBytesWithETag(t *testing.T) {
	s, store := newTestServer(t)
	payload := bytes.Repeat([]byte("tick-bytes-"), 1024) // ~12 KB
	saveRound(t, store, 7, payload)

	// First grab the manifest so we know the expected ETag.
	var m replay.Manifest
	{
		rec := httptest.NewRecorder()
		req := httptest.NewRequest(http.MethodGet, "/rounds/7", nil)
		s.Handler().ServeHTTP(rec, req)
		if err := json.Unmarshal(rec.Body.Bytes(), &m); err != nil {
			t.Fatalf("manifest decode: %v", err)
		}
	}

	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodGet, "/rounds/7/replay.bin", nil)
	s.Handler().ServeHTTP(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("status: got %d want 200, body=%s", rec.Code, rec.Body.String())
	}
	if got := rec.Header().Get("Content-Type"); got != "application/octet-stream" {
		t.Errorf("Content-Type: got %q want application/octet-stream", got)
	}
	wantETag := `"` + m.ReplaySHA256Hex + `"`
	if got := rec.Header().Get("ETag"); got != wantETag {
		t.Errorf("ETag: got %q want %q", got, wantETag)
	}
	if got := rec.Header().Get("Cache-Control"); !strings.Contains(got, "immutable") {
		t.Errorf("Cache-Control missing immutable: %q", got)
	}

	body, _ := io.ReadAll(rec.Body)
	if !bytes.Equal(body, payload) {
		t.Errorf("replay bytes differ: got %d want %d", len(body), len(payload))
	}
}

func TestGetUnknownRoundReturns404(t *testing.T) {
	s, _ := newTestServer(t)

	for _, path := range []string{"/rounds/999", "/rounds/999/replay.bin"} {
		rec := httptest.NewRecorder()
		req := httptest.NewRequest(http.MethodGet, path, nil)
		s.Handler().ServeHTTP(rec, req)
		if rec.Code != http.StatusNotFound {
			t.Errorf("%s: got %d want 404, body=%s", path, rec.Code, rec.Body.String())
		}
	}
}

func TestBadRoundIDReturns400(t *testing.T) {
	s, _ := newTestServer(t)

	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodGet, "/rounds/not-a-number", nil)
	s.Handler().ServeHTTP(rec, req)
	if rec.Code != http.StatusBadRequest {
		t.Errorf("status: got %d want 400, body=%s", rec.Code, rec.Body.String())
	}
}

func TestCORSHeadersPresentAndPermissive(t *testing.T) {
	s, store := newTestServer(t)
	saveRound(t, store, 1, []byte("x"))

	// Preflight.
	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodOptions, "/rounds/1", nil)
	s.Handler().ServeHTTP(rec, req)
	if rec.Code != http.StatusNoContent {
		t.Errorf("preflight status: got %d want 204", rec.Code)
	}
	if got := rec.Header().Get("Access-Control-Allow-Origin"); got != "*" {
		t.Errorf("preflight Allow-Origin: got %q want *", got)
	}

	// Regular GET should still include CORS header.
	rec = httptest.NewRecorder()
	req = httptest.NewRequest(http.MethodGet, "/rounds/1", nil)
	s.Handler().ServeHTTP(rec, req)
	if got := rec.Header().Get("Access-Control-Allow-Origin"); got != "*" {
		t.Errorf("GET Allow-Origin: got %q want *", got)
	}
	if got := rec.Header().Get("Access-Control-Expose-Headers"); !strings.Contains(got, "ETag") {
		t.Errorf("Expose-Headers missing ETag: %q", got)
	}
}

func TestReplayRangeRequestServesPartialContent(t *testing.T) {
	s, store := newTestServer(t)
	payload := bytes.Repeat([]byte("X"), 10_000)
	saveRound(t, store, 1, payload)

	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodGet, "/rounds/1/replay.bin", nil)
	req.Header.Set("Range", "bytes=100-199")
	s.Handler().ServeHTTP(rec, req)

	if rec.Code != http.StatusPartialContent {
		t.Fatalf("status: got %d want 206, body=%s", rec.Code, rec.Body.String())
	}
	if rec.Body.Len() != 100 {
		t.Errorf("range body length: got %d want 100", rec.Body.Len())
	}
}
