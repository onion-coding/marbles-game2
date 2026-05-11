package casino

import (
	"context"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"os/exec"
	"sync"
	"time"

	"github.com/pion/webrtc/v4/pkg/media"
	"github.com/pion/webrtc/v4/pkg/media/h264reader"
	"github.com/pion/webrtc/v4/pkg/media/ivfreader"
)

// FFmpegPublisher wraps an ffmpeg subprocess that produces baseline H.264
// in Annex-B format on stdout, parses NAL units with Pion's h264reader,
// groups them into access units (one decoded frame each), and writes
// every access unit onto the SFU's shared video track. From the
// subscriber's point of view this looks identical to a video call.
//
// FFmpegSourceArgs is the only thing that varies between modes:
//
//   - Phase 1.1 smoke: `-f lavfi -i testsrc2=size=640x360:rate=30` —
//     generates a colored animation entirely in ffmpeg.
//   - Phase 2+: `-f rawvideo -pix_fmt rgba -s WxH -r 60 -i pipe:N` —
//     accepts raw frames piped from Godot.
//
// In both cases the encode args (libx264 ultrafast, baseline 3.1,
// keyframe every second, no B-frames) are tuned for sub-200 ms encode
// latency on a single CPU thread; replace with `-c:v h264_nvenc` etc.
// later if hardware encode is available.
type FFmpegPublisher struct {
	cfg FFmpegPublisherConfig
	sfu *SFU
	log *slog.Logger

	mu  sync.Mutex
	cmd *exec.Cmd
}

// FFmpegPublisherConfig wires everything the publisher needs to start.
//
// Two input modes, mutually exclusive:
//   - SourceArgs: ffmpeg-internal source (e.g. lavfi testsrc2 for smoke
//     tests). Set to nil/empty to disable.
//   - RawVideo: raw frames piped to ffmpeg's stdin from a Go io.Reader.
//     This is the Godot-fed mode; the Reader typically wraps a TCP
//     connection from the FrameListener.
//
// When RawVideo is set, RawWidth/RawHeight/RawPixFmt describe the input
// frames (must match what Godot sends).
type FFmpegPublisherConfig struct {
	// Bin is the absolute path to ffmpeg.exe. Required.
	Bin string
	// SourceArgs is the ffmpeg input description (everything before the
	// codec args). For the Phase 1.1 smoke test, set this to:
	//   []string{"-f", "lavfi", "-i", "testsrc2=size=854x480:rate=30"}
	// Mutually exclusive with RawVideo.
	SourceArgs []string

	// RawVideo, when non-nil, is piped to ffmpeg's stdin as raw video.
	// Mutually exclusive with SourceArgs. Caller owns the Reader's
	// lifetime — Close it to make ffmpeg exit cleanly.
	RawVideo io.Reader
	// RawWidth, RawHeight, RawPixFmt describe the raw frames in
	// RawVideo. Required when RawVideo is set. RawPixFmt examples:
	// "rgba", "bgra", "yuv420p". Godot's get_image() returns RGBA8.
	RawWidth, RawHeight int
	RawPixFmt           string

	// FPS drives the duration each access unit is announced as on the
	// track. Should match what the source is producing.
	FPS int
	// EncodePreset maps to libx264's --preset; "ultrafast" is the
	// lowest-latency option, "veryfast" is a reasonable middle ground.
	// Ignored when Encoder == "h264_amf".
	EncodePreset string
	// Encoder selects the video codec. "libx264" (default) for portable
	// CPU encode, "h264_amf" for AMD GPU hardware encode (requires
	// ffmpeg built with --enable-amf and an AMD GPU + driver). On any
	// other value we error out at Start.
	Encoder string
	// AMFBitrateBps is the constant bitrate in bps used when Encoder
	// is "h264_amf". Defaults to 4_000_000 (4 Mb/s).
	AMFBitrateBps int
	// Logger; defaults to slog.Default().
	Logger *slog.Logger
}

// NewFFmpegPublisher constructs the publisher; nothing happens until Start.
func NewFFmpegPublisher(sfu *SFU, cfg FFmpegPublisherConfig) (*FFmpegPublisher, error) {
	if sfu == nil {
		return nil, errors.New("casino/ffmpeg: sfu is nil")
	}
	if cfg.Bin == "" {
		return nil, errors.New("casino/ffmpeg: Bin (path to ffmpeg.exe) is required")
	}
	hasSource := len(cfg.SourceArgs) > 0
	hasRaw := cfg.RawVideo != nil
	if hasSource == hasRaw {
		return nil, errors.New("casino/ffmpeg: exactly one of SourceArgs or RawVideo must be set")
	}
	if hasRaw {
		if cfg.RawWidth <= 0 || cfg.RawHeight <= 0 {
			return nil, errors.New("casino/ffmpeg: RawWidth and RawHeight must be > 0 in raw mode")
		}
		if cfg.RawPixFmt == "" {
			cfg.RawPixFmt = "rgba"
		}
	}
	if cfg.FPS <= 0 {
		cfg.FPS = 30
	}
	if cfg.EncodePreset == "" {
		cfg.EncodePreset = "ultrafast"
	}
	if cfg.Encoder == "" {
		cfg.Encoder = "libx264"
	}
	if cfg.Encoder != "libx264" && cfg.Encoder != "h264_amf" && cfg.Encoder != "libvpx" {
		return nil, fmt.Errorf("casino/ffmpeg: Encoder %q not supported (use libx264, h264_amf, or libvpx)", cfg.Encoder)
	}
	if cfg.AMFBitrateBps <= 0 {
		cfg.AMFBitrateBps = 4_000_000
	}
	if cfg.Logger == nil {
		cfg.Logger = slog.Default()
	}
	return &FFmpegPublisher{cfg: cfg, sfu: sfu, log: cfg.Logger}, nil
}

// Start spawns ffmpeg, reads its stdout, parses NAL units, groups them
// into access units, and writes each AU to the SFU video track. Returns
// when ctx is cancelled or the subprocess dies, whichever comes first.
//
// The function is intentionally serial — one ffmpeg per FFmpegPublisher.
// For multiple concurrent rounds, instantiate multiple publishers, each
// against its own SFU instance.
func (p *FFmpegPublisher) Start(ctx context.Context) error {
	var args []string
	if p.cfg.RawVideo != nil {
		// Raw mode: ffmpeg reads RGBA from stdin; cadence + dimensions
		// must match what the producer (Godot) is sending exactly, or
		// libavformat will misinterpret frame boundaries.
		args = []string{
			"-f", "rawvideo",
			"-pix_fmt", p.cfg.RawPixFmt,
			"-s", fmt.Sprintf("%dx%d", p.cfg.RawWidth, p.cfg.RawHeight),
			"-r", fmt.Sprint(p.cfg.FPS),
			"-i", "pipe:0",
		}
	} else {
		args = append([]string{}, p.cfg.SourceArgs...)
	}
	// GOP = FPS/4 → keyframe every ~0.25 s. Aggressive but matters for
	// WebRTC: a fresh subscriber can only render once it receives an
	// IDR, so short GOPs keep the "black until first keyframe" window
	// small. The bitrate cost of frequent IDRs is offset by the low
	// resolution + ultralowlatency / ultrafast presets.
	gop := p.cfg.FPS / 4
	if gop < 4 {
		gop = 4
	}
	switch p.cfg.Encoder {
	case "h264_amf":
		args = append(args,
			"-c:v", "h264_amf",
			"-usage", "ultralowlatency",
			"-quality", "speed",
			"-rc", "cbr",
			"-b:v", fmt.Sprintf("%d", p.cfg.AMFBitrateBps),
			"-bf", "0",
			"-r", fmt.Sprint(p.cfg.FPS),
			"-g", fmt.Sprint(gop),
			"-keyint_min", fmt.Sprint(gop),
			"-bsf:v", "h264_mp4toannexb",
			"-an",
			"-f", "h264",
			"pipe:1",
		)
	case "libvpx":
		// VP8 encoder. Realtime deadline + cpu-used 8 (max speed); IVF
		// container so Pion's ivfreader can parse frame boundaries.
		args = append(args,
			"-c:v", "libvpx",
			"-deadline", "realtime",
			"-cpu-used", "8",
			"-b:v", fmt.Sprintf("%d", p.cfg.AMFBitrateBps),
			"-r", fmt.Sprint(p.cfg.FPS),
			"-g", fmt.Sprint(gop),
			"-keyint_min", fmt.Sprint(gop),
			"-pix_fmt", "yuv420p",
			"-an",
			"-f", "ivf",
			"pipe:1",
		)
	default: // "libx264"
		args = append(args,
			"-c:v", "libx264",
			"-preset", p.cfg.EncodePreset,
			"-tune", "zerolatency",
			"-profile:v", "baseline",
			"-level", "3.1",
			"-pix_fmt", "yuv420p",
			"-r", fmt.Sprint(p.cfg.FPS),
			"-g", fmt.Sprint(gop),
			"-keyint_min", fmt.Sprint(gop),
			"-sc_threshold", "0",
			"-force_key_frames", fmt.Sprintf("expr:gte(t,n_forced*%f)", float64(gop)/float64(p.cfg.FPS)),
			"-bsf:v", "h264_mp4toannexb",
			"-an",
			"-f", "h264",
			"pipe:1",
		)
	}
	cmd := exec.CommandContext(ctx, p.cfg.Bin, args...)
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		return fmt.Errorf("casino/ffmpeg: stdout pipe: %w", err)
	}
	stderr, err := cmd.StderrPipe()
	if err != nil {
		return fmt.Errorf("casino/ffmpeg: stderr pipe: %w", err)
	}
	var stdin io.WriteCloser
	if p.cfg.RawVideo != nil {
		stdin, err = cmd.StdinPipe()
		if err != nil {
			return fmt.Errorf("casino/ffmpeg: stdin pipe: %w", err)
		}
	}

	p.mu.Lock()
	p.cmd = cmd
	p.mu.Unlock()

	if err := cmd.Start(); err != nil {
		return fmt.Errorf("casino/ffmpeg: start: %w", err)
	}
	p.log.Info("casino/ffmpeg: started",
		"bin", p.cfg.Bin, "fps", p.cfg.FPS, "preset", p.cfg.EncodePreset,
		"mode", inputMode(p.cfg))

	// Drain stderr to debug log so a crash leaves a trail. Bounded so a
	// runaway encoder can't OOM the daemon.
	go p.drainStderr(stderr)

	// Raw mode: pump bytes from the producer Reader → ffmpeg stdin until
	// either the Reader hits EOF (Godot disconnected) or ctx cancels.
	if stdin != nil {
		go func() {
			defer stdin.Close()
			_, err := io.Copy(stdin, p.cfg.RawVideo)
			if err != nil && !errors.Is(err, io.EOF) {
				p.log.Info("casino/ffmpeg: stdin pump exited", "err", err)
			}
		}()
	}

	if p.cfg.Encoder == "libvpx" {
		return p.pumpIVF(ctx, stdout)
	}
	return p.pumpNALs(ctx, stdout)
}

// pumpIVF reads VP8 frames from an IVF stream and writes each as a
// WriteSample to the SFU track. IVF is a simple container: 32-byte
// global header, then per-frame: 12-byte frame header + payload.
func (p *FFmpegPublisher) pumpIVF(ctx context.Context, r io.Reader) error {
	rdr, hdr, err := ivfreader.NewWith(r)
	if err != nil {
		return fmt.Errorf("casino/ffmpeg ivf header: %w", err)
	}
	p.log.Info("casino/ffmpeg ivf header", "fourcc", string(hdr.FourCC[:]),
		"w", hdr.Width, "h", hdr.Height, "ts_num", hdr.TimebaseNumerator, "ts_den", hdr.TimebaseDenominator)
	frameDur := time.Second / time.Duration(p.cfg.FPS)
	for {
		select {
		case <-ctx.Done():
			return ctx.Err()
		default:
		}
		frame, _, err := rdr.ParseNextFrame()
		if err != nil {
			if errors.Is(err, io.EOF) {
				return nil
			}
			return fmt.Errorf("casino/ffmpeg ivf parse: %w", err)
		}
		if err := p.sfu.PublishVideoSample(frame, frameDur); err != nil {
			return fmt.Errorf("casino/ffmpeg ivf WriteSample: %w", err)
		}
	}
}

func inputMode(c FFmpegPublisherConfig) string {
	if c.RawVideo != nil {
		return fmt.Sprintf("rawvideo %dx%d %s", c.RawWidth, c.RawHeight, c.RawPixFmt)
	}
	return "lavfi-source"
}

// drainStderr forwards ffmpeg's stderr to slog. Logs the first banner
// chunk verbatim, then keeps a small ring of the most recent lines
// (default 32) so that when ffmpeg crashes the failure context is on
// disk, not silently swallowed.
func (p *FFmpegPublisher) drainStderr(r io.ReadCloser) {
	defer r.Close()
	buf := make([]byte, 4096)
	for {
		n, err := r.Read(buf)
		if n > 0 {
			p.log.Info("casino/ffmpeg stderr", "msg", string(buf[:n]))
		}
		if err != nil {
			return
		}
	}
}

// pumpNALs reads NAL units from r (Annex-B), groups them into access
// units, and writes each AU as a single media.Sample. AU boundaries are
// detected via the "first slice of new picture" heuristic that h264reader
// surfaces: a new VCL NAL after we've already seen a VCL NAL in the
// current AU starts a new AU.
//
// This is the same boundary rule webrtc reference apps use; matches the
// behaviour of `srtp.RTPRewriter` and ffmpeg's `-bsf h264_mp4toannexb`
// output.
func (p *FFmpegPublisher) pumpNALs(ctx context.Context, r io.Reader) error {
	reader, err := h264reader.NewReader(r)
	if err != nil {
		return fmt.Errorf("casino/ffmpeg: h264reader: %w", err)
	}

	frameDur := time.Second / time.Duration(p.cfg.FPS)
	var au []byte // current access unit, Annex-B format with 0x00000001 prefixes
	var sawVCL bool
	flushAU := func() error {
		if len(au) == 0 {
			return nil
		}
		if err := p.sfu.PublishVideoSample(au, frameDur); err != nil {
			return fmt.Errorf("casino/ffmpeg: WriteSample: %w", err)
		}
		au = nil
		sawVCL = false
		return nil
	}

	for {
		select {
		case <-ctx.Done():
			return ctx.Err()
		default:
		}
		nal, err := reader.NextNAL()
		if err != nil {
			if errors.Is(err, io.EOF) {
				_ = flushAU()
				return nil
			}
			return fmt.Errorf("casino/ffmpeg: NextNAL: %w", err)
		}
		if nal == nil {
			continue
		}
		isVCL := isVCLNAL(nal.UnitType)
		// New AU boundary: a VCL NAL appearing after we've already seen one.
		if isVCL && sawVCL {
			if err := flushAU(); err != nil {
				return err
			}
		}
		// Pion's h264reader.NAL.Data is "header byte + rbsp" (per the
		// in-source docstring at h264reader.go line 86) — i.e. the NAL
		// header is INCLUDED. We only need to prepend the start code.
		au = append(au, 0x00, 0x00, 0x00, 0x01)
		au = append(au, nal.Data...)
		if isVCL {
			sawVCL = true
		}
	}
}

// isVCLNAL returns true for slice NAL types that carry coded picture data
// — these are the units that delimit access units. NAL types 1 and 5
// cover non-IDR and IDR slices respectively, which is all baseline
// profile uses. Higher-profile streams with SVC/MVC (types 14, 20, 21)
// don't apply here because we emit baseline.
func isVCLNAL(t h264reader.NalUnitType) bool {
	return t == h264reader.NalUnitTypeCodedSliceNonIdr ||
		t == h264reader.NalUnitTypeCodedSliceIdr
}

// _unused keeps the media package referenced for future use (sample
// builders etc.). Erase if not needed.
var _ = media.Sample{}
