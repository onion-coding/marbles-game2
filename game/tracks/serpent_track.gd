class_name SerpentTrack
extends Track

# SerpentTrack — Phase 6 prototype #1 (M23).
#
# First track with a GENUINELY different geometric silhouette from the
# M11 drop-cascade (V-funnel → 3 ramps → peg field → gate). This is a
# horizontal SERPENT shape: 4 long lanes stacked vertically, marbles
# alternate left→right and right→left, joined by curved 180° turn-arounds
# at the lane ends. Visible silhouette: an S-shape lying on its side.
#
# Field is 50m wide × 8m deep × ~44m tall (vs Forest's 40×5×~46) so the
# camera frames a wider, less-tall silhouette than the cascade tracks.
#
# Per-lane unique mechanics so each segment of the snake feels different:
#   C1 (top, +X direction)    : 3 vertical pillar obstacles (slalom)
#   Turn-1 (right, -Y drop)   : curved redirector (6-segment arc)
#   C2 (-X direction)         : ROTATING horizontal bar (kinematic)
#   Turn-2 (left, -Y drop)    : curved redirector
#   C3 (+X direction)         : 4 BUMPER triangles (peg-like deflectors)
#   Turn-3 (right, -Y drop)   : curved redirector
#   C4 (bottom, -X direction) : pin slalom (4 vertical pins)
#   Final drop                : Tier-2 pickup zone at the centre, then gate
#
# Determinism: rotating bar in C2 derives ω from `_hash_with_tag` so
# different rounds show different timing while staying replay-stable.
# Everything else is static.
#
# Field axes:
#   +X = right, -X = left, +Y = up, +Z = behind, -Z = camera.
#
# Lane layout (Y descends from spawn to gate):
#   spawn at  y=36, x in [-12, +12]
#   C1 at     y=34, runs x=-22 → +22 (length 44m), tilted +X
#   Turn-1   pivot=(+18, 30, 0), R=4, redirects to C2 at +X end
#   C2 at     y=26, runs x=+22 → -22, tilted -X
#   Turn-2   pivot=(-18, 22, 0), R=4
#   C3 at     y=18, runs x=-22 → +22, tilted +X
#   Turn-3   pivot=(+18, 14, 0), R=4
#   C4 at     y=10, runs x=+22 → -22, tilted -X
#   Drop from C4's -X end down to the gate at y=0
#   Gate at   y=0, full field width
#
# Total path length ≈ 4×44 + 3×(π·4) ≈ 213 m.  At ~3-4° lane tilt under
# real gravity, expected race time 35-50s (matches the user-requested
# 40-45s target window).

# ─── Field dimensions ────────────────────────────────────────────────────────
const FIELD_W       := 50.0          # X extent
const FIELD_DEPTH   := 6.0           # Z extent
const WALL_THICK    := 0.5
const FLOOR_THICK   := 0.5

# ─── Vertical layout (Y) ─────────────────────────────────────────────────────
const SPAWN_Y       := 36.0
const C1_Y          := 33.0          # lane 1 floor
const C2_Y          := 25.0
const C3_Y          := 17.0
const C4_Y          :=  9.0
const GATE_Y        :=  0.0
const FLOOR_BASE_Y  := -6.0

# ─── Horizontal layout (X) ───────────────────────────────────────────────────
const X_LEFT        := -22.0
const X_RIGHT       :=  22.0
# Distance from each lane end to the turn pivot.  Pivot sits inboard by
# the turn radius so the arc terminates right at the lane edge.
const TURN_RADIUS   := 4.0

# ─── Lane physics tuning ─────────────────────────────────────────────────────
# Mild tilt — long lanes accumulate too much speed at higher angles.
# 3.5° on a 44m lane gives ~6.5 m/s exit speed, slow enough that turn
# arcs actually redirect rather than launch.
const LANE_TILT_DEG := 3.5
# Lane width along Z (canal cross-section).  Slightly less than the field
# depth so there's a small visual gap to the side walls.
const LANE_INNER_DEPTH := FIELD_DEPTH - 0.6
# Side wall height above lane floor.  Tall enough that even a high-bounce
# marble can't hop the wall and skip the rest of the snake.
const SIDE_WALL_H   := 4.0

# ─── Spawn (32 slots, identical layout across all tracks) ────────────────────
const SPAWN_COLS := 8
const SPAWN_ROWS := 3
const SPAWN_DX   := 1.6
const SPAWN_DZ   := 1.0

# ─── Finish line ─────────────────────────────────────────────────────────────
const FINISH_Y_OFF := 2.5
const FINISH_BOX   := Vector3(FIELD_W + 2.0, 5.0, FIELD_DEPTH + 1.0)
const F6_LANES     := 30

# ─── Lane mechanic tuning ────────────────────────────────────────────────────
# C1 pillars — 3 vertical cylinders for slalom.
const C1_PILLAR_R  := 0.5
const C1_PILLAR_H  := 3.0
const C1_PILLAR_XS := [-10.0, 0.0, 10.0]

# C2 rotating bar — kinematic bar at lane centre, rotates around Z axis.
const C2_BAR_LEN     := 8.0
const C2_BAR_THICK   := 0.5
const C2_BAR_OMEGA_MAX := 1.5         # rad/s magnitude cap
const C2_BAR_OMEGA_MIN := 0.5

# C3 bumpers — 4 triangle-like wedges (approximated by tilted boxes).
const C3_BUMPER_W  := 1.6
const C3_BUMPER_H  := 1.6
const C3_BUMPER_XS := [-12.0, -4.0, 4.0, 12.0]

# C4 pins — 4 vertical thin pins (slalom).
const C4_PIN_R   := 0.3
const C4_PIN_H   := 2.5
const C4_PIN_XS  := [-12.0, -4.0, 4.0, 12.0]

# ─── Theme palette (snake / jungle) ──────────────────────────────────────────
# Hardcoded for the prototype; will move to TrackPalette once approved.
const COL_LANE_FLOOR := Color(0.32, 0.55, 0.30)   # mossy snake-back green
const COL_LANE_WALL  := Color(0.18, 0.30, 0.18)   # dark forest green
const COL_TURN_FLOOR := Color(0.50, 0.42, 0.20)   # dry-leaf brown
const COL_OBSTACLE   := Color(0.85, 0.65, 0.20)   # warning yellow (snake stripes)
const COL_PILLAR     := Color(0.45, 0.30, 0.18)
const COL_BAR        := Color(0.85, 0.20, 0.20)
const COL_BUMPER     := Color(0.95, 0.55, 0.15)
const COL_PIN        := Color(0.90, 0.85, 0.20)
const COL_GATE       := Color(0.92, 0.78, 0.18)

# Physics materials.
var _mat_floor:  PhysicsMaterial = null
var _mat_wall:   PhysicsMaterial = null
var _mat_obs:    PhysicsMaterial = null
var _mat_gate:   PhysicsMaterial = null
var _mat_bar:    PhysicsMaterial = null

# C2 rotating bar state.
var _c2_bar: AnimatableBody3D = null
var _c2_bar_pivot: Vector3 = Vector3.ZERO
var _c2_bar_omega: float = 0.0
var _c2_bar_time: float = 0.0

func _ready() -> void:
	_init_physics_materials()
	_build_outer_frame()
	_build_lane(0, "C1", C1_Y, +1)            # +X direction
	_build_turn_arc("Turn1", Vector3(X_RIGHT - TURN_RADIUS, (C1_Y + C2_Y) * 0.5, 0), TURN_RADIUS, true)   # right turn (+X to -X)
	_build_lane(1, "C2", C2_Y, -1)            # -X direction
	_build_turn_arc("Turn2", Vector3(X_LEFT + TURN_RADIUS, (C2_Y + C3_Y) * 0.5, 0), TURN_RADIUS, false)   # left turn
	_build_lane(2, "C3", C3_Y, +1)
	_build_turn_arc("Turn3", Vector3(X_RIGHT - TURN_RADIUS, (C3_Y + C4_Y) * 0.5, 0), TURN_RADIUS, true)
	_build_lane(3, "C4", C4_Y, -1)
	_build_lane_obstacles_c1()
	_build_lane_obstacles_c2()
	_build_lane_obstacles_c3()
	_build_lane_obstacles_c4()
	_build_final_drop()
	_build_gate()
	_build_catchment()
	_build_pickup_zones()
	_build_mood_lights()

func _physics_process(delta: float) -> void:
	# C2 rotating bar — spins around Z axis at seed-derived ω.
	if _c2_bar == null:
		return
	_c2_bar_time += delta
	var angle: float = _c2_bar_omega * _c2_bar_time
	var basis := Basis(Vector3(0, 0, 1), angle)
	_c2_bar.global_transform = Transform3D(basis, _c2_bar_pivot)

func _init_physics_materials() -> void:
	# Lane floors: moderate friction (marbles roll, don't stick).
	_mat_floor = PhysicsMaterial.new()
	_mat_floor.friction = 0.40
	_mat_floor.bounce   = 0.20

	# Walls: low friction, low bounce — marbles slide along them.
	_mat_wall = PhysicsMaterial.new()
	_mat_wall.friction = 0.15
	_mat_wall.bounce   = 0.15

	# Obstacles: bouncy so marbles deflect noticeably.
	_mat_obs = PhysicsMaterial.new()
	_mat_obs.friction = 0.20
	_mat_obs.bounce   = 0.55

	# Gate: very high friction so marbles settle quickly.
	_mat_gate = PhysicsMaterial.new()
	_mat_gate.friction = 0.55
	_mat_gate.bounce   = 0.10

	# Rotating bar: smooth + bouncy.
	_mat_bar = PhysicsMaterial.new()
	_mat_bar.friction = 0.25
	_mat_bar.bounce   = 0.50

func _build_outer_frame() -> void:
	var wall_mat := TrackBlocks.std_mat(COL_LANE_WALL, 0.10, 0.85)
	var frame := StaticBody3D.new()
	frame.name = "OuterFrame"
	frame.physics_material_override = _mat_wall
	add_child(frame)
	TrackBlocks.build_outer_frame(frame, "Frame",
		SPAWN_Y + 4.0, FLOOR_BASE_Y - 1.0,
		FIELD_W, FIELD_DEPTH, WALL_THICK, wall_mat)

# Build a single horizontal lane.  `dir = +1` → marbles roll +X; -1 → -X.
# The lane floor tilts so the downhill end is at `dir × X_RIGHT|X_LEFT`.
# Side walls (Z+ and Z-) keep marbles from rolling out of the depth axis.
# Top wall (ceiling) prevents high-bouncing marbles from escaping upward.
func _build_lane(idx: int, prefix: String, y_pos: float, dir: int) -> void:
	var floor_mat := TrackBlocks.std_mat_emit(COL_LANE_FLOOR, 0.10, 0.65, 0.10)
	var wall_mat  := TrackBlocks.std_mat(COL_LANE_WALL, 0.15, 0.80)
	var body := StaticBody3D.new()
	body.name = "%s_Lane" % prefix
	body.physics_material_override = _mat_floor
	add_child(body)

	# Lane floor: a tilted slab spanning x=[X_LEFT, X_RIGHT].
	# Tilt around Z: dir=+1 → -X edge UP / +X edge DOWN, so positive rotation.
	# Wait — Godot Z-rotation right-hand rule: +Z rotation lifts +X edge.
	# So for marble to roll +X (low at +X), we want -Z rotation, i.e. -tilt.
	var tilt_rad: float = -float(dir) * deg_to_rad(LANE_TILT_DEG)
	var basis := Basis(Vector3(0, 0, 1), tilt_rad)
	var lane_w: float = X_RIGHT - X_LEFT       # 44m
	var lane_center := Vector3(0.0, y_pos, 0.0)
	TrackBlocks.add_box(body, "%s_Floor" % prefix,
		Transform3D(basis, lane_center),
		Vector3(lane_w, FLOOR_THICK, LANE_INNER_DEPTH),
		floor_mat)

	# Side walls (Z+ and Z-) — high enough to contain bouncing marbles.
	for sgn_z in [-1, 1]:
		var z_pos: float = float(sgn_z) * (LANE_INNER_DEPTH * 0.5 + WALL_THICK * 0.5)
		var wall_center := Vector3(0.0, y_pos + SIDE_WALL_H * 0.5, z_pos)
		TrackBlocks.add_box(body, "%s_SideZ_%s" % [prefix, ("pos" if sgn_z > 0 else "neg")],
			Transform3D(basis, wall_center),
			Vector3(lane_w, SIDE_WALL_H, WALL_THICK),
			wall_mat)

	# Ceiling: a flat slab above the lane.  Prevents high-bounce escape.
	# Sits at lane_y + SIDE_WALL_H so there's room for the marble (radius 0.3)
	# plus ~3.4m headroom.  The ceiling is NOT tilted with the floor — it's
	# horizontal so the lane has a roof everywhere.
	var ceil_y: float = y_pos + SIDE_WALL_H + 0.5
	TrackBlocks.add_box(body, "%s_Ceiling" % prefix,
		Transform3D(Basis.IDENTITY, Vector3(0.0, ceil_y, 0.0)),
		Vector3(lane_w, FLOOR_THICK, LANE_INNER_DEPTH + WALL_THICK * 2.0),
		wall_mat)

	# Far-end wall (the END of the lane in direction `dir`) is OPEN — marbles
	# exit into the next turn.  The OPPOSITE end (where the marble entered
	# from the previous turn or spawn) gets a closing wall to prevent
	# back-rolling for entry lane idx > 0.
	if idx > 0:
		var entry_x: float = -float(dir) * X_RIGHT      # opposite side from exit
		var entry_wall_center := Vector3(entry_x + float(-dir) * 0.5, y_pos + SIDE_WALL_H * 0.5, 0.0)
		TrackBlocks.add_box(body, "%s_EntryWall" % prefix,
			Transform3D(basis, entry_wall_center),
			Vector3(WALL_THICK, SIDE_WALL_H, LANE_INNER_DEPTH),
			wall_mat)

# Build a curved redirector arc that takes marbles from one lane end and
# drops them into the next lane in the opposite direction.  Approximated
# by N straight box segments along a half-circle.
#
# `pivot`     : centre of the arc circle.
# `radius`    : radius of the arc.
# `right_turn`: true → turn goes around +X side (lane goes +X → -X);
#               false → turn goes around -X side (-X → +X).
#
# Marbles slide along the OUTER wall of the arc (the concave side).  The
# arc is built from `n_segs` short box segments tangent to the circle,
# forming a smooth-enough redirector.  Plus a flat floor along the arc
# bottom so marbles don't fall through.
func _build_turn_arc(prefix: String, pivot: Vector3, radius: float,
		right_turn: bool) -> void:
	var floor_mat := TrackBlocks.std_mat_emit(COL_TURN_FLOOR, 0.10, 0.50, 0.10)
	var wall_mat  := TrackBlocks.std_mat(COL_LANE_WALL, 0.15, 0.80)
	var body := StaticBody3D.new()
	body.name = "%s_Arc" % prefix
	body.physics_material_override = _mat_floor
	add_child(body)

	# Arc spans 180°.
	# right_turn=true:  marble enters from -X side at top of arc (angle=+π/2)
	#                   exits +X side at bottom (angle=-π/2) → arc goes from
	#                   +π/2 down to -π/2 going through 0 (i.e. through +X).
	# right_turn=false: mirrored, from -π/2 up to +π/2 going through π (-X).
	var n_segs := 8
	var start_angle: float
	var end_angle: float
	if right_turn:
		start_angle = PI * 0.5    # top of circle
		end_angle   = -PI * 0.5   # bottom, going clockwise through +X
	else:
		start_angle = PI * 0.5
		end_angle   = -PI * 0.5
		# For left turns we sweep the OTHER way (counterclockwise through -X).
		# Easiest: pivot's circle is the same, but we flip the OUTER wall
		# direction.  Implemented below by negating the segment offset.

	var dt: float = (end_angle - start_angle) / float(n_segs)
	# Outer wall: a series of box segments tangent to the circle at radius R.
	# Each segment is a short box rotated to align with its tangent.
	for i in range(n_segs):
		var a_mid: float = start_angle + dt * (float(i) + 0.5)
		# For left turn, mirror across X axis (negate cos component).
		var dir_x: float = cos(a_mid) if right_turn else -cos(a_mid)
		var dir_y: float = sin(a_mid)
		var center := pivot + radius * Vector3(dir_x, dir_y, 0.0)
		# Tangent direction is perpendicular to radius, rotated 90°.
		var tangent_angle: float = a_mid + PI * 0.5
		if not right_turn:
			tangent_angle = PI - a_mid + PI * 0.5    # mirror
		var basis := Basis(Vector3(0, 0, 1), tangent_angle)
		var chord: float = 2.0 * radius * sin(absf(dt) * 0.5)
		# Slightly bigger so segments overlap and there are no gaps.
		chord *= 1.05
		TrackBlocks.add_box(body, "%s_Seg%d" % [prefix, i],
			Transform3D(basis, center),
			Vector3(chord, FLOOR_THICK * 1.2, LANE_INNER_DEPTH),
			floor_mat)

	# Side walls (Z+ and Z-) — vertical slab on each side of the arc, sized
	# to bound the arc's bounding box so marbles can't escape laterally.
	var arc_half_w: float = radius + 0.5
	var arc_half_h: float = radius + 0.5
	for sgn_z in [-1, 1]:
		var z_pos: float = float(sgn_z) * (LANE_INNER_DEPTH * 0.5 + WALL_THICK * 0.5)
		TrackBlocks.add_box(body, "%s_SideZ_%s" % [prefix, ("pos" if sgn_z > 0 else "neg")],
			Transform3D(Basis.IDENTITY, pivot + Vector3(0.0, 0.0, z_pos)),
			Vector3(arc_half_w * 2.0, arc_half_h * 2.0, WALL_THICK),
			wall_mat)

# ─── Per-lane obstacles ──────────────────────────────────────────────────────

func _build_lane_obstacles_c1() -> void:
	# 3 vertical pillars in C1 — slalom.  Pillars sit ~0.5m above lane floor.
	var pillar_mat := TrackBlocks.std_mat_emit(COL_PILLAR, 0.10, 0.55, 0.05)
	var body := StaticBody3D.new()
	body.name = "C1_Pillars"
	body.physics_material_override = _mat_obs
	add_child(body)
	for i in range(C1_PILLAR_XS.size()):
		var x: float = float(C1_PILLAR_XS[i])
		# Pillar centre Y = lane floor + half pillar height + small gap.
		var y: float = C1_Y + C1_PILLAR_H * 0.5 + 0.3
		# Stagger Z slightly so the slalom forces lateral movement.
		var z: float = (-1.0 if i % 2 == 0 else 1.0) * 0.8
		TrackBlocks.add_cylinder(body, "Pillar_%d" % i,
			Transform3D(Basis.IDENTITY, Vector3(x, y, z)),
			C1_PILLAR_R, C1_PILLAR_H, pillar_mat)

func _build_lane_obstacles_c2() -> void:
	# Rotating horizontal bar at C2 centre.  Spins around the Z axis
	# (lane's depth axis), so it sweeps in the X-Y plane and can knock
	# marbles forward or backward depending on phase.
	var bar_mat := TrackBlocks.std_mat_emit(COL_BAR, 0.20, 0.30, 0.40)
	var pivot := Vector3(0.0, C2_Y + 1.5, 0.0)
	var body := TrackBlocks.add_animatable_cylinder(
		self, "C2_RotatingBar",
		Transform3D(Basis(Vector3.RIGHT, deg_to_rad(90.0)), pivot),
		C2_BAR_THICK * 0.5, C2_BAR_LEN, bar_mat)
	body.physics_material_override = _mat_bar
	_c2_bar = body
	_c2_bar_pivot = pivot

	# ω derived from seed.
	var hash_bytes: PackedByteArray = _hash_with_tag("serpent_c2_bar")
	var raw_omega: float
	if hash_bytes.size() >= 1:
		raw_omega = float(int(hash_bytes[0]) - 128) / 128.0
	else:
		raw_omega = 0.7
	if absf(raw_omega) < (C2_BAR_OMEGA_MIN / C2_BAR_OMEGA_MAX):
		raw_omega = (C2_BAR_OMEGA_MIN / C2_BAR_OMEGA_MAX) * (1.0 if raw_omega >= 0 else -1.0)
	_c2_bar_omega = raw_omega * C2_BAR_OMEGA_MAX

func _build_lane_obstacles_c3() -> void:
	# 4 bumper wedges along C3 — squat boxes that deflect marbles.
	var bumper_mat := TrackBlocks.std_mat_emit(COL_BUMPER, 0.10, 0.40, 0.30)
	var body := StaticBody3D.new()
	body.name = "C3_Bumpers"
	body.physics_material_override = _mat_obs
	add_child(body)
	for i in range(C3_BUMPER_XS.size()):
		var x: float = float(C3_BUMPER_XS[i])
		var y: float = C3_Y + C3_BUMPER_H * 0.5 + 0.3
		# Alternate Z so adjacent bumpers don't form a wall.
		var z: float = (-1.0 if i % 2 == 0 else 1.0) * 1.0
		# Tilted box ~30° around Y so the marble glances off at an angle.
		var basis := Basis(Vector3.UP, deg_to_rad(30.0 if i % 2 == 0 else -30.0))
		TrackBlocks.add_box(body, "Bumper_%d" % i,
			Transform3D(basis, Vector3(x, y, z)),
			Vector3(C3_BUMPER_W, C3_BUMPER_H, C3_BUMPER_W),
			bumper_mat)

func _build_lane_obstacles_c4() -> void:
	# Pin slalom in C4 — 4 thin vertical pins.
	var pin_mat := TrackBlocks.std_mat_emit(COL_PIN, 0.20, 0.35, 0.50)
	var body := StaticBody3D.new()
	body.name = "C4_Pins"
	body.physics_material_override = _mat_obs
	add_child(body)
	for i in range(C4_PIN_XS.size()):
		var x: float = float(C4_PIN_XS[i])
		var y: float = C4_Y + C4_PIN_H * 0.5 + 0.3
		var z: float = (-1.0 if i % 2 == 0 else 1.0) * 0.8
		TrackBlocks.add_cylinder(body, "Pin_%d" % i,
			Transform3D(Basis.IDENTITY, Vector3(x, y, z)),
			C4_PIN_R, C4_PIN_H, pin_mat)

# ─── Final drop from C4 to gate ──────────────────────────────────────────────
# C4 ends at -X (X_LEFT side).  We need to drop the marble from there
# down to the gate at y=0.  A single curved redirector at the C4 -X end
# turns the marble downward, then a short funnel concentrates marbles
# toward the gate centre.
func _build_final_drop() -> void:
	var floor_mat := TrackBlocks.std_mat_emit(COL_TURN_FLOOR, 0.10, 0.50, 0.10)
	var body := StaticBody3D.new()
	body.name = "FinalDrop"
	body.physics_material_override = _mat_floor
	add_child(body)

	# Redirector arc at C4 -X end: from the lane (going -X) down to falling
	# straight down.  Quarter-circle from angle=+π/2 to angle=π
	# (counterclockwise through -X), pivot at (X_LEFT + R, C4_Y - R, 0).
	var pivot := Vector3(X_LEFT + TURN_RADIUS, C4_Y - TURN_RADIUS, 0.0)
	var n_segs := 6
	var start_angle: float = PI * 0.5
	var end_angle: float   = PI
	var dt: float = (end_angle - start_angle) / float(n_segs)
	for i in range(n_segs):
		var a_mid: float = start_angle + dt * (float(i) + 0.5)
		var center := pivot + TURN_RADIUS * Vector3(cos(a_mid), sin(a_mid), 0.0)
		var tangent_angle: float = a_mid + PI * 0.5
		var basis := Basis(Vector3(0, 0, 1), tangent_angle)
		var chord: float = 2.0 * TURN_RADIUS * sin(absf(dt) * 0.5) * 1.05
		TrackBlocks.add_box(body, "FinalArc_%d" % i,
			Transform3D(basis, center),
			Vector3(chord, FLOOR_THICK * 1.2, LANE_INNER_DEPTH),
			floor_mat)

	# After the arc, marbles fall vertically.  Add side guides (-X and +X)
	# from the arc bottom down to the gate area so marbles can't drift.
	# The arc ends at pivot + R*(-1, 0, 0) = (X_LEFT, C4_Y - R, 0).
	var guide_top_y: float = C4_Y - TURN_RADIUS
	var guide_bot_y: float = GATE_Y + 4.0
	var guide_h: float = guide_top_y - guide_bot_y
	var guide_y: float = (guide_top_y + guide_bot_y) * 0.5
	var wall_mat := TrackBlocks.std_mat(COL_LANE_WALL, 0.15, 0.80)
	# Outer guide on -X side (continues the arc end).
	TrackBlocks.add_box(body, "FinalGuide_OuterX",
		Transform3D(Basis.IDENTITY, Vector3(X_LEFT - 0.5, guide_y, 0.0)),
		Vector3(WALL_THICK, guide_h, LANE_INNER_DEPTH),
		wall_mat)
	# Inner guide on +X side: angled inward to funnel marbles toward
	# centre.  Built as a tilted slab.
	var inner_tilt := deg_to_rad(15.0)
	var inner_basis := Basis(Vector3(0, 0, 1), inner_tilt)
	var inner_x: float = X_LEFT + 6.0
	TrackBlocks.add_box(body, "FinalGuide_Funnel",
		Transform3D(inner_basis, Vector3(inner_x, guide_y, 0.0)),
		Vector3(WALL_THICK, guide_h, LANE_INNER_DEPTH),
		wall_mat)

func _build_gate() -> void:
	var floor_mat := TrackBlocks.std_mat(COL_GATE, 0.85, 0.30)
	var div_mat   := TrackBlocks.std_mat_emit(COL_GATE, 0.30, 0.40, 0.45)
	var body := StaticBody3D.new()
	body.name = "Gate"
	body.physics_material_override = _mat_gate
	add_child(body)
	TrackBlocks.build_lane_gate(body, "Gate",
		GATE_Y, FIELD_W, FIELD_DEPTH, F6_LANES,
		1.5, 0.15, FLOOR_THICK, floor_mat, div_mat)

func _build_catchment() -> void:
	var mat := TrackBlocks.std_mat(Color(0.06, 0.10, 0.06), 0.10, 0.85)
	var body := StaticBody3D.new()
	body.name = "Catchment"
	body.physics_material_override = _mat_gate
	add_child(body)
	TrackBlocks.build_catchment(body, "Catch",
		FLOOR_BASE_Y, FIELD_W, FIELD_DEPTH, FLOOR_THICK, mat)

# ─── Pickup zones (M19 layout for v2 payout model) ──────────────────────────
# Tier-1 zones: one per lane, placed mid-lane where marbles concentrate.
# Tier-2 zone: in the final drop, narrow so only the lucky marble crosses.
func _build_pickup_zones() -> void:
	var t1_mat := TrackBlocks.std_mat_emit(
		Color(0.40, 0.95, 0.55, 0.30),    # mossy green semi-transparent
		0.0, 0.50, 0.50)
	t1_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	var t2_mat := TrackBlocks.std_mat_emit(
		Color(1.00, 0.70, 0.20, 0.45),    # warm gold semi-transparent
		0.0, 0.40, 0.90)
	t2_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA

	# T1 ×4: one per lane, centred on the X axis.  Z spans most of the
	# lane depth so any marble passing through the lane mid-section
	# triggers it.
	const T1_SIZE := Vector3(6.0, 1.5, LANE_INNER_DEPTH - 0.8)
	var t1_lanes: Array = [
		{"name": "PickupT1_C1", "y": C1_Y + 1.5, "x": -8.0},
		{"name": "PickupT1_C2", "y": C2_Y + 1.5, "x":  8.0},
		{"name": "PickupT1_C3", "y": C3_Y + 1.5, "x": -8.0},
		{"name": "PickupT1_C4", "y": C4_Y + 1.5, "x":  8.0},
	]
	for cfg in t1_lanes:
		TrackBlocks.add_pickup_zone(self, String(cfg["name"]),
			Transform3D(Basis.IDENTITY, Vector3(float(cfg["x"]), float(cfg["y"]), 0.0)),
			T1_SIZE, PickupZone.TIER_1, t1_mat)

	# T2 ×1: in the vertical drop after the final arc, narrow so only
	# marbles hitting near the centre trigger.  Sits at y = mid-drop.
	var t2_y: float = (C4_Y - TURN_RADIUS + GATE_Y) * 0.5
	TrackBlocks.add_pickup_zone(self, "PickupT2",
		Transform3D(Basis.IDENTITY, Vector3(X_LEFT + 3.0, t2_y, 0.0)),
		Vector3(2.0, 3.0, LANE_INNER_DEPTH - 0.8), PickupZone.TIER_2, t2_mat)

func _build_mood_lights() -> void:
	# Snake / jungle lighting: green-tinted key + warm uplight from the gate.
	var key := DirectionalLight3D.new()
	key.name = "SerpentKey"
	key.light_color    = Color(1.0, 0.95, 0.75)
	key.light_energy   = 1.4
	key.rotation_degrees = Vector3(-50.0, -25.0, 0.0)
	key.shadow_enabled = true
	add_child(key)
	var fill := OmniLight3D.new()
	fill.name = "SerpentFill"
	fill.light_color  = Color(0.45, 0.85, 0.50)
	fill.light_energy = 1.1
	fill.omni_range   = 60.0
	fill.position     = Vector3(0.0, (C2_Y + C3_Y) * 0.5, -8.0)
	add_child(fill)
	var gate_spot := OmniLight3D.new()
	gate_spot.name = "GateGlow"
	gate_spot.light_color  = Color(1.0, 0.85, 0.30)
	gate_spot.light_energy = 2.0
	gate_spot.omni_range   = 14.0
	gate_spot.position     = Vector3(0.0, GATE_Y + 4.0, 3.0)
	add_child(gate_spot)

# ─── Track API overrides ────────────────────────────────────────────────────

# 32 spawn slots — same convention as the M11 tracks (preserves backward
# compat with the M20 SLOT_COUNT=32 invariant).  Slots 0-23 in 8×3 grid
# above the C1 -X end (where marbles enter C1).  Slots 24-31 in a 4th row.
func spawn_points() -> Array:
	var pts: Array = []
	# Spawn cluster sits above C1's -X end so marbles drop directly into
	# the start of C1 and roll +X under gravity.
	var spawn_x_origin: float = X_LEFT + 4.0    # roughly above the C1 entry
	for r in range(SPAWN_ROWS):
		for c in range(SPAWN_COLS):
			var fx: float = spawn_x_origin + (float(c) - float(SPAWN_COLS - 1) * 0.5) * SPAWN_DX
			var fz: float = (float(r) - 1.0) * SPAWN_DZ
			pts.append(Vector3(fx, SPAWN_Y, fz))
	# 4th row at z=+2.0 (M20 expansion to 32 slots).
	for c in range(SPAWN_COLS):
		var fx: float = spawn_x_origin + (float(c) - float(SPAWN_COLS - 1) * 0.5) * SPAWN_DX
		pts.append(Vector3(fx, SPAWN_Y, 2.0))
	return pts

func finish_area_transform() -> Transform3D:
	return Transform3D(Basis.IDENTITY, Vector3(0.0, GATE_Y + FINISH_Y_OFF, 0.0))

func finish_area_size() -> Vector3:
	return FINISH_BOX

func camera_bounds() -> AABB:
	var min_v := Vector3(-FIELD_W * 0.5 - 1.0, FLOOR_BASE_Y - 2.0, -FIELD_DEPTH * 0.5 - 1.0)
	var max_v := Vector3( FIELD_W * 0.5 + 1.0, SPAWN_Y + 4.0,        FIELD_DEPTH * 0.5 + 1.0)
	return AABB(min_v, max_v - min_v)

func camera_pose() -> Dictionary:
	# The serpent silhouette is wider and shorter than the cascade tracks,
	# so we pull the camera back further along Z and lift it less.
	var mid_y: float = (SPAWN_Y + GATE_Y) * 0.5
	return {
		"position": Vector3(0.0, mid_y + 4.0, 65.0),
		"target":   Vector3(0.0, mid_y - 2.0, 0.0),
		"fov":      62.0,
	}

func environment_overrides() -> Dictionary:
	return {
		"sky_top":        Color(0.18, 0.32, 0.18),
		"sky_horizon":    Color(0.55, 0.65, 0.40),
		"ambient_energy": 0.95,
		"fog_color":      Color(0.40, 0.55, 0.35),
		"fog_density":    0.0015,
		"sun_color":      Color(1.0, 0.92, 0.72),
		"sun_energy":     1.5,
	}
