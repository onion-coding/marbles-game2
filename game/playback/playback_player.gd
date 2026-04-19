class_name PlaybackPlayer
extends Node3D

const MARBLE_RADIUS := 0.3

var _frames: Array = []
var _header: Array = []
var _tick_rate: float = 60.0
var _marbles: Array[Node3D] = []
var _elapsed_ticks: float = 0.0
var _finished := false
# Streaming mode: frames arrive incrementally over a live WS feed. In that mode
# we don't emit playback_finished when _elapsed_ticks hits the tail — we hold
# the last available frame and wait. end_stream() flips _stream_done, which
# lets the normal tail-of-replay handling fire once the cursor gets there.
var _streaming := false
var _stream_done := false

signal playback_finished(last_tick: int, first_marble_pos: Vector3)

func load_replay(replay: Dictionary) -> void:
	_header = replay["header"]
	_frames = replay["frames"]
	_tick_rate = float(replay["tick_rate_hz"])
	_streaming = false
	_stream_done = false
	_finished = false
	_elapsed_ticks = 0.0
	_build_marbles()
	# Snap to the first recorded frame so the scene is valid before playback starts.
	_apply_frame_state(_frames[0])

# Streaming entrypoint — call once on HEADER arrival. Builds marble nodes and
# resets the playback cursor. After this, feed tick frames via append_frame
# and call end_stream() when DONE arrives.
func begin_stream(header_dict: Dictionary) -> void:
	_header = header_dict["header"]
	_frames = []
	_tick_rate = float(header_dict["tick_rate_hz"])
	_streaming = true
	_stream_done = false
	_finished = false
	_elapsed_ticks = 0.0
	_build_marbles()

# Push one decoded tick frame into the buffer. Safe to call before begin_stream
# completes (no-op), but callers should always send HEADER first.
func append_frame(frame: Dictionary) -> void:
	if not _streaming:
		return
	_frames.append(frame)
	# Snap the scene to the first frame as soon as it's available; otherwise
	# marbles stay at (0,0,0) until _process runs and interpolation kicks in.
	if _frames.size() == 1:
		_apply_frame_state(frame)

# Signal that no more frames will arrive. Once playback catches up to the tail,
# playback_finished fires just like for file-based playback.
func end_stream() -> void:
	_stream_done = true

func _build_marbles() -> void:
	for m in _marbles:
		m.queue_free()
	_marbles.clear()
	for m in _header:
		var node := MeshInstance3D.new()
		node.name = m["name"]
		var sphere := SphereMesh.new()
		sphere.radius = MARBLE_RADIUS
		sphere.height = MARBLE_RADIUS * 2.0
		node.mesh = sphere
		var mat := StandardMaterial3D.new()
		var rgba: int = m["rgba"]
		if rgba == 0:
			# Deterministic fallback color by header index so M1/M2 look roughly alike.
			mat.albedo_color = Color.from_hsv(float(_marbles.size()) / max(_header.size(), 1), 0.8, 0.95)
		else:
			mat.albedo_color = Color(((rgba >> 24) & 0xFF) / 255.0, ((rgba >> 16) & 0xFF) / 255.0, ((rgba >> 8) & 0xFF) / 255.0, (rgba & 0xFF) / 255.0)
		node.material_override = mat
		add_child(node)
		_marbles.append(node)

func _process(delta: float) -> void:
	if _finished or _frames.is_empty():
		return
	_elapsed_ticks += delta * _tick_rate
	var idx_f: float = min(_elapsed_ticks, float(_frames.size() - 1))
	var i := int(idx_f)
	var t := idx_f - float(i)
	if i + 1 < _frames.size():
		_apply_interpolated(_frames[i], _frames[i + 1], t)
	else:
		# Tail of the buffer. In file-playback this is end-of-race; in streaming
		# it's just "next frame hasn't arrived yet" — hold unless DONE was signaled.
		_apply_frame_state(_frames[i])
		if not _streaming or _stream_done:
			_finished = true
			var last: Dictionary = _frames[_frames.size() - 1]
			playback_finished.emit(int(last["tick"]), (last["states"][0]["pos"] as Vector3))

func _apply_frame_state(frame: Dictionary) -> void:
	var states: Array = frame["states"]
	for j in range(min(_marbles.size(), states.size())):
		var s: Dictionary = states[j]
		_marbles[j].global_position = s["pos"]
		_marbles[j].global_basis = Basis(s["rot"] as Quaternion)

func _apply_interpolated(a: Dictionary, b: Dictionary, t: float) -> void:
	var sa: Array = a["states"]
	var sb: Array = b["states"]
	for j in range(min(_marbles.size(), sa.size())):
		_marbles[j].global_position = (sa[j]["pos"] as Vector3).lerp(sb[j]["pos"] as Vector3, t)
		_marbles[j].global_basis = Basis((sa[j]["rot"] as Quaternion).slerp(sb[j]["rot"] as Quaternion, t))
