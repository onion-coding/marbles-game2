class_name SlotsTrack
extends Track

# M6.4 — Slots. Marbles drop down a vertical chute through three spinning reels
# that periodically gate the path, ricochet inside a chrome funnel, then exit
# through a coin tray to the finish.
#
# Determinism story: reels are kinematic AnimatableBody3Ds rotating on fixed
# axes at constant angular velocity. Each reel's initial phase is seeded from
# (server_seed, round_id, reel index) so each round has a unique gate
# alignment, but every replay of the same round renders the same motion.
#
# The course is built around world +Y running from spawn (top) to finish
# (bottom). Marbles fall under gravity, deflected by reel slots, side walls,
# and a chrome funnel.

# ─── Layout ────────────────────────────────────────────────────────────────
const COURSE_TOP_Y := 50.0       # taller cabinet — 7 reels stacked over 50 m of drop
const COURSE_BOTTOM_Y := 0.0
const COURSE_WIDTH_X := 12.0
const COURSE_DEPTH_Z := 8.0
const CABINET_WALL_THICKNESS := 0.4
const CABINET_FRICTION := 0.45    # stickier cabinet so marbles bouncing off side
                                   # walls don't accelerate downward
const CABINET_BOUNCE := 0.30

# ─── Spawn ────────────────────────────────────────────────────────────────
const SPAWN_Y := COURSE_TOP_Y - 1.0
const SPAWN_COLS := 6
const SPAWN_ROWS := 4
const SPAWN_DX := 0.9
const SPAWN_DZ := 0.7

# ─── Reels ────────────────────────────────────────────────────────────────
# Three horizontal cylinders rotating around world X. Each reel has a slot
# cut through its middle (modeled as an arc of "blockers" — short box arcs
# spanning ~270° of the cylinder, leaving a 90° gap that marbles can slip
# through).
const REEL_COUNT := 8                # more reels stacked through the taller cabinet
const REEL_RADIUS := 2.4             # bigger discs catch and carry marbles longer
const REEL_LENGTH := 11.0
const REEL_BLOCKER_THICKNESS := 0.45
const REEL_BLOCKER_HEIGHT := 1.00    # taller teeth deflect marbles more aggressively
const REEL_BLOCKER_COUNT := 10       # 10 segments → gap is 36° wide; gate aligns less often
const REEL_GATE_INDEX := 0
const REEL_FRICTION := 0.50
const REEL_BOUNCE := 0.30
# Y positions of the eight reels descending through the cabinet, spaced
# ~5 m apart so each reel has a clear chance to interact with marbles
# before the next one.
const REEL_YS := [44.0, 39.0, 34.0, 29.0, 24.0, 19.0, 14.0, 9.0]
# Angular velocities (rad/tick at 60Hz). Slower than v1 — at 0.015 rad/tick
# = 0.9 rad/s, gate aligns once every ~7 s, so marbles often have to wait
# multiple cycles before slipping through.
const REEL_W := [0.015, -0.013, 0.017, -0.014, 0.016, -0.015, 0.013, -0.017]

# ─── Funnel (after the bottom reel) ──────────────────────────────────────
const FUNNEL_TOP_Y := 6.0
const FUNNEL_BOTTOM_Y := 1.5
const FUNNEL_TOP_RADIUS := 5.5
const FUNNEL_BOTTOM_RADIUS := 1.0    # tighter throat — marbles bottleneck a bit
const FUNNEL_SEGMENTS := 12
const FUNNEL_FRICTION := 0.45
const FUNNEL_BOUNCE := 0.25

# ─── Tray (finish) ───────────────────────────────────────────────────────
const TRAY_Y := -0.5
const TRAY_RADIUS := 6.0
const TRAY_DEPTH := 0.8
const FINISH_BOX_SIZE := Vector3(COURSE_WIDTH_X + 4.0, 1.5, COURSE_DEPTH_Z + 4.0)

# ─── Materials ───────────────────────────────────────────────────────────
const COLOR_CHROME := Color(0.78, 0.78, 0.85)
const COLOR_REEL_BODY := Color(0.92, 0.92, 0.96)
const COLOR_REEL_FACE_RED := Color(0.95, 0.2, 0.18)
const COLOR_REEL_FACE_GOLD := Color(0.92, 0.78, 0.18)
const COLOR_REEL_FACE_BLUE := Color(0.18, 0.42, 0.95)
const COLOR_TRAY := Color(0.85, 0.65, 0.18)

# ─── Internal state ──────────────────────────────────────────────────────
var _cabinet_mat: PhysicsMaterial = null
var _reel_mat: PhysicsMaterial = null
var _funnel_mat: PhysicsMaterial = null
var _tray_mat: PhysicsMaterial = null

var _reels: Array[AnimatableBody3D] = []
var _reel_phases: Array = []     # initial angle per reel (radians), from seed
var _local_tick: int = -1

func _ready() -> void:
	_init_materials()
	_build_cabinet()
	_init_reel_phases()
	_build_reels()
	_build_funnel()
	_build_tray()
	_build_mood_light()

func _build_mood_light() -> void:
	# Cool electric-blue mood — chrome cabinet vibe.
	var light := OmniLight3D.new()
	light.name = "MoodLight"
	light.light_color = Color(0.78, 0.88, 1.0)
	light.light_energy = 1.8
	light.omni_range = 40.0
	light.position = Vector3(0, 14, 0)
	add_child(light)
	# Secondary fill from below to read the tray.
	var fill := OmniLight3D.new()
	fill.name = "FillLight"
	fill.light_color = Color(1.0, 0.7, 0.3)
	fill.light_energy = 0.8
	fill.omni_range = 20.0
	fill.position = Vector3(0, TRAY_Y + 1.5, 4.0)
	add_child(fill)

func _physics_process(_delta: float) -> void:
	_local_tick += 1
	for i in range(_reels.size()):
		_apply_reel_pose(i, float(_local_tick))

# ─── Materials ───────────────────────────────────────────────────────────

func _init_materials() -> void:
	_cabinet_mat = PhysicsMaterial.new()
	_cabinet_mat.friction = CABINET_FRICTION
	_cabinet_mat.bounce = CABINET_BOUNCE

	_reel_mat = PhysicsMaterial.new()
	_reel_mat.friction = REEL_FRICTION
	_reel_mat.bounce = REEL_BOUNCE

	_funnel_mat = PhysicsMaterial.new()
	_funnel_mat.friction = FUNNEL_FRICTION
	_funnel_mat.bounce = FUNNEL_BOUNCE

	_tray_mat = PhysicsMaterial.new()
	_tray_mat.friction = 0.55
	_tray_mat.bounce = 0.15

# ─── Cabinet (side walls + back) ─────────────────────────────────────────

func _build_cabinet() -> void:
	var chrome_mat := StandardMaterial3D.new()
	chrome_mat.albedo_color = COLOR_CHROME
	chrome_mat.metallic = 1.0
	chrome_mat.metallic_specular = 1.0
	chrome_mat.roughness = 0.10

	var cabinet := StaticBody3D.new()
	cabinet.name = "Cabinet"
	cabinet.physics_material_override = _cabinet_mat
	add_child(cabinet)

	var height: float = COURSE_TOP_Y - COURSE_BOTTOM_Y + 2.0
	var center_y: float = (COURSE_TOP_Y + COURSE_BOTTOM_Y) * 0.5

	# +X wall and -X wall (along the cabinet's length)
	for sgn in [-1, 1]:
		var x: float = float(sgn) * (COURSE_WIDTH_X * 0.5 + CABINET_WALL_THICKNESS * 0.5)
		_add_box(cabinet, "WallX_%s" % ("pos" if sgn > 0 else "neg"),
			Transform3D(Basis.IDENTITY, Vector3(x, center_y, 0)),
			Vector3(CABINET_WALL_THICKNESS, height, COURSE_DEPTH_Z),
			chrome_mat)

	# Back wall (-Z)
	_add_box(cabinet, "WallBack",
		Transform3D(Basis.IDENTITY, Vector3(0, center_y, -COURSE_DEPTH_Z * 0.5 - CABINET_WALL_THICKNESS * 0.5)),
		Vector3(COURSE_WIDTH_X + CABINET_WALL_THICKNESS * 2.0, height, CABINET_WALL_THICKNESS),
		chrome_mat)

	# Front glass (+Z) — just visual + collision so marbles don't escape forward.
	_add_box(cabinet, "WallFront",
		Transform3D(Basis.IDENTITY, Vector3(0, center_y, COURSE_DEPTH_Z * 0.5 + CABINET_WALL_THICKNESS * 0.5)),
		Vector3(COURSE_WIDTH_X + CABINET_WALL_THICKNESS * 2.0, height, CABINET_WALL_THICKNESS),
		chrome_mat)

# ─── Reels ───────────────────────────────────────────────────────────────

func _init_reel_phases() -> void:
	# Per-reel initial phase in [0, TAU). Shifted so the gates are spread
	# out across the cabinet rather than starting aligned — looks more
	# kinetic and gives marbles different chances at each level.
	for i in range(REEL_COUNT):
		var raw := _hash_with_tag("reel_%d" % i)
		_reel_phases.append(float(raw[0]) / 255.0 * TAU)

func _build_reels() -> void:
	# A reel is an AnimatableBody3D whose spin axis is world X. We model the
	# blocker geometry as REEL_BLOCKER_COUNT - 1 box "teeth" arrayed around
	# the cylinder (the missing one is the gap that marbles can pass through).
	# Each tooth's local position is at (cos θ * R, sin θ * R) in YZ, with the
	# teeth extending radially outward.
	var face_mats := [
		_solid_mat(COLOR_REEL_FACE_RED),
		_solid_mat(COLOR_REEL_FACE_GOLD),
		_solid_mat(COLOR_REEL_FACE_BLUE),
	]

	for i in range(REEL_COUNT):
		var reel := AnimatableBody3D.new()
		reel.name = "Reel_%d" % i
		reel.physics_material_override = _reel_mat
		reel.sync_to_physics = true
		var y: float = REEL_YS[i]
		# The reel's local frame: +X along world X (axis of rotation). We place
		# it at world (0, y, 0) with the rotation applied around X.
		reel.global_transform = Transform3D(Basis.IDENTITY, Vector3(0, y, 0))
		add_child(reel)

		# Build tooth boxes. Each tooth is a flat slab whose long axis lies
		# along the cylinder axis (world X) and whose Y dimension is the
		# radial-out direction at angle θ. With θ measured around world X
		# from world +Y, radial-out = (0, cos θ, sin θ); the basis that
		# rotates the canonical Y axis into that direction is
		# Basis(Vector3.RIGHT, θ).
		var face_mat: StandardMaterial3D = face_mats[i % face_mats.size()]
		var arc_step: float = TAU / float(REEL_BLOCKER_COUNT)
		for k in range(REEL_BLOCKER_COUNT):
			if k == REEL_GATE_INDEX:
				continue   # gap that lets marbles pass through
			var angle: float = arc_step * float(k)
			var radial := Vector3(0, cos(angle), sin(angle))
			var tooth_center := radial * (REEL_RADIUS + REEL_BLOCKER_HEIGHT * 0.5)
			var rot_basis := Basis(Vector3.RIGHT, angle)
			_add_box(reel, "Tooth_%d_%d" % [i, k],
				Transform3D(rot_basis, tooth_center),
				Vector3(REEL_LENGTH, REEL_BLOCKER_HEIGHT, REEL_BLOCKER_THICKNESS),
				face_mat)

		_reels.append(reel)
		_apply_reel_pose(i, 0.0)

func _apply_reel_pose(i: int, t: float) -> void:
	var w: float = float(REEL_W[i])
	var phase: float = float(_reel_phases[i])
	var angle: float = phase + w * t
	# Spin around world X.
	var basis := Basis(Vector3.RIGHT, angle)
	var pos := Vector3(0, REEL_YS[i], 0)
	_reels[i].global_transform = Transform3D(basis, pos)

# ─── Funnel (chrome cone after the reels) ────────────────────────────────

func _build_funnel() -> void:
	var chrome_mat := _solid_mat(COLOR_CHROME)
	chrome_mat.metallic = 0.85
	chrome_mat.roughness = 0.2

	var funnel := StaticBody3D.new()
	funnel.name = "Funnel"
	funnel.physics_material_override = _funnel_mat
	add_child(funnel)

	# Build the funnel as a ring of N tilted boxes between top and bottom radii.
	var height: float = FUNNEL_TOP_Y - FUNNEL_BOTTOM_Y
	var arc: float = TAU / float(FUNNEL_SEGMENTS)
	for k in range(FUNNEL_SEGMENTS):
		var angle: float = float(k) * arc
		var dir_top := Vector3(cos(angle), 0, sin(angle))
		var dir_bottom := dir_top   # same azimuth
		var top_pt := Vector3(FUNNEL_TOP_RADIUS * dir_top.x, FUNNEL_TOP_Y, FUNNEL_TOP_RADIUS * dir_top.z)
		var bottom_pt := Vector3(FUNNEL_BOTTOM_RADIUS * dir_bottom.x, FUNNEL_BOTTOM_Y, FUNNEL_BOTTOM_RADIUS * dir_bottom.z)
		var center := (top_pt + bottom_pt) * 0.5
		var direction := (bottom_pt - top_pt)
		var length := direction.length()
		var forward := direction.normalized()
		var right := Vector3.UP.cross(forward).normalized()
		if right.length() < 0.001:
			right = Vector3.RIGHT
		var up := forward.cross(right).normalized()
		var basis := Basis(right, up, -forward)
		# Each panel: width arc * mid_radius, length, thin.
		var mid_radius: float = (FUNNEL_TOP_RADIUS + FUNNEL_BOTTOM_RADIUS) * 0.5
		var panel_w: float = arc * mid_radius * 1.05   # slight overlap
		_add_box(funnel, "FunnelPanel_%d" % k,
			Transform3D(basis, center),
			Vector3(panel_w, 0.18, length),
			chrome_mat)

# ─── Tray (finish basin) ─────────────────────────────────────────────────

func _build_tray() -> void:
	var tray_mat := _solid_mat(COLOR_TRAY)
	tray_mat.metallic = 0.7
	tray_mat.roughness = 0.3

	var tray := StaticBody3D.new()
	tray.name = "Tray"
	tray.physics_material_override = _tray_mat
	add_child(tray)

	# Floor disc.
	var floor_coll := CollisionShape3D.new()
	var floor_cyl := CylinderShape3D.new()
	floor_cyl.radius = TRAY_RADIUS
	floor_cyl.height = 0.3
	floor_coll.shape = floor_cyl
	floor_coll.transform = Transform3D(Basis.IDENTITY, Vector3(0, TRAY_Y - 0.15, 0))
	tray.add_child(floor_coll)

	var floor_mesh := MeshInstance3D.new()
	var floor_cm := CylinderMesh.new()
	floor_cm.top_radius = TRAY_RADIUS
	floor_cm.bottom_radius = TRAY_RADIUS
	floor_cm.height = 0.3
	floor_mesh.mesh = floor_cm
	floor_mesh.transform = Transform3D(Basis.IDENTITY, Vector3(0, TRAY_Y - 0.15, 0))
	floor_mesh.material_override = tray_mat
	tray.add_child(floor_mesh)

	# Rim ring (8 box segments).
	var ring_segs := 12
	var arc: float = TAU / float(ring_segs)
	for k in range(ring_segs):
		var angle: float = float(k) * arc
		var dir := Vector3(cos(angle), 0, sin(angle))
		var pos := dir * TRAY_RADIUS + Vector3(0, TRAY_Y + TRAY_DEPTH * 0.5, 0)
		var basis := Basis(Vector3.UP, -angle)
		_add_box(tray, "TrayRim_%d" % k,
			Transform3D(basis, pos),
			Vector3(arc * TRAY_RADIUS * 1.05, TRAY_DEPTH, 0.25),
			tray_mat)

# ─── Helpers ─────────────────────────────────────────────────────────────

func _solid_mat(c: Color) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = c
	# Default to a slight emission tint of the same color so reel teeth pop
	# in the bloom pass — chrome cabinet vibe needs the vivid reels to read.
	m.emission_enabled = true
	m.emission = c
	m.emission_energy_multiplier = 0.30
	m.metallic_specular = 0.6
	m.roughness = 0.4
	return m

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
	var points: Array = []
	for r in range(SPAWN_ROWS):
		for c in range(SPAWN_COLS):
			var fx: float = float(c) - float(SPAWN_COLS - 1) * 0.5
			var fz: float = float(r) - float(SPAWN_ROWS - 1) * 0.5
			points.append(Vector3(fx * SPAWN_DX, SPAWN_Y, fz * SPAWN_DZ))
	return points

func finish_area_transform() -> Transform3D:
	# Centered at the tray, axis-aligned.
	return Transform3D(Basis.IDENTITY, Vector3(0, TRAY_Y + FINISH_BOX_SIZE.y * 0.5, 0))

func finish_area_size() -> Vector3:
	return FINISH_BOX_SIZE

func camera_bounds() -> AABB:
	# Y max includes the SpawnRail drop-order stagger above SPAWN_Y so the
	# 24-marble column isn't clipped at race start.
	var min_v := Vector3(-COURSE_WIDTH_X * 0.5 - 4.0, TRAY_Y - 2.0, -COURSE_DEPTH_Z * 0.5 - 2.0)
	var max_v := Vector3(COURSE_WIDTH_X * 0.5 + 4.0, COURSE_TOP_Y + 5.0, COURSE_DEPTH_Z * 0.5 + 2.0)
	return AABB(min_v, max_v - min_v)

func environment_overrides() -> Dictionary:
	# Cool chrome mood from the fog + sun; sky stays the daylight default.
	return {
		"ambient_energy": 0.80,
		"fog_color": Color(0.70, 0.82, 0.95),
		"fog_density": 0.003,
		"sun_color": Color(0.85, 0.94, 1.0),
		"sun_energy": 1.4,
	}
