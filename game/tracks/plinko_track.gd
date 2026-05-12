class_name PlinkoTrack
extends Track

# PlinkoTrack v5 — split-map redesign.
#
# v5 splits the playfield into two halves with a ~32% blank gap in the
# middle, descended via 5 visible 3-D tubes at varying speeds. The
# multiplier zone is now at the END of the upper half (immediately above
# the gap), and a row of low-bounce "pin barrier" pegs below it makes it
# very rare for a marble to rebound up into a second multiplier slot.
# A short funnel deck below the pin row sorts marbles into one of the
# 5 tube entrances. Three of the tubes are SLOW (internal slalom pegs
# scrub speed via repeated bounces) and two are FAST (smooth, low-friction
# walls — marbles accelerate under gravity). Tubes deposit into a short
# lower plinko field which feeds the finish line.
#
# Layout (top → bottom):
#   y= 95     SPAWN
#   y= 93     S1 top — DESCENT peg field
#   y= 33     S1 bot
#   y= 33     BUMPER (5 m, 3-zone launcher)
#   y= 28     BUMPER bot / MULT top
#   y= 28     MULTIPLIER ZONE (7 slots, 5 m)
#   y= 23     MULT bot
#   y= 22.4   PIN BARRIER ROW (anti-rebound)
#   y= 22     FUNNEL DECK top
#   y= 21     FUNNEL DECK bot / GAP top / TUBE top
#   y=-25     GAP bot / TUBE bot — tubes empty into lower plinko
#   y=-25     LOWER PLINKO peg field
#   y=-42     LOWER PLINKO bot
#   y=-45     FINISH
#   y=-50     CATCH
#
# Status: UNTHEMED PROTOTYPE per project rule "validate patterns unthemed
# first". Theme pass overlays casino visuals on top of the same colliders.

# ─── Field shell ────────────────────────────────────────────────────────────

const FIELD_W       := 30.0
const FIELD_W_MID   := 22.0
const FIELD_DEPTH   := 3.5
const WALL_THICK    := 0.4
const FLOOR_THICK   := 0.4

# ─── Y levels ───────────────────────────────────────────────────────────────

const SPAWN_Y        := 95.0
const S1_TOP_Y       := 93.0
const S1_BOT_Y       := 33.0
const PEG_ROW_SPACING_S1 := 3.50
const BUMPER_TOP_Y   := 33.0
const BUMPER_BOT_Y   := 28.0
const MULT_TOP_Y     := 28.0
const MULT_BOT_Y     := 26.8    # 1.2 m tall — slot dividers shrink with this
const PIN_ROW_Y      := 23.0    # 3.8 m below mults — rebounds can't reach the slots
const FUNNEL_TOP_Y   := 21.5
const FUNNEL_BOT_Y   := 19.0
const TUBE_TOP_Y     := 19.0
const TUBE_BOT_Y     := -15.0    # tubes finish ~23% above the gap floor
const FREEFALL_TOP_Y := -15.0    # below tubes, open zone (TBD content)
const FREEFALL_BOT_Y := -25.5
const S2_TOP_Y       := -25.5
const S2_BOT_Y       := -42.5
const DEFLECTOR_Y    := -34.0
const SPLITTER_TOP_Y := -39.5
const SPLITTER_BOT_Y := -42.5
const FINISH_Y       := -45.0
const CATCH_Y        := -50.0
const FRAME_TOP_Y    := SPAWN_Y + 3.0
const FRAME_BOT_Y    := CATCH_Y - 1.0

# ─── Spawn grid ─────────────────────────────────────────────────────────────

const SPAWN_COLS    := 10
const SPAWN_ROWS    := 6
const SPAWN_DX      := 1.4    # 10 cols × 1.4 = 14m wide (fits FIELD_W = 26 with margin)
const SPAWN_DZ      := 0.55   # 6 rows × 0.55 = 3.3m deep (just under FIELD_DEPTH = 3.5)

# ─── Multiplier slots ───────────────────────────────────────────────────────

const SLOT_WIDTHS:       Array = [1.4, 2.2, 3.2, 6.6, 3.2, 2.2, 1.4]
const SLOT_MULTIPLIERS:  Array = [3.0, 2.0, 1.0, 0.5, 1.0, 2.0, 3.0]
const DIVIDER_THICK     := 0.2

# ─── Tube layout ────────────────────────────────────────────────────────────
#
# 4 smooth waterslide-style tubes. Each tube is a kinematic ride: a Tube
# node carries the marble along a 3-D polyline at the tube's `speed`, then
# releases it at the exit with the tangent velocity of the final segment.
# Kinematic motion (rather than physical channel walls) lets paths cross
# visually in the camera's front view — they only LOOK entwined; in 3-D
# they sit at distinct Z planes and never actually intersect.
#
# Per-tube fields:
#   path:          Array[Vector3] waypoints (X, Y, Z) for the kinematic ride.
#   speed:         m/s along the path. Slow tubes ~11; the JACKPOT tube ~20.
#   entry_size:    Vector3(W, H, D) of the Area3D trigger at path[0].
#                  T1-T3 are wide (~1.7 m); T4 is tiny (0.5 m) — only
#                  marbles landing exactly on the right funnel peak go in.
#   visual_radius: cylinder mesh radius for the visible pipe.
#   colour:        translucent emissive tint of the visible pipe.
#
# Tubes finish at TUBE_BOT_Y = -15 (~23 % above the gap floor). Below
# is an open free-fall zone (FREEFALL_TOP_Y..FREEFALL_BOT_Y) — TBD.
const TUBE_DEFS: Array = [
	# Z-layout INSIDE the frame walls (which sit at z = ±FIELD_DEPTH/2 = ±1.75).
	# 3-tube layout (T4 JACKPOT removed for now — 4 tubes geometrically
	# couldn't fit in the 3.5 m field depth at marble-passable radius).
	# Tubes at z=-1.2 / 0 / +1.2, radius 0.55: ~1.2 m centre-to-centre,
	# 0.1 m edge-to-edge gap, marble inner clearance 0.25 m per side.

	# Tube 1 (BACK, z≈-1.2) — enters left, sweeps full-width.
	{
		"path": [
			Vector3(-9.0,  19.5,  0.0),
			Vector3(-9.0,  18.0,  0.0),
			Vector3(-9.0,  17.0, -1.2),
			Vector3( 9.0,  12.0, -1.0),
			Vector3(-9.0,   5.0, -1.2),
			Vector3( 9.0,  -3.0, -1.1),
			Vector3(-5.0, -11.0, -1.2),
			Vector3(-5.0, -14.0, -0.6),
			Vector3(-5.0, -15.0,  0.0),
		],
		"speed": 11.0,
		"entry_size": Vector3(1.7, 0.8, 2.9),
		"visual_radius": 0.55,
		"colour": Color(0.40, 0.85, 1.00, 0.55),     # cyan
	},
	# Tube 2 (CENTRE, z≈0) — enters centre, opposite-phase swings.
	{
		"path": [
			Vector3( 0.0,  19.5,  0.0),
			Vector3( 0.0,  18.0,  0.0),
			Vector3( 0.0,  17.0,  0.0),
			Vector3( 9.0,  12.0,  0.1),
			Vector3(-9.0,   6.0,  0.0),
			Vector3( 9.0,  -2.0,  0.1),
			Vector3(-9.0,  -9.0,  0.0),
			Vector3( 0.0, -14.0,  0.0),
			Vector3( 0.0, -15.0,  0.0),
		],
		"speed": 11.0,
		"entry_size": Vector3(1.7, 0.8, 2.9),
		"visual_radius": 0.55,
		"colour": Color(1.00, 0.85, 0.40, 0.55),     # warm gold
	},
	# Tube 3 (FRONT, z≈+1.2) — mirror of Tube 1 in X-phase.
	{
		"path": [
			Vector3( 9.0,  19.5,  0.0),
			Vector3( 9.0,  18.0,  0.0),
			Vector3( 9.0,  17.0,  1.2),
			Vector3(-9.0,  12.0,  1.0),
			Vector3( 9.0,   6.0,  1.2),
			Vector3(-9.0,  -2.0,  1.1),
			Vector3( 9.0,  -9.0,  1.2),
			Vector3( 5.0, -14.0,  0.6),
			Vector3( 5.0, -15.0,  0.0),
		],
		"speed": 11.0,
		"entry_size": Vector3(1.7, 0.8, 2.9),
		"visual_radius": 0.55,
		"colour": Color(1.00, 0.40, 0.95, 0.55),     # magenta
	},
]
const T4_HOLE_X     := 4.5
const T4_HOLE_HALF  := 0.30   # horizontal half-width of the hole at peak

# ─── Peg dimensions ─────────────────────────────────────────────────────────

const PEG_RADIUS    := 0.32
const S1_HEX_DX     := 2.0
const S1_HEX_X_HALF := 13.0

# ─── Palette ────────────────────────────────────────────────────────────────

const COL_FRAME       := Color(0.30, 0.30, 0.35)
const COL_FLOOR       := Color(0.40, 0.40, 0.45)
const COL_PEG         := Color(0.62, 0.62, 0.66)
const COL_BUMPER      := Color(0.78, 0.78, 0.82)
const COL_DIV         := Color(0.55, 0.55, 0.60)
const COL_DIAG        := Color(0.45, 0.50, 0.55)
const COL_PIN_BARRIER := Color(0.95, 0.55, 0.20)
const COL_FUNNEL      := Color(0.50, 0.52, 0.58)
const COL_TUBE_FAST   := Color(0.35, 0.85, 1.00, 0.50)
const COL_TUBE_SLOW   := Color(1.00, 0.40, 0.95, 0.50)
const COL_SLOT_3X     := Color(0.95, 0.55, 0.20, 0.35)
const COL_SLOT_2X     := Color(0.55, 0.85, 0.35, 0.30)
const COL_SLOT_1X     := Color(0.55, 0.65, 0.95, 0.28)
const COL_SLOT_05X    := Color(0.95, 0.30, 0.30, 0.30)

# ─── Physics materials ──────────────────────────────────────────────────────

var _mat_floor:    PhysicsMaterial = null
var _mat_peg:      PhysicsMaterial = null
var _mat_wall:     PhysicsMaterial = null
var _mat_bumper:   PhysicsMaterial = null
var _mat_dampener: PhysicsMaterial = null
var _mat_smooth:   PhysicsMaterial = null

func _ready() -> void:
	_init_physics_materials()
	_build_outer_frame()
	_build_section1_descent()
	_build_section2_bumper()
	_build_section3_multipliers()
	_build_pin_barrier_row()
	_build_funnel_deck()
	_build_tubes()
	_build_section_lower_plinko()
	_build_finish_and_catchment()
	# Skip decorations in --demo mode: the M11 sky theme places billboards,
	# bleachers, and neon arrays at y=60-70 and y=2 (the "flying blocks" a
	# demo viewer sees). Real gameplay wants them; visual demos don't.
	if not _is_demo_mode():
		_build_decorations()

# Read --demo from CLI args; matches main.gd._demo_mode wiring.
func _is_demo_mode() -> bool:
	for a in OS.get_cmdline_user_args():
		if a == "--demo":
			return true
	return false

func _init_physics_materials() -> void:
	_mat_floor = PhysicsMaterial.new()
	_mat_floor.friction = 0.40
	_mat_floor.bounce   = 0.20
	# High-bounce pegs — pinball deflection per spec.
	_mat_peg = PhysicsMaterial.new()
	_mat_peg.friction = 0.15
	_mat_peg.bounce   = 0.72
	_mat_wall = PhysicsMaterial.new()
	_mat_wall.friction = 0.30
	_mat_wall.bounce   = 0.30
	_mat_bumper = PhysicsMaterial.new()
	_mat_bumper.friction = 0.10
	_mat_bumper.bounce   = 0.75
	# Pin barrier: very low bounce. An upward rebound from this row should
	# never carry enough energy to climb back into the multiplier zone above.
	_mat_dampener = PhysicsMaterial.new()
	_mat_dampener.friction = 0.50
	_mat_dampener.bounce   = 0.10
	# Fast-tube walls: near-frictionless, low bounce. Marble accelerates
	# under gravity with minimal energy loss against the channel walls.
	_mat_smooth = PhysicsMaterial.new()
	_mat_smooth.friction = 0.05
	_mat_smooth.bounce   = 0.20

# ─── Outer frame with funnel ────────────────────────────────────────────────

func _build_outer_frame() -> void:
	var wall_mat := TrackBlocks.std_mat(COL_FRAME, 0.20, 0.60)
	var frame := StaticBody3D.new()
	frame.name = "OuterFrame"
	frame.physics_material_override = _mat_wall
	add_child(frame)

	# Top stub walls
	var top_h: float = FRAME_TOP_Y - S1_TOP_Y
	var top_y: float = (FRAME_TOP_Y + S1_TOP_Y) * 0.5
	for sgn in [-1, 1]:
		var x: float = float(sgn) * (FIELD_W * 0.5 + WALL_THICK * 0.5)
		TrackBlocks.add_box(frame, "FrameTop_%s" % ("L" if sgn < 0 else "R"),
			Transform3D(Basis.IDENTITY, Vector3(x, top_y, 0.0)),
			Vector3(WALL_THICK, top_h, FIELD_DEPTH + 0.4),
			wall_mat)

	# Funnel walls — angled inward through S1.
	var s1_h: float = S1_TOP_Y - S1_BOT_Y
	var s1_y: float = (S1_TOP_Y + S1_BOT_Y) * 0.5
	var dx_top: float = FIELD_W * 0.5
	var dx_bot: float = FIELD_W_MID * 0.5
	var slab_dx: float = dx_top - dx_bot
	var slab_len: float = sqrt(s1_h * s1_h + slab_dx * slab_dx)
	var tilt: float = atan2(slab_dx, s1_h)
	for sgn in [-1, 1]:
		var center_x: float = float(sgn) * (dx_top + dx_bot) * 0.5
		var rot_amt: float = -float(sgn) * tilt
		var basis := Basis(Vector3(0, 0, 1), rot_amt)
		TrackBlocks.add_box(frame, "FrameFunnel_%s" % ("L" if sgn < 0 else "R"),
			Transform3D(basis, Vector3(center_x, s1_y, 0.0)),
			Vector3(WALL_THICK, slab_len, FIELD_DEPTH + 0.4),
			wall_mat)

	# Continuation walls — from S1 bottom down through bumper, multipliers,
	# pin row, funnel, gap, lower plinko, and finish.
	var cont_h: float = S1_BOT_Y - FRAME_BOT_Y
	var cont_y: float = (S1_BOT_Y + FRAME_BOT_Y) * 0.5
	for sgn in [-1, 1]:
		var x: float = float(sgn) * (FIELD_W_MID * 0.5 + WALL_THICK * 0.5)
		TrackBlocks.add_box(frame, "FrameCont_%s" % ("L" if sgn < 0 else "R"),
			Transform3D(Basis.IDENTITY, Vector3(x, cont_y, 0.0)),
			Vector3(WALL_THICK, cont_h, FIELD_DEPTH + 0.4),
			wall_mat)

	# Back wall
	var full_h: float = FRAME_TOP_Y - FRAME_BOT_Y
	var full_y: float = (FRAME_TOP_Y + FRAME_BOT_Y) * 0.5
	TrackBlocks.add_box(frame, "FrameBack",
		Transform3D(Basis.IDENTITY,
			Vector3(0.0, full_y, -FIELD_DEPTH * 0.5 - WALL_THICK * 0.5)),
		Vector3(FIELD_W + WALL_THICK * 2.0, full_h, WALL_THICK),
		wall_mat)

	# Front wall — collision only, camera looks through.
	TrackBlocks.add_collider_only(frame, "FrameFront",
		Transform3D(Basis.IDENTITY,
			Vector3(0.0, full_y, FIELD_DEPTH * 0.5 + WALL_THICK * 0.5)),
		Vector3(FIELD_W + WALL_THICK * 2.0, full_h, WALL_THICK))

# ─── SECTION 1 — Descent ────────────────────────────────────────────────────

func _build_section1_descent() -> void:
	var pegs := StaticBody3D.new()
	pegs.name = "S1_Pegs"
	pegs.physics_material_override = _mat_peg
	add_child(pegs)

	var slabs := StaticBody3D.new()
	slabs.name = "S1_Slabs"
	slabs.physics_material_override = _mat_wall
	add_child(slabs)

	var peg_mat := TrackBlocks.std_mat(COL_PEG, 0.10, 0.45)
	var slab_mat := TrackBlocks.std_mat(COL_DIAG, 0.20, 0.55)
	var rot_zaxis := Basis(Vector3.RIGHT, deg_to_rad(90.0))
	var peg_height: float = FIELD_DEPTH - 0.4

	# Hex-stagger row generation.
	var y: float = S1_TOP_Y - 1.0
	var row_idx: int = 0
	while y >= S1_BOT_Y + 1.0:
		var n: int = int(floor((S1_HEX_X_HALF - 0.001) / S1_HEX_DX))
		var xs: Array = []
		if row_idx % 2 == 0:
			xs.append(0.0)
			for k in range(1, n + 1):
				var dx: float = float(k) * S1_HEX_DX
				xs.append(-dx)
				xs.append(dx)
		else:
			for k in range(0, n + 1):
				var dx2: float = (float(k) + 0.5) * S1_HEX_DX
				if dx2 > S1_HEX_X_HALF:
					break
				xs.append(-dx2)
				xs.append(dx2)
		for xv in xs:
			var px: float = float(xv)
			if _peg_in_void(y, px):
				continue
			if not _peg_inside_funnel(y, px):
				continue
			TrackBlocks.add_cylinder(pegs, "Peg_y%d_x%d"
					% [int(y * 10), int(px * 10)],
				Transform3D(rot_zaxis, Vector3(px, y, 0.0)),
				PEG_RADIUS, peg_height, peg_mat)
		y -= PEG_ROW_SPACING_S1
		row_idx += 1

	# Mirrored diagonal slab pairs — adds variety to the descent.
	var slab_pairs: Array = [
		{"cy": 80.0, "cx": 8.0, "len": 5.0, "tilt": 35.0},
		{"cy": 70.0, "cx": 5.0, "len": 4.0, "tilt": 35.0},
		{"cy": 55.0, "cx": 7.0, "len": 5.0, "tilt": 35.0},
		{"cy": 45.0, "cx": 9.0, "len": 4.5, "tilt": 35.0},
	]
	for s in slab_pairs:
		var cy: float = float(s["cy"])
		var cx_mag: float = float(s["cx"])
		var slen: float = float(s["len"])
		var tilt_deg: float = float(s["tilt"])
		for sgn in [-1, 1]:
			var rot: float = float(sgn) * deg_to_rad(tilt_deg)
			var basis := Basis(Vector3(0, 0, 1), rot)
			var cx: float = float(sgn) * cx_mag
			TrackBlocks.add_box(slabs, "S1_Slab_y%d_%s"
					% [int(cy * 10), ("L" if sgn < 0 else "R")],
				Transform3D(basis, Vector3(cx, cy, 0.0)),
				Vector3(slen, 0.3, FIELD_DEPTH - 0.4),
				slab_mat)

func _peg_in_void(y: float, x: float) -> bool:
	if y >= 83.0 and y <= 88.0 and abs(x) > 10.0:
		return true
	if y >= 68.0 and y <= 72.0 and abs(x) < 3.0:
		return true
	if y >= 50.0 and y <= 56.0 and abs(x) > 9.0:
		return true
	if y >= 38.0 and y <= 42.0 and abs(x) < 2.5:
		return true
	return false

func _peg_inside_funnel(y: float, x: float) -> bool:
	var t: float = clampf((S1_TOP_Y - y) / (S1_TOP_Y - S1_BOT_Y), 0.0, 1.0)
	var half_w: float = lerp(FIELD_W * 0.5, FIELD_W_MID * 0.5, t)
	return abs(x) < half_w - PEG_RADIUS - 0.3

# ─── SECTION 2 — Bumper ────────────────────────────────────────────────────

func _build_section2_bumper() -> void:
	var bumpers := StaticBody3D.new()
	bumpers.name = "S2_Bumpers"
	bumpers.physics_material_override = _mat_bumper
	add_child(bumpers)

	var bump_mat := TrackBlocks.std_mat_emit(COL_BUMPER, 0.30, 0.35, 0.20)
	var peak_y: float = BUMPER_TOP_Y - 1.2

	# Central peak — 3-zone launcher per spec.
	var peak_half_w: float = 1.4
	for sgn in [-1, 1]:
		var rot_amt: float = float(sgn) * deg_to_rad(45.0)
		var basis := Basis(Vector3(0, 0, 1), rot_amt)
		var cx: float = -float(sgn) * peak_half_w * 0.5
		TrackBlocks.add_box(bumpers, "Bumper_Peak_%s" % ("L" if sgn < 0 else "R"),
			Transform3D(basis, Vector3(cx, peak_y - 0.4, 0.0)),
			Vector3(peak_half_w * 1.4, 0.35, FIELD_DEPTH - 0.4),
			bump_mat)

	for sgn in [-1, 1]:
		var rot_amt: float = float(sgn) * deg_to_rad(30.0)
		var basis := Basis(Vector3(0, 0, 1), rot_amt)
		var cx: float = float(sgn) * 3.0
		TrackBlocks.add_box(bumpers, "Bumper_InnerWing_%s" % ("L" if sgn < 0 else "R"),
			Transform3D(basis, Vector3(cx, peak_y - 1.2, 0.0)),
			Vector3(1.8, 0.35, FIELD_DEPTH - 0.4),
			bump_mat)

	for sgn in [-1, 1]:
		var rot_amt: float = float(sgn) * deg_to_rad(38.0)
		var basis := Basis(Vector3(0, 0, 1), rot_amt)
		var cx: float = float(sgn) * 7.5
		TrackBlocks.add_box(bumpers, "Bumper_OuterWing_%s" % ("L" if sgn < 0 else "R"),
			Transform3D(basis, Vector3(cx, peak_y - 2.0, 0.0)),
			Vector3(2.8, 0.4, FIELD_DEPTH - 0.4),
			bump_mat)

# ─── SECTION 3 — Multiplier zone ────────────────────────────────────────────
#
# Now positioned at the END of the upper half, immediately above the gap.
# Geometry / payouts are unchanged from v4 — only the Y range moved.

func _build_section3_multipliers() -> void:
	var dividers := StaticBody3D.new()
	dividers.name = "S3_Dividers"
	dividers.physics_material_override = _mat_wall
	add_child(dividers)

	var div_mat := TrackBlocks.std_mat(COL_DIV, 0.20, 0.55)

	var total_slot_w: float = 0.0
	for w in SLOT_WIDTHS:
		total_slot_w += float(w)
	var total_dividers_w: float = float(SLOT_WIDTHS.size() - 1) * DIVIDER_THICK
	var total_w: float = total_slot_w + total_dividers_w
	var x_cursor: float = -total_w * 0.5

	var slot_centres: Array = []
	var slot_widths_actual: Array = []
	var slot_h: float = MULT_TOP_Y - MULT_BOT_Y
	var slot_mid_y: float = (MULT_TOP_Y + MULT_BOT_Y) * 0.5

	for i in range(SLOT_WIDTHS.size()):
		var sw: float = float(SLOT_WIDTHS[i])
		var slot_centre: float = x_cursor + sw * 0.5
		slot_centres.append(slot_centre)
		slot_widths_actual.append(sw)
		x_cursor += sw
		if i < SLOT_WIDTHS.size() - 1:
			var div_x: float = x_cursor + DIVIDER_THICK * 0.5
			x_cursor += DIVIDER_THICK
			TrackBlocks.add_box(dividers, "Div_%d" % i,
				Transform3D(Basis.IDENTITY, Vector3(div_x, slot_mid_y, 0.0)),
				Vector3(DIVIDER_THICK, slot_h, FIELD_DEPTH - 0.4),
				div_mat)

	for i in range(SLOT_WIDTHS.size()):
		var sw_actual: float = float(slot_widths_actual[i])
		var cx: float = float(slot_centres[i])
		var mult: float = float(SLOT_MULTIPLIERS[i])
		var tier: int = PickupZone.TIER_2 if mult >= 2.0 else PickupZone.TIER_1
		var col: Color = _slot_colour_for(mult)
		var mat := TrackBlocks.std_mat_emit(col, 0.0, 0.40, 0.50)
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		# Stable depth write so marbles passing through the slot zone don't
		# flicker against the transparent box surface (same fix applied to
		# the smooth tubes for the same reason).
		mat.depth_draw_mode = BaseMaterial3D.DEPTH_DRAW_ALWAYS
		var size := Vector3(sw_actual - 0.4, slot_h - 0.6, FIELD_DEPTH - 0.6)
		var zone := TrackBlocks.add_pickup_zone(self,
			"Slot_%d_%sx" % [i + 1, _mult_label(mult)],
			Transform3D(Basis.IDENTITY, Vector3(cx, slot_mid_y, 0.0)),
			size, tier, mat)
		zone.set_meta("multiplier_value", mult)

func _slot_colour_for(mult: float) -> Color:
	if is_equal_approx(mult, 3.0):
		return COL_SLOT_3X
	if is_equal_approx(mult, 2.0):
		return COL_SLOT_2X
	if is_equal_approx(mult, 1.0):
		return COL_SLOT_1X
	return COL_SLOT_05X

func _mult_label(mult: float) -> String:
	if is_equal_approx(mult, 0.5):
		return "0p5"
	return "%d" % int(mult)

# ─── PIN BARRIER ROW — anti-rebound ─────────────────────────────────────────
#
# Single row of low-bounce horizontal cylinder pegs immediately below the
# multiplier zone. With bounce=0.10 the steepest realistic incoming speeds
# (~25 m/s in extreme cases) rebound at ≤2.5 m/s, climbing only ~0.32 m —
# well short of the 0.6 m it would need to clear MULT_BOT_Y back into a
# multiplier slot. Combined with the dividers above, second pickups become
# exceedingly rare.

func _build_pin_barrier_row() -> void:
	var pins := StaticBody3D.new()
	pins.name = "PinBarrier"
	pins.physics_material_override = _mat_dampener
	add_child(pins)
	var mat := TrackBlocks.std_mat_emit(COL_PIN_BARRIER, 0.20, 0.40, 0.30)
	var rot := Basis(Vector3.RIGHT, deg_to_rad(90.0))
	var peg_height: float = FIELD_DEPTH - 0.4

	# 15 pegs spaced ~1.43 m apart, covering -10..+10. Denser than the
	# original 9-peg layout so a falling marble has more chances to hit a
	# peg and get redirected laterally — combined with the very low bounce
	# coefficient, second pickups remain statistically negligible. Spacing
	# stays well above peg_dia (0.64 m) + marble_dia (0.6 m) = 1.24 m so
	# marbles never get wedged between adjacent pegs.
	var n_pins: int = 15
	var span: float = 20.0
	var dx: float = span / float(n_pins - 1)
	for i in range(n_pins):
		var x: float = -span * 0.5 + float(i) * dx
		TrackBlocks.add_cylinder(pins, "Pin_%d" % i,
			Transform3D(rot, Vector3(x, PIN_ROW_Y, 0.0)),
			PEG_RADIUS, peg_height, mat)

# ─── FUNNEL DECK — sorts marbles into 4 tube entrances ──────────────────────
#
# Below the pin row, inverted-V slab pairs guide marbles into the 3 main
# tube openings (T1/T2/T3 entries at x=-9, 0, +9). The right inter-tube
# peak (apex at x=+4.5) carries the JACKPOT tube T4 directly under its
# apex — so the slab pair on that side has a small T4_HOLE_HALF*2 hole
# at the apex, and a marble landing exactly on the peak drops through
# rather than sliding off into T2 or T3. Most marbles hit the slabs
# off-apex and slide to T2 or T3, making T4 statistically rare.
# Slabs tilt 30° — shallow enough to fit inside the deck height even for
# the 9-m gaps between widely-spaced tubes.

func _build_funnel_deck() -> void:
	var deck := StaticBody3D.new()
	deck.name = "FunnelDeck"
	deck.physics_material_override = _mat_wall
	add_child(deck)
	var mat := TrackBlocks.std_mat(COL_FUNNEL, 0.10, 0.55)

	var deck_y: float = (FUNNEL_TOP_Y + FUNNEL_BOT_Y) * 0.5
	var slab_t: float = 0.3
	var tilt_deg: float = 30.0

	# Main tube entry X positions (T1/T2/T3 — wide entries). T4's tiny
	# entrance is handled separately as a hole in the peak between T2 and T3.
	var main_entry_xs: Array = []
	for def in TUBE_DEFS:
		var path: Array = def["path"]
		var entry_w: float = float((def["entry_size"] as Vector3).x)
		# Treat anything narrower than 1.0 m as a "secret hole"; not part of
		# the regular funnel routing.
		if entry_w >= 1.0:
			main_entry_xs.append(float((path[0] as Vector3).x))
	main_entry_xs.sort()

	var entry_half_w: float = 0.85    # half of the wide entries' X size
	var left_wall_x: float  = -FIELD_W_MID * 0.5
	var right_wall_x: float =  FIELD_W_MID * 0.5

	# Left edge slab — tilts down-right toward the leftmost tube.
	var t_first_left: float = float(main_entry_xs[0]) - entry_half_w
	if t_first_left > left_wall_x + 0.1:
		var slab_len: float = t_first_left - left_wall_x
		var slab_cx: float = (left_wall_x + t_first_left) * 0.5
		var basis := Basis(Vector3(0, 0, 1), -deg_to_rad(tilt_deg))
		TrackBlocks.add_box(deck, "Funnel_LeftEdge",
			Transform3D(basis, Vector3(slab_cx, deck_y, 0.0)),
			Vector3(slab_len, slab_t, FIELD_DEPTH - 0.4),
			mat)

	# Inter-tube peaks. The peak between T2 and T3 (peak_cx ≈ +4.5) gets
	# split with a T4_HOLE_HALF-wide hole at its apex.
	for i in range(main_entry_xs.size() - 1):
		var ta_right: float = float(main_entry_xs[i])     + entry_half_w
		var tb_left: float  = float(main_entry_xs[i + 1]) - entry_half_w
		var peak_cx: float  = (ta_right + tb_left) * 0.5
		var has_hole: bool  = abs(peak_cx - T4_HOLE_X) < 0.5
		# Left half — tilts down-left toward T_i.
		var l_far: float    = ta_right
		var l_near: float   = (peak_cx - T4_HOLE_HALF) if has_hole else peak_cx
		var l_len: float    = l_near - l_far
		if l_len > 0.05:
			var lcx: float = (l_far + l_near) * 0.5
			var bL := Basis(Vector3(0, 0, 1), deg_to_rad(tilt_deg))
			TrackBlocks.add_box(deck, "Funnel_PeakL_%d" % i,
				Transform3D(bL, Vector3(lcx, deck_y, 0.0)),
				Vector3(l_len, slab_t, FIELD_DEPTH - 0.4),
				mat)
		# Right half — tilts down-right toward T_{i+1}.
		var r_near: float   = (peak_cx + T4_HOLE_HALF) if has_hole else peak_cx
		var r_far: float    = tb_left
		var r_len: float    = r_far - r_near
		if r_len > 0.05:
			var rcx: float = (r_near + r_far) * 0.5
			var bR := Basis(Vector3(0, 0, 1), -deg_to_rad(tilt_deg))
			TrackBlocks.add_box(deck, "Funnel_PeakR_%d" % i,
				Transform3D(bR, Vector3(rcx, deck_y, 0.0)),
				Vector3(r_len, slab_t, FIELD_DEPTH - 0.4),
				mat)

	# Right edge slab — tilts down-left toward the rightmost tube.
	var t_last_right: float = float(main_entry_xs[main_entry_xs.size() - 1]) + entry_half_w
	if t_last_right < right_wall_x - 0.1:
		var slab_len: float = right_wall_x - t_last_right
		var slab_cx: float = (t_last_right + right_wall_x) * 0.5
		var basis := Basis(Vector3(0, 0, 1), deg_to_rad(tilt_deg))
		TrackBlocks.add_box(deck, "Funnel_RightEdge",
			Transform3D(basis, Vector3(slab_cx, deck_y, 0.0)),
			Vector3(slab_len, slab_t, FIELD_DEPTH - 0.4),
			mat)

# ─── 3-D TUBES — kinematic waterslides ──────────────────────────────────────
#
# Each tube is a Tube node carrying its own Area3D entry trigger and
# tracking marbles in transit. When a marble enters the trigger at the top
# of the tube, the Tube freezes its physics and slides it along the path
# at TUBE_TRANSIT_SPEED (kinematic motion); at the last waypoint the marble
# is unfrozen with the tangent velocity of the final segment so it falls
# naturally into whatever sits below the tube exit.
#
# Visuals: a chain of translucent CylinderMesh segments traces the path,
# plus glowing rings at the entry and exit.

func _build_tubes() -> void:
	var root := Node3D.new()
	root.name = "Tubes"
	add_child(root)
	for i in range(TUBE_DEFS.size()):
		_build_one_tube(root, i, TUBE_DEFS[i] as Dictionary)

func _build_one_tube(root: Node, idx: int, def: Dictionary) -> void:
	var path: Array = (def["path"] as Array).duplicate()
	var glow: Color = def["colour"]
	var visual_r: float = float(def["visual_radius"])

	# Real physics tube: build the visible swept mesh AND a matching
	# ConcavePolygonShape3D trimesh collider from the same vertices so
	# marbles physically roll through the inside surface. The old Tube
	# Area3D+kinematic-transport class is no longer instantiated — pipe
	# motion is now gravity + friction + walls, not a position snap.
	var pipe_mat := TrackBlocks.std_mat_emit(glow, 0.15, 0.30, 0.25)
	pipe_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	pipe_mat.depth_draw_mode = BaseMaterial3D.DEPTH_DRAW_ALWAYS
	# CULL_BACK: outer shell renders from outside; inner shell (built
	# below with inverted winding) renders from inside. Each surface is
	# correctly lit. CULL_DISABLED was producing alternating front/back
	# lighting bands along the curve ('buggy stripes') — a true two-shell
	# tube fixes it without the lighting weirdness.

	# OUTER shell (radius = visual_r). Visible from outside the tube.
	var pipe_mesh_inst: MeshInstance3D = TrackBlocks.add_smooth_tube(self,
			"Pipe_smooth_%d" % idx, path, visual_r, pipe_mat, 0.25, 18)

	# INNER shell (radius slightly smaller + inverted winding). The
	# normals now point inward; with CULL_BACK only the inside surface
	# renders, so a camera (or marble) inside the tube sees a properly-lit
	# wall instead of looking through to the other side.
	TrackBlocks.add_smooth_tube(self, "Pipe_inner_%d" % idx, path,
			visual_r * 0.93, pipe_mat, 0.25, 18, true)

	# Physics collider — same mesh, ConcavePolygonShape3D with
	# backface_collision so marbles inside the hollow cylinder collide
	# with the inner surface (which from the trimesh's POV is the back
	# face). CCD on marbles prevents tunneling through this thin shell.
	if pipe_mesh_inst != null and pipe_mesh_inst.mesh != null:
		var body := StaticBody3D.new()
		body.name = "Pipe_body_%d" % idx
		body.physics_material_override = _mat_smooth
		var coll := CollisionShape3D.new()
		var trimesh: ConcavePolygonShape3D = pipe_mesh_inst.mesh.create_trimesh_shape()
		trimesh.backface_collision = true
		coll.shape = trimesh
		body.add_child(coll)
		add_child(body)

	# Funnels removed entirely. Earlier attempt with a visible CylinderMesh
	# cone read as 'tilted nipples' protruding from the funnel deck;
	# replacing with an invisible-collider was rejected by the user as a
	# hack (see feedback_no_invisible_colliders.md). With wider tube radii
	# the funnel-deck gap and tube mouth are close enough in width that
	# most marbles enter cleanly without a separate funnel object.

# ─── LOWER PLINKO — receives tube exits, leads to finish ────────────────────

func _build_section_lower_plinko() -> void:
	var pegs := StaticBody3D.new()
	pegs.name = "S2_Pegs"
	pegs.physics_material_override = _mat_peg
	add_child(pegs)
	var deflectors := StaticBody3D.new()
	deflectors.name = "S2_Deflectors"
	deflectors.physics_material_override = _mat_floor
	add_child(deflectors)

	var peg_mat := TrackBlocks.std_mat(COL_PEG, 0.10, 0.45)
	var floor_mat := TrackBlocks.std_mat(COL_FLOOR, 0.20, 0.55)
	var rot_zaxis := Basis(Vector3.RIGHT, deg_to_rad(90.0))
	var peg_height: float = FIELD_DEPTH - 0.4

	# Hex-staggered peg field below the gap. Rows alternate a 2.0 m offset
	# so that each tube exit X always has at least one row of pegs ~2 m below.
	var y: float = S2_TOP_Y - 1.5
	var row_idx: int = 0
	while y >= S2_BOT_Y + 1.0:
		var xs: Array = []
		if row_idx % 2 == 0:
			xs = [-8.0, -4.0, 0.0, 4.0, 8.0]
		else:
			xs = [-10.0, -6.0, -2.0, 2.0, 6.0, 10.0]
		for x in xs:
			TrackBlocks.add_cylinder(pegs, "S2_Peg_y%d_x%d"
					% [int(y * 10), int(float(x) * 10)],
				Transform3D(rot_zaxis, Vector3(float(x), y, 0.0)),
				0.30, peg_height, peg_mat)
		y -= 2.0
		row_idx += 1

	# Single row of catch-up deflectors — nudges stragglers back toward centre.
	for sgn in [-1, 1]:
		var rot: float = float(sgn) * deg_to_rad(35.0)
		var basis := Basis(Vector3(0, 0, 1), rot)
		var cx: float = float(sgn) * 8.0
		TrackBlocks.add_box(deflectors,
			"S2_Deflector_%s" % ("L" if sgn < 0 else "R"),
			Transform3D(basis, Vector3(cx, DEFLECTOR_Y, 0.0)),
			Vector3(5.0, 0.4, FIELD_DEPTH - 0.4),
			floor_mat)

	# Final centre splitter — last position swap before the finish line.
	var split_basis := Basis(Vector3(0, 0, 1), deg_to_rad(2.0))
	var split_mid: float = (SPLITTER_TOP_Y + SPLITTER_BOT_Y) * 0.5
	var split_h: float   = SPLITTER_TOP_Y - SPLITTER_BOT_Y
	TrackBlocks.add_box(deflectors, "S2_Splitter",
		Transform3D(split_basis, Vector3(0.0, split_mid, 0.0)),
		Vector3(0.4, split_h, FIELD_DEPTH - 0.4),
		floor_mat)

# ─── Finish line floor + catchment ──────────────────────────────────────────

func _build_finish_and_catchment() -> void:
	var well := StaticBody3D.new()
	well.name = "Catchment"
	well.physics_material_override = _mat_floor
	add_child(well)
	var mat := TrackBlocks.std_mat(Color(0.10, 0.10, 0.12), 0.10, 0.70)
	TrackBlocks.build_catchment(well, "Catch",
		CATCH_Y, FIELD_W_MID, FIELD_DEPTH, FLOOR_THICK, mat)

# ─── Track API ──────────────────────────────────────────────────────────────

func spawn_points() -> Array:
	var pts: Array = []
	for r in range(SPAWN_ROWS):
		for c in range(SPAWN_COLS):
			var fx: float = (float(c) - float(SPAWN_COLS - 1) * 0.5) * SPAWN_DX
			var fz: float = (float(r) - float(SPAWN_ROWS - 1) * 0.5) * SPAWN_DZ
			pts.append(Vector3(fx, SPAWN_Y, fz))
	return pts

func finish_area_transform() -> Transform3D:
	return Transform3D(Basis.IDENTITY, Vector3(0.0, FINISH_Y, 0.0))

func finish_area_size() -> Vector3:
	return Vector3(FIELD_W_MID + 2.0, 3.0, FIELD_DEPTH + 1.0)

func camera_bounds() -> AABB:
	var min_v := Vector3(-FIELD_W * 0.5 - 1.0, FRAME_BOT_Y - 1.0, -FIELD_DEPTH * 0.5 - 1.0)
	var max_v := Vector3( FIELD_W * 0.5 + 1.0, FRAME_TOP_Y + 1.0,  FIELD_DEPTH * 0.5 + 1.0)
	return AABB(min_v, max_v - min_v)

func camera_pose() -> Dictionary:
	var mid_y: float = (FRAME_TOP_Y + FRAME_BOT_Y) * 0.5
	return {
		"position": Vector3(0.0, mid_y, 175.0),
		"target":   Vector3(0.0, mid_y, 0.0),
		"fov":      46.0,
	}

func environment_overrides() -> Dictionary:
	return {
		"sky_top":        Color(0.30, 0.55, 0.95),
		"sky_horizon":    Color(0.95, 0.92, 0.78),
		"ambient_energy": 1.20,
		"fog_color":      Color(0.85, 0.90, 1.00),
		"fog_density":    0.0008,
		"sun_color":      Color(1.00, 0.95, 0.70),
		"sun_energy":     1.7,
	}

# ─── Decoration props (visual-only, NO collision) ───────────────────────────
# Sky / Plinko theme: cloud-white bleachers high above, sun-gold "SKY RUN"
# banners, cloud-puff particles drifting sideways, warm golden neon.
func _build_decorations() -> void:
	var deco := Node3D.new()
	deco.name = "Decorations"
	add_child(deco)

	# Plinko is very tall (y=-50..y=98). Place two stand clusters:
	# Upper cluster around the S1 descent midpoint (~y=63), and lower cluster
	# near the tube zone (~y=2). Both at Z ±10 outside FIELD_DEPTH/2=1.75.
	var sky_bodies: Array = [
		Color(0.92, 0.92, 0.98), Color(0.65, 0.85, 1.00),
		Color(0.95, 0.85, 0.55), Color(0.55, 0.78, 0.95),
		Color(0.80, 0.92, 1.00), Color(0.75, 0.88, 0.60),
	]
	var head_col := Color(0.95, 0.90, 0.80)

	for side in [-1, 1]:
		var z_near: float = float(side) * 8.0
		var z_far: float  = float(side) * 10.5
		# Upper stands (around upper S1 descent, y≈63)
		TrackBlocks.build_spectator_row(deco, "SkyStandUpper_S%d_R0" % side,
			Vector3(0.0, 60.0, z_near), 18, 1.8, sky_bodies, head_col)
		TrackBlocks.build_spectator_row(deco, "SkyStandUpper_S%d_R1" % side,
			Vector3(0.0, 61.5, z_far),  18, 1.8, sky_bodies, head_col)
		# Lower stands (around tube exit zone, y≈0)
		TrackBlocks.build_spectator_row(deco, "SkyStandLower_S%d_R0" % side,
			Vector3(0.0, -2.0, z_near), 18, 1.8, sky_bodies, head_col)
		TrackBlocks.build_spectator_row(deco, "SkyStandLower_S%d_R1" % side,
			Vector3(0.0, -0.5, z_far),  18, 1.8, sky_bodies, head_col)

	# --- Billboards: sun-gold + sky-blue at top and bottom of track
	var sign_cols: Array = [
		Color(1.00, 0.90, 0.30),   # sun gold
		Color(0.55, 0.85, 1.00),   # sky blue
		Color(1.00, 0.80, 0.20),   # amber
		Color(0.35, 0.80, 1.00),   # deep sky
	]
	# Upper row of signs near spawn
	var upper_xs: Array = [-10.0, 0.0, 10.0]
	for i in range(upper_xs.size()):
		var bx: float = float(upper_xs[i])
		TrackBlocks.build_billboard(deco, "SkySignTop_%d" % i,
			Transform3D(Basis.IDENTITY,
				Vector3(bx, SPAWN_Y + 2.0, -FIELD_DEPTH * 0.5 - 1.5)),
			Vector3(7.5, 2.5, 0.18), sign_cols[i % sign_cols.size()], 3.0)
	# Lower row near finish
	var lower_xs: Array = [-8.0, 0.0, 8.0]
	for i in range(lower_xs.size()):
		var bx: float = float(lower_xs[i])
		TrackBlocks.build_billboard(deco, "SkySignBot_%d" % i,
			Transform3D(Basis.IDENTITY,
				Vector3(bx, FINISH_Y - 3.0, -FIELD_DEPTH * 0.5 - 1.5)),
			Vector3(6.5, 2.0, 0.18), sign_cols[(i + 1) % sign_cols.size()], 2.8)

	# --- Neon accent lights: golden daylight brackets
	var neon_cols: Array = [
		Color(1.00, 0.90, 0.30),
		Color(0.55, 0.85, 1.00),
		Color(1.00, 0.90, 0.30),
	]
	TrackBlocks.build_neon_array(deco, "SkyNeonUpper_Pos",
		65.0, 9.0, [-12.0, 0.0, 12.0], neon_cols, 2.0, 28.0)
	TrackBlocks.build_neon_array(deco, "SkyNeonUpper_Neg",
		65.0, -9.0, [-12.0, 0.0, 12.0], neon_cols, 2.0, 28.0)
	TrackBlocks.build_neon_array(deco, "SkyNeonLower_Pos",
		2.0, 9.0, [-10.0, 0.0, 10.0], neon_cols, 2.0, 22.0)
	TrackBlocks.build_neon_array(deco, "SkyNeonLower_Neg",
		2.0, -9.0, [-10.0, 0.0, 10.0], neon_cols, 2.0, 22.0)

	# --- Ambient particles: cloud puffs + sparkle sun-beams
	# Upper cloud puffs
	TrackBlocks.build_ambient_particles(deco, "SkyClouds",
		Vector3(0.0, 70.0, 0.0),
		50, 15.0,
		Color(0.95, 0.95, 1.00, 0.75),
		Vector3(0.3, -0.1, 0.0),          # gentle sideways drift
		14.0, 5.0, 1.5,
		0.05, 0.25,
		0.08, 0.22)
	# Golden sun-sparkle near tubes
	TrackBlocks.build_ambient_particles(deco, "SkySparks",
		Vector3(0.0, 10.0, 0.0),
		40, 8.0,
		Color(1.00, 0.95, 0.60, 0.90),
		Vector3(0.0, 0.5, 0.0),
		12.0, 4.0, 1.5,
		0.1, 0.5,
		0.03, 0.08)

# ─── Tube — kinematic waterslide ────────────────────────────────────────────
#
# A Tube hosts an Area3D entry trigger at the first waypoint of `path`.
# When a marble enters, the Tube freezes the marble's RigidBody3D and
# advances it along `path` at `transit_speed` each physics tick. When
# progress reaches the end of the path the marble is unfrozen with the
# tangent velocity of the final segment, so it falls naturally into the
# free-fall zone below the tube exits.
#
# Determinism: positions are sampled along the polyline at fixed delta,
# so given identical entry tick the marble always exits at the same tick.
# Replay-stable.

class Tube extends Node3D:
	var path: Array = []
	var transit_speed: float = 11.0
	var entry_size: Vector3 = Vector3(1.7, 0.8, 3.0)

	var _entry: Area3D
	var _seg_lens: Array = []
	var _path_length: float = 0.0
	var _transits: Dictionary = {}    # RigidBody3D -> progress (float)

	func _ready() -> void:
		# Cache segment lengths for fast progress→position lookup.
		for i in range(path.size() - 1):
			var seg_len: float = ((path[i + 1] as Vector3) - (path[i] as Vector3)).length()
			_seg_lens.append(seg_len)
			_path_length += seg_len

		# Entry trigger sits at the first waypoint, sized to catch any marble
		# the funnel deck delivers near the entrance X.
		_entry = Area3D.new()
		_entry.name = "TubeEntry"
		_entry.monitoring = true
		_entry.monitorable = false
		var coll := CollisionShape3D.new()
		coll.name = "TubeEntry_shape"
		var box := BoxShape3D.new()
		box.size = entry_size
		coll.shape = box
		_entry.add_child(coll)
		var entry_pos: Vector3 = path[0]
		_entry.global_transform = Transform3D(Basis.IDENTITY,
			Vector3(entry_pos.x, entry_pos.y - entry_size.y * 0.5, entry_pos.z))
		add_child(_entry)
		_entry.body_entered.connect(_on_body_entered)

	func _on_body_entered(body: Node) -> void:
		if not body is RigidBody3D:
			return
		if not String(body.name).begins_with("Marble_"):
			return
		var rb := body as RigidBody3D
		if _transits.has(rb):
			return
		# Switch to kinematic-frozen so we own its position while in transit.
		rb.freeze_mode = RigidBody3D.FREEZE_MODE_KINEMATIC
		rb.freeze = true
		rb.linear_velocity = Vector3.ZERO
		rb.angular_velocity = Vector3.ZERO
		rb.global_position = path[0]
		_transits[rb] = 0.0

	func _physics_process(delta: float) -> void:
		if _transits.is_empty():
			return
		var step: float = transit_speed * delta
		var done: Array = []
		for key in _transits.keys():
			var rb: RigidBody3D = key
			var progress: float = float(_transits[rb]) + step
			if progress >= _path_length:
				# Release at the exit with tangent velocity of the last
				# segment, and carry a roll-spin so it keeps tumbling for
				# a beat after leaving the tube (looks like it has momentum,
				# not just a position-snapped pose).
				var n: int = path.size()
				var last_dir: Vector3 = ((path[n - 1] as Vector3) - (path[n - 2] as Vector3)).normalized()
				rb.global_position = path[n - 1]
				rb.freeze = false
				rb.linear_velocity = last_dir * transit_speed
				var roll_axis: Vector3 = last_dir.cross(Vector3.UP)
				if roll_axis.length_squared() < 0.001:
					roll_axis = last_dir.cross(Vector3.RIGHT)
				rb.angular_velocity = roll_axis.normalized() * (transit_speed / 0.3)
				done.append(rb)
			else:
				var old_pos: Vector3 = rb.global_position
				var new_pos: Vector3 = _sample_path(progress)
				rb.global_position = new_pos
				# Tumble during kinematic transit. Roll-without-slipping:
				# angular displacement per step = (linear step) / radius.
				# Spin axis = motion direction × world up (perpendicular to
				# the path, in the marble's horizontal plane). The marble
				# now visibly rotates as it slides through the tube rather
				# than gliding pose-locked on rails.
				var motion: Vector3 = new_pos - old_pos
				var motion_len: float = motion.length()
				if motion_len > 1e-5:
					var tangent: Vector3 = motion / motion_len
					var spin_axis: Vector3 = tangent.cross(Vector3.UP)
					if spin_axis.length_squared() < 0.001:
						spin_axis = tangent.cross(Vector3.RIGHT)
					spin_axis = spin_axis.normalized()
					var spin_angle: float = motion_len / 0.3   # marble radius
					var spin_basis: Basis = Basis(spin_axis, spin_angle)
					rb.transform.basis = spin_basis * rb.transform.basis
				_transits[rb] = progress
		for rb in done:
			_transits.erase(rb)

	func _sample_path(progress: float) -> Vector3:
		var accum: float = 0.0
		for i in range(_seg_lens.size()):
			var seg_len: float = float(_seg_lens[i])
			if accum + seg_len >= progress:
				var t: float = (progress - accum) / seg_len if seg_len > 0.0 else 0.0
				return (path[i] as Vector3).lerp(path[i + 1] as Vector3, t)
			accum += seg_len
		return path[path.size() - 1]
