package stream

import (
	"encoding/binary"
	"errors"
	"fmt"
	"io"
	"log"
	"net"
	"sync"
	"time"
)

// MaxPayloadBytes caps a single wire-format message. One tick for 20 marbles
// in the v2 format is ~565 bytes; a 1 MB ceiling is orders of magnitude over
// that but well below any resource concern.
const MaxPayloadBytes uint32 = 1 << 20

// Listener accepts sim-side TCP connections on a given address and routes the
// streamed messages into the Hub. The sim must send its round_id as the first
// 8 bytes on the connection (little-endian u64), then begin protocol messages.
// One connection per round.
type Listener struct {
	hub  *Hub
	ln   net.Listener
	wg   sync.WaitGroup
	quit chan struct{}
}

// Listen binds to addr and starts accepting sim connections in the background.
// Caller must call Close() for a clean shutdown.
func Listen(hub *Hub, addr string) (*Listener, error) {
	ln, err := net.Listen("tcp", addr)
	if err != nil {
		return nil, fmt.Errorf("stream: listen %s: %w", addr, err)
	}
	l := &Listener{hub: hub, ln: ln, quit: make(chan struct{})}
	l.wg.Add(1)
	go l.acceptLoop()
	return l, nil
}

// Addr returns the listen address (useful when addr=":0" picks a random port).
func (l *Listener) Addr() net.Addr { return l.ln.Addr() }

// Close stops accepting new connections and waits for in-flight handlers.
func (l *Listener) Close() error {
	close(l.quit)
	err := l.ln.Close()
	l.wg.Wait()
	return err
}

func (l *Listener) acceptLoop() {
	defer l.wg.Done()
	for {
		conn, err := l.ln.Accept()
		if err != nil {
			select {
			case <-l.quit:
				return
			default:
				log.Printf("stream: accept error: %v", err)
				return
			}
		}
		l.wg.Add(1)
		go func() {
			defer l.wg.Done()
			l.handleConn(conn)
		}()
	}
}

func (l *Listener) handleConn(conn net.Conn) {
	defer conn.Close()
	// First 8 bytes = round_id (little-endian u64). Pick a short read deadline
	// so a probe on the port doesn't tie up a goroutine.
	_ = conn.SetReadDeadline(time.Now().Add(5 * time.Second))
	var idBuf [8]byte
	if _, err := io.ReadFull(conn, idBuf[:]); err != nil {
		log.Printf("stream: read round_id: %v", err)
		return
	}
	roundID := binary.LittleEndian.Uint64(idBuf[:])
	_ = conn.SetReadDeadline(time.Time{}) // no deadline for the stream body

	round, err := l.hub.Open(roundID)
	if err != nil {
		log.Printf("stream: open round %d: %v", roundID, err)
		return
	}
	log.Printf("stream: round %d live from %s", roundID, conn.RemoteAddr())

	defer func() {
		// On any disconnect, finalize the round so subscribers get DONE.
		// (If the sim sent an explicit MsgDone we already finalized; Done() is idempotent.)
		round.Done()
		log.Printf("stream: round %d closed", roundID)
	}()

	for {
		m, err := ReadMessage(conn, MaxPayloadBytes)
		if err != nil {
			if !errors.Is(err, io.EOF) {
				log.Printf("stream: round %d read: %v", roundID, err)
			}
			return
		}
		switch m.Type {
		case MsgHeader:
			if err := round.WriteHeader(m.Payload); err != nil {
				log.Printf("stream: round %d header: %v", roundID, err)
				return
			}
		case MsgTick:
			if err := round.WriteTick(m.Payload); err != nil {
				log.Printf("stream: round %d tick: %v", roundID, err)
				return
			}
		case MsgDone:
			return
		default:
			log.Printf("stream: round %d unknown msg type 0x%02x", roundID, m.Type)
			return
		}
	}
}
