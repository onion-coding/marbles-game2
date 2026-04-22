class_name MarbleSpawner
extends RefCounted

const RADIUS := 0.3

# Deterministic-by-slot spawn. `slots[i]` is the spawn slot for marble i.
# `colors[i]` (optional, same length as slots) overrides the default HSV-by-index color.
# `rail` resolves slot indices to world positions — different tracks have different rails.
static func spawn(parent: Node, rail: SpawnRail, slots: Array, colors: Array = []) -> Array[RigidBody3D]:
	var marbles: Array[RigidBody3D] = []
	for i in range(slots.size()):
		var color: Color = colors[i] if i < colors.size() else Color.from_hsv(float(i) / max(slots.size(), 1), 0.8, 0.95)
		var marble := _make_marble(rail, i, int(slots[i]), color)
		parent.add_child(marble)
		marbles.append(marble)
	return marbles

static func _make_marble(rail: SpawnRail, drop_order: int, slot: int, color: Color) -> RigidBody3D:
	var marble := RigidBody3D.new()
	marble.name = "Marble_%02d" % drop_order
	marble.mass = 1.0
	marble.continuous_cd = true

	var mesh_inst := MeshInstance3D.new()
	var sphere := SphereMesh.new()
	sphere.radius = RADIUS
	sphere.height = RADIUS * 2.0
	mesh_inst.mesh = sphere
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	mesh_inst.material_override = mat
	marble.add_child(mesh_inst)

	var shape := CollisionShape3D.new()
	var sphere_shape := SphereShape3D.new()
	sphere_shape.radius = RADIUS
	shape.shape = sphere_shape
	marble.add_child(shape)

	marble.physics_material_override = PhysicsMaterials.marble()
	marble.position = rail.slot_position(slot, drop_order)
	return marble
