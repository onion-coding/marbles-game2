class_name PokerTrack
extends Track

# M6.3 — Poker. Marbles shoot out a dealer's shoe, ride down a felt slope past
# chip-stack funnels, cross a row of giant flipping cards (kinematic see-saws
# that catapult marbles forward or back depending on phase), and finish in
# the dealer's chip pile.
#
# Determinism story: each card's see-saw rotation is a closed-form sin curve
# whose period and phase are seeded from (server_seed, round_id) per card via
# Track._hash_with_tag. Sim and playback see identical motion. No marble
# trigger logic — cards are on a clock, not on contact (which would break
# replay because playback marbles are visual-only Node3Ds, not RigidBody3Ds
# that emit Area3D events).

# ─── Layout ────────────────────────────────────────────────────────────────
# Course runs along world +X. Spawn at the dealer shoe (-X end), finish at
# the pot (+X end).

const COURSE_LEN := 36.0           # X span between shoe and pot
const COURSE_WIDTH := 12.0         # Z span
const FELT_TILT_DEG := 9.0         # downhill tilt around Z (descend toward +X). Combined
                                    # with FELT_FRICTION 0.55 keeps races in the ~25-35s range.

# Y of the felt's top surface at x=0 (track is locally flat; tilt rotates the
# whole table around the world Z axis for the downhill effect).
const TABLE_TOP_Y := 0.0
const TABLE_THICKNESS := 0.4
const RAIL_HEIGHT := 1.4
const RAIL_THICKNESS := 0.3

# ─── Spawn (inside the dealer shoe) ───────────────────────────────────────
const SHOE_X := -16.0
const SHOE_Y_BASE := 5.0
const SHOE_LEN := 4.0
const SHOE_INNER_W := 1.6
const SHOE_INNER_H := 1.0
const SHOE_TILT_DEG := 35.0        # nose-down to launch marbles forward

# Spawn 24 points inside the shoe in a 6×4 grid.
const SPAWN_GRID_COLS := 6
const SPAWN_GRID_ROWS := 4
const SPAWN_GRID_DX := 0.5
const SPAWN_GRID_DZ := 0.4

# ─── Chip-stack funnels ───────────────────────────────────────────────────
# Two staggered rows of chip-stacks form gates that marbles must thread.
const CHIP_RADIUS := 0.4
const CHIP_HEIGHT := 1.6
const CHIP_ROWS := [
	{"x": -8.0, "zs": [-4.0, -1.0, 1.0, 4.0]},
	{"x": -4.5, "zs": [-3.0, 0.0, 3.0]},
]

# ─── Flipping cards (kinematic see-saws) ─────────────────────────────────
# Each card is a flat box pivoting on its short edge. The pivot axis is along
# world Z (across the course); the card tilts ±FLIP_AMP_DEG around that axis.
# Rotation: angle(t) = amp * sin(2π * t / period_ticks + phase)
const CARD_COUNT := 6
const CARD_LEN := 3.5              # along X (course direction)
const CARD_WIDTH := 4.5            # along Z (wider so marbles can't all slip past at one Z)
const CARD_THICKNESS := 0.18
const CARD_FLIP_AMP_DEG := 30.0
const CARD_PERIOD_BASE_TICKS := 300   # 5s at 60Hz; per-card jitter from seed
const CARD_PERIOD_JITTER := 90        # ±1.5s
const CARD_X_STEP := 3.8              # spacing along the course
const CARD_X_START := -2.0            # first card placed earlier in the course
const CARD_PIVOT_HEIGHT := 0.8

# ─── Decorative community cards (visual only) ────────────────────────────
# Behind the rails, on a side pedestal — flop/turn/river. No collision.
const COMMUNITY_X := 6.0
const COMMUNITY_Z := -6.6
const COMMUNITY_Y := 1.5
const COMMUNITY_COUNT := 5

# ─── Finish (pot) ─────────────────────────────────────────────────────────
const FINISH_X := 17.5
const FINISH_BOX_SIZE := Vector3(1.0, 5.0, COURSE_WIDTH)
const POT_RADIUS := 3.5
const POT_HEIGHT := 0.6

# ─── Physics materials ───────────────────────────────────────────────────
const FELT_FRICTION := 0.55
const FELT_BOUNCE := 0.10
const CARD_FRICTION := 0.18        # slippery — card surface
const CARD_BOUNCE := 0.30
const WOOD_FRICTION := 0.4
const WOOD_BOUNCE := 0.20
const CHIP_FRICTION := 0.45
const CHIP_BOUNCE := 0.25

# ─── Colors ──────────────────────────────────────────────────────────────
const COLOR_FELT := Color(0.05, 0.30, 0.10)
const COLOR_RAIL := Color(0.28, 0.12, 0.05)
const COLOR_BRASS := Color(0.85, 0.72, 0.25)
const COLOR_CHIP_RED := Color(0.85, 0.18, 0.16)
const COLOR_CHIP_BLUE := Color(0.10, 0.30, 0.85)
const COLOR_CARD_BACK := Color(0.85, 0.10, 0.10)
const COLOR_CARD_FACE := Color(0.95, 0.95, 0.92)
const COLOR_POT := Color(0.85, 0.72, 0.25)

# ─── Internal state ──────────────────────────────────────────────────────
var _felt_mat: PhysicsMaterial = null
var _wood_mat: PhysicsMaterial = null
var _card_mat: PhysicsMaterial = null
var _chip_mat: PhysicsMaterial = null

var _tilt_basis: Basis = Basis.IDENTITY

var _cards: Array[AnimatableBody3D] = []
# Per-card pivot world position + sin-curve params: {pivot, period, phase}
var _card_params: Array = []
var _local_tick: int = -1

func _ready() -> void:
	_init_materials()
	_tilt_basis = Basis(Vector3(0, 0, 1), -deg_to_rad(FELT_TILT_DEG))
	_build_table()
	_build_dealer_shoe()
	_build_chip_stacks()
	_init_card_params()
	_build_cards()
	_build_pot()
	_build_community_cards()
	_build_mood_light()

func _build_mood_light() -> void:
	# Warm pendant-light mood — the giant lamp over a card table.
	var light := OmniLight3D.new()
	light.name = "MoodLight"
	light.light_color = Color(1.0, 0.85, 0.55)
	light.light_energy = 2.0
	light.omni_range = 50.0
	light.position = Vector3(0, 8, 0)
	add_child(light)

func _physics_process(_delta: float) -> void:
	_local_tick += 1
	for i in range(_cards.size()):
		_apply_card_pose(i, float(_local_tick))

# ─── Materials ────────────────────────────────────────────────────────────

func _init_materials() -> void:
	_felt_mat = PhysicsMaterial.new()
	_felt_mat.friction = FELT_FRICTION
	_felt_mat.bounce = FELT_BOUNCE

	_wood_mat = PhysicsMaterial.new()
	_wood_mat.friction = WOOD_FRICTION
	_wood_mat.bounce = WOOD_BOUNCE

	_card_mat = PhysicsMaterial.new()
	_card_mat.friction = CARD_FRICTION
	_card_mat.bounce = CARD_BOUNCE

	_chip_mat = PhysicsMaterial.new()
	_chip_mat.friction = CHIP_FRICTION
	_chip_mat.bounce = CHIP_BOUNCE

# ─── Table (felt + rails) ────────────────────────────────────────────────

func _build_table() -> void:
	var felt_mat := StandardMaterial3D.new()
	felt_mat.albedo_color = COLOR_FELT
	felt_mat.roughness = 0.85

	var rail_mat := StandardMaterial3D.new()
	rail_mat.albedo_color = COLOR_RAIL

	var table := StaticBody3D.new()
	table.name = "Table"
	table.physics_material_override = _felt_mat
	table.transform = Transform3D(_tilt_basis, Vector3.ZERO)
	add_child(table)

	# Felt slab.
	_add_box(table, "Felt",
		Transform3D(Basis.IDENTITY, Vector3(0, -TABLE_THICKNESS * 0.5, 0)),
		Vector3(COURSE_LEN, TABLE_THICKNESS, COURSE_WIDTH),
		felt_mat)

	# Side rails along X (on +/-Z).
	for sgn in [-1, 1]:
		var z: float = float(sgn) * (COURSE_WIDTH * 0.5 + RAIL_THICKNESS * 0.5)
		_add_box(table, "Rail_%s" % ("pos" if sgn > 0 else "neg"),
			Transform3D(Basis.IDENTITY, Vector3(0, RAIL_HEIGHT * 0.5, z)),
			Vector3(COURSE_LEN, RAIL_HEIGHT, RAIL_THICKNESS),
			rail_mat)

# ─── Dealer shoe (start launcher) ────────────────────────────────────────

func _build_dealer_shoe() -> void:
	var shoe_mat := StandardMaterial3D.new()
	shoe_mat.albedo_color = COLOR_RAIL
	shoe_mat.roughness = 0.4

	var shoe := StaticBody3D.new()
	shoe.name = "DealerShoe"
	shoe.physics_material_override = _wood_mat
	# Tilt the shoe nose-down toward +X. Same Z axis as table tilt so the
	# combined effect is "felt slopes downhill, shoe slopes more steeply
	# downhill". Shoe sits at -X end above the felt.
	var shoe_tilt := Basis(Vector3(0, 0, 1), -deg_to_rad(SHOE_TILT_DEG))
	shoe.transform = Transform3D(shoe_tilt, Vector3(SHOE_X, SHOE_Y_BASE, 0))
	add_child(shoe)

	# Inside is a U-channel. Build floor + two side walls.
	_add_box(shoe, "ShoeFloor",
		Transform3D(Basis.IDENTITY, Vector3(0, -SHOE_INNER_H * 0.5, 0)),
		Vector3(SHOE_LEN, 0.2, SHOE_INNER_W + 0.4),
		shoe_mat)
	for sgn in [-1, 1]:
		var z: float = float(sgn) * (SHOE_INNER_W * 0.5 + 0.1)
		_add_box(shoe, "ShoeWall_%s" % ("pos" if sgn > 0 else "neg"),
			Transform3D(Basis.IDENTITY, Vector3(0, -SHOE_INNER_H * 0.25, z)),
			Vector3(SHOE_LEN, SHOE_INNER_H, 0.2),
			shoe_mat)

# ─── Chip stacks ─────────────────────────────────────────────────────────

func _build_chip_stacks() -> void:
	var red_mat := StandardMaterial3D.new()
	red_mat.albedo_color = COLOR_CHIP_RED
	var blue_mat := StandardMaterial3D.new()
	blue_mat.albedo_color = COLOR_CHIP_BLUE

	for r in range(CHIP_ROWS.size()):
		var row: Dictionary = CHIP_ROWS[r]
		var x: float = float(row["x"])
		var zs: Array = row["zs"]
		for c in range(zs.size()):
			var z: float = float(zs[c])
			var local_pos := Vector3(x, CHIP_HEIGHT * 0.5, z)
			var stack := StaticBody3D.new()
			stack.name = "ChipStack_%d_%d" % [r, c]
			stack.physics_material_override = _chip_mat
			stack.transform = Transform3D(_tilt_basis, _tilt_basis * local_pos)
			add_child(stack)

			var coll := CollisionShape3D.new()
			var cs := CylinderShape3D.new()
			cs.radius = CHIP_RADIUS
			cs.height = CHIP_HEIGHT
			coll.shape = cs
			stack.add_child(coll)

			var mesh := MeshInstance3D.new()
			var cm := CylinderMesh.new()
			cm.top_radius = CHIP_RADIUS
			cm.bottom_radius = CHIP_RADIUS
			cm.height = CHIP_HEIGHT
			mesh.mesh = cm
			mesh.material_override = (red_mat if (r + c) % 2 == 0 else blue_mat)
			stack.add_child(mesh)

# ─── Cards (kinematic flippers) ──────────────────────────────────────────

func _init_card_params() -> void:
	# For each card, derive a period jitter + phase from server_seed.
	for i in range(CARD_COUNT):
		var raw := _hash_with_tag("card_%d" % i)
		var jitter_ticks: int = (int(raw[0]) * CARD_PERIOD_JITTER * 2) / 255 - CARD_PERIOD_JITTER
		var period: int = max(60, CARD_PERIOD_BASE_TICKS + jitter_ticks)
		var phase: float = float(raw[1]) / 255.0 * TAU
		_card_params.append({"period": period, "phase": phase})

func _build_cards() -> void:
	var face_mat := StandardMaterial3D.new()
	face_mat.albedo_color = COLOR_CARD_FACE
	face_mat.roughness = 0.25

	for i in range(CARD_COUNT):
		var x_local: float = CARD_X_START + float(i) * CARD_X_STEP
		# Pivot pos in tilted-local frame: above the felt at this x.
		var pivot_local := Vector3(x_local, CARD_PIVOT_HEIGHT, 0.0)
		var pivot_world := _tilt_basis * pivot_local

		var card := AnimatableBody3D.new()
		card.name = "Card_%d" % i
		card.physics_material_override = _card_mat
		card.sync_to_physics = true
		card.global_transform = Transform3D(_tilt_basis, pivot_world)
		add_child(card)

		var coll := CollisionShape3D.new()
		var box := BoxShape3D.new()
		box.size = Vector3(CARD_LEN, CARD_THICKNESS, CARD_WIDTH)
		coll.shape = box
		# Card extends along +X from the pivot — pivot is at the card's -X edge
		# so it see-saws like a paddle. Offset the box origin half a card length.
		coll.transform = Transform3D(Basis.IDENTITY, Vector3(CARD_LEN * 0.5, 0, 0))
		card.add_child(coll)

		var mesh := MeshInstance3D.new()
		var bm := BoxMesh.new()
		bm.size = Vector3(CARD_LEN, CARD_THICKNESS, CARD_WIDTH)
		mesh.mesh = bm
		mesh.transform = Transform3D(Basis.IDENTITY, Vector3(CARD_LEN * 0.5, 0, 0))
		mesh.material_override = face_mat
		card.add_child(mesh)

		_cards.append(card)
		_card_params[i]["pivot_world"] = pivot_world
		_apply_card_pose(i, 0.0)

func _apply_card_pose(i: int, t: float) -> void:
	var p: Dictionary = _card_params[i]
	var pivot: Vector3 = p["pivot_world"]
	var period: float = float(p["period"])
	var phase: float = float(p["phase"])
	var theta: float = deg_to_rad(CARD_FLIP_AMP_DEG) * sin(TAU * t / period + phase)
	# Rotate around the pivot's local Z axis (which is the world's tilted Z).
	var rot_local := Basis(Vector3.FORWARD, theta)
	var basis := _tilt_basis * rot_local
	_cards[i].global_transform = Transform3D(basis, pivot)

# ─── Pot (finish décor) ──────────────────────────────────────────────────

func _build_pot() -> void:
	var pot_mat := StandardMaterial3D.new()
	pot_mat.albedo_color = COLOR_POT
	pot_mat.metallic = 0.6
	pot_mat.roughness = 0.4

	var pot := StaticBody3D.new()
	pot.name = "Pot"
	pot.physics_material_override = _chip_mat
	var pot_local := Vector3(FINISH_X + 1.5, POT_HEIGHT * 0.5, 0)
	pot.transform = Transform3D(_tilt_basis, _tilt_basis * pot_local)
	add_child(pot)

	# Squat cylinder pile of chips at the finish.
	var coll := CollisionShape3D.new()
	var cs := CylinderShape3D.new()
	cs.radius = POT_RADIUS
	cs.height = POT_HEIGHT
	coll.shape = cs
	pot.add_child(coll)

	var mesh := MeshInstance3D.new()
	var cm := CylinderMesh.new()
	cm.top_radius = POT_RADIUS
	cm.bottom_radius = POT_RADIUS
	cm.height = POT_HEIGHT
	mesh.mesh = cm
	mesh.material_override = pot_mat
	pot.add_child(mesh)

# ─── Community cards (decoration only) ───────────────────────────────────

func _build_community_cards() -> void:
	var face_mat := StandardMaterial3D.new()
	face_mat.albedo_color = COLOR_CARD_FACE
	face_mat.roughness = 0.4
	# A row of 5 thin boxes parented to a no-collision Node3D — purely visual.
	var holder := Node3D.new()
	holder.name = "CommunityCards"
	holder.transform = Transform3D(Basis(Vector3.UP, deg_to_rad(15)), Vector3(COMMUNITY_X, COMMUNITY_Y, COMMUNITY_Z))
	add_child(holder)
	for i in range(COMMUNITY_COUNT):
		var x: float = (float(i) - float(COMMUNITY_COUNT - 1) * 0.5) * 1.4
		var card := MeshInstance3D.new()
		card.name = "Community_%d" % i
		var bm := BoxMesh.new()
		bm.size = Vector3(1.2, 0.05, 1.8)
		card.mesh = bm
		card.material_override = face_mat
		card.transform = Transform3D(Basis.IDENTITY, Vector3(x, 0, 0))
		holder.add_child(card)

# ─── Helpers ─────────────────────────────────────────────────────────────

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
	# 24 points clustered in a small grid directly above the shoe's mouth, in
	# world coords. SpawnRail then adds a world-Y drop stagger, so marbles
	# fall straight down into the shoe under gravity. Keeping the grid small
	# in X/Z avoids any tilted-frame projection making marbles drift past the
	# shoe's open top.
	var origin := Vector3(SHOE_X, SHOE_Y_BASE + 1.0, 0.0)
	var points: Array = []
	for r in range(SPAWN_GRID_ROWS):
		for c in range(SPAWN_GRID_COLS):
			var fx: float = (float(c) - float(SPAWN_GRID_COLS - 1) * 0.5) * SPAWN_GRID_DX
			var fz: float = (float(r) - float(SPAWN_GRID_ROWS - 1) * 0.5) * SPAWN_GRID_DZ
			points.append(origin + Vector3(fx, 0.0, fz))
	return points

func finish_area_transform() -> Transform3D:
	var local := Vector3(FINISH_X, FINISH_BOX_SIZE.y * 0.5, 0)
	return Transform3D(_tilt_basis, _tilt_basis * local)

func finish_area_size() -> Vector3:
	return FINISH_BOX_SIZE

func camera_bounds() -> AABB:
	# Y max accounts for the SpawnRail drop-order stagger (~3m above the top
	# spawn row) so the marble column isn't clipped at race start.
	var min_v := Vector3(SHOE_X - 4.0, -3.0, -COURSE_WIDTH * 0.5 - 2.0)
	var max_v := Vector3(FINISH_X + 5.0, SHOE_Y_BASE + 6.0, COURSE_WIDTH * 0.5 + 2.0)
	return AABB(min_v, max_v - min_v)
