class_name SpiralDropTrack
extends Track

# SpiralDropTrack — Phase 6 prototype #2 (M24).
#
# Wide-open helical ramp descending clockwise (viewed from above).  3.5
# turns, cone-shaped: outer radius shrinks from 18m at the top to 6m at
# the finish, so marbles get progressively compressed against the outer
# rail by centrifugal force as they descend.
#
# This is INTENTIONALLY NOT a "container".  No top, no inner wall, no
# enclosing box — just a single ramp surface with a low outer rail.  If
# a marble loses traction it falls inward into the next coil below
# (interesting failure state, not a ride-killer).
#
# Camera: side-elevated ~35° down, fixed.  Whole helix visible in one
# shot — viewer tracks marble pack progress as "X turns through".
#
# Helix parameters (must match the design doc cross-map summary table):
#   total_turns         = 3.5  (= 7π radians of θ sweep)
#   total_vertical_drop = 32m  (spawn_y - gate_y)
#   ramp_width          = 4m
#   ramp_thickness      = 0.5m
#   inclination (avg)   ≈ 7°  (varies because radius shrinks while drop
#                              per radian stays linear — steeper at end)
#   outer_rail_height   = 1.2m
#
# Geometry built from N=112 small box segments tangent to the helix
# curve (32 segments per turn × 3.5 turns).  Plus matching outer rail
# segments.  Plus per-design obstacles:
#   - 6 inner-line speed bumps in turns 1-2 (slows the inside line)
#   - 3 outer-rail kickers in turn 2 (deflect marbles inward)
#   - 1 mid-ramp gap in turn 3 (skip-segment hole)
#
# Determinism: helix geometry + bumps/kickers are static.  No kinematic
# obstacles → server_seed not consumed by this track (different rounds
# look the same, but different spawn slots → different starting
# positions on the ramp → different bounce paths).

# ─── Helix parameters ────────────────────────────────────────────────────────
# v4 upgrade (calibrated): 3 turns × 6π rad with the formula bug fixed
# (was TAU*0.5 = π giving half the intended angular sweep).  v4 first
# tried 4.2 turns but the resulting 187m path took marbles >120s to
# traverse with friction 0.08 — outside the 35-45s target.  3 turns gives
# path ~134m, predicted race time ~44s, comfortably in target.
# Outer pitch (r=12): atan(1.59/12) = 7.5°, friction 0.08 → marbles move.
# Inner pitch (r=2.2): atan(1.59/2.2) = 35.9° → strong final acceleration.
const TOTAL_TURNS    := 3.0
const TOTAL_THETA    := TOTAL_TURNS * TAU             # 3 turns = 6π rad ≈ 18.85
const R_START        := 12.0
const R_END          := 2.2
const SPAWN_Y        := 32.0
const GATE_Y         := 2.0
const FLOOR_BASE_Y   := -4.0

# Number of box segments per turn.  v4: 24 × 3 = 72 segments.
const SEGS_PER_TURN  := 24
const TOTAL_SEGS     := int(round(TOTAL_TURNS * float(SEGS_PER_TURN)))

# Ramp geometry.
const RAMP_WIDTH     := 4.0
const FLOOR_THICK    := 0.5
# Outer rail: tall enough that marbles can't bounce over to escape outward.
const RAIL_HEIGHT    := 2.0
const RAIL_THICK     := 0.3
# Inner curb: short lip on the spiral's INNER edge.  Low enough that the
# snail-shell silhouette stays readable from above, tall enough to keep
# marbles ON the ramp instead of falling straight through the centre to
# the finish gate (was the v3.3 stall: race finished in 3.5s because
# marbles short-circuited through the open inner edge).
# v4.7: 1.0m compromise — taller than v3.4's 0.7 (tunneling) but shorter
# than v4.6's 1.5 (pile-up jam).  Combined with SPAWN_LIFT=2.0 (1m above
# curb top) marbles drop onto the slab cleanly without crowding the curb.
const INNER_CURB_H   := 1.0
const INNER_CURB_THICK := 0.3

# Spawn / finish.
const SPAWN_COLS := 8
const SPAWN_ROWS := 4
const SPAWN_DX   := 0.5     # 8 cols × 0.5 = 4m wide (matches ramp width)
const SPAWN_DZ   := 1.0
# v4.7: spawn lift bumped 1.0 → 2.0 (final slot.y = slab_top + 2.5m).
# At 1.0, slot.y was 33.29 — exactly at the inner curb top (33.28) when
# INNER_CURB_H=1.5, causing half the marbles to spawn ON the curb edge
# and fall into the spiral centre.  2.0 puts spawn cleanly 1m above the
# curb top.
const SPAWN_LIFT := 2.0

const FINISH_Y_OFF := 2.5
const FINISH_BOX_SIZE := Vector3(12.0, 5.0, 12.0)

# ─── Inner-line speed bumps (v4 — 9 bumps along the inner half) ──────────
# Per the v4 spec: 8-10 small bumps on the inner half, friction zone
# friction 0.13.  Spread over the first 75% of the spiral (θ ∈ [0, 6.3π]).
const BUMP_COUNT     := 9
const BUMP_INNER_OFFSET := 1.0       # m inside from ramp centerline
const BUMP_SIZE      := Vector3(0.4, 0.18, 1.6)

# ─── v4 Chaos Zone 1 (θ ≈ 1.5π — early, after first half turn) ──────────
const CHAOS1_THETA   := 1.5 * PI
const SPINNER_RADIUS := 1.2
const SPINNER_HEIGHT := 0.5
const SPINNER_OMEGA  := 0.6                  # rad/s

# ─── v4 Chaos Zone 2 (θ ≈ 2.5π — mid-race) — bumper fan ─────────────────
# Replaces the legacy kickers.  5 bumpers in a fan pattern across the ramp
# width.  Each bumper is a small cylinder with high bounce.
const CHAOS2_THETA   := 2.5 * PI
const FAN_BUMPERS    := 5
const FAN_BUMPER_R   := 0.6
const FAN_BUMPER_H   := 0.7

# ─── v4 Chaos Zone 3 (θ ≈ 4.5π — late-race, before finish) ───────────────
# 4 large vertical pins + 2 angled deflectors that strongly reshape the
# pack just before the finish straight.
const CHAOS3_THETA       := 4.5 * PI
const RESHUFFLE_PIN_R    := 0.45
const RESHUFFLE_PIN_H    := 1.2
const RESHUFFLE_DEFL_SZ  := Vector3(1.4, 0.9, 0.35)

# ─── v4 Jump (θ ≈ 4.5π — moved earlier so the landing pad doesn't
#    overlap with the finish trigger) ─────────────────────────────────────
# Skip ~3 segments to create a 1.8m gap.  A landing pad sits 2.5m below
# the take-off, sloped 20° toward the next helix segment so marbles land
# and rejoin the spiral cleanly.
# Position v4.5 (3-turn helix): θ = 3.5π in turn 1.75.  Helix y at
# 3.5π = 32 + (-30)*(3.5/6) = 14.5.  Landing pad y ≈ 12 — well above
# the finish trigger (y ∈ [2, 7]).
const JUMP_THETA          := 3.5 * PI
const JUMP_GAP_M          := 1.8            # horizontal gap on the helix curve
const JUMP_DROP_M         := 2.5            # vertical drop to landing pad
const JUMP_LAND_SLOPE_DEG := 20.0
const JUMP_LAND_LEN       := 4.0

# ─── v4 Split Drop (θ ≈ 4π) — 70 / 30 mid-spiral fork ────────────────────
# Replaces the legacy mid-ramp gap.  Main path keeps 70% of ramp width;
# secondary path drops 0.5m, runs lower for ~6m, then re-merges.
const SPLIT_THETA       := 3.0 * PI
const SPLIT_LENGTH      := 7.0              # arc-length over which the split runs
const SPLIT_MAIN_FRAC   := 0.70
const SPLIT_SECOND_DROP := 0.5

# ─── v4 Micro variations ─────────────────────────────────────────────────
# v4.5: temporarily disabled (PERIOD = -1).  The pitch jitter at segment
# seams was causing marbles to catch — 0° both stays consistent.  Will
# re-enable once dual-line + chaos zones are stable.
const PITCH_VAR_PERIOD := -1
const PITCH_VAR_DEG    := 1.0

# ─── Theme palette ───────────────────────────────────────────────────────────
const COL_RAMP        := Color(0.55, 0.40, 0.22)  # warm wood brown — neutral ramp
const COL_RAMP_OUTER  := Color(0.30, 0.62, 0.85)  # cyan tint — speed strip
const COL_RAMP_INNER  := Color(0.85, 0.55, 0.20)  # orange tint — slow zone
const COL_RAIL        := Color(0.30, 0.20, 0.12)
const COL_BUMP        := Color(0.85, 0.65, 0.20)  # warning yellow
const COL_SPINNER     := Color(0.55, 0.30, 0.85)  # purple — chaos 1
const COL_FAN_BUMPER  := Color(0.95, 0.30, 0.30)  # red bouncy — chaos 2
const COL_RESHUFFLE   := Color(0.95, 0.55, 0.15)  # orange — chaos 3
const COL_JUMP_RAMP   := Color(0.85, 0.20, 0.55)  # magenta — jump take-off
const COL_LANDING     := Color(0.20, 0.85, 0.55)  # green — landing pad
const COL_GATE        := Color(0.92, 0.78, 0.18)
const COL_PLATFORM    := Color(0.50, 0.45, 0.40)

# Physics materials (v4 — split per-zone for the dual-line system).
var _mat_ramp:        PhysicsMaterial = null   # neutral ramp (legacy fallback)
var _mat_speed_zone:  PhysicsMaterial = null   # outer half: friction 0.05
var _mat_slow_zone:   PhysicsMaterial = null   # inner half: friction 0.13
var _mat_landing:     PhysicsMaterial = null   # jump landing: friction 0.12
var _mat_rail:        PhysicsMaterial = null
var _mat_bump:        PhysicsMaterial = null
var _mat_spinner:     PhysicsMaterial = null
var _mat_fan_bumper:  PhysicsMaterial = null
var _mat_gate:        PhysicsMaterial = null

# Spinner kinematic state.
var _spinner: AnimatableBody3D = null
var _spinner_pivot: Vector3 = Vector3.ZERO
var _spinner_omega: float = 0.0
var _spinner_time: float = 0.0

# Indexes of segments that get skipped (jump gap + split-drop main hole).
var _jump_skip_start: int = -1
var _jump_skip_end: int = -1
var _split_skip_start: int = -1
var _split_skip_end: int = -1

func _ready() -> void:
	_init_physics_materials()
	_compute_gap_segment()
	_build_ground_plane()
	_build_entry_platform()
	_build_helix_segments()
	_build_outer_rail()
	_build_inner_curb()
	_build_inner_bumps()
	_build_split_drop()
	_build_chaos_zone_1_spinner()
	_build_chaos_zone_2_bumper_fan()
	_build_chaos_zone_3_reshuffle()
	_build_jump()
	_build_pickup_zones()
	_build_finish_platform()
	_build_catchment()
	_build_scenography_arena()
	_build_scenography_audience()
	_build_scenography_palms()
	_build_scenography_banners()
	_build_stadium_lighting()
	_build_mood_lights()

func _physics_process(delta: float) -> void:
	# Spinner kinematic rotation around world Y axis.
	if _spinner == null:
		return
	_spinner_time += delta
	var angle: float = _spinner_omega * _spinner_time
	var basis := Basis(Vector3.UP, angle)
	_spinner.global_transform = Transform3D(basis, _spinner_pivot)

func _init_physics_materials() -> void:
	# Neutral ramp (legacy fallback — mostly unused after v4's split lines).
	_mat_ramp = PhysicsMaterial.new()
	_mat_ramp.friction = 0.08
	_mat_ramp.bounce   = 0.18

	# Outer speed strip (v4 dual-line) — low friction.  Spec asked 0.05
	# but 0.07 stops marbles tunneling the helix at start (where outer
	# pitch is only 5.4°).  Tweakable.
	_mat_speed_zone = PhysicsMaterial.new()
	_mat_speed_zone.friction = 0.07
	_mat_speed_zone.bounce   = 0.18

	# Inner friction zone (v4 dual-line) — higher friction, slower line but
	# shorter arc.  Pairs with the inner-line bumps for cumulative drag.
	_mat_slow_zone = PhysicsMaterial.new()
	_mat_slow_zone.friction = 0.13
	_mat_slow_zone.bounce   = 0.18

	# Jump landing pad — moderate friction so marbles dissipate jump energy.
	_mat_landing = PhysicsMaterial.new()
	_mat_landing.friction = 0.12
	_mat_landing.bounce   = 0.30

	_mat_rail = PhysicsMaterial.new()
	_mat_rail.friction = 0.20
	_mat_rail.bounce   = 0.30

	_mat_bump = PhysicsMaterial.new()
	_mat_bump.friction = 0.55
	_mat_bump.bounce   = 0.55

	# v4 chaos materials.
	_mat_spinner = PhysicsMaterial.new()
	_mat_spinner.friction = 0.20
	_mat_spinner.bounce   = 0.20

	_mat_fan_bumper = PhysicsMaterial.new()
	_mat_fan_bumper.friction = 0.15
	_mat_fan_bumper.bounce   = 0.70

	_mat_gate = PhysicsMaterial.new()
	_mat_gate.friction = 0.55
	_mat_gate.bounce   = 0.10

# Sample the helix at θ.  Returns:
#   pos     : Vector3 — world position on the ramp centerline at this θ
#   tangent : Vector3 — unit vector along motion direction (3D, includes pitch)
#   radial  : Vector3 — unit horizontal vector pointing OUTWARD from spiral axis
#   r       : float   — radius at this θ
func _helix_at(theta: float) -> Dictionary:
	var t_norm: float = theta / TOTAL_THETA
	var r: float = R_START + (R_END - R_START) * t_norm
	var pos := Vector3(
		r * cos(theta),
		SPAWN_Y + (GATE_Y - SPAWN_Y) * t_norm,
		r * sin(theta)
	)
	var dr_dt: float = (R_END - R_START) / TOTAL_THETA
	var dy_dt: float = (GATE_Y - SPAWN_Y) / TOTAL_THETA
	var tangent := Vector3(
		dr_dt * cos(theta) - r * sin(theta),
		dy_dt,
		dr_dt * sin(theta) + r * cos(theta)
	).normalized()
	var radial := Vector3(cos(theta), 0.0, sin(theta))
	return {"pos": pos, "tangent": tangent, "radial": radial, "r": r}

# v4: compute the segment ranges to skip for the JUMP gap and the SPLIT
# DROP main-path hole.  Both ranges are integer-segment windows centred on
# their respective θ values.
func _compute_gap_segment() -> void:
	var d_theta: float = TOTAL_THETA / float(TOTAL_SEGS)

	# Jump gap: skip enough segments to make ~JUMP_GAP_M of arc length.
	# Average chord per segment ≈ avg_r * d_theta.  Average r ≈ (R_START+R_END)/2.
	var avg_chord: float = ((R_START + R_END) * 0.5) * d_theta
	var jump_segs: int = max(1, int(round(JUMP_GAP_M / avg_chord)))
	var jump_centre: int = int(round(JUMP_THETA / d_theta - 0.5))
	_jump_skip_start = max(0, jump_centre - jump_segs / 2)
	_jump_skip_end   = min(TOTAL_SEGS, _jump_skip_start + jump_segs)

	# Split-drop main-path hole: skip a longer window at SPLIT_THETA.  The
	# secondary path (built separately in _build_split_drop) covers this
	# region at a lower y.  Length ~= SPLIT_LENGTH on the spiral arc.
	var split_segs: int = max(1, int(round(SPLIT_LENGTH / avg_chord)))
	var split_centre: int = int(round(SPLIT_THETA / d_theta - 0.5))
	_split_skip_start = max(0, split_centre - split_segs / 2)
	_split_skip_end   = min(TOTAL_SEGS, _split_skip_start + split_segs)

# Build a small flat platform behind the helix start.  Marbles spawn
# above this platform, drop onto it, and roll forward (in tangent
# direction) onto the helix.
func _build_entry_platform() -> void:
	var mat := TrackBlocks.std_mat(COL_PLATFORM, 0.10, 0.85)
	var body := StaticBody3D.new()
	body.name = "EntryPlatform"
	body.physics_material_override = _mat_ramp
	add_child(body)

	# Helix start position.
	var start := _helix_at(0.0)
	var fwd: Vector3 = start["tangent"]
	# Place platform behind the start, in the -tangent direction.
	# We use horizontal tangent only (zero out Y) so the platform stays flat.
	var fwd_h := Vector3(fwd.x, 0.0, fwd.z).normalized()
	var platform_center: Vector3 = start["pos"] - fwd_h * 3.0
	platform_center.y = SPAWN_Y - 0.5     # platform top surface at SPAWN_Y - 0.25

	# Orient platform so its long axis aligns with fwd_h.  Width along radial.
	var radial: Vector3 = start["radial"]
	var up := fwd_h.cross(radial).normalized()
	var basis := Basis(fwd_h, up, radial)
	TrackBlocks.add_box(body, "EntrySlab",
		Transform3D(basis, platform_center),
		Vector3(6.0, FLOOR_THICK, RAMP_WIDTH),
		mat)

	# Connector ramp from platform to helix start — a small ramp that
	# bridges the platform top to the first helix segment.  Tilted to
	# match the platform's orientation.
	var connector_center: Vector3 = (platform_center + start["pos"]) * 0.5
	connector_center.y = SPAWN_Y - 0.25
	# Same basis as platform — it's a flat ~3m link.
	TrackBlocks.add_box(body, "EntryConnector",
		Transform3D(basis, connector_center),
		Vector3(3.5, FLOOR_THICK, RAMP_WIDTH),
		mat)

# v4: build the helix as TWO separate StaticBody3D parents — outer half
# (speed strip, friction 0.05) and inner half (slow zone, friction 0.13).
# Two parents = each half can have its own physics_material_override → the
# dual-line racing line emerges from the friction differential.
#
# Skip ranges: jump-gap segments (creates the air-time gap) AND
# split-drop segments (the main path is hollowed out so the lower
# secondary path becomes the only floor under that arc).
#
# Micro variations: every PITCH_VAR_PERIOD (=7) segments, the slab gets
# an additional ±PITCH_VAR_DEG pitch jitter around the radial axis.  Sign
# alternates so the wave-like effect averages out — race time stays the
# same but every coil reads visually distinct.
func _build_helix_segments() -> void:
	var ramp_outer_mat := TrackBlocks.std_mat_emit(COL_RAMP_OUTER, 0.10, 0.55, 0.10)
	var ramp_inner_mat := TrackBlocks.std_mat_emit(COL_RAMP_INNER, 0.10, 0.65, 0.05)

	# Dual-line v4: outer half = speed strip (friction 0.07), inner half =
	# slow zone (friction 0.13).  Marbles on outer line accelerate but
	# travel a longer arc; inner line is shorter but slowed by friction
	# AND inner-line bumps.
	var outer_body := StaticBody3D.new()
	outer_body.name = "HelixRamp_Outer"
	outer_body.physics_material_override = _mat_speed_zone
	add_child(outer_body)
	var inner_body := StaticBody3D.new()
	inner_body.name = "HelixRamp_Inner"
	inner_body.physics_material_override = _mat_slow_zone
	add_child(inner_body)

	var d_theta: float = TOTAL_THETA / float(TOTAL_SEGS)
	for i in range(TOTAL_SEGS):
		# Skip: jump gap.
		if i >= _jump_skip_start and i < _jump_skip_end:
			continue
		# Skip: split-drop main hole (the secondary path covers it lower).
		if i >= _split_skip_start and i < _split_skip_end:
			continue

		var theta_mid: float = (float(i) + 0.5) * d_theta
		var data := _helix_at(theta_mid)
		var pos: Vector3 = data["pos"]
		var fwd: Vector3 = data["tangent"]
		var radial: Vector3 = data["radial"]
		var up := fwd.cross(radial).normalized()
		# Micro pitch variation: alternating ±PITCH_VAR_DEG every PITCH_VAR_PERIOD.
		var pitch_var: float = 0.0
		if PITCH_VAR_PERIOD > 0 and (i % PITCH_VAR_PERIOD) == 0:
			pitch_var = deg_to_rad(PITCH_VAR_DEG) * (1.0 if (i / PITCH_VAR_PERIOD) % 2 == 0 else -1.0)
		var basis := Basis(fwd, up, radial)
		if pitch_var != 0.0:
			# Rotate around radial axis (= "pitch" in the local frame).
			basis = Basis(radial, pitch_var) * basis

		var p1: Vector3 = _helix_at(float(i) * d_theta)["pos"]
		var p2: Vector3 = _helix_at(float(i + 1) * d_theta)["pos"]
		var chord: float = p1.distance_to(p2) * 1.06    # 6% overlap to hide seams

		# Outer half (speed strip): centred at +radial * RAMP_WIDTH/4.
		var outer_pos: Vector3 = pos + radial * (RAMP_WIDTH * 0.25)
		# Inner half (slow zone): centred at -radial * RAMP_WIDTH/4.
		var inner_pos: Vector3 = pos - radial * (RAMP_WIDTH * 0.25)
		var half_size := Vector3(chord, FLOOR_THICK, RAMP_WIDTH * 0.5)
		TrackBlocks.add_box(outer_body, "Seg%d_Outer" % i,
			Transform3D(basis, outer_pos), half_size, ramp_outer_mat)
		TrackBlocks.add_box(inner_body, "Seg%d_Inner" % i,
			Transform3D(basis, inner_pos), half_size, ramp_inner_mat)

# Outer rail: vertical wall along the +radial edge of every segment (skip
# the gap segment too, so the rail has a small gap matching the floor gap).
func _build_outer_rail() -> void:
	var rail_mat := TrackBlocks.std_mat(COL_RAIL, 0.20, 0.60)
	var body := StaticBody3D.new()
	body.name = "OuterRail"
	body.physics_material_override = _mat_rail
	add_child(body)

	var d_theta: float = TOTAL_THETA / float(TOTAL_SEGS)
	for i in range(TOTAL_SEGS):
		# v4: skip jump gap (rail follows the gap so the take-off is clear).
		if i >= _jump_skip_start and i < _jump_skip_end:
			continue
		# Split-drop region keeps the rail (the main path is gone but the
		# rail still bounds the scene visually).
		var theta_mid: float = (float(i) + 0.5) * d_theta
		var data := _helix_at(theta_mid)
		var pos: Vector3 = data["pos"]
		var fwd: Vector3 = data["tangent"]
		var radial: Vector3 = data["radial"]
		var up := fwd.cross(radial).normalized()
		var basis := Basis(fwd, up, radial)

		var p1: Vector3 = _helix_at(float(i) * d_theta)["pos"]
		var p2: Vector3 = _helix_at(float(i + 1) * d_theta)["pos"]
		var chord: float = p1.distance_to(p2) * 1.06

		# Rail position: at outer edge (+radial * RAMP_WIDTH/2) and lifted
		# up by RAIL_HEIGHT/2 so its base sits on the ramp surface.
		var rail_pos: Vector3 = pos + radial * (RAMP_WIDTH * 0.5 + RAIL_THICK * 0.5) \
				+ up * (RAIL_HEIGHT * 0.5)
		TrackBlocks.add_box(body, "Rail%d" % i,
			Transform3D(basis, rail_pos),
			Vector3(chord, RAIL_HEIGHT, RAIL_THICK),
			rail_mat)

# Inner curb: short lip along the -radial edge of every helix segment so
# marbles can't fall through the spiral's open centre to the gate below.
# Same per-segment geometry as the outer rail but shorter (0.7m vs 2m) and
# placed on the inner edge.  Visible from above as a thin inner ring.
func _build_inner_curb() -> void:
	var curb_mat := TrackBlocks.std_mat(COL_RAIL, 0.20, 0.60)
	var body := StaticBody3D.new()
	body.name = "InnerCurb"
	body.physics_material_override = _mat_rail
	add_child(body)

	var d_theta: float = TOTAL_THETA / float(TOTAL_SEGS)
	for i in range(TOTAL_SEGS):
		# v4: only skip the jump region (split-drop has its own curb in
		# _build_split_drop's secondary-path side).  Keeping the curb in
		# the split region prevents marbles from falling through the gap
		# between the main and secondary paths.
		if i >= _jump_skip_start and i < _jump_skip_end:
			continue
		var theta_mid: float = (float(i) + 0.5) * d_theta
		var data := _helix_at(theta_mid)
		var pos: Vector3 = data["pos"]
		var fwd: Vector3 = data["tangent"]
		var radial: Vector3 = data["radial"]
		var up := fwd.cross(radial).normalized()
		var basis := Basis(fwd, up, radial)

		var p1: Vector3 = _helix_at(float(i) * d_theta)["pos"]
		var p2: Vector3 = _helix_at(float(i + 1) * d_theta)["pos"]
		var chord: float = p1.distance_to(p2) * 1.06

		# Inner edge: -radial * RAMP_WIDTH/2.  Lifted by INNER_CURB_H/2 so
		# its base sits on the ramp surface.
		var curb_pos: Vector3 = pos - radial * (RAMP_WIDTH * 0.5 + INNER_CURB_THICK * 0.5) \
				+ up * (INNER_CURB_H * 0.5)
		TrackBlocks.add_box(body, "Curb%d" % i,
			Transform3D(basis, curb_pos),
			Vector3(chord, INNER_CURB_H, INNER_CURB_THICK),
			curb_mat)

# v4: 9 inner-line speed bumps spread across the first 75% of the spiral
# (θ ∈ [0, 6.3π]).  Each bump sits on the inner half of the ramp.  Pairs
# with the slow-zone friction (0.13) for cumulative drag on the inside line.
func _build_inner_bumps() -> void:
	var bump_mat := TrackBlocks.std_mat_emit(COL_BUMP, 0.10, 0.55, 0.30)
	var body := StaticBody3D.new()
	body.name = "InnerBumps"
	body.physics_material_override = _mat_bump
	add_child(body)

	# Spread bumps across the first 75% of TOTAL_THETA, avoiding the
	# chaos zones and jump.
	var theta_max: float = TOTAL_THETA * 0.75
	for i in range(BUMP_COUNT):
		var theta: float = (float(i + 1) / float(BUMP_COUNT + 1)) * theta_max
		var data := _helix_at(theta)
		var pos: Vector3 = data["pos"]
		var fwd: Vector3 = data["tangent"]
		var radial: Vector3 = data["radial"]
		var up := fwd.cross(radial).normalized()
		var basis := Basis(fwd, up, radial)

		# Position: shifted INWARD from centerline by BUMP_INNER_OFFSET.
		# Lifted slightly so the bump sits ON the ramp.
		var bump_pos: Vector3 = pos - radial * BUMP_INNER_OFFSET \
				+ up * (BUMP_SIZE.y * 0.5 + FLOOR_THICK * 0.5)
		TrackBlocks.add_box(body, "Bump%d" % i,
			Transform3D(basis, bump_pos),
			BUMP_SIZE,
			bump_mat)

# ─── v4 Chaos Zone 1 — rotating spinner at θ ≈ 2π ────────────────────────
# Single horizontal kinematic disc at the centre of the ramp at θ=2π.
# Rotates around its vertical axis at SPINNER_OMEGA rad/s.  Marbles that
# touch it get a tangential nudge.
func _build_chaos_zone_1_spinner() -> void:
	var spinner_mat := TrackBlocks.std_mat_emit(COL_SPINNER, 0.20, 0.40, 0.50)
	var data := _helix_at(CHAOS1_THETA)
	var pos: Vector3 = data["pos"]
	var up := Vector3.UP
	# Position the spinner ON the ramp surface (slightly above) at the
	# centerline.  Spin axis = world Y (vertical).
	var pivot: Vector3 = pos + up * (SPINNER_HEIGHT * 0.5 + FLOOR_THICK * 0.5)
	var body := TrackBlocks.add_animatable_cylinder(
		self, "ChaosZone1_Spinner",
		Transform3D(Basis.IDENTITY, pivot),
		SPINNER_RADIUS, SPINNER_HEIGHT, spinner_mat)
	body.physics_material_override = _mat_spinner
	_spinner = body
	_spinner_pivot = pivot
	_spinner_omega = SPINNER_OMEGA

# ─── v4 Chaos Zone 2 — bumper fan at θ ≈ 3.5π ────────────────────────────
# 5 vertical-axis cylinder bumpers in a STAGGERED fan: bumpers are spread
# across a small θ-window AND across the ramp width so marbles encounter
# them one or two at a time, not all 5 in a wall.
# Each bumper has high bounce (0.7).
#
# Layout: 5 bumpers across 3 sub-θ steps:
#   sub-θ 0: bumpers at x = -1.4, +1.4
#   sub-θ 1: bumpers at x = -0.7, +0.7
#   sub-θ 2: bumper at x = 0
# This forms a triangle / diamond fan.  A marble approaching from any
# x position has at least one clear gap to slip through.
func _build_chaos_zone_2_bumper_fan() -> void:
	var fan_mat := TrackBlocks.std_mat_emit(COL_FAN_BUMPER, 0.10, 0.30, 0.60)
	var body := StaticBody3D.new()
	body.name = "ChaosZone2_BumperFan"
	body.physics_material_override = _mat_fan_bumper
	add_child(body)

	var d_theta: float = TOTAL_THETA / float(TOTAL_SEGS)
	var fan_layout: Array = [
		{"theta_off": -1.5 * d_theta, "x":  1.4},
		{"theta_off": -1.5 * d_theta, "x": -1.4},
		{"theta_off":  0.0,           "x":  0.7},
		{"theta_off":  0.0,           "x": -0.7},
		{"theta_off":  1.5 * d_theta, "x":  0.0},
	]
	for i in range(fan_layout.size()):
		var cfg: Dictionary = fan_layout[i]
		var theta: float = CHAOS2_THETA + float(cfg["theta_off"])
		var data := _helix_at(theta)
		var pos: Vector3 = data["pos"]
		var fwd: Vector3 = data["tangent"]
		var radial: Vector3 = data["radial"]
		var up := fwd.cross(radial).normalized()
		var bumper_pos: Vector3 = pos + radial * float(cfg["x"]) \
				+ up * (FAN_BUMPER_H * 0.5 + FLOOR_THICK * 0.5)
		TrackBlocks.add_cylinder(body, "FanBumper%d" % i,
			Transform3D(Basis.IDENTITY, bumper_pos),
			FAN_BUMPER_R, FAN_BUMPER_H, fan_mat)

# ─── v4 Chaos Zone 3 — high-impact reshuffle at θ ≈ 5.5π ─────────────────
# 4 large vertical pins + 2 angled deflectors.  Goal: strongly shuffle
# the pack just before the finish straight, so the late-race ranking is
# determined here (high betting variance).
func _build_chaos_zone_3_reshuffle() -> void:
	var pin_mat := TrackBlocks.std_mat_emit(COL_RESHUFFLE, 0.10, 0.40, 0.40)
	var defl_mat := TrackBlocks.std_mat_emit(COL_RESHUFFLE, 0.10, 0.30, 0.55)
	var body := StaticBody3D.new()
	body.name = "ChaosZone3_Reshuffle"
	body.physics_material_override = _mat_fan_bumper
	add_child(body)

	# 4 pins distributed over a small θ-window centred on CHAOS3_THETA.
	var d_theta: float = TOTAL_THETA / float(TOTAL_SEGS)
	for i in range(4):
		var theta: float = CHAOS3_THETA + (float(i) - 1.5) * d_theta * 1.5
		var data := _helix_at(theta)
		var pos: Vector3 = data["pos"]
		var fwd: Vector3 = data["tangent"]
		var radial: Vector3 = data["radial"]
		var up := fwd.cross(radial).normalized()
		# Stagger pin x-position across ramp width.
		var dx: float = (-1.5 if i % 2 == 0 else 1.5) + (-0.4 if i < 2 else 0.4)
		var pin_pos: Vector3 = pos + radial * dx \
				+ up * (RESHUFFLE_PIN_H * 0.5 + FLOOR_THICK * 0.5)
		TrackBlocks.add_cylinder(body, "ReshufflePin%d" % i,
			Transform3D(Basis.IDENTITY, pin_pos),
			RESHUFFLE_PIN_R, RESHUFFLE_PIN_H, pin_mat)

	# 2 angled deflectors flanking the pins (at the rail-side edges).
	for i in range(2):
		var theta: float = CHAOS3_THETA + (float(i) - 0.5) * d_theta * 3.0
		var data := _helix_at(theta)
		var pos: Vector3 = data["pos"]
		var fwd: Vector3 = data["tangent"]
		var radial: Vector3 = data["radial"]
		var up := fwd.cross(radial).normalized()
		var defl_yaw := Basis(up, deg_to_rad(35.0 if i == 0 else -35.0))
		var basis := defl_yaw * Basis(fwd, up, radial)
		var d_pos: Vector3 = pos + radial * (RAMP_WIDTH * 0.5 - 0.5) * (1.0 if i == 0 else -1.0) \
				+ up * (RESHUFFLE_DEFL_SZ.y * 0.5 + FLOOR_THICK * 0.5)
		TrackBlocks.add_box(body, "ReshuffleDefl%d" % i,
			Transform3D(basis, d_pos),
			RESHUFFLE_DEFL_SZ,
			defl_mat)

# ─── v4 Jump — major air-time feature at θ ≈ 6.5π ────────────────────────
# Take-off ramp slope upward 8°, then the helix gap, then a landing pad
# JUMP_DROP_M below sloped 20° to feed marbles back onto the helix
# downstream.  Friction on landing pad = 0.12 (defined in _mat_landing).
func _build_jump() -> void:
	var takeoff_mat := TrackBlocks.std_mat_emit(COL_JUMP_RAMP, 0.10, 0.40, 0.55)
	var landing_mat := TrackBlocks.std_mat_emit(COL_LANDING, 0.10, 0.40, 0.45)
	var body := StaticBody3D.new()
	body.name = "JumpFeature"
	body.physics_material_override = _mat_landing
	add_child(body)

	if _jump_skip_start < 0 or _jump_skip_end <= _jump_skip_start:
		return

	var d_theta: float = TOTAL_THETA / float(TOTAL_SEGS)

	# Take-off ramp: a tilted slab covering 1 segment just BEFORE the gap.
	# Tilted upward (kick the marble into the air) by ~8°.
	var takeoff_idx: int = max(0, _jump_skip_start - 1)
	var theta_to: float = (float(takeoff_idx) + 0.5) * d_theta
	var data_to := _helix_at(theta_to)
	var pos_to: Vector3 = data_to["pos"]
	var fwd_to: Vector3 = data_to["tangent"]
	var radial_to: Vector3 = data_to["radial"]
	var up_to := fwd_to.cross(radial_to).normalized()
	var takeoff_basis := Basis(radial_to, deg_to_rad(-8.0)) * Basis(fwd_to, up_to, radial_to)
	var p1 := _helix_at(float(takeoff_idx) * d_theta)["pos"] as Vector3
	var p2 := _helix_at(float(takeoff_idx + 1) * d_theta)["pos"] as Vector3
	var chord_to: float = p1.distance_to(p2) * 1.1
	# Lift the takeoff slightly to integrate visually with the helix.
	TrackBlocks.add_box(body, "Takeoff",
		Transform3D(takeoff_basis, pos_to + up_to * 0.15),
		Vector3(chord_to, FLOOR_THICK, RAMP_WIDTH),
		takeoff_mat)

	# Landing pad: 4m × 0.5m × ramp_width, JUMP_DROP_M below the helix at
	# θ_landing = θ at end of skip range, sloped 20° downhill toward the
	# next helix segment.
	var landing_idx: int = _jump_skip_end
	var theta_la: float = (float(landing_idx) + 0.5) * d_theta
	var data_la := _helix_at(theta_la)
	var pos_la: Vector3 = data_la["pos"]
	var fwd_la: Vector3 = data_la["tangent"]
	var radial_la: Vector3 = data_la["radial"]
	var up_la := fwd_la.cross(radial_la).normalized()
	var landing_basis := Basis(radial_la, deg_to_rad(-JUMP_LAND_SLOPE_DEG)) * Basis(fwd_la, up_la, radial_la)
	# Position: at θ_landing but JUMP_DROP_M below the helix surface.
	var landing_pos: Vector3 = pos_la - up_la * JUMP_DROP_M
	# Shift slightly back (in -fwd direction) so it catches all ballistic
	# trajectories from the take-off.
	landing_pos -= fwd_la * (JUMP_LAND_LEN * 0.25)
	TrackBlocks.add_box(body, "LandingPad",
		Transform3D(landing_basis, landing_pos),
		Vector3(JUMP_LAND_LEN, FLOOR_THICK, RAMP_WIDTH + 1.0),
		landing_mat)

	# Recovery ramp: connects the landing pad up to the next helix segment.
	var recovery_pos: Vector3 = (landing_pos + pos_la) * 0.5 + up_la * 0.5
	TrackBlocks.add_box(body, "RecoveryRamp",
		Transform3D(landing_basis, recovery_pos),
		Vector3(2.5, FLOOR_THICK, RAMP_WIDTH),
		landing_mat)

# ─── v4 Split Drop — 70 / 30 fork at θ ≈ 4π ──────────────────────────────
# The main helix is hollowed out across SPLIT_LENGTH (handled by
# _split_skip_start/_end in _build_helix_segments).  Here we build:
#   - MAIN path: 70% of ramp width, at the original helix surface y
#   - SECONDARY path: 30% of ramp width, dropped SPLIT_SECOND_DROP=0.5m
# Both rejoin smoothly at the segment after _split_skip_end.
func _build_split_drop() -> void:
	if _split_skip_start < 0 or _split_skip_end <= _split_skip_start:
		return

	var main_mat := TrackBlocks.std_mat_emit(COL_RAMP_OUTER, 0.10, 0.55, 0.10)
	var second_mat := TrackBlocks.std_mat_emit(COL_RAMP_INNER, 0.10, 0.65, 0.10)

	var main_body := StaticBody3D.new()
	main_body.name = "SplitDrop_Main"
	main_body.physics_material_override = _mat_speed_zone
	add_child(main_body)
	var second_body := StaticBody3D.new()
	second_body.name = "SplitDrop_Secondary"
	second_body.physics_material_override = _mat_slow_zone
	add_child(second_body)

	var d_theta: float = TOTAL_THETA / float(TOTAL_SEGS)
	for i in range(_split_skip_start, _split_skip_end):
		var theta_mid: float = (float(i) + 0.5) * d_theta
		var data := _helix_at(theta_mid)
		var pos: Vector3 = data["pos"]
		var fwd: Vector3 = data["tangent"]
		var radial: Vector3 = data["radial"]
		var up := fwd.cross(radial).normalized()
		var basis := Basis(fwd, up, radial)

		var p1: Vector3 = _helix_at(float(i) * d_theta)["pos"]
		var p2: Vector3 = _helix_at(float(i + 1) * d_theta)["pos"]
		var chord: float = p1.distance_to(p2) * 1.06

		# Main path: SPLIT_MAIN_FRAC of ramp width on the OUTER side.
		var main_w: float = RAMP_WIDTH * SPLIT_MAIN_FRAC
		var main_centre_offset: float = (RAMP_WIDTH - main_w) * 0.5
		var main_pos: Vector3 = pos + radial * main_centre_offset
		TrackBlocks.add_box(main_body, "SplitMain%d" % i,
			Transform3D(basis, main_pos),
			Vector3(chord, FLOOR_THICK, main_w),
			main_mat)

		# Secondary path: (1 - SPLIT_MAIN_FRAC) of ramp width on the INNER
		# side, dropped by SPLIT_SECOND_DROP.
		var second_w: float = RAMP_WIDTH * (1.0 - SPLIT_MAIN_FRAC)
		var second_centre_offset: float = -(RAMP_WIDTH - second_w) * 0.5
		var second_pos: Vector3 = pos + radial * second_centre_offset \
				- up * SPLIT_SECOND_DROP
		TrackBlocks.add_box(second_body, "SplitSecond%d" % i,
			Transform3D(basis, second_pos),
			Vector3(chord, FLOOR_THICK, second_w),
			second_mat)

# ─── v4 Pickup zones (M19 payout v2 integration) ─────────────────────────
# 5 pickup zones distributed along the spiral per the v4 spec:
#   3 × Tier 1 in the EARLY spiral (turns 1-2, before chaos)
#   1 × Tier 2 in the MID-LATE spiral (turn 3-ish, just after split drop)
#   1 × HIGH-RISK Tier 2 right at the JUMP take-off — only fast marbles
#       grab it, slow ones miss as they tumble down the gap.
func _build_pickup_zones() -> void:
	var t1_mat := TrackBlocks.std_mat_emit(
		Color(0.40, 0.95, 0.55, 0.30),    # mossy green semi-transparent
		0.0, 0.50, 0.50)
	t1_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	var t2_mat := TrackBlocks.std_mat_emit(
		Color(1.00, 0.70, 0.20, 0.45),    # warm gold
		0.0, 0.40, 0.90)
	t2_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	var t2_risk_mat := TrackBlocks.std_mat_emit(
		Color(1.00, 0.20, 0.45, 0.50),    # vivid pink — high-risk T2
		0.0, 0.30, 1.10)
	t2_risk_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA

	# Helper: place one zone tangent to the helix at θ.
	var zones: Array = [
		# 3 × Tier 1 in turns 1-2 (θ ∈ [0.5π, 2.5π]).
		{"name": "PickupT1_a", "theta": 0.7 * PI,  "tier": PickupZone.TIER_1, "mat": t1_mat,
		 "size": Vector3(2.5, 1.0, 2.5)},
		{"name": "PickupT1_b", "theta": 1.7 * PI,  "tier": PickupZone.TIER_1, "mat": t1_mat,
		 "size": Vector3(2.5, 1.0, 2.5)},
		{"name": "PickupT1_c", "theta": 2.6 * PI,  "tier": PickupZone.TIER_1, "mat": t1_mat,
		 "size": Vector3(2.5, 1.0, 2.5)},
		# 1 × Tier 2 mid-late (after split-drop, before chaos 3).
		{"name": "PickupT2_mid", "theta": 4.6 * PI, "tier": PickupZone.TIER_2, "mat": t2_mat,
		 "size": Vector3(1.6, 1.2, 1.6)},
		# 1 × Tier 2 high-risk: at the jump take-off — fast marbles only.
		{"name": "PickupT2_jump", "theta": JUMP_THETA - 0.15 * PI, "tier": PickupZone.TIER_2, "mat": t2_risk_mat,
		 "size": Vector3(1.4, 1.5, 1.8)},
	]
	for cfg in zones:
		var data := _helix_at(float(cfg["theta"]))
		var pos: Vector3 = data["pos"]
		# Lift zone above the ramp surface so it captures marbles passing through.
		var zone_pos: Vector3 = pos + Vector3(0.0, 0.8, 0.0)
		TrackBlocks.add_pickup_zone(self, String(cfg["name"]),
			Transform3D(Basis.IDENTITY, zone_pos),
			cfg["size"] as Vector3,
			int(cfg["tier"]),
			cfg["mat"])

# Finish platform: a flat catch surface at the bottom of the helix,
# directly under the helix exit point.  Includes a finish-line gate
# centred on the exit position.
func _build_finish_platform() -> void:
	var floor_mat := TrackBlocks.std_mat_emit(COL_GATE, 0.85, 0.30, 0.30)
	var body := StaticBody3D.new()
	body.name = "FinishPlatform"
	body.physics_material_override = _mat_gate
	add_child(body)

	# Helix exit point at θ=TOTAL_THETA.
	var exit := _helix_at(TOTAL_THETA)
	var exit_pos: Vector3 = exit["pos"]
	# Flat platform 12m × 12m centred on exit, surface at y=GATE_Y - 0.5
	# (slightly below so marbles drop onto it cleanly).
	var pad_center := Vector3(exit_pos.x, GATE_Y - 0.5, exit_pos.z)
	TrackBlocks.add_box(body, "FinishPad",
		Transform3D(Basis.IDENTITY, pad_center),
		Vector3(14.0, FLOOR_THICK, 14.0),
		floor_mat)

# Catchment safety net well below the gate.
func _build_catchment() -> void:
	var mat := TrackBlocks.std_mat(Color(0.10, 0.07, 0.05), 0.10, 0.85)
	var body := StaticBody3D.new()
	body.name = "Catchment"
	body.physics_material_override = _mat_gate
	add_child(body)
	# Big square catch covering the spiral footprint.
	TrackBlocks.add_box(body, "CatchFloor",
		Transform3D(Basis.IDENTITY, Vector3(0.0, FLOOR_BASE_Y, 0.0)),
		Vector3(50.0, FLOOR_THICK, 50.0),
		mat)

# ─── Scenografia: ground plane (terreno sotto tutto) ────────────────────────
# Wide grass + dirt circle around the spiral footprint.  The track
# stands on a real ground, not in the void.
func _build_ground_plane() -> void:
	var grass_mat := TrackBlocks.std_mat(Color(0.20, 0.32, 0.15), 0.0, 0.95)
	var dirt_mat  := TrackBlocks.std_mat(Color(0.45, 0.32, 0.18), 0.0, 0.90)
	var body := StaticBody3D.new()
	body.name = "GroundPlane"
	add_child(body)
	# Grass square 80×80m (contains the v3.3 footprint: stands R=22, poles R=26).
	TrackBlocks.add_box(body, "Grass",
		Transform3D(Basis.IDENTITY, Vector3(0.0, FLOOR_BASE_Y - 0.5, 0.0)),
		Vector3(80.0, 0.5, 80.0),
		grass_mat)
	# Dirt ring around the spiral (visual variation under the track).
	TrackBlocks.add_box(body, "DirtRing",
		Transform3D(Basis.IDENTITY, Vector3(0.0, FLOOR_BASE_Y - 0.49, 0.0)),
		Vector3(40.0, 0.5, 40.0),
		dirt_mat)

# ─── Scenografia: arena base (sand-pit ring around the spiral) ──────────────
# Low circular wall around the spiral, like a sand pit / raceway boundary.
# Built as 24 box segments forming a 24-sided polygon approximating a circle.
func _build_scenography_arena() -> void:
	var wall_mat := TrackBlocks.std_mat(Color(0.65, 0.55, 0.40), 0.0, 0.90)
	var body := StaticBody3D.new()
	body.name = "ArenaWall"
	add_child(body)

	const SEGS: int = 32
	const ARENA_R: float = 16.0
	const ARENA_H: float = 0.8
	for i in range(SEGS):
		var a: float = float(i) * TAU / float(SEGS) + (TAU / float(SEGS) * 0.5)
		var seg_pos := Vector3(ARENA_R * cos(a), FLOOR_BASE_Y + ARENA_H * 0.5, ARENA_R * sin(a))
		var basis := Basis(Vector3.UP, a + PI * 0.5)
		var chord: float = 2.0 * ARENA_R * sin(PI / float(SEGS)) * 1.05
		TrackBlocks.add_box(body, "ArenaSeg%d" % i,
			Transform3D(basis, seg_pos),
			Vector3(chord, ARENA_H, 0.4),
			wall_mat)

# ─── Scenografia: tribuna pubblico ──────────────────────────────────────────
# 4 stand di tribuna stadium-style attorno alla spirale, ai 4 punti
# cardinali.  Ogni stand è 3 file di gradini, riempite di "spettatori"
# (cubetti colorati randomicamente — niente IA, statici).
func _build_scenography_audience() -> void:
	var stand_mat := TrackBlocks.std_mat(Color(0.42, 0.40, 0.45), 0.10, 0.80)
	var body := StaticBody3D.new()
	body.name = "AudienceStands"
	add_child(body)

	# 4 stand ai 4 punti cardinali, raggio 22m (fuori dal footprint spirale R=12).
	var stand_positions: Array = [
		{"pos": Vector3(  0.0, 0.0,  22.0), "yaw_deg":   0.0},
		{"pos": Vector3(  0.0, 0.0, -22.0), "yaw_deg": 180.0},
		{"pos": Vector3( 22.0, 0.0,   0.0), "yaw_deg":  90.0},
		{"pos": Vector3(-22.0, 0.0,   0.0), "yaw_deg": -90.0},
	]
	const STAND_W: float = 24.0
	const ROW_DEPTH: float = 1.8
	const ROW_H: float = 1.4
	const N_ROWS: int = 4

	for stand_idx in range(stand_positions.size()):
		var cfg: Dictionary = stand_positions[stand_idx]
		var origin: Vector3 = cfg["pos"]
		var yaw: float = deg_to_rad(float(cfg["yaw_deg"]))
		var basis := Basis(Vector3.UP, yaw)
		# Costruzione gradini (concrete tiers).
		for r in range(N_ROWS):
			var row_y: float = FLOOR_BASE_Y + float(r) * ROW_H + ROW_H * 0.5
			# Step depth: each row offset back from the previous.
			var local_z: float = -float(r) * ROW_DEPTH
			var local_pos := Vector3(0.0, row_y, local_z)
			var world_pos := origin + basis * local_pos
			TrackBlocks.add_box(body, "Stand%d_R%d" % [stand_idx, r],
				Transform3D(basis, world_pos),
				Vector3(STAND_W, ROW_H, ROW_DEPTH),
				stand_mat)
		# Cubetti spettatori: 8 colonne × N_ROWS file = 32 cubetti per stand.
		# Colori sgargianti, statici.  Sit on top of each step row.
		for r in range(N_ROWS):
			var seat_y: float = FLOOR_BASE_Y + float(r) * ROW_H + ROW_H + 0.4
			var local_z: float = -float(r) * ROW_DEPTH
			for c in range(8):
				var dx: float = (float(c) - 3.5) * 2.6
				var local_pos := Vector3(dx, seat_y, local_z)
				var world_pos := origin + basis * local_pos
				# Color jitter — deterministic from stand+row+col indices.
				var seed_v: int = stand_idx * 100 + r * 10 + c
				var hue: float = fmod(float(seed_v) * 0.137, 1.0)
				var col := Color.from_hsv(hue, 0.65, 0.85)
				var seat_mat := TrackBlocks.std_mat(col, 0.0, 0.70)
				TrackBlocks.add_box(body, "Spectator_S%d_R%d_C%d" % [stand_idx, r, c],
					Transform3D(basis, world_pos),
					Vector3(0.7, 0.8, 0.7),
					seat_mat)

# ─── Scenografia: palme decorative ──────────────────────────────────────────
# 6 palme attorno alla spirale, fra le tribune.  Ogni palma = tronco
# cilindrico marrone + chioma cilindrica verde appiattita in cima.
func _build_scenography_palms() -> void:
	var trunk_mat := TrackBlocks.std_mat(Color(0.45, 0.30, 0.18), 0.0, 0.95)
	var leaves_mat := TrackBlocks.std_mat_emit(Color(0.30, 0.55, 0.20), 0.0, 0.85, 0.10)
	var body := StaticBody3D.new()
	body.name = "Palms"
	add_child(body)

	# 8 palme ad anello raggio 19m (fuori spirale R=12, davanti alle tribune R=22).
	const N_PALMS: int = 8
	const PALM_R: float = 19.0
	const TRUNK_H: float = 6.0
	const TRUNK_RADIUS: float = 0.35
	const LEAVES_RADIUS: float = 2.5
	const LEAVES_H: float = 1.5

	for i in range(N_PALMS):
		var angle: float = float(i) * TAU / float(N_PALMS) + PI / float(N_PALMS)
		var px: float = PALM_R * cos(angle)
		var pz: float = PALM_R * sin(angle)
		var trunk_pos := Vector3(px, FLOOR_BASE_Y + TRUNK_H * 0.5, pz)
		TrackBlocks.add_cylinder(body, "PalmTrunk%d" % i,
			Transform3D(Basis.IDENTITY, trunk_pos),
			TRUNK_RADIUS, TRUNK_H, trunk_mat)
		var leaves_pos := Vector3(px, FLOOR_BASE_Y + TRUNK_H + LEAVES_H * 0.5, pz)
		TrackBlocks.add_cylinder(body, "PalmLeaves%d" % i,
			Transform3D(Basis.IDENTITY, leaves_pos),
			LEAVES_RADIUS, LEAVES_H, leaves_mat)

# ─── Scenografia: banner pubblicitari ───────────────────────────────────────
# 8 banner inclinati sui lati delle tribune (tipo F1 advertising boards).
# Colorati, emissive — danno il "broadcast TV" feel.
func _build_scenography_banners() -> void:
	var body := StaticBody3D.new()
	body.name = "Banners"
	add_child(body)

	# Theme colors per banner ("sponsor" feel).
	var banner_colors: Array = [
		Color(0.95, 0.20, 0.20),    # red
		Color(0.20, 0.55, 0.95),    # blue
		Color(0.95, 0.85, 0.20),    # gold
		Color(0.30, 0.85, 0.40),    # green
		Color(0.95, 0.55, 0.20),    # orange
		Color(0.65, 0.30, 0.85),    # purple
		Color(0.20, 0.85, 0.85),    # cyan
		Color(0.95, 0.95, 0.95),    # white
	]
	const N_BANNERS: int = 12
	const BANNER_R: float = 14.5
	for i in range(N_BANNERS):
		var angle: float = float(i) * TAU / float(N_BANNERS)
		var px: float = BANNER_R * cos(angle)
		var pz: float = BANNER_R * sin(angle)
		var banner_pos := Vector3(px, FLOOR_BASE_Y + 1.0, pz)
		var basis := Basis(Vector3.UP, angle + PI * 0.5)
		var col: Color = banner_colors[i % banner_colors.size()]
		var banner_mat := TrackBlocks.std_mat_emit(col, 0.10, 0.40, 0.40)
		TrackBlocks.add_box(body, "Banner%d" % i,
			Transform3D(basis, banner_pos),
			Vector3(5.0, 1.6, 0.2),
			banner_mat)

# ─── Scenografia: stadium lighting (4 light poles) ───────────────────────────
# 4 lampioni stadium-style ai 4 angoli del campo.  Ognuno è un pilone
# alto + un OmniLight in cima.
func _build_stadium_lighting() -> void:
	var pole_mat := TrackBlocks.std_mat(Color(0.30, 0.30, 0.32), 0.50, 0.40)
	var lamp_mat := TrackBlocks.std_mat_emit(Color(1.0, 0.95, 0.85), 0.0, 0.20, 1.50)
	var body := StaticBody3D.new()
	body.name = "StadiumLights"
	add_child(body)

	const N_POLES: int = 4
	const POLE_R: float = 26.0
	const POLE_H: float = 22.0
	const POLE_RADIUS: float = 0.4
	for i in range(N_POLES):
		var angle: float = float(i) * TAU / float(N_POLES) + PI / float(N_POLES)
		var px: float = POLE_R * cos(angle)
		var pz: float = POLE_R * sin(angle)
		var pole_pos := Vector3(px, FLOOR_BASE_Y + POLE_H * 0.5, pz)
		TrackBlocks.add_cylinder(body, "LightPole%d" % i,
			Transform3D(Basis.IDENTITY, pole_pos),
			POLE_RADIUS, POLE_H, pole_mat)
		# Lamp head (small box at the top).
		var lamp_pos := Vector3(px, FLOOR_BASE_Y + POLE_H + 0.3, pz)
		TrackBlocks.add_box(body, "Lamp%d" % i,
			Transform3D(Basis.IDENTITY, lamp_pos),
			Vector3(1.6, 0.6, 1.0),
			lamp_mat)
		# Real OmniLight for actual illumination.
		var lamp_light := OmniLight3D.new()
		lamp_light.name = "LampLight%d" % i
		lamp_light.light_color  = Color(1.0, 0.95, 0.80)
		lamp_light.light_energy = 1.6
		lamp_light.omni_range   = 35.0
		lamp_light.position     = Vector3(px, FLOOR_BASE_Y + POLE_H, pz)
		add_child(lamp_light)

func _build_mood_lights() -> void:
	# Warm spotlight focused on the helix center, plus a soft fill.
	var key := DirectionalLight3D.new()
	key.name = "SpiralKey"
	key.light_color    = Color(1.0, 0.92, 0.70)
	key.light_energy   = 1.5
	key.rotation_degrees = Vector3(-55.0, -25.0, 0.0)
	key.shadow_enabled = true
	add_child(key)
	var fill := OmniLight3D.new()
	fill.name = "SpiralFill"
	fill.light_color  = Color(0.85, 0.70, 0.45)
	fill.light_energy = 1.2
	fill.omni_range   = 60.0
	fill.position     = Vector3(0.0, (SPAWN_Y + GATE_Y) * 0.5, 25.0)
	add_child(fill)
	# Gate spotlight — golden glow at the helix exit.
	var exit := _helix_at(TOTAL_THETA)
	var exit_pos: Vector3 = exit["pos"]
	var gate_spot := OmniLight3D.new()
	gate_spot.name = "GateGlow"
	gate_spot.light_color  = Color(1.0, 0.85, 0.30)
	gate_spot.light_energy = 2.2
	gate_spot.omni_range   = 14.0
	gate_spot.position     = Vector3(exit_pos.x, GATE_Y + 4.0, exit_pos.z)
	add_child(gate_spot)

# ─── Track API overrides ────────────────────────────────────────────────────

# 32 spawn slots (M20 SLOT_COUNT=32).  v3.4 layout:
# Marbles spawn DIRECTLY above the first 4 helix segments (θ ∈ [0, 4dθ])
# instead of on a flat entry platform.  This guarantees they drop onto the
# ramp surface (with non-zero pitch from the start) and immediately begin
# rolling forward — was the v3.3 stall: flat platform meant marbles had
# no forward momentum and either sat there or fell off the inner edge.
#
# 8 columns × 4 rows.  Each row sits above one helix segment.  Columns
# span the ramp width.
func spawn_points() -> Array:
	var pts: Array = []
	var d_theta: float = TOTAL_THETA / float(TOTAL_SEGS)
	for r in range(SPAWN_ROWS):
		for c in range(SPAWN_COLS):
			var theta: float = (float(r) + 0.5) * d_theta
			var data := _helix_at(theta)
			var seg_pos: Vector3 = data["pos"]
			var radial: Vector3 = data["radial"]
			# col offset across the ramp width (-1.75 .. +1.75 for 8 cols).
			var dx: float = (float(c) - float(SPAWN_COLS - 1) * 0.5) * SPAWN_DX
			# Slot position: on the helix segment, offset radially, lifted
			# 1m above the ramp surface so marbles drop cleanly.
			var slot_pos: Vector3 = seg_pos + radial * dx + Vector3(0.0, SPAWN_LIFT + 0.5, 0.0)
			pts.append(slot_pos)
	return pts

func finish_area_transform() -> Transform3D:
	var exit := _helix_at(TOTAL_THETA)
	var exit_pos: Vector3 = exit["pos"]
	return Transform3D(Basis.IDENTITY,
		Vector3(exit_pos.x, GATE_Y + FINISH_Y_OFF, exit_pos.z))

func finish_area_size() -> Vector3:
	return FINISH_BOX_SIZE

func camera_bounds() -> AABB:
	# v3.3 footprint: spirale R=12, stands R=22, light poles R=26.
	var min_v := Vector3(-32.0, FLOOR_BASE_Y - 2.0, -32.0)
	var max_v := Vector3( 32.0, SPAWN_Y + 6.0,       32.0)
	return AABB(min_v, max_v - min_v)

func camera_pose() -> Dictionary:
	# v3.3: HIGH ANGLE top-down (~55° down) so the viewer reads the spiral
	# as a SNAIL SHELL FROM ABOVE.  Closer-in than v3.2 because the spiral
	# is now smaller (R=12 vs R=20).
	var mid_y: float = (SPAWN_Y + GATE_Y) * 0.5
	return {
		"position": Vector3(0.0, mid_y + 30.0, 30.0),
		"target":   Vector3(0.0, GATE_Y, 0.0),
		"fov":      55.0,
	}

func environment_overrides() -> Dictionary:
	# Late-afternoon stadium: warm sky, bright sun, slight haze to suggest
	# atmosphere/depth, ambient lifted so the scenography reads.
	return {
		"sky_top":        Color(0.20, 0.42, 0.78),
		"sky_horizon":    Color(0.95, 0.70, 0.40),
		"ambient_energy": 1.05,
		"fog_color":      Color(0.85, 0.72, 0.55),
		"fog_density":    0.0008,
		"sun_color":      Color(1.0, 0.92, 0.70),
		"sun_energy":     1.7,
	}
