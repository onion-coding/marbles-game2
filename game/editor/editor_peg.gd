class_name EditorPeg
extends EditorObject

# Editable peg: cylinder mesh + matching cylinder collider.
#
# Plinko pegs are horizontal cylinders extending along Z; other tracks
# may want vertical pegs (standing poles). `axis` selects orientation:
#   "x" — cylinder lies along world X (long axis horizontal, east-west)
#   "y" — cylinder stands upright (default Godot orientation)
#   "z" — cylinder lies along world Z (the plinko-peg case)

var radius: float = 0.30
var height: float = 3.0
var axis: String = "z"
var color: Color = Color(0.95, 0.55, 0.20, 1.0)

func get_object_type() -> String:
	return "peg"

func build_visual() -> void:
	var mesh_inst := MeshInstance3D.new()
	mesh_inst.name = "PegMesh"
	var cm := CylinderMesh.new()
	cm.top_radius = radius
	cm.bottom_radius = radius
	cm.height = height
	cm.radial_segments = 20
	mesh_inst.mesh = cm

	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	mat.metallic = 0.10
	mat.roughness = 0.45
	mesh_inst.material_override = mat
	mesh_inst.basis = _axis_basis()
	add_child(mesh_inst)

	var body := StaticBody3D.new()
	body.name = "PegBody"
	var coll := CollisionShape3D.new()
	var shape := CylinderShape3D.new()
	shape.radius = radius
	shape.height = height
	coll.shape = shape
	coll.basis = _axis_basis()
	body.add_child(coll)
	add_child(body)

func _axis_basis() -> Basis:
	# Cylinder default is along Y. Rotate around Z (to lay along X) or
	# around X (to lay along Z).
	match axis:
		"x":
			return Basis(Vector3.FORWARD, deg_to_rad(90.0))
		"z":
			return Basis(Vector3.RIGHT, deg_to_rad(90.0))
		_:
			return Basis.IDENTITY

func get_params() -> Dictionary:
	return {
		"radius": radius,
		"height": height,
		"axis": axis,
		"color": [color.r, color.g, color.b, color.a],
	}

func apply_params(d: Dictionary) -> void:
	radius = float(d.get("radius", radius))
	height = float(d.get("height", height))
	axis = String(d.get("axis", axis))
	var c = d.get("color", null)
	if c is Array and c.size() >= 4:
		color = Color(float(c[0]), float(c[1]), float(c[2]), float(c[3]))
	rebuild_visual()
