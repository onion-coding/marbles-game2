// streamtest is a dev utility: polls /live on a replayd instance, picks the
// first active round, subscribes via WebSocket, and prints a per-message-type
// tally. Useful for sanity-checking the full sim → TCP → Hub → WS path without
// a Godot client. Exits when the round emits DONE.
package main

import (
	"bytes"
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"log"
	"net/http"
	"strings"
	"time"

	"github.com/coder/websocket"
	"github.com/onion-coding/marbles-game2/server/stream"
)

func main() {
	apiBase := flag.String("api-base", "http://127.0.0.1:8087", "base URL of replayd")
	flag.Parse()

	wsBase := strings.Replace(*apiBase, "http://", "ws://", 1)

	// Poll /live for an active round.
	var roundID string
	deadline := time.Now().Add(30 * time.Second)
	for {
		if time.Now().After(deadline) {
			log.Fatal("no active round after 30s")
		}
		resp, err := http.Get(*apiBase + "/live")
		if err == nil {
			var got struct {
				RoundIDs []string `json:"round_ids"`
			}
			json.NewDecoder(resp.Body).Decode(&got)
			resp.Body.Close()
			if len(got.RoundIDs) > 0 {
				roundID = got.RoundIDs[0]
				break
			}
		}
		time.Sleep(500 * time.Millisecond)
	}

	fmt.Printf("subscribing to round %s\n", roundID)
	ctx := context.Background()
	ws, _, err := websocket.Dial(ctx, wsBase+"/live/"+roundID, nil)
	if err != nil {
		log.Fatalf("ws Dial: %v", err)
	}
	defer ws.Close(websocket.StatusNormalClosure, "")

	var (
		header, ticks, done int
	)
	start := time.Now()
	for {
		typ, data, err := ws.Read(ctx)
		if err != nil {
			fmt.Printf("read ended: %v\n", err)
			break
		}
		if typ != websocket.MessageBinary {
			log.Printf("unexpected frame type %v", typ)
			continue
		}
		m, err := stream.ReadMessage(bytes.NewReader(data), stream.MaxPayloadBytes)
		if err != nil {
			log.Fatalf("parse: %v", err)
		}
		switch m.Type {
		case stream.MsgHeader:
			header++
			fmt.Printf("HEADER  %d bytes\n", len(m.Payload))
		case stream.MsgTick:
			ticks++
		case stream.MsgDone:
			done++
			fmt.Printf("DONE (received after %s)\n", time.Since(start).Round(time.Millisecond))
		}
	}
	fmt.Printf("summary: HEADER=%d TICK=%d DONE=%d\n", header, ticks, done)
}
