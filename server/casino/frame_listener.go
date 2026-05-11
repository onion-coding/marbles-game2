package casino

import (
	"context"
	"encoding/binary"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"net"
	"sync"
	"time"
)

// ReadFrameHeader reads the 16-byte self-reported video format header
// that CasinoFrameStreamer sends as the first bytes of the TCP stream:
//
//	bytes  0..3  : ASCII "MARB"
//	bytes  4..7  : u32 LE width
//	bytes  8..11 : u32 LE height
//	bytes 12..15 : u32 LE fps
//
// On success the connection's read pointer is positioned at the first
// raw RGBA byte and the caller can hand it straight to an ffmpeg
// rawvideo input. Returns an error (with the connection still open) if
// the magic doesn't match or any read fails — caller decides whether to
// fall back to CLI defaults or close the conn.
func ReadFrameHeader(r io.Reader) (width, height, fps int, err error) {
	var hdr [16]byte
	if _, err = io.ReadFull(r, hdr[:]); err != nil {
		return 0, 0, 0, fmt.Errorf("casino/frame: read header: %w", err)
	}
	if string(hdr[0:4]) != "MARB" {
		return 0, 0, 0, fmt.Errorf("casino/frame: bad magic %q (want \"MARB\")", string(hdr[0:4]))
	}
	width = int(binary.LittleEndian.Uint32(hdr[4:8]))
	height = int(binary.LittleEndian.Uint32(hdr[8:12]))
	fps = int(binary.LittleEndian.Uint32(hdr[12:16]))
	if width <= 0 || height <= 0 || fps <= 0 {
		return 0, 0, 0, fmt.Errorf("casino/frame: invalid header dims %dx%d@%d", width, height, fps)
	}
	return width, height, fps, nil
}

// FrameListener accepts TCP connections from the Godot subprocess
// carrying raw RGBA frames at a known resolution + framerate.
//
// Lifecycle: Run() blocks accepting publishers serially — each connection
// is handed to the supplied callback; the listener does NOT accept another
// publisher until that callback returns (so a long-lived publisher runs
// uninterrupted). When Godot disconnects, the callback returns and the
// listener accepts the next reconnection automatically. Concurrent
// publisher attempts arriving while one is live block in the OS accept
// queue rather than being rejected — they're served as soon as the
// current publisher exits.
//
// Wire format on the socket: a 16-byte header (see ReadFrameHeader) then
// a continuous byte stream of RGBA frames concatenated, with no framing
// — ffmpeg's "-f rawvideo -s WxH -r N" already knows the cadence.
type FrameListener struct {
	addr string
	log  *slog.Logger

	ln  net.Listener
	mu  sync.Mutex
	cur io.ReadCloser // current Godot connection, nil between publishers
}

// NewFrameListener binds the listener; call Accept inside a goroutine to
// receive the first Godot connection as an io.Reader.
func NewFrameListener(addr string, log *slog.Logger) (*FrameListener, error) {
	if log == nil {
		log = slog.Default()
	}
	ln, err := net.Listen("tcp", addr)
	if err != nil {
		return nil, fmt.Errorf("casino/frame: listen %s: %w", addr, err)
	}
	return &FrameListener{addr: addr, log: log, ln: ln}, nil
}

// Addr returns the listener's bound address (useful when addr=":0").
func (l *FrameListener) Addr() string { return l.ln.Addr().String() }

// Run is the main loop. It accepts publishers serially: for each
// connection, the caller's onPublisher callback is invoked synchronously
// with the io.ReadCloser; when the callback returns, the connection is
// closed and the listener loops back to accept the next reconnection.
//
// Run is intended to be called inside a goroutine. It returns when ctx
// is cancelled or the underlying listener is Closed; transient accept
// errors are logged and the loop continues so an EAGAIN doesn't kill
// the stream after a Godot restart.
func (l *FrameListener) Run(ctx context.Context, onPublisher func(io.ReadCloser)) error {
	// Cancel the underlying Accept when ctx is done so the loop unblocks.
	go func() {
		<-ctx.Done()
		_ = l.ln.Close()
	}()
	for {
		conn, err := l.ln.Accept()
		if err != nil {
			if ctx.Err() != nil {
				return ctx.Err()
			}
			if errors.Is(err, net.ErrClosed) {
				return nil
			}
			// Transient accept error — log + back off briefly.
			l.log.Warn("casino/frame: accept error (will retry)", "err", err)
			select {
			case <-time.After(200 * time.Millisecond):
			case <-ctx.Done():
				return ctx.Err()
			}
			continue
		}
		l.log.Info("casino/frame: Godot connected", "remote", conn.RemoteAddr())

		l.mu.Lock()
		l.cur = conn
		l.mu.Unlock()

		// Drive the publisher. Blocks until Godot disconnects (or the
		// ffmpeg subprocess fed by it exits, depending on the callback).
		onPublisher(conn)

		l.mu.Lock()
		_ = l.cur.Close()
		l.cur = nil
		l.mu.Unlock()
		l.log.Info("casino/frame: publisher ended; awaiting next Godot connection")
	}
}

// Close stops accepting and tears down the active connection.
func (l *FrameListener) Close() error {
	var err error
	if l.ln != nil {
		err = l.ln.Close()
	}
	l.mu.Lock()
	if l.cur != nil {
		_ = l.cur.Close()
		l.cur = nil
	}
	l.mu.Unlock()
	if err != nil && !errors.Is(err, net.ErrClosed) {
		return err
	}
	return nil
}
