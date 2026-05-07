class_name RouletteTrack
extends Track

# RouletteTrack — REBUILT as "Forest Run" (M11 + Forest unique geometry).
#
# Class name kept as RouletteTrack so existing replays with track_id=1 still
# decode through TrackRegistry. The casino-roulette wheel obstacle is gone;
# this is now a forest-themed course with the M11 drop-cascade backbone PLUS
# a distinguishing "log roll" mechanic — three rotating wooden logs spanning
# the depth axis, one per F2/F3/F4 ramp, that deflect marbles passing under.
#
# This is the FIRST of the six tracks to receive a unique geometric mechanic
# (post the M11 "all six tracks share the same skeleton" debt). The other
# five (Volcano, Ice, Cavern, Sky, Stadium) still share the plain cascade
# until they get their own distinguishing features.
#
# Drop-cascade design (real gravity, no slow-motion):
#   y=42  spawn (32 slots: 8×3 original + 8 new at z=+2)
#   ─── F1: V-funnel (moss green) — gap centred at x=0
#   ─── F2: directed ramp (bark brown) + ROTATING LOG → gap on +X
#   ─── F3: directed ramp (leaf green) + ROTATING LOG → gap on -X
#   ─── F4: directed ramp (warm wood) + ROTATING LOG → gap on +X
#   ─── F5: peg forest (tree-trunk pegs, hex grid 7×9)
#   ─── F6: lane gate (warm gold, 20 lanes)
#
# Determinism: log angular velocity is derived from the round's server_seed
# via _hash_with_tag("forest_log_<i>") so each round shows a different log
# behaviour while staying replay-stable. Logs are AnimatableBody3D
# (kinematic) — they impart momentum to colliding marbles correctly under
# Jolt without feeding back into the physics state machine.
#
# Palette + sky from TrackPalette.theme_for(ROULETTE).
# Geometry primitives from TrackBlocks.

# ─── Field dimensions ────────────────────────────────────────────────────────
const FIELD_W      := 40.0
const FIELD_DEPTH  := 5.0
const WALL_THICK   := 0.5
const FLOOR_THICK  := 0.5

# ─── Vertical layout ─────────────────────────────────────────────────────────
const SPAWN_Y      := 40.0
const F1_Y         := 38.0
const F2_Y         := 32.0
const F3_Y         := 26.0
const F4_Y         := 20.0
const F5_TOP_Y     := 14.0
const F5_BOT_Y     := 4.0
const F6_Y         := 0.0
const FLOOR_BASE_Y := -6.0

# ─── Tuning (matches StadiumTrack reliable defaults) ───────────────────────
const F1_GAP_W     := 4.0
const RAMP_GAP_W   := 4.0
const F1_TILT_DEG  := 6.0
const RAMP_TILT_DEG := 8.0
const F5_PEG_RADIUS := 0.55
const F5_ROWS      := 7
const F5_COLS      := 9
const F5_COL_SPACING := 4.5
const F6_LANES     := 30

# ─── Spawn ──────────────────────────────────────────────────────────────────
const SPAWN_COLS := 8
const SPAWN_ROWS := 3
const SPAWN_DX   := 1.6
const SPAWN_DZ   := 1.0

# ─── Finish line ────────────────────────────────────────────────────────────
const FINISH_Y_OFF := 2.5
const FINISH_BOX   := Vector3(FIELD_W + 2.0, 5.0, FIELD_DEPTH + 1.0)

var _theme: Dictionary

# ─── Rolling log obstacles (Forest unique mechanic) ─────────────────────────
# Three horizontal cylinders spanning the depth axis (Z), one per F2/F3/F4
# ramp. They sit ~1.5m above each ramp's centerline, spinning around their
# own axis at angular velocities derived from the round's server_seed.
const LOG_RADIUS    := 0.6
const LOG_LENGTH    := 4.0           # along Z (FIELD_DEPTH = 5, leave margin)
const LOG_OMEGA_MAX := 1.6           # rad/s magnitude cap (≈4s/rev)
const LOG_OMEGA_MIN_ABS := 0.5       # never spin slower than this in abs value
# Vertical clearance between the slab's centre y and the log pivot y.
# Slab is 0.5m thick (top surface ≈ slab_y + 0.25). Log radius 0.6.
# Log bottom = pivot_y - LOG_RADIUS. We want clearance from slab top
# of at least marble_diameter (0.6) + buffer (0.4) = 1.0m so marbles
# pass under cleanly and only bouncing marbles brush the log.
# pivot_y = slab_y + 0.25 + 1.0 + LOG_RADIUS = slab_y + 1.85.
const LOG_CLEARANCE_Y := 1.9

# Physics materials.
var _mat_floor: PhysicsMaterial = null
var _mat_peg:   PhysicsMaterial = null
var _mat_wall:  PhysicsMaterial = null
var _mat_gate:  PhysicsMaterial = null
var _mat_log:   PhysicsMaterial = null

# Log animation state.
var _logs: Array[AnimatableBody3D] = []
var _log_pivots: Array = []      # Vector3 array, parallel to _logs
var _log_omegas: Array = []      # float array, rad/s, parallel to _logs
var _log_time: float = 0.0       # accumulated _physics_process delta

func _ready() -> void:
	_theme = TrackPalette.theme_for(TrackRegistry.ROULETTE)
	_init_physics_materials()
	_build_outer_frame()
	_build_floor1()
	_build_directed_floor("F2", F2_Y, +1, _theme["floor_b"])
	_build_directed_floor("F3", F3_Y, -1, _theme["floor_c"])
	_build_directed_floor("F4", F4_Y, +1, _theme["floor_d"])
	_build_peg_field()
	_build_gate()
	_build_catchment()
	_build_rolling_logs()
	_build_pickup_zones()
	_build_mood_lights()
	_build_decorations()

# Forest demo of the M17 pickup-zone system. Lays out 4 Tier-1 (2×) zones
# and 1 Tier-2 (3×) zone inside the F5 peg-forest area. Geometry is sized so
# that on average ~1 marble per Tier-1 zone collects (4 total, matching the
# math-model cap) and ~0.7 marbles per round traverse the Tier-2 zone (the
# server's deterministic Tier 2 active flag adds the second probabilistic
# gate on top — see DeriveTier2Active).
#
# Visual hint: zones get a soft green glow material so players see WHERE
# the multiplier opportunities are. Operator can disable the visual by
# passing `mat=null` to add_pickup_zone if a cleaner look is preferred.
func _build_pickup_zones() -> void:
	var t1_mat := TrackBlocks.std_mat_emit(
		Color(0.40, 0.95, 0.55, 0.30),    # mossy green semi-transparent
		0.0, 0.50, 0.40)
	t1_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	var t2_mat := TrackBlocks.std_mat_emit(
		Color(1.00, 0.70, 0.20, 0.40),    # warm gold semi-transparent
		0.0, 0.40, 0.80)
	t2_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA

	# 4 Tier-1 zones at roughly equal x-spacing across the F5 peg-forest mid-Y.
	# Each zone is ~3m wide × 1.5m tall × FIELD_DEPTH so a marble traversing
	# F5 has a moderate chance of crossing exactly one of them.
	const TIER1_SIZE := Vector3(3.0, 1.5, FIELD_DEPTH - 0.4)
	const TIER1_Y    := 9.0    # mid F5 (top=14, bot=4 → centre 9)
	const TIER1_XS   := [-12.0, -4.0, 4.0, 12.0]
	for i in range(TIER1_XS.size()):
		var x: float = float(TIER1_XS[i])
		TrackBlocks.add_pickup_zone(self, "PickupT1_%d" % i,
			Transform3D(Basis.IDENTITY, Vector3(x, TIER1_Y, 0.0)),
			TIER1_SIZE, PickupZone.TIER_1, t1_mat)

	# 1 Tier-2 zone at field centre, narrow so only the most lucky marble
	# crosses it. 1.4m wide × 1.5m tall — fewer marbles in the centre after
	# the V-funnel and the rotating logs, so probability stays near target.
	TrackBlocks.add_pickup_zone(self, "PickupT2",
		Transform3D(Basis.IDENTITY, Vector3(0.0, 6.5, 0.0)),
		Vector3(1.4, 1.5, FIELD_DEPTH - 0.4), PickupZone.TIER_2, t2_mat)

func _physics_process(delta: float) -> void:
	# Drive the kinematic log rotation. Each log spins around its own long
	# axis (which is world Z after the orient basis applied below); marbles
	# riding the ramp under each log hit it and get nudged in the spin's
	# tangential direction. Constant ω across the race.
	_log_time += delta
	var orient := Basis(Vector3.RIGHT, deg_to_rad(90.0))
	for i in range(_logs.size()):
		var w: float = float(_log_omegas[i])
		var angle: float = w * _log_time
		var spin := Basis(Vector3(0, 0, 1), angle)
		var pivot: Vector3 = _log_pivots[i]
		_logs[i].global_transform = Transform3D(spin * orient, pivot)

func _init_physics_materials() -> void:
	# Same tuning as StadiumTrack — proven to finish ~30 s with real gravity.
	# Theme variations stay visual only (palette + sky); physics is uniform
	# across the cascade tracks so the marble feel is consistent.
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
	# Logs: rough wood — moderate friction so the spin imparts visible motion
	# to passing marbles, low bounce so marbles don't fly off vertically.
	_mat_log = PhysicsMaterial.new()
	_mat_log.friction = 0.55
	_mat_log.bounce   = 0.20

func _build_outer_frame() -> void:
	var wall_mat := TrackBlocks.std_mat(_theme["wall"], 0.10, 0.85)
	var frame := StaticBody3D.new()
	frame.name = "OuterFrame"
	frame.physics_material_override = _mat_wall
	add_child(frame)
	TrackBlocks.build_outer_frame(frame, "Frame",
		SPAWN_Y + 3.0, FLOOR_BASE_Y - 1.0,
		FIELD_W, FIELD_DEPTH, WALL_THICK, wall_mat)

func _build_floor1() -> void:
	var floor_mat := TrackBlocks.std_mat(_theme["floor_a"], 0.20, 0.75)
	var body := StaticBody3D.new()
	body.name = "F1_MossFunnel"
	body.physics_material_override = _mat_floor
	add_child(body)
	TrackBlocks.build_v_funnel(body, "F1",
		F1_Y, FIELD_W, F1_GAP_W, FIELD_DEPTH, FLOOR_THICK,
		F1_TILT_DEG, floor_mat)

func _build_directed_floor(prefix: String, y_pos: float, gap_dir: int,
		col: Color) -> void:
	var floor_mat := TrackBlocks.std_mat(col, 0.15, 0.65)
	var curb_mat  := TrackBlocks.std_mat(_theme["wall"], 0.10, 0.80)
	var body := StaticBody3D.new()
	body.name = "%s_Ramp" % prefix
	body.physics_material_override = _mat_floor
	add_child(body)
	TrackBlocks.build_directed_ramp(body, prefix,
		y_pos, FIELD_W, RAMP_GAP_W, FIELD_DEPTH, FLOOR_THICK,
		RAMP_TILT_DEG, gap_dir, floor_mat, curb_mat)

func _build_peg_field() -> void:
	var peg_mat := TrackBlocks.std_mat_emit(_theme["peg"], 0.0, 0.85, 0.10)
	var pegs := StaticBody3D.new()
	pegs.name = "F5_Trees"
	pegs.physics_material_override = _mat_peg
	add_child(pegs)
	TrackBlocks.build_peg_forest(pegs, "F5",
		F5_TOP_Y, F5_BOT_Y, FIELD_W, FIELD_DEPTH,
		F5_ROWS, F5_COLS, F5_PEG_RADIUS, F5_COL_SPACING, peg_mat)

func _build_gate() -> void:
	var floor_mat := TrackBlocks.std_mat(_theme["gate"], 0.85, 0.30)
	var div_mat   := TrackBlocks.std_mat_emit(_theme["accent"], 0.30, 0.40, 0.45)
	var body := StaticBody3D.new()
	body.name = "F6_Gate"
	body.physics_material_override = _mat_gate
	add_child(body)
	TrackBlocks.build_lane_gate(body, "Gate",
		F6_Y, FIELD_W, FIELD_DEPTH, F6_LANES,
		1.5, 0.15, FLOOR_THICK, floor_mat, div_mat)

func _build_catchment() -> void:
	var mat := TrackBlocks.std_mat(Color(0.06, 0.10, 0.06), 0.10, 0.85)
	var body := StaticBody3D.new()
	body.name = "Catchment"
	body.physics_material_override = _mat_gate
	add_child(body)
	TrackBlocks.build_catchment(body, "Catch",
		FLOOR_BASE_Y, FIELD_W, FIELD_DEPTH, FLOOR_THICK, mat)

func _build_rolling_logs() -> void:
	# Three rotating log obstacles, one per F2/F3/F4 ramp. Each log is an
	# AnimatableBody3D positioned ~1.5m above the ramp's centerline, oriented
	# along Z (depth), spinning around its own axis at a seed-derived ω so
	# different rounds show different log behaviour while staying replay-stable.
	#
	# The ramp slabs are tilted around Z by ±RAMP_TILT_DEG; the log sits
	# horizontally at the slab's midpoint X. Vertical clearance is set so
	# a marble can pass under most of the time, only brushing the log when
	# it bounces high — see LOG_CLEARANCE_Y derivation above.

	var log_mat := TrackBlocks.std_mat_emit(
		Color(0.55, 0.42, 0.18),     # warm wood brown
		0.10, 0.85, 0.10)             # metallic, roughness, emission_energy
	# Wood ring detail comes from the trail of marble interactions; for now
	# the log is a uniform cylinder.

	# Per-log: y position is the ramp's y + LOG_CLEARANCE.
	# X is the ramp's slab center: -float(gap_dir) * (RAMP_GAP_W/2).
	#   F2 (gap_dir=+1) → x = -2
	#   F3 (gap_dir=-1) → x = +2
	#   F4 (gap_dir=+1) → x = -2
	var configs := [
		{"prefix": "F2", "y": F2_Y + LOG_CLEARANCE_Y, "x": -float(+1) * RAMP_GAP_W * 0.5},
		{"prefix": "F3", "y": F3_Y + LOG_CLEARANCE_Y, "x": -float(-1) * RAMP_GAP_W * 0.5},
		{"prefix": "F4", "y": F4_Y + LOG_CLEARANCE_Y, "x": -float(+1) * RAMP_GAP_W * 0.5},
	]

	for i in range(configs.size()):
		var cfg: Dictionary = configs[i]
		var pivot := Vector3(float(cfg["x"]), float(cfg["y"]), 0.0)
		# Initial transform: cylinder (default Y-axis) rotated 90° around X
		# so it lies along Z (the depth axis). Spin around Z is added per-frame
		# in _physics_process.
		var orient := Basis(Vector3.RIGHT, deg_to_rad(90.0))
		var tx := Transform3D(orient, pivot)
		var body := TrackBlocks.add_animatable_cylinder(
			self, "%s_RollingLog" % str(cfg["prefix"]),
			tx, LOG_RADIUS, LOG_LENGTH, log_mat)
		body.physics_material_override = _mat_log
		_logs.append(body)
		_log_pivots.append(pivot)

		# Derive ω from the round seed. _hash_with_tag returns 32 bytes —
		# we use the first byte mapped to [-1, +1], scaled by LOG_OMEGA_MAX.
		# Floor on |ω| so a hash near 128 doesn't yield a near-stationary log.
		var hash_bytes: PackedByteArray = _hash_with_tag("forest_log_%d" % i)
		var raw_omega: float
		if hash_bytes.size() >= 1:
			raw_omega = float(int(hash_bytes[0]) - 128) / 128.0   # ≈ -1..+1
		else:
			raw_omega = (1.0 if (i % 2 == 0) else -1.0) * 0.7
		if absf(raw_omega) < (LOG_OMEGA_MIN_ABS / LOG_OMEGA_MAX):
			# Force a sensible minimum spin; sign comes from sgn(raw) or i parity.
			raw_omega = (LOG_OMEGA_MIN_ABS / LOG_OMEGA_MAX) * (1.0 if raw_omega >= 0 else -1.0)
		_log_omegas.append(raw_omega * LOG_OMEGA_MAX)

func _build_mood_lights() -> void:
	# Dappled sunlight through the canopy: warm angled directional + soft
	# green fill from below, gold glow at the gate.
	var key := DirectionalLight3D.new()
	key.name = "ForestKey"
	key.light_color    = Color(1.0, 0.95, 0.70)
	key.light_energy   = 1.3
	key.rotation_degrees = Vector3(-50.0, -30.0, 0.0)
	key.shadow_enabled = true
	add_child(key)
	var fill := OmniLight3D.new()
	fill.name = "ForestFill"
	fill.light_color  = Color(0.55, 0.85, 0.45)
	fill.light_energy = 1.0
	fill.omni_range   = 40.0
	fill.position     = Vector3(0.0, F4_Y - 2.0, -6.0)
	add_child(fill)
	var gate_spot := OmniLight3D.new()
	gate_spot.name = "GateGlow"
	gate_spot.light_color  = Color(1.0, 0.85, 0.45)
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
# Forest theme: canopy tribune bleachers, "FOREST RUN" banners, firefly
# particles drifting upward, and neon-green accent lights washing the stands.
func _build_decorations() -> void:
	var deco := Node3D.new()
	deco.name = "Decorations"
	add_child(deco)

	# --- Spectator stands (2 rows, both sides, Z ≈ ±8 so well outside FIELD_DEPTH/2=2.5)
	# Each side: 2 tiered rows of 20 spectators each = 40 per side, 80 total.
	var forest_bodies: Array = [
		Color(0.20, 0.50, 0.18), Color(0.45, 0.30, 0.12),
		Color(0.30, 0.55, 0.22), Color(0.55, 0.42, 0.18),
		Color(0.65, 0.50, 0.25), Color(0.18, 0.40, 0.15),
	]
	var head_col := Color(0.85, 0.70, 0.55)
	var mid_y: float = (SPAWN_Y + F6_Y) * 0.5     # vertical centre of track ≈ 20
	for side in [-1, 1]:
		var z_near: float = float(side) * 8.5
		var z_far: float  = float(side) * 11.0
		TrackBlocks.build_spectator_row(deco, "ForestStand_S%d_R0" % side,
			Vector3(0.0, mid_y - 6.0, z_near), 20, 2.0, forest_bodies, head_col)
		TrackBlocks.build_spectator_row(deco, "ForestStand_S%d_R1" % side,
			Vector3(0.0, mid_y - 4.5, z_far), 20, 2.0, forest_bodies, head_col)

	# --- Billboards (4 panels, two per side above the stands)
	# "FOREST RUN" lettering implied by the emissive green-gold panel.
	var sign_cols: Array = [
		Color(0.30, 0.90, 0.30),  # vivid green
		Color(1.00, 0.80, 0.20),  # firefly gold
		Color(0.20, 0.70, 0.20),  # darker green
		Color(1.00, 0.70, 0.10),  # amber
	]
	var board_positions: Array = [-15.0, -5.0, 5.0, 15.0]
	for i in range(board_positions.size()):
		var bx: float = float(board_positions[i])
		var col: Color = sign_cols[i % sign_cols.size()]
		# Front-facing panel (visible from +Z camera).
		var basis := Basis.IDENTITY    # faces +Z by default
		TrackBlocks.build_billboard(deco, "ForestSign_%d" % i,
			Transform3D(basis, Vector3(bx, SPAWN_Y + 2.0, -FIELD_DEPTH * 0.5 - 1.5)),
			Vector3(7.0, 2.5, 0.18), col, 3.0)

	# --- Neon accent lights: 6 lights bracketing the stands, green + amber mix
	var neon_cols: Array = [
		Color(0.25, 1.00, 0.35),
		Color(1.00, 0.85, 0.25),
		Color(0.25, 1.00, 0.35),
	]
	TrackBlocks.build_neon_array(deco, "ForestNeon_Pos",
		mid_y, 10.0, [-15.0, 0.0, 15.0], neon_cols, 2.2, 22.0)
	TrackBlocks.build_neon_array(deco, "ForestNeon_Neg",
		mid_y, -10.0, [-15.0, 0.0, 15.0], neon_cols, 2.2, 22.0)

	# --- Ambient particles: "firefly" dots drifting upward slowly
	# Kept well inside the track corridor (Z=0) so they don't clip the stands.
	TrackBlocks.build_ambient_particles(deco, "ForestFireflies",
		Vector3(0.0, mid_y, 0.0),
		60, 8.0,                                  # amount, lifetime
		Color(1.00, 1.00, 0.40, 0.85),            # warm yellow
		Vector3(0.0, 0.4, 0.0),                   # gentle upward drift
		18.0, 15.0, 2.0,                          # spread_x/y/z
		0.1, 0.5,                                 # velocity min/max
		0.04, 0.12)                               # scale min/max
