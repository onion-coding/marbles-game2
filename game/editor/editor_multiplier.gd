class_name EditorMultiplier
extends EditorObject

# Editable payout slot. Renders as a translucent emissive box; the
# colour is auto-derived from the multiplier value so a player can read
# the payout at a glance (cool blue = low, hot red = high).
#
# Same box collider as a slab — the slot is a real geometry the marble
# lands in, not an invisible trigger zone. Per the no-invisible-blocks
# rule.

var size_x: float = 2.0
var size_y: float = 1.2
var size_z: float = 3.0
var multiplier: float = 1.0

func get_object_type() -> String:
	return "multiplier"

func build_visual() -> void:
	var mesh_inst := MeshInstance3D.new()
	mesh_inst.name = "MultMesh"
	var bm := BoxMesh.new()
	bm.size = Vector3(size_x, size_y, size_z)
	mesh_inst.mesh = bm
	var c := _color_for_multiplier(multiplier)
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(c.r, c.g, c.b, 0.55)
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.depth_draw_mode = BaseMaterial3D.DEPTH_DRAW_ALWAYS
	mat.emission_enabled = true
	mat.emission = c
	mat.emission_energy_multiplier = 0.45
	mesh_inst.material_override = mat
	add_child(mesh_inst)

	var body := StaticBody3D.new()
	body.name = "MultBody"
	var coll := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = Vector3(size_x, size_y, size_z)
	coll.shape = shape
	body.add_child(coll)
	add_child(body)

	# Multiplier label as a Label3D so the user can read it in-scene.
	var label := Label3D.new()
	label.name = "MultLabel"
	label.text = "x%s" % _fmt_mult(multiplier)
	label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	label.pixel_size = 0.012
	label.font_size = 32
	label.outline_size = 4
	label.modulate = Color(1, 1, 1)
	label.position = Vector3(0, size_y * 0.5 + 0.4, 0)
	add_child(label)

func _color_for_multiplier(m: float) -> Color:
	if m >= 5.0:   return Color(1.0, 0.20, 0.30)   # red — jackpot
	if m >= 2.0:   return Color(1.0, 0.65, 0.20)   # orange — high
	if m >= 1.0:   return Color(1.0, 0.95, 0.40)   # yellow — even
	if m >= 0.5:   return Color(0.55, 0.85, 1.00)  # cool blue — half
	return Color(0.45, 0.55, 0.70)                 # cold — lose

static func _fmt_mult(m: float) -> String:
	# Drop the decimal point on integer multipliers (2.0 -> "2").
	if is_equal_approx(m, round(m)):
		return "%d" % int(round(m))
	return "%.1f" % m

func get_params() -> Dictionary:
	return {
		"size_x": size_x,
		"size_y": size_y,
		"size_z": size_z,
		"multiplier": multiplier,
	}

func apply_params(d: Dictionary) -> void:
	size_x = float(d.get("size_x", size_x))
	size_y = float(d.get("size_y", size_y))
	size_z = float(d.get("size_z", size_z))
	multiplier = float(d.get("multiplier", multiplier))
	rebuild_visual()
