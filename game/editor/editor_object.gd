class_name EditorObject
extends Node3D

# Base class for editable map objects (funnels, tubes, pegs, slabs, …).
#
# Contract for subclasses:
#   - get_object_type() : "funnel" / "tube" / etc. — the JSON tag
#   - build_visual()    : construct child MeshInstance3D + StaticBody3D
#                         from the current parameter set
#   - get_params()      : -> Dictionary of editable scalar/colour params
#   - apply_params(d)   : assign params from a dict + rebuild visual
#
# Selection state is shared here. set_selected(true) tints all child
# StandardMaterial3Ds with an emission boost so the user sees which
# object the property panel is editing.

const SELECTED_EMISSION_COLOR := Color(1.0, 0.8, 0.0)
const SELECTED_EMISSION_ENERGY := 0.8

var _selected: bool = false

# --- Subclass interface (override) -----------------------------------

func get_object_type() -> String:
	return "base"

func build_visual() -> void:
	pass

func get_params() -> Dictionary:
	return {}

func apply_params(_d: Dictionary) -> void:
	pass

# --- Common helpers --------------------------------------------------

func rebuild_visual() -> void:
	# Free everything we created on the previous build (and re-apply
	# the highlight if we're selected).
	for c in get_children():
		c.queue_free()
	build_visual()
	if _selected:
		# Re-apply highlight on next frame after children exist.
		call_deferred("_apply_highlight", true)

func set_selected(sel: bool) -> void:
	if _selected == sel:
		return
	_selected = sel
	_apply_highlight(sel)

func _apply_highlight(sel: bool) -> void:
	for child in _all_mesh_instances():
		var mat: StandardMaterial3D = child.material_override as StandardMaterial3D
		if mat == null:
			continue
		mat.emission_enabled = sel
		if sel:
			mat.emission = SELECTED_EMISSION_COLOR
			mat.emission_energy_multiplier = SELECTED_EMISSION_ENERGY

func _all_mesh_instances() -> Array:
	var out: Array = []
	_collect_mesh_instances(self, out)
	return out

func _collect_mesh_instances(node: Node, into: Array) -> void:
	for c in node.get_children():
		if c is MeshInstance3D:
			into.append(c)
		_collect_mesh_instances(c, into)

# --- Serialisation ---------------------------------------------------

func to_dict() -> Dictionary:
	return {
		"type": get_object_type(),
		"position": [position.x, position.y, position.z],
		"rotation_y": rotation.y,
		"params": get_params(),
	}

func from_dict(d: Dictionary) -> void:
	var p = d.get("position", [0.0, 0.0, 0.0])
	if p is Array and p.size() >= 3:
		position = Vector3(float(p[0]), float(p[1]), float(p[2]))
	rotation.y = float(d.get("rotation_y", 0.0))
	apply_params(d.get("params", {}))
