package casino

import (
	"bufio"
	"context"
	"errors"
	"fmt"
	"log/slog"
	"net"
	"sync"
	"time"
)

// MetaListener accepts a single TCP connection from the Godot subprocess
// carrying line-delimited JSON metadata (HUD coords, minimap samples,
// names) and broadcasts each line verbatim onto every WebRTC subscriber's
// data channel via the SFU.
//
// Wire format: each line is one self-contained JSON object terminated by
// '\n'. Lines are forwarded as-is — no inspection, no batching. The
// browser is responsible for typing/dispatching by the "type" field.
//
// One Godot publisher at a time. A second connection is rejected the
// same way FrameListener handles it.
type MetaListener struct {
	addr string
	sfu  *SFU
	log  *slog.Logger

	ln  net.Listener
	mu  sync.Mutex
	cur net.Conn
}

// NewMetaListener binds the listener; call Run inside a goroutine to
// drive the read+broadcast loop.
func NewMetaListener(addr string, sfu *SFU, log *slog.Logger) (*MetaListener, error) {
	if sfu == nil {
		return nil, errors.New("casino/meta: sfu is nil")
	}
	if log == nil {
		log = slog.Default()
	}
	ln, err := net.Listen("tcp", addr)
	if err != nil {
		return nil, fmt.Errorf("casino/meta: listen %s: %w", addr, err)
	}
	return &MetaListener{addr: addr, sfu: sfu, log: log, ln: ln}, nil
}

// Addr returns the bound address.
func (l *MetaListener) Addr() string { return l.ln.Addr().String() }

// Run accepts the first Godot connection, then reads line-delimited JSON
// and broadcasts each line on the SFU data channel. Returns when ctx is
// cancelled or the connection ends.
func (l *MetaListener) Run(ctx context.Context) error {
	go l.rejectExtras()

	type accepted struct {
		conn net.Conn
		err  error
	}
	out := make(chan accepted, 1)
	go func() {
		c, err := l.ln.Accept()
		out <- accepted{conn: c, err: err}
	}()
	var conn net.Conn
	select {
	case <-ctx.Done():
		_ = l.ln.Close()
		return ctx.Err()
	case r := <-out:
		if r.err != nil {
			return fmt.Errorf("casino/meta: accept: %w", r.err)
		}
		conn = r.conn
	}
	l.mu.Lock()
	l.cur = conn
	l.mu.Unlock()
	defer func() {
		_ = conn.Close()
		l.mu.Lock()
		l.cur = nil
		l.mu.Unlock()
	}()
	l.log.Info("casino/meta: Godot connected", "remote", conn.RemoteAddr())

	scanner := bufio.NewScanner(conn)
	// Accept up to 1 MiB lines (a single per-frame coords payload at
	// 30 marbles is ~2 KiB; 1 MiB is generous headroom for future fields).
	scanner.Buffer(make([]byte, 0, 64*1024), 1<<20)
	for scanner.Scan() {
		select {
		case <-ctx.Done():
			return ctx.Err()
		default:
		}
		line := scanner.Bytes()
		if len(line) == 0 {
			continue
		}
		// Defensive copy: SFU.Broadcast may capture the slice across
		// data-channel send boundaries; scanner reuses its internal buf.
		payload := append([]byte(nil), line...)
		l.sfu.Broadcast(payload)
	}
	if err := scanner.Err(); err != nil && !errors.Is(err, net.ErrClosed) {
		return fmt.Errorf("casino/meta: scan: %w", err)
	}
	return nil
}

func (l *MetaListener) rejectExtras() {
	for {
		conn, err := l.ln.Accept()
		if err != nil {
			return
		}
		_ = conn.SetDeadline(time.Now().Add(100 * time.Millisecond))
		_ = conn.Close()
		l.log.Warn("casino/meta: rejected extra connection", "remote", conn.RemoteAddr())
	}
}

// Close stops accepting and tears down the active connection.
func (l *MetaListener) Close() error {
	if l.ln != nil {
		_ = l.ln.Close()
	}
	l.mu.Lock()
	if l.cur != nil {
		_ = l.cur.Close()
		l.cur = nil
	}
	l.mu.Unlock()
	return nil
}
