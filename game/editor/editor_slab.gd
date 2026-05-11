class_name EditorSlab
extends EditorObject

# Editable slab: box mesh + box collider with rotation around Z.
#
# Slabs cover ramps / floors / walls / deflectors / dividers — anything
# that's box-shaped in plinko, sky, stadium etc. Tilt around Z lets the
# user build inclined ramps to direct marbles.

var size_x: float = 4.0
var size_y: float = 0.4
var size_z: float = 3.0
var tilt_deg: float = 0.0              # rotation around the LOCAL Z axis
var color: Color = Color(0.55, 0.58, 0.62, 1.0)

func get_object_type() -> String:
	return "slab"

func build_visual() -> void:
	var mesh_inst := MeshInstance3D.new()
	mesh_inst.name = "SlabMesh"
	var bm := BoxMesh.new()
	bm.size = Vector3(size_x, size_y, size_z)
	mesh_inst.mesh = bm

	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	mat.metallic = 0.05
	mat.roughness = 0.65
	mesh_inst.material_override = mat
	add_child(mesh_inst)

	var body := StaticBody3D.new()
	body.name = "SlabBody"
	var coll := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = Vector3(size_x, size_y, size_z)
	coll.shape = shape
	body.add_child(coll)
	add_child(body)

	# Apply the tilt to the whole object (rotation around local Z so the
	# slab tips one way along X). rotation_y from the base class is kept
	# separate so the user can both yaw and tilt.
	basis = Basis(Vector3(0, 0, 1), deg_to_rad(tilt_deg)) * Basis(Vector3.UP, rotation.y)

func get_params() -> Dictionary:
	return {
		"size_x": size_x,
		"size_y": size_y,
		"size_z": size_z,
		"tilt_deg": tilt_deg,
		"color": [color.r, color.g, color.b, color.a],
	}

func apply_params(d: Dictionary) -> void:
	size_x = float(d.get("size_x", size_x))
	size_y = float(d.get("size_y", size_y))
	size_z = float(d.get("size_z", size_z))
	tilt_deg = float(d.get("tilt_deg", tilt_deg))
	var c = d.get("color", null)
	if c is Array and c.size() >= 4:
		color = Color(float(c[0]), float(c[1]), float(c[2]), float(c[3]))
	rebuild_visual()
