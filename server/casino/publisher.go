package casino

import (
	"context"
	"encoding/json"
	"log/slog"
	"time"
)

// HeartbeatPublisher is the Phase-1.0 placeholder: it doesn't produce any
// video, but it pushes a tiny JSON heartbeat to every connected
// subscriber's data channel every interval. The point is to verify the
// WebRTC plumbing — SDP exchange, peer connection, DataChannel open — end
// to end before introducing the ffmpeg / Godot video pipeline.
//
// Phase 1.1 replaces this with a real H.264 publisher (ffmpeg-encoded
// frames from a static file, then live frames from Godot in M30+).
type HeartbeatPublisher struct {
	sfu      *SFU
	interval time.Duration
	log      *slog.Logger
}

// NewHeartbeatPublisher constructs the publisher; call Start to begin.
func NewHeartbeatPublisher(sfu *SFU, interval time.Duration, log *slog.Logger) *HeartbeatPublisher {
	if interval <= 0 {
		interval = 500 * time.Millisecond
	}
	if log == nil {
		log = slog.Default()
	}
	return &HeartbeatPublisher{sfu: sfu, interval: interval, log: log}
}

// Start runs the heartbeat loop until ctx is done. Returns nil when ctx
// expires; designed to be called inside a goroutine in main.
func (h *HeartbeatPublisher) Start(ctx context.Context) error {
	t := time.NewTicker(h.interval)
	defer t.Stop()
	seq := uint64(0)
	for {
		select {
		case <-ctx.Done():
			return nil
		case now := <-t.C:
			seq++
			payload, _ := json.Marshal(heartbeatMessage{
				Type:        "heartbeat",
				Seq:         seq,
				ServerTime:  now.UTC(),
				Subscribers: h.sfu.SubscriberCount(),
				Note:        "phase-1.0 plumbing-only; video lands in phase 1.1",
			})
			h.sfu.Broadcast(payload)
		}
	}
}

type heartbeatMessage struct {
	Type        string    `json:"type"`
	Seq         uint64    `json:"seq"`
	ServerTime  time.Time `json:"server_time"`
	Subscribers int       `json:"subscribers"`
	Note        string    `json:"note"`
}
