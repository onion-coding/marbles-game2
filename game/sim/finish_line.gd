class_name FinishLine
extends Area3D

signal marble_crossed(marble: RigidBody3D, tick: int)
signal race_finished(winner: RigidBody3D, tick: int)

var _winner: RigidBody3D = null
var _crossed: Dictionary = {}

func _ready() -> void:
	# Park the slab just past the last segment's downhill edge. The slab is
	# oriented to match the last segment's frame so its "crossing plane" is
	# perpendicular to the segment's forward direction — otherwise a curving
	# track ending with a yaw would have marbles missing an axis-aligned slab.
	var last := RampTrack.segment_count() - 1
	var meta := RampTrack.segment_meta(last)
	var forward: Vector3 = meta["forward"]
	var up: Vector3 = meta["up"]
	var length: float = meta["length"]

	# Surface point at the downhill edge, plus a small forward offset so the slab
	# sits just past the edge and catches balls that fall off.
	var edge := RampTrack.segment_surface_point(last, length * 0.5 + 0.5)
	position = edge + up * 2.0
	basis = meta["basis"]

	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	# Wide and tall in the segment's cross-track / vertical axes, thin along its forward axis.
	box.size = Vector3(RampTrack.WIDTH + 4.0, 12.0, 0.4)
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
