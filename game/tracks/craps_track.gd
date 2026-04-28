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
# v2: long Vegas-strip table — 60 m of felt with a gentle 5° tilt and high
# friction so a marble released at the come end takes ~40 s to traverse.
# 9 chip-stack rows force a slalom; 4 dice tumble across mid-table.
const TABLE_LEN := 90.0          # X-extent — long mini-golf-style course
const TABLE_WIDTH := 16.0        # Z-extent
const TABLE_TILT_DEG := 0.0      # vertical orientation: gravity aligns with the race
                                  # direction post-root-rotation, so the felt-tilt that
                                  # drove the original horizontal mode is no longer needed.
const TABLE_THICKNESS := 0.4
const TABLE_RAIL_HEIGHT := 1.6
const TABLE_RAIL_THICKNESS := 0.3

# Felt physics: very grippy, low bounce — keeps marbles rolling slowly.
const FELT_FRICTION := 0.75
const FELT_BOUNCE := 0.10

# Wood rail physics: medium grip, low bounce.
const WOOD_FRICTION := 0.55
const WOOD_BOUNCE := 0.20

# ─── Spawn ────────────────────────────────────────────────────────────────
# 24 spawn points at the "uphill" end (-X in local coords). After the
# vertical-orientation root rotation (see ROOT_OFFSET / _ready), local +X
# maps to world -Y (gravity), local +Y maps to world +Z (depth toward
# camera), so SPAWN_Y is the depth offset of marbles in front of the back
# wall — kept small so spawn sits just in front of the play surface.
const SPAWN_X := -42.0
const SPAWN_Y := 1.0                # depth in front of back wall
const SPAWN_GRID_COLS := 6
const SPAWN_GRID_ROWS := 4
const SPAWN_SPREAD_X := 1.5         # spreads spawn along old +X = world -Y (vertical stagger)
const SPAWN_SPREAD_Z := 9.0         # spreads spawn along old +Z = world -X (sideways)

# ─── Vertical orientation (root rotation) ────────────────────────────────
# Apply a rigid rotation to the whole track so the original "horizontal
# table" becomes a "vertical wall" the player views frontally. Marbles
# now drop along the original race direction under gravity instead of
# rolling on a tilted felt. Mapping:
#   local +X (downhill)         → world -Y (gravity)
#   local +Y (above felt)       → world +Z (depth, toward camera)
#   local +Z (across the table) → world -X (sideways)
# Decomposes as Basis(Z, -90°) * Basis(X, +90°). ROOT_OFFSET shifts the
# rotated play volume up so the finish (was old +X=42) lands near world
# Y=6 instead of Y=-42.
const ROOT_OFFSET_Y := 48.0

# ─── Chip-stack obstacles ─────────────────────────────────────────────────
# v2-split layout: chip rows split across three zones —
#   1. Pre-split (x ≤ -16): full-width chip rows (entry slalom)
#   2. +Z channel only (-12 ≤ x ≤ +8): chips on the upper half of the table.
#      The lower half is the "pin" channel (kinematic pistons, see PIN_*).
#   3. Post-funnel (x ≥ +18): full-width again, after the channels merge.
const CHIP_RADIUS := 0.45
const CHIP_HEIGHT := 1.6
const CHIP_ROW_X := [
	-36.0, -32.0, -28.0, -24.0, -20.0, -16.0,   # pre-split full-width (6 rows)
	-10.0,  -4.0,   2.0,   8.0,                 # +Z channel only (4 rows)
	 18.0,  22.0,  26.0,                         # post-funnel full-width (3 rows)
]
const CHIP_ROW_OFFSETS := [
	# pre-split full-width
	[-6.0, -3.0,  0.0,  3.0,  6.0],
	[-4.5, -1.5,  1.5,  4.5,  7.0],
	[-6.5, -3.5, -0.5,  2.5,  5.5],
	[-5.0, -2.0,  1.0,  4.0,  7.0],
	[-6.0, -3.0,  0.0,  3.0,  6.0],
	[-7.0, -4.0, -1.0,  2.0,  5.0],
	# +Z channel only (z > 0; pins occupy the mirror -Z channel)
	[ 1.5,  3.5,  5.5,  7.0],
	[ 2.5,  4.5,  6.5],
	[ 1.5,  4.0,  6.5],
	[ 2.0,  4.5,  7.0],
	# post-funnel full-width
	[-5.5, -2.5,  0.5,  3.5,  6.5],
	[-4.5, -1.5,  1.5,  4.5,  7.0],
	[-6.0, -3.0,  0.0,  3.0,  6.0],
]

# ─── Split corridor (Y-fork median + funnel merge) ────────────────────────
# A wood median wall splits the table into two parallel channels in the
# middle of the course; +Z carries chips, -Z carries kinematic pin
# pistons. After the median ends, the channels merge naturally as marbles
# continue rolling +X (no active funnel — the open table beyond x=FUNNEL_END_X
# lets +Z and -Z marbles re-mingle by the time they reach the post-funnel
# chip rows).
const SPLIT_ENTRY_X := -14.0       # median wall starts here (uphill end)
const FUNNEL_START_X := 10.0       # median wall ends here; channels merge
const MEDIAN_WALL_HEIGHT := 1.8    # 3× marble diameter — can't roll over
const MEDIAN_WALL_THICKNESS := 0.4

# ─── Pin obstacles (kinematic pistons in the -Z channel) ─────────────────
# Four boxy pistons rise and fall on a sin clock, period 90 ticks (1.5 s
# at 60 Hz). Each pin's phase is seeded from server_seed so all four
# don't move in sync — round to round, the timing of "blocker is up
# right when a marble approaches" varies per round, adding variance.
const PIN_COUNT := 4
const PIN_X_POSITIONS := [-10.0, -4.0, 2.0, 8.0]   # mirror of +Z chip x-positions
const PIN_Z := -4.0                                  # mid -Z channel
const PIN_BASE_Y := -0.9                             # centre y at fully-retracted (pin top just below felt)
const PIN_AMPLITUDE := 1.7                           # vertical sweep so pin top reaches +1.6 above felt at peak
const PIN_PERIOD_TICKS := 90
const PIN_SIZE := Vector3(0.7, 1.6, 0.7)
const PIN_FRICTION := 0.45
const PIN_BOUNCE := 0.30

# ─── Pyramid rubber back wall ─────────────────────────────────────────────
# A jagged sawtooth row before the finish; deflects marbles unpredictably.
# Tooth count chosen so the gap between adjacent teeth is wider than a
# marble (radius 0.3 → 0.6 diameter). With TABLE_WIDTH=14 and 5 teeth, gaps
# average 14/5 - tooth_diagonal = 2.8 - 1.7 = 1.1m: marbles thread through.
const PYRAMID_X := 30.0
const PYRAMID_TOOTH_COUNT := 6
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
const DICE_COUNT := 3              # 3 dice in the pre-split zone only —
                                    # mid-table is the split corridor (median + pins),
                                    # post-funnel is chip rows; dice belong to the entry
                                    # phase where they tumble across the full felt width.
const DICE_HALF_EXTENT := 0.6     # half-edge of the cube (so edge length 1.2 m)
const DICE_PATH_HALF_WIDTH := 6.5  # |z| amplitude
const DICE_PATH_X_AMP := 5.0       # along-table wiggle (smaller now; dice stay in pre-split)
# Centre frequency around which per-die frequencies cluster (rad / tick).
# At 60 Hz physics, w = 0.06 → period ~ 105 ticks ~ 1.75s. Low-frequency
# enough to be readable, high-frequency enough to vary.
const DICE_W_BASE := 0.07
const DICE_FRICTION := 0.55
const DICE_BOUNCE := 0.35

# ─── Finish ───────────────────────────────────────────────────────────────
const FINISH_X := 42.0
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
var _pin_mat: PhysicsMaterial = null

# Per-die motion parameters cached from server_seed.
var _dice_bodies: Array[AnimatableBody3D] = []
var _dice_params: Array = []   # array of dictionaries: {x0,z0,ax,az,wx,wz,px,pz, rx,ry,rz}

# Per-pin sin-clock phases cached from server_seed.
var _pins: Array[AnimatableBody3D] = []
var _pin_phases: Array = []

# Table tilt basis applied to the whole course (everything sits on the tilted
# felt). Cached so dice motion code can use the same frame.
var _tilt_basis: Basis = Basis.IDENTITY

# Root rotation applied to the whole track at the end of _ready(). All
# child geometry rotates with it; spawn_points / finish_area_transform /
# camera_pose / camera_bounds apply this transform manually since they
# return values consumed in world space.
var _root_transform: Transform3D = Transform3D.IDENTITY

func _ready() -> void:
	_init_materials()
	_tilt_basis = Basis(Vector3(0, 0, 1), -deg_to_rad(TABLE_TILT_DEG))
	_build_table()
	_build_split_corridor()
	_build_chip_stacks()
	_build_pyramid_wall()
	_init_dice_params()
	_build_dice()
	_init_pin_phases()
	_build_pins()
	_build_mood_light()

	_ensure_root_transform()
	transform = _root_transform

# Lazy-initialise the root transform so spawn_points / finish_area_transform
# / camera_pose return correctly-rotated values even when called from a
# context that doesn't add the track to the scene tree (e.g. verify_main).
func _ensure_root_transform() -> void:
	if _root_transform != Transform3D.IDENTITY:
		return
	# Stand the whole track up on its end. local +X → world -Y (gravity),
	# local +Y → world +Z (depth toward camera), local +Z → world -X.
	var b1 := Basis(Vector3(1, 0, 0), PI / 2)        # +Y → +Z, +Z → -Y
	var b2 := Basis(Vector3(0, 0, 1), -PI / 2)       # +X → -Y, +Y → +X
	_root_transform = Transform3D(b2 * b1, Vector3(0, ROOT_OFFSET_Y, 0))

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
	for i in range(_pins.size()):
		_apply_pin_pose(i, float(_local_tick))

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
	# Use LOCAL transform — root rotation propagates via parent.
	body.transform = Transform3D(_tilt_basis * local_rot, _tilt_basis * local_pos)

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

	_pin_mat = PhysicsMaterial.new()
	_pin_mat.friction = PIN_FRICTION
	_pin_mat.bounce = PIN_BOUNCE

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
	# (Old uphill end-rail removed: in vertical orientation it would become a
	# ceiling above the spawn column, trapping the SpawnRail-staggered marbles.
	# Marbles drop into play under gravity so no backward-roll guard is needed.)

	# Front cover — collision-only (no mesh) at old +Y = 3.0 above the felt.
	# After the root rotation, this slab sits 3 m in front of the back wall
	# along world +Z, catching marbles that would otherwise bounce off chips
	# toward the camera and drift out of the play volume.
	var front_coll := CollisionShape3D.new()
	front_coll.name = "FrontCover_shape"
	var front_box := BoxShape3D.new()
	front_box.size = Vector3(TABLE_LEN, 0.2, TABLE_WIDTH)
	front_coll.shape = front_box
	front_coll.transform = Transform3D(Basis.IDENTITY, Vector3(0, 3.0, 0))
	table.add_child(front_coll)

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
		# v2-split: dice are constrained to the pre-split zone only
		# (x = -34 .. -16, z = ±3). Mid-table is the split corridor (median
		# wall + pins) — letting dice wander into it would jam them against
		# the static median wall. Post-funnel is chip-stack territory.
		var x0: float = -25.0 + (float(raw[0]) / 255.0 - 0.5) * 16.0   # x in ~[-33, -17]
		var z0: float = (float(raw[1]) / 255.0 - 0.5) * 6.0           # ±3 m
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

# ─── Split corridor (median wall) ────────────────────────────────────────

func _build_split_corridor() -> void:
	var wood_mat := StandardMaterial3D.new()
	wood_mat.albedo_color = COLOR_WOOD
	wood_mat.roughness = 0.7

	var brass_accent := StandardMaterial3D.new()
	brass_accent.albedo_color = Color(0.85, 0.72, 0.25)
	brass_accent.metallic = 0.85
	brass_accent.metallic_specular = 0.85
	brass_accent.roughness = 0.30
	brass_accent.emission_enabled = true
	brass_accent.emission = Color(0.85, 0.72, 0.25)
	brass_accent.emission_energy_multiplier = 0.30

	var split := StaticBody3D.new()
	split.name = "SplitCorridor"
	split.physics_material_override = _wood_mat
	split.transform = Transform3D(_tilt_basis, Vector3.ZERO)
	add_child(split)

	# Median wall along z=0 — divides the mid-table into +Z (chips) and
	# -Z (pins) channels. Endpoints are SPLIT_ENTRY_X (uphill) and
	# FUNNEL_START_X (where the channels merge again).
	var median_len: float = FUNNEL_START_X - SPLIT_ENTRY_X
	var median_centre_x: float = (SPLIT_ENTRY_X + FUNNEL_START_X) * 0.5
	_add_box(split, "Median",
		Transform3D(Basis.IDENTITY, Vector3(median_centre_x, MEDIAN_WALL_HEIGHT * 0.5, 0)),
		Vector3(median_len, MEDIAN_WALL_HEIGHT, MEDIAN_WALL_THICKNESS),
		wood_mat)

	# Brass cap-strip on the median wall's leading edge — visual marker
	# of the split entry, looks like a "diverter post" at the fork.
	_add_box(split, "MedianLeadingEdge",
		Transform3D(Basis.IDENTITY, Vector3(SPLIT_ENTRY_X, MEDIAN_WALL_HEIGHT * 0.5 + 0.2, 0)),
		Vector3(0.6, 0.4, MEDIAN_WALL_THICKNESS + 0.2),
		brass_accent)
	_add_box(split, "MedianTrailingEdge",
		Transform3D(Basis.IDENTITY, Vector3(FUNNEL_START_X, MEDIAN_WALL_HEIGHT * 0.5 + 0.2, 0)),
		Vector3(0.6, 0.4, MEDIAN_WALL_THICKNESS + 0.2),
		brass_accent)

# ─── Pin obstacles (kinematic pistons in -Z channel) ─────────────────────

func _init_pin_phases() -> void:
	# Per-pin phase derived from server_seed so each round has a different
	# "blocker timing" pattern — same input → same pattern, but bytes
	# vary across rounds to keep the race interesting. Replay-stable.
	for i in range(PIN_COUNT):
		var raw := _hash_with_tag("pin_%d" % i)
		_pin_phases.append(float(raw[0]) / 255.0 * TAU)

func _build_pins() -> void:
	var rubber_mat := StandardMaterial3D.new()
	rubber_mat.albedo_color = COLOR_RUBBER
	rubber_mat.roughness = 0.85
	rubber_mat.emission_enabled = true
	rubber_mat.emission = Color(0.85, 0.20, 0.20)
	rubber_mat.emission_energy_multiplier = 0.25

	for i in range(PIN_COUNT):
		var pin := AnimatableBody3D.new()
		pin.name = "Pin_%d" % i
		pin.physics_material_override = _pin_mat
		pin.sync_to_physics = true
		add_child(pin)

		var coll := CollisionShape3D.new()
		var box := BoxShape3D.new()
		box.size = PIN_SIZE
		coll.shape = box
		pin.add_child(coll)

		var mesh := MeshInstance3D.new()
		var bm := BoxMesh.new()
		bm.size = PIN_SIZE
		mesh.mesh = bm
		mesh.material_override = rubber_mat
		pin.add_child(mesh)

		_pins.append(pin)
		_apply_pin_pose(i, 0.0)

func _apply_pin_pose(i: int, t: float) -> void:
	var pin: AnimatableBody3D = _pins[i]
	var x: float = float(PIN_X_POSITIONS[i])
	var phase: float = float(_pin_phases[i])
	var w: float = TAU / float(PIN_PERIOD_TICKS)
	var y: float = PIN_BASE_Y + PIN_AMPLITUDE * 0.5 * (1.0 + sin(w * t + phase))
	var local_pos := Vector3(x, y, PIN_Z)
	# Local transform so root rotation propagates via parent.
	pin.transform = Transform3D(_tilt_basis, _tilt_basis * local_pos)

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
	# 24 points (6×4 grid) above the uphill end of the table in LOCAL coords;
	# we apply _root_transform to convert to world so they match where the
	# rotated geometry actually sits. SpawnRail then adds a world-Y stagger
	# so marbles drop in sequence under gravity (which now aligns with the
	# track's race direction post-rotation).
	_ensure_root_transform()
	var points: Array = []
	for r in range(SPAWN_GRID_ROWS):
		for c in range(SPAWN_GRID_COLS):
			var fx: float = float(c) / float(SPAWN_GRID_COLS - 1) - 0.5
			var fz: float = float(r) / float(SPAWN_GRID_ROWS - 1) - 0.5
			var local := Vector3(SPAWN_X + fx * SPAWN_SPREAD_X, SPAWN_Y, fz * SPAWN_SPREAD_Z)
			points.append(_root_transform * local)
	return points

func finish_area_transform() -> Transform3D:
	# Local transform → world via _root_transform so the FinishLine Area3D
	# aligns with the rotated finish slab.
	_ensure_root_transform()
	var local := Vector3(FINISH_X, FINISH_BOX_SIZE.y * 0.5, 0)
	var local_tx := Transform3D(_tilt_basis, _tilt_basis * local)
	return _root_transform * local_tx

func finish_area_size() -> Vector3:
	return FINISH_BOX_SIZE

func camera_bounds() -> AABB:
	# Vertical play volume after the root rotation: width ~16 m along world X,
	# height ~90 m along world Y centred at ROOT_OFFSET_Y, depth ~3 m along
	# world Z.
	var half_h: float = TABLE_LEN * 0.5 + 5.0
	var min_v := Vector3(-TABLE_WIDTH * 0.5 - 2.0, ROOT_OFFSET_Y - half_h, -3.0)
	var max_v := Vector3(TABLE_WIDTH * 0.5 + 2.0, ROOT_OFFSET_Y + half_h, 4.0)
	return AABB(min_v, max_v - min_v)

func camera_pose() -> Dictionary:
	# Frontal vertical view: camera in front of the back wall (+Z), centred
	# horizontally and at the vertical midpoint of the play volume. Wide
	# enough FOV that the full 90 m drop fits in frame at this distance.
	return {
		"position": Vector3(0, ROOT_OFFSET_Y, 70),
		"target": Vector3(0, ROOT_OFFSET_Y, 0),
		"fov": 70.0,
	}

func environment_overrides() -> Dictionary:
	# Sky stays the daylight default (onion's cloud shader); per-track
	# mood comes from a slightly hazy warm-gold fog and a softly amber
	# sun, which is enough to push the felt and brass toward
	# vegas-strip warm without fighting the sky.
	return {
		"ambient_energy": 0.70,
		"fog_color": Color(0.85, 0.55, 0.40),
		"fog_density": 0.004,
		"sun_color": Color(1.0, 0.92, 0.78),
	}
