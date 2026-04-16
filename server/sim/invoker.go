// Package sim spawns the Godot headless simulator as a subprocess and
// collects the replay + race result. The simulator reads a JSON round-spec
// written by this package and writes a JSON status file when it finishes;
// stdout is kept for human logs only. See game/main.gd for the other side.
package sim

import (
	"context"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"time"
)

// Request configures a single sim run.
type Request struct {
	// GodotBin: absolute path to the Godot executable (e.g. C:\Users\...\Godot_v4.6.2-stable_win64.exe).
	GodotBin string
	// ProjectPath: absolute path to the Godot project dir (the one containing project.godot).
	ProjectPath string
	// WorkDir: directory where the invoker writes the spec + status + replay files.
	// Created if missing. Files inside are left for audit; the caller is responsible for cleanup.
	WorkDir string
	// Round parameters.
	RoundID     uint64
	ServerSeed  [32]byte
	ClientSeeds []string
	// Timeout: hard cap on the subprocess. 0 means no timeout (not recommended).
	Timeout time.Duration
	// Stderr: if non-nil, Godot's combined stdout+stderr is also streamed here.
	// Otherwise it's discarded. Useful for surfacing sim crashes during development.
	Stderr io.Writer
	// LiveStreamAddr: if non-empty ("host:port"), the sim connects to this TCP
	// address during the race and streams HEADER + per-tick frames. Typically
	// points at a replayd instance's --stream-tcp port. Optional — the sim
	// still writes the full replay to disk regardless.
	LiveStreamAddr string
}

// Result is the parsed outcome.
type Result struct {
	RoundID           uint64
	WinnerMarbleIndex int
	FinishTick        int
	ReplayPath        string
	ServerSeedHashHex string
	TickRateHz        int
}

type statusFile struct {
	RoundID           uint64 `json:"round_id"`
	OK                bool   `json:"ok"`
	WinnerMarbleIndex int    `json:"winner_marble_index"`
	FinishTick        int    `json:"finish_tick"`
	ReplayPath        string `json:"replay_path"`
	ServerSeedHashHex string `json:"server_seed_hash_hex"`
	TickRateHz        int    `json:"tick_rate_hz"`
}

type specFile struct {
	RoundID        uint64   `json:"round_id"`
	ServerSeedHex  string   `json:"server_seed_hex"`
	ClientSeeds    []string `json:"client_seeds"`
	ReplayPath     string   `json:"replay_path"`
	StatusPath     string   `json:"status_path"`
	LiveStreamAddr string   `json:"live_stream_addr,omitempty"`
}

var (
	ErrGodotExit    = errors.New("sim: godot subprocess exited non-zero")
	ErrNoStatus     = errors.New("sim: godot did not write status file")
	ErrStatusNotOK  = errors.New("sim: status.ok=false (race did not finish cleanly)")
	ErrMissingField = errors.New("sim: request missing required field")
)

// Run writes a round-spec, spawns Godot, waits for it to exit, and parses the status.
// Blocks until the sim exits or ctx is done. The spec/status/replay files are left on
// disk inside req.WorkDir for audit; the caller owns cleanup.
func Run(ctx context.Context, req Request) (Result, error) {
	if req.GodotBin == "" || req.ProjectPath == "" || req.WorkDir == "" {
		return Result{}, fmt.Errorf("%w: GodotBin, ProjectPath, and WorkDir are required", ErrMissingField)
	}
	if len(req.ClientSeeds) == 0 {
		return Result{}, fmt.Errorf("%w: ClientSeeds must be non-empty", ErrMissingField)
	}

	if err := os.MkdirAll(req.WorkDir, 0o755); err != nil {
		return Result{}, fmt.Errorf("sim: mkdir workdir: %w", err)
	}

	specPath := filepath.Join(req.WorkDir, "spec.json")
	statusPath := filepath.Join(req.WorkDir, "status.json")
	replayPath := filepath.Join(req.WorkDir, "replay.bin")

	// Stale files from a prior run would silently be picked up below. Clear them.
	_ = os.Remove(statusPath)
	_ = os.Remove(replayPath)

	spec := specFile{
		RoundID:       req.RoundID,
		ServerSeedHex: hex.EncodeToString(req.ServerSeed[:]),
		ClientSeeds:   req.ClientSeeds,
		// Godot reads these paths with forward slashes — normalize so a Windows
		// backslash path doesn't turn into an escape sequence in JSON.
		ReplayPath:     filepath.ToSlash(replayPath),
		StatusPath:     filepath.ToSlash(statusPath),
		LiveStreamAddr: req.LiveStreamAddr,
	}
	if err := writeJSON(specPath, spec); err != nil {
		return Result{}, fmt.Errorf("sim: write spec: %w", err)
	}

	runCtx := ctx
	if req.Timeout > 0 {
		var cancel context.CancelFunc
		runCtx, cancel = context.WithTimeout(ctx, req.Timeout)
		defer cancel()
	}

	cmd := exec.CommandContext(runCtx, req.GodotBin,
		"--headless",
		"--path", req.ProjectPath,
		"res://main.tscn",
		"++",
		"--round-spec="+filepath.ToSlash(specPath),
	)
	if req.Stderr != nil {
		cmd.Stdout = req.Stderr
		cmd.Stderr = req.Stderr
	}

	if err := cmd.Run(); err != nil {
		return Result{}, fmt.Errorf("%w: %v", ErrGodotExit, err)
	}

	status, err := readStatus(statusPath)
	if err != nil {
		return Result{}, err
	}
	if !status.OK {
		return Result{}, ErrStatusNotOK
	}

	return Result{
		RoundID:           status.RoundID,
		WinnerMarbleIndex: status.WinnerMarbleIndex,
		FinishTick:        status.FinishTick,
		ReplayPath:        status.ReplayPath,
		ServerSeedHashHex: status.ServerSeedHashHex,
		TickRateHz:        status.TickRateHz,
	}, nil
}

func writeJSON(path string, v any) error {
	f, err := os.Create(path)
	if err != nil {
		return err
	}
	defer f.Close()
	enc := json.NewEncoder(f)
	enc.SetIndent("", "  ")
	return enc.Encode(v)
}

func readStatus(path string) (statusFile, error) {
	b, err := os.ReadFile(path)
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return statusFile{}, ErrNoStatus
		}
		return statusFile{}, fmt.Errorf("sim: read status: %w", err)
	}
	var s statusFile
	if err := json.Unmarshal(b, &s); err != nil {
		return statusFile{}, fmt.Errorf("sim: parse status: %w", err)
	}
	return s, nil
}
