class_name PokerTrack
extends Track

# PokerTrack — REBUILT as "Ice Run" (M11 + Ice unique geometry).
#
# Class name kept as PokerTrack so existing replays with track_id=3 still
# decode through TrackRegistry. The casino-poker obstacles (cards, felt
# table) are gone; this is now an icy course with the M11 drop-cascade
# backbone PLUS a distinguishing "vertical ice shards" obstacle field —
# tall thin vertical slabs in F5 instead of round cylinder pegs, giving
# a flat-faced collision pattern that deflects marbles in sharp angles
# (vs the soft round bounces of cylindrical pegs).
#
# Drop-cascade design (real gravity, no slow-motion):
#   y=42 spawn → F1 V-funnel (ice white) → F2-F4 ice ramps →
#   F5 ICE SHARD FOREST (zigzag of vertical thin slabs) →
#   F6 ice-blue gate.
#
# Determinism: shards are static, replay-stable by construction.
#
# Palette + sky from TrackPalette.theme_for(POKER).

const FIELD_W      := 40.0
const FIELD_DEPTH  := 5.0
const WALL_THICK   := 0.5
const FLOOR_THICK  := 0.5

const SPAWN_Y      := 40.0
const F1_Y         := 38.0
const F2_Y         := 32.0
const F3_Y         := 26.0
const F4_Y         := 20.0
const F5_TOP_Y     := 14.0
const F5_BOT_Y     := 4.0
const F6_Y         := 0.0
const FLOOR_BASE_Y := -6.0

# Tuning matches StadiumTrack defaults. Theme variation stays visual.
const F1_GAP_W     := 4.0
const RAMP_GAP_W   := 4.0
const F1_TILT_DEG  := 6.0
const RAMP_TILT_DEG := 8.0
const F5_PEG_RADIUS := 0.55
const F5_ROWS      := 7
const F5_COLS      := 9
const F5_COL_SPACING := 4.5
const F6_LANES     := 30

const SPAWN_COLS := 8
const SPAWN_ROWS := 3
const SPAWN_DX   := 1.6
const SPAWN_DZ   := 1.0

const FINISH_Y_OFF := 2.5
const FINISH_BOX   := Vector3(FIELD_W + 2.0, 5.0, FIELD_DEPTH + 1.0)

var _theme: Dictionary
var _mat_floor: PhysicsMaterial = null
var _mat_peg:   PhysicsMaterial = null
var _mat_wall:  PhysicsMaterial = null
var _mat_gate:  PhysicsMaterial = null

func _ready() -> void:
	_theme = TrackPalette.theme_for(TrackRegistry.POKER)
	_init_physics_materials()
	_build_outer_frame()
	_build_floor1()
	_build_directed_floor("F2", F2_Y, +1, _theme["floor_b"])
	_build_directed_floor("F3", F3_Y, -1, _theme["floor_c"])
	_build_directed_floor("F4", F4_Y, +1, _theme["floor_d"])
	_build_peg_field()
	_build_gate()
	_build_catchment()
	_build_pickup_zones()
	_build_mood_lights()
	_build_decorations()

# M19 — Ice pickup zones. Same standardized layout as Forest, ice-themed
# colors. The shard rows are at y≈[12.3, 10.7, 9.0, 7.3, 5.7]; T1 zones at
# y=9 sit in the middle row's plane, but they're Area3D and don't collide
# with the static StaticBody3D shards.
func _build_pickup_zones() -> void:
	var t1_mat := TrackBlocks.std_mat_emit(
		Color(0.55, 0.85, 1.00, 0.30),    # frosty cyan semi-transparent
		0.0, 0.45, 0.70)
	t1_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	var t2_mat := TrackBlocks.std_mat_emit(
		Color(0.30, 0.90, 1.00, 0.45),    # bright aqua semi-transparent
		0.0, 0.30, 1.10)
	t2_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA

	const TIER1_SIZE := Vector3(3.0, 1.5, FIELD_DEPTH - 0.4)
	const TIER1_Y    := 9.0
	const TIER1_XS   := [-12.0, -4.0, 4.0, 12.0]
	for i in range(TIER1_XS.size()):
		var x: float = float(TIER1_XS[i])
		TrackBlocks.add_pickup_zone(self, "PickupT1_%d" % i,
			Transform3D(Basis.IDENTITY, Vector3(x, TIER1_Y, 0.0)),
			TIER1_SIZE, PickupZone.TIER_1, t1_mat)

	TrackBlocks.add_pickup_zone(self, "PickupT2",
		Transform3D(Basis.IDENTITY, Vector3(0.0, 6.5, 0.0)),
		Vector3(1.4, 1.5, FIELD_DEPTH - 0.4), PickupZone.TIER_2, t2_mat)

func _init_physics_materials() -> void:
	# Stadium-aligned physics for reliable finish.
	_mat_floor = PhysicsMaterial.new()
	_mat_floor.friction = 0.40
	_mat_floor.bounce   = 0.20
	_mat_peg = PhysicsMaterial.new()
	_mat_peg.friction = 0.25
	_mat_peg.bounce   = 0.55
	_mat_wall = PhysicsMaterial.new()
	_mat_wall.friction = 0.30
	_mat_wall.bounce   = 0.30
	_mat_gate = PhysicsMaterial.new()
	_mat_gate.friction = 0.55
	_mat_gate.bounce   = 0.10

func _build_outer_frame() -> void:
	var wall_mat := TrackBlocks.std_mat(_theme["wall"], 0.30, 0.40)
	var frame := StaticBody3D.new()
	frame.name = "OuterFrame"
	frame.physics_material_override = _mat_wall
	add_child(frame)
	TrackBlocks.build_outer_frame(frame, "Frame",
		SPAWN_Y + 3.0, FLOOR_BASE_Y - 1.0,
		FIELD_W, FIELD_DEPTH, WALL_THICK, wall_mat)

func _build_floor1() -> void:
	var floor_mat := TrackBlocks.std_mat(_theme["floor_a"], 0.40, 0.20)
	var body := StaticBody3D.new()
	body.name = "F1_IceFunnel"
	body.physics_material_override = _mat_floor
	add_child(body)
	TrackBlocks.build_v_funnel(body, "F1",
		F1_Y, FIELD_W, F1_GAP_W, FIELD_DEPTH, FLOOR_THICK,
		F1_TILT_DEG, floor_mat)

func _build_directed_floor(prefix: String, y_pos: float, gap_dir: int,
		col: Color) -> void:
	var floor_mat := TrackBlocks.std_mat(col, 0.50, 0.20)
	var curb_mat  := TrackBlocks.std_mat(_theme["wall"], 0.30, 0.50)
	var body := StaticBody3D.new()
	body.name = "%s_Ramp" % prefix
	body.physics_material_override = _mat_floor
	add_child(body)
	TrackBlocks.build_directed_ramp(body, prefix,
		y_pos, FIELD_W, RAMP_GAP_W, FIELD_DEPTH, FLOOR_THICK,
		RAMP_TILT_DEG, gap_dir, floor_mat, curb_mat)

func _build_peg_field() -> void:
	# Ice unique mechanic: replace cylindrical pegs with VERTICAL ICE SHARDS.
	# Each shard is a thin tall slab oriented along Z (depth axis), narrow
	# face pointing along X (the marble travel direction). Marbles striking
	# the flat face deflect at sharp angles — distinct from the rounded
	# bounces of cylinder pegs. Hex-staggered grid for slalom feel.
	const SHARD_W: float = 0.4    # x extent — narrow face hits marbles
	const SHARD_H: float = 2.5    # y extent — taller than pegs for drama
	const SHARD_D: float = 0.5    # z extent (depth) — full slab depth into Z
	const SHARD_ROWS: int = 5     # fewer rows than pegs (each shard is bigger)
	const SHARD_COLS: int = 7
	const SHARD_X_SPACING: float = 5.0
	const SHARD_Z_OFFSETS: Array = [-1.6, 0.0, 1.6]   # 3 z-rows per row, hex-ish

	var shard_mat := TrackBlocks.std_mat_emit(_theme["peg"], 0.85, 0.15, 0.45)
	var shards := StaticBody3D.new()
	shards.name = "F5_IceShards"
	shards.physics_material_override = _mat_peg
	add_child(shards)

	var row_spacing: float = (F5_TOP_Y - F5_BOT_Y) / float(SHARD_ROWS + 1)
	for row in range(SHARD_ROWS):
		var y: float = F5_TOP_Y - row_spacing * float(row + 1)
		var x_offset: float = 0.0 if (row % 2 == 0) else SHARD_X_SPACING * 0.5
		var x_origin: float = -float(SHARD_COLS - 1) * 0.5 * SHARD_X_SPACING + x_offset
		# Per row, scatter shards across z too — alternate which z-offset
		# each col uses based on (row+col) parity so the pattern doesn't
		# form a regular grid.
		for col in range(SHARD_COLS):
			var x: float = x_origin + float(col) * SHARD_X_SPACING
			if absf(x) > FIELD_W * 0.5 - SHARD_W * 0.5 - 0.4:
				continue
			var z_idx: int = (row + col) % SHARD_Z_OFFSETS.size()
			var z: float = float(SHARD_Z_OFFSETS[z_idx])
			TrackBlocks.add_box(shards, "Shard_r%d_c%d" % [row, col],
				Transform3D(Basis.IDENTITY, Vector3(x, y, z)),
				Vector3(SHARD_W, SHARD_H, SHARD_D),
				shard_mat)

func _build_gate() -> void:
	var floor_mat := TrackBlocks.std_mat_emit(_theme["gate"], 0.50, 0.25, 0.55)
	var div_mat   := TrackBlocks.std_mat_emit(_theme["accent"], 0.50, 0.30, 0.75)
	var body := StaticBody3D.new()
	body.name = "F6_IceGate"
	body.physics_material_override = _mat_gate
	add_child(body)
	TrackBlocks.build_lane_gate(body, "Gate",
		F6_Y, FIELD_W, FIELD_DEPTH, F6_LANES,
		1.5, 0.15, FLOOR_THICK, floor_mat, div_mat)

func _build_catchment() -> void:
	var mat := TrackBlocks.std_mat(Color(0.10, 0.15, 0.22), 0.20, 0.70)
	var body := StaticBody3D.new()
	body.name = "Catchment"
	body.physics_material_override = _mat_gate
	add_child(body)
	TrackBlocks.build_catchment(body, "Catch",
		FLOOR_BASE_Y, FIELD_W, FIELD_DEPTH, FLOOR_THICK, mat)

func _build_mood_lights() -> void:
	# Cool blue-white midday: bright key + cyan back rim + cold ambient.
	var key := DirectionalLight3D.new()
	key.name = "IceKey"
	key.light_color    = Color(0.85, 0.92, 1.00)
	key.light_energy   = 1.6
	key.rotation_degrees = Vector3(-55.0, -30.0, 0.0)
	key.shadow_enabled = true
	add_child(key)
	var rim := OmniLight3D.new()
	rim.name = "IceRim"
	rim.light_color  = Color(0.40, 0.85, 1.00)
	rim.light_energy = 1.4
	rim.omni_range   = 50.0
	rim.position     = Vector3(0.0, F4_Y, -8.0)
	add_child(rim)
	var gate_spot := OmniLight3D.new()
	gate_spot.name = "GateGlow"
	gate_spot.light_color  = Color(0.60, 0.90, 1.00)
	gate_spot.light_energy = 1.8
	gate_spot.omni_range   = 12.0
	gate_spot.position     = Vector3(0.0, F6_Y + 4.0, 3.0)
	add_child(gate_spot)

# ─── Track API overrides ────────────────────────────────────────────────────

func spawn_points() -> Array:
	# Slots 0-23: original 8×3 grid (rows 0/1/2, z=-1/0/+1). Preserved for
	# backward compat with old 20-marble replays — verifier checks these by
	# position. Do NOT re-centre; formula is fz=(r-1.0)*SPAWN_DZ exactly.
	var pts: Array = []
	for r in range(SPAWN_ROWS):
		for c in range(SPAWN_COLS):
			var fx := (float(c) - float(SPAWN_COLS - 1) * 0.5) * SPAWN_DX
			var fz := (float(r) - 1.0) * SPAWN_DZ
			pts.append(Vector3(fx, SPAWN_Y, fz))
	# Slots 24-31: 4th row appended at z=+2.0 (well within FIELD_DEPTH=5m).
	for c in range(SPAWN_COLS):
		var fx := (float(c) - float(SPAWN_COLS - 1) * 0.5) * SPAWN_DX
		pts.append(Vector3(fx, SPAWN_Y, 2.0))
	return pts

func finish_area_transform() -> Transform3D:
	return Transform3D(Basis.IDENTITY, Vector3(0.0, F6_Y + FINISH_Y_OFF, 0.0))

func finish_area_size() -> Vector3:
	return FINISH_BOX

func camera_bounds() -> AABB:
	var min_v := Vector3(-FIELD_W * 0.5 - 1.0, FLOOR_BASE_Y - 2.0, -FIELD_DEPTH * 0.5 - 1.0)
	var max_v := Vector3( FIELD_W * 0.5 + 1.0, SPAWN_Y + 4.0,        FIELD_DEPTH * 0.5 + 1.0)
	return AABB(min_v, max_v - min_v)

func camera_pose() -> Dictionary:
	var mid_y: float = (SPAWN_Y + FLOOR_BASE_Y) * 0.5
	return {
		"position": Vector3(8.0, mid_y + 6.0, 55.0),
		"target":   Vector3(0.0, mid_y - 4.0, 0.0),
		"fov":      65.0,
	}

func environment_overrides() -> Dictionary:
	return _theme["env"]

# ─── Decoration props (visual-only, NO collision) ───────────────────────────
# Ice theme: frost-white bleachers, "ICE RUN" cyan neon banners,
# falling snowflake particles, cold-blue accent lights.
func _build_decorations() -> void:
	var deco := Node3D.new()
	deco.name = "Decorations"
	add_child(deco)

	# --- Spectator stands: icy whites and cool blues
	var ice_bodies: Array = [
		Color(0.80, 0.90, 1.00), Color(0.55, 0.78, 0.92),
		Color(0.92, 0.95, 1.00), Color(0.30, 0.55, 0.78),
		Color(0.65, 0.80, 0.95), Color(0.45, 0.70, 0.90),
	]
	var head_col := Color(0.95, 0.95, 1.00)
	var mid_y: float = (SPAWN_Y + F6_Y) * 0.5
	for side in [-1, 1]:
		var z_near: float = float(side) * 8.5
		var z_far: float  = float(side) * 11.0
		TrackBlocks.build_spectator_row(deco, "IceStand_S%d_R0" % side,
			Vector3(0.0, mid_y - 6.0, z_near), 20, 2.0, ice_bodies, head_col)
		TrackBlocks.build_spectator_row(deco, "IceStand_S%d_R1" % side,
			Vector3(0.0, mid_y - 4.5, z_far), 20, 2.0, ice_bodies, head_col)

	# --- Billboards: crystal-cyan + ice-blue panels
	var sign_cols: Array = [
		Color(0.30, 0.90, 1.00),   # cyan neon
		Color(0.55, 0.95, 1.00),   # bright ice
		Color(0.20, 0.75, 1.00),   # deep cyan
		Color(0.75, 0.92, 1.00),   # pale frost
	]
	var board_positions: Array = [-15.0, -5.0, 5.0, 15.0]
	for i in range(board_positions.size()):
		var bx: float = float(board_positions[i])
		TrackBlocks.build_billboard(deco, "IceSign_%d" % i,
			Transform3D(Basis.IDENTITY,
				Vector3(bx, SPAWN_Y + 2.0, -FIELD_DEPTH * 0.5 - 1.5)),
			Vector3(7.0, 2.5, 0.18), sign_cols[i % sign_cols.size()], 3.2)

	# --- Neon accent lights: cool blue-cyan
	var neon_cols: Array = [
		Color(0.30, 0.85, 1.00),
		Color(0.55, 0.95, 1.00),
		Color(0.30, 0.85, 1.00),
	]
	TrackBlocks.build_neon_array(deco, "IceNeon_Pos",
		mid_y, 10.0, [-15.0, 0.0, 15.0], neon_cols, 2.0, 24.0)
	TrackBlocks.build_neon_array(deco, "IceNeon_Neg",
		mid_y, -10.0, [-15.0, 0.0, 15.0], neon_cols, 2.0, 24.0)

	# --- Ambient particles: snowflakes drifting gently downward
	TrackBlocks.build_ambient_particles(deco, "IceSnow",
		Vector3(0.0, SPAWN_Y - 2.0, 0.0),
		90, 12.0,
		Color(0.90, 0.95, 1.00, 0.80),
		Vector3(0.0, -0.6, 0.0),          # slow fall
		20.0, 5.0, 2.0,
		0.05, 0.30,
		0.03, 0.10)
