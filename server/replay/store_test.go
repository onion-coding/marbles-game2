package replay

import (
	"bytes"
	"encoding/hex"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func sampleManifest() *Manifest {
	return &Manifest{
		RoundID:           42,
		ProtocolVersion:   2,
		TickRateHz:        60,
		ServerSeedHashHex: strings.Repeat("ab", 32),
		ServerSeedHex:     strings.Repeat("cd", 32),
		Participants: []Participant{
			{MarbleIndex: 0, Name: "alice", ClientSeed: "a"},
			{MarbleIndex: 1, Name: "bob", ClientSeed: "b"},
		},
		Winner: Winner{MarbleIndex: 1, FinishTick: 417},
	}
}

func TestSaveLoadRoundTrip(t *testing.T) {
	root := t.TempDir()
	s, err := New(root)
	if err != nil {
		t.Fatalf("New: %v", err)
	}

	payload := bytes.Repeat([]byte("replay-bytes-"), 512)
	m := sampleManifest()
	if err := s.Save(m, bytes.NewReader(payload)); err != nil {
		t.Fatalf("Save: %v", err)
	}
	if m.ReplaySHA256Hex == "" {
		t.Fatal("Save did not populate ReplaySHA256Hex")
	}
	if m.CreatedAt.IsZero() {
		t.Fatal("Save did not set CreatedAt")
	}

	loaded, replayPath, err := s.Load(42)
	if err != nil {
		t.Fatalf("Load: %v", err)
	}
	if loaded.RoundID != 42 {
		t.Errorf("RoundID: got %d want 42", loaded.RoundID)
	}
	if loaded.ReplaySHA256Hex != m.ReplaySHA256Hex {
		t.Errorf("ReplaySHA256Hex mismatch: got %s want %s", loaded.ReplaySHA256Hex, m.ReplaySHA256Hex)
	}
	if len(loaded.Participants) != 2 || loaded.Participants[1].Name != "bob" {
		t.Errorf("participants not preserved: %+v", loaded.Participants)
	}

	readBack, err := os.ReadFile(replayPath)
	if err != nil {
		t.Fatalf("read replay: %v", err)
	}
	if !bytes.Equal(readBack, payload) {
		t.Errorf("replay bytes changed: got %d bytes want %d", len(readBack), len(payload))
	}
}

func TestSaveRefusesOverwrite(t *testing.T) {
	root := t.TempDir()
	s, _ := New(root)

	if err := s.Save(sampleManifest(), bytes.NewReader([]byte("first"))); err != nil {
		t.Fatalf("first Save: %v", err)
	}
	err := s.Save(sampleManifest(), bytes.NewReader([]byte("second")))
	if !errors.Is(err, ErrRoundExists) {
		t.Fatalf("second Save: got %v want ErrRoundExists", err)
	}

	// Original bytes must still be there.
	_, replayPath, _ := s.Load(42)
	b, _ := os.ReadFile(replayPath)
	if string(b) != "first" {
		t.Errorf("store overwrote on duplicate Save: got %q", string(b))
	}
}

func TestLoadMissingRound(t *testing.T) {
	s, _ := New(t.TempDir())
	if _, _, err := s.Load(999); !errors.Is(err, ErrRoundMissing) {
		t.Fatalf("Load missing: got %v want ErrRoundMissing", err)
	}
}

func TestListReturnsStoredRoundsSorted(t *testing.T) {
	root := t.TempDir()
	s, _ := New(root)

	for _, id := range []uint64{5, 100, 2, 50} {
		m := sampleManifest()
		m.RoundID = id
		if err := s.Save(m, bytes.NewReader([]byte("x"))); err != nil {
			t.Fatalf("Save %d: %v", id, err)
		}
	}

	// Drop a non-numeric dir and a stray file to confirm they're ignored.
	_ = os.Mkdir(filepath.Join(root, "not-a-round"), 0o755)
	_ = os.WriteFile(filepath.Join(root, "stray.txt"), []byte("x"), 0o644)

	got, err := s.List()
	if err != nil {
		t.Fatalf("List: %v", err)
	}
	want := []uint64{2, 5, 50, 100}
	if len(got) != len(want) {
		t.Fatalf("List length: got %d want %d (%v)", len(got), len(want), got)
	}
	for i, id := range want {
		if got[i] != id {
			t.Errorf("List[%d]: got %d want %d", i, got[i], id)
		}
	}
}

func TestVerifyDetectsReplayTampering(t *testing.T) {
	root := t.TempDir()
	s, _ := New(root)

	if err := s.Save(sampleManifest(), bytes.NewReader([]byte("canonical"))); err != nil {
		t.Fatalf("Save: %v", err)
	}
	if err := s.Verify(42); err != nil {
		t.Fatalf("Verify clean store: %v", err)
	}

	// Edit replay.bin out from under the manifest.
	_, replayPath, _ := s.Load(42)
	if err := os.WriteFile(replayPath, []byte("tampered"), 0o644); err != nil {
		t.Fatalf("tamper: %v", err)
	}
	if err := s.Verify(42); !errors.Is(err, ErrChecksumMismatch) {
		t.Fatalf("Verify tampered: got %v want ErrChecksumMismatch", err)
	}
}

func TestSaveRejectsInvalidManifest(t *testing.T) {
	s, _ := New(t.TempDir())

	// Missing round_id.
	bad := sampleManifest()
	bad.RoundID = 0
	if err := s.Save(bad, bytes.NewReader(nil)); !errors.Is(err, ErrInvalidManifest) {
		t.Errorf("empty round_id: got %v want ErrInvalidManifest", err)
	}

	// Missing revealed seed (Save should require the reveal — if you haven't
	// revealed yet, you shouldn't be persisting an audit entry).
	bad = sampleManifest()
	bad.ServerSeedHex = ""
	if err := s.Save(bad, bytes.NewReader(nil)); !errors.Is(err, ErrInvalidManifest) {
		t.Errorf("missing server_seed: got %v want ErrInvalidManifest", err)
	}

	// No participants.
	bad = sampleManifest()
	bad.Participants = nil
	if err := s.Save(bad, bytes.NewReader(nil)); !errors.Is(err, ErrInvalidManifest) {
		t.Errorf("no participants: got %v want ErrInvalidManifest", err)
	}
}

func TestSaveReplaySHAIsLowercaseHex(t *testing.T) {
	s, _ := New(t.TempDir())
	m := sampleManifest()
	if err := s.Save(m, bytes.NewReader([]byte("hello"))); err != nil {
		t.Fatalf("Save: %v", err)
	}
	if _, err := hex.DecodeString(m.ReplaySHA256Hex); err != nil {
		t.Errorf("ReplaySHA256Hex not hex-decodable: %v", err)
	}
	if m.ReplaySHA256Hex != strings.ToLower(m.ReplaySHA256Hex) {
		t.Errorf("ReplaySHA256Hex has uppercase: %s", m.ReplaySHA256Hex)
	}
}
