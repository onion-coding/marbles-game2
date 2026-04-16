package stream

import (
	"context"
	"errors"
	"log"
	"net/http"
	"strconv"
	"time"

	"github.com/coder/websocket"
)

// ActiveListHandler returns `GET /live` → {"round_ids": ["<id>", ...]} of the
// rounds currently live in the hub. Matches the archive API shape (IDs are
// strings, not numbers, to dodge 19-digit JSON-number precision loss).
func (h *Hub) ActiveListHandler() http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		ids := h.ActiveRounds()
		strs := make([]string, len(ids))
		for i, id := range ids {
			strs[i] = strconv.FormatUint(id, 10)
		}
		w.Header().Set("Content-Type", "application/json")
		w.Header().Set("Access-Control-Allow-Origin", "*")
		_, _ = w.Write(encodeActiveList(strs))
	})
}

func encodeActiveList(ids []string) []byte {
	// Minimal hand-rolled JSON — avoids pulling in encoding/json for one shape
	// and keeps the output deterministic (go's json encoder already is, this
	// is just cheaper).
	out := []byte(`{"round_ids":[`)
	for i, id := range ids {
		if i > 0 {
			out = append(out, ',')
		}
		out = append(out, '"')
		out = append(out, id...)
		out = append(out, '"')
	}
	out = append(out, ']', '}')
	return out
}

// WSHandler returns an http.Handler for `GET /live/{id}`. Clients receive the
// wire-format bytes (type+len+payload) as binary WebSocket frames — exactly
// the same format the sim sent, so the client can use a single decoder for
// both streaming and archive.
func (h *Hub) WSHandler() http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		id, err := strconv.ParseUint(r.PathValue("id"), 10, 64)
		if err != nil {
			http.Error(w, "bad round id", http.StatusBadRequest)
			return
		}
		round := h.Lookup(id)
		if round == nil {
			// Round isn't live (never existed, or already ended). Clients that
			// want a completed round go through the archive API.
			http.Error(w, "round not live", http.StatusNotFound)
			return
		}

		conn, err := websocket.Accept(w, r, &websocket.AcceptOptions{
			// Permissive: archive is public, streams are public. Tighten later if needed.
			InsecureSkipVerify: true,
		})
		if err != nil {
			log.Printf("stream/ws: accept: %v", err)
			return
		}
		defer conn.Close(websocket.StatusInternalError, "handler exit")

		sub := round.Subscribe(180) // ~3s of headroom at 60Hz
		ctx := r.Context()

		for {
			select {
			case m, ok := <-sub.C():
				if !ok {
					// Round done or sub kicked.
					conn.Close(websocket.StatusNormalClosure, "stream ended")
					return
				}
				wctx, cancel := context.WithTimeout(ctx, 10*time.Second)
				err := conn.Write(wctx, websocket.MessageBinary, encodeInline(m))
				cancel()
				if err != nil {
					if !errors.Is(err, context.Canceled) {
						log.Printf("stream/ws: write: %v", err)
					}
					sub.Unsubscribe(round)
					return
				}
			case <-ctx.Done():
				sub.Unsubscribe(round)
				return
			}
		}
	})
}

// encodeInline serializes a Message to a single []byte so we can send one WS
// frame per protocol message. Tiny alloc — worth it for code simplicity.
func encodeInline(m Message) []byte {
	out := make([]byte, 5+len(m.Payload))
	out[0] = m.Type
	out[1] = byte(len(m.Payload))
	out[2] = byte(len(m.Payload) >> 8)
	out[3] = byte(len(m.Payload) >> 16)
	out[4] = byte(len(m.Payload) >> 24)
	copy(out[5:], m.Payload)
	return out
}
