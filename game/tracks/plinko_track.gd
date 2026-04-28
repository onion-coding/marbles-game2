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
const PLAY_FIELD_WIDTH := 20.0
const PLAY_FIELD_HEIGHT := 60.0

# Field is dramatically taller now — three peg sections stacked over
# ~55 m of vertical, with kinematic spinning bars between them. Targets
# the longest practical Plinko race without making the descent boring:
# ~30 s in our smokes, vs the 5-12 s the smaller v1 produced.
const FIELD_TOP_Y := 60.0
const FIELD_BOTTOM_Y := 4.0

# ─── Hopper (closed-chamber bottleneck above the peg field) ──────────────
# Big enclosed chamber that holds all 20 marbles at race start; the only
# exit is a narrow slot in the floor (HOPPER_OUTLET_W) so marbles trickle
# out one or two at a time. This adds ~8-12 s of pre-field queue time
# that's visually engaging — the audience watches marbles compete to
# escape the cage before the descent even starts.
const HOPPER_FLOOR_Y := 58.5             # just above FIELD_TOP_Y
const HOPPER_INNER_W := 4.0              # plenty of room for 20 marbles
const HOPPER_INNER_H := 4.0
const HOPPER_OUTLET_W := 0.8             # ~1 marble wide; forces single-file egress
const HOPPER_WALL_THICKNESS := 0.3
const HOPPER_FRICTION := 0.35

# Spawn 24 points inside the hopper, lower-left to upper-right grid.
# The grid is wide so all marbles fit horizontally even at SLOT_COUNT=24
# without overlapping. Y_STAGGER from SpawnRail still applies on top.
const SPAWN_Y := 59.5                    # 1 m above hopper floor; 24 marbles stagger up to ~62.8
const SPAWN_COLS := 6
const SPAWN_ROWS := 4
const SPAWN_DX := 0.50
const SPAWN_DZ := 0.20

# ─── Peg forest ──────────────────────────────────────────────────────────
# Three stacked sections. Column spacing must be >= 2*(PEG_RADIUS + marble
# radius 0.3) ~= 1.2 m or marbles wedge between pegs; we keep all sections
# at 1.3 m to be safe with a small margin.
const PEG_RADIUS := 0.30
const PEG_HEIGHT := COURSE_DEPTH
const PEG_BASE_COLS := 14
const PEG_FRICTION := 0.85             # very grippy: each peg drains a lot of velocity
const PEG_BOUNCE := 0.10               # very low: marbles roll-and-slide rather than ping

# Section 1 (top of field) — sparse, sets rhythm.
const SECTION1_TOP_Y := FIELD_TOP_Y - 1.0
const SECTION1_ROWS := 12
const SECTION1_ROW_SPACING := 1.0
const SECTION1_COL_SPACING := 1.4

# Section 2 (middle) — main deflection zone, dense + tight.
const SECTION2_TOP_Y := SECTION1_TOP_Y - SECTION1_ROWS * SECTION1_ROW_SPACING - 3.5
const SECTION2_ROWS := 22
const SECTION2_ROW_SPACING := 0.95
const SECTION2_COL_SPACING := 1.3

# Section 3 (bottom) — funnel toward slot row.
const SECTION3_TOP_Y := SECTION2_TOP_Y - SECTION2_ROWS * SECTION2_ROW_SPACING - 3.5
const SECTION3_ROWS := 12
const SECTION3_ROW_SPACING := 0.9
const SECTION3_COL_SPACING := 1.3

# ─── Spinning paddle bars (kinematic obstacles between peg sections) ─────
# Each bar is a thin elongated AnimatableBody3D rotating around world Z so
# marbles falling on its top edge are flung sideways before continuing
# down. Two zones, two bars each.
const SPINNER_BAR_LEN := 6.0
const SPINNER_BAR_THICKNESS := 0.25
const SPINNER_FRICTION := 0.20
const SPINNER_BOUNCE := 0.55
# Y centre per bar; X offset per bar (alternating sides).
const SPINNER_ZONE1_Y := SECTION1_TOP_Y - SECTION1_ROWS * SECTION1_ROW_SPACING - 1.7
const SPINNER_ZONE2_Y := SECTION2_TOP_Y - SECTION2_ROWS * SECTION2_ROW_SPACING - 1.7
# Two bars per zone, offset on X so marbles can't slip down a single column.
const SPINNER_X_OFFSET := 4.0
# Angular velocities (rad/tick at 60Hz). Slow enough to read, fast enough
# to noticeably push marbles around.
const SPINNER_W := [0.040, -0.045, 0.038, -0.042]

# ─── Slot row (bottom catchers) ──────────────────────────────────────────
const SLOT_COUNT := 9
const SLOT_DIVIDER_HEIGHT := 1.8
const SLOT_DIVIDER_THICKNESS := 0.18
const SLOT_FLOOR_Y := 1.5
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
const FINISH_Y := 2.4
const FINISH_BOX_SIZE := Vector3(PLAY_FIELD_WIDTH + 2.0, 1.8, COURSE_DEPTH + 1.0)

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

# Kinematic spinner state
var _spinners: Array[AnimatableBody3D] = []
var _spinner_centers: Array = []     # per-spinner pivot in world coords
var _local_tick: int = -1

func _ready() -> void:
	_init_materials()
	_build_outer_walls()
	_build_hopper()
	_build_peg_forest()
	_build_spinners()
	_build_slot_row()
	_build_mood_light()

func _physics_process(_delta: float) -> void:
	_local_tick += 1
	for i in range(_spinners.size()):
		var w: float = float(SPINNER_W[i])
		var pivot: Vector3 = _spinner_centers[i]
		var angle: float = w * float(_local_tick)
		_spinners[i].global_transform = Transform3D(Basis(Vector3.FORWARD, angle), pivot)

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

# ─── Spinning paddle bars (kinematic, deterministic) ─────────────────────

func _build_spinners() -> void:
	var bar_mat := StandardMaterial3D.new()
	bar_mat.albedo_color = Color(0.95, 0.40, 0.85)
	bar_mat.metallic = 0.6
	bar_mat.roughness = 0.30
	bar_mat.emission_enabled = true
	bar_mat.emission = Color(1.0, 0.55, 0.95)
	bar_mat.emission_energy_multiplier = 0.55

	# Two bars per zone, four bars total; centers chosen so adjacent bars
	# can't all align at once (alternating X offsets).
	var configs := [
		{"y": SPINNER_ZONE1_Y, "x": -SPINNER_X_OFFSET},
		{"y": SPINNER_ZONE1_Y, "x":  SPINNER_X_OFFSET},
		{"y": SPINNER_ZONE2_Y, "x": -SPINNER_X_OFFSET},
		{"y": SPINNER_ZONE2_Y, "x":  SPINNER_X_OFFSET},
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

func environment_overrides() -> Dictionary:
	# Arcade mood pulled out of fog + sun; sky stays the daylight cloud
	# default. Pinker sun against magenta fog reads as "loud arcade"
	# without fighting the sky shader the way a fully magenta sky did.
	return {
		"ambient_energy": 0.75,
		"fog_color": Color(0.95, 0.55, 0.80),
		"fog_density": 0.005,
		"sun_color": Color(1.0, 0.78, 0.95),
		"sun_energy": 1.3,
	}
