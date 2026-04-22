class_name FixedCamera
extends Camera3D

# Set by the caller before add_child. The camera frames whatever track it's
# handed, so new tracks don't need a bespoke camera each.
var track: Track

func _ready() -> void:
	# Compute a high-angle shot that frames the whole (possibly curving) track.
	# Pull back from the AABB center along world -Z by enough distance to fit the
	# track's longest horizontal extent in frame, then lift up by ~60% of that
	# distance. Tilt down to look at the AABB center. Tuned against the current
	# 5-segment S-curve; if segments change radically, this may need re-tuning
	# rather than being a pure function of bounds.
	var bb := track.track_bounds()
	var center := bb.get_center()
	var extent := bb.size
	var horizontal_span: float = maxf(extent.x, extent.z)
	var pullback: float = horizontal_span * 0.9 + 10.0
	position = center + Vector3(0, pullback * 0.6 + extent.y * 0.5, pullback * 0.6)
	look_at(center, Vector3.UP)
	current = true
	fov = 60.0
