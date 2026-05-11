package casino

import (
	"context"
	"errors"
	"fmt"
	"sync"
	"time"

	"github.com/pion/webrtc/v4"
)

// SFU is a tiny single-publisher / many-subscriber forwarding unit. It owns
// one outbound video track that the publisher writes RTP/sample data into;
// every subscriber peer connection gets that same track copied into its
// transport. Built on Pion v4.
//
// Publisher side: a goroutine inside the rgsd process owns the publisher
// (in M29 it's a synthetic test-pattern source; in M30+ it's ffmpeg fed by
// Godot). The publisher pushes media via PublishVideoSample.
//
// Subscriber side: every browser POSTs an SDP offer to /casino/api/offer.
// The handler creates a peer connection, attaches the shared video track,
// generates an SDP answer, and returns it. From then on Pion delivers RTP
// to that browser whenever the publisher writes a sample.
//
// Concurrency: AddSubscriber is safe to call concurrently with
// PublishVideoSample. Removed peers (closed by ICE failure or browser
// reload) are reaped by Pion automatically — the track goroutine exits
// when the peer connection's underlying transport is gone.
type SFU struct {
	api *webrtc.API

	// videoTrack is the shared track every subscriber attaches to. Writing
	// a sample on it fans out to all attached transports automatically.
	videoTrack *webrtc.TrackLocalStaticSample

	// dataChannelLabel is the label every subscriber's metadata channel
	// uses. The publisher pushes JSON metadata via Broadcast(); each peer's
	// open data channel receives a copy.
	dataChannelLabel string

	mu          sync.RWMutex
	subscribers map[string]*subscriber // peerID → subscriber
}

type subscriber struct {
	id  string
	pc  *webrtc.PeerConnection
	dc  *webrtc.DataChannel // metadata channel; nil until ondatachannel/initial open
	rtt time.Duration       // last measured ICE RTT (placeholder — Pion v4 surfaces stats elsewhere)
}

// SFUConfig is the wiring for NewSFU.
type SFUConfig struct {
	// VideoCodec is the codec the publisher will produce. Defaults to
	// "video/H264" with the standard WebRTC profile-id (42e01f, level 3.1).
	// "video/VP8" is also acceptable but H.264 is more portable across
	// older Safari / iOS versions.
	VideoCodec string

	// DataChannelLabel is the label of the metadata side-channel. Defaults
	// to "casino-meta". Browser code listens for ondatachannel with this
	// label.
	DataChannelLabel string

	// ICEServers, when non-empty, configures STUN/TURN servers for NAT
	// traversal. For local-only deployments (rgsd reachable directly) leave
	// nil — host-candidate ICE works on LAN.
	ICEServers []webrtc.ICEServer
}

// NewSFU constructs an SFU with one shared video track. The publisher is
// not started here — call PublishVideoSample to push frames once your
// source (test pattern, ffmpeg pipe, etc.) is ready.
func NewSFU(cfg SFUConfig) (*SFU, error) {
	if cfg.VideoCodec == "" {
		cfg.VideoCodec = webrtc.MimeTypeH264
	}
	if cfg.DataChannelLabel == "" {
		cfg.DataChannelLabel = "casino-meta"
	}

	// Use a MediaEngine that registers exactly the codec we need. The
	// fmtp line is codec-specific.
	me := &webrtc.MediaEngine{}
	codecCap := webrtc.RTPCodecCapability{
		MimeType:  cfg.VideoCodec,
		ClockRate: 90_000,
	}
	switch cfg.VideoCodec {
	case webrtc.MimeTypeH264:
		codecCap.SDPFmtpLine = "level-asymmetry-allowed=1;packetization-mode=1;profile-level-id=42e01f"
	case webrtc.MimeTypeVP8:
		// VP8 needs no fmtp; ClockRate=90000 is canonical.
	}
	if err := me.RegisterCodec(webrtc.RTPCodecParameters{
		RTPCodecCapability: codecCap,
		PayloadType:        102,
	}, webrtc.RTPCodecTypeVideo); err != nil {
		return nil, fmt.Errorf("casino: register codec: %w", err)
	}
	api := webrtc.NewAPI(webrtc.WithMediaEngine(me))

	track, err := webrtc.NewTrackLocalStaticSample(codecCap, "casino-video", "casino-room")
	if err != nil {
		return nil, fmt.Errorf("casino: new track: %w", err)
	}

	return &SFU{
		api:              api,
		videoTrack:       track,
		dataChannelLabel: cfg.DataChannelLabel,
		subscribers:      map[string]*subscriber{},
	}, nil
}

// AddSubscriber accepts a browser-supplied SDP offer, creates a peer
// connection, attaches the shared video track and a metadata data channel,
// and returns the SDP answer. The peerID returned is the SFU-internal
// handle used in logs and bookkeeping; browsers don't see it.
//
// The peer is automatically reaped when ICE fails or the browser closes —
// the SFU does not require explicit removal.
func (s *SFU) AddSubscriber(ctx context.Context, offerSDP string) (peerID string, answerSDP string, err error) {
	cfg := webrtc.Configuration{}
	pc, err := s.api.NewPeerConnection(cfg)
	if err != nil {
		return "", "", fmt.Errorf("casino: NewPeerConnection: %w", err)
	}

	// Attach the shared video track. RTPSender is returned so we could
	// drive RTCP feedback later (PLI, NACK) — not used in M29.
	if _, err := pc.AddTrack(s.videoTrack); err != nil {
		_ = pc.Close()
		return "", "", fmt.Errorf("casino: AddTrack: %w", err)
	}

	// Create the server-initiated metadata data channel. The browser
	// listens for ondatachannel rather than creating its own so the label
	// and ordering are server-controlled.
	dc, err := pc.CreateDataChannel(s.dataChannelLabel, &webrtc.DataChannelInit{
		Ordered: pointerTo(true),
	})
	if err != nil {
		_ = pc.Close()
		return "", "", fmt.Errorf("casino: CreateDataChannel: %w", err)
	}

	id := newPeerID()
	sub := &subscriber{id: id, pc: pc, dc: dc}

	s.mu.Lock()
	s.subscribers[id] = sub
	s.mu.Unlock()

	// Reap on close / ICE failure.
	pc.OnConnectionStateChange(func(state webrtc.PeerConnectionState) {
		switch state {
		case webrtc.PeerConnectionStateFailed,
			webrtc.PeerConnectionStateClosed,
			webrtc.PeerConnectionStateDisconnected:
			s.mu.Lock()
			delete(s.subscribers, id)
			s.mu.Unlock()
			_ = pc.Close()
		}
	})

	if err := pc.SetRemoteDescription(webrtc.SessionDescription{
		Type: webrtc.SDPTypeOffer,
		SDP:  offerSDP,
	}); err != nil {
		_ = pc.Close()
		return "", "", fmt.Errorf("casino: SetRemoteDescription: %w", err)
	}
	answer, err := pc.CreateAnswer(nil)
	if err != nil {
		_ = pc.Close()
		return "", "", fmt.Errorf("casino: CreateAnswer: %w", err)
	}
	// Wait for ICE gathering to finish so the answer carries every host
	// candidate inline; this avoids the trickle-ICE round-trip and keeps
	// the JS client trivial.
	gatherDone := webrtc.GatheringCompletePromise(pc)
	if err := pc.SetLocalDescription(answer); err != nil {
		_ = pc.Close()
		return "", "", fmt.Errorf("casino: SetLocalDescription: %w", err)
	}
	select {
	case <-gatherDone:
	case <-ctx.Done():
		_ = pc.Close()
		return "", "", ctx.Err()
	}
	return id, pc.LocalDescription().SDP, nil
}

// PublishVideoSample pushes one encoded frame onto the shared video track.
// Pion handles RTP packetization + fan-out to every attached subscriber.
// Caller is responsible for cadence (the publisher loop).
func (s *SFU) PublishVideoSample(data []byte, duration time.Duration) error {
	return s.videoTrack.WriteSample(mediaSample(data, duration))
}

// Broadcast sends a JSON-encoded metadata payload to every subscriber's
// data channel. Used for HUD coords, minimap, names. Errors on individual
// subscribers are swallowed — a slow / dead peer should never affect the
// rest.
func (s *SFU) Broadcast(payload []byte) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	for _, sub := range s.subscribers {
		if sub.dc == nil || sub.dc.ReadyState() != webrtc.DataChannelStateOpen {
			continue
		}
		_ = sub.dc.Send(payload)
	}
}

// SubscriberCount returns the number of currently-attached browsers.
func (s *SFU) SubscriberCount() int {
	s.mu.RLock()
	defer s.mu.RUnlock()
	return len(s.subscribers)
}

// Close shuts down every subscriber. Safe to call once.
func (s *SFU) Close() error {
	s.mu.Lock()
	defer s.mu.Unlock()
	var firstErr error
	for id, sub := range s.subscribers {
		if err := sub.pc.Close(); err != nil && firstErr == nil {
			firstErr = err
		}
		delete(s.subscribers, id)
	}
	return firstErr
}

// ── helpers ─────────────────────────────────────────────────────────────

// ErrNoSDP is returned when the offer body is empty.
var ErrNoSDP = errors.New("casino: empty SDP offer")

// pointerTo is a tiny helper to take the address of a literal value (Pion
// API uses *bool for optional fields).
func pointerTo[T any](v T) *T { return &v }
