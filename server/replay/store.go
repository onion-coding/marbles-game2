// Package replay is the per-round audit trail. Every completed round writes
// one object/directory containing the full tick-replay (as produced by the
// Godot recorder) plus a manifest describing the commit/reveal, participants,
// and result. This is what a dispute or regulator review would read.
//
// The store is intentionally append-only: Save refuses to overwrite an
// existing round. If a round truly needs to be replaced (e.g. it was a
// broken test run), the caller deletes it explicitly. An audit trail that
// silently rewrites history is worse than none.
//
// Integrity: the manifest records SHA-256 of replay.bin. Verify recomputes
// it so bit-rot / tampering of the stored blob is detectable post-hoc.
// This is separate from the fairness commit hash — that proves the server
// didn't pick the seed after buy-in; this proves the stored replay wasn't
// edited after the round.
//
// # Backend abstraction
//
// Store is a thin wrapper around a Backend interface.  The default backend
// (FilesystemBackend) writes to a local directory — identical to the
// pre-refactor behaviour.  An S3Backend can be substituted for production
// deployments where a single-host failure must not lose audit data.
//
// Constructors for callers:
//
//	// Filesystem (default, backward-compat):
//	store, err := replay.NewFilesystemStore(root)
//	// — or, using New() which is the legacy alias:
//	store, err := replay.New(root)
//
//	// S3 / S3-compatible:
//	store, err := replay.NewS3Store(replay.S3Config{...})
package replay

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
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

// PodiumEntry is one rank on the top-3 finish board (added in M16, payout v2).
// MarbleIndex == -1 means "no marble crossed in this slot before the recorder
// tail closed" (incomplete race). Tick mirrors the meaning of Winner.FinishTick.
type PodiumEntry struct {
	MarbleIndex int `json:"marble_index"`
	FinishTick  int `json:"finish_tick"`
}

// ProtocolVersion4 is the current manifest protocol version. The writer
// always emits v4; the reader accepts both v3 (missing v4 fields default
// to zero / empty) and v4. Clients that only know v3 will silently ignore
// the extra JSON keys, which is safe because JSON is open-schema.
const ProtocolVersion4 = 4

// Manifest is the server's ground-truth record of one round. A verifier can
// re-derive everything in here from ServerSeedHex + Participants + TrackID +
// the track constants, and compare against the stored replay.bin.
//
// Version history:
//
//	v3 (M9-M15): single Winner, no podium/pickup fields.
//	v4 (M16+):   adds Podium, PickupPerMarble*, MarbleCount, PodiumPayouts,
//	             PickupPerMarbleTier, JackpotTriggered, JackpotMarbleIndex,
//	             FinishOrder. Old v3 manifests remain decode-able; all new
//	             fields default to zero / empty and are backward-compatible.
//
// Certification note (iTech/GLI/BMM): an auditor can recompute the gross
// payoff for any marble from this manifest alone — no need to trust the
// settle record. Formula: PickupPerMarbleTier[i] maps to multiplier
// (0→1×, 1→2×, 2→3×), PodiumPayouts[rank] gives the base payoff in cents
// for stake=1.0 unit. JackpotTriggered overrides 1° payoff with 100×.
type Manifest struct {
	RoundID           uint64        `json:"round_id"`
	CreatedAt         time.Time     `json:"created_at"`
	ProtocolVersion   int           `json:"protocol_version"`
	TickRateHz        int           `json:"tick_rate_hz"`
	TrackID           uint8         `json:"track_id"`
	ServerSeedHashHex string        `json:"server_seed_hash_hex"`
	ServerSeedHex     string        `json:"server_seed_hex"`
	Participants      []Participant `json:"participants"`
	Winner            Winner        `json:"winner"`

	// ── v4 base payout fields ─────────────────────────────────────────────
	// Present on all v4 manifests; zero/empty on v3 (use Winner as fallback).

	// Podium holds the top-3 finish entries. MarbleIndex==-1 means "no marble
	// crossed in this slot" (incomplete race tail).
	Podium [3]PodiumEntry `json:"podium,omitempty"`

	// MarbleCount is the number of marbles that raced. v3 tracks had 20;
	// v2-model (M11+) tracks use 30. Defaults to 0 on v3 manifests — callers
	// should treat 0 as "unknown / legacy, assume 20".
	MarbleCount uint8 `json:"marble_count,omitempty"`

	// PodiumPayouts is the pre-computed gross payoff in cents for a 1-unit
	// stake on each of the top-3 positions ([0]=1°, [1]=2°, [2]=3°). Derived
	// by the manager via ComputeBetPayoff(marble_idx, 1.0, outcome) so an
	// external auditor can verify payout without re-running game logic.
	// Nil on v3 manifests (fixed-size arrays cannot use omitempty; pointer
	// form is used so that absent=nil is distinguished from all-zeroes).
	PodiumPayouts *[3]uint64 `json:"podium_payouts,omitempty"`

	// PickupTier1Marbles/PickupTier2Marble are the RAW pickup-zone collections
	// from physics. Tier2Active flags whether the Tier 2 zone was "live" for
	// this round (derived from seed via DeriveTier2Active); when false, the
	// Tier 2 marble's pickup is downgraded to Tier 1 / no-pickup at payoff time.
	PickupTier1Marbles []int `json:"pickup_tier_1_marbles,omitempty"`
	PickupTier2Marble  int   `json:"pickup_tier_2_marble,omitempty"`
	Tier2Active        bool  `json:"tier_2_active,omitempty"`

	// PickupPerMarble is a derived convenience array for fast payoff lookup;
	// length = MarbleCount, float values 1.0 (no pickup) / 2.0 (Tier 1) /
	// 3.0 (Tier 2). Built by the manager after applying Tier2Active.
	// Kept for backward compat with v3 readers; prefer PickupPerMarbleTier.
	PickupPerMarble []float64 `json:"pickup_per_marble,omitempty"`

	// PickupPerMarbleTier is the v4 canonical form of pickup data: one byte
	// per marble (length = MarbleCount), values 0=no pickup, 1=Tier1 (2×),
	// 2=Tier2 (3×). This is what a certification auditor reads.
	// Constraints (per math-model §2.1): at most 4 entries == 1, at most 1
	// entry == 2.
	PickupPerMarbleTier []uint8 `json:"pickup_per_marble_tier,omitempty"`

	JackpotTriggered bool `json:"jackpot_triggered,omitempty"`
	// JackpotMarbleIdx is the marble that triggered the jackpot, or -1.
	// NOTE: JSON omitempty on int fields omits 0, which is a valid marble
	// index. We keep the field non-omitempty so a zero index is preserved.
	JackpotMarbleIdx int `json:"jackpot_marble_index"`

	// FinishOrder is the full sorted marble finish order (1°→last°). Length
	// may be less than MarbleCount if the race was truncated. Empty on v3
	// manifests (only Winner is available).
	FinishOrder []int `json:"finish_order,omitempty"`

	ReplaySHA256Hex string `json:"replay_sha256_hex"`
}

// ListOpts controls the page / filter parameters for Backend.List.
// Currently only pagination fields are wired; extend as needed.
type ListOpts struct {
	// Limit is the maximum number of manifests to return (0 = no limit).
	Limit int
	// After is an optional exclusive lower-bound round_id for cursor-style
	// pagination. 0 = start from the beginning.
	After uint64
}

// Backend is the storage abstraction for the replay audit trail.
// Implementations must be safe for concurrent use.
//
// Invariant: Save is write-once. A second Save for the same round_id must
// return ErrRoundExists without modifying the existing data.
type Backend interface {
	// Save writes manifest + replay bytes atomically. Mutates m.ReplaySHA256Hex
	// and m.CreatedAt (if zero) before persisting.
	Save(ctx context.Context, m *Manifest, replay io.Reader) error

	// Load returns the manifest and an open reader for the replay bytes.
	// The caller is responsible for closing the reader.
	Load(ctx context.Context, roundID uint64) (*Manifest, io.ReadCloser, error)

	// List returns manifests in ascending round_id order, honouring opts.
	List(ctx context.Context, opts ListOpts) ([]*Manifest, error)

	// Delete removes both objects for the given round_id.
	// Returns ErrRoundMissing when the round does not exist.
	Delete(ctx context.Context, roundID uint64) error
}

// Store is the public-facing wrapper around a Backend. It exposes the same
// surface as the pre-refactor concrete struct so call sites remain unchanged
// while the underlying persistence can be swapped.
type Store struct {
	backend Backend
}

// NewStore constructs a Store backed by the provided Backend.
func NewStore(b Backend) *Store {
	return &Store{backend: b}
}

// NewFilesystemStore is the backward-compatible constructor for filesystem
// persistence.  Callers that previously used replay.New can switch to this
// alias with a one-token change, or keep using New() which delegates here.
func NewFilesystemStore(root string) (*Store, error) {
	b, err := NewFilesystemBackend(root)
	if err != nil {
		return nil, err
	}
	return NewStore(b), nil
}

// NewS3Store constructs a Store backed by S3-compatible object storage.
func NewS3Store(cfg S3Config) (*Store, error) {
	b, err := NewS3Backend(cfg)
	if err != nil {
		return nil, err
	}
	return NewStore(b), nil
}

// New is the legacy alias for NewFilesystemStore, kept for backward compat.
// All callers in cmd/* and tests can keep using replay.New(root).
func New(root string) (*Store, error) {
	return NewFilesystemStore(root)
}

var (
	ErrRoundExists      = errors.New("replay: round already stored")
	ErrRoundMissing     = errors.New("replay: round not found")
	ErrChecksumMismatch = errors.New("replay: replay.bin SHA-256 does not match manifest")
	ErrInvalidManifest  = errors.New("replay: manifest missing required field")
)

// Save writes replay bytes + manifest via the backend. Validates the manifest
// first, fills in ReplaySHA256Hex and CreatedAt, then delegates to the backend.
// The manifest argument is mutated in place.
func (s *Store) Save(m *Manifest, replay io.Reader) error {
	if err := validateManifestForSave(m); err != nil {
		return err
	}
	return s.backend.Save(context.Background(), m, replay)
}

// Load returns the manifest and an open reader for the replay bytes.
// The caller must close the reader when done.
func (s *Store) Load(id uint64) (*Manifest, io.ReadCloser, error) {
	return s.backend.Load(context.Background(), id)
}

// List returns all stored round IDs, ascending.
func (s *Store) List() ([]uint64, error) {
	manifests, err := s.backend.List(context.Background(), ListOpts{})
	if err != nil {
		return nil, err
	}
	ids := make([]uint64, len(manifests))
	for i, m := range manifests {
		ids[i] = m.RoundID
	}
	return ids, nil
}

// Verify re-reads replay bytes and confirms the SHA-256 matches the manifest.
// Use to detect tampering or bit-rot before trusting a stored replay.
func (s *Store) Verify(id uint64) error {
	m, rc, err := s.Load(id)
	if err != nil {
		return err
	}
	defer rc.Close()
	h := sha256.New()
	if _, err := io.Copy(h, rc); err != nil {
		return fmt.Errorf("replay: hash replay bytes: %w", err)
	}
	got := hex.EncodeToString(h.Sum(nil))
	if got != m.ReplaySHA256Hex {
		return fmt.Errorf("%w: round_id=%d manifest=%s actual=%s",
			ErrChecksumMismatch, id, m.ReplaySHA256Hex, got)
	}
	return nil
}

// ValidateJackpotConsistency checks the three-way invariant required by the
// certification spec (docs/math-model.md §4.3): when JackpotTriggered is
// true the manifest must satisfy all of:
//  1. JackpotMarbleIdx >= 0
//  2. PickupPerMarbleTier[JackpotMarbleIdx] == 2 (the marble held a Tier 2 pickup)
//  3. FinishOrder[0] == JackpotMarbleIdx (the jackpot marble won 1°)
//
// Returns nil when JackpotTriggered is false (no constraints apply) or when
// all three conditions hold. Returns a descriptive error otherwise so an
// audit tool can surface the exact violation.
func ValidateJackpotConsistency(m *Manifest) error {
	if !m.JackpotTriggered {
		return nil
	}
	if m.JackpotMarbleIdx < 0 {
		return fmt.Errorf("replay: JackpotMarbleIdx must be >= 0 when JackpotTriggered (got %d)", m.JackpotMarbleIdx)
	}
	idx := m.JackpotMarbleIdx
	if idx < len(m.PickupPerMarbleTier) && m.PickupPerMarbleTier[idx] != 2 {
		return fmt.Errorf("replay: PickupPerMarbleTier[JackpotMarbleIdx] must be 2 (got %d for marble %d)",
			m.PickupPerMarbleTier[idx], idx)
	}
	if len(m.FinishOrder) > 0 && m.FinishOrder[0] != idx {
		return fmt.Errorf("replay: FinishOrder[0] must equal JackpotMarbleIdx (FinishOrder[0]=%d, JackpotMarbleIdx=%d)",
			m.FinishOrder[0], idx)
	}
	return nil
}

// validateManifestForSave is shared by all backends; callers invoke it before
// delegating to the backend so we don't duplicate the check per-implementation.
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

// writeJSONFile is a shared helper used by backends that write local files.
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
