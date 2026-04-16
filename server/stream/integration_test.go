package stream_test

import (
	"bytes"
	"context"
	"encoding/binary"
	"net"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/coder/websocket"
	"github.com/onion-coding/marbles-game2/server/stream"
)

// Full path: sim-like TCP producer → Hub → WebSocket client.
// Confirms every byte the "sim" sends comes out of the WS exactly once.
func TestTCPToWebSocketRoundTrip(t *testing.T) {
	hub := stream.NewHub()

	// Bring up TCP ingest on a random port.
	ln, err := stream.Listen(hub, "127.0.0.1:0")
	if err != nil {
		t.Fatalf("Listen: %v", err)
	}
	defer ln.Close()
	tcpAddr := ln.Addr().String()

	// HTTP server for the WS handler.
	mux := http.NewServeMux()
	mux.Handle("/live/{id}", hub.WSHandler())
	srv := httptest.NewServer(mux)
	defer srv.Close()

	// Producer: dial TCP, send round_id + HEADER + 3 TICKs + DONE.
	const roundID = uint64(42)
	conn, err := net.Dial("tcp", tcpAddr)
	if err != nil {
		t.Fatalf("Dial: %v", err)
	}
	defer conn.Close()
	var idBuf [8]byte
	binary.LittleEndian.PutUint64(idBuf[:], roundID)
	if _, err := conn.Write(idBuf[:]); err != nil {
		t.Fatalf("write round id: %v", err)
	}

	send := func(m stream.Message) {
		t.Helper()
		if err := m.Encode(conn); err != nil {
			t.Fatalf("Encode: %v", err)
		}
	}
	send(stream.Message{Type: stream.MsgHeader, Payload: []byte("HDR")})
	send(stream.Message{Type: stream.MsgTick, Payload: []byte("T0")})

	// Wait for the round to appear in the hub before subscribing — otherwise
	// we race the TCP handler's Open call.
	deadline := time.Now().Add(2 * time.Second)
	for hub.Lookup(roundID) == nil {
		if time.Now().After(deadline) {
			t.Fatal("round never appeared in hub")
		}
		time.Sleep(10 * time.Millisecond)
	}

	// WS subscribe. First messages should include the HEADER + T0 backfill.
	wsURL := strings.Replace(srv.URL, "http://", "ws://", 1) + "/live/42"
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	ws, _, err := websocket.Dial(ctx, wsURL, nil)
	if err != nil {
		t.Fatalf("ws Dial: %v", err)
	}
	defer ws.Close(websocket.StatusNormalClosure, "")

	read := func() stream.Message {
		t.Helper()
		typ, data, err := ws.Read(ctx)
		if err != nil {
			t.Fatalf("ws Read: %v", err)
		}
		if typ != websocket.MessageBinary {
			t.Fatalf("ws frame type: got %v want binary", typ)
		}
		m, err := stream.ReadMessage(bytes.NewReader(data), stream.MaxPayloadBytes)
		if err != nil {
			t.Fatalf("parse frame: %v", err)
		}
		return m
	}

	// Expect HEADER then T0 (backfill).
	if got := read(); got.Type != stream.MsgHeader || string(got.Payload) != "HDR" {
		t.Errorf("backfill HEADER: got %+v", got)
	}
	if got := read(); got.Type != stream.MsgTick || string(got.Payload) != "T0" {
		t.Errorf("backfill T0: got %+v", got)
	}

	// Send more live ticks.
	send(stream.Message{Type: stream.MsgTick, Payload: []byte("T1")})
	send(stream.Message{Type: stream.MsgTick, Payload: []byte("T2")})
	send(stream.Message{Type: stream.MsgDone})

	if got := read(); string(got.Payload) != "T1" {
		t.Errorf("live T1: got %+v", got)
	}
	if got := read(); string(got.Payload) != "T2" {
		t.Errorf("live T2: got %+v", got)
	}
	if got := read(); got.Type != stream.MsgDone {
		t.Errorf("DONE: got %+v", got)
	}
}
