package casino

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"os/exec"
)

// ProbeFFmpegEncoder runs a 1-second lavfi testsrc through the requested
// encoder and discards the output. Returns nil on success (encoder
// initialized + produced at least one frame) or an error describing
// what ffmpeg complained about. Used at rgsd startup to decide whether
// to use a hardware encoder (h264_amf) or fall back to libx264 BEFORE
// Godot connects — so a fallback never has to drop a real publisher
// mid-stream.
//
// Cost: ~half a second of CPU + (for h264_amf) one GPU init/teardown.
// Acceptable to do once at startup.
func ProbeFFmpegEncoder(ctx context.Context, bin, encoder string) error {
	if bin == "" {
		return errors.New("casino/probe: ffmpeg bin is empty")
	}
	var args []string
	switch encoder {
	case "h264_amf":
		args = []string{
			"-hide_banner", "-loglevel", "error",
			"-f", "lavfi", "-i", "testsrc2=size=320x180:rate=30:duration=1",
			"-c:v", "h264_amf",
			"-usage", "ultralowlatency",
			"-quality", "speed",
			"-rc", "cbr",
			"-b:v", "1M",
			"-bf", "0",
			"-frames:v", "30",
			"-an",
			"-f", "null", "-",
		}
	case "libx264":
		args = []string{
			"-hide_banner", "-loglevel", "error",
			"-f", "lavfi", "-i", "testsrc2=size=320x180:rate=30:duration=1",
			"-c:v", "libx264",
			"-preset", "ultrafast",
			"-tune", "zerolatency",
			"-frames:v", "30",
			"-an",
			"-f", "null", "-",
		}
	default:
		return fmt.Errorf("casino/probe: unsupported encoder %q", encoder)
	}
	cmd := exec.CommandContext(ctx, bin, args...)
	var stderr bytes.Buffer
	cmd.Stderr = &stderr
	if err := cmd.Run(); err != nil {
		// Surface ffmpeg's own error message (with "-loglevel error" stderr
		// stays narrow — driver-init / encoder-init lines are present).
		msg := bytes.TrimSpace(stderr.Bytes())
		return fmt.Errorf("casino/probe %s: %w; ffmpeg stderr: %s", encoder, err, msg)
	}
	return nil
}
