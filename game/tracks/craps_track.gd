class_name CrapsTrack
extends Track

# CrapsTrack — REBUILT as "Volcano Run" (M11 + Volcano unique geometry).
#
# Class name kept as CrapsTrack so existing replays with track_id=2 still
# decode through TrackRegistry. The casino-craps obstacles (dice, felt
# table) are gone; this is now a volcano-themed course with the M11
# drop-cascade backbone PLUS a distinguishing "lava geyser" mechanic —
# four kinematic vertical cylinders that oscillate up and down inside
# the F5 zone, pushing passing marbles upward when they emerge.
#
# Drop-cascade design (real gravity, no slow-motion):
#   y=42 spawn → F1 V-funnel (lava) → F2-F4 basalt ramps →
#   F5 dense obsidian peg field + 4 LAVA GEYSERS oscillating →
#   F6 lava gate.
#
# Determinism: each geyser's phase is derived from
# _hash_with_tag("volcano_geyser_<i>") so every round shows different
# geyser timing while staying replay-stable. Animation uses a constant
# frequency + per-geyser phase offset, integrated in _physics_process.
#
# Palette + sky from TrackPalette.theme_for(CRAPS).

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

# Tuning matches StadiumTrack defaults (same drop physics that finishes
# reliably in ~30s). Theme variation stays visual.
const F1_GAP_W     := 4.0
const RAMP_GAP_W   := 4.0
const F1_TILT_DEG  := 6.0
const RAMP_TILT_DEG := 8.0
const F5_PEG_RADIUS := 0.55
const F5_ROWS      := 8                # denser peg field for chaos
const F5_COLS      := 9
const F5_COL_SPACING := 4.5
const F6_LANES     := 30

const SPAWN_COLS := 8
const SPAWN_ROWS := 3
const SPAWN_DX   := 1.6
const SPAWN_DZ   := 1.0

const FINISH_Y_OFF := 2.5
const FINISH_BOX   := Vector3(FIELD_W + 2.0, 5.0, FIELD_DEPTH + 1.0)

# ─── Lava geyser config (Volcano unique mechanic) ──────────────────────────
# 4 vertical kinematic cylinders inside the F5 zone, oscillating between
# y_low and y_high at a constant frequency. Each has a phase offset
# derived from the round's server_seed so different rounds = different
# emergence timing.
const GEYSER_RADIUS    := 0.6
const GEYSER_LENGTH    := 4.0
const GEYSER_FREQ      := 1.2     # rad/s — period ≈ 5.2 s
const GEYSER_Y_MIN     := 5.5     # cylinder centre at lowest point
const GEYSER_Y_MAX     := 11.0    # cylinder centre at highest point
const GEYSER_X_COLS    := [-13.0, -4.5, 4.5, 13.0]    # 4 geysers, edges + middle

var _theme: Dictionary
var _mat_floor:  PhysicsMaterial = null
var _mat_peg:    PhysicsMaterial = null
var _mat_wall:   PhysicsMaterial = null
var _mat_gate:   PhysicsMaterial = null
var _mat_geyser: PhysicsMaterial = null

# Lava geyser kinematic state.
var _geysers: Array[AnimatableBody3D] = []
var _geyser_xs: Array = []        # parallel float array
var _geyser_phases: Array = []    # parallel float array
var _geyser_time: float = 0.0

func _ready() -> void:
	_theme = TrackPalette.theme_for(TrackRegistry.CRAPS)
	_init_physics_materials()
	_build_outer_frame()
	_build_floor1()
	_build_directed_floor("F2", F2_Y, +1, _theme["floor_b"])
	_build_directed_floor("F3", F3_Y, -1, _theme["floor_c"])
	_build_directed_floor("F4", F4_Y, +1, _theme["floor_d"])
	_build_peg_field()
	_build_lava_geysers()
	_build_gate()
	_build_catchment()
	_build_pickup_zones()
	_build_mood_lights()

# M19 — Volcano pickup zones (lava-themed). Same standardized layout as
# Forest (4 Tier-1 + 1 Tier-2 around F5 mid-Y), tuned colors for the lava
# theme. PickupZone is an Area3D filtered to RigidBody3D marbles, so the
# kinematic geyser cylinders sweeping through these volumes don't trigger
# false pickups even when the geyser column intersects a zone's bounds.
func _build_pickup_zones() -> void:
	var t1_mat := TrackBlocks.std_mat_emit(
		Color(1.00, 0.50, 0.20, 0.35),    # molten orange semi-transparent
		0.0, 0.40, 0.85)
	t1_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	var t2_mat := TrackBlocks.std_mat_emit(
		Color(1.00, 0.20, 0.10, 0.45),    # white-hot red semi-transparent
		0.0, 0.30, 1.20)
	t2_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA

	const TIER1_SIZE := Vector3(3.0, 1.5, FIELD_DEPTH - 0.4)
	const TIER1_Y    := 9.0    # mid F5 (top=14, bot=4 → centre 9)
	const TIER1_XS   := [-12.0, -4.0, 4.0, 12.0]
	for i in range(TIER1_XS.size()):
		var x: float = float(TIER1_XS[i])
		TrackBlocks.add_pickup_zone(self, "PickupT1_%d" % i,
			Transform3D(Basis.IDENTITY, Vector3(x, TIER1_Y, 0.0)),
			TIER1_SIZE, PickupZone.TIER_1, t1_mat)

	# Tier 2: narrow centre zone in the lower F5 zone where geyser min y is
	# just above (centre y=5.5 → bottom y=3.5). Sits at y=6.5 so descending
	# marbles cross it after most peg/geyser interactions.
	TrackBlocks.add_pickup_zone(self, "PickupT2",
		Transform3D(Basis.IDENTITY, Vector3(0.0, 6.5, 0.0)),
		Vector3(1.4, 1.5, FIELD_DEPTH - 0.4), PickupZone.TIER_2, t2_mat)

func _physics_process(delta: float) -> void:
	# Drive each geyser's vertical position. y_center = midpoint + sin(t·ω + φ)·amp.
	# The cylinder is solid — colliding marbles get pushed by the kinematic
	# velocity at the contact point (Jolt handles this correctly via
	# AnimatableBody3D + sync_to_physics).
	_geyser_time += delta
	var mid_y: float = (GEYSER_Y_MIN + GEYSER_Y_MAX) * 0.5
	var amp: float = (GEYSER_Y_MAX - GEYSER_Y_MIN) * 0.5
	for i in range(_geysers.size()):
		var phase: float = float(_geyser_phases[i])
		var y: float = mid_y + sin(_geyser_time * GEYSER_FREQ + phase) * amp
		var x: float = float(_geyser_xs[i])
		_geysers[i].global_transform = Transform3D(Basis.IDENTITY, Vector3(x, y, 0.0))

func _init_physics_materials() -> void:
	# Stadium-aligned physics for reliable finish.
	_mat_floor = PhysicsMaterial.new()
	_mat_floor.friction = 0.40
	_mat_floor.bounce   = 0.25
	_mat_peg = PhysicsMaterial.new()
	_mat_peg.friction = 0.25
	_mat_peg.bounce   = 0.55
	_mat_wall = PhysicsMaterial.new()
	_mat_wall.friction = 0.25
	_mat_wall.bounce   = 0.30
	_mat_gate = PhysicsMaterial.new()
	_mat_gate.friction = 0.55
	_mat_gate.bounce   = 0.10
	# Geyser: smooth, very bouncy — marbles riding the rising column should
	# feel "launched" rather than sticky.
	_mat_geyser = PhysicsMaterial.new()
	_mat_geyser.friction = 0.20
	_mat_geyser.bounce   = 0.60

func _build_outer_frame() -> void:
	var wall_mat := TrackBlocks.std_mat(_theme["wall"], 0.20, 0.80)
	var frame := StaticBody3D.new()
	frame.name = "OuterFrame"
	frame.physics_material_override = _mat_wall
	add_child(frame)
	TrackBlocks.build_outer_frame(frame, "Frame",
		SPAWN_Y + 3.0, FLOOR_BASE_Y - 1.0,
		FIELD_W, FIELD_DEPTH, WALL_THICK, wall_mat)

func _build_floor1() -> void:
	# Lava floor: emit so it glows.
	var floor_mat := TrackBlocks.std_mat_emit(_theme["floor_a"], 0.10, 0.40, 0.55)
	var body := StaticBody3D.new()
	body.name = "F1_LavaFunnel"
	body.physics_material_override = _mat_floor
	add_child(body)
	TrackBlocks.build_v_funnel(body, "F1",
		F1_Y, FIELD_W, F1_GAP_W, FIELD_DEPTH, FLOOR_THICK,
		F1_TILT_DEG, floor_mat)

func _build_directed_floor(prefix: String, y_pos: float, gap_dir: int,
		col: Color) -> void:
	var floor_mat := TrackBlocks.std_mat_emit(col, 0.20, 0.50, 0.30)
	var curb_mat  := TrackBlocks.std_mat(_theme["wall"], 0.15, 0.80)
	var body := StaticBody3D.new()
	body.name = "%s_Ramp" % prefix
	body.physics_material_override = _mat_floor
	add_child(body)
	TrackBlocks.build_directed_ramp(body, prefix,
		y_pos, FIELD_W, RAMP_GAP_W, FIELD_DEPTH, FLOOR_THICK,
		RAMP_TILT_DEG, gap_dir, floor_mat, curb_mat)

func _build_peg_field() -> void:
	# Obsidian pillars: dark, faintly emissive (heat residue).
	var peg_mat := TrackBlocks.std_mat_emit(_theme["peg"], 0.40, 0.30, 0.20)
	var pegs := StaticBody3D.new()
	pegs.name = "F5_Obsidian"
	pegs.physics_material_override = _mat_peg
	add_child(pegs)
	TrackBlocks.build_peg_forest(pegs, "F5",
		F5_TOP_Y, F5_BOT_Y, FIELD_W, FIELD_DEPTH,
		F5_ROWS, F5_COLS, F5_PEG_RADIUS, F5_COL_SPACING, peg_mat)

func _build_gate() -> void:
	var floor_mat := TrackBlocks.std_mat_emit(_theme["gate"], 0.30, 0.40, 0.70)
	var div_mat   := TrackBlocks.std_mat_emit(_theme["accent"], 0.30, 0.40, 0.85)
	var body := StaticBody3D.new()
	body.name = "F6_LavaGate"
	body.physics_material_override = _mat_gate
	add_child(body)
	TrackBlocks.build_lane_gate(body, "Gate",
		F6_Y, FIELD_W, FIELD_DEPTH, F6_LANES,
		1.5, 0.15, FLOOR_THICK, floor_mat, div_mat)

func _build_catchment() -> void:
	var mat := TrackBlocks.std_mat(Color(0.04, 0.02, 0.02), 0.10, 0.85)
	var body := StaticBody3D.new()
	body.name = "Catchment"
	body.physics_material_override = _mat_gate
	add_child(body)
	TrackBlocks.build_catchment(body, "Catch",
		FLOOR_BASE_Y, FIELD_W, FIELD_DEPTH, FLOOR_THICK, mat)

func _build_lava_geysers() -> void:
	# Four kinematic vertical cylinders. Material tinted with strong lava
	# emission so each geyser column reads as "molten" — bloom turns it
	# into a glowing pillar even at the lowest oscillation point.
	var geyser_mat := TrackBlocks.std_mat_emit(_theme["accent"], 0.10, 0.30, 1.10)

	var mid_y: float = (GEYSER_Y_MIN + GEYSER_Y_MAX) * 0.5
	for i in range(GEYSER_X_COLS.size()):
		var x: float = float(GEYSER_X_COLS[i])
		var pivot := Vector3(x, mid_y, 0.0)
		# Default Basis = cylinder along Y (vertical), which is what we want.
		var tx := Transform3D(Basis.IDENTITY, pivot)
		var body := TrackBlocks.add_animatable_cylinder(
			self, "LavaGeyser_%d" % i,
			tx, GEYSER_RADIUS, GEYSER_LENGTH, geyser_mat)
		body.physics_material_override = _mat_geyser
		_geysers.append(body)
		_geyser_xs.append(x)
		# Phase from seed: first byte mapped to [0, 2π] so each geyser fires
		# at a different point in the cycle every round.
		var hash_bytes: PackedByteArray = _hash_with_tag("volcano_geyser_%d" % i)
		var phase: float
		if hash_bytes.size() >= 1:
			phase = (float(int(hash_bytes[0])) / 255.0) * TAU
		else:
			# Fallback: evenly distribute phases across the 4 geysers.
			phase = (float(i) / float(GEYSER_X_COLS.size())) * TAU
		_geyser_phases.append(phase)

func _build_mood_lights() -> void:
	# Dramatic volcano lighting: dim warm key + bright bottom-up red glow.
	var key := DirectionalLight3D.new()
	key.name = "VolcanoKey"
	key.light_color    = Color(1.0, 0.55, 0.30)
	key.light_energy   = 1.0
	key.rotation_degrees = Vector3(-50.0, -30.0, 0.0)
	key.shadow_enabled = true
	add_child(key)
	var lava_glow := OmniLight3D.new()
	lava_glow.name = "LavaGlow"
	lava_glow.light_color  = Color(1.0, 0.40, 0.05)
	lava_glow.light_energy = 2.5
	lava_glow.omni_range   = 30.0
	lava_glow.position     = Vector3(0.0, F6_Y + 1.0, 0.0)
	add_child(lava_glow)
	var top_ember := OmniLight3D.new()
	top_ember.name = "TopEmber"
	top_ember.light_color  = Color(1.0, 0.65, 0.20)
	top_ember.light_energy = 1.6
	top_ember.omni_range   = 20.0
	top_ember.position     = Vector3(0.0, F1_Y + 1.0, 5.0)
	add_child(top_ember)

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
