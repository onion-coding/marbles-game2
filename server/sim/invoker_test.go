package sim

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// Integration test: requires Godot on disk. Skipped unless both env vars are set:
//
//	MARBLES_GODOT_BIN     — absolute path to the Godot executable
//	MARBLES_PROJECT_PATH  — absolute path to the game/ directory
//
// Run with e.g.:
//
//	MARBLES_GODOT_BIN="C:/Users/sergi/Godot/Godot_v4.6.2-stable_win64.exe" \
//	MARBLES_PROJECT_PATH="C:/Users/sergi/projects/marbles-game/game" \
//	go test ./sim/... -v -run TestRunEndToEnd
//
// The test runs a full race (~7s wall clock) so don't put it in the fast path.
func TestRunEndToEnd(t *testing.T) {
	godot := os.Getenv("MARBLES_GODOT_BIN")
	project := os.Getenv("MARBLES_PROJECT_PATH")
	if godot == "" || project == "" {
		t.Skip("set MARBLES_GODOT_BIN and MARBLES_PROJECT_PATH to run the Godot integration test")
	}

	workDir := t.TempDir()

	var seed [32]byte
	for i := range seed {
		seed[i] = byte(i * 7) // arbitrary deterministic pattern
	}
	clientSeeds := make([]string, 20)
	for i := range clientSeeds {
		clientSeeds[i] = ""
	}

	res, err := Run(context.Background(), Request{
		GodotBin:    godot,
		ProjectPath: project,
		WorkDir:     workDir,
		RoundID:     42,
		ServerSeed:  seed,
		ClientSeeds: clientSeeds,
		Timeout:     30 * time.Second,
		Stderr:      os.Stderr,
	})
	if err != nil {
		t.Fatalf("Run: %v", err)
	}

	if res.RoundID != 42 {
		t.Errorf("RoundID: got %d want 42", res.RoundID)
	}
	if res.WinnerMarbleIndex < 0 || res.WinnerMarbleIndex >= 20 {
		t.Errorf("WinnerMarbleIndex out of range: %d", res.WinnerMarbleIndex)
	}
	if res.FinishTick <= 0 {
		t.Errorf("FinishTick should be positive, got %d", res.FinishTick)
	}
	if res.TickRateHz != 60 {
		t.Errorf("TickRateHz: got %d want 60", res.TickRateHz)
	}

	// Verify the status matches what Godot computed for the commit: a fresh SHA-256
	// of the supplied seed. If this fails, Godot consumed a different seed.
	gotHash, err := hex.DecodeString(res.ServerSeedHashHex)
	if err != nil {
		t.Fatalf("ServerSeedHashHex not valid hex: %v", err)
	}
	wantHash := sha256.Sum256(seed[:])
	if string(gotHash) != string(wantHash[:]) {
		t.Errorf("server seed hash mismatch\n  got  %s\n  want %x", res.ServerSeedHashHex, wantHash)
	}

	// Replay file should exist and be non-trivial in size.
	info, err := os.Stat(res.ReplayPath)
	if err != nil {
		t.Fatalf("stat replay: %v", err)
	}
	if info.Size() < 10_000 {
		t.Errorf("replay suspiciously small: %d bytes", info.Size())
	}
	// Sanity: ReplayPath reported by Godot should live inside WorkDir.
	rel, err := filepath.Rel(workDir, filepath.FromSlash(res.ReplayPath))
	if err != nil || strings.HasPrefix(rel, "..") {
		t.Errorf("replay path %q escaped work dir %q (rel=%q err=%v)", res.ReplayPath, workDir, rel, err)
	}
}

func TestRunRejectsMissingFields(t *testing.T) {
	_, err := Run(context.Background(), Request{
		GodotBin:    "",
		ProjectPath: "x",
		WorkDir:     "y",
		ClientSeeds: []string{"a"},
	})
	if err == nil {
		t.Fatal("expected error for missing GodotBin")
	}

	_, err = Run(context.Background(), Request{
		GodotBin:    "g",
		ProjectPath: "x",
		WorkDir:     "y",
		ClientSeeds: nil,
	})
	if err == nil {
		t.Fatal("expected error for empty ClientSeeds")
	}
}
