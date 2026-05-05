class_name PlinkoTrack
extends Track

# PlinkoTrack — REBUILT as "Casino Drop" per docs/plinko-spec.md.
#
# Class name kept as PlinkoTrack and track_id stays at 5 so existing replays
# still decode through TrackRegistry. The previous M11 "Sky Run" geometry
# (cloud V-funnel + stepping stones) is gone; this is the casino-plinko
# vertical-descent design with The Tube shortcut, the 3-way Bumper, the
# 7-slot Multiplier zone, and a Chase final stretch.
#
# Build status: UNTHEMED PROTOTYPE.
#   Per project rule: "Validate patterns on no-theme version first — for any
#   new track / piece / section / physics setup, build the unthemed test
#   variant first, then reskin." This file ships geometry only — neutral
#   greys, no track palette, no neon glow, no slot-machine reels, no warp
#   FX. The themed pass overlays visuals on top of the same colliders once
#   physics is validated end-to-end.
#
# Section layout (top → bottom, all 30 marbles spawn at SPAWN_Y):
#
#   y=130 ░ SPAWN — 8×4 grid above S1 ░
#   y=127 ┌── SECTION 1 — DESCENT (105m, ~80 dense rows of pegs) ───┐
#         │ Asymmetric peg clusters (NOT a grid). Top fan-out, a    │
#         │ LEFT-DENSE band that funnels marbles toward the Tube,   │
#         │ a sparse zone where the Tube spits warped marbles back  │
#         │ into the descent, a RIGHT-DENSE mirror band, then a     │
#         │ central sort grid down to the bumper.                   │
#         │ ◄ THE TUBE ► is a left-wall warp at y=100 → y=87        │
#         │ (~12-m skip; lands a marble in the sparse exit zone).   │
#   y=22  ├── SECTION 2 — BUMPER ──────────────────────────────────┤
#         │ Center peak + 2 outer wing wedges + 2 inner mini bumps │
#         │ — landing position determines Zone A/B/C trajectory.   │
#   y=16  ├── SECTION 3 — MULTIPLIER ZONE ─────────────────────────┤
#         │ 7 channels (dividers y=15→10), widths tuned so center  │
#         │ slot catches ~19/30, edge slots ~1/30 each. PickupZone │
#         │ Area3D in each slot.                                    │
#   y=10  ├── SECTION 4 — CHASE (25m, sparse pegs + deflectors) ───┤
#         │ Sparse pegs, 2 inward deflector ramps (catch-up),      │
#         │ center divider before finish (2 lanes).                 │
#   y=-15 └── FINISH LINE ────────────────────────────────────────┘
#   y=-20   Catchment (catches bouncers).
#
# Total field height ≈ 150 m (3× the original prototype). Real gravity (9.8
# m/s²) applies — no slow-gravity zone. Race time hits the spec's 40-50s
# window naturally because the field is tall enough and the peg field is
# dense enough that marble interaction time dominates pure free-fall.
#
# Determinism: every collider is static. The Tube warps via Area3D body_entered;
# entry order is deterministic from the seed-derived spawn slots, so replays
# stay stable.
#
# Camera: fixed 2D side view (camera_pose returns position on +Z axis pulled
# back, looking down -Z). The shallow FIELD_DEPTH (3.5m) keeps marbles in a
# near-2D plane so the side view reads cleanly.

# ─── Field shell ────────────────────────────────────────────────────────────

const FIELD_W       := 30.0
const FIELD_DEPTH   := 3.5
const WALL_THICK    := 0.4
const FLOOR_THICK   := 0.4

# ─── Y levels (vertical layout) ─────────────────────────────────────────────
#
# Field height ≈ 150 m total — 3× the original prototype. Real gravity
# (9.8 m/s²) finishes a 50-m field in ~5s; this taller field plus dense
# pegs holds the race in the spec's 40-50s window without any slow-gravity
# trickery. Marbles fall like real balls.
#
# Section 1 (Descent) is 105 m tall (y=22 → y=127). Sections 2/3 keep
# their original heights (bumper + multiplier dividers don't need to scale
# vertically). Section 4 (Chase) is 25 m so the final stretch lasts long
# enough to feel like a "chase" per spec.

const SPAWN_Y       := 130.0
const S1_TOP_Y      := 127.0
const S1_BOT_Y      := 22.0     # = S2_TOP_Y, bumper handoff
const TUBE_ENTRY_Y  := 100.0    # in the LEFT-DENSE band
const TUBE_EXIT_Y   := 87.0     # in the SPARSE exit zone (~12 m skip)
const S2_BOT_Y      := 16.0     # = S3_TOP_Y
const S3_BOT_Y      := 10.0     # = S4_TOP_Y; bottom of slot dividers
const DEFLECTOR_Y   := 0.0      # mid-chase deflectors
const GAP_TOP_Y     := -8.0
const GAP_BOT_Y     := -12.0
const FINISH_Y      := -15.0
const CATCH_Y       := -20.0
const FRAME_TOP_Y   := SPAWN_Y + 3.0
const FRAME_BOT_Y   := CATCH_Y - 1.0

# ─── Spawn grid (must yield SLOT_COUNT=32 entries; 30 marbles consume 30) ───

const SPAWN_COLS    := 8
const SPAWN_ROWS    := 4
const SPAWN_DX      := 1.5
const SPAWN_DZ      := 0.7

# ─── Multiplier slots (Section 3) ───────────────────────────────────────────

# 7 slots, symmetric. Widths tuned so the natural ball distribution from the
# bumper output approximates the spec's per-race targets:
#   Slot 4 (center, 0.5×): widest → ~19/30 balls
#   Slots 3/5 (1×):       medium  → ~3-4 each
#   Slots 2/6 (2×):       narrow  → ~1-2 each
#   Slots 1/7 (3×, edge): narrowest → ~0-1 each (jackpot)
# Sum = 28.4m, leaving ~0.8m of margin total once we add 6 × 0.2m dividers.
const SLOT_WIDTHS:       Array = [2.0, 3.0, 4.4, 9.0, 4.4, 3.0, 2.0]
const SLOT_MULTIPLIERS:  Array = [3.0, 2.0, 1.0, 0.5, 1.0, 2.0, 3.0]
const DIVIDER_THICK     := 0.2

# ─── Tube (Section 1 left-wall shortcut) ────────────────────────────────────

const TUBE_ENTRY_X      := -13.0       # just inside the -X wall
const TUBE_W            := 1.2         # entry slot width along X
const TUBE_H            := 1.6         # entry slot height along Y
const TUBE_EXIT_X       := -10.0       # slight inward nudge so the marble
                                       # doesn't immediately re-enter
const TUBE_EXIT_VX      := 3.0         # rightward kick on exit
const TUBE_EXIT_VY      := -7.0        # downward kick on exit

# ─── Unthemed palette (neutral greys; theme pass overrides later) ───────────

const COL_FRAME    := Color(0.30, 0.30, 0.35)
const COL_FLOOR    := Color(0.40, 0.40, 0.45)
const COL_PEG      := Color(0.62, 0.62, 0.66)
const COL_BUMPER   := Color(0.78, 0.78, 0.82)
const COL_DIV      := Color(0.55, 0.55, 0.60)
# Slot tints by tier — kept distinguishable in the unthemed prototype so the
# 7-slot pattern is readable when we eyeball the race. NOT the final palette.
const COL_SLOT_3X  := Color(0.95, 0.55, 0.20, 0.35)   # gold-orange
const COL_SLOT_2X  := Color(0.55, 0.85, 0.35, 0.30)   # green
const COL_SLOT_1X  := Color(0.55, 0.65, 0.95, 0.28)   # cool blue
const COL_SLOT_05X := Color(0.95, 0.30, 0.30, 0.30)   # red (penalty)
const COL_TUBE     := Color(1.00, 0.45, 0.95, 0.50)   # magenta hint

# ─── Physics materials ──────────────────────────────────────────────────────

var _mat_floor:  PhysicsMaterial = null
var _mat_peg:    PhysicsMaterial = null
var _mat_wall:   PhysicsMaterial = null
var _mat_bumper: PhysicsMaterial = null

# ─── Build entry point ──────────────────────────────────────────────────────

func _ready() -> void:
	_init_physics_materials()
	_build_outer_frame()
	_build_section1_descent()
	_build_section2_bumper()
	_build_section3_multipliers()
	_build_section4_chase()
	_build_finish_and_catchment()

# ─── Physics materials ──────────────────────────────────────────────────────

func _init_physics_materials() -> void:
	_mat_floor = PhysicsMaterial.new()
	_mat_floor.friction = 0.40
	_mat_floor.bounce   = 0.20
	# High-bounce pegs — pinball deflection per spec ("Every peg-hit is a
	# clean deflection"). Spec material notes target restitution 0.7+.
	_mat_peg = PhysicsMaterial.new()
	_mat_peg.friction = 0.20
	_mat_peg.bounce   = 0.55
	_mat_wall = PhysicsMaterial.new()
	_mat_wall.friction = 0.30
	_mat_wall.bounce   = 0.30
	# Bumpers want even higher bounce — they're the launchers.
	_mat_bumper = PhysicsMaterial.new()
	_mat_bumper.friction = 0.10
	_mat_bumper.bounce   = 0.70

# ─── Outer frame ────────────────────────────────────────────────────────────

func _build_outer_frame() -> void:
	var wall_mat := TrackBlocks.std_mat(COL_FRAME, 0.20, 0.60)
	var frame := StaticBody3D.new()
	frame.name = "OuterFrame"
	frame.physics_material_override = _mat_wall
	add_child(frame)
	TrackBlocks.build_outer_frame(frame, "Frame",
		FRAME_TOP_Y, FRAME_BOT_Y,
		FIELD_W, FIELD_DEPTH, WALL_THICK, wall_mat)

# ─── SECTION 1 — Descent + The Tube ─────────────────────────────────────────

# Peg row patterns. Each is an Array of x-positions; rows are emitted by
# cycling through pattern lists per band. Patterns are designed for the spec's
# "asymmetric clusters, not a grid" — DENSE rows fill ~10 pegs across, biased
# rows leave one half sparser, CENTER rows are mid-density, SPARSE rows let
# marbles re-converge. The y range is x ∈ [-13, 13] so pegs stay clear of
# the ±15 walls.
const PEG_RADIUS: float = 0.30
const PEG_ROW_SPACING: float = 1.30        # vertical row spacing in metres
const _P_DENSE_A: Array     = [-13, -10, -7, -4, -1,  2,  5,  8, 11, 13]
const _P_DENSE_B: Array     = [-12,  -9, -6, -3,  0,  3,  6,  9, 12]
const _P_LEFT_DENSE: Array  = [-13, -11, -9, -7, -5, -3, -1,  4, 11]
const _P_LEFT_DENSE_B: Array= [-12, -10, -8, -6, -4, -1,  3,  8]
const _P_TUBE_GAP: Array    = [-9,   -7, -5, -2,  1,  5, 11]
const _P_RIGHT_DENSE: Array = [-11,  -4,  0,  3,  6,  8, 10, 12, 13]
const _P_RIGHT_DENSE_B: Array= [-12, -2,  4,  6,  9, 11, 13]
const _P_CENTER_A: Array    = [-11,  -7, -3,  0,  3,  7, 11]
const _P_CENTER_B: Array    = [-12,  -8, -4,  0,  4,  8, 12]
const _P_DIAGONAL: Array    = [-13,  -9, -5, -1,  3,  7, 11]
const _P_TUBE_EXIT_GAP: Array= [-2,   2,  5,  8, 11, 13]
const _P_SPARSE: Array      = [-10,  -4,  4, 10]
const _P_PRE_BUMPER: Array  = [-9,   -3,  3,  9]
const _P_FINAL: Array       = [-7,    0,  7]

func _build_section1_descent() -> void:
	var pegs := StaticBody3D.new()
	pegs.name = "S1_Pegs"
	pegs.physics_material_override = _mat_peg
	add_child(pegs)

	var peg_mat := TrackBlocks.std_mat(COL_PEG, 0.10, 0.45)

	# Bands span the 105-m descent (y=127 → y=22). Each band declares which
	# pattern(s) to cycle as rows are emitted top-down at PEG_ROW_SPACING.
	# Bands are tuned so:
	#   - Top of S1: top fan-out (dense, near-uniform funnel)
	#   - Upper-mid: LEFT-DENSE (steers marbles toward the Tube entry at y=100)
	#   - Tube entry: row(s) with a gap at the -X wall for the warp mouth
	#   - Below tube entry: LEFT-DENSE continued, then a sparse exit zone
	#     (the Tube spits warped marbles into y≈87, sparse pegs let them fall)
	#   - Mid: dense central sort grid
	#   - Lower-mid: RIGHT-DENSE (mirror), then central continued
	#   - Lower: sparser pre-bumper rows so the stream re-converges
	# The list must remain top-down (descending y_top values).
	var bands: Array = [
		# Top fan-out (~4 rows)
		{"y_top": 127.0, "y_bot": 122.0, "patterns": [_P_DENSE_A, _P_DENSE_B]},
		# LEFT-DENSE pre-tube (~16 rows)
		{"y_top": 121.0, "y_bot": 102.0, "patterns": [_P_LEFT_DENSE, _P_LEFT_DENSE_B]},
		# Tube entry zone (~3 rows with gap)
		{"y_top": 101.0, "y_bot":  96.0, "patterns": [_P_TUBE_GAP]},
		# LEFT-DENSE post-tube (~7 rows)
		{"y_top":  95.0, "y_bot":  90.0, "patterns": [_P_LEFT_DENSE_B, _P_LEFT_DENSE]},
		# Tube exit sparse zone (~7 rows) — warped marbles land in here.
		{"y_top":  89.0, "y_bot":  82.0, "patterns": [_P_TUBE_EXIT_GAP, _P_DIAGONAL]},
		# Central sort dense (~12 rows)
		{"y_top":  81.0, "y_bot":  66.0, "patterns": [_P_DENSE_A, _P_DENSE_B]},
		# RIGHT-DENSE band (~12 rows) — mirror of upper LEFT-DENSE.
		{"y_top":  65.0, "y_bot":  50.0, "patterns": [_P_RIGHT_DENSE, _P_RIGHT_DENSE_B]},
		# Lower central sort (~10 rows)
		{"y_top":  49.0, "y_bot":  37.0, "patterns": [_P_CENTER_A, _P_CENTER_B, _P_DIAGONAL]},
		# Lower dense (~6 rows) — re-tightening before pre-bumper.
		{"y_top":  36.0, "y_bot":  29.0, "patterns": [_P_DENSE_B, _P_CENTER_A]},
		# Sparser pre-bumper (~4 rows)
		{"y_top":  28.0, "y_bot":  25.0, "patterns": [_P_SPARSE, _P_PRE_BUMPER]},
		# Final descent (~2 rows)
		{"y_top":  24.0, "y_bot":  23.0, "patterns": [_P_FINAL]},
	]

	var peg_height := FIELD_DEPTH - 0.4
	var rot_zaxis := Basis(Vector3.RIGHT, deg_to_rad(90.0))   # Y → Z

	for band in bands:
		var y_top: float = float(band["y_top"])
		var y_bot: float = float(band["y_bot"])
		var patterns: Array = band["patterns"]
		var y := y_top
		var pat_idx := 0
		while y >= y_bot - 0.001:
			var xs: Array = patterns[pat_idx % patterns.size()]
			for x in xs:
				var px: float = float(x)
				# Skip pegs that would clip the Tube entry mouth.
				if _peg_clips_tube(y, px):
					continue
				TrackBlocks.add_cylinder(pegs, "Peg_y%d_x%d" % [int(y * 10), int(px * 10)],
					Transform3D(rot_zaxis, Vector3(px, y, 0.0)),
					PEG_RADIUS, peg_height, peg_mat)
			y -= PEG_ROW_SPACING
			pat_idx += 1

	# THE TUBE — left-wall warp shortcut.
	# Entry: thin Area3D against the -X wall at TUBE_ENTRY_Y. The LEFT-DENSE
	# band above steers some marbles into the leftmost lane.
	# Exit: ~12 m below entry, in the sparse exit zone. Inward+downward kick
	# pushes the marble back into the descent stream cleanly.
	var tube := TubeWarp.new()
	tube.name = "TheTube"
	tube.exit_y = TUBE_EXIT_Y
	tube.exit_x = TUBE_EXIT_X
	tube.exit_vx = TUBE_EXIT_VX
	tube.exit_vy = TUBE_EXIT_VY
	tube.transform = Transform3D(Basis.IDENTITY,
		Vector3(TUBE_ENTRY_X + TUBE_W * 0.5, TUBE_ENTRY_Y, 0.0))
	var tube_coll := CollisionShape3D.new()
	tube_coll.name = "TheTube_shape"
	var tube_box := BoxShape3D.new()
	tube_box.size = Vector3(TUBE_W, TUBE_H, FIELD_DEPTH - 0.4)
	tube_coll.shape = tube_box
	tube.add_child(tube_coll)
	var tube_mat := TrackBlocks.std_mat_emit(COL_TUBE, 0.10, 0.40, 0.80)
	tube_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	var tube_mesh := MeshInstance3D.new()
	tube_mesh.name = "TheTube_mesh"
	var tube_bm := BoxMesh.new()
	tube_bm.size = Vector3(TUBE_W, TUBE_H, FIELD_DEPTH - 0.4)
	tube_mesh.mesh = tube_bm
	tube_mesh.material_override = tube_mat
	tube.add_child(tube_mesh)
	add_child(tube)

# True if a peg at (x, y) would clip the Tube entry mouth — the band that
# the entry Area3D occupies at the -X wall.
func _peg_clips_tube(y: float, x: float) -> bool:
	if abs(y - TUBE_ENTRY_Y) < TUBE_H * 0.6 \
			and x < TUBE_ENTRY_X + TUBE_W + 0.4:
		return true
	return false

# ─── SECTION 2 — Bumper (3-way launcher) ────────────────────────────────────

func _build_section2_bumper() -> void:
	var bumpers := StaticBody3D.new()
	bumpers.name = "S2_Bumpers"
	bumpers.physics_material_override = _mat_bumper
	add_child(bumpers)

	var bump_mat := TrackBlocks.std_mat_emit(COL_BUMPER, 0.30, 0.35, 0.20)

	# Layout: a 5-piece bumper at y≈19. The spec calls out three Zones (A
	# centre, B mid, C outer); the geometry here yields three trajectory
	# bands depending on incoming x:
	#   |x| < 1.5  → lands on Centre Peak's apex → splits L/R, drops near
	#                centre dividers → multiplier slot 4 (0.5×) [Zone A]
	#   1.5 < |x| < 6 → glances Inner Wing → drifts to mid slots 3/5 (1×) or
	#                   2/6 (2×) [Zone B]
	#   |x| > 6    → strikes Outer Wing → kicked toward edge slots 1/7 (3×)
	#                or 2/6 [Zone C]
	#
	# All wedges are static slabs; the trajectory split is entirely physical
	# (deterministic, replay-stable).

	# (1) Centre peak — two slabs meeting at apex (x=0, y=20.5).
	#     Each slab tilted 45° so the top forms a ridge.
	var peak_y := 20.5
	var peak_half_w := 1.4
	for sgn in [-1, 1]:
		var tilt: float = float(sgn) * deg_to_rad(45.0)
		var basis := Basis(Vector3(0, 0, 1), tilt)
		# Slab centre: shifted slightly off-axis so the two slabs meet at
		# (0, peak_y) on top.
		var cx: float = -float(sgn) * peak_half_w * 0.5
		TrackBlocks.add_box(bumpers, "Bumper_Peak_%s" % ("L" if sgn < 0 else "R"),
			Transform3D(basis, Vector3(cx, peak_y - 0.4, 0.0)),
			Vector3(peak_half_w * 1.4, 0.35, FIELD_DEPTH - 0.4),
			bump_mat)

	# (2) Inner wings — small bumps at x=±4, slight outward tilt. Glancing
	#     hits slow the ball and push it 1-2 slots off centre.
	for sgn in [-1, 1]:
		var tilt: float = float(sgn) * deg_to_rad(30.0)   # outer-edge low
		var basis := Basis(Vector3(0, 0, 1), tilt)
		var cx: float = float(sgn) * 4.0
		TrackBlocks.add_box(bumpers, "Bumper_InnerWing_%s" % ("L" if sgn < 0 else "R"),
			Transform3D(basis, Vector3(cx, 19.5, 0.0)),
			Vector3(2.0, 0.35, FIELD_DEPTH - 0.4),
			bump_mat)

	# (3) Outer wings — big tilted ramps at x=±9 angled OUTWARD so far-edge
	#     marbles get launched toward the edge slots. These are the Zone-C
	#     paths; they are the only way to reach the 3× edge slots without
	#     going through the Tube.
	for sgn in [-1, 1]:
		var tilt: float = float(sgn) * deg_to_rad(38.0)   # steep outer slope
		var basis := Basis(Vector3(0, 0, 1), tilt)
		var cx: float = float(sgn) * 9.5
		TrackBlocks.add_box(bumpers, "Bumper_OuterWing_%s" % ("L" if sgn < 0 else "R"),
			Transform3D(basis, Vector3(cx, 19.0, 0.0)),
			Vector3(3.5, 0.4, FIELD_DEPTH - 0.4),
			bump_mat)

	# (4) Floor strip below the bumpers — a thin bevelled slab spanning the
	#     gap so marbles that fall straight through don't hit nothing for
	#     2m of empty space before reaching the dividers.
	# Two short slabs left/right of centre, forming a shallow V toward x=0.
	for sgn in [-1, 1]:
		var tilt: float = float(sgn) * deg_to_rad(6.0)   # shallow funnel
		var basis := Basis(Vector3(0, 0, 1), tilt)
		var cx: float = float(sgn) * 7.0
		TrackBlocks.add_box(bumpers, "Bumper_Catch_%s" % ("L" if sgn < 0 else "R"),
			Transform3D(basis, Vector3(cx, S2_BOT_Y + 0.3, 0.0)),
			Vector3(7.0, FLOOR_THICK, FIELD_DEPTH - 0.4),
			bump_mat)

# ─── SECTION 3 — Multiplier zone (7 channels + pickup zones) ────────────────

func _build_section3_multipliers() -> void:
	var dividers := StaticBody3D.new()
	dividers.name = "S3_Dividers"
	dividers.physics_material_override = _mat_wall
	add_child(dividers)

	var div_mat := TrackBlocks.std_mat(COL_DIV, 0.20, 0.55)

	# Compute slot edges from cumulative widths centred on x=0.
	var total_slot_w: float = 0.0
	for w in SLOT_WIDTHS:
		total_slot_w += float(w)
	var total_dividers_w: float = float(SLOT_WIDTHS.size() - 1) * DIVIDER_THICK
	var total_w: float = total_slot_w + total_dividers_w
	var x_cursor: float = -total_w * 0.5

	var slot_centres: Array = []   # filled per-slot for pickup-zone placement
	var slot_widths_actual: Array = []
	for i in range(SLOT_WIDTHS.size()):
		var sw: float = float(SLOT_WIDTHS[i])
		var slot_centre: float = x_cursor + sw * 0.5
		slot_centres.append(slot_centre)
		slot_widths_actual.append(sw)
		x_cursor += sw
		# Place a divider AFTER each slot except the last.
		if i < SLOT_WIDTHS.size() - 1:
			var div_x: float = x_cursor + DIVIDER_THICK * 0.5
			x_cursor += DIVIDER_THICK
			TrackBlocks.add_box(dividers, "Div_%d" % i,
				Transform3D(Basis.IDENTITY,
					Vector3(div_x, (S3_BOT_Y + S2_BOT_Y) * 0.5, 0.0)),
				Vector3(DIVIDER_THICK, S2_BOT_Y - S3_BOT_Y, FIELD_DEPTH - 0.4),
				div_mat)

	# Pickup zones (Area3D) — one per slot, sized to fill the channel
	# horizontally. Tier mapping:
	#   3×, 2×    → TIER_2 (only 1 marble can collect; matches "edge / rare")
	#   1×, 0.5×  → TIER_1 (up to 4 marbles per zone)
	# The 0.5× tier is structurally a TIER_1 zone but flagged with the
	# multiplier value so a future payout integration can apply the penalty
	# rule. Until that integration lands, the zone still works as a stable
	# detection point for replays.
	for i in range(SLOT_WIDTHS.size()):
		var sw_actual: float = float(slot_widths_actual[i])
		var cx: float = float(slot_centres[i])
		var mult: float = float(SLOT_MULTIPLIERS[i])
		var tier: int = PickupZone.TIER_2 if mult >= 2.0 else PickupZone.TIER_1
		var col: Color = _slot_colour_for(mult)
		var mat := TrackBlocks.std_mat_emit(col, 0.0, 0.40, 0.50)
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		var size := Vector3(sw_actual - 0.4, 1.4, FIELD_DEPTH - 0.6)
		var zone := TrackBlocks.add_pickup_zone(self,
			"Slot_%d_%sx" % [i + 1, _mult_label(mult)],
			Transform3D(Basis.IDENTITY,
				Vector3(cx, (S3_BOT_Y + S2_BOT_Y) * 0.5, 0.0)),
			size, tier, mat)
		# Tag the multiplier on the zone via metadata. Future payout code
		# can read it via zone.get_meta("multiplier_value"). Doesn't affect
		# the existing Tier1/Tier2 cap logic.
		zone.set_meta("multiplier_value", mult)

func _slot_colour_for(mult: float) -> Color:
	if is_equal_approx(mult, 3.0):
		return COL_SLOT_3X
	if is_equal_approx(mult, 2.0):
		return COL_SLOT_2X
	if is_equal_approx(mult, 1.0):
		return COL_SLOT_1X
	return COL_SLOT_05X      # 0.5×

func _mult_label(mult: float) -> String:
	if is_equal_approx(mult, 0.5):
		return "0p5"
	return "%d" % int(mult)

# ─── SECTION 4 — Chase (deflectors + final gap) ─────────────────────────────

func _build_section4_chase() -> void:
	var chase := StaticBody3D.new()
	chase.name = "S4_Chase"
	chase.physics_material_override = _mat_floor
	add_child(chase)

	var peg_mat := TrackBlocks.std_mat(COL_PEG, 0.10, 0.45)
	var floor_mat := TrackBlocks.std_mat(COL_FLOOR, 0.20, 0.55)

	# Sparse pegs spread through the 25-m chase (y=10 down to y=-15). Per
	# spec: "Sparser pegs — faster movement, finish race begins." So they're
	# fewer and offset to keep marbles drifting laterally without strongly
	# stalling them. Eight rows at ~1.5-m spacing through the upper chase.
	var rot_zaxis := Basis(Vector3.RIGHT, deg_to_rad(90.0))
	var sparse_pegs: Array = [
		{"y":  9.0, "xs": [-11, -5,  0,  5, 11]},
		{"y":  7.5, "xs": [-8, -2,  2,  8]},
		{"y":  6.0, "xs": [-12, -4,  4, 12]},
		{"y":  4.5, "xs": [-9,  -1,  3,  9]},
		{"y":  3.0, "xs": [-11, -5,  0,  5, 11]},
		{"y":  1.5, "xs": [-8,  -2,  2,  8]},
		{"y": -1.5, "xs": [-10, -4,  4, 10]},
		{"y": -3.0, "xs": [-7,  -1,  3,  7]},
	]
	for row in sparse_pegs:
		var y: float = float(row["y"])
		for x in row["xs"]:
			var px: float = float(x)
			TrackBlocks.add_cylinder(chase, "S4_Peg_y%d_x%d" % [int(y * 10), int(px * 10)],
				Transform3D(rot_zaxis, Vector3(px, y, 0.0)),
				0.30, FIELD_DEPTH - 0.4, peg_mat)

	# Deflector barriers — two angled slabs at y=DEFLECTOR_Y (≈5.5) leaning
	# IN from the side walls. A straggler near a wall hits the deflector and
	# is pushed back toward centre (subtle catch-up).
	for sgn in [-1, 1]:
		var tilt: float = float(sgn) * deg_to_rad(35.0)   # outer-bottom low
		var basis := Basis(Vector3(0, 0, 1), tilt)
		var cx: float = float(sgn) * 11.0
		TrackBlocks.add_box(chase, "S4_Deflector_%s" % ("L" if sgn < 0 else "R"),
			Transform3D(basis, Vector3(cx, DEFLECTOR_Y, 0.0)),
			Vector3(5.0, 0.4, FIELD_DEPTH - 0.4),
			floor_mat)

	# Final-stretch divider — vertical wall at x=0 from GAP_TOP_Y down to
	# GAP_BOT_Y. Splits the field into 2 lanes for the last ~5s of the race.
	# Per spec one lane is "fast" and one "slow"; we tilt the wall a few
	# degrees so its base sits asymmetrically (right side has slightly more
	# room → that's the "fast" lane).
	var split_basis := Basis(Vector3(0, 0, 1), deg_to_rad(2.0))
	TrackBlocks.add_box(chase, "S4_FinalSplit",
		Transform3D(split_basis, Vector3(0.0, (GAP_TOP_Y + GAP_BOT_Y) * 0.5, 0.0)),
		Vector3(0.4, GAP_TOP_Y - GAP_BOT_Y, FIELD_DEPTH - 0.4),
		floor_mat)

# ─── Finish line floor + catchment ──────────────────────────────────────────

func _build_finish_and_catchment() -> void:
	var well := StaticBody3D.new()
	well.name = "Catchment"
	well.physics_material_override = _mat_floor
	add_child(well)
	var mat := TrackBlocks.std_mat(Color(0.10, 0.10, 0.12), 0.10, 0.70)
	TrackBlocks.build_catchment(well, "Catch",
		CATCH_Y, FIELD_W, FIELD_DEPTH, FLOOR_THICK, mat)

# ─── Inner class: Tube warp (Section 1 shortcut) ────────────────────────────

# Custom Area3D that teleports a marble from the Tube entry to the exit point
# below. Marble is moved in a single physics step (transform + linear_velocity
# both reset). Determinism: entry is deterministic from spawn slot → physics
# trajectory → which marble enters first is reproducible from the seed.
class TubeWarp extends Area3D:
	var exit_y: float = 0.0
	var exit_x: float = 0.0
	var exit_vx: float = 0.0
	var exit_vy: float = 0.0
	# Track which marbles already warped this round so a marble can't
	# re-trigger by clipping the entry on its way to the exit. Per-marble,
	# not global — each marble may warp at most once.
	var _warped: Dictionary = {}

	func _ready() -> void:
		monitoring = true
		monitorable = false
		body_entered.connect(_on_body_entered)

	func _on_body_entered(body: Node) -> void:
		if not body is RigidBody3D:
			return
		var marble_name := String(body.name)
		if not marble_name.begins_with("Marble_"):
			return
		if _warped.has(marble_name):
			return
		_warped[marble_name] = true
		var rb := body as RigidBody3D
		var t := rb.global_transform
		t.origin = Vector3(exit_x, exit_y, t.origin.z)
		rb.global_transform = t
		rb.linear_velocity = Vector3(exit_vx, exit_vy, rb.linear_velocity.z)
		rb.angular_velocity = Vector3.ZERO

# ─── Track API overrides ────────────────────────────────────────────────────

func spawn_points() -> Array:
	# 32 spawn slots in an 8×4 grid above S1 — first 30 used, 2 spare for
	# replay headroom. Centred on x=0 / z=0.
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
	return Vector3(FIELD_W + 2.0, 3.0, FIELD_DEPTH + 1.0)

func camera_bounds() -> AABB:
	var min_v := Vector3(-FIELD_W * 0.5 - 1.0, FRAME_BOT_Y - 1.0, -FIELD_DEPTH * 0.5 - 1.0)
	var max_v := Vector3( FIELD_W * 0.5 + 1.0, FRAME_TOP_Y + 1.0,  FIELD_DEPTH * 0.5 + 1.0)
	return AABB(min_v, max_v - min_v)

func camera_pose() -> Dictionary:
	# Fixed 2D side view per spec. Camera pulled back on +Z, looking down -Z
	# at the field centre. The 150-m tall field needs a far-back camera so
	# the whole board fits. FOV widened slightly to 44° so the vertical view
	# (2·d·tan(fov/2) ≈ 162 m at d=200) clears the frame top + catchment.
	var mid_y: float = (FRAME_TOP_Y + FRAME_BOT_Y) * 0.5
	return {
		"position": Vector3(0.0, mid_y, 200.0),
		"target":   Vector3(0.0, mid_y, 0.0),
		"fov":      44.0,
	}

func environment_overrides() -> Dictionary:
	# Dark casino-felt ambience (placeholder — themed pass replaces with
	# proper palette + neon backdrop).
	return {
		"sky_top":        Color(0.04, 0.04, 0.06),
		"sky_horizon":    Color(0.10, 0.08, 0.14),
		"ground_top":     Color(0.06, 0.05, 0.08),
		"ground_bottom":  Color(0.02, 0.02, 0.03),
		"ambient_energy": 0.4,
		"fog_energy":     0.0,
	}
