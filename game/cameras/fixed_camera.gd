class_name FixedCamera
extends Camera3D

# Set by the caller before add_child. The camera frames whatever track it's
# handed, so new tracks don't need a bespoke camera each.
var track: Track

func _ready() -> void:
	current = true
	fov = 60.0

	# Tracks may supply an explicit camera_pose() — useful when the AABB-
	# fitting default produces an overly far / top-down framing (e.g. very
	# long horizontal tables where dist gets dominated by the X extent).
	var pose: Dictionary = track.camera_pose()
	if not pose.is_empty():
		position = pose.get("position", Vector3.ZERO) as Vector3
		var target: Vector3 = pose.get("target", Vector3.ZERO) as Vector3
		if pose.has("fov"):
			fov = float(pose["fov"])
		look_at(target, Vector3.UP)
		return

	# Default: fit the whole AABB. Pulls back enough to fit the largest
	# dimension at the camera's vertical FOV, with a small margin and a
	# modest Y lift for high-angle feel.
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
