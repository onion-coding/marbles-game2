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
	"path/filepath"
	"sort"
	"strconv"
	"time"
)

// FilesystemBackend is the default Backend implementation. Each round is stored
// as a directory under root:
//
//	<root>/<round_id>/manifest.json
//	<root>/<round_id>/replay.bin
//
// Write pattern is temp-dir + rename so interrupted Saves never leave a
// half-populated round directory visible to List or Load.
type FilesystemBackend struct {
	root string
}

// NewFilesystemBackend prepares (and creates if missing) the store root
// directory, then returns a FilesystemBackend ready for use.
func NewFilesystemBackend(root string) (*FilesystemBackend, error) {
	if root == "" {
		return nil, errors.New("replay: root is required")
	}
	if err := os.MkdirAll(root, 0o755); err != nil {
		return nil, fmt.Errorf("replay: mkdir root: %w", err)
	}
	return &FilesystemBackend{root: root}, nil
}

// Save copies the replay bytes to disk, writes the manifest, and fills in the
// SHA-256 field of the manifest before persisting. The manifest argument is
// mutated in place (ReplaySHA256Hex and CreatedAt are set). Returns
// ErrRoundExists if the round directory already exists.
func (b *FilesystemBackend) Save(_ context.Context, m *Manifest, replay io.Reader) error {
	dir := b.roundDir(m.RoundID)
	if _, err := os.Stat(dir); err == nil {
		return fmt.Errorf("%w: round_id=%d at %s", ErrRoundExists, m.RoundID, dir)
	} else if !errors.Is(err, os.ErrNotExist) {
		return fmt.Errorf("replay: stat round dir: %w", err)
	}

	// Write to a temp directory, then rename — partial writes don't create a
	// visible round in List() or leave a half-populated directory on crash.
	tmpDir, err := os.MkdirTemp(b.root, fmt.Sprintf("pending-%d-", m.RoundID))
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

// Load reads the manifest from disk and returns it together with an open
// *os.File for replay.bin. The file implements io.ReadCloser; it also
// implements io.ReadSeeker and io.ReaderAt so callers such as
// http.ServeContent can use it for range requests.
func (b *FilesystemBackend) Load(_ context.Context, roundID uint64) (*Manifest, io.ReadCloser, error) {
	dir := b.roundDir(roundID)
	manifestPath := filepath.Join(dir, "manifest.json")
	raw, err := os.ReadFile(manifestPath)
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return nil, nil, fmt.Errorf("%w: round_id=%d", ErrRoundMissing, roundID)
		}
		return nil, nil, fmt.Errorf("replay: read manifest: %w", err)
	}
	var m Manifest
	if err := json.Unmarshal(raw, &m); err != nil {
		return nil, nil, fmt.Errorf("replay: parse manifest: %w", err)
	}
	f, err := os.Open(filepath.Join(dir, "replay.bin"))
	if err != nil {
		return nil, nil, fmt.Errorf("replay: open replay.bin: %w", err)
	}
	return &m, f, nil
}

// List returns all stored manifests in ascending round_id order.
// Directories whose names are not decimal uint64 values (including the
// "pending-*" temp dirs from interrupted Saves) are silently skipped.
func (b *FilesystemBackend) List(_ context.Context, opts ListOpts) ([]*Manifest, error) {
	entries, err := os.ReadDir(b.root)
	if err != nil {
		return nil, fmt.Errorf("replay: read root: %w", err)
	}
	var ids []uint64
	for _, e := range entries {
		if !e.IsDir() {
			continue
		}
		n, err := strconv.ParseUint(e.Name(), 10, 64)
		if err != nil {
			continue
		}
		if opts.After > 0 && n <= opts.After {
			continue
		}
		ids = append(ids, n)
	}
	sort.Slice(ids, func(i, j int) bool { return ids[i] < ids[j] })
	if opts.Limit > 0 && len(ids) > opts.Limit {
		ids = ids[:opts.Limit]
	}

	manifests := make([]*Manifest, 0, len(ids))
	for _, id := range ids {
		manifestPath := filepath.Join(b.roundDir(id), "manifest.json")
		raw, err := os.ReadFile(manifestPath)
		if err != nil {
			// Corrupt or incomplete round — skip rather than fail the whole list.
			continue
		}
		var m Manifest
		if err := json.Unmarshal(raw, &m); err != nil {
			continue
		}
		manifests = append(manifests, &m)
	}
	return manifests, nil
}

// Delete removes the round directory and all its contents.
// Returns ErrRoundMissing when the directory does not exist.
func (b *FilesystemBackend) Delete(_ context.Context, roundID uint64) error {
	dir := b.roundDir(roundID)
	if _, err := os.Stat(dir); errors.Is(err, os.ErrNotExist) {
		return fmt.Errorf("%w: round_id=%d", ErrRoundMissing, roundID)
	}
	if err := os.RemoveAll(dir); err != nil {
		return fmt.Errorf("replay: delete round dir: %w", err)
	}
	return nil
}

func (b *FilesystemBackend) roundDir(id uint64) string {
	return filepath.Join(b.root, strconv.FormatUint(id, 10))
}

// copyWithSHA256 streams src to the file at dstPath while computing SHA-256.
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
