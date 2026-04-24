class_name FinishLine
extends Area3D

signal marble_crossed(marble: RigidBody3D, tick: int)
signal race_finished(winner: RigidBody3D, tick: int)

# Set by the caller before add_child. The finish slab geometry is pulled from
# track.finish_area_transform() and .finish_area_size() so each track decides
# where and how big the finish is without this class knowing any geometry.
var track: Track

var _winner: RigidBody3D = null
var _crossed: Dictionary = {}

func _ready() -> void:
	transform = track.finish_area_transform()
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = track.finish_area_size()
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
