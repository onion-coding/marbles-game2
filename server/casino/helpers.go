package casino

import (
	"crypto/rand"
	"encoding/hex"
	"time"

	"github.com/pion/webrtc/v4/pkg/media"
)

// mediaSample wraps a single encoded video sample for Pion's
// TrackLocalStaticSample.WriteSample. The duration is the time between
// this frame and the next (1/60 s for 60 Hz video, 1/30 s for 30 Hz).
func mediaSample(data []byte, dur time.Duration) media.Sample {
	return media.Sample{Data: data, Duration: dur}
}

// newPeerID returns a short hex identifier for an SFU subscriber.
// Format is intentionally compact for log lines; uniqueness within a
// session is what matters, not cryptographic strength.
func newPeerID() string {
	var b [6]byte
	_, _ = rand.Read(b[:])
	return "peer_" + hex.EncodeToString(b[:])
}
