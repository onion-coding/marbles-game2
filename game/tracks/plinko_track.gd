class_name PlinkoTrack
extends Track

# PlinkoTrack — REBUILT as "Sky Run" (M11 + Sky unique geometry).
#
# Class name kept as PlinkoTrack so existing replays with track_id=5 still
# decode through TrackRegistry. The casino-plinko obstacles (peg wall +
# spinner bars) are gone; this is now a sky-themed bright-daylight course
# with the M11 drop-cascade backbone PLUS a distinguishing "cloud
# stepping-stones" mechanic — instead of a dense peg field, F5 is a
# scatter of horizontal cloud platforms at multiple y-levels, forcing
# marbles to bounce down a zigzag path.
#
# Drop-cascade design (real gravity, no slow-motion):
#   y=42 spawn → F1 cloud V-funnel → F2-F4 sky ramps →
#   F5 CLOUD PLATFORM STEPPING-STONES (scattered horizontal slabs) →
#   F6 sun-gold gate.
#
# Determinism: cloud platforms are static, replay-stable by construction.
#
# Palette + sky from TrackPalette.theme_for(PLINKO).

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

# Tuning matches StadiumTrack defaults; the densest peg field of any track.
const F1_GAP_W     := 4.0
const RAMP_GAP_W   := 4.0
const F1_TILT_DEG  := 6.0
const RAMP_TILT_DEG := 8.0
const F5_PEG_RADIUS := 0.50           # smaller, more abundant cloud-pillars
const F5_ROWS      := 8
const F5_COLS      := 11              # densest peg field
const F5_COL_SPACING := 3.6           # 11×3.6 = 39.6 m
const F6_LANES     := 20

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
	_theme = TrackPalette.theme_for(TrackRegistry.PLINKO)
	_init_physics_materials()
	_build_outer_frame()
	_build_floor1()
	_build_directed_floor("F2", F2_Y, +1, _theme["floor_b"])
	_build_directed_floor("F3", F3_Y, -1, _theme["floor_c"])
	_build_directed_floor("F4", F4_Y, +1, _theme["floor_d"])
	_build_peg_field()
	_build_gate()
	_build_catchment()
	_build_mood_lights()

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
	var wall_mat := TrackBlocks.std_mat(_theme["wall"], 0.20, 0.60)
	var frame := StaticBody3D.new()
	frame.name = "OuterFrame"
	frame.physics_material_override = _mat_wall
	add_child(frame)
	TrackBlocks.build_outer_frame(frame, "Frame",
		SPAWN_Y + 3.0, FLOOR_BASE_Y - 1.0,
		FIELD_W, FIELD_DEPTH, WALL_THICK, wall_mat)

func _build_floor1() -> void:
	var floor_mat := TrackBlocks.std_mat(_theme["floor_a"], 0.15, 0.50)
	var body := StaticBody3D.new()
	body.name = "F1_CloudFunnel"
	body.physics_material_override = _mat_floor
	add_child(body)
	TrackBlocks.build_v_funnel(body, "F1",
		F1_Y, FIELD_W, F1_GAP_W, FIELD_DEPTH, FLOOR_THICK,
		F1_TILT_DEG, floor_mat)

func _build_directed_floor(prefix: String, y_pos: float, gap_dir: int,
		col: Color) -> void:
	var floor_mat := TrackBlocks.std_mat(col, 0.15, 0.55)
	var curb_mat  := TrackBlocks.std_mat_emit(_theme["accent"], 0.30, 0.30, 0.55)
	var body := StaticBody3D.new()
	body.name = "%s_Ramp" % prefix
	body.physics_material_override = _mat_floor
	add_child(body)
	TrackBlocks.build_directed_ramp(body, prefix,
		y_pos, FIELD_W, RAMP_GAP_W, FIELD_DEPTH, FLOOR_THICK,
		RAMP_TILT_DEG, gap_dir, floor_mat, curb_mat)

func _build_peg_field() -> void:
	# Sky unique mechanic: replace the dense cylinder peg field with a
	# scattered set of horizontal CLOUD PLATFORMS at multiple y-levels.
	# Marbles bounce down from platform to platform on a zigzag path —
	# distinct from the chaotic ricocheting of a peg field, more like
	# step-down obstacle navigation.
	#
	# Platform widths and y-levels are tuned so:
	#   - Marbles always have a platform below them when falling (no
	#     marble can drop straight from F4 to F6 without intersecting at
	#     least one platform).
	#   - Gaps between platforms are wide enough (>1m) for the 0.6m
	#     diameter marble to pass through.
	const CLOUD_W: float  = 5.0    # X extent — wider than peg radius
	const CLOUD_H: float  = 0.4    # Y extent — slim slab
	const CLOUD_D: float  = 4.0    # Z extent — leaves margin to side walls

	var peg_mat := TrackBlocks.std_mat_emit(_theme["peg"], 0.20, 0.40, 0.30)
	var clouds := StaticBody3D.new()
	clouds.name = "F5_CloudPlatforms"
	clouds.physics_material_override = _mat_peg
	add_child(clouds)

	# 4 levels × 3 platforms each = 12 stepping-stones. Per-level x positions
	# alternate so adjacent levels don't perfectly stack (marbles must drift
	# laterally to find the next platform).
	# Levels run from y_top (just below F5_TOP_Y) down to y just above F5_BOT_Y.
	var levels: Array = [
		# Level 1 (y=12.5): platforms left-of-centre + right-of-centre.
		{"y": 12.5, "xs": [-13.0, -3.0,  9.0]},
		# Level 2 (y=9.5): inverted offset.
		{"y":  9.5, "xs": [-7.0,  3.0, 13.0]},
		# Level 3 (y=6.5): cluster middle.
		{"y":  6.5, "xs": [-11.0, 0.0,  6.0]},
		# Level 4 (y=4.5): final spread before drop to gate.
		{"y":  4.5, "xs": [-5.0,  5.0, 12.0]},
	]
	var idx: int = 0
	for level in levels:
		var y: float = float(level["y"])
		for x in level["xs"]:
			var px: float = float(x)
			# Cloud platform: slightly tilted (3°) toward an alternating
			# direction so marbles don't park on top — they roll off the
			# downhill edge after a brief rest.
			var tilt: float = (-3.0 if (idx % 2 == 0) else 3.0)
			var basis := Basis(Vector3(0, 0, 1), deg_to_rad(tilt))
			TrackBlocks.add_box(clouds, "Cloud_l%d_p%d" % [int(level["y"]), idx],
				Transform3D(basis, Vector3(px, y, 0.0)),
				Vector3(CLOUD_W, CLOUD_H, CLOUD_D),
				peg_mat)
			idx += 1

func _build_gate() -> void:
	var floor_mat := TrackBlocks.std_mat_emit(_theme["gate"], 0.80, 0.25, 0.65)
	var div_mat   := TrackBlocks.std_mat_emit(_theme["accent"], 0.60, 0.30, 0.85)
	var body := StaticBody3D.new()
	body.name = "F6_SunGate"
	body.physics_material_override = _mat_gate
	add_child(body)
	TrackBlocks.build_lane_gate(body, "Gate",
		F6_Y, FIELD_W, FIELD_DEPTH, F6_LANES,
		1.5, 0.15, FLOOR_THICK, floor_mat, div_mat)

func _build_catchment() -> void:
	var mat := TrackBlocks.std_mat(Color(0.10, 0.20, 0.32), 0.20, 0.60)
	var body := StaticBody3D.new()
	body.name = "Catchment"
	body.physics_material_override = _mat_gate
	add_child(body)
	TrackBlocks.build_catchment(body, "Catch",
		FLOOR_BASE_Y, FIELD_W, FIELD_DEPTH, FLOOR_THICK, mat)

func _build_mood_lights() -> void:
	# Bright daylight: high-energy warm sun + bright sky fill.
	var key := DirectionalLight3D.new()
	key.name = "SkyKey"
	key.light_color    = Color(1.00, 0.95, 0.70)
	key.light_energy   = 1.7
	key.rotation_degrees = Vector3(-55.0, -25.0, 0.0)
	key.shadow_enabled = true
	add_child(key)
	var fill := OmniLight3D.new()
	fill.name = "SkyFill"
	fill.light_color  = Color(0.85, 0.92, 1.00)
	fill.light_energy = 1.2
	fill.omni_range   = 50.0
	fill.position     = Vector3(0.0, F4_Y, -8.0)
	add_child(fill)
	var gate_spot := OmniLight3D.new()
	gate_spot.name = "SunGold"
	gate_spot.light_color  = Color(1.00, 0.85, 0.30)
	gate_spot.light_energy = 2.2
	gate_spot.omni_range   = 14.0
	gate_spot.position     = Vector3(0.0, F6_Y + 4.0, 3.0)
	add_child(gate_spot)

# ─── Track API overrides ────────────────────────────────────────────────────

func spawn_points() -> Array:
	var pts: Array = []
	for r in range(SPAWN_ROWS):
		for c in range(SPAWN_COLS):
			var fx := (float(c) - float(SPAWN_COLS - 1) * 0.5) * SPAWN_DX
			var fz := (float(r) - float(SPAWN_ROWS - 1) * 0.5) * SPAWN_DZ
			pts.append(Vector3(fx, SPAWN_Y, fz))
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
