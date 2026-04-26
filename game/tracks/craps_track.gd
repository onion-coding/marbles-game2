class_name CrapsTrack
extends Track

# M6.2 — Craps. Marbles enter at the "come" end of a long downhill felt table,
# weave between rolling dice and chip-stack obstacles, ricochet off pyramid
# rubber rails along the back, and finish at the stickman's chip rack.
#
# Determinism story: the dice are kinematic AnimatableBody3Ds whose tumbling
# motion is a pure function of (server_seed, round_id, tick). They never
# accumulate physics state — each tick we recompute the pose from a closed-form
# expression seeded once in _ready. This way:
#   - The sim sees physically-meaningful kinematic bodies that push marbles.
#   - The playback scene rebuilds an identical track and animates the dice on
#     the same closed-form curve, so what the viewer sees lines up with the
#     recorded marble paths even though no replay state is stored for the dice.
#
# Hazard: the dice cross the marble path at irregular intervals derived from
# the seed, so each round looks different but is replay-stable.
#
# See docs/bugfixes.md "nested-PhysicsBody3D hang": every body uses sibling
# CollisionShape3D + MeshInstance3D children, never another body.

# ─── Table ────────────────────────────────────────────────────────────────
const TABLE_LEN := 36.0          # X-extent (race direction = +X)
const TABLE_WIDTH := 14.0        # Z-extent
const TABLE_TILT_DEG := 9.0      # downhill tilt around Z. Combined with FELT_FRICTION
                                  # 0.55 keeps marbles moving but slow enough for ~25-35s races.
const TABLE_THICKNESS := 0.4
const TABLE_RAIL_HEIGHT := 1.6
const TABLE_RAIL_THICKNESS := 0.3

# Felt physics: grippy, low bounce.
const FELT_FRICTION := 0.55
const FELT_BOUNCE := 0.10

# Wood rail physics: medium grip, low bounce.
const WOOD_FRICTION := 0.45
const WOOD_BOUNCE := 0.20

# ─── Spawn ────────────────────────────────────────────────────────────────
# 24 spawn points clustered at the uphill end (+X = downhill, so spawn at -X).
const SPAWN_X := -16.0
const SPAWN_Y := 8.0
const SPAWN_GRID_COLS := 6
const SPAWN_GRID_ROWS := 4
const SPAWN_SPREAD_X := 1.5
const SPAWN_SPREAD_Z := 8.0

# ─── Chip-stack obstacles ─────────────────────────────────────────────────
# Three rows of chip-stacks force lane discipline mid-table.
const CHIP_RADIUS := 0.45
const CHIP_HEIGHT := 1.4
# Five rows of chip-stacks across the table at staggered Z offsets — each row
# breaks the line marbles would otherwise follow, forcing a slalom that adds
# real time to each crossing.
const CHIP_ROW_X := [-10.0, -5.5, -1.0, 3.5, 8.0]
const CHIP_ROW_OFFSETS := [
	[-5.0, -2.0, 1.0, 4.0],
	[-3.5, -0.5, 2.5, 5.5],
	[-4.5, -1.5, 1.5, 4.5],
	[-3.0, 0.0, 3.0, 6.0],
	[-5.5, -2.5, 0.5, 3.5],
]

# ─── Pyramid rubber back wall ─────────────────────────────────────────────
# A jagged sawtooth row before the finish; deflects marbles unpredictably.
# Tooth count chosen so the gap between adjacent teeth is wider than a
# marble (radius 0.3 → 0.6 diameter). With TABLE_WIDTH=14 and 5 teeth, gaps
# average 14/5 - tooth_diagonal = 2.8 - 1.7 = 1.1m: marbles thread through.
const PYRAMID_X := 13.0
const PYRAMID_TOOTH_COUNT := 5
const PYRAMID_TOOTH_HALF_WIDTH := 0.55
const PYRAMID_TOOTH_HEIGHT := 1.2
const PYRAMID_FRICTION := 0.35
const PYRAMID_BOUNCE := 0.55

# ─── Dice (kinematic obstacles) ───────────────────────────────────────────
# Each die is a kinematic cube whose centre travels along a closed-form path:
#   x(t) = x0 + ax * sin(wx * t + px)
#   z(t) = z0 + az * sin(wz * t + pz)
# with parameters drawn from server_seed via _hash_with_tag("dice_<i>").
# Tumbling rotation is also closed-form, three independent angles each tick.
# Centre Y is held just above the table felt at that x, so the die slides on
# the felt rather than floating.
const DICE_COUNT := 3
const DICE_HALF_EXTENT := 0.6     # half-edge of the cube (so edge length 1.2 m)
const DICE_PATH_HALF_WIDTH := 5.5  # |z| amplitude
const DICE_PATH_X_AMP := 3.5       # along-table wiggle
# Centre frequency around which per-die frequencies cluster (rad / tick).
# At 60 Hz physics, w = 0.06 → period ~ 105 ticks ~ 1.75s. Low-frequency
# enough to be readable, high-frequency enough to vary.
const DICE_W_BASE := 0.07
const DICE_FRICTION := 0.55
const DICE_BOUNCE := 0.35

# ─── Finish ───────────────────────────────────────────────────────────────
const FINISH_X := 17.0
const FINISH_BOX_SIZE := Vector3(1.0, 6.0, TABLE_WIDTH)

# ─── Materials ────────────────────────────────────────────────────────────
const COLOR_FELT := Color(0.06, 0.32, 0.10)
const COLOR_WOOD := Color(0.30, 0.13, 0.06)
const COLOR_RUBBER := Color(0.55, 0.13, 0.13)
const COLOR_CHIP := Color(0.93, 0.85, 0.20)
const COLOR_DICE := Color(0.92, 0.92, 0.92)
const COLOR_PIP := Color(0.05, 0.05, 0.05)

# ─── Internal state ───────────────────────────────────────────────────────
var _felt_mat: PhysicsMaterial = null
var _wood_mat: PhysicsMaterial = null
var _rubber_mat: PhysicsMaterial = null
var _dice_mat: PhysicsMaterial = null

# Per-die motion parameters cached from server_seed.
var _dice_bodies: Array[AnimatableBody3D] = []
var _dice_params: Array = []   # array of dictionaries: {x0,z0,ax,az,wx,wz,px,pz, rx,ry,rz}

# Table tilt basis applied to the whole course (everything sits on the tilted
# felt). Cached so dice motion code can use the same frame.
var _tilt_basis: Basis = Basis.IDENTITY

func _ready() -> void:
	_init_materials()
	_tilt_basis = Basis(Vector3(0, 0, 1), -deg_to_rad(TABLE_TILT_DEG))
	_build_table()
	_build_chip_stacks()
	_build_pyramid_wall()
	_init_dice_params()
	_build_dice()
	_build_mood_light()

func _build_mood_light() -> void:
	# Warm gold key light from above-X to give the table a casino-pit mood
	# that contrasts with the entry scene's cool sky ambient.
	var light := OmniLight3D.new()
	light.name = "MoodLight"
	light.light_color = Color(1.0, 0.92, 0.7)
	light.light_energy = 1.6
	light.omni_range = 60.0
	light.position = Vector3(0, 12, 0)
	add_child(light)

func _physics_process(_delta: float) -> void:
	# Drive each kinematic die to its closed-form pose for this tick. We work
	# in the table's tilted-local frame (felt top at y=0), then apply the
	# table tilt to get world coords. Tick counter is local to this track so
	# replays starting at any engine time produce identical motion.
	_local_tick += 1
	for i in range(_dice_bodies.size()):
		_apply_dice_pose(i, float(_local_tick))

func _apply_dice_pose(i: int, t: float) -> void:
	var body: AnimatableBody3D = _dice_bodies[i]
	var p: Dictionary = _dice_params[i]
	var x: float = float(p["x0"]) + float(p["ax"]) * sin(float(p["wx"]) * t + float(p["px"]))
	var z: float = float(p["z0"]) + float(p["az"]) * sin(float(p["wz"]) * t + float(p["pz"]))
	var local_pos := Vector3(x, DICE_HALF_EXTENT + 0.05, z)
	var rx: float = float(p["rx"]) * t
	var ry: float = float(p["ry"]) * t
	var rz: float = float(p["rz"]) * t
	var local_rot := Basis(Vector3.RIGHT, rx) * Basis(Vector3.UP, ry) * Basis(Vector3.FORWARD, rz)
	body.global_transform = Transform3D(_tilt_basis * local_rot, _tilt_basis * local_pos)

var _local_tick: int = -1

# ─── Materials ────────────────────────────────────────────────────────────

func _init_materials() -> void:
	_felt_mat = PhysicsMaterial.new()
	_felt_mat.friction = FELT_FRICTION
	_felt_mat.bounce = FELT_BOUNCE

	_wood_mat = PhysicsMaterial.new()
	_wood_mat.friction = WOOD_FRICTION
	_wood_mat.bounce = WOOD_BOUNCE

	_rubber_mat = PhysicsMaterial.new()
	_rubber_mat.friction = PYRAMID_FRICTION
	_rubber_mat.bounce = PYRAMID_BOUNCE

	_dice_mat = PhysicsMaterial.new()
	_dice_mat.friction = DICE_FRICTION
	_dice_mat.bounce = DICE_BOUNCE

# ─── Table (felt + rails) ────────────────────────────────────────────────

func _build_table() -> void:
	var felt_mat := StandardMaterial3D.new()
	felt_mat.albedo_color = COLOR_FELT
	felt_mat.roughness = 0.85

	var wood_mat := StandardMaterial3D.new()
	wood_mat.albedo_color = COLOR_WOOD
	wood_mat.roughness = 0.7

	var table := StaticBody3D.new()
	table.name = "Table"
	table.physics_material_override = _felt_mat
	table.transform = Transform3D(_tilt_basis, Vector3.ZERO)
	add_child(table)

	# Felt slab. Top face passes through y=0 in local space.
	_add_box(table, "Felt",
		Transform3D(Basis.IDENTITY, Vector3(0, -TABLE_THICKNESS * 0.5, 0)),
		Vector3(TABLE_LEN, TABLE_THICKNESS, TABLE_WIDTH),
		felt_mat)

	# Side rails (along X, on +/-Z edges).
	for sgn in [-1, 1]:
		var rail_z: float = float(sgn) * (TABLE_WIDTH * 0.5 + TABLE_RAIL_THICKNESS * 0.5)
		_add_box(table, "RailZ_%s" % ("pos" if sgn > 0 else "neg"),
			Transform3D(Basis.IDENTITY, Vector3(0, TABLE_RAIL_HEIGHT * 0.5, rail_z)),
			Vector3(TABLE_LEN, TABLE_RAIL_HEIGHT, TABLE_RAIL_THICKNESS),
			wood_mat)
	# End rail at uphill end so marbles can't roll off backwards.
	_add_box(table, "RailUphill",
		Transform3D(Basis.IDENTITY, Vector3(-TABLE_LEN * 0.5 - TABLE_RAIL_THICKNESS * 0.5, TABLE_RAIL_HEIGHT * 0.5, 0)),
		Vector3(TABLE_RAIL_THICKNESS, TABLE_RAIL_HEIGHT, TABLE_WIDTH + 2.0 * TABLE_RAIL_THICKNESS),
		wood_mat)

# ─── Chip stacks ─────────────────────────────────────────────────────────

func _build_chip_stacks() -> void:
	var chip_mat := StandardMaterial3D.new()
	chip_mat.albedo_color = COLOR_CHIP
	chip_mat.metallic = 0.7
	chip_mat.metallic_specular = 0.8
	chip_mat.roughness = 0.30
	chip_mat.emission_enabled = true
	chip_mat.emission = COLOR_CHIP
	chip_mat.emission_energy_multiplier = 0.20

	for r in range(CHIP_ROW_X.size()):
		var row_x: float = CHIP_ROW_X[r]
		var offsets: Array = CHIP_ROW_OFFSETS[r]
		for c in range(offsets.size()):
			var z: float = float(offsets[c])
			var pos := _on_felt(row_x, z, CHIP_HEIGHT * 0.5)
			var stack := StaticBody3D.new()
			stack.name = "Chip_%d_%d" % [r, c]
			stack.physics_material_override = _wood_mat
			stack.transform = Transform3D(_tilt_basis, pos)
			add_child(stack)

			var coll := CollisionShape3D.new()
			var shape := CylinderShape3D.new()
			shape.radius = CHIP_RADIUS
			shape.height = CHIP_HEIGHT
			coll.shape = shape
			stack.add_child(coll)

			var mesh := MeshInstance3D.new()
			var cyl := CylinderMesh.new()
			cyl.top_radius = CHIP_RADIUS
			cyl.bottom_radius = CHIP_RADIUS
			cyl.height = CHIP_HEIGHT
			mesh.mesh = cyl
			mesh.material_override = chip_mat
			stack.add_child(mesh)

# ─── Pyramid wall ────────────────────────────────────────────────────────

func _build_pyramid_wall() -> void:
	var rubber_mat := StandardMaterial3D.new()
	rubber_mat.albedo_color = COLOR_RUBBER
	rubber_mat.roughness = 0.9

	var wall := StaticBody3D.new()
	wall.name = "PyramidWall"
	wall.physics_material_override = _rubber_mat
	wall.transform = Transform3D(_tilt_basis, Vector3.ZERO)
	add_child(wall)

	var step := TABLE_WIDTH / float(PYRAMID_TOOTH_COUNT)
	for i in range(PYRAMID_TOOTH_COUNT):
		var z: float = -TABLE_WIDTH * 0.5 + step * (float(i) + 0.5)
		# Each tooth is a triangular prism approximated as a rotated thin box,
		# pointing back upstream (toward -X).
		var basis := Basis(Vector3.UP, deg_to_rad(45.0))
		var tooth_pos := Vector3(PYRAMID_X, PYRAMID_TOOTH_HEIGHT * 0.5, z)
		_add_box(wall, "Tooth_%02d" % i,
			Transform3D(basis, tooth_pos),
			Vector3(PYRAMID_TOOTH_HALF_WIDTH * 2.0, PYRAMID_TOOTH_HEIGHT, PYRAMID_TOOTH_HALF_WIDTH * 2.0),
			rubber_mat)

# ─── Dice (kinematic) ────────────────────────────────────────────────────

func _init_dice_params() -> void:
	# Pull deterministic-but-varying parameters from server_seed for each die.
	# All values are chosen to keep dice on the visible playfield.
	for i in range(DICE_COUNT):
		var raw := _hash_with_tag("dice_%d" % i)
		# Use bytes 0–7 for spatial offsets, 8–15 for frequencies, 16–23 for
		# phases, 24–29 for rotation rates. All values normalised to a
		# friendly range.
		var x0: float = (float(raw[0]) / 255.0 - 0.5) * 6.0           # ±3 m around table center
		var z0: float = (float(raw[1]) / 255.0 - 0.5) * 4.0           # ±2 m
		var ax: float = DICE_PATH_X_AMP * (0.6 + float(raw[2]) / 511.0)
		var az: float = DICE_PATH_HALF_WIDTH * (0.6 + float(raw[3]) / 511.0)
		var wx: float = DICE_W_BASE * (0.7 + float(raw[8]) / 255.0)
		var wz: float = DICE_W_BASE * (0.9 + float(raw[9]) / 255.0)
		var px: float = float(raw[16]) / 255.0 * TAU
		var pz: float = float(raw[17]) / 255.0 * TAU
		var rx: float = (float(raw[24]) / 255.0 - 0.5) * 0.3   # rad/tick — slow tumble
		var ry: float = (float(raw[25]) / 255.0 - 0.5) * 0.3
		var rz: float = (float(raw[26]) / 255.0 - 0.5) * 0.3
		_dice_params.append({
			"x0": x0, "z0": z0,
			"ax": ax, "az": az,
			"wx": wx, "wz": wz,
			"px": px, "pz": pz,
			"rx": rx, "ry": ry, "rz": rz,
		})

func _build_dice() -> void:
	var dice_mat := StandardMaterial3D.new()
	dice_mat.albedo_color = COLOR_DICE
	dice_mat.metallic = 0.10
	dice_mat.roughness = 0.35

	for i in range(DICE_COUNT):
		var body := AnimatableBody3D.new()
		body.name = "Die_%d" % i
		body.physics_material_override = _dice_mat
		# sync_to_physics=true lets Jolt infer velocity from the transform
		# delta we set each tick and transfer it to colliding marbles, so a
		# moving die actually pushes marbles instead of just blocking them.
		body.sync_to_physics = true
		add_child(body)

		var coll := CollisionShape3D.new()
		var shape := BoxShape3D.new()
		shape.size = Vector3.ONE * (DICE_HALF_EXTENT * 2.0)
		coll.shape = shape
		body.add_child(coll)

		var mesh := MeshInstance3D.new()
		var box := BoxMesh.new()
		box.size = Vector3.ONE * (DICE_HALF_EXTENT * 2.0)
		mesh.mesh = box
		mesh.material_override = dice_mat
		body.add_child(mesh)

		_dice_bodies.append(body)
		# Snap to tick-0 pose so the first frame doesn't show dice at the origin.
		_apply_dice_pose(i, 0.0)

# ─── Helpers ─────────────────────────────────────────────────────────────

# Convert a (x, z) point on the felt into the local table-frame world position
# with the right Y above the felt for the given vertical offset above the
# tilted surface. (Local Y axis is the table's "up" — the world up only after
# applying _tilt_basis at the body level.)
func _on_felt(x: float, z: float, y_above: float) -> Vector3:
	return Vector3(x, y_above, z)

func _add_box(parent: Node, node_name: String, tx: Transform3D, size: Vector3, mat: StandardMaterial3D) -> void:
	var coll := CollisionShape3D.new()
	coll.name = node_name + "_shape"
	coll.transform = tx
	var shape := BoxShape3D.new()
	shape.size = size
	coll.shape = shape
	parent.add_child(coll)

	var mesh := MeshInstance3D.new()
	mesh.name = node_name + "_mesh"
	mesh.transform = tx
	var box := BoxMesh.new()
	box.size = size
	mesh.mesh = box
	mesh.material_override = mat
	parent.add_child(mesh)

# ─── Track API overrides ─────────────────────────────────────────────────

func spawn_points() -> Array:
	# 24 points (6×4 grid) above the uphill end of the table. SpawnRail adds a
	# world-Y stagger so marbles drop in sequence rather than overlapping.
	var points: Array = []
	for r in range(SPAWN_GRID_ROWS):
		for c in range(SPAWN_GRID_COLS):
			var fx: float = float(c) / float(SPAWN_GRID_COLS - 1) - 0.5
			var fz: float = float(r) / float(SPAWN_GRID_ROWS - 1) - 0.5
			points.append(Vector3(SPAWN_X + fx * SPAWN_SPREAD_X, SPAWN_Y, fz * SPAWN_SPREAD_Z))
	return points

func finish_area_transform() -> Transform3D:
	# Place the finish slab in the tilted table frame at +X end.
	var local := Vector3(FINISH_X, FINISH_BOX_SIZE.y * 0.5, 0)
	return Transform3D(_tilt_basis, _tilt_basis * local)

func finish_area_size() -> Vector3:
	return FINISH_BOX_SIZE

func camera_bounds() -> AABB:
	# Frame the whole table including spawn drop column (24 marbles staggered
	# at ~0.12m per drop_order = ~3m extra above SPAWN_Y) and finish.
	var min_v := Vector3(-TABLE_LEN * 0.5 - 2.0, -2.0, -TABLE_WIDTH * 0.5 - 2.0)
	var max_v := Vector3(FINISH_X + 4.0, SPAWN_Y + 5.0, TABLE_WIDTH * 0.5 + 2.0)
	return AABB(min_v, max_v - min_v)
