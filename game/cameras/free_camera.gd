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
	_min_dist = max(2.0, _distance * 0.2)
	_max_dist = _distance * 3.0 + 20.0
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
	# R — reset
	if e.pressed and e.keycode == KEY_R:
		_reset()
		return
	# Movement keys: update the continuous _move_input vector.
	# The vector is rebuilt from the set of currently-pressed keys so that
	# releasing one key while another is held correctly reverts the axis.
	var sign: float = 1.0 if e.pressed else -1.0
	match e.keycode:
		KEY_W, KEY_UP:
			_move_input.z += sign         # forward
		KEY_S, KEY_DOWN:
			_move_input.z -= sign         # backward
		KEY_A, KEY_LEFT:
			_move_input.x -= sign         # strafe left
		KEY_D, KEY_RIGHT:
			_move_input.x += sign         # strafe right
		KEY_Q:
			_move_input.y -= sign         # descend
		KEY_E:
			_move_input.y += sign         # ascend
	# Clamp each axis to [-1, 1] in case of double-press (two keys same axis).
	_move_input = _move_input.clamp(Vector3(-1.0, -1.0, -1.0), Vector3(1.0, 1.0, 1.0))

func _process(delta: float) -> void:
	if _move_input == Vector3.ZERO:
		return
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

func _reset() -> void:
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
