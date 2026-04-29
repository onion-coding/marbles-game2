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
# Once true, the EVENT_FINISH_CROSS flag has already been observed and the
# WinnerReveal effect has fired — don't re-fire it on subsequent flagged
# frames (e.g. if multiple marbles cross during the race tail).
var _winner_revealed := false

# Track set by the caller for race-aware features (lead glow). Optional —
# if null, lead glow is skipped and marbles render with their default
# emission energy.
var _track: Track = null
var _current_leader_idx: int = -1
const LEAD_GLOW_BASE := 0.45
const LEAD_GLOW_BOOST := 1.10

signal playback_finished(last_tick: int, first_marble_pos: Vector3)
# Emitted every frame the cursor advances into a new tick — HUDs / overlays
# use this to drive a race timer without re-implementing the lerp math.
signal tick_advanced(tick: int)
# Emitted once when EVENT_FINISH_CROSS first appears in a frame's flags;
# carries the marble-index that crossed and its color so HUD modals can
# display the winner without re-deriving the data.
signal winner_revealed(marble_index: int, marble_name: String, color: Color)

func set_track(track: Track) -> void:
	_track = track

# Returns the current array of visual marble nodes so callers (e.g. HUD) can
# read their world positions for live standings. Read-only intent — callers
# must not free or reparent these nodes.
func get_marbles() -> Array[Node3D]:
	return _marbles

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
		var color: Color
		if rgba == 0:
			# Deterministic fallback color by header index so M1/M2 look roughly alike.
			color = Color.from_hsv(float(_marbles.size()) / max(_header.size(), 1), 0.8, 0.95)
		else:
			color = Color(((rgba >> 24) & 0xFF) / 255.0, ((rgba >> 16) & 0xFF) / 255.0, ((rgba >> 8) & 0xFF) / 255.0, (rgba & 0xFF) / 255.0)
		# PBR + emission to match the sim-side marble look (M7.0).
		mat.albedo_color = color
		mat.metallic = 0.30
		mat.metallic_specular = 0.6
		mat.roughness = 0.18
		mat.emission_enabled = true
		mat.emission = color
		mat.emission_energy_multiplier = 0.45
		node.material_override = mat
		node.add_to_group("marbles")
		add_child(node)
		MarbleSpawner.attach_trail(node, color)
		MarbleSpawner.attach_number_label(node, _marbles.size())
		# Per-marble name labels are intentionally not attached: 20 of them
		# clustered at spawn made the screen unreadable. Names live in the
		# HUD's marble list. A future "leader badge" can opt back in for
		# the single leading marble via MarbleSpawner.attach_name_label.
		_marbles.append(node)

func _process(delta: float) -> void:
	if _finished or _frames.is_empty():
		return
	_elapsed_ticks += delta * _tick_rate
	var idx_f: float = min(_elapsed_ticks, float(_frames.size() - 1))
	var i := int(idx_f)
	var t := idx_f - float(i)
	# Drive the HUD timer once per advancing tick.
	if i < _frames.size():
		tick_advanced.emit(int(_frames[i]["tick"]))
	# Trigger WinnerReveal the first time we see EVENT_FINISH_CROSS (1 << 0)
	# in a frame's flags. The recorder sets that bit on the tick a marble
	# crossed the finish, so this fires once at the climax of the race.
	if not _winner_revealed and i < _frames.size():
		var f: Dictionary = _frames[i]
		var flags: int = int(f.get("flags", 0))
		if (flags & 1) != 0:
			_fire_winner_reveal(f)
	if i + 1 < _frames.size():
		_apply_interpolated(_frames[i], _frames[i + 1], t)
	else:
		# Tail of the buffer. In file-playback this is end-of-race; in streaming
		# it's just "next frame hasn't arrived yet" — hold unless DONE was signaled.
		_apply_frame_state(_frames[i])
	# Lead-glow refresh — runs once per cursor advance, after marble positions
	# are set above. Skipped after the winner reveal fires (the winner's boost
	# tween there shouldn't be overwritten by the lead glow).
	if _track != null and not _winner_revealed:
		_update_lead_glow()
	# Tail-of-buffer end-of-race handling.
	if i + 1 >= _frames.size() and (not _streaming or _stream_done):
		_finished = true
		var last: Dictionary = _frames[_frames.size() - 1]
		playback_finished.emit(int(last["tick"]), (last["states"][0]["pos"] as Vector3))

func _fire_winner_reveal(frame: Dictionary) -> void:
	# Identify the "winner": the recorded frame doesn't tag which marble
	# crossed, but the winner is by definition the marble whose position is
	# closest to the finish-area trigger. Without easy access to the track's
	# finish_area_transform here, we approximate by picking the marble whose
	# delta-from-previous-frame is largest along its motion direction — that
	# marble is the one most actively crossing the finish-line area on this
	# tick. Cheap and visually believable.
	_winner_revealed = true
	var states: Array = frame["states"]
	if states.is_empty():
		return
	var winner_idx := 0
	# Header carries the rgba; pick the first marble's position as fallback
	# anchor if we can't compute deltas (e.g. first frame).
	var winner_pos: Vector3 = states[0]["pos"] as Vector3
	# Use the previous frame to compute per-marble velocity and pick the fastest.
	var prev_idx := _frames.find(frame) - 1
	if prev_idx >= 0:
		var prev_states: Array = _frames[prev_idx]["states"]
		var best_speed := -1.0
		for j in range(min(states.size(), prev_states.size())):
			var d := (states[j]["pos"] as Vector3) - (prev_states[j]["pos"] as Vector3)
			if d.length() > best_speed:
				best_speed = d.length()
				winner_idx = j
				winner_pos = states[j]["pos"]
	var rgba: int = int(_header[winner_idx]["rgba"])
	var color: Color
	if rgba == 0:
		color = Color(1.0, 0.85, 0.20)
	else:
		color = Color(((rgba >> 24) & 0xFF) / 255.0, ((rgba >> 16) & 0xFF) / 255.0, ((rgba >> 8) & 0xFF) / 255.0, 1.0)
	WinnerReveal.spawn_confetti(self, winner_pos, color)
	if winner_idx < _marbles.size():
		WinnerReveal.boost_winner_emission(_marbles[winner_idx], get_tree())
	winner_revealed.emit(winner_idx, String(_header[winner_idx].get("name", "")), color)

func _update_lead_glow() -> void:
	# The "leader" is the marble whose centre is closest to the finish-line
	# trigger. We refresh every frame; track changes are cheap because we
	# only touch the swap-out and swap-in marble's emission energy.
	var finish_pos: Vector3 = _track.finish_area_transform().origin
	var best_idx := -1
	var best_dist := INF
	for j in range(_marbles.size()):
		var d2: float = (_marbles[j].global_position - finish_pos).length_squared()
		if d2 < best_dist:
			best_dist = d2
			best_idx = j
	if best_idx == _current_leader_idx or best_idx < 0:
		return
	_set_marble_emission(_current_leader_idx, LEAD_GLOW_BASE)
	_set_marble_emission(best_idx, LEAD_GLOW_BOOST)
	_current_leader_idx = best_idx

func _set_marble_emission(idx: int, energy: float) -> void:
	if idx < 0 or idx >= _marbles.size():
		return
	var node: Node3D = _marbles[idx]
	var mat: StandardMaterial3D = null
	if node is MeshInstance3D:
		mat = (node as MeshInstance3D).material_override as StandardMaterial3D
	if mat != null:
		mat.emission_energy_multiplier = energy

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
