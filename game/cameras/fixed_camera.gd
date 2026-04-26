class_name FixedCamera
extends Camera3D

# Set by the caller before add_child. The camera frames whatever track it's
# handed, so new tracks don't need a bespoke camera each.
var track: Track

func _ready() -> void:
	# Compute a shot that frames the whole AABB tightly. Pulls back enough to
	# fit the largest dimension at the camera's vertical FOV, with a small
	# margin and a modest Y lift for high-angle feel.
	var bb := track.camera_bounds()
	var center := bb.get_center()
	var extent := bb.size
	# Required distance to fit the AABB's vertical extent at FOV 60°.
	# tan(30°) ≈ 0.577, so dist = (extent.y/2) / 0.577.
	# For wide-and-flat tracks the X dimension dominates; account via aspect.
	var aspect := 16.0 / 9.0
	var dist_v: float = (extent.y * 0.5) / 0.577
	var dist_h: float = (maxf(extent.x, extent.z) * 0.5) / (0.577 * aspect)
	var dist: float = maxf(dist_v, dist_h) * 1.10 + 4.0
	var lift: float = extent.y * 0.20
	position = center + Vector3(0, lift, dist)
	look_at(center, Vector3.UP)
	current = true
	fov = 60.0
