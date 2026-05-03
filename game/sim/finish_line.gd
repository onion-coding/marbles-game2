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

# Returns the top-N marbles to cross the finish line, in finish order
# (1st, 2nd, 3rd, ...). Up to `n` entries — fewer if not enough marbles
# crossed by the time this is called. Used by the recorder at finalize
# time to compute the podium for the v4 replay manifest.
#
# Sort by tick ascending (= earliest crossing first). Stable on equal
# ticks via insertion order (Dictionary in GDScript 4 preserves key
# insertion order).
func get_podium(n: int = 3) -> Array[RigidBody3D]:
	var entries: Array = []                         # [{ marble, tick }]
	for marble in _crossed.keys():
		if not is_instance_valid(marble):
			continue
		entries.append({"marble": marble, "tick": int(_crossed[marble])})
	entries.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return a["tick"] < b["tick"]
	)
	var out: Array[RigidBody3D] = []
	for e in entries:
		if out.size() >= n:
			break
		out.append(e["marble"] as RigidBody3D)
	return out
