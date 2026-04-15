class_name RampTrack
extends Node3D

const LENGTH := 30.0
const WIDTH := 6.0
const ANGLE_DEG := 20.0

func _ready() -> void:
	add_child(_make_box_body("Ramp", Vector3(WIDTH, 0.5, LENGTH), Vector3.ZERO))
	add_child(_make_box_body("Wall_-1", Vector3(0.2, 1.0, LENGTH), Vector3(-WIDTH * 0.5, 0.5, 0)))
	add_child(_make_box_body("Wall_1", Vector3(0.2, 1.0, LENGTH), Vector3(WIDTH * 0.5, 0.5, 0)))

func _make_box_body(node_name: String, size: Vector3, pos: Vector3) -> StaticBody3D:
	var body := StaticBody3D.new()
	body.name = node_name
	body.rotation_degrees = Vector3(-ANGLE_DEG, 0, 0)
	body.position = pos

	var mesh_inst := MeshInstance3D.new()
	var box_mesh := BoxMesh.new()
	box_mesh.size = size
	mesh_inst.mesh = box_mesh
	body.add_child(mesh_inst)

	var shape := CollisionShape3D.new()
	var box_shape := BoxShape3D.new()
	box_shape.size = size
	shape.shape = box_shape
	body.add_child(shape)

	body.physics_material_override = PhysicsMaterials.track()
	return body
