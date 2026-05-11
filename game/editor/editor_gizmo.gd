class_name EditorGizmo
extends Node3D

# Visible XYZ translation gizmo. Three coloured arrows (X=red, Y=green,
# Z=blue) appear at the currently selected object's position. Each arrow
# is a StaticBody3D on collision layer GIZMO_LAYER (16) so MapEditor's
# raycast can distinguish "clicked on gizmo" from "clicked on object"
# without ever consulting node names.
#
# Drag math (per axis):
#   1. On LMB-press over an arrow, record the axis direction and the
#      cursor's world ray. Compute the parameter t along the axis where
#      the ray comes closest — this is the "grab" point.
#   2. On mouse motion, compute t again with the new cursor ray. The
#      delta_t is the user's intended displacement along the axis.
#   3. Apply delta_t (snapped to GRID_STEP) to the original object
#      position. Y axis snap is the same step so behaviour matches the
#      property-panel +/- buttons.

const GIZMO_LAYER := 16
const ARROW_LENGTH := 1.6
const ARROW_RADIUS := 0.05
const ARROW_HEAD_R := 0.18
const ARROW_HEAD_LEN := 0.40
const ARROW_HIT_R := 0.10      # collider radius — slightly fatter than
                                # the visual (0.05) so the arrow is easy
                                # to grab, but small enough that clicks
                                # in the surrounding empty space still
                                # reach the scene below for deselect.

const AXIS_COLOURS := {
	"x": Color(1.00, 0.30, 0.30),
	"y": Color(0.30, 1.00, 0.30),
	"z": Color(0.30, 0.50, 1.00),
}

func _ready() -> void:
	_build_arrow("x", Vector3.RIGHT)
	_build_arrow("y", Vector3.UP)
	_build_arrow("z", Vector3.BACK)   # Godot's "front" is -Z, so +Z BACK
									  # is the conventional "blue arrow"

# Build one arrow oriented along `axis_dir`, registered on the gizmo
# collision layer and tagged with its axis letter as metadata so the
# click handler in MapEditor can read it back.
func _build_arrow(axis: String, axis_dir: Vector3) -> void:
	var body := StaticBody3D.new()
	body.name = "Arrow_" + axis.to_upper()
	body.collision_layer = 1 << (GIZMO_LAYER - 1)
	body.collision_mask = 0
	body.set_meta("axis", axis)
	add_child(body)

	# Rotate the body so its +Y points along axis_dir. The shaft and
	# head meshes are authored along the body's local +Y; rotating the
	# body once orients both pieces.
	body.basis = _basis_from_up(axis_dir)

	var mat := StandardMaterial3D.new()
	mat.albedo_color = AXIS_COLOURS[axis]
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.flags_transparent = false
	mat.no_depth_test = true              # arrows always visible above scene

	# Shaft (cylinder along local +Y, centred at half-length).
	var shaft := MeshInstance3D.new()
	shaft.name = "Shaft"
	var cm := CylinderMesh.new()
	cm.top_radius = ARROW_RADIUS
	cm.bottom_radius = ARROW_RADIUS
	cm.height = ARROW_LENGTH - ARROW_HEAD_LEN
	cm.radial_segments = 12
	shaft.mesh = cm
	shaft.material_override = mat
	shaft.position = Vector3(0, (ARROW_LENGTH - ARROW_HEAD_LEN) * 0.5, 0)
	body.add_child(shaft)

	# Cone head — a tapered cylinder placed at the tip.
	var head := MeshInstance3D.new()
	head.name = "Head"
	var hm := CylinderMesh.new()
	hm.top_radius = 0.0
	hm.bottom_radius = ARROW_HEAD_R
	hm.height = ARROW_HEAD_LEN
	hm.radial_segments = 16
	head.mesh = hm
	head.material_override = mat
	head.position = Vector3(0, ARROW_LENGTH - ARROW_HEAD_LEN * 0.5, 0)
	body.add_child(head)

	# Collision: a capsule wrapping shaft + head so picking the arrow
	# is forgiving. The collider doesn't push marbles — that's why
	# GIZMO_LAYER is unique; nothing else casts against this layer.
	var coll := CollisionShape3D.new()
	coll.name = "ArrowShape"
	var caps := CapsuleShape3D.new()
	caps.radius = ARROW_HIT_R
	caps.height = ARROW_LENGTH
	coll.shape = caps
	coll.position = Vector3(0, ARROW_LENGTH * 0.5, 0)
	body.add_child(coll)

# Build a basis whose local +Y points along `up_dir`. Picks a stable
# secondary axis to avoid the singularity when up_dir is ±world up.
static func _basis_from_up(up_dir: Vector3) -> Basis:
	var u := up_dir.normalized()
	# Pick a reference axis NOT parallel to u.
	var ref := Vector3.RIGHT
	if absf(u.dot(ref)) > 0.95:
		ref = Vector3.UP
	var right := u.cross(ref).normalized()
	var forward := right.cross(u).normalized()
	return Basis(right, u, forward)

# Closest-point parameter along an axis (a line through axis_origin
# with direction axis_dir) to an arbitrary ray. Returns the t such that
# axis_origin + axis_dir * t is the point on the axis nearest the ray.
static func axis_param_under_ray(ray_origin: Vector3, ray_dir: Vector3,
		axis_origin: Vector3, axis_dir: Vector3) -> float:
	var w := ray_origin - axis_origin
	var a := ray_dir.dot(ray_dir)
	var b := ray_dir.dot(axis_dir)
	var c := axis_dir.dot(axis_dir)
	var d := ray_dir.dot(w)
	var e := axis_dir.dot(w)
	var denom := a * c - b * b
	if absf(denom) < 1e-5:
		return 0.0
	return (a * e - b * d) / denom

static func axis_unit_vector(axis: String) -> Vector3:
	match axis:
		"x": return Vector3.RIGHT
		"y": return Vector3.UP
		"z": return Vector3.BACK
		_:   return Vector3.RIGHT
