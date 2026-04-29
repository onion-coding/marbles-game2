class_name PlinkoTrack
extends Track

# M6.5 — Plinko. A vertical wall of staggered cylindrical pegs. Marbles drop
# from a hopper at the top, bounce chaotically through the peg forest, and
# settle into numbered slot catchers at the bottom. First marble to fully
# enter any slot wins.
#
# Determinism story: pegs are static, hopper is static. The course is
# deterministic-by-construction from track_id alone — no seed plumbing needed.
# Initial marble positions still vary per round (derived from server_seed by
# fairness protocol) so each round looks different.

# ─── Geometry ────────────────────────────────────────────────────────────
# Course depth (Z) is shallow so marbles stay roughly in the plane.
const COURSE_DEPTH := 1.4
# Play field width hugs the peg span (pegs at COL_SPACING 1.3-1.4 with 14
# columns reach ±7-8 m); side walls sit just outside that so marbles can't
# drift through gap-strips and miss the pegs. v3 narrowing forces every
# drop to thread through the peg field.
const PLAY_FIELD_WIDTH := 17.0
const PLAY_FIELD_HEIGHT := 60.0

# Field is dramatically taller now — three peg sections stacked over
# ~55 m of vertical, with kinematic spinning bars between them. Targets
# the longest practical Plinko race without making the descent boring:
# ~30 s in our smokes, vs the 5-12 s the smaller v1 produced.
const FIELD_TOP_Y := 60.0
const FIELD_BOTTOM_Y := 4.0

# ─── Hopper (wide chamber spanning the full play width) ──────────────────
# v3.2: previous bottleneck design (4 m chamber, 0.7 m outlet) made every
# marble exit through the same centred funnel — they all entered the peg
# field at the same X and traced almost identical paths. Now the chamber
# spans the full play width with a near-open floor; marbles spawn spread
# across the field and enter the pegs at varied X for genuine path
# variety. The "cube" is still visible (side walls + glass front) but no
# longer concentrates the flow.
const HOPPER_FLOOR_Y := 58.5
const HOPPER_INNER_W := 16.0             # matches PLAY_FIELD_WIDTH minus wall thickness
const HOPPER_INNER_H := 3.0              # shorter — no bottleneck queue space needed
const HOPPER_OUTLET_W := 15.0            # nearly the full inner width; only 0.5 m lip per side
const HOPPER_WALL_THICKNESS := 0.3
const HOPPER_FRICTION := 0.35

# Spawn 24 points across the wide chamber as an 8×3 grid. Y_STAGGER from
# SpawnRail still applies on top. Wider DX means each marble enters the
# peg field at a different X, dramatically increasing path randomness.
const SPAWN_Y := 59.5
const SPAWN_COLS := 8
const SPAWN_ROWS := 3
const SPAWN_DX := 1.7                    # 8 cols × 1.7 m = ~12 m spread; fits inside 16 m chamber
const SPAWN_DZ := 0.30

# ─── Peg forest ──────────────────────────────────────────────────────────
# Three stacked sections. Column spacing must be >= 2*(PEG_RADIUS + marble
# radius 0.3) ~= 1.2 m or marbles wedge between pegs; we keep all sections
# at 1.3 m to be safe with a small margin.
const PEG_RADIUS := 0.30
const PEG_HEIGHT := COURSE_DEPTH
const PEG_BASE_COLS := 14
const PEG_FRICTION := 0.55             # moderate friction — fast ping-and-go feel
const PEG_BOUNCE := 0.30               # higher bounce — marbles spread sideways more

# Section 1 (top of field) — sparse, sets rhythm.
const SECTION1_TOP_Y := FIELD_TOP_Y - 1.0
const SECTION1_ROWS := 10
const SECTION1_ROW_SPACING := 1.0
const SECTION1_COL_SPACING := 1.4

# ─── Serpentine zone (between SECTION1 and SECTION2) ─────────────────────
# Closed-U corridor with 4 alternating-direction lanes; each lane has a
# tilted floor that funnels marbles to one end, where they fall through a
# drop hole onto the next lane. A single kinematic paddle bar spins inside
# each lane as a moving obstacle. Replaces the old spinner-zone gaps.
#
# Marble path: top of S1 → Lane 1 (rolls +X) → Lane 2 (rolls -X) → Lane 3
# (rolls +X) → Lane 4 (rolls -X) → drops into S2.
const LANE_HEIGHT := 3.5            # vertical spacing between lane floors
const LANE_TILT_DEG := 5.0
const LANE_FLOOR_LEN := 14.0        # x-extent of each lane's floor
const LANE_FLOOR_THICKNESS := 0.25
const LANE_FRICTION := 0.35            # less drag on serpentine floors — faster traverse
const LANE_BOUNCE := 0.25
# A 2.0m wide drop hole at each lane's downhill end. Floor extends from
# x=-LANE_HALF to (LANE_HALF - DROP_HOLE_W) on +X-flow lanes; mirrored
# on -X-flow lanes. With LANE_HALF=8.0 + 0 margin, hole sits at x=+6 to
# +8 on lanes 1,3 and at x=-8 to -6 on lanes 2,4.
const LANE_HALF := 8.0
const LANE_DROP_HOLE_W := 2.0

# Lane floor Y positions (top to bottom). LANE1_FLOOR_Y is the floor's
# centreline at its mid-X point — actual surface tilts ±0.7 m around it.
const LANE1_FLOOR_Y := SECTION1_TOP_Y - SECTION1_ROWS * SECTION1_ROW_SPACING - 2.0
const LANE2_FLOOR_Y := LANE1_FLOOR_Y - LANE_HEIGHT
const LANE3_FLOOR_Y := LANE2_FLOOR_Y - LANE_HEIGHT
const LANE4_FLOOR_Y := LANE3_FLOOR_Y - LANE_HEIGHT

# Section 2 (middle) — main deflection zone, dense + tight. Now sits below
# the serpentine.
const SECTION2_TOP_Y := LANE4_FLOOR_Y - 2.5
const SECTION2_ROWS := 16
const SECTION2_ROW_SPACING := 0.95
const SECTION2_COL_SPACING := 1.3

# Section 3 (bottom) — short funnel directly above the slot row.
const SECTION3_TOP_Y := SECTION2_TOP_Y - SECTION2_ROWS * SECTION2_ROW_SPACING - 1.0
const SECTION3_ROWS := 6
const SECTION3_ROW_SPACING := 0.9
const SECTION3_COL_SPACING := 1.3

# ─── Spinning paddle bars (one per serpentine lane) ──────────────────────
# Kinematic AnimatableBody3D pivoting around world Z. Length is bounded
# by LANE_HEIGHT - some margin so when the paddle is vertical it doesn't
# punch through floor or ceiling. 2.4 m fits the 3.5 m clearance.
const SPINNER_BAR_LEN := 1.0     # short paddles that don't span the lane height —
                                  # avoid trapping marbles between blade tip and floor
const SPINNER_BAR_THICKNESS := 0.20
const SPINNER_FRICTION := 0.20
const SPINNER_BOUNCE := 0.55
# Angular velocities (rad/tick at 60 Hz). Two paddles total — placed only
# in the middle lanes (2 and 3) so the entry/exit lanes (1 and 4) are
# unobstructed and marbles flow naturally in/out of the serpentine.
# Slow rotation (~10 s per revolution) so paddles don't punt marbles
# backwards uphill.
const SPINNER_W := [-0.012, 0.011]

# ─── Slot row (bottom catchers) ──────────────────────────────────────────
const SLOT_COUNT := 9
const SLOT_DIVIDER_HEIGHT := 1.8
const SLOT_DIVIDER_THICKNESS := 0.18
const SLOT_FLOOR_Y := 9.0          # raised so the gap from S3's last peg row is ~3 m
                                    # (was 7.3 m); marbles drop quickly into the slot row
const SLOT_FLOOR_THICKNESS := 0.4
const SLOT_FRICTION := 0.55
const SLOT_BOUNCE := 0.10

# ─── Outer walls ─────────────────────────────────────────────────────────
const SIDE_WALL_FRICTION := 0.20
const SIDE_WALL_BOUNCE := 0.50

# ─── Finish ──────────────────────────────────────────────────────────────
# Spans the slot interior column — from slot-floor top (y=SLOT_FLOOR_Y) up
# to divider top. Any marble falling into a slot necessarily overlaps the
# slab's vertical span and triggers the body_entered signal.
const FINISH_Y := SLOT_FLOOR_Y + 0.9   # centred in the slot interior column
const FINISH_BOX_SIZE := Vector3(PLAY_FIELD_WIDTH + 2.0, 1.8, COURSE_DEPTH + 1.0)

# ─── Slow-motion gravity ─────────────────────────────────────────────────
# Starting at 1.0 m/s² — Plinko has many obstacles (pegs + paddles +
# serpentine walls) that already bleed speed. Full 9.8 m/s² yields ~27 s;
# target is 40-50 s. Tune via physics-tuner if needed.
const SLOW_GRAVITY_ACCEL := 3.5

# ─── Materials ───────────────────────────────────────────────────────────
const COLOR_FRAME := Color(0.06, 0.06, 0.10)
const COLOR_PEG := Color(0.96, 0.96, 0.96)
const COLOR_SLOT_FLOOR := Color(0.10, 0.05, 0.20)
const COLOR_DIVIDER_GOLD := Color(0.92, 0.78, 0.18)
const COLOR_DIVIDER_RED := Color(0.85, 0.18, 0.16)

var _peg_mat: PhysicsMaterial = null
var _wall_mat: PhysicsMaterial = null
var _slot_mat: PhysicsMaterial = null
var _spinner_mat: PhysicsMaterial = null
var _lane_mat: PhysicsMaterial = null

# Kinematic spinner state
var _spinners: Array[AnimatableBody3D] = []
var _spinner_centers: Array = []     # per-spinner pivot in world coords
var _local_tick: int = -1

func _ready() -> void:
	_init_materials()
	_build_outer_walls()
	_build_hopper()
	_build_peg_forest()
	_build_serpentine()
	_build_spinners()
	_build_slot_row()
	_build_slow_gravity_zone()
	_build_mood_light()

func _physics_process(_delta: float) -> void:
	_local_tick += 1
	for i in range(_spinners.size()):
		var w: float = float(SPINNER_W[i])
		var pivot: Vector3 = _spinner_centers[i]
		var angle: float = w * float(_local_tick)
		_spinners[i].global_transform = Transform3D(Basis(Vector3.FORWARD, angle), pivot)

func _build_slow_gravity_zone() -> void:
	# Replaces the default 9.8 m/s² gravity with SLOW_GRAVITY_ACCEL over the
	# entire play volume so the peg-bounce descent takes 40-50 s instead of ~27 s.
	var top_y: float = HOPPER_FLOOR_Y + HOPPER_INNER_H + 1.0   # ~63 m
	var bot_y: float = FINISH_Y                                  # ~9.9 m
	var centre_y: float = (top_y + bot_y) * 0.5
	var size_y: float = top_y - bot_y + 4.0                     # +2 m each end for safety
	var size_x: float = PLAY_FIELD_WIDTH + 4.0
	var size_z: float = COURSE_DEPTH + 4.0

	var zone := Area3D.new()
	zone.name = "SlowGravityZone"
	zone.gravity_space_override = Area3D.SPACE_OVERRIDE_REPLACE
	zone.gravity_direction = Vector3(0, -1, 0)
	zone.gravity = SLOW_GRAVITY_ACCEL
	zone.position = Vector3(0, centre_y, 0)
	add_child(zone)

	var coll := CollisionShape3D.new()
	coll.name = "SlowGravityZone_shape"
	var box := BoxShape3D.new()
	box.size = Vector3(size_x, size_y, size_z)
	coll.shape = box
	zone.add_child(coll)

func _build_mood_light() -> void:
	# Saturated magenta-arcade mood — the loudest track on the rotation.
	var key := OmniLight3D.new()
	key.name = "MoodLightKey"
	key.light_color = Color(1.0, 0.45, 0.85)
	key.light_energy = 2.4
	key.omni_range = 35.0
	key.position = Vector3(0, FIELD_TOP_Y - 4.0, 4.0)
	add_child(key)
	var rim := OmniLight3D.new()
	rim.name = "MoodLightRim"
	rim.light_color = Color(0.4, 0.85, 1.0)
	rim.light_energy = 1.5
	rim.omni_range = 25.0
	rim.position = Vector3(0, FIELD_BOTTOM_Y, -3.0)
	add_child(rim)

# ─── Materials ───────────────────────────────────────────────────────────

func _init_materials() -> void:
	_peg_mat = PhysicsMaterial.new()
	_peg_mat.friction = PEG_FRICTION
	_peg_mat.bounce = PEG_BOUNCE

	_wall_mat = PhysicsMaterial.new()
	_wall_mat.friction = SIDE_WALL_FRICTION
	_wall_mat.bounce = SIDE_WALL_BOUNCE

	_slot_mat = PhysicsMaterial.new()
	_slot_mat.friction = SLOT_FRICTION
	_slot_mat.bounce = SLOT_BOUNCE

	_spinner_mat = PhysicsMaterial.new()
	_spinner_mat.friction = SPINNER_FRICTION
	_spinner_mat.bounce = SPINNER_BOUNCE

	_lane_mat = PhysicsMaterial.new()
	_lane_mat.friction = LANE_FRICTION
	_lane_mat.bounce = LANE_BOUNCE

# ─── Outer frame ─────────────────────────────────────────────────────────

func _build_outer_walls() -> void:
	var frame_mat := StandardMaterial3D.new()
	frame_mat.albedo_color = COLOR_FRAME
	frame_mat.roughness = 0.6

	var frame := StaticBody3D.new()
	frame.name = "Frame"
	frame.physics_material_override = _wall_mat
	add_child(frame)

	# Frame envelopes everything from below the slot row to the top of the
	# closed hopper chamber.
	var top_y: float = HOPPER_FLOOR_Y + HOPPER_INNER_H + 1.0
	var height: float = top_y - FINISH_Y + 4.0
	var center_y: float = (top_y + FINISH_Y) * 0.5

	# Side walls (along Y, on +/-X)
	for sgn in [-1, 1]:
		var x: float = float(sgn) * (PLAY_FIELD_WIDTH * 0.5 + 0.2)
		_add_box(frame, "WallX_%s" % ("pos" if sgn > 0 else "neg"),
			Transform3D(Basis.IDENTITY, Vector3(x, center_y, 0)),
			Vector3(0.4, height, COURSE_DEPTH + 0.6),
			frame_mat)

	# Back panel (-Z): full mesh + collision; serves as the dark backdrop
	# the pegs sit against. The +Z (front) side gets collision only — no
	# mesh — so the camera looking from +Z can see straight into the play
	# volume without a wall blocking the view. Marbles still can't fly
	# out the front because the collision shape stays.
	_add_box(frame, "WallZ_neg",
		Transform3D(Basis.IDENTITY, Vector3(0, center_y, -COURSE_DEPTH * 0.5 - 0.2)),
		Vector3(PLAY_FIELD_WIDTH + 0.4, height, 0.4),
		frame_mat)

	var front_coll := CollisionShape3D.new()
	front_coll.name = "WallZ_pos_shape"
	var front_box := BoxShape3D.new()
	front_box.size = Vector3(PLAY_FIELD_WIDTH + 0.4, height, 0.4)
	front_coll.shape = front_box
	front_coll.transform = Transform3D(Basis.IDENTITY, Vector3(0, center_y, COURSE_DEPTH * 0.5 + 0.2))
	frame.add_child(front_coll)

# ─── Hopper (closed chamber with narrow floor outlet) ────────────────────

func _build_hopper() -> void:
	var frame_mat := StandardMaterial3D.new()
	frame_mat.albedo_color = COLOR_FRAME

	var glass_mat := StandardMaterial3D.new()
	glass_mat.albedo_color = Color(0.85, 0.45, 0.85, 0.20)
	glass_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	glass_mat.metallic = 0.4
	glass_mat.roughness = 0.10

	var hopper_mat := PhysicsMaterial.new()
	hopper_mat.friction = HOPPER_FRICTION
	hopper_mat.bounce = 0.30

	var hopper := StaticBody3D.new()
	hopper.name = "Hopper"
	hopper.physics_material_override = hopper_mat
	add_child(hopper)

	# Side walls (along Y, on +/-X)
	for sgn in [-1, 1]:
		var x: float = float(sgn) * (HOPPER_INNER_W * 0.5 + HOPPER_WALL_THICKNESS * 0.5)
		_add_box(hopper, "ChamberWallX_%s" % ("pos" if sgn > 0 else "neg"),
			Transform3D(Basis.IDENTITY, Vector3(x, HOPPER_FLOOR_Y + HOPPER_INNER_H * 0.5, 0)),
			Vector3(HOPPER_WALL_THICKNESS, HOPPER_INNER_H, COURSE_DEPTH + 0.4),
			frame_mat)

	# Floor with a centred outlet: build two slabs leaving a HOPPER_OUTLET_W
	# gap at x=0 so marbles only escape through that bottleneck.
	var slab_w: float = (HOPPER_INNER_W - HOPPER_OUTLET_W) * 0.5
	for sgn in [-1, 1]:
		var slab_x: float = float(sgn) * (HOPPER_OUTLET_W * 0.5 + slab_w * 0.5)
		_add_box(hopper, "ChamberFloor_%s" % ("pos" if sgn > 0 else "neg"),
			Transform3D(Basis.IDENTITY, Vector3(slab_x, HOPPER_FLOOR_Y, 0)),
			Vector3(slab_w, 0.3, COURSE_DEPTH + 0.4),
			frame_mat)

	# Glass front (visible) so the queueing animation reads from the camera.
	# Just a mesh, no collision (the outer Frame's front-wall collision
	# already handles depth containment).
	var glass_front := MeshInstance3D.new()
	glass_front.name = "ChamberGlass"
	var bm := BoxMesh.new()
	bm.size = Vector3(HOPPER_INNER_W + 2 * HOPPER_WALL_THICKNESS, HOPPER_INNER_H, 0.05)
	glass_front.mesh = bm
	glass_front.material_override = glass_mat
	glass_front.position = Vector3(0, HOPPER_FLOOR_Y + HOPPER_INNER_H * 0.5, COURSE_DEPTH * 0.5)
	hopper.add_child(glass_front)

# ─── Peg forest (3 stacked sections) ─────────────────────────────────────

func _build_peg_forest() -> void:
	var peg_mat := StandardMaterial3D.new()
	peg_mat.albedo_color = COLOR_PEG
	peg_mat.metallic = 0.85
	peg_mat.metallic_specular = 0.9
	peg_mat.roughness = 0.20
	peg_mat.emission_enabled = true
	peg_mat.emission = Color(0.95, 0.85, 1.0)
	peg_mat.emission_energy_multiplier = 0.15

	var pegs := StaticBody3D.new()
	pegs.name = "Pegs"
	pegs.physics_material_override = _peg_mat
	add_child(pegs)

	_build_peg_section(pegs, peg_mat, "S1", SECTION1_TOP_Y, SECTION1_ROWS, SECTION1_ROW_SPACING, SECTION1_COL_SPACING)
	_build_peg_section(pegs, peg_mat, "S2", SECTION2_TOP_Y, SECTION2_ROWS, SECTION2_ROW_SPACING, SECTION2_COL_SPACING)
	_build_peg_section(pegs, peg_mat, "S3", SECTION3_TOP_Y, SECTION3_ROWS, SECTION3_ROW_SPACING, SECTION3_COL_SPACING)

func _build_peg_section(parent: Node, peg_mat: StandardMaterial3D, tag: String, top_y: float, rows: int, row_spacing: float, col_spacing: float) -> void:
	for r in range(rows):
		var y: float = top_y - float(r) * row_spacing
		var cols: int = PEG_BASE_COLS if (r % 2 == 0) else PEG_BASE_COLS - 1
		var x_offset: float = 0.0 if (r % 2 == 0) else col_spacing * 0.5
		var x_origin: float = -float(cols - 1) * 0.5 * col_spacing + x_offset
		for c in range(cols):
			var x: float = x_origin + float(c) * col_spacing
			# Skip pegs that would sit outside the play field width.
			if abs(x) > PLAY_FIELD_WIDTH * 0.5 - PEG_RADIUS:
				continue
			var coll := CollisionShape3D.new()
			coll.name = "Peg_%s_%d_%d_shape" % [tag, r, c]
			var cs := CylinderShape3D.new()
			cs.radius = PEG_RADIUS
			cs.height = PEG_HEIGHT
			coll.shape = cs
			coll.transform = Transform3D(Basis(Vector3.RIGHT, deg_to_rad(90.0)), Vector3(x, y, 0))
			parent.add_child(coll)

			var mesh := MeshInstance3D.new()
			mesh.name = "Peg_%s_%d_%d_mesh" % [tag, r, c]
			var cm := CylinderMesh.new()
			cm.top_radius = PEG_RADIUS
			cm.bottom_radius = PEG_RADIUS
			cm.height = PEG_HEIGHT
			mesh.mesh = cm
			mesh.material_override = peg_mat
			mesh.transform = Transform3D(Basis(Vector3.RIGHT, deg_to_rad(90.0)), Vector3(x, y, 0))
			parent.add_child(mesh)

# ─── Serpentine corridor (4 alternating-direction lanes) ─────────────────

# Per-lane direction: +1 = lane flows toward +X (downhill +X), -1 = flows -X.
# Lanes 1 and 3 flow +X; lanes 2 and 4 flow -X. The drop hole sits at the
# downhill end so marbles always exit at the lane's low side.
const _LANE_DIRS := [1, -1, 1, -1]
const _LANE_FLOOR_YS := [LANE1_FLOOR_Y, LANE2_FLOOR_Y, LANE3_FLOOR_Y, LANE4_FLOOR_Y]

func _build_serpentine() -> void:
	var floor_mat := StandardMaterial3D.new()
	floor_mat.albedo_color = Color(0.18, 0.05, 0.20)
	floor_mat.metallic = 0.30
	floor_mat.roughness = 0.45
	floor_mat.emission_enabled = true
	floor_mat.emission = Color(0.95, 0.40, 0.95)
	floor_mat.emission_energy_multiplier = 0.10

	var corridor := StaticBody3D.new()
	corridor.name = "Serpentine"
	corridor.physics_material_override = _lane_mat
	add_child(corridor)

	for i in range(4):
		var dir: int = _LANE_DIRS[i]
		var lane_y: float = _LANE_FLOOR_YS[i]
		# Floor: spans LANE_FLOOR_LEN m along X, with the drop hole at the
		# downhill end. For a +X-flow lane, floor centre x is shifted -1 m
		# so the floor covers [-8, +6] and the hole sits at [+6, +8].
		# Mirror for -X-flow lanes.
		var floor_centre_x: float = -float(dir) * (LANE_DROP_HOLE_W * 0.5)
		var floor_size := Vector3(LANE_FLOOR_LEN, LANE_FLOOR_THICKNESS, COURSE_DEPTH + 0.4)
		# Tilt around Z. +X-flow: rotate -tilt around Z (so +X end sinks).
		# -X-flow: rotate +tilt (so -X end sinks).
		var lane_basis := Basis(Vector3(0, 0, 1), float(-dir) * deg_to_rad(LANE_TILT_DEG))
		_add_box(corridor, "LaneFloor_%d" % i,
			Transform3D(lane_basis, Vector3(floor_centre_x, lane_y, 0)),
			floor_size,
			floor_mat)

		# Closed-end wall at the uphill side. Sits 2 m above the lane's
		# floor surface so a falling marble that bounces high doesn't
		# pop over the wall back into the previous lane's drop column.
		var closed_x: float = -float(dir) * LANE_HALF
		var wall_h: float = LANE_HEIGHT - LANE_FLOOR_THICKNESS
		_add_box(corridor, "LaneClosedWall_%d" % i,
			Transform3D(Basis.IDENTITY, Vector3(closed_x, lane_y + wall_h * 0.5, 0)),
			Vector3(0.3, wall_h, COURSE_DEPTH + 0.4),
			floor_mat)

# ─── Spinning paddle bars (one per serpentine lane) ──────────────────────

func _build_spinners() -> void:
	var bar_mat := StandardMaterial3D.new()
	bar_mat.albedo_color = Color(0.95, 0.40, 0.85)
	bar_mat.metallic = 0.6
	bar_mat.roughness = 0.30
	bar_mat.emission_enabled = true
	bar_mat.emission = Color(1.0, 0.55, 0.95)
	bar_mat.emission_energy_multiplier = 0.55

	# Two paddles total, in the two middle lanes only (2 and 3). Lanes 1
	# and 4 stay clear so marbles enter and exit the serpentine without
	# obstruction. Pivot near each lane's mid-X with vertical clearance
	# above the floor surface so the paddle's sweep stays inside the
	# lane's vertical envelope.
	var configs := [
		{"y": LANE2_FLOOR_Y + 1.4, "x": 0.0},
		{"y": LANE3_FLOOR_Y + 1.4, "x": 0.0},
	]
	for i in range(configs.size()):
		var pivot := Vector3(float(configs[i]["x"]), float(configs[i]["y"]), 0.0)
		var bar := AnimatableBody3D.new()
		bar.name = "Spinner_%d" % i
		bar.physics_material_override = _spinner_mat
		bar.sync_to_physics = true
		bar.global_transform = Transform3D(Basis.IDENTITY, pivot)
		add_child(bar)

		var coll := CollisionShape3D.new()
		var box := BoxShape3D.new()
		box.size = Vector3(SPINNER_BAR_LEN, SPINNER_BAR_THICKNESS, COURSE_DEPTH * 0.9)
		coll.shape = box
		bar.add_child(coll)

		var mesh := MeshInstance3D.new()
		var bm := BoxMesh.new()
		bm.size = Vector3(SPINNER_BAR_LEN, SPINNER_BAR_THICKNESS, COURSE_DEPTH * 0.9)
		mesh.mesh = bm
		mesh.material_override = bar_mat
		bar.add_child(mesh)

		_spinners.append(bar)
		_spinner_centers.append(pivot)

# ─── Slot row ────────────────────────────────────────────────────────────

func _build_slot_row() -> void:
	var floor_mat := StandardMaterial3D.new()
	floor_mat.albedo_color = COLOR_SLOT_FLOOR
	var div_gold := StandardMaterial3D.new()
	div_gold.albedo_color = COLOR_DIVIDER_GOLD
	div_gold.metallic = 0.8
	div_gold.roughness = 0.30
	div_gold.emission_enabled = true
	div_gold.emission = COLOR_DIVIDER_GOLD
	div_gold.emission_energy_multiplier = 0.40
	var div_red := StandardMaterial3D.new()
	div_red.albedo_color = COLOR_DIVIDER_RED
	div_red.roughness = 0.40
	div_red.emission_enabled = true
	div_red.emission = COLOR_DIVIDER_RED
	div_red.emission_energy_multiplier = 0.40

	var slots := StaticBody3D.new()
	slots.name = "SlotRow"
	slots.physics_material_override = _slot_mat
	add_child(slots)

	# Floor
	_add_box(slots, "SlotFloor",
		Transform3D(Basis.IDENTITY, Vector3(0, SLOT_FLOOR_Y - SLOT_FLOOR_THICKNESS * 0.5, 0)),
		Vector3(PLAY_FIELD_WIDTH + 0.2, SLOT_FLOOR_THICKNESS, COURSE_DEPTH + 0.2),
		floor_mat)

	# Dividers (SLOT_COUNT + 1 walls).
	var slot_width: float = PLAY_FIELD_WIDTH / float(SLOT_COUNT)
	for i in range(SLOT_COUNT + 1):
		var x: float = -PLAY_FIELD_WIDTH * 0.5 + float(i) * slot_width
		var mat: StandardMaterial3D = div_gold if (i % 2 == 0) else div_red
		_add_box(slots, "Divider_%d" % i,
			Transform3D(Basis.IDENTITY, Vector3(x, SLOT_FLOOR_Y + SLOT_DIVIDER_HEIGHT * 0.5, 0)),
			Vector3(SLOT_DIVIDER_THICKNESS, SLOT_DIVIDER_HEIGHT, COURSE_DEPTH),
			mat)

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
	# 24 points clustered inside the hopper (8 cols × 3 rows). All within the
	# HOPPER_INNER_W to ensure marbles funnel through the throat.
	var points: Array = []
	for r in range(SPAWN_ROWS):
		for c in range(SPAWN_COLS):
			var fx: float = (float(c) - float(SPAWN_COLS - 1) * 0.5) * SPAWN_DX
			var fz: float = (float(r) - float(SPAWN_ROWS - 1) * 0.5) * SPAWN_DZ
			points.append(Vector3(fx, SPAWN_Y, fz))
	return points

func finish_area_transform() -> Transform3D:
	# Centered at the bottom of the slot row, axis-aligned.
	return Transform3D(Basis.IDENTITY, Vector3(0, FINISH_Y, 0))

func finish_area_size() -> Vector3:
	return FINISH_BOX_SIZE

func camera_bounds() -> AABB:
	# Y max covers the closed-hopper chamber + drop-order stagger above
	# SPAWN_Y. Field with the bottleneck hopper is ~62 m tall total.
	var min_v := Vector3(-PLAY_FIELD_WIDTH * 0.5 - 2.0, FINISH_Y - 2.0, -COURSE_DEPTH * 0.5 - 1.0)
	var max_v := Vector3(PLAY_FIELD_WIDTH * 0.5 + 2.0, HOPPER_FLOOR_Y + HOPPER_INNER_H + 4.0, COURSE_DEPTH * 0.5 + 1.0)
	return AABB(min_v, max_v - min_v)

func camera_pose() -> Dictionary:
	# Frontal view of the vertical peg tower. The play volume spans
	# ~9.9 m (FINISH_Y) to ~62.5 m (hopper top), a 52.6 m height, with
	# 17 m width. At FOV 70 the half-height subtends ~26 m; distance 45 m
	# keeps the full column in frame with margin on both sides.
	var mid_y: float = (FINISH_Y + HOPPER_FLOOR_Y + HOPPER_INNER_H) * 0.5
	return {
		"position": Vector3(0.0, mid_y, 45.0),
		"target":   Vector3(0.0, mid_y, 0.0),
		"fov":      70.0,
	}

func environment_overrides() -> Dictionary:
	# Arcade mood pulled out of fog + sun; sky stays the daylight cloud
	# default. Pinker sun against magenta fog reads as "loud arcade"
	# without fighting the sky shader the way a fully magenta sky did.
	return {
		"ambient_energy": 0.75,
		"fog_color": Color(0.95, 0.55, 0.80),
		"fog_density": 0.002,
		"sun_color": Color(1.0, 0.78, 0.95),
		"sun_energy": 1.3,
	}
