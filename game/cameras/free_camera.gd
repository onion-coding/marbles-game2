class_name FreeCamera
extends Camera3D

# Per-player free camera: orbit + zoom around the track center.
# Used by the Web client (web_main.gd, live_main.gd) so each viewer can
# pick their own angle. Sim and disk-playback scenes keep FixedCamera —
# that's the "headless / cinematic" path.
#
# Controls:
#   Left mouse drag      — orbit (yaw + pitch)
#   Mouse wheel          — zoom in/out (dolly along view direction)
#   Right mouse drag     — pan target laterally inside camera_bounds
#   R                    — reset to the default fixed-camera framing
#   W / Up arrow         — move target forward (along camera look direction)
#   S / Down arrow       — move target backward
#   A / Left arrow       — strafe target left
#   D / Right arrow      — strafe target right
#   Q                    — move target down (world Y)
#   E                    — move target up (world Y)
#   Shift (held)         — multiply movement speed × 3
#
# All input handlers are no-ops on headless platforms (no input device), so
# this camera works for both interactive and CI export-test runs.

# Set by the caller before add_child. The camera frames whatever track it's
# handed, so new tracks don't need a bespoke camera each.
var track: Track

# Orbit state. Pitch is the elevation angle of the camera above the target's
# horizontal plane: pitch > 0 → camera is above the target → looks down.
var _target: Vector3 = Vector3.ZERO
var _yaw: float = 0.0          # radians, around world Y
var _pitch: float = 0.4        # radians, ~23° above horizon by default
var _distance: float = 30.0

# Bounds derived from the track's camera_bounds AABB so users can't pan into
# infinity or zoom out past the track's reasonable framing.
var _bb: AABB = AABB()
var _min_dist: float = 5.0
var _max_dist: float = 120.0

# Default reset state, captured at _ready time so R always returns to it.
var _default_target: Vector3 = Vector3.ZERO
var _default_yaw: float = 0.0
var _default_pitch: float = 0.4
var _default_distance: float = 30.0

# Drag state
var _orbit_dragging: bool = false
var _pan_dragging: bool = false

# Keyboard movement state — accumulated in _input, consumed in _process.
# Axes: x = strafe right, y = elevate up, z = forward (camera look).
var _move_input: Vector3 = Vector3.ZERO

# Follow-marble state. When non-null, _process smoothly steers _target toward
# the marble's world position each frame. Keys 0-9 → marbles 0-9; Shift+0-9
# → marbles 10-19. F or Esc releases the lock; R also releases and resets.
# The camera orbit (yaw/pitch/distance) is unaffected — the user can still
# drag to change viewing angle while following.
# This state is per-viewer and never recorded or broadcast.
var _follow_marble: Node3D = null

const ORBIT_SENSITIVITY := 0.005      # rad/pixel
const PAN_SENSITIVITY := 0.05         # m/pixel (scaled by current distance)
const ZOOM_STEP := 1.10               # multiplicative per wheel notch
const PITCH_LIMIT := 1.45             # ±~83° to avoid gimbal lock
const MOVE_SPEED := 10.0              # m/s at distance == 1; scaled by _distance
const MOVE_SHIFT_MULT := 3.0          # speed multiplier when Shift is held

func _ready() -> void:
	current = true
	fov = 60.0
	_bb = track.camera_bounds()
	_target = _bb.get_center()

	# Tracks may supply an explicit camera_pose() override; convert it to
	# (target, yaw, pitch, distance) so the orbit controls still work
	# from a sensible starting view.
	var pose: Dictionary = track.camera_pose()
	if not pose.is_empty():
		var p: Vector3 = pose.get("position", Vector3.ZERO) as Vector3
		var t: Vector3 = pose.get("target", Vector3.ZERO) as Vector3
		if pose.has("fov"):
			fov = float(pose["fov"])
		_target = t
		var offset := p - t
		_distance = offset.length()
		var horiz: float = sqrt(offset.x * offset.x + offset.z * offset.z)
		_yaw = atan2(offset.x, offset.z)
		_pitch = atan2(offset.y, horiz)
	else:
		# Default: AABB-fit FOV-aware framing — match FixedCamera's logic.
		var extent := _bb.size
		var aspect := 16.0 / 9.0
		var dist_v: float = (extent.y * 0.5) / 0.577
		var dist_h: float = (maxf(extent.x, extent.z) * 0.5) / (0.577 * aspect)
		_distance = maxf(dist_v, dist_h) * 1.10 + 4.0
	_min_dist = 0.5
	_max_dist = 500.0
	_default_target = _target
	_default_yaw = _yaw
	_default_pitch = _pitch
	_default_distance = _distance
	_apply_pose()

func _input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		_handle_mouse_button(event)
	elif event is InputEventMouseMotion:
		_handle_mouse_motion(event)
	elif event is InputEventKey:
		_handle_key(event)

func _handle_mouse_button(e: InputEventMouseButton) -> void:
	match e.button_index:
		MOUSE_BUTTON_LEFT:
			_orbit_dragging = e.pressed
		MOUSE_BUTTON_RIGHT:
			_pan_dragging = e.pressed
		MOUSE_BUTTON_WHEEL_UP:
			if e.pressed:
				_distance = clampf(_distance / ZOOM_STEP, _min_dist, _max_dist)
				_apply_pose()
		MOUSE_BUTTON_WHEEL_DOWN:
			if e.pressed:
				_distance = clampf(_distance * ZOOM_STEP, _min_dist, _max_dist)
				_apply_pose()

func _handle_mouse_motion(e: InputEventMouseMotion) -> void:
	if _orbit_dragging:
		_yaw -= e.relative.x * ORBIT_SENSITIVITY
		_pitch = clampf(_pitch - e.relative.y * ORBIT_SENSITIVITY, -PITCH_LIMIT, PITCH_LIMIT)
		_apply_pose()
	elif _pan_dragging:
		# Pan in the camera's local plane — right * dx + up * dy, scaled by
		# distance so far-away pans don't feel slow.
		var scale: float = _distance * PAN_SENSITIVITY * 0.05
		var right := global_transform.basis.x
		var up := global_transform.basis.y
		_target -= right * (e.relative.x * scale)
		_target += up * (e.relative.y * scale)
		# Keep target inside the AABB.
		_target.x = clampf(_target.x, _bb.position.x, _bb.position.x + _bb.size.x)
		_target.y = clampf(_target.y, _bb.position.y, _bb.position.y + _bb.size.y)
		_target.z = clampf(_target.z, _bb.position.z, _bb.position.z + _bb.size.z)
		_apply_pose()

func _handle_key(e: InputEventKey) -> void:
	if not e.pressed:
		# Key-release: only update movement axes below; follow/reset are press-only.
		var sign: float = -1.0
		match e.keycode:
			KEY_W, KEY_UP:   _move_input.z += sign
			KEY_S, KEY_DOWN: _move_input.z -= sign
			KEY_A, KEY_LEFT: _move_input.x -= sign
			KEY_D, KEY_RIGHT: _move_input.x += sign
			KEY_Q:           _move_input.y -= sign
			KEY_E:           _move_input.y += sign
		_move_input = _move_input.clamp(Vector3(-1.0, -1.0, -1.0), Vector3(1.0, 1.0, 1.0))
		return

	# R — reset (also releases follow).
	if e.keycode == KEY_R:
		_follow_marble = null
		_reset()
		return

	# F / Esc — release follow lock.
	if e.keycode == KEY_F or e.keycode == KEY_ESCAPE:
		_follow_marble = null
		return

	# Digit keys 0-9: follow marble by index (Shift held → add 10).
	var digit := _digit_from_keycode(e.keycode)
	if digit >= 0:
		var idx: int = digit + (10 if e.shift_pressed else 0)
		_follow_marble = _find_marble_by_index(idx)
		return

	# Movement keys: update the continuous _move_input vector.
	# The vector is rebuilt from the set of currently-pressed keys so that
	# releasing one key while another is held correctly reverts the axis.
	var sign: float = 1.0
	match e.keycode:
		KEY_W, KEY_UP:   _move_input.z += sign
		KEY_S, KEY_DOWN: _move_input.z -= sign
		KEY_A, KEY_LEFT: _move_input.x -= sign
		KEY_D, KEY_RIGHT: _move_input.x += sign
		KEY_Q:           _move_input.y -= sign
		KEY_E:           _move_input.y += sign
	# Clamp each axis to [-1, 1] in case of double-press (two keys same axis).
	_move_input = _move_input.clamp(Vector3(-1.0, -1.0, -1.0), Vector3(1.0, 1.0, 1.0))

# Returns 0-9 for KEY_0-KEY_9 (both main row and numpad), -1 otherwise.
func _digit_from_keycode(kc: Key) -> int:
	match kc:
		KEY_0, KEY_KP_0: return 0
		KEY_1, KEY_KP_1: return 1
		KEY_2, KEY_KP_2: return 2
		KEY_3, KEY_KP_3: return 3
		KEY_4, KEY_KP_4: return 4
		KEY_5, KEY_KP_5: return 5
		KEY_6, KEY_KP_6: return 6
		KEY_7, KEY_KP_7: return 7
		KEY_8, KEY_KP_8: return 8
		KEY_9, KEY_KP_9: return 9
	return -1

# Returns the marble at the given drop-order index from the "marbles" group,
# or null if none is registered yet. Marbles are named "Marble_00", "Marble_01"
# etc. so we sort by name to get a deterministic order.
func _find_marble_by_index(idx: int) -> Node3D:
	var nodes := get_tree().get_nodes_in_group("marbles")
	if nodes.is_empty():
		return null
	# Sort by node name for stable ordering regardless of add_child order.
	nodes.sort_custom(func(a: Node, b: Node) -> bool:
		return a.name < b.name
	)
	if idx < 0 or idx >= nodes.size():
		return null
	return nodes[idx] as Node3D

func _process(delta: float) -> void:
	# WASD / arrow key movement (skipped when follow is active to avoid fighting).
	if _move_input != Vector3.ZERO and _follow_marble == null:
		# Speed scales with distance so far-away views feel responsive.
		var shift: bool = Input.is_key_pressed(KEY_SHIFT)
		var speed: float = MOVE_SPEED * _distance * delta * (MOVE_SHIFT_MULT if shift else 1.0)
		# Decompose movement into world-space using the camera basis.
		# Forward is projected onto the horizontal plane so W/S doesn't dive/climb
		# with pitch — only Q/E changes world Y.
		var cam_basis: Basis = global_transform.basis
		var right: Vector3 = cam_basis.x                          # world right
		var look_h: Vector3 = Vector3(-cam_basis.z.x, 0.0, -cam_basis.z.z).normalized()  # horizontal forward
		_target += right * (_move_input.x * speed)
		_target += look_h * (_move_input.z * speed)
		_target.y += _move_input.y * speed
		# Re-apply AABB clamp (same as pan handler).
		_target.x = clampf(_target.x, _bb.position.x, _bb.position.x + _bb.size.x)
		_target.y = clampf(_target.y, _bb.position.y, _bb.position.y + _bb.size.y)
		_target.z = clampf(_target.z, _bb.position.z, _bb.position.z + _bb.size.z)
		_apply_pose()

	# Follow-marble mode: smoothly steer _target toward the marble each frame.
	# AABB clamp is intentionally skipped here so the camera can track a marble
	# that exits the default framing box (e.g. very long drops on Plinko).
	# The marble will always be visible; the pan clamp would fight the follow.
	if _follow_marble != null:
		if not is_instance_valid(_follow_marble):
			# Marble was freed (round ended); release follow gracefully.
			_follow_marble = null
		else:
			_target = _target.lerp(_follow_marble.global_position, 0.15)
			_apply_pose()

func _reset() -> void:
	_follow_marble = null
	_target = _default_target
	_yaw = _default_yaw
	_pitch = _default_pitch
	_distance = _default_distance
	_apply_pose()

func _apply_pose() -> void:
	# Camera orbit position around _target, in spherical coords (yaw, pitch,
	# distance) with world-Y up. pitch > 0 = camera above target = looks down.
	var cos_p: float = cos(_pitch)
	var offset := Vector3(
		_distance * cos_p * sin(_yaw),
		_distance * sin(_pitch),
		_distance * cos_p * cos(_yaw),
	)
	global_position = _target + offset
	look_at(_target, Vector3.UP)
