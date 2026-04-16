// Package replay is the per-round audit trail. Every completed round writes
// one directory containing the full tick-replay (as produced by the Godot
// recorder) plus a manifest describing the commit/reveal, participants, and
// result. This is what a dispute or regulator review would read.
//
// The store is intentionally append-only: Save refuses to overwrite an
// existing round. If a round truly needs to be replaced (e.g. it was a
// broken test run), the caller deletes the directory explicitly. An audit
// trail that silently rewrites history is worse than none.
//
// Integrity: the manifest records SHA-256 of replay.bin. Verify recomputes
// it so bit-rot / tampering of the stored blob is detectable post-hoc.
// This is separate from the fairness commit hash — that proves the server
// didn't pick the seed after buy-in; this proves the stored replay wasn't
// edited after the round.
package replay

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"time"
)

// Participant is what the store knows about a player — decoupled from the
// round package so the two can evolve independently.
type Participant struct {
	MarbleIndex int    `json:"marble_index"`
	Name        string `json:"name"`
	ClientSeed  string `json:"client_seed"`
}

type Winner struct {
	MarbleIndex int `json:"marble_index"`
	FinishTick  int `json:"finish_tick"`
}

// Manifest is the server's ground-truth record of one round. A verifier can
// re-derive everything in here from ServerSeedHex + Participants + the track
// constants, and compare against the stored replay.bin.
type Manifest struct {
	RoundID           uint64        `json:"round_id"`
	CreatedAt         time.Time     `json:"created_at"`
	ProtocolVersion   int           `json:"protocol_version"`
	TickRateHz        int           `json:"tick_rate_hz"`
	ServerSeedHashHex string        `json:"server_seed_hash_hex"`
	ServerSeedHex     string        `json:"server_seed_hex"`
	Participants      []Participant `json:"participants"`
	Winner            Winner        `json:"winner"`
	ReplaySHA256Hex   string        `json:"replay_sha256_hex"`
}

type Store struct {
	root string
}

var (
	ErrRoundExists      = errors.New("replay: round already stored")
	ErrRoundMissing     = errors.New("replay: round not found")
	ErrChecksumMismatch = errors.New("replay: replay.bin SHA-256 does not match manifest")
	ErrInvalidManifest  = errors.New("replay: manifest missing required field")
)

// New prepares (and creates if missing) the store root.
func New(root string) (*Store, error) {
	if root == "" {
		return nil, errors.New("replay: root is required")
	}
	if err := os.MkdirAll(root, 0o755); err != nil {
		return nil, fmt.Errorf("replay: mkdir root: %w", err)
	}
	return &Store{root: root}, nil
}

// Save copies the replay bytes to disk, writes the manifest, and fills in
// the SHA-256 field of the manifest before persisting it. The manifest argument
// is mutated in place (ReplaySHA256Hex is set). Fails with ErrRoundExists if
// the round directory already exists — callers must not overwrite audit data.
func (s *Store) Save(m *Manifest, replay io.Reader) error {
	if err := validateManifestForSave(m); err != nil {
		return err
	}

	dir := s.roundDir(m.RoundID)
	if _, err := os.Stat(dir); err == nil {
		return fmt.Errorf("%w: round_id=%d at %s", ErrRoundExists, m.RoundID, dir)
	} else if !errors.Is(err, os.ErrNotExist) {
		return fmt.Errorf("replay: stat round dir: %w", err)
	}

	// Write to a temp directory, then rename — partial writes don't create a
	// visible round in List() or leave a half-populated directory on crash.
	tmpDir, err := os.MkdirTemp(s.root, fmt.Sprintf("pending-%d-", m.RoundID))
	if err != nil {
		return fmt.Errorf("replay: mkdir temp: %w", err)
	}
	cleanupTmp := true
	defer func() {
		if cleanupTmp {
			os.RemoveAll(tmpDir)
		}
	}()

	replayPath := filepath.Join(tmpDir, "replay.bin")
	sum, err := copyWithSHA256(replay, replayPath)
	if err != nil {
		return fmt.Errorf("replay: write replay.bin: %w", err)
	}
	m.ReplaySHA256Hex = hex.EncodeToString(sum)
	if m.CreatedAt.IsZero() {
		m.CreatedAt = time.Now().UTC()
	}

	manifestPath := filepath.Join(tmpDir, "manifest.json")
	if err := writeJSONFile(manifestPath, m); err != nil {
		return fmt.Errorf("replay: write manifest: %w", err)
	}

	if err := os.Rename(tmpDir, dir); err != nil {
		return fmt.Errorf("replay: finalize round dir: %w", err)
	}
	cleanupTmp = false
	return nil
}

// Load returns the manifest and the absolute path to replay.bin. The replay
// file is not verified — call Verify for integrity checks.
func (s *Store) Load(id uint64) (Manifest, string, error) {
	dir := s.roundDir(id)
	manifestPath := filepath.Join(dir, "manifest.json")
	b, err := os.ReadFile(manifestPath)
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return Manifest{}, "", fmt.Errorf("%w: round_id=%d", ErrRoundMissing, id)
		}
		return Manifest{}, "", fmt.Errorf("replay: read manifest: %w", err)
	}
	var m Manifest
	if err := json.Unmarshal(b, &m); err != nil {
		return Manifest{}, "", fmt.Errorf("replay: parse manifest: %w", err)
	}
	return m, filepath.Join(dir, "replay.bin"), nil
}

// List returns all stored round IDs, ascending.
func (s *Store) List() ([]uint64, error) {
	entries, err := os.ReadDir(s.root)
	if err != nil {
		return nil, fmt.Errorf("replay: read root: %w", err)
	}
	var ids []uint64
	for _, e := range entries {
		if !e.IsDir() {
			continue
		}
		// Ignore the "pending-*" temp dirs from interrupted Saves.
		n, err := strconv.ParseUint(e.Name(), 10, 64)
		if err != nil {
			continue
		}
		ids = append(ids, n)
	}
	sort.Slice(ids, func(i, j int) bool { return ids[i] < ids[j] })
	return ids, nil
}

// Verify re-reads replay.bin and confirms its SHA-256 matches the manifest.
// Use to detect tampering or bit-rot before trusting a stored replay.
func (s *Store) Verify(id uint64) error {
	m, replayPath, err := s.Load(id)
	if err != nil {
		return err
	}
	f, err := os.Open(replayPath)
	if err != nil {
		return fmt.Errorf("replay: open replay.bin: %w", err)
	}
	defer f.Close()
	h := sha256.New()
	if _, err := io.Copy(h, f); err != nil {
		return fmt.Errorf("replay: hash replay.bin: %w", err)
	}
	got := hex.EncodeToString(h.Sum(nil))
	if got != m.ReplaySHA256Hex {
		return fmt.Errorf("%w: round_id=%d manifest=%s actual=%s", ErrChecksumMismatch, id, m.ReplaySHA256Hex, got)
	}
	return nil
}

func (s *Store) roundDir(id uint64) string {
	return filepath.Join(s.root, strconv.FormatUint(id, 10))
}

func validateManifestForSave(m *Manifest) error {
	if m == nil {
		return fmt.Errorf("%w: manifest is nil", ErrInvalidManifest)
	}
	if m.RoundID == 0 {
		return fmt.Errorf("%w: round_id", ErrInvalidManifest)
	}
	if m.ServerSeedHashHex == "" {
		return fmt.Errorf("%w: server_seed_hash_hex", ErrInvalidManifest)
	}
	if m.ServerSeedHex == "" {
		return fmt.Errorf("%w: server_seed_hex (must be revealed before Save)", ErrInvalidManifest)
	}
	if len(m.Participants) == 0 {
		return fmt.Errorf("%w: participants", ErrInvalidManifest)
	}
	return nil
}

func copyWithSHA256(src io.Reader, dstPath string) ([]byte, error) {
	f, err := os.Create(dstPath)
	if err != nil {
		return nil, err
	}
	defer f.Close()
	h := sha256.New()
	if _, err := io.Copy(io.MultiWriter(f, h), src); err != nil {
		return nil, err
	}
	if err := f.Sync(); err != nil {
		return nil, err
	}
	return h.Sum(nil), nil
}

func writeJSONFile(path string, v any) error {
	f, err := os.Create(path)
	if err != nil {
		return err
	}
	defer f.Close()
	enc := json.NewEncoder(f)
	enc.SetIndent("", "  ")
	if err := enc.Encode(v); err != nil {
		return err
	}
	return f.Sync()
}
