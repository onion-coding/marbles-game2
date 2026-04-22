class_name RampTrack
extends Track

# Multi-segment curving track. Each segment is a flat tilted box with walls;
# segments chain end-to-end with yaw offsets between them, producing an S-curve
# for test purposes. The cleanest way to think about this: a "snake" made of
# N tilted boxes, each yawed relative to the previous, all tilted the same
# amount so the whole path goes downhill.
#
# Seams between segments: the floors meet at an edge where yaw changes. Jolt
# handles this OK with continuous-CD on the marbles, but marbles can jitter a
# bit at junctions. That's acceptable for an MVP test track; a real track (M6)
# would use a single swept mesh or spline-based geometry.

const WIDTH := 6.0
const DECK_THICKNESS := 0.5
const WALL_HEIGHT := 3.0

# Segment list. Each entry:
#   length: meters along the segment's local -Z (downhill direction)
#   yaw_deg: absolute yaw (around world Y) for this segment. Accumulating yaws
#     via deltas was tempting but absolute values are easier to reason about.
#   tilt_deg: downhill tilt around the segment's local X axis (positive = floor
#     sloping down toward local -Z).
const SEGMENTS := [
	{"length": 18.0, "yaw_deg":   0.0, "tilt_deg": 14.0},
	{"length": 18.0, "yaw_deg":  18.0, "tilt_deg": 14.0},
	{"length": 18.0, "yaw_deg": -18.0, "tilt_deg": 14.0},
	{"length": 18.0, "yaw_deg": -18.0, "tilt_deg": 14.0},
	{"length": 18.0, "yaw_deg":  18.0, "tilt_deg": 14.0},
]

# Per-instance segment metadata. Computed lazily on first access so the verifier
# can use a RampTrack without adding it to the tree. Each entry:
# {center: Vector3, basis: Basis, forward: Vector3, right: Vector3, up: Vector3, length: float}.
var _meta: Array = []

func _ready() -> void:
	_ensure_meta()
	for m: Dictionary in _meta:
		add_child(_make_box_body("Deck", Vector3(WIDTH, DECK_THICKNESS, float(m["length"])), m["center"], m["basis"]))
		add_child(_make_wall(m, +1))
		add_child(_make_wall(m, -1))

func _make_wall(meta: Dictionary, side: int) -> StaticBody3D:
	var right: Vector3 = meta["right"]
	var up: Vector3 = meta["up"]
	var center: Vector3 = meta["center"]
	var length: float = meta["length"]
	var wall_center := center + right * (WIDTH * 0.5 * side) + up * (WALL_HEIGHT * 0.5)
	return _make_box_body("Wall", Vector3(0.2, WALL_HEIGHT, length), wall_center, meta["basis"])

func _make_box_body(node_name: String, size: Vector3, pos: Vector3, basis: Basis) -> StaticBody3D:
	var body := StaticBody3D.new()
	body.name = node_name
	body.transform = Transform3D(basis, pos)

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

# ─── Track overrides ───────────────────────────────────────────────────

func get_width() -> float:
	return WIDTH

func segment_count() -> int:
	_ensure_meta()
	return _meta.size()

func segment_meta(i: int) -> Dictionary:
	_ensure_meta()
	return _meta[i]

# World position of a point on segment i's top surface, offset `forward_offset`
# meters along the segment's local forward axis (positive = further downhill).
func segment_surface_point(i: int, forward_offset: float) -> Vector3:
	_ensure_meta()
	var m: Dictionary = _meta[i]
	var center: Vector3 = m["center"]
	var forward: Vector3 = m["forward"]
	var up: Vector3 = m["up"]
	return center + forward * forward_offset + up * (DECK_THICKNESS * 0.5)

# Axis-aligned bounding box of the whole track in world coords (deck + walls,
# approx). Used by the camera to frame everything.
func track_bounds() -> AABB:
	_ensure_meta()
	var bb := AABB()
	var first := true
	for m: Dictionary in _meta:
		var center: Vector3 = m["center"]
		var right: Vector3 = m["right"]
		var up: Vector3 = m["up"]
		var forward: Vector3 = m["forward"]
		var half_len: float = float(m["length"]) * 0.5
		for sx in [-1, 1]:
			for sy in [0, 1]:
				for sz in [-1, 1]:
					var corner := center
					corner += right * (WIDTH * 0.5 * float(sx))
					corner += up * (WALL_HEIGHT * float(sy))
					corner += forward * (half_len * float(sz))
					if first:
						bb = AABB(corner, Vector3.ZERO)
						first = false
					else:
						bb = bb.expand(corner)
	return bb

func _ensure_meta() -> void:
	if not _meta.is_empty():
		return
	var cursor := Vector3.ZERO
	for s: Dictionary in SEGMENTS:
		var yaw_rad := deg_to_rad(float(s["yaw_deg"]))
		var tilt_rad := deg_to_rad(-float(s["tilt_deg"]))
		# Yaw around world Y, then tilt around the yawed local X axis.
		var yaw_basis := Basis(Vector3.UP, yaw_rad)
		var tilt_basis := Basis(Vector3(1, 0, 0), tilt_rad)
		var basis := yaw_basis * tilt_basis
		var forward: Vector3 = basis * Vector3(0, 0, -1)  # segment's local -Z = downhill in world
		var right: Vector3 = basis * Vector3(1, 0, 0)
		var up: Vector3 = basis * Vector3(0, 1, 0)
		var length := float(s["length"])
		var center := cursor + forward * (length * 0.5)
		_meta.append({
			"center": center,
			"basis": basis,
			"forward": forward,
			"right": right,
			"up": up,
			"length": length,
		})
		cursor += forward * length
