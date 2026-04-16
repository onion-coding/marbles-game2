// Package stream fans out live per-tick updates from the sim to web clients.
//
// Architecture:
//
//	sim (Godot)  --TCP-->  Hub  --WS-->  clients
//
// The Hub is pure in-memory: it holds one Round per active sim, buffering the
// HEADER and all TICK messages so a late subscriber still gets the full stream
// to render from tick 0. When a round ends (DONE), the Hub delivers DONE to all
// subscribers and drops the round. Completed rounds live in the archive API
// (server/api/replay), not here.
//
// Wire format (identical sim→hub and hub→client so the hub can forward bytes
// without re-encoding):
//
//	u8 msg_type      // 0x01 HEADER, 0x02 TICK, 0x03 DONE
//	u32 payload_len  // little-endian
//	bytes payload    // raw v2 replay-format header or frame bytes
//
// HEADER payload is the same header the replay writer emits (protocol version
// through per-marble entries, but NOT the frame-count u32 — that's unknown live).
// TICK payload is one frame: tick_idx(u32) + flags(u8) + N × (pos+quat) bytes.
// DONE payload is empty.
package stream

import (
	"encoding/binary"
	"errors"
	"fmt"
	"io"
	"sync"
)

const (
	MsgHeader byte = 0x01
	MsgTick   byte = 0x02
	MsgDone   byte = 0x03
)

// Message is one protocol frame.
type Message struct {
	Type    byte
	Payload []byte
}

// Encode writes the message to w using the wire format. Named Encode rather
// than WriteTo to avoid colliding with the io.WriterTo interface signature
// (which would require returning int64).
func (m Message) Encode(w io.Writer) error {
	var hdr [5]byte
	hdr[0] = m.Type
	binary.LittleEndian.PutUint32(hdr[1:], uint32(len(m.Payload)))
	if _, err := w.Write(hdr[:]); err != nil {
		return err
	}
	if len(m.Payload) > 0 {
		if _, err := w.Write(m.Payload); err != nil {
			return err
		}
	}
	return nil
}

// ReadMessage reads a single message from r. Caller-controlled payload size
// cap prevents a malicious/broken sender from exhausting memory.
func ReadMessage(r io.Reader, maxPayload uint32) (Message, error) {
	var hdr [5]byte
	if _, err := io.ReadFull(r, hdr[:]); err != nil {
		return Message{}, err
	}
	m := Message{Type: hdr[0]}
	n := binary.LittleEndian.Uint32(hdr[1:])
	if n > maxPayload {
		return Message{}, fmt.Errorf("stream: payload %d exceeds cap %d", n, maxPayload)
	}
	if n > 0 {
		m.Payload = make([]byte, n)
		if _, err := io.ReadFull(r, m.Payload); err != nil {
			return Message{}, err
		}
	}
	return m, nil
}

// Hub stores currently-live rounds. Rounds appear when Open() is called and
// vanish after the corresponding Round.Done() fan-out completes.
type Hub struct {
	mu     sync.Mutex
	rounds map[uint64]*Round
}

func NewHub() *Hub {
	return &Hub{rounds: map[uint64]*Round{}}
}

var (
	ErrRoundExists    = errors.New("stream: round already open")
	ErrRoundNotFound  = errors.New("stream: round not live")
	ErrHeaderRequired = errors.New("stream: HEADER must precede any TICK or DONE")
	ErrRoundClosed    = errors.New("stream: round already closed")
)

// Open registers a new live round. Returns an error if the ID collides with
// an already-open round — caller retries with a fresh ID.
func (h *Hub) Open(id uint64) (*Round, error) {
	h.mu.Lock()
	defer h.mu.Unlock()
	if _, ok := h.rounds[id]; ok {
		return nil, fmt.Errorf("%w: id=%d", ErrRoundExists, id)
	}
	r := &Round{
		id:   id,
		hub:  h,
		subs: map[*Subscriber]struct{}{},
	}
	h.rounds[id] = r
	return r, nil
}

// Lookup returns the live round, or nil if not live.
func (h *Hub) Lookup(id uint64) *Round {
	h.mu.Lock()
	defer h.mu.Unlock()
	return h.rounds[id]
}

// ActiveRounds returns the IDs of currently-live rounds.
func (h *Hub) ActiveRounds() []uint64 {
	h.mu.Lock()
	defer h.mu.Unlock()
	ids := make([]uint64, 0, len(h.rounds))
	for id := range h.rounds {
		ids = append(ids, id)
	}
	return ids
}

// Round is a live in-progress round. Only one writer side (the sim feeding it)
// and N subscribers. Methods are safe for concurrent calls from writer + subs.
type Round struct {
	id   uint64
	hub  *Hub
	mu   sync.Mutex
	hdr  *Message  // single HEADER buffered for late subscribers
	tks  []Message // every TICK, buffered so late subs can catch up
	done bool
	subs map[*Subscriber]struct{}
}

// WriteHeader stores the header and delivers it to all current subscribers.
// Must be called exactly once before the first tick.
func (r *Round) WriteHeader(payload []byte) error {
	r.mu.Lock()
	defer r.mu.Unlock()
	if r.hdr != nil {
		return errors.New("stream: header already written")
	}
	if r.done {
		return ErrRoundClosed
	}
	m := Message{Type: MsgHeader, Payload: payload}
	r.hdr = &m
	r.fanoutLocked(m)
	return nil
}

// WriteTick appends a tick and delivers it to all subscribers. Fails if HEADER
// hasn't been written yet — HEADER-before-TICK is a protocol invariant.
func (r *Round) WriteTick(payload []byte) error {
	r.mu.Lock()
	defer r.mu.Unlock()
	if r.hdr == nil {
		return ErrHeaderRequired
	}
	if r.done {
		return ErrRoundClosed
	}
	m := Message{Type: MsgTick, Payload: payload}
	r.tks = append(r.tks, m)
	r.fanoutLocked(m)
	return nil
}

// Done finalizes the round: fans out DONE, closes every subscriber's channel,
// and unregisters from the Hub. Idempotent.
func (r *Round) Done() {
	r.mu.Lock()
	if r.done {
		r.mu.Unlock()
		return
	}
	r.done = true
	m := Message{Type: MsgDone}
	r.fanoutLocked(m)
	// Close every sub's send channel so readers unblock cleanly.
	for s := range r.subs {
		close(s.send)
	}
	r.subs = nil
	r.mu.Unlock()

	r.hub.mu.Lock()
	delete(r.hub.rounds, r.id)
	r.hub.mu.Unlock()
}

// Subscribe attaches a new subscriber. The returned Subscriber's channel is
// pre-loaded with HEADER + every buffered TICK (so a late joiner still renders
// from tick 0), and will keep receiving live messages until the round ends.
//
// liveBuf is the per-subscriber headroom for *live* ticks after backfill.
// Slow subscribers that let the buffer fill get kicked — we'd rather drop a
// lagger than stall the fan-out for everyone. A generous default is a few
// seconds' worth of ticks (e.g. 60Hz × 3s = 180).
func (r *Round) Subscribe(liveBuf int) *Subscriber {
	if liveBuf < 16 {
		liveBuf = 16
	}
	r.mu.Lock()
	defer r.mu.Unlock()

	// Size the channel so the synchronous backfill below never blocks:
	// 1 (header) + len(ticks) + liveBuf headroom for future ticks.
	bufSize := 1 + len(r.tks) + liveBuf
	s := &Subscriber{send: make(chan Message, bufSize)}

	if r.hdr != nil {
		s.send <- *r.hdr
	}
	for _, t := range r.tks {
		s.send <- t
	}
	if r.done {
		s.send <- Message{Type: MsgDone}
		close(s.send)
		return s
	}
	r.subs[s] = struct{}{}
	return s
}

// fanoutLocked delivers m to every current subscriber. r.mu must be held.
// Laggers whose buffers are full get kicked: their channel is closed, they're
// removed from the set, and future calls won't see them.
func (r *Round) fanoutLocked(m Message) {
	for s := range r.subs {
		select {
		case s.send <- m:
		default:
			delete(r.subs, s)
			close(s.send)
		}
	}
}

// Subscriber receives messages for one round. Read from C() until it closes.
type Subscriber struct {
	send chan Message
}

// C returns the outbound channel. Closed when the round ends, the subscriber
// is kicked for slowness, or Unsubscribe is called.
func (s *Subscriber) C() <-chan Message { return s.send }

// Unsubscribe detaches the subscriber from its round. Safe to call multiple
// times and from any goroutine.
func (s *Subscriber) Unsubscribe(r *Round) {
	r.mu.Lock()
	defer r.mu.Unlock()
	if _, ok := r.subs[s]; ok {
		delete(r.subs, s)
		close(s.send)
	}
}
