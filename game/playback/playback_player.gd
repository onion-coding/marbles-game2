class_name PlaybackPlayer
extends Node3D

const MARBLE_RADIUS := 0.3

var _frames: Array = []
var _header: Array = []
var _tick_rate: float = 60.0
var _marbles: Array[Node3D] = []
var _elapsed_ticks: float = 0.0
var _finished := false

signal playback_finished(last_tick: int, first_marble_pos: Vector3)

func load_replay(replay: Dictionary) -> void:
	_header = replay["header"]
	_frames = replay["frames"]
	_tick_rate = float(replay["tick_rate_hz"])
	_build_marbles()
	# Snap to the first recorded frame so the scene is valid before playback starts.
	_apply_frame_state(_frames[0])

func _build_marbles() -> void:
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
		_apply_frame_state(_frames[i])
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
