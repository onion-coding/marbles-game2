class_name EditorFunnel
extends EditorObject

# Editable funnel: tapered cylinder mesh + matching trimesh collider.
# Parameters:
#   top_radius    : outer rim radius (top of the cone)
#   bottom_radius : narrow opening radius (bottom)
#   height        : vertical extent
#   color         : material albedo (alpha < 1 for translucent funnel walls)

var top_radius: float = 1.20
var bottom_radius: float = 0.55
var height: float = 1.80
var color: Color = Color(0.55, 0.85, 1.00, 0.78)

func get_object_type() -> String:
	return "funnel"

func build_visual() -> void:
	# Visual cone (uncapped — open top + open bottom).
	var mesh_inst := MeshInstance3D.new()
	mesh_inst.name = "FunnelMesh"
	var cm := CylinderMesh.new()
	cm.top_radius = top_radius
	cm.bottom_radius = bottom_radius
	cm.height = height
	cm.radial_segments = 28
	cm.cap_top = false
	cm.cap_bottom = false
	mesh_inst.mesh = cm

	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat.depth_draw_mode = BaseMaterial3D.DEPTH_DRAW_ALWAYS
	mat.metallic = 0.15
	mat.roughness = 0.30
	mesh_inst.material_override = mat
	add_child(mesh_inst)

	# Collider: same cone via create_trimesh_shape; backface_collision so
	# a marble approaching from outside the cone (above the rim, falling
	# inward) and a marble inside the cone both push off the wall.
	var body := StaticBody3D.new()
	body.name = "FunnelBody"
	var coll := CollisionShape3D.new()
	var shape: ConcavePolygonShape3D = cm.create_trimesh_shape()
	shape.backface_collision = true
	coll.shape = shape
	body.add_child(coll)
	add_child(body)

func get_params() -> Dictionary:
	return {
		"top_radius": top_radius,
		"bottom_radius": bottom_radius,
		"height": height,
		"color": [color.r, color.g, color.b, color.a],
	}

func apply_params(d: Dictionary) -> void:
	top_radius    = float(d.get("top_radius", top_radius))
	bottom_radius = float(d.get("bottom_radius", bottom_radius))
	height        = float(d.get("height", height))
	var c = d.get("color", null)
	if c is Array and c.size() >= 4:
		color = Color(float(c[0]), float(c[1]), float(c[2]), float(c[3]))
	rebuild_visual()
