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
const PLAY_FIELD_WIDTH := 20.0       # X span (peg field + slot row)
const PLAY_FIELD_HEIGHT := 24.0      # Y span (top of peg field to bottom of slots)

const FIELD_TOP_Y := 22.0
const FIELD_BOTTOM_Y := 4.0          # bottom of pegs (slots below this)

# ─── Hopper (above the peg field) ────────────────────────────────────────
const HOPPER_Y := 24.0
const HOPPER_INNER_W := 2.0
const HOPPER_THROAT_W := 1.0
const HOPPER_HEIGHT := 1.6

# Spawn 24 points inside the hopper.
const SPAWN_Y := 25.5
const SPAWN_COLS := 8
const SPAWN_ROWS := 3
const SPAWN_DX := 0.20
const SPAWN_DZ := 0.20

# ─── Peg forest ──────────────────────────────────────────────────────────
const PEG_RADIUS := 0.20
const PEG_HEIGHT := COURSE_DEPTH       # spans the full play depth so marbles can't slip past
const PEG_ROW_COUNT := 12              # number of rows
const PEG_ROW_SPACING := 1.4           # vertical between rows
const PEG_COL_SPACING := 1.4           # horizontal between pegs in a row
const PEG_BASE_COLS := 11              # pegs in the widest (even-indexed) rows
const PEG_FIELD_TOP_Y_GAP := 1.5       # Y gap from FIELD_TOP_Y to first peg row
const PEG_FRICTION := 0.10
const PEG_BOUNCE := 0.55

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
# Spans the entire slot row at the very bottom — first marble to drop into
# any slot crosses the finish line.
const FINISH_Y := 0.6
const FINISH_BOX_SIZE := Vector3(PLAY_FIELD_WIDTH + 2.0, 0.8, COURSE_DEPTH + 1.0)

# ─── Materials ───────────────────────────────────────────────────────────
const COLOR_FRAME := Color(0.06, 0.06, 0.10)
const COLOR_PEG := Color(0.96, 0.96, 0.96)
const COLOR_SLOT_FLOOR := Color(0.10, 0.05, 0.20)
const COLOR_DIVIDER_GOLD := Color(0.92, 0.78, 0.18)
const COLOR_DIVIDER_RED := Color(0.85, 0.18, 0.16)

var _peg_mat: PhysicsMaterial = null
var _wall_mat: PhysicsMaterial = null
var _slot_mat: PhysicsMaterial = null

func _ready() -> void:
	_init_materials()
	_build_outer_walls()
	_build_hopper()
	_build_peg_forest()
	_build_slot_row()
	_build_mood_light()

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

# ─── Outer frame ─────────────────────────────────────────────────────────

func _build_outer_walls() -> void:
	var frame_mat := StandardMaterial3D.new()
	frame_mat.albedo_color = COLOR_FRAME
	frame_mat.roughness = 0.6

	var frame := StaticBody3D.new()
	frame.name = "Frame"
	frame.physics_material_override = _wall_mat
	add_child(frame)

	var height: float = HOPPER_Y - FINISH_Y + 4.0
	var center_y: float = (HOPPER_Y + FINISH_Y) * 0.5

	# Side walls (along Y, on +/-X)
	for sgn in [-1, 1]:
		var x: float = float(sgn) * (PLAY_FIELD_WIDTH * 0.5 + 0.2)
		_add_box(frame, "WallX_%s" % ("pos" if sgn > 0 else "neg"),
			Transform3D(Basis.IDENTITY, Vector3(x, center_y, 0)),
			Vector3(0.4, height, COURSE_DEPTH + 0.6),
			frame_mat)

	# Front + back panels (along X, on +/-Z) — keep marbles in the plane.
	for sgn in [-1, 1]:
		var z: float = float(sgn) * (COURSE_DEPTH * 0.5 + 0.2)
		_add_box(frame, "WallZ_%s" % ("pos" if sgn > 0 else "neg"),
			Transform3D(Basis.IDENTITY, Vector3(0, center_y, z)),
			Vector3(PLAY_FIELD_WIDTH + 0.4, height, 0.4),
			frame_mat)

	# Back wall colour: a dark "felt" backdrop (mostly visual).
	# (The Z-walls cover this; nothing more needed here.)

# ─── Hopper (funnels marbles into the peg field) ─────────────────────────

func _build_hopper() -> void:
	var frame_mat := StandardMaterial3D.new()
	frame_mat.albedo_color = COLOR_FRAME

	var hopper := StaticBody3D.new()
	hopper.name = "Hopper"
	hopper.physics_material_override = _wall_mat
	add_child(hopper)

	# Two angled walls forming the funnel: outer top width = HOPPER_INNER_W,
	# bottom (throat) = HOPPER_THROAT_W. We approximate each as one tilted box.
	var top_y: float = HOPPER_Y + HOPPER_HEIGHT * 0.5
	var bot_y: float = HOPPER_Y - HOPPER_HEIGHT * 0.5
	for sgn in [-1, 1]:
		var top_x: float = float(sgn) * HOPPER_INNER_W * 0.5
		var bot_x: float = float(sgn) * HOPPER_THROAT_W * 0.5
		var top_pt := Vector3(top_x, top_y, 0)
		var bot_pt := Vector3(bot_x, bot_y, 0)
		var center := (top_pt + bot_pt) * 0.5
		var direction := bot_pt - top_pt
		var length := direction.length()
		var forward := direction.normalized()
		var right := Vector3.FORWARD.cross(forward).normalized()
		if right.length() < 0.001:
			right = Vector3.RIGHT
		var up := forward.cross(right).normalized()
		var basis := Basis(right, up, -forward)
		_add_box(hopper, "HopperWall_%s" % ("pos" if sgn > 0 else "neg"),
			Transform3D(basis, center),
			Vector3(0.18, COURSE_DEPTH, length),
			frame_mat)

# ─── Peg forest ──────────────────────────────────────────────────────────

func _build_peg_forest() -> void:
	var peg_mat := StandardMaterial3D.new()
	peg_mat.albedo_color = COLOR_PEG
	peg_mat.metallic = 0.4
	peg_mat.roughness = 0.4

	var pegs := StaticBody3D.new()
	pegs.name = "Pegs"
	pegs.physics_material_override = _peg_mat
	add_child(pegs)

	var first_row_y: float = FIELD_TOP_Y - PEG_FIELD_TOP_Y_GAP
	for r in range(PEG_ROW_COUNT):
		var y: float = first_row_y - float(r) * PEG_ROW_SPACING
		# Stagger: even rows have PEG_BASE_COLS, odd rows have one fewer
		# offset by half a column.
		var cols: int = PEG_BASE_COLS if (r % 2 == 0) else PEG_BASE_COLS - 1
		var x_offset: float = 0.0 if (r % 2 == 0) else PEG_COL_SPACING * 0.5
		var x_origin: float = -float(cols - 1) * 0.5 * PEG_COL_SPACING + x_offset
		for c in range(cols):
			var x: float = x_origin + float(c) * PEG_COL_SPACING
			# Cylinder lying along world Z (so its long axis spans the play
			# depth); its CollisionShape3D is rotated 90° around X.
			var coll := CollisionShape3D.new()
			coll.name = "Peg_%d_%d_shape" % [r, c]
			var cs := CylinderShape3D.new()
			cs.radius = PEG_RADIUS
			cs.height = PEG_HEIGHT
			coll.shape = cs
			coll.transform = Transform3D(Basis(Vector3.RIGHT, deg_to_rad(90.0)), Vector3(x, y, 0))
			pegs.add_child(coll)

			var mesh := MeshInstance3D.new()
			mesh.name = "Peg_%d_%d_mesh" % [r, c]
			var cm := CylinderMesh.new()
			cm.top_radius = PEG_RADIUS
			cm.bottom_radius = PEG_RADIUS
			cm.height = PEG_HEIGHT
			mesh.mesh = cm
			mesh.material_override = peg_mat
			mesh.transform = Transform3D(Basis(Vector3.RIGHT, deg_to_rad(90.0)), Vector3(x, y, 0))
			pegs.add_child(mesh)

# ─── Slot row ────────────────────────────────────────────────────────────

func _build_slot_row() -> void:
	var floor_mat := StandardMaterial3D.new()
	floor_mat.albedo_color = COLOR_SLOT_FLOOR
	var div_gold := StandardMaterial3D.new()
	div_gold.albedo_color = COLOR_DIVIDER_GOLD
	div_gold.metallic = 0.7
	var div_red := StandardMaterial3D.new()
	div_red.albedo_color = COLOR_DIVIDER_RED

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
	# Y max includes the SpawnRail drop-order stagger above SPAWN_Y.
	var min_v := Vector3(-PLAY_FIELD_WIDTH * 0.5 - 2.0, FINISH_Y - 2.0, -COURSE_DEPTH * 0.5 - 1.0)
	var max_v := Vector3(PLAY_FIELD_WIDTH * 0.5 + 2.0, SPAWN_Y + 5.0, COURSE_DEPTH * 0.5 + 1.0)
	return AABB(min_v, max_v - min_v)
