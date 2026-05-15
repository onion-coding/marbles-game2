class_name FreeCamera
extends Camera3D

# Emitted whenever the followed marble changes. idx == -1 means no marble is
# being followed (released via F, Esc, R, or the marble was freed). HUD
# listens to this to update its "eye" marker in the standings list.
signal following_changed(idx: int)

# Per-viewer free camera. Two modes blend into a single control surface
# inspired by Godot / Unity / Unreal editor cameras:
#
# Casual / orbit mode (default — Left mouse + wheel)
#   Left mouse drag       — orbit yaw + pitch around the target
#   Middle mouse drag     — pan target in the camera's local plane
#   Mouse wheel           — zoom (dolly along view direction)
#   W/A/S/D (or arrows)   — move the orbit target (horizontal-only forward,
#                           so the framing stays level)
#   Q / E                 — move target down / up (world Y)
#   Shift held            — × 3 movement / zoom speed
#   Ctrl  held            — × 0.25 speed for precision adjustments
#   R                     — reset camera + release follow
#   F / Esc               — release follow
#   0-9 / Shift+0-9       — follow marble 0-9 / 10-19
#
# Fly mode (FPS-style — Right mouse hold)
#   Right mouse HELD      — capture mouse, free-look (yaw/pitch around camera
#                           itself); cursor is hidden and the eye direction
#                           is controlled directly. Release to return cursor.
#   W/A/S/D while held    — fly camera forward / back / strafe ALONG view dir
#   Q / E while held      — fly down / up (world Y)
#   Wheel while held      — change fly speed (multiplicative)
#   Shift / Ctrl          — × 3 / × 0.25 speed multipliers (same as orbit)
#
# All input handlers are no-ops on headless platforms (no input device).

# Set by the caller before add_child. The camera frames whatever track it's
# handed, so new tracks don't need a bespoke camera each.
var track: Track

# Orbit state. Pitch is the elevation angle of the camera above the target's
# horizontal plane: pitch > 0 → camera is above the target → looks down.
var _target: Vector3 = Vector3.ZERO
var _yaw: float = 0.0          # radians, around world Y
var _pitch: float = 0.4        # radians, ~23° above horizon by default
var _distance: float = 30.0

# Bounds used for the initial AABB-fit framing only. We DO NOT clamp the
# target inside this AABB any more — the user explicitly asked to "go
# anywhere". The bounds inform _min_dist / _max_dist defaults and the reset.
var _bb: AABB = AABB()
var _min_dist: float = 0.05
var _max_dist: float = 1000.0

# Default reset state, captured at _ready time so R always returns to it.
var _default_target: Vector3 = Vector3.ZERO
var _default_yaw: float = 0.0
var _default_pitch: float = 0.4
var _default_distance: float = 30.0

# Drag state
var _orbit_dragging: bool = false   # left mouse: orbit
var _pan_dragging:   bool = false   # middle mouse: pan
var _fly_dragging:   bool = false   # right mouse: FPS look + fly

# Keyboard movement state — accumulated in _input, consumed in _process.
# Axes: x = strafe right, y = elevate up, z = forward (camera look).
var _move_input: Vector3 = Vector3.ZERO

# Fly speed (modifiable via wheel while right-held). Persists across drags.
var _fly_speed: float = 12.0

# Follow-marble state.
var _follow_marble: Node3D = null

const ORBIT_SENSITIVITY := 0.005      # rad/pixel for left-drag orbit
const LOOK_SENSITIVITY  := 0.0035     # rad/pixel for right-drag FPS look (a touch slower for accuracy)
const PAN_SENSITIVITY   := 0.05       # m/pixel (scaled by current distance)
const ZOOM_STEP         := 1.10       # multiplicative per wheel notch
const PITCH_LIMIT       := 1.45       # ±~83° to avoid gimbal lock
const MOVE_SPEED        := 10.0       # m/s for orbit-mode target movement
const FLY_SPEED_MIN     := 1.0
const FLY_SPEED_MAX     := 200.0
const MOVE_SHIFT_MULT   := 3.0        # × speed when Shift is held
const MOVE_CTRL_MULT    := 0.25       # × speed when Ctrl is held (precision)

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
		MOUSE_BUTTON_MIDDLE:
			_pan_dragging = e.pressed
		MOUSE_BUTTON_RIGHT:
			_fly_dragging = e.pressed
			# Capture / release the mouse cursor for FPS-style look.
			# Captured = cursor hidden + relative-motion events.
			if e.pressed:
				Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)
			else:
				Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
		MOUSE_BUTTON_WHEEL_UP:
			if e.pressed:
				_wheel_zoom_or_flyspeed(true)
		MOUSE_BUTTON_WHEEL_DOWN:
			if e.pressed:
				_wheel_zoom_or_flyspeed(false)

# Wheel changes fly-speed while in fly mode, zoom otherwise.
func _wheel_zoom_or_flyspeed(in_dir: bool) -> void:
	var mult: float = ZOOM_STEP
	if Input.is_key_pressed(KEY_SHIFT):
		mult = mult * mult  # ≈ 1.21 → noticeable extra step
	if _fly_dragging:
		# Adjust fly speed.
		if in_dir:
			_fly_speed = clampf(_fly_speed * mult, FLY_SPEED_MIN, FLY_SPEED_MAX)
		else:
			_fly_speed = clampf(_fly_speed / mult, FLY_SPEED_MIN, FLY_SPEED_MAX)
		return
	# Normal zoom (dolly).
	if in_dir:
		_distance = clampf(_distance / mult, _min_dist, _max_dist)
	else:
		_distance = clampf(_distance * mult, _min_dist, _max_dist)
	_apply_pose()

func _handle_mouse_motion(e: InputEventMouseMotion) -> void:
	if _fly_dragging:
		# FPS look: rotate the camera itself. Target moves with it so the
		# camera-target geometry stays consistent (you can release fly mode
		# and continue orbiting around the new target).
		_yaw -= e.relative.x * LOOK_SENSITIVITY
		_pitch = clampf(_pitch - e.relative.y * LOOK_SENSITIVITY, -PITCH_LIMIT, PITCH_LIMIT)
		# Recompute target so the camera position stays put while looking
		# around — feels like rotating the head, not orbiting.
		var fwd := _forward_from_yaw_pitch()
		_target = global_position + fwd * _distance
		_apply_pose()
		return

	if _orbit_dragging:
		_yaw -= e.relative.x * ORBIT_SENSITIVITY
		_pitch = clampf(_pitch - e.relative.y * ORBIT_SENSITIVITY, -PITCH_LIMIT, PITCH_LIMIT)
		_apply_pose()
		return

	if _pan_dragging:
		# Pan in the camera's local plane — right * dx + up * dy, scaled by
		# distance so far-away pans don't feel slow. NO AABB clamp — user
		# explicitly wants to go anywhere.
		var scale: float = _distance * PAN_SENSITIVITY * 0.05
		var right := global_transform.basis.x
		var up := global_transform.basis.y
		_target -= right * (e.relative.x * scale)
		_target += up * (e.relative.y * scale)
		_apply_pose()

func _handle_key(e: InputEventKey) -> void:
	if not e.pressed:
		# Key-release: only update movement axes; follow/reset are press-only.
		var sign: float = -1.0
		match e.keycode:
			KEY_W, KEY_UP:    _move_input.z += sign
			KEY_S, KEY_DOWN:  _move_input.z -= sign
			KEY_A, KEY_LEFT:  _move_input.x -= sign
			KEY_D, KEY_RIGHT: _move_input.x += sign
			KEY_Q:            _move_input.y -= sign
			KEY_E:            _move_input.y += sign
		_move_input = _move_input.clamp(Vector3(-1.0, -1.0, -1.0), Vector3(1.0, 1.0, 1.0))
		return

	# R — reset (also releases follow).
	if e.keycode == KEY_R:
		_set_follow(null)
		_reset()
		return

	# F / Esc — release follow. Esc also releases mouse capture if active.
	if e.keycode == KEY_F:
		_set_follow(null)
		return
	if e.keycode == KEY_ESCAPE:
		_set_follow(null)
		if _fly_dragging:
			_fly_dragging = false
			Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
		return

	# Digit keys 0-9: follow marble by index (Shift held → add 10).
	var digit := _digit_from_keycode(e.keycode)
	if digit >= 0:
		var idx: int = digit + (10 if e.shift_pressed else 0)
		_set_follow(_find_marble_by_index(idx), idx)
		return

	# Movement keys: update the continuous _move_input vector.
	var sign: float = 1.0
	match e.keycode:
		KEY_W, KEY_UP:    _move_input.z += sign
		KEY_S, KEY_DOWN:  _move_input.z -= sign
		KEY_A, KEY_LEFT:  _move_input.x -= sign
		KEY_D, KEY_RIGHT: _move_input.x += sign
		KEY_Q:            _move_input.y -= sign
		KEY_E:            _move_input.y += sign
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

# Returns the marble at the given drop-order index from the "marbles" group.
func _find_marble_by_index(idx: int) -> Node3D:
	var nodes := get_tree().get_nodes_in_group("marbles")
	if nodes.is_empty():
		return null
	nodes.sort_custom(func(a: Node, b: Node) -> bool:
		return a.name < b.name
	)
	if idx < 0 or idx >= nodes.size():
		return null
	return nodes[idx] as Node3D

func _process(delta: float) -> void:
	# Compute speed multiplier from modifier keys.
	var mult: float = 1.0
	if Input.is_key_pressed(KEY_SHIFT):
		mult *= MOVE_SHIFT_MULT
	if Input.is_key_pressed(KEY_CTRL):
		mult *= MOVE_CTRL_MULT

	if _follow_marble != null:
		# Follow-marble mode: smoothly steer _target toward the marble.
		# WASD is ignored to avoid fighting the follow.
		if not is_instance_valid(_follow_marble):
			_set_follow(null)
		else:
			_target = _target.lerp(_follow_marble.global_position, 0.15)
			_apply_pose()
		return

	if _move_input == Vector3.ZERO:
		return

	if _fly_dragging:
		# FPS fly: WASD moves the CAMERA position along the look direction.
		# Forward and right come from the full camera basis (includes pitch),
		# so W can climb / dive when looking up/down — typical FPS.
		var speed: float = _fly_speed * delta * mult
		var basis: Basis = global_transform.basis
		var fwd: Vector3 = -basis.z  # camera looks down -Z
		var right: Vector3 = basis.x
		var delta_pos: Vector3 = right * (_move_input.x * speed) \
			+ fwd * (_move_input.z * speed) \
			+ Vector3(0.0, _move_input.y * speed, 0.0)
		global_position += delta_pos
		# Keep target ahead of the camera so the orbit math stays valid when
		# the user releases right-click and goes back to left-drag orbit.
		_target = global_position + fwd * _distance
		# look_at refresh (no need to re-apply pose since position is direct).
		look_at(_target, Vector3.UP)
		return

	# Orbit mode: WASD moves the target. Forward is horizontal-only so the
	# framing stays level. Q/E moves world Y. Speed scales with distance.
	var speed: float = MOVE_SPEED * _distance * delta * mult
	var cam_basis: Basis = global_transform.basis
	var right: Vector3 = cam_basis.x
	var look_h: Vector3 = Vector3(-cam_basis.z.x, 0.0, -cam_basis.z.z).normalized()
	_target += right * (_move_input.x * speed)
	_target += look_h * (_move_input.z * speed)
	_target.y += _move_input.y * speed
	_apply_pose()

func _reset() -> void:
	_follow_marble = null
	_target = _default_target
	_yaw = _default_yaw
	_pitch = _default_pitch
	_distance = _default_distance
	_apply_pose()

# Public API: called by HUD marble_selected signal. Finds the marble at the
# given drop-order index and begins following it, emitting following_changed.
func follow_marble_index(idx: int) -> void:
	_set_follow(_find_marble_by_index(idx), idx)

# Internal setter that updates _follow_marble and emits following_changed.
func _set_follow(marble: Node3D, marble_idx: int = -1) -> void:
	_follow_marble = marble
	following_changed.emit(marble_idx if marble != null else -1)

# Compute the forward (look) vector from current yaw + pitch. Used by the
# FPS-look handler to keep the target consistent with the rotated head.
func _forward_from_yaw_pitch() -> Vector3:
	var cos_p: float = cos(_pitch)
	# Camera looks at _target from _target + offset, so look direction is -offset.
	# offset is (cos_p sin(yaw), sin(pitch), cos_p cos(yaw)) → forward = negate.
	return -Vector3(cos_p * sin(_yaw), sin(_pitch), cos_p * cos(_yaw)).normalized()

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
