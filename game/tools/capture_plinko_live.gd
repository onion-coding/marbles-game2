extends Node3D

# Spawns 30 marbles into PlinkoTrack and captures a screenshot every 2 seconds
# for 60 s. Lets the agent SEE where balls actually go and where they get
# stuck — instead of guessing.
#
# Run via:
#   Godot --path game res://tools/capture_plinko_live.tscn
# Output: user://capture/plinko_live_t<sec>.png — paths are printed.

const SHOTS = [2, 4, 6, 8, 10, 14, 18, 22, 26, 30, 36, 42, 50, 60]
const CAM_FOV = 48.0
const CAM_DIST = 160.0
const CAM_MID_Y = 35.0

func _ready() -> void:
	var dir := DirAccess.open("user://")
	if dir != null and not dir.dir_exists("capture"):
		dir.make_dir("capture")

	# Environment.
	var world_env := WorldEnvironment.new()
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.10, 0.10, 0.14)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.7, 0.7, 0.8)
	env.ambient_light_energy = 0.6
	world_env.environment = env
	add_child(world_env)

	var sun := DirectionalLight3D.new()
	sun.transform = Transform3D(Basis.IDENTITY, Vector3(0, 100, 50))
	sun.rotate_x(deg_to_rad(-50))
	sun.rotate_y(deg_to_rad(-25))
	sun.light_energy = 1.4
	add_child(sun)

	# Track.
	var track := PlinkoTrack.new()
	add_child(track)

	# Camera.
	var cam := Camera3D.new()
	cam.current = true
	cam.fov = CAM_FOV
	cam.global_transform = Transform3D(Basis.IDENTITY,
		Vector3(0, CAM_MID_Y, CAM_DIST))
	cam.look_at(Vector3(0, CAM_MID_Y, 0), Vector3.UP)
	add_child(cam)

	# Wait for track _ready to finish.
	await get_tree().process_frame
	await get_tree().process_frame

	# Spawn 30 simple test marbles using the track's spawn_points.
	var spawns: Array = track.spawn_points()
	var color_palette: Array = [
		Color.RED, Color.ORANGE, Color.YELLOW, Color.GREEN,
		Color.CYAN, Color.BLUE, Color.MAGENTA, Color.WHITE,
	]
	for i in range(30):
		var p: Vector3 = spawns[i] if i < spawns.size() else Vector3(0, 100, 0)
		# Match SpawnRail's stagger so marbles don't enter the field at
		# tunneling-worthy speeds: 0.5 m clearance + 0.12 m per drop_order.
		p.y += 0.5 + float(i) * 0.12
		var marble := _make_test_marble(i, p, color_palette[i % color_palette.size()])
		add_child(marble)

	# Capture loop. Start a timer that fires at each SHOTS[i] mark.
	var t_start: float = Time.get_ticks_msec() / 1000.0
	var idx: int = 0
	while idx < SHOTS.size():
		var target_t: float = float(SHOTS[idx])
		while (Time.get_ticks_msec() / 1000.0 - t_start) < target_t:
			await get_tree().process_frame
		var img: Image = get_viewport().get_texture().get_image()
		var rel: String = "user://capture/plinko_live_t%02d.png" % SHOTS[idx]
		img.save_png(rel)
		var abs_path: String = ProjectSettings.globalize_path(rel)
		print("LIVE_CAPTURE: t=%ds %s" % [SHOTS[idx], abs_path])
		idx += 1

	get_tree().quit()

func _make_test_marble(idx: int, pos: Vector3, color: Color) -> RigidBody3D:
	var rb := RigidBody3D.new()
	rb.name = "Marble_%02d" % idx
	rb.mass = 1.0
	rb.continuous_cd = true
	rb.position = pos

	var coll := CollisionShape3D.new()
	var sph := SphereShape3D.new()
	sph.radius = 0.3
	coll.shape = sph
	rb.add_child(coll)

	var mesh_inst := MeshInstance3D.new()
	var sphere := SphereMesh.new()
	sphere.radius = 0.3
	sphere.height = 0.6
	mesh_inst.mesh = sphere
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	mat.emission_enabled = true
	mat.emission = color
	mat.emission_energy_multiplier = 0.5
	mesh_inst.material_override = mat
	rb.add_child(mesh_inst)

	var pmat := PhysicsMaterial.new()
	pmat.friction = 0.3
	pmat.bounce = 0.4
	rb.physics_material_override = pmat
	return rb
