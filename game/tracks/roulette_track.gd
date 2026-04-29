class_name RouletteTrack
extends Track

# Roulette v3.5 — simpler skeleton chosen 2026-04-25 after the multi-section
# v3 chain failed to flow (sections didn't align with each other).
#
# This version is: spawn cluster → one long descending helical channel
# (closed floor + tall outer wall + tall inner wall) → short exit ramp →
# finish rack. Chip-stack pegs scattered along the helix floor add
# marble-run-style deflection and variance.
#
# The helix is deliberately closed-channel (no airborne sections) so
# marbles physically cannot leave the course mid-run. This is the
# Marbles-on-Stream "tube piece" pattern, simplified.
#
# Theming (still roulette): a big decorative wheel sits in the middle of
# the helix as visual centerpiece (no collision); chip-stack pegs decorate
# the floor; finish rack is a dealer's chip rack at the bottom.

# ─── Spiral helix (the main course) ───────────────────────────────────────
# Helix axis is world +Y. Marbles travel around the +Y axis at constant
# radius from it, descending as they go.
const HELIX_AXIS_X := 0.0
const HELIX_AXIS_Z := 0.0
const HELIX_RADIUS := 8.0
const HELIX_TOP_Y := 25.0
const HELIX_BOTTOM_Y := 5.0
const HELIX_TURNS := 2.0
const HELIX_SEGMENTS := 40                 # smoothness vs shape count
const HELIX_START_ANGLE := 0.0             # entry at +X direction (angle 0)
const HELIX_FLOOR_WIDTH := 2.4
const HELIX_FLOOR_THICKNESS := 0.2
const HELIX_OUTER_WALL_HEIGHT := 1.6
const HELIX_INNER_WALL_HEIGHT := 1.0
const HELIX_WALL_THICKNESS := 0.2
const HELIX_FRICTION := 0.55               # firm grip — slows marbles enough to control time
const HELIX_BOUNCE := 0.20

# ─── Spawn ────────────────────────────────────────────────────────────────
const SPAWN_CENTER := Vector3(8.0, 28.0, 0.0)  # directly above helix entry at angle 0
const SPAWN_SPREAD_X := 1.5                    # cross-track spread
const SPAWN_SPREAD_Z := 1.5

# ─── Exit chute (helix → finish) ─────────────────────────────────────────
# Helix exits at angle (start + 2 turns) = 0 + 4π = 0 (mod 2π), tangent
# pointing roughly +Z. The exit chute is a straight ramp from the helix's
# bottom-tangent direction to the finish rack.
const EXIT_LEN := 4.0
const EXIT_DROP := 1.0

# ─── Finish ──────────────────────────────────────────────────────────────
const FINISH_CENTER := Vector3(8.0, 4.0, 5.0)  # +Z from helix bottom (8,5,0)
const FINISH_BOX_SIZE := Vector3(8.0, 2.5, 0.6)  # spans full helix width along X, thin along Z

# ─── Chip-stack obstacles on the helix floor ─────────────────────────────
# Placed at fractional t along the helix; offset is cross-track.
# Eight stacks evenly distributed along the descent.
const CHIP_T_STEPS := [0.10, 0.20, 0.30, 0.40, 0.50, 0.60, 0.72, 0.85]
const CHIP_OFFSETS := [-0.4, 0.5, -0.5, 0.4, -0.3, 0.5, -0.5, 0.3]
const CHIP_RADIUS := 0.5
const CHIP_HEIGHT := 1.0

# ─── Décor wheel (no collision, visual centerpiece) ──────────────────────
const WHEEL_DECOR_CENTER := Vector3(0.0, 14.0, 0.0)
const WHEEL_DECOR_RADIUS := 5.0
const WHEEL_DECOR_HEIGHT := 1.2
const WHEEL_DECOR_ANGULAR_VEL := 0.4

# ─── Materials ───────────────────────────────────────────────────────────
const COLOR_MAHOGANY := Color(0.22, 0.08, 0.05)
const COLOR_BRASS := Color(0.85, 0.75, 0.25)
const COLOR_FELT := Color(0.04, 0.35, 0.12)
const COLOR_VELVET := Color(0.1, 0.05, 0.2)

var _wheel_decor: Node3D = null
var _wheel_decor_angle: float = 0.0

var _mat_felt: PhysicsMaterial = null
var _mat_wood: PhysicsMaterial = null

func _ready() -> void:
	_init_materials()
	_build_helix()
	_build_chip_stacks()
	_build_exit_chute()
	_build_finish_rack()
	_build_wheel_decor()

func _physics_process(delta: float) -> void:
	if _wheel_decor != null:
		_wheel_decor_angle += WHEEL_DECOR_ANGULAR_VEL * delta
		_wheel_decor.basis = Basis(Vector3.UP, _wheel_decor_angle)

# ─── Materials ────────────────────────────────────────────────────────────

func _init_materials() -> void:
	_mat_felt = PhysicsMaterial.new()
	_mat_felt.friction = HELIX_FRICTION
	_mat_felt.bounce = HELIX_BOUNCE

	_mat_wood = PhysicsMaterial.new()
	_mat_wood.friction = 0.4
	_mat_wood.bounce = 0.2

# ─── Helix sample math ────────────────────────────────────────────────────

func _helix_pos(t: float) -> Vector3:
	var angle: float = HELIX_START_ANGLE + HELIX_TURNS * TAU * t
	var y: float = HELIX_TOP_Y + (HELIX_BOTTOM_Y - HELIX_TOP_Y) * t
	return Vector3(HELIX_AXIS_X + cos(angle) * HELIX_RADIUS, y, HELIX_AXIS_Z + sin(angle) * HELIX_RADIUS)

func _helix_tangent(t: float) -> Vector3:
	var angle: float = HELIX_START_ANGLE + HELIX_TURNS * TAU * t
	var d_angle_dt: float = HELIX_TURNS * TAU
	var dy_dt: float = HELIX_BOTTOM_Y - HELIX_TOP_Y
	return Vector3(-sin(angle) * HELIX_RADIUS * d_angle_dt, dy_dt, cos(angle) * HELIX_RADIUS * d_angle_dt).normalized()

func _helix_frame(t: float) -> Dictionary:
	# Returns a stable per-segment basis: forward = tangent, right = world-Y × tangent
	# (radial-outward, horizontal), up = forward × right (perpendicular to floor,
	# tilted back by the descent slope).
	var pos := _helix_pos(t)
	var forward := _helix_tangent(t)
	var right := Vector3.UP.cross(forward).normalized()
	var up := forward.cross(right).normalized()
	# Sanity: if up.y < 0 something flipped — flip back.
	if up.y < 0.0:
		up = -up
		right = -right
	return {"pos": pos, "forward": forward, "right": right, "up": up}

# ─── Build: helix tube (floor + outer wall + inner wall) ─────────────────

func _build_helix() -> void:
	var helix := StaticBody3D.new()
	helix.name = "Helix"
	helix.physics_material_override = _mat_felt
	add_child(helix)

	var felt_mat := StandardMaterial3D.new()
	felt_mat.albedo_color = COLOR_FELT
	var wood_mat := StandardMaterial3D.new()
	wood_mat.albedo_color = COLOR_MAHOGANY
	var brass_mat := StandardMaterial3D.new()
	brass_mat.albedo_color = COLOR_BRASS
	brass_mat.metallic = 0.85
	brass_mat.metallic_specular = 0.85
	brass_mat.roughness = 0.30
	brass_mat.emission_enabled = true
	brass_mat.emission = COLOR_BRASS
	brass_mat.emission_energy_multiplier = 0.20

	# Per-segment length: sum of tangent magnitude × dt approximated as
	# arc-length over the segment count, with a 1.2× overlap so adjacent
	# segments share their seam.
	var seg_dt := 1.0 / float(HELIX_SEGMENTS)
	var arc_len := HELIX_RADIUS * HELIX_TURNS * TAU / float(HELIX_SEGMENTS)
	# True 3D segment length (account for descent).
	var hyp_len := sqrt(arc_len * arc_len + pow((HELIX_TOP_Y - HELIX_BOTTOM_Y) / float(HELIX_SEGMENTS), 2))
	var seg_len := hyp_len * 1.20

	for i in range(HELIX_SEGMENTS):
		var t: float = (float(i) + 0.5) * seg_dt
		var frame := _helix_frame(t)
		var pos: Vector3 = frame["pos"]
		var right: Vector3 = frame["right"]
		var up: Vector3 = frame["up"]
		var forward: Vector3 = frame["forward"]
		var basis := Basis(right, up, -forward)

		# Floor: a wide thin slab. Top surface passes through the helix sample.
		var floor_pos := pos - up * (HELIX_FLOOR_THICKNESS * 0.5)
		_add_box_child(helix, "HelixFloor_%02d" % i,
			Transform3D(basis, floor_pos),
			Vector3(HELIX_FLOOR_WIDTH, HELIX_FLOOR_THICKNESS, seg_len),
			felt_mat)

		# Outer wall (away from spiral center): tall, full height
		var outer_pos := pos + right * (HELIX_FLOOR_WIDTH * 0.5 + HELIX_WALL_THICKNESS * 0.5) + up * (HELIX_OUTER_WALL_HEIGHT * 0.5)
		_add_box_child(helix, "HelixOuter_%02d" % i,
			Transform3D(basis, outer_pos),
			Vector3(HELIX_WALL_THICKNESS, HELIX_OUTER_WALL_HEIGHT, seg_len),
			brass_mat)

		# Inner wall (toward spiral center): shorter, but still a wall
		var inner_pos := pos - right * (HELIX_FLOOR_WIDTH * 0.5 + HELIX_WALL_THICKNESS * 0.5) + up * (HELIX_INNER_WALL_HEIGHT * 0.5)
		_add_box_child(helix, "HelixInner_%02d" % i,
			Transform3D(basis, inner_pos),
			Vector3(HELIX_WALL_THICKNESS, HELIX_INNER_WALL_HEIGHT, seg_len),
			wood_mat)

# ─── Build: chip-stack obstacles ──────────────────────────────────────────

func _build_chip_stacks() -> void:
	var brass_mat := StandardMaterial3D.new()
	brass_mat.albedo_color = COLOR_BRASS
	brass_mat.metallic = 0.7
	for i in range(CHIP_T_STEPS.size()):
		var t: float = CHIP_T_STEPS[i]
		var off: float = CHIP_OFFSETS[i]
		var frame := _helix_frame(t)
		var pos: Vector3 = frame["pos"]
		var right: Vector3 = frame["right"]
		# Center the stack on the helix floor with a small cross-track offset.
		var stack_base := pos + right * off
		var stack := StaticBody3D.new()
		stack.name = "ChipStack_%d" % i
		stack.transform = Transform3D(Basis.IDENTITY, stack_base + Vector3(0, CHIP_HEIGHT * 0.5, 0))
		stack.physics_material_override = _mat_wood
		add_child(stack)

		var coll := CollisionShape3D.new()
		var cyl_shape := CylinderShape3D.new()
		cyl_shape.radius = CHIP_RADIUS
		cyl_shape.height = CHIP_HEIGHT
		coll.shape = cyl_shape
		stack.add_child(coll)

		var mesh_inst := MeshInstance3D.new()
		var cyl := CylinderMesh.new()
		cyl.top_radius = CHIP_RADIUS
		cyl.bottom_radius = CHIP_RADIUS
		cyl.height = CHIP_HEIGHT
		mesh_inst.mesh = cyl
		mesh_inst.material_override = brass_mat
		stack.add_child(mesh_inst)

# ─── Build: exit chute (helix bottom → finish rack) ──────────────────────

func _build_exit_chute() -> void:
	# Helix exits at t=1: angle = 0 + 2*TAU = 0 (mod 2π). Position (8, 5, 0).
	# Tangent at exit: (-sin(0)*r*d_angle, dy_dt, cos(0)*r*d_angle)
	# = (0, -20, +100.5) normalized = (0, -0.196, +0.981). Mostly +Z.
	#
	# So the exit chute extends in +Z direction from the helix's bottom.
	# It's a small ramp from helix bottom (8, 5, 0) down to finish (8, 4, 5).
	var exit := StaticBody3D.new()
	exit.name = "ExitChute"
	exit.physics_material_override = _mat_wood
	add_child(exit)

	var wood_mat := StandardMaterial3D.new()
	wood_mat.albedo_color = COLOR_MAHOGANY
	var brass_mat := StandardMaterial3D.new()
	brass_mat.albedo_color = COLOR_BRASS

	var helix_exit := _helix_pos(1.0)
	var exit_end := Vector3(helix_exit.x, helix_exit.y - EXIT_DROP, helix_exit.z + EXIT_LEN)
	var center := (helix_exit + exit_end) * 0.5
	var direction := (exit_end - helix_exit)
	var length := direction.length()
	var forward := direction.normalized()
	var right := Vector3.UP.cross(forward).normalized()
	var up := forward.cross(right).normalized()
	var basis := Basis(right, up, -forward)

	# Floor
	_add_box_child(exit, "ExitFloor",
		Transform3D(basis, center - up * 0.1),
		Vector3(HELIX_FLOOR_WIDTH, 0.2, length),
		wood_mat)
	# Side walls
	_add_box_child(exit, "ExitWallLeft",
		Transform3D(basis, center - right * (HELIX_FLOOR_WIDTH * 0.5) + up * 0.6),
		Vector3(0.2, 1.2, length),
		brass_mat)
	_add_box_child(exit, "ExitWallRight",
		Transform3D(basis, center + right * (HELIX_FLOOR_WIDTH * 0.5) + up * 0.6),
		Vector3(0.2, 1.2, length),
		brass_mat)

# ─── Build: finish rack ───────────────────────────────────────────────────

func _build_finish_rack() -> void:
	var rack := StaticBody3D.new()
	rack.name = "DealerRack"
	rack.transform = Transform3D(Basis.IDENTITY, FINISH_CENTER + Vector3(0.0, 0.5, 0.6))
	rack.physics_material_override = _mat_wood
	add_child(rack)

	var wood_mat := StandardMaterial3D.new()
	wood_mat.albedo_color = COLOR_MAHOGANY
	var velvet_mat := StandardMaterial3D.new()
	velvet_mat.albedo_color = COLOR_VELVET

	# Back wall (catches marbles after the FinishLine)
	_add_box_child(rack, "RackBack", Transform3D(Basis.IDENTITY, Vector3(0, 0.6, 0.6)), Vector3(8.0, 2.0, 0.2), wood_mat)
	# Floor (velvet basin)
	_add_box_child(rack, "RackFloor", Transform3D(Basis.IDENTITY, Vector3(0, -0.4, 0)), Vector3(8.5, 0.2, 1.5), velvet_mat)
	# Side walls
	_add_box_child(rack, "RackSide_neg", Transform3D(Basis.IDENTITY, Vector3(-4.1, 0.4, 0)), Vector3(0.2, 1.5, 1.5), wood_mat)
	_add_box_child(rack, "RackSide_pos", Transform3D(Basis.IDENTITY, Vector3(4.1, 0.4, 0)), Vector3(0.2, 1.5, 1.5), wood_mat)

# ─── Build: décor wheel (no collision) ───────────────────────────────────

func _build_wheel_decor() -> void:
	_wheel_decor = Node3D.new()
	_wheel_decor.name = "WheelDecor"
	_wheel_decor.transform = Transform3D(Basis.IDENTITY, WHEEL_DECOR_CENTER)
	add_child(_wheel_decor)

	var disc := MeshInstance3D.new()
	var disc_mesh := CylinderMesh.new()
	disc_mesh.top_radius = WHEEL_DECOR_RADIUS
	disc_mesh.bottom_radius = WHEEL_DECOR_RADIUS
	disc_mesh.height = WHEEL_DECOR_HEIGHT
	disc.mesh = disc_mesh
	var disc_mat := StandardMaterial3D.new()
	disc_mat.albedo_color = COLOR_MAHOGANY
	disc.material_override = disc_mat
	_wheel_decor.add_child(disc)

	# Brass turret on top
	var turret := MeshInstance3D.new()
	var turret_mesh := CylinderMesh.new()
	turret_mesh.top_radius = 0.2
	turret_mesh.bottom_radius = 1.0
	turret_mesh.height = 1.4
	turret.mesh = turret_mesh
	turret.transform = Transform3D(Basis.IDENTITY, Vector3(0, WHEEL_DECOR_HEIGHT * 0.5 + 0.7, 0))
	var turret_mat := StandardMaterial3D.new()
	turret_mat.albedo_color = COLOR_BRASS
	turret_mat.metallic = 0.8
	turret.material_override = turret_mat
	_wheel_decor.add_child(turret)

	# 37 pocket dividers around the rim (visual only)
	var divider_mat := StandardMaterial3D.new()
	divider_mat.albedo_color = COLOR_BRASS
	divider_mat.metallic = 0.7
	for i in range(37):
		var angle: float = TAU * float(i) / 37.0
		var mesh := MeshInstance3D.new()
		var box_mesh := BoxMesh.new()
		box_mesh.size = Vector3(WHEEL_DECOR_RADIUS * 0.18, 0.2, 0.08)
		mesh.mesh = box_mesh
		var p_basis := Basis(Vector3.UP, angle)
		var p_radius: float = WHEEL_DECOR_RADIUS * 0.85
		mesh.transform = Transform3D(p_basis, Vector3(cos(angle) * p_radius, WHEEL_DECOR_HEIGHT * 0.5 + 0.1, sin(angle) * p_radius))
		mesh.material_override = divider_mat
		_wheel_decor.add_child(mesh)

# ─── Helpers ──────────────────────────────────────────────────────────────

func _add_box_child(parent: Node, node_name: String, tx: Transform3D, size: Vector3, mat: StandardMaterial3D) -> void:
	var coll := CollisionShape3D.new()
	coll.name = node_name + "_shape"
	coll.transform = tx
	var shape := BoxShape3D.new()
	shape.size = size
	coll.shape = shape
	parent.add_child(coll)

	var mesh_inst := MeshInstance3D.new()
	mesh_inst.name = node_name + "_mesh"
	mesh_inst.transform = tx
	var box := BoxMesh.new()
	box.size = size
	mesh_inst.mesh = box
	mesh_inst.material_override = mat
	parent.add_child(mesh_inst)

# ─── Track API overrides ──────────────────────────────────────────────────

func spawn_points() -> Array:
	# 24 positions in a 3×8 grid above the helix entry. SpawnRail applies
	# a world-Y stagger on top, so marbles drop into the helix's first
	# segment in tightly-clustered formation.
	var points := []
	var rows := 3
	var cols := 8
	for r in range(rows):
		for c in range(cols):
			var fx: float = float(c) / float(cols - 1) - 0.5  # in [-0.5, +0.5]
			var fz: float = float(r) / float(rows - 1) - 0.5  # in [-0.5, +0.5]
			points.append(SPAWN_CENTER + Vector3(fx * SPAWN_SPREAD_X, 0.0, fz * SPAWN_SPREAD_Z))
	return points

func finish_area_transform() -> Transform3D:
	# Centered at FINISH_CENTER, axis-aligned.
	return Transform3D(Basis.IDENTITY, FINISH_CENTER + Vector3(0.0, FINISH_BOX_SIZE.y * 0.5, 0.0))

func finish_area_size() -> Vector3:
	return FINISH_BOX_SIZE

func camera_bounds() -> AABB:
	# Frame the entire helix + spawn area + finish.
	var min_x := -HELIX_RADIUS - 2.0
	var max_x := HELIX_RADIUS + 2.0
	var min_y := FINISH_CENTER.y - 2.0
	var max_y := SPAWN_CENTER.y + 4.0
	var min_z := -HELIX_RADIUS - 2.0
	var max_z := FINISH_CENTER.z + 3.0
	return AABB(Vector3(min_x, min_y, min_z), Vector3(max_x - min_x, max_y - min_y, max_z - min_z))

func camera_pose() -> Dictionary:
	# Frontal view from +Z looking toward the helix axis. The helix spans
	# roughly Y=5–28 (spawn overhead), X from -8 to +8 (radius). A position
	# at Z=35 centred on the mid-height (Y≈16) keeps the entire descent and
	# the decorative wheel visible. FOV 65 avoids perspective distortion
	# while fitting the 16 m wide helix comfortably at this distance.
	var mid_y: float = (SPAWN_CENTER.y + FINISH_CENTER.y) * 0.5
	return {
		"position": Vector3(0.0, mid_y, 35.0),
		"target":   Vector3(0.0, mid_y - 2.0, 0.0),
		"fov":      65.0,
	}

func environment_overrides() -> Dictionary:
	return {}
