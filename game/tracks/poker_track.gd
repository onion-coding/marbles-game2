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

const COURSE_LEN := 80.0           # X span between shoe and pot — long mini-golf course
const COURSE_WIDTH := 14.0         # Z span
const FELT_TILT_DEG := 0.0         # vertical orientation: gravity now aligns with the race
                                    # direction post-root-rotation; the felt-tilt that drove
                                    # the original horizontal mode is no longer needed.

# Y of the felt's top surface at x=0 (track is locally flat; tilt rotates the
# whole table around the world Z axis for the downhill effect).
const TABLE_TOP_Y := 0.0
const TABLE_THICKNESS := 0.4
const RAIL_HEIGHT := 1.4
const RAIL_THICKNESS := 0.3

# ─── Spawn (inside the dealer shoe) ───────────────────────────────────────
const SHOE_X := -38.0
# After the vertical root rotation, old +Y maps to world +Z (depth). With
# SHOE_Y_BASE = 1.0, the shoe (and the spawn points inside it) sits 1 m
# in front of the back wall — well within the play depth and ahead of
# the chips/cards/wheels at z≈0.5-1.6.
const SHOE_Y_BASE := 1.0
const SHOE_LEN := 4.0
const SHOE_INNER_W := 1.6
const SHOE_INNER_H := 1.0
const SHOE_TILT_DEG := 0.0         # tilt no longer needed; gravity does the launching now

# Spawn 24 points inside the shoe in a 6×4 grid.
const SPAWN_GRID_COLS := 6
const SPAWN_GRID_ROWS := 4
const SPAWN_GRID_DX := 0.5
const SPAWN_GRID_DZ := 0.4

# ─── Chip-stack funnels ───────────────────────────────────────────────────
# Two staggered rows of chip-stacks form gates that marbles must thread.
const CHIP_RADIUS := 0.4
const CHIP_HEIGHT := 1.6
# Six staggered chip-stack rows along the long table, alternating offsets
# so a marble can never follow a single straight Z column.
const CHIP_ROWS := [
	{"x": -30.0, "zs": [-5.0, -2.0,  1.0,  4.0]},
	{"x": -25.0, "zs": [-4.0, -1.0,  2.0,  5.0]},
	{"x": -20.0, "zs": [-5.5, -2.5,  0.5,  3.5]},
	{"x": -15.0, "zs": [-3.5, -0.5,  2.5,  5.5]},
	{"x":  -8.0, "zs": [-5.0, -2.0,  1.0,  4.0]},
	{"x":  18.0, "zs": [-4.5, -1.5,  1.5,  4.5]},
	{"x":  25.0, "zs": [-5.0, -2.0,  1.0,  4.0]},
]

# ─── Flipping cards (kinematic see-saws) ─────────────────────────────────
# Each card is a flat box pivoting on its short edge. The pivot axis is along
# world Z (across the course); the card tilts ±FLIP_AMP_DEG around that axis.
# Rotation: angle(t) = amp * sin(2π * t / period_ticks + phase)
const CARD_COUNT := 10
const CARD_LEN := 3.5              # along X (course direction)
const CARD_WIDTH := 5.0            # along Z (wider so marbles can't all slip past at one Z)
const CARD_THICKNESS := 0.18
const CARD_FLIP_AMP_DEG := 28.0
const CARD_PERIOD_BASE_TICKS := 360   # 6s at 60Hz; slower flips for the longer course
const CARD_PERIOD_JITTER := 120       # ±2s
const CARD_X_STEP := 4.0
const CARD_X_START := -10.0
const CARD_PIVOT_HEIGHT := 0.8

# ─── Decorative community cards (visual only) ────────────────────────────
# Behind the rails, on a side pedestal — flop/turn/river. No collision.
const COMMUNITY_X := 6.0
const COMMUNITY_Z := -6.6
const COMMUNITY_Y := 1.5
const COMMUNITY_COUNT := 5

# ─── Finish (pot) ─────────────────────────────────────────────────────────
const FINISH_X := 38.0
const FINISH_BOX_SIZE := Vector3(1.0, 5.0, COURSE_WIDTH)
const POT_RADIUS := 3.5
const POT_HEIGHT := 0.6

# ─── Physics materials ───────────────────────────────────────────────────
const FELT_FRICTION := 0.75
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

# ─── Vertical orientation (root rotation) ────────────────────────────────
# Same logic as CrapsTrack: rigid-rotate the whole track so the original
# +X (downhill) axis aligns with world -Y (gravity). Marbles fall along
# the original race direction under gravity instead of rolling on a
# tilted felt; camera looks at the back wall frontally.
const ROOT_OFFSET_Y := 44.0

# Per-wheel rotation phases cached from server_seed.
var _chip_wheels: Array[AnimatableBody3D] = []
var _chip_wheel_phases: Array = []
var _chip_wheel_mat: PhysicsMaterial = null

# Slow-motion gravity zone. After the vertical root rotation, gravity does
# all the work and the race naturally completes in ~6 s over 80 m of drop.
# To stretch it back into the 40-50 s "watchable race" window the user
# wants, we drop the gravity inside the play volume to ~5 % of normal.
# Marbles still fall, but visually it reads as "slow-motion" instead of
# "freefall".
const SLOW_GRAVITY_ACCEL := 0.25     # m/s² (~2.5 % of project default 9.8) — produces
                                      # ~42 s race over the 80 m drop with the chip rows,
                                      # cards, and chip wheels deflecting marbles.

# Spinning chip wheels — three large rotating discs with peg-chips on
# the rim, scattered between the existing chip rows / cards. Same idea
# as CrapsTrack v2 (rim-pegs sweep through the play volume) but tinted
# blue here for visual differentiation against the green felt.
const CHIP_WHEEL_COUNT := 3
const CHIP_WHEEL_RADIUS := 2.2
const CHIP_WHEEL_THICKNESS := 0.32
const CHIP_WHEEL_PEG_COUNT := 6
const CHIP_WHEEL_PEG_RADIUS := 0.28
const CHIP_WHEEL_PEG_LENGTH := 1.10
const CHIP_WHEEL_PEG_RIM_OFFSET := 1.85
const CHIP_WHEEL_FRICTION := 0.40
const CHIP_WHEEL_BOUNCE := 0.35

# Old-coords positions, between existing chip rows along the course.
const CHIP_WHEEL_POSITIONS := [
	Vector3(-22.0, 0.5,  0.0),    # between pre-card chip rows
	Vector3(  4.0, 0.5,  3.5),    # mid-card-row, side-offset
	Vector3( 22.0, 0.5,  0.0),    # past the cards, before the pot
]
const CHIP_WHEEL_W := [-0.038, 0.045, -0.040]    # rad/tick

var _root_transform: Transform3D = Transform3D.IDENTITY

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
	_init_chip_wheel_phases()
	_build_chip_wheels()
	_build_slow_gravity_zone()
	_build_mood_light()

	# Stand the whole track up. Same root rotation as CrapsTrack so the
	# orientation convention is consistent between the two long-table tracks.
	_ensure_root_transform()
	transform = _root_transform

func _ensure_root_transform() -> void:
	if _root_transform != Transform3D.IDENTITY:
		return
	var b1 := Basis(Vector3(1, 0, 0), PI / 2)        # +Y → +Z, +Z → -Y
	var b2 := Basis(Vector3(0, 0, 1), -PI / 2)       # +X → -Y, +Y → +X
	_root_transform = Transform3D(b2 * b1, Vector3(0, ROOT_OFFSET_Y, 0))

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
	for i in range(_chip_wheels.size()):
		_apply_chip_wheel_pose(i, float(_local_tick))

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

	_chip_wheel_mat = PhysicsMaterial.new()
	_chip_wheel_mat.friction = CHIP_WHEEL_FRICTION
	_chip_wheel_mat.bounce = CHIP_WHEEL_BOUNCE

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

	# Front cover (collision-only, no mesh) — same trick as CrapsTrack.
	# After the root rotation, this slab sits 3 m in front of the back
	# wall along world +Z, catching marbles that bounce off cards / chips
	# / wheels toward the camera.
	var front_coll := CollisionShape3D.new()
	front_coll.name = "FrontCover_shape"
	var front_box := BoxShape3D.new()
	front_box.size = Vector3(COURSE_LEN, 0.2, COURSE_WIDTH)
	front_coll.shape = front_box
	front_coll.transform = Transform3D(Basis.IDENTITY, Vector3(0, 3.0, 0))
	table.add_child(front_coll)

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
	face_mat.roughness = 0.20
	face_mat.metallic_specular = 0.7

	for i in range(CARD_COUNT):
		var x_local: float = CARD_X_START + float(i) * CARD_X_STEP
		# Pivot pos in tilted-local frame: above the felt at this x.
		var pivot_local := Vector3(x_local, CARD_PIVOT_HEIGHT, 0.0)
		var pivot_world := _tilt_basis * pivot_local

		var card := AnimatableBody3D.new()
		card.name = "Card_%d" % i
		card.physics_material_override = _card_mat
		card.sync_to_physics = true
		card.transform = Transform3D(_tilt_basis, pivot_world)
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
	_cards[i].transform = Transform3D(basis, pivot)

# ─── Pot (finish décor) ──────────────────────────────────────────────────

func _build_pot() -> void:
	var pot_mat := StandardMaterial3D.new()
	pot_mat.albedo_color = COLOR_POT
	pot_mat.metallic = 0.85
	pot_mat.metallic_specular = 0.9
	pot_mat.roughness = 0.25
	pot_mat.emission_enabled = true
	pot_mat.emission = COLOR_POT
	pot_mat.emission_energy_multiplier = 0.35

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

# ─── Chip wheels (kinematic spinning discs with peg-chips on the rim) ────
# Same surprise pattern as CrapsTrack v3 — three rotating discs with rim
# pegs that sweep the play volume. Pegs are blue here for theme.

func _init_chip_wheel_phases() -> void:
	for i in range(CHIP_WHEEL_COUNT):
		var raw := _hash_with_tag("wheel_%d" % i)
		_chip_wheel_phases.append(float(raw[0]) / 255.0 * TAU)

func _build_chip_wheels() -> void:
	var disc_mat := StandardMaterial3D.new()
	disc_mat.albedo_color = Color(0.85, 0.72, 0.25)   # gold disc (matches Craps for visual continuity)
	disc_mat.metallic = 0.85
	disc_mat.metallic_specular = 0.85
	disc_mat.roughness = 0.30
	disc_mat.emission_enabled = true
	disc_mat.emission = Color(0.85, 0.72, 0.25)
	disc_mat.emission_energy_multiplier = 0.30

	var peg_mat := StandardMaterial3D.new()
	peg_mat.albedo_color = COLOR_CHIP_BLUE                # blue chips (Poker theme)
	peg_mat.metallic = 0.40
	peg_mat.roughness = 0.40
	peg_mat.emission_enabled = true
	peg_mat.emission = COLOR_CHIP_BLUE
	peg_mat.emission_energy_multiplier = 0.30

	for i in range(CHIP_WHEEL_COUNT):
		var pos: Vector3 = CHIP_WHEEL_POSITIONS[i]
		var wheel := AnimatableBody3D.new()
		wheel.name = "ChipWheel_%d" % i
		wheel.physics_material_override = _chip_wheel_mat
		wheel.sync_to_physics = true
		wheel.transform = Transform3D(Basis.IDENTITY, pos)
		add_child(wheel)

		var disc_coll := CollisionShape3D.new()
		var disc_shape := CylinderShape3D.new()
		disc_shape.radius = CHIP_WHEEL_RADIUS
		disc_shape.height = CHIP_WHEEL_THICKNESS
		disc_coll.shape = disc_shape
		wheel.add_child(disc_coll)

		var disc_mesh := MeshInstance3D.new()
		var disc_cyl := CylinderMesh.new()
		disc_cyl.top_radius = CHIP_WHEEL_RADIUS
		disc_cyl.bottom_radius = CHIP_WHEEL_RADIUS
		disc_cyl.height = CHIP_WHEEL_THICKNESS
		disc_mesh.mesh = disc_cyl
		disc_mesh.material_override = disc_mat
		wheel.add_child(disc_mesh)

		var peg_y_centre: float = CHIP_WHEEL_THICKNESS * 0.5 + CHIP_WHEEL_PEG_LENGTH * 0.5
		for k in range(CHIP_WHEEL_PEG_COUNT):
			var theta: float = TAU * float(k) / float(CHIP_WHEEL_PEG_COUNT)
			var peg_pos := Vector3(
				cos(theta) * CHIP_WHEEL_PEG_RIM_OFFSET,
				peg_y_centre,
				sin(theta) * CHIP_WHEEL_PEG_RIM_OFFSET,
			)
			var peg_coll := CollisionShape3D.new()
			var peg_shape := CylinderShape3D.new()
			peg_shape.radius = CHIP_WHEEL_PEG_RADIUS
			peg_shape.height = CHIP_WHEEL_PEG_LENGTH
			peg_coll.shape = peg_shape
			peg_coll.transform = Transform3D(Basis.IDENTITY, peg_pos)
			wheel.add_child(peg_coll)

			var peg_mesh := MeshInstance3D.new()
			var peg_cyl := CylinderMesh.new()
			peg_cyl.top_radius = CHIP_WHEEL_PEG_RADIUS
			peg_cyl.bottom_radius = CHIP_WHEEL_PEG_RADIUS
			peg_cyl.height = CHIP_WHEEL_PEG_LENGTH
			peg_mesh.mesh = peg_cyl
			peg_mesh.material_override = peg_mat
			peg_mesh.transform = Transform3D(Basis.IDENTITY, peg_pos)
			wheel.add_child(peg_mesh)

		_chip_wheels.append(wheel)
		_apply_chip_wheel_pose(i, 0.0)

func _apply_chip_wheel_pose(i: int, t: float) -> void:
	var wheel: AnimatableBody3D = _chip_wheels[i]
	var w: float = float(CHIP_WHEEL_W[i])
	var phase: float = float(_chip_wheel_phases[i])
	var angle: float = phase + w * t
	var pos: Vector3 = CHIP_WHEEL_POSITIONS[i]
	wheel.transform = Transform3D(Basis(Vector3.UP, angle), pos)

# ─── Slow-motion gravity zone ────────────────────────────────────────────

func _build_slow_gravity_zone() -> void:
	# Area3D covering the full play volume; marbles inside experience a
	# fraction of project gravity so the race reads as slow-motion. The
	# Area's collision shape is in the track's local frame, so it rotates
	# with the root rotation and stays aligned with the play volume.
	var zone := Area3D.new()
	zone.name = "SlowGravityZone"
	zone.gravity_space_override = Area3D.SPACE_OVERRIDE_REPLACE
	zone.gravity_direction = Vector3(0, -1, 0)   # always world-down regardless of zone rotation
	zone.gravity = SLOW_GRAVITY_ACCEL
	add_child(zone)

	var coll := CollisionShape3D.new()
	var box := BoxShape3D.new()
	# Cover the full course length + width with margin in old coords.
	box.size = Vector3(COURSE_LEN + 12, 6, COURSE_WIDTH + 6)
	coll.shape = box
	coll.transform = Transform3D(Basis.IDENTITY, Vector3(0, 1.5, 0))
	zone.add_child(coll)

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
	# Local-coord spawn points; _root_transform maps them to world after
	# the vertical rotation. Keeping the grid small in old X/Z avoids any
	# tilted-frame projection making marbles drift past the shoe's mouth.
	_ensure_root_transform()
	var origin := Vector3(SHOE_X, SHOE_Y_BASE, 0.0)
	var points: Array = []
	for r in range(SPAWN_GRID_ROWS):
		for c in range(SPAWN_GRID_COLS):
			var fx: float = (float(c) - float(SPAWN_GRID_COLS - 1) * 0.5) * SPAWN_GRID_DX
			var fz: float = (float(r) - float(SPAWN_GRID_ROWS - 1) * 0.5) * SPAWN_GRID_DZ
			var local := origin + Vector3(fx, 0.0, fz)
			points.append(_root_transform * local)
	return points

func finish_area_transform() -> Transform3D:
	_ensure_root_transform()
	var local := Vector3(FINISH_X, FINISH_BOX_SIZE.y * 0.5, 0)
	var local_tx := Transform3D(_tilt_basis, _tilt_basis * local)
	return _root_transform * local_tx

func finish_area_size() -> Vector3:
	return FINISH_BOX_SIZE

func camera_bounds() -> AABB:
	# Vertical play volume after the root rotation.
	var half_h: float = COURSE_LEN * 0.5 + 5.0
	var min_v := Vector3(-COURSE_WIDTH * 0.5 - 2.0, ROOT_OFFSET_Y - half_h, -3.0)
	var max_v := Vector3(COURSE_WIDTH * 0.5 + 2.0, ROOT_OFFSET_Y + half_h, 4.0)
	return AABB(min_v, max_v - min_v)

func camera_pose() -> Dictionary:
	# Frontal view of the now-vertical course. Camera in front of the back
	# wall (+Z), centred horizontally at the play volume's midpoint.
	return {
		"position": Vector3(0, ROOT_OFFSET_Y, 65),
		"target": Vector3(0, ROOT_OFFSET_Y, 0),
		"fov": 70.0,
	}

func environment_overrides() -> Dictionary:
	# Cardroom mood pulled out of the fog + sun rather than the sky;
	# letting the daylight cloud shader render unmodified avoids the
	# muddy interaction the dark-green sky used to produce.
	return {
		"ambient_energy": 0.60,
		"fog_color": Color(0.55, 0.70, 0.45),
		"fog_density": 0.002,
		"sun_color": Color(1.0, 0.85, 0.60),
	}
