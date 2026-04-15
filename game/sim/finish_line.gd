class_name FinishLine
extends Area3D

signal marble_crossed(marble: RigidBody3D, tick: int)
signal race_finished(winner: RigidBody3D, tick: int)

var _winner: RigidBody3D = null
var _crossed: Dictionary = {}

func _ready() -> void:
	# Ramp rotates -ANGLE_DEG about X, so its downhill end sits near world (0, -5, -14).
	# Slab is world-aligned so marbles falling off the deck still register.
	position = Vector3(0, -3.0, -13.0)

	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(RampTrack.WIDTH + 2.0, 12.0, 0.4)
	shape.shape = box
	add_child(shape)

	body_entered.connect(_on_body_entered)

func _on_body_entered(body: Node) -> void:
	if not body is RigidBody3D:
		return
	if _crossed.has(body):
		return
	var tick := Engine.get_physics_frames()
	_crossed[body] = tick
	marble_crossed.emit(body, tick)
	if _winner == null:
		_winner = body
		race_finished.emit(body, tick)
		print("WINNER: %s at tick %d" % [body.name, tick])

func get_winner() -> RigidBody3D:
	return _winner

func get_crossings() -> Dictionary:
	return _crossed
