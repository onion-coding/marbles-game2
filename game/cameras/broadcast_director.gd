class_name BroadcastDirector
extends Node3D

# Broadcast-style camera director — replaces the single FreeCamera with
# automatic cuts between three angles, mimicking a live F1/NBA broadcast.
#
# Cameras managed:
#   STADIUM_WIDE       — fixed overhead/lateral view framing the full track.
#   LEADER_FOLLOW      — smooth dolly locked to the current race leader.
#   FINISH_LINE_LOWANGLE — low ground-level shot aimed at the finish line,
#                         activated when the leading marble is within 8 m.
#
# Cut logic:
#   t=0            → STADIUM_WIDE
#   t=5 s          → LEADER_FOLLOW
#   every 8–12 s   → toggle LEADER_FOLLOW ↔ STADIUM_WIDE
#                    (interval drawn from _hash_with_tag per cut index,
#                    so timing is deterministic per round seed but looks
#                    random to the viewer)
#   leader < 8 m   → FINISH_LINE_LOWANGLE (stays until race_finished)
#
# Modes accessible via set_mode():
#   "auto"          — run the cut schedule (default on start_directing)
#   "wide"          — lock to STADIUM_WIDE
#   "leader"        — lock to LEADER_FOLLOW
#   "finish_line"   — lock to FINISH_LINE_LOWANGLE
#   "free"          — hand control back to the embedded FreeCamera
#
# Fade transitions: 200 ms cubic ease-in fade-to-black, swap camera,
# 200 ms cubic ease-out fade-from-black, implemented via a full-screen
# ColorRect on a dedicated CanvasLayer (layer 20 so it sits above the HUD).
#
# Headless guard: setup() returns immediately when
# DisplayServer.get_name() == "headless" so the director is a no-op in
# spec / CI runs without touching the physics sim.

# ─── Public API ──────────────────────────────────────────────────────────────

func setup(p_track: Track, p_marbles: Array, p_finish_pos: Vector3) -> void:
	if DisplayServer.get_name() == "headless":
		return
	_track       = p_track
	_marbles     = p_marbles
	_finish_pos  = p_finish_pos

	_build_cameras()
	_build_fade_overlay()

func start_directing() -> void:
	if DisplayServer.get_name() == "headless":
		return
	_directing    = true
	_race_finished = false
	_elapsed      = 0.0
	_cut_index    = 0
	_finish_locked = false
	_set_active_camera(_cam_wide)
	_current_mode = MODE_AUTO
	_schedule_next_cut()

func stop_directing() -> void:
	_directing = false

func set_mode(mode: String) -> void:
	if DisplayServer.get_name() == "headless":
		return
	match mode:
		"auto":
			_current_mode = MODE_AUTO
			if not _directing:
				start_directing()
		"wide":
			_current_mode = MODE_WIDE
			_do_cut(_cam_wide)
		"leader":
			_current_mode = MODE_LEADER
			_do_cut(_cam_leader)
		"finish_line":
			_current_mode = MODE_FINISH
			_do_cut(_cam_finish)
		"free":
			_current_mode = MODE_FREE
			_do_cut(_freecam)
		_:
			push_warning("BroadcastDirector.set_mode: unknown mode '%s'" % mode)

# Expose the embedded FreeCamera so main.gd can connect HUD marble_selected.
var freecam: FreeCamera:
	get: return _freecam

# Notify the director that the race has ended so it freezes on the current
# camera (usually FINISH_LINE_LOWANGLE).
func notify_race_finished() -> void:
	_race_finished = true
	_directing = false

# ─── Constants ───────────────────────────────────────────────────────────────

const MODE_AUTO   := "auto"
const MODE_WIDE   := "wide"
const MODE_LEADER := "leader"
const MODE_FINISH := "finish_line"
const MODE_FREE   := "free"

# After this many seconds from race start, cut from WIDE to LEADER.
const INITIAL_WIDE_SEC := 5.0
# When the leader is within this distance of the finish, cut to FINISH.
const FINISH_TRIGGER_M := 8.0
# Camera dolly smoothing factor (lerp alpha per second).
const LEADER_LERP_SPEED := 4.0
# Dolly offset behind + above the leader marble.
const LEADER_OFFSET_BACK := 5.0   # metres behind (along world -Z when marble's forward ≈ -Z)
const LEADER_OFFSET_UP   := 2.0   # metres above
# Fade duration for each half of a cut (fade-in + fade-out).
const FADE_HALF_SEC := 0.2

# ─── Private state ───────────────────────────────────────────────────────────

var _track:       Track    = null
var _marbles:     Array    = []
var _finish_pos:  Vector3  = Vector3.ZERO

# Sub-cameras (Camera3D nodes added as children).
var _cam_wide:   Camera3D = null
var _cam_leader: Camera3D = null
var _cam_finish: Camera3D = null
var _freecam:    FreeCamera = null

# Current active Camera3D (or FreeCamera).
var _active_cam: Camera3D = null

# Director state.
var _directing:     bool   = false
var _race_finished: bool   = false
var _finish_locked: bool   = false   # true once FINISH camera is locked
var _elapsed:       float  = 0.0
var _cut_index:     int    = 0
var _next_cut_at:   float  = -1.0    # absolute elapsed seconds for next auto-cut
var _current_mode:  String = MODE_AUTO

# Cut-interval hash bytes — generated at start_directing() from the track seed.
# Each 2-byte pair gives an interval in [8, 12] seconds.
var _cut_intervals: Array = []

# Fade overlay.
var _fade_layer: CanvasLayer = null
var _fade_rect:  ColorRect   = null
var _fade_tween: Tween       = null
var _pending_cam_after_fade: Camera3D = null

# ─── Lifecycle ───────────────────────────────────────────────────────────────

func _process(delta: float) -> void:
	if not _directing:
		return
	_elapsed += delta
	_tick_leader_follow(delta)
	_tick_finish_trigger()
	_tick_auto_cuts()

# ─── Camera building ─────────────────────────────────────────────────────────

func _build_cameras() -> void:
	var bb: AABB = _track.camera_bounds()

	# ── STADIUM_WIDE ────────────────────────────────────────────────────────
	_cam_wide = Camera3D.new()
	_cam_wide.name = "CamWide"
	_cam_wide.fov  = 60.0
	_place_wide_camera(_cam_wide, bb)
	add_child(_cam_wide)

	# ── LEADER_FOLLOW ───────────────────────────────────────────────────────
	_cam_leader = Camera3D.new()
	_cam_leader.name = "CamLeader"
	_cam_leader.fov  = 55.0
	# Initial position equals wide; will be moved every frame.
	_cam_leader.global_position = _cam_wide.global_position
	_cam_leader.look_at(bb.get_center(), Vector3.UP)
	add_child(_cam_leader)

	# ── FINISH_LINE_LOWANGLE ─────────────────────────────────────────────────
	_cam_finish = Camera3D.new()
	_cam_finish.name = "CamFinish"
	_cam_finish.fov  = 50.0
	_place_finish_camera(_cam_finish)
	add_child(_cam_finish)

	# ── FREECAM (fallback "free" mode) ──────────────────────────────────────
	_freecam = FreeCamera.new()
	_freecam.name = "CamFree"
	_freecam.track = _track
	add_child(_freecam)

	# Start with no camera current; _set_active_camera activates one.
	for cam in [_cam_wide, _cam_leader, _cam_finish, _freecam]:
		cam.current = false

# Position the wide camera: back and above the track AABB, framing the full
# extent, modelled after FixedCamera's FOV-fit math plus a lateral bias so
# the shot reads like a broadcast "stadium" angle instead of a top-down.
func _place_wide_camera(cam: Camera3D, bb: AABB) -> void:
	var center := bb.get_center()
	var extent := bb.size
	var aspect := 16.0 / 9.0
	var dist_v: float = (extent.y * 0.5) / tan(deg_to_rad(cam.fov * 0.5))
	var dist_h: float = (maxf(extent.x, extent.z) * 0.5) / (tan(deg_to_rad(cam.fov * 0.5)) * aspect)
	var dist: float   = maxf(dist_v, dist_h) * 1.15 + 5.0

	# Lateral+elevation offset: 30° pitch down, side offset = 15% of X extent.
	var pitch_rad := deg_to_rad(30.0)
	var side_bias := extent.x * 0.15
	cam.global_position = center + Vector3(
		side_bias,
		dist * sin(pitch_rad),
		dist * cos(pitch_rad)
	)
	cam.look_at(center, Vector3.UP)

# Position the finish-line low-angle camera: ground level to the side of the
# finish area, looking across the line from a "grandstand" perspective.
func _place_finish_camera(cam: Camera3D) -> void:
	var ft := _track.finish_area_transform()
	var finish_center := ft.origin

	# Lateral offset ~8 m to the right (finish line's local X) and lifted 1 m.
	var right := ft.basis.x.normalized()
	var cam_pos := finish_center + right * 8.0 + Vector3(0.0, 1.2, 0.0)
	cam.global_position = cam_pos

	# Aim toward the approach side: look slightly behind the finish line so
	# incoming marbles cross screen left-to-right.
	var look_target := finish_center - ft.basis.z.normalized() * 6.0
	look_target.y = finish_center.y + 0.3  # slight upward look
	cam.look_at(look_target, Vector3.UP)

# ─── Fade overlay ────────────────────────────────────────────────────────────

func _build_fade_overlay() -> void:
	_fade_layer       = CanvasLayer.new()
	_fade_layer.layer = 20   # above HUD at layer 10
	add_child(_fade_layer)

	_fade_rect = ColorRect.new()
	_fade_rect.color        = Color(0.0, 0.0, 0.0, 0.0)
	_fade_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_fade_rect.set_anchors_preset(Control.PRESET_FULL_RECT)
	_fade_layer.add_child(_fade_rect)

# ─── Cut scheduling ───────────────────────────────────────────────────────────

# Pre-compute enough cut intervals from the track seed.
func _schedule_next_cut() -> void:
	if _cut_intervals.is_empty():
		_precompute_cut_intervals(32)
	# First cut: switch from WIDE to LEADER after INITIAL_WIDE_SEC.
	_next_cut_at = _elapsed + INITIAL_WIDE_SEC

# Derive a deterministic sequence of cut intervals from the server seed
# (via Track._hash_with_tag). Falls back to pseudo-random if track has no seed.
func _precompute_cut_intervals(count: int) -> void:
	_cut_intervals.clear()
	for i in range(count):
		# Use two bytes of the hash to pick an interval in [8.0, 12.0].
		var raw_bytes: PackedByteArray = _track._hash_with_tag("cam_cut_%d" % i)
		var b0: int = int(raw_bytes[0]) if raw_bytes.size() > 0 else i * 37
		var b1: int = int(raw_bytes[1]) if raw_bytes.size() > 1 else i * 53
		var combined: int = (b0 << 8) | b1
		var t: float = 8.0 + float(combined % 4097) / 4096.0 * 4.0   # [8, 12]
		_cut_intervals.append(t)

func _tick_auto_cuts() -> void:
	if _current_mode != MODE_AUTO:
		return
	if _finish_locked:
		return
	if _next_cut_at < 0.0:
		return
	if _elapsed < _next_cut_at:
		return

	# Decide which camera to cut to.
	var target_cam: Camera3D
	if _cut_index == 0:
		# First scheduled cut: wide → leader.
		target_cam = _cam_leader
	else:
		# Subsequent cuts: toggle leader ↔ wide.
		if _active_cam == _cam_leader or _active_cam == _freecam:
			target_cam = _cam_wide
		else:
			target_cam = _cam_leader

	_do_cut(target_cam)
	_cut_index += 1

	# Schedule the next cut.
	var idx := _cut_index % _cut_intervals.size()
	_next_cut_at = _elapsed + float(_cut_intervals[idx])

# ─── Finish trigger ──────────────────────────────────────────────────────────

func _tick_finish_trigger() -> void:
	if _finish_locked:
		return
	if _current_mode != MODE_AUTO:
		return
	var leader := _find_leader()
	if leader == null:
		return
	var dist := leader.global_position.distance_to(_finish_pos)
	if dist <= FINISH_TRIGGER_M:
		_finish_locked = true
		_do_cut(_cam_finish)

# ─── Leader follow ────────────────────────────────────────────────────────────

func _tick_leader_follow(delta: float) -> void:
	if _active_cam != _cam_leader:
		return
	var leader := _find_leader()
	if leader == null:
		return

	# Target position: behind leader along world -Z, elevated.
	# We use the marble's velocity direction if available, otherwise fall back
	# to world -Z, so the camera stays "behind" the marble's travel direction.
	var marble_body := leader as RigidBody3D
	var forward := Vector3(0.0, 0.0, -1.0)
	if marble_body != null and marble_body.linear_velocity.length_squared() > 0.01:
		forward = marble_body.linear_velocity.normalized()

	var target_pos := leader.global_position \
		- forward * LEADER_OFFSET_BACK \
		+ Vector3(0.0, LEADER_OFFSET_UP, 0.0)

	_cam_leader.global_position = _cam_leader.global_position.lerp(
		target_pos, delta * LEADER_LERP_SPEED
	)
	_cam_leader.look_at(leader.global_position, Vector3.UP)

# Return the marble closest to the finish line (minimum distance = leader).
func _find_leader() -> Node3D:
	var best_dist := INF
	var best_node: Node3D = null
	for m in _marbles:
		var node := m as Node3D
		if node == null or not is_instance_valid(node):
			continue
		var d := node.global_position.distance_to(_finish_pos)
		if d < best_dist:
			best_dist = d
			best_node = node
	return best_node

# ─── Camera activation ───────────────────────────────────────────────────────

func _set_active_camera(cam: Camera3D) -> void:
	if _active_cam != null:
		_active_cam.current = false
	_active_cam = cam
	if cam != null:
		cam.current = true

# Perform a cut with a 200 ms fade-to-black / swap / fade-from-black.
func _do_cut(target_cam: Camera3D) -> void:
	if target_cam == null or target_cam == _active_cam:
		return
	if _fade_tween != null and _fade_tween.is_valid():
		_fade_tween.kill()

	_pending_cam_after_fade = target_cam
	_fade_tween = create_tween()

	# Fade to black (cubic ease-in).
	_fade_tween.tween_property(_fade_rect, "color",
		Color(0.0, 0.0, 0.0, 1.0), FADE_HALF_SEC
	).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_IN)

	# Swap camera at the dark frame.
	_fade_tween.tween_callback(_apply_pending_cut)

	# Fade from black (cubic ease-out).
	_fade_tween.tween_property(_fade_rect, "color",
		Color(0.0, 0.0, 0.0, 0.0), FADE_HALF_SEC
	).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)

func _apply_pending_cut() -> void:
	_set_active_camera(_pending_cam_after_fade)
	_pending_cam_after_fade = null
