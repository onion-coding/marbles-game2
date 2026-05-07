package admin

import (
	"bufio"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"sync"
	"time"
)

// AuditEvent records a single admin action for the operator audit trail.
type AuditEvent struct {
	Timestamp time.Time `json:"timestamp"`
	Actor     string    `json:"actor"`
	Action    string    `json:"action"`
	Target    string    `json:"target,omitempty"`
	Details   string    `json:"details,omitempty"`
}

const ringSize = 1000

// AuditLog is a thread-safe in-memory ring buffer (last 1000 events) that
// also appends every event to a JSONL file for durable storage.
type AuditLog struct {
	mu      sync.Mutex
	ring    [ringSize]AuditEvent
	head    int  // index of the oldest entry (wraps at ringSize)
	count   int  // total entries ever recorded (not capped at ringSize)
	file    *os.File
}

// NewAuditLog opens (or creates) the JSONL file at dataDir/admin_audit.jsonl
// and returns an AuditLog ready for use. dataDir may be empty, in which case
// events are only held in-memory.
func NewAuditLog(dataDir string) (*AuditLog, error) {
	al := &AuditLog{}
	if dataDir != "" {
		if err := os.MkdirAll(dataDir, 0o755); err != nil {
			return nil, fmt.Errorf("admin: audit log mkdir %q: %w", dataDir, err)
		}
		path := filepath.Join(dataDir, "admin_audit.jsonl")
		f, err := os.OpenFile(path, os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0o644)
		if err != nil {
			return nil, fmt.Errorf("admin: audit log open %q: %w", path, err)
		}
		al.file = f
	}
	return al, nil
}

// Close flushes and closes the underlying file, if any.
func (al *AuditLog) Close() error {
	al.mu.Lock()
	defer al.mu.Unlock()
	if al.file != nil {
		return al.file.Close()
	}
	return nil
}

// Record appends an event to the ring buffer and (if a file is open) to disk.
func (al *AuditLog) Record(ev AuditEvent) {
	if ev.Timestamp.IsZero() {
		ev.Timestamp = time.Now()
	}
	al.mu.Lock()
	slot := al.count % ringSize
	al.ring[slot] = ev
	al.count++
	al.head = al.count % ringSize
	f := al.file
	al.mu.Unlock()

	if f != nil {
		line, _ := json.Marshal(ev)
		al.mu.Lock()
		_, _ = f.Write(append(line, '\n'))
		al.mu.Unlock()
	}
}

// List returns up to `limit` events starting at `offset` (0-based, newest-first).
func (al *AuditLog) List(offset, limit int) []AuditEvent {
	al.mu.Lock()
	defer al.mu.Unlock()

	total := al.count
	if total > ringSize {
		total = ringSize
	}
	if offset >= total {
		return []AuditEvent{}
	}
	end := total - offset
	start := end - limit
	if start < 0 {
		start = 0
	}

	// Build the logical slice in insertion order, then reverse it.
	// When count < ringSize the ring isn't full: entries live at indices 0..count-1.
	// When count >= ringSize the ring is full: oldest entry is at al.count%ringSize.
	out := make([]AuditEvent, 0, end-start)
	oldest := 0
	if al.count >= ringSize {
		oldest = al.count % ringSize
	}
	for i := start; i < end; i++ {
		idx := (oldest + i) % ringSize
		out = append(out, al.ring[idx])
	}
	// Reverse so newest is first.
	for i, j := 0, len(out)-1; i < j; i, j = i+1, j-1 {
		out[i], out[j] = out[j], out[i]
	}
	return out
}

// Total returns the total number of events ever recorded (not capped).
func (al *AuditLog) Total() int {
	al.mu.Lock()
	defer al.mu.Unlock()
	return al.count
}

// LoadFromFile reads events from a JSONL file into the ring buffer. Used on
// startup to populate in-memory state from a previous run's durable log.
func (al *AuditLog) LoadFromFile(path string) error {
	f, err := os.Open(path)
	if err != nil {
		if os.IsNotExist(err) {
			return nil
		}
		return err
	}
	defer f.Close()

	sc := bufio.NewScanner(f)
	for sc.Scan() {
		var ev AuditEvent
		if err := json.Unmarshal(sc.Bytes(), &ev); err != nil {
			continue // skip malformed lines
		}
		slot := al.count % ringSize
		al.ring[slot] = ev
		al.count++
	}
	al.head = al.count % ringSize
	return sc.Err()
}
