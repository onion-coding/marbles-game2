package replay

import (
	"bytes"
	"encoding/hex"
	"encoding/json"
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

// ── v4 manifest tests ──────────────────────────────────────────────────────

// sampleV4Manifest returns a fully-populated v4 manifest suitable for
// roundtrip and consistency tests. All new v4 fields are non-zero so we can
// confirm they survive the JSON save+load cycle unchanged.
func sampleV4Manifest() *Manifest {
	return &Manifest{
		RoundID:           1_000_000_001,
		ProtocolVersion:   ProtocolVersion4,
		TickRateHz:        60,
		TrackID:           3,
		ServerSeedHashHex: strings.Repeat("ab", 32),
		ServerSeedHex:     strings.Repeat("cd", 32),
		Participants: []Participant{
			{MarbleIndex: 0, Name: "p0", ClientSeed: "s0"},
		},
		Winner: Winner{MarbleIndex: 7, FinishTick: 400},
		Podium: [3]PodiumEntry{
			{MarbleIndex: 7, FinishTick: 400},
			{MarbleIndex: 15, FinishTick: 412},
			{MarbleIndex: 22, FinishTick: 425},
		},
		// v4 fields
		MarbleCount: 30,
		PodiumPayouts: &[3]uint64{
			// jackpot fired on marble 7 (1°+Tier2) → 100× × 100 cents = 10000
			10000, // 1°: jackpot → 100× stake
			450,   // 2°: 4.5× stake (no pickup on 2°)
			300,   // 3°: 3× stake  (no pickup on 3°)
		},
		PickupTier1Marbles: []int{1, 2, 3, 4},
		PickupTier2Marble:  7,
		Tier2Active:        true,
		PickupPerMarble:    buildPickupFloat(30, map[int]float64{1: 2, 2: 2, 3: 2, 4: 2, 7: 3}),
		PickupPerMarbleTier: buildPickupTier(30, map[int]uint8{1: 1, 2: 1, 3: 1, 4: 1, 7: 2}),
		JackpotTriggered:   true,
		JackpotMarbleIdx:   7,
		FinishOrder:        []int{7, 15, 22},
	}
}

// buildPickupFloat constructs a []float64 of length n with specified overrides.
func buildPickupFloat(n int, overrides map[int]float64) []float64 {
	out := make([]float64, n)
	for i := range out {
		out[i] = 1.0
	}
	for idx, v := range overrides {
		out[idx] = v
	}
	return out
}

// buildPickupTier constructs a []uint8 of length n with specified overrides.
func buildPickupTier(n int, overrides map[int]uint8) []uint8 {
	out := make([]uint8, n)
	for idx, v := range overrides {
		out[idx] = v
	}
	return out
}

// TestManifest_V4Roundtrip writes a fully-populated v4 manifest to disk and
// reads it back, verifying every v4 field survives the JSON encode/decode
// cycle unchanged.
func TestManifest_V4Roundtrip(t *testing.T) {
	s, _ := New(t.TempDir())
	m := sampleV4Manifest()

	if err := s.Save(m, bytes.NewReader([]byte("v4-replay-data"))); err != nil {
		t.Fatalf("Save: %v", err)
	}

	loaded, _, err := s.Load(m.RoundID)
	if err != nil {
		t.Fatalf("Load: %v", err)
	}

	// Core identity.
	if loaded.ProtocolVersion != ProtocolVersion4 {
		t.Errorf("ProtocolVersion: got %d want %d", loaded.ProtocolVersion, ProtocolVersion4)
	}
	if loaded.MarbleCount != 30 {
		t.Errorf("MarbleCount: got %d want 30", loaded.MarbleCount)
	}

	// PodiumPayouts — all three entries must match exactly.
	if loaded.PodiumPayouts == nil {
		t.Errorf("PodiumPayouts: got nil, want non-nil")
	} else if *loaded.PodiumPayouts != *m.PodiumPayouts {
		t.Errorf("PodiumPayouts: got %v want %v", *loaded.PodiumPayouts, *m.PodiumPayouts)
	}

	// PickupPerMarbleTier — length and spot-check overridden indices.
	if len(loaded.PickupPerMarbleTier) != 30 {
		t.Fatalf("PickupPerMarbleTier length: got %d want 30", len(loaded.PickupPerMarbleTier))
	}
	tierChecks := map[int]uint8{1: 1, 2: 1, 3: 1, 4: 1, 7: 2, 0: 0, 10: 0}
	for idx, want := range tierChecks {
		if got := loaded.PickupPerMarbleTier[idx]; got != want {
			t.Errorf("PickupPerMarbleTier[%d]: got %d want %d", idx, got, want)
		}
	}

	// Jackpot fields.
	if !loaded.JackpotTriggered {
		t.Errorf("JackpotTriggered: got false want true")
	}
	if loaded.JackpotMarbleIdx != 7 {
		t.Errorf("JackpotMarbleIdx: got %d want 7", loaded.JackpotMarbleIdx)
	}

	// FinishOrder — must be preserved exactly.
	if len(loaded.FinishOrder) != 3 || loaded.FinishOrder[0] != 7 || loaded.FinishOrder[1] != 15 || loaded.FinishOrder[2] != 22 {
		t.Errorf("FinishOrder: got %v want [7 15 22]", loaded.FinishOrder)
	}

	// Tier2Active flag.
	if !loaded.Tier2Active {
		t.Errorf("Tier2Active: got false want true")
	}
}

// TestManifest_V3Backward writes a manifest that looks like a v3 record
// (all v4 fields at zero / nil) and verifies that the v4 reader decodes it
// without error and returns zero values for the new fields — as a certified
// auditor would see when re-reading legacy archive data.
func TestManifest_V3Backward(t *testing.T) {
	s, _ := New(t.TempDir())

	// Build a v3-style manifest: ProtocolVersion=3, none of the v4 fields set.
	v3 := &Manifest{
		RoundID:           99,
		ProtocolVersion:   3,
		TickRateHz:        60,
		TrackID:           0,
		ServerSeedHashHex: strings.Repeat("11", 32),
		ServerSeedHex:     strings.Repeat("22", 32),
		Participants: []Participant{
			{MarbleIndex: 0, Name: "legacy", ClientSeed: ""},
		},
		Winner: Winner{MarbleIndex: 3, FinishTick: 500},
		// v4 fields intentionally left zero / nil.
	}

	if err := s.Save(v3, bytes.NewReader([]byte("legacy-replay"))); err != nil {
		t.Fatalf("Save v3-style manifest: %v", err)
	}

	loaded, _, err := s.Load(99)
	if err != nil {
		t.Fatalf("Load v3-style manifest: %v", err)
	}

	// v3 fields must be intact.
	if loaded.ProtocolVersion != 3 {
		t.Errorf("ProtocolVersion: got %d want 3", loaded.ProtocolVersion)
	}
	if loaded.Winner.MarbleIndex != 3 {
		t.Errorf("Winner.MarbleIndex: got %d want 3", loaded.Winner.MarbleIndex)
	}

	// v4 fields must be zero / empty — not fabricated by the reader.
	if loaded.MarbleCount != 0 {
		t.Errorf("MarbleCount: got %d want 0 (absent in v3)", loaded.MarbleCount)
	}
	if loaded.PodiumPayouts != nil {
		t.Errorf("PodiumPayouts: got %v want nil (absent in v3)", *loaded.PodiumPayouts)
	}
	if loaded.PickupPerMarbleTier != nil {
		t.Errorf("PickupPerMarbleTier: got %v want nil (absent in v3)", loaded.PickupPerMarbleTier)
	}
	if loaded.JackpotTriggered {
		t.Errorf("JackpotTriggered: got true want false (absent in v3)")
	}
	if loaded.FinishOrder != nil {
		t.Errorf("FinishOrder: got %v want nil (absent in v3)", loaded.FinishOrder)
	}

	// Also verify that reading the raw JSON of the stored file does NOT
	// contain any v4 keys (omitempty must have suppressed them).
	dir := s.roundDir(99)
	raw, _ := os.ReadFile(filepath.Join(dir, "manifest.json"))
	var probe map[string]json.RawMessage
	if err := json.Unmarshal(raw, &probe); err != nil {
		t.Fatalf("probe unmarshal: %v", err)
	}
	for _, key := range []string{"marble_count", "podium_payouts", "pickup_per_marble_tier", "finish_order"} {
		if _, present := probe[key]; present {
			t.Errorf("v3 manifest unexpectedly contains key %q (omitempty should suppress it)", key)
		}
	}
}

// TestManifest_PickupCounts verifies that PickupPerMarbleTier respects the
// math-model caps: at most 4 marbles with tier==1, at most 1 marble with
// tier==2 (§2.1 of docs/math-model.md).
func TestManifest_PickupCounts(t *testing.T) {
	tier := sampleV4Manifest().PickupPerMarbleTier

	var tier1, tier2 int
	for _, v := range tier {
		switch v {
		case 1:
			tier1++
		case 2:
			tier2++
		}
	}
	if tier1 > 4 {
		t.Errorf("PickupPerMarbleTier: tier1 count %d exceeds cap of 4", tier1)
	}
	if tier2 > 1 {
		t.Errorf("PickupPerMarbleTier: tier2 count %d exceeds cap of 1", tier2)
	}
	// The sample fixture must actually exercise both caps.
	if tier1 != 4 {
		t.Errorf("PickupPerMarbleTier: expected exactly 4 tier-1 entries in sample, got %d", tier1)
	}
	if tier2 != 1 {
		t.Errorf("PickupPerMarbleTier: expected exactly 1 tier-2 entry in sample, got %d", tier2)
	}
}

// TestManifest_JackpotConsistency verifies the three-way invariant required
// by the certification spec: if JackpotTriggered==true then
//  1. JackpotMarbleIdx >= 0
//  2. PickupPerMarbleTier[JackpotMarbleIdx] == 2 (has Tier 2 pickup)
//  3. FinishOrder[0] == JackpotMarbleIdx (the jackpot marble won 1°)
func TestManifest_JackpotConsistency(t *testing.T) {
	cases := []struct {
		name      string
		manifest  *Manifest
		wantError string
	}{
		{
			name:     "valid jackpot",
			manifest: sampleV4Manifest(), // JackpotTriggered=true, idx=7, tier[7]=2, FinishOrder[0]=7
		},
		{
			name: "jackpot but marble index negative",
			manifest: func() *Manifest {
				m := sampleV4Manifest()
				m.JackpotMarbleIdx = -1 // violation: triggered but no valid index
				return m
			}(),
			wantError: "JackpotMarbleIdx must be >= 0 when JackpotTriggered",
		},
		{
			name: "jackpot but marble not tier2",
			manifest: func() *Manifest {
				m := sampleV4Manifest()
				m.PickupPerMarbleTier[7] = 1 // marble 7 is only Tier1, not Tier2
				return m
			}(),
			wantError: "PickupPerMarbleTier[JackpotMarbleIdx] must be 2",
		},
		{
			name: "jackpot but wrong winner",
			manifest: func() *Manifest {
				m := sampleV4Manifest()
				m.FinishOrder[0] = 15 // marble 15 listed as 1°, not the jackpot marble (7)
				return m
			}(),
			wantError: "FinishOrder[0] must equal JackpotMarbleIdx",
		},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			err := ValidateJackpotConsistency(tc.manifest)
			if tc.wantError == "" {
				if err != nil {
					t.Errorf("expected no error, got: %v", err)
				}
			} else {
				if err == nil {
					t.Errorf("expected error containing %q, got nil", tc.wantError)
				} else if !strings.Contains(err.Error(), tc.wantError) {
					t.Errorf("error %q does not contain %q", err.Error(), tc.wantError)
				}
			}
		})
	}
}

// TestManifest_JackpotConsistency_NoJackpot verifies that when
// JackpotTriggered==false the validator accepts any JackpotMarbleIdx value
// (including -1 and valid indices) without complaint.
func TestManifest_JackpotConsistency_NoJackpot(t *testing.T) {
	m := sampleV4Manifest()
	m.JackpotTriggered = false
	m.JackpotMarbleIdx = -1
	if err := ValidateJackpotConsistency(m); err != nil {
		t.Errorf("no-jackpot manifest: unexpected error: %v", err)
	}
}
