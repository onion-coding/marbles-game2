package stream

import (
	"bytes"
	"testing"
)

func TestMessageRoundTrip(t *testing.T) {
	orig := Message{Type: MsgTick, Payload: []byte("hello-world")}
	var buf bytes.Buffer
	if err := orig.Encode(&buf); err != nil {
		t.Fatalf("Encode: %v", err)
	}
	got, err := ReadMessage(&buf, 1<<16)
	if err != nil {
		t.Fatalf("ReadMessage: %v", err)
	}
	if got.Type != orig.Type || !bytes.Equal(got.Payload, orig.Payload) {
		t.Errorf("round-trip mismatch: got %+v want %+v", got, orig)
	}
}

func TestReadMessageEnforcesPayloadCap(t *testing.T) {
	var buf bytes.Buffer
	Message{Type: MsgTick, Payload: make([]byte, 1000)}.Encode(&buf)
	if _, err := ReadMessage(&buf, 500); err == nil {
		t.Fatal("expected cap violation, got nil")
	}
}

func TestHubLifecycle(t *testing.T) {
	h := NewHub()
	r, err := h.Open(42)
	if err != nil {
		t.Fatalf("Open: %v", err)
	}
	if h.Lookup(42) != r {
		t.Fatal("Lookup didn't find the opened round")
	}
	if _, err := h.Open(42); err == nil {
		t.Fatal("second Open of same ID should fail")
	}
	r.Done()
	if h.Lookup(42) != nil {
		t.Error("Lookup still finds round after Done")
	}
	// Idempotent Done.
	r.Done()
}

func TestWriteTickRejectedBeforeHeader(t *testing.T) {
	h := NewHub()
	r, _ := h.Open(1)
	defer r.Done()
	if err := r.WriteTick([]byte{0}); err == nil {
		t.Error("expected ErrHeaderRequired, got nil")
	}
}

func TestSubscriberReceivesHeaderAndTicks(t *testing.T) {
	h := NewHub()
	r, _ := h.Open(1)

	if err := r.WriteHeader([]byte("HDR")); err != nil {
		t.Fatalf("WriteHeader: %v", err)
	}
	if err := r.WriteTick([]byte("T1")); err != nil {
		t.Fatalf("WriteTick: %v", err)
	}

	// New subscriber arrives late — should still get HEADER + backfilled TICK + future TICKs.
	s := r.Subscribe(32)

	drainOne := func(name string, wantType byte, wantPayload string) {
		t.Helper()
		m, ok := <-s.C()
		if !ok {
			t.Fatalf("%s: channel closed early", name)
		}
		if m.Type != wantType {
			t.Errorf("%s: type got 0x%02x want 0x%02x", name, m.Type, wantType)
		}
		if string(m.Payload) != wantPayload {
			t.Errorf("%s: payload got %q want %q", name, string(m.Payload), wantPayload)
		}
	}

	drainOne("header backfill", MsgHeader, "HDR")
	drainOne("tick backfill", MsgTick, "T1")

	if err := r.WriteTick([]byte("T2")); err != nil {
		t.Fatalf("WriteTick: %v", err)
	}
	drainOne("live tick", MsgTick, "T2")

	r.Done()
	drainOne("done", MsgDone, "")

	// After Done, channel closes.
	if _, ok := <-s.C(); ok {
		t.Error("channel should be closed after DONE")
	}
}

func TestMultipleSubscribersAllReceive(t *testing.T) {
	h := NewHub()
	r, _ := h.Open(1)
	r.WriteHeader([]byte("H"))

	s1 := r.Subscribe(32)
	s2 := r.Subscribe(32)

	r.WriteTick([]byte("A"))
	r.WriteTick([]byte("B"))
	r.Done()

	// Each subscriber should see: HEADER, A, B, DONE (4 messages).
	for name, s := range map[string]*Subscriber{"s1": s1, "s2": s2} {
		var msgs []Message
		for m := range s.C() {
			msgs = append(msgs, m)
		}
		if len(msgs) != 4 {
			t.Errorf("%s: got %d messages want 4: %+v", name, len(msgs), msgs)
			continue
		}
		if msgs[0].Type != MsgHeader || msgs[3].Type != MsgDone {
			t.Errorf("%s: order off: %v", name, msgs)
		}
	}
}

func TestSubscriberToClosedRoundGetsBackfillThenDone(t *testing.T) {
	h := NewHub()
	r, _ := h.Open(1)
	r.WriteHeader([]byte("H"))
	r.WriteTick([]byte("A"))
	r.Done()

	// Even though round is done, a subscribe call should still return a usable
	// channel with header + ticks + DONE. (Useful if a client raced with Done.)
	// Note: after Done(), Hub.Lookup returns nil, so callers typically go
	// through the archive API instead. This test just confirms the edge case
	// where a caller holds a *Round reference from before Done.
	s := r.Subscribe(32)
	var types []byte
	for m := range s.C() {
		types = append(types, m.Type)
	}
	want := []byte{MsgHeader, MsgTick, MsgDone}
	if !bytes.Equal(types, want) {
		t.Errorf("types: got %v want %v", types, want)
	}
}
