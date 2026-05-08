class_name CasinoFrameStreamer
extends RefCounted

# Captures the active Viewport and ships raw RGBA bytes to a TCP listener
# (rgsd's casino/frame_listener.go). On the wire: 16-byte header
# (MARB magic + u32 W + u32 H + u32 FPS) followed by `W * H * 4`-byte
# frames concatenated, no inter-frame framing. rgsd hands the connection
# to ffmpeg as `-f rawvideo -pix_fmt rgba`, so cadence + dimensions must
# match the header.
#
# Pipeline (Godot 4.4+, Forward+ / Mobile renderer):
#
#   [main thread / tick]
#     └─ submit ─► RenderingServer.call_on_render_thread()
#                              │
#                              ▼
#                    [render thread]
#                    rd.texture_get_data_async(rd_tex, 0, _on_frame_ready)
#                              │ (~1 frame later, GPU finishes)
#                              ▼
#                    _on_frame_ready(bytes) ─► _writer_queue (mutex)
#                                                 │
#                                                 ▼
#                                       [writer thread]
#                                       drains, crops to W×H,
#                                       blocking peer.put_data
#
# Two frames in flight max — main thread never blocks on GPU sync, and
# the blocking TCP write happens on a dedicated thread so it can't stall
# rendering.
#
# Usage:
#   var s := CasinoFrameStreamer.new()
#   s.connect_to(host, port, get_viewport(), 30.0)
#   s.tick(delta)        # call from _process — submits captures
#   s.close()            # drains in-flight, joins writer, closes socket

const TARGET_FPS := 30.0
const MAX_FRAMES_IN_FLIGHT := 2

# ── Connection state ──────────────────────────────────────────────────────

var _peer: StreamPeerTCP = null
var _peer_mutex: Mutex = null     # guards _peer.put_data on the writer thread
var _viewport: Viewport = null
var _accum: float = 0.0
var _frame_period: float = 1.0 / TARGET_FPS
var _ok: bool = false

# Announced (header) dimensions — always even. Captured frames may be
# at >= these dimensions; the writer crops if needed.
var _w: int = 0
var _h: int = 0

# ── Async readback state ──────────────────────────────────────────────────

var _rd: RenderingDevice = null
var _rd_texture: RID = RID()      # resolved lazily on first capture
var _rd_tex_w: int = 0            # actual GPU texture dims (cached)
var _rd_tex_h: int = 0
var _frames_in_flight: int = 0
var _frames_in_flight_mutex: Mutex = null

# ── Writer thread ─────────────────────────────────────────────────────────

var _writer: Thread = null
var _writer_mutex: Mutex = null
var _writer_sem: Semaphore = null
var _writer_queue: Array = []     # of PackedByteArray
var _writer_should_exit: bool = false

# Periodic-stats accumulator + counter, updated by tick().
var _stats_accum: float = 0.0
var _stats_submitted: int = 0

# ── Public API ────────────────────────────────────────────────────────────

# Connects to host:port and binds the source viewport. Returns true on
# success. On true, the writer thread is up and the streamer is ready
# for tick() calls. On false, the streamer is left in a closed state.
func connect_to(host: String, port: int, viewport: Viewport, fps: float = 30.0, connect_timeout_ms: int = 2000) -> bool:
	_viewport = viewport
	_frame_period = 1.0 / max(fps, 1.0)

	# RenderingDevice is only available on Forward+/Mobile. Compatibility
	# returns null and we have no fallback in this implementation.
	_rd = RenderingServer.get_rendering_device()
	if _rd == null:
		push_error("CasinoFrameStreamer: RenderingDevice unavailable; renderer must be Forward+ or Mobile (not Compatibility)")
		return false

	_peer = StreamPeerTCP.new()
	var err := _peer.connect_to_host(host, port)
	if err != OK:
		push_error("CasinoFrameStreamer: connect_to_host err=%d" % err)
		_peer = null
		return false
	var deadline := Time.get_ticks_msec() + connect_timeout_ms
	while Time.get_ticks_msec() < deadline:
		_peer.poll()
		var s := _peer.get_status()
		if s == StreamPeerTCP.STATUS_CONNECTED:
			break
		if s == StreamPeerTCP.STATUS_ERROR:
			push_error("CasinoFrameStreamer: status=ERROR while connecting")
			_peer = null
			return false
		OS.delay_msec(10)
	if _peer.get_status() != StreamPeerTCP.STATUS_CONNECTED:
		push_error("CasinoFrameStreamer: connect timeout")
		_peer = null
		return false
	_peer.set_no_delay(true)

	# Round announced dims down to even — H.264 baseline requires both.
	var sz := _viewport.get_visible_rect().size
	_w = int(sz.x) & ~1
	_h = int(sz.y) & ~1
	var hdr := StreamPeerBuffer.new()
	hdr.big_endian = false
	hdr.put_data("MARB".to_utf8_buffer())
	hdr.put_u32(_w)
	hdr.put_u32(_h)
	hdr.put_u32(int(fps))
	if _peer.put_data(hdr.data_array) != OK:
		push_error("CasinoFrameStreamer: failed to send header")
		_peer = null
		return false

	# Spin up the writer thread.
	_peer_mutex = Mutex.new()
	_frames_in_flight_mutex = Mutex.new()
	_writer_mutex = Mutex.new()
	_writer_sem = Semaphore.new()
	_writer_should_exit = false
	_writer = Thread.new()
	_writer.start(_writer_loop)

	_ok = true
	print("CasinoFrameStreamer: connected to %s:%d, broadcast=%dx%d (viewport=%dx%d), fps=%.1f"
			% [host, port, _w, _h, int(sz.x), int(sz.y), fps])
	return true

# tick is called every frame from the host scene's _process. Accumulates
# delta and submits one async capture each time _frame_period has elapsed
# AND there's headroom in the in-flight pool.
func tick(delta: float) -> void:
	if not _ok or _peer == null:
		return
	_peer.poll()
	if _peer.get_status() != StreamPeerTCP.STATUS_CONNECTED:
		_ok = false
		return
	# Periodic stats so we can tell what's bottlenecked from the log
	# instead of guessing. Every ~2s.
	_stats_accum += delta
	if _stats_accum >= 2.0:
		_stats_accum = 0.0
		_writer_mutex.lock()
		var qlen := _writer_queue.size()
		_writer_mutex.unlock()
		_frames_in_flight_mutex.lock()
		var inflight := _frames_in_flight
		_frames_in_flight_mutex.unlock()
		print("CasinoFrameStreamer: stats godot_fps=%.1f in_flight=%d/%d writer_queue=%d submitted=%d"
				% [Engine.get_frames_per_second(), inflight, MAX_FRAMES_IN_FLIGHT, qlen, _stats_submitted])
		_stats_submitted = 0

	_accum += delta
	if _accum < _frame_period:
		return
	# Backpressure: encoder/SFU is behind, drop this submission slot
	# rather than queueing forever. The accumulator keeps advancing so
	# we'll attempt again next frame.
	_frames_in_flight_mutex.lock()
	var in_flight := _frames_in_flight
	if in_flight < MAX_FRAMES_IN_FLIGHT:
		_frames_in_flight += 1
	_frames_in_flight_mutex.unlock()
	if in_flight >= MAX_FRAMES_IN_FLIGHT:
		return

	_accum = 0.0
	_stats_submitted += 1
	# Async readback hop: schedule on render thread so we touch the GPU
	# resources from the right context.
	RenderingServer.call_on_render_thread(_render_thread_submit)

# is_streaming returns whether we still have a healthy connection.
func is_streaming() -> bool:
	return _ok and _peer != null and _peer.get_status() == StreamPeerTCP.STATUS_CONNECTED

# close drains in-flight readbacks, signals + joins the writer thread,
# and closes the socket. Idempotent.
func close() -> void:
	if not _ok and _peer == null and _writer == null:
		return
	_ok = false

	# Let pending async readbacks land. Each fires within ~1–2 render
	# frames; a 250 ms ceiling is generous and keeps cleanup bounded.
	var deadline := Time.get_ticks_msec() + 250
	while Time.get_ticks_msec() < deadline:
		_frames_in_flight_mutex.lock()
		var n := _frames_in_flight
		_frames_in_flight_mutex.unlock()
		if n <= 0:
			break
		OS.delay_msec(5)

	# Signal writer thread to exit, wake it, join.
	if _writer_mutex != null:
		_writer_mutex.lock()
		_writer_should_exit = true
		_writer_mutex.unlock()
	if _writer_sem != null:
		_writer_sem.post()
	if _writer != null and _writer.is_started():
		_writer.wait_to_finish()
	_writer = null

	if _peer != null:
		_peer.disconnect_from_host()
		_peer = null
	# RID is server-owned — DO NOT free, just drop the reference.
	_rd_texture = RID()
	_rd = null

# ── Render thread: submit one async readback ──────────────────────────────

# Runs on the render thread (RenderingServer.call_on_render_thread). All
# RD operations on the viewport texture must happen here.
func _render_thread_submit() -> void:
	if _rd == null:
		_dec_in_flight()
		return
	if not _rd_texture.is_valid():
		# Resolve once: get_rid() returns the RenderingServer texture handle;
		# texture_get_rd_texture maps it to the RD-side handle. May still be
		# invalid on the very first frame before the viewport has rendered;
		# we'll retry next call.
		var vp_rid := _viewport.get_texture().get_rid()
		_rd_texture = RenderingServer.texture_get_rd_texture(vp_rid)
		if not _rd_texture.is_valid():
			_dec_in_flight()
			return
		# Cache GPU texture dimensions for the writer-side crop.
		var fmt := _rd.texture_get_format(_rd_texture)
		_rd_tex_w = fmt.width
		_rd_tex_h = fmt.height

	var err := _rd.texture_get_data_async(_rd_texture, 0, _on_frame_ready)
	if err != OK:
		push_error("CasinoFrameStreamer: texture_get_data_async err=%d" % err)
		_dec_in_flight()

# Runs on the render thread when the GPU has finished the readback.
# Hand off to the writer thread fast — we're on a hot path.
func _on_frame_ready(bytes: PackedByteArray) -> void:
	_writer_mutex.lock()
	_writer_queue.push_back(bytes)
	_writer_mutex.unlock()
	_writer_sem.post()
	_dec_in_flight()

func _dec_in_flight() -> void:
	_frames_in_flight_mutex.lock()
	if _frames_in_flight > 0:
		_frames_in_flight -= 1
	_frames_in_flight_mutex.unlock()

# ── Writer thread: drain queue, crop, write to TCP ────────────────────────

func _writer_loop() -> void:
	while true:
		_writer_sem.wait()

		_writer_mutex.lock()
		var should_exit := _writer_should_exit
		var batch: Array = _writer_queue
		_writer_queue = []
		_writer_mutex.unlock()

		for raw in batch:
			var data: PackedByteArray = raw as PackedByteArray
			if data.is_empty():
				continue
			var to_send := _crop_to_announced_dims(data)
			if to_send.is_empty():
				continue
			# put_data is blocking on a connected StreamPeerTCP; that's
			# what we want here — TCP-level backpressure throttles the
			# encoder if rgsd's read side falls behind.
			_peer_mutex.lock()
			var p := _peer
			if p != null:
				var err := p.put_data(to_send)
				if err != OK:
					push_error("CasinoFrameStreamer: writer put_data err=%d" % err)
					_peer_mutex.unlock()
					return
			_peer_mutex.unlock()

		if should_exit and _writer_queue.is_empty():
			return

# Crop a captured RGBA buffer down to the announced (_w × _h) dimensions.
# The async readback returns the full GPU texture (`_rd_tex_w × _rd_tex_h`
# bytes per row × 4); we declared _w × _h in the header so every frame
# on the wire must match.
func _crop_to_announced_dims(src: PackedByteArray) -> PackedByteArray:
	if _rd_tex_w == _w and _rd_tex_h == _h:
		return src
	var src_stride := _rd_tex_w * 4
	var dst_stride := _w * 4
	if _rd_tex_w == _w:
		# Width matches — slice off bottom rows. One allocation, no loop.
		return src.slice(0, _h * src_stride)
	# Width AND height differ. Rare path — copy row by row.
	var out := PackedByteArray()
	out.resize(_h * dst_stride)
	for row in range(_h):
		for col in range(dst_stride):
			out[row * dst_stride + col] = src[row * src_stride + col]
	return out
