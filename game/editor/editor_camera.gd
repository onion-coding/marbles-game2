class_name EditorCamera
extends Camera3D

# Map-editor camera with the standard DCC-tool control set:
#
#   RMB drag (no movement keys)        — orbit around _focus
#   RMB held + WASD/QE                 — free-fly; _focus translates with the
#                                        camera in its look frame
#   MMB drag                           — pan _focus in the screen plane
#   Scroll wheel                       — zoom (changes _distance)
#   Shift held                         — fly speed boost
#
# All inputs feed *target* state (_target_yaw etc.). The actual camera
# transform is interpolated toward the target every frame, so navigation
# feels smooth instead of frame-snapped.

@export var orbit_sensitivity: float = 0.005
@export var pan_sensitivity:   float = 0.003
@export var zoom_step:         float = 1.12
@export var fly_speed:         float = 12.0
@export var fly_boost:         float = 32.0
@export var smoothing:         float = 14.0

var _focus: Vector3 = Vector3(0.0, 4.0, 0.0)
var _yaw:   float = 0.0
var _pitch: float = -0.45
var _distance: float = 22.0

var _target_focus:    Vector3 = Vector3(0.0, 4.0, 0.0)
var _target_yaw:      float = 0.0
var _target_pitch:    float = -0.45
var _target_distance: float = 22.0

var _orbiting: bool = false
var _panning:  bool = false

func _ready() -> void:
	current = true
	_apply_transform_now()

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		match mb.button_index:
			MOUSE_BUTTON_RIGHT:
				_orbiting = mb.pressed
			MOUSE_BUTTON_MIDDLE:
				_panning = mb.pressed
			MOUSE_BUTTON_WHEEL_UP:
				if mb.pressed:
					_target_distance = max(0.5, _target_distance / zoom_step)
			MOUSE_BUTTON_WHEEL_DOWN:
				if mb.pressed:
					_target_distance = min(400.0, _target_distance * zoom_step)
	elif event is InputEventMouseMotion:
		var mm := event as InputEventMouseMotion
		# RMB drag = orbit ONLY if no WASD is held. With WASD held, the
		# motion feeds a future-friendly mouse-look during fly (not
		# implemented for v1; orbit input is dropped while flying).
		if _orbiting and not _is_wasd_active():
			_target_yaw -= mm.relative.x * orbit_sensitivity
			_target_pitch = clamp(_target_pitch - mm.relative.y * orbit_sensitivity, -1.4, 1.4)
		elif _panning:
			# Pan: shift _focus in the camera's screen plane. Scale by
			# _distance so pan speed feels constant regardless of zoom.
			var basis := global_transform.basis
			var right := basis.x
			var up    := basis.y
			var pan_scale := pan_sensitivity * _distance
			_target_focus -= right * mm.relative.x * pan_scale
			_target_focus += up    * mm.relative.y * pan_scale

func _is_wasd_active() -> bool:
	return Input.is_key_pressed(KEY_W) or Input.is_key_pressed(KEY_A) \
		or Input.is_key_pressed(KEY_S) or Input.is_key_pressed(KEY_D) \
		or Input.is_key_pressed(KEY_Q) or Input.is_key_pressed(KEY_E)

func _process(delta: float) -> void:
	# Fly mode: WASD shifts _focus along the camera's local axes when RMB
	# is held. RMB-held lets the user fly without orbiting at the same time
	# (which would feel chaotic). E/Q raise/lower in world space.
	if _orbiting:
		var fly_local := Vector3.ZERO
		if Input.is_key_pressed(KEY_W): fly_local.z -= 1.0
		if Input.is_key_pressed(KEY_S): fly_local.z += 1.0
		if Input.is_key_pressed(KEY_A): fly_local.x -= 1.0
		if Input.is_key_pressed(KEY_D): fly_local.x += 1.0
		var fly_vertical := 0.0
		if Input.is_key_pressed(KEY_E): fly_vertical += 1.0
		if Input.is_key_pressed(KEY_Q): fly_vertical -= 1.0
		if fly_local.length_squared() > 0.001 or absf(fly_vertical) > 0.001:
			var speed := fly_speed
			if Input.is_key_pressed(KEY_SHIFT):
				speed = fly_boost
			var basis := global_transform.basis
			# Forward = -Z in Godot camera-space. Project forward onto
			# the horizontal plane so W moves you forward "on the ground",
			# not into the floor when looking down.
			var fwd := -basis.z
			fwd.y = 0.0
			if fwd.length_squared() > 0.0001:
				fwd = fwd.normalized()
			var right := basis.x
			right.y = 0.0
			if right.length_squared() > 0.0001:
				right = right.normalized()
			var move := (fwd * -fly_local.z + right * fly_local.x) * speed * delta
			move.y += fly_vertical * speed * delta
			_target_focus += move

	# Smooth toward targets every frame.
	var t: float = clamp(delta * smoothing, 0.0, 1.0)
	_focus    = _focus.lerp(_target_focus, t)
	_yaw      = lerp_angle(_yaw, _target_yaw, t)
	_pitch    = lerp(_pitch, _target_pitch, t)
	_distance = lerp(_distance, _target_distance, t)
	_apply_transform_now()

func _apply_transform_now() -> void:
	# Spherical offset from _focus, then look_at the focus point.
	var offset := Vector3(
		cos(_pitch) * sin(_yaw),
		sin(_pitch),
		cos(_pitch) * cos(_yaw)
	) * _distance
	global_position = _focus + offset
	# Avoid the singularity at exact straight-up/-down by clamping pitch.
	look_at(_focus, Vector3.UP)
