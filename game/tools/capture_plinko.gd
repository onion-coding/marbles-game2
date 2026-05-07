extends Node3D

# Loads PlinkoTrack and saves PNG screenshots from multiple camera angles.
# Used by the asset workflow to inspect track geometry without watching a
# whole race in the editor.
#
# Run via:
#   Godot --path game res://tools/capture_plinko.tscn
# Output goes to user://capture/plinko_<view>.png — ProjectSettings prints
# the absolute path so the harness can read them back.

const VIEWS: Array = [
	{"name": "01_full",         "pos": Vector3( 0.0,  35.0, 165.0), "look": Vector3(0,  35, 0), "fov": 48.0},
	{"name": "02_S1_plinko_top","pos": Vector3( 0.0,  78.0,  55.0), "look": Vector3(0,  78, 0), "fov": 48.0},
	{"name": "03_S2_gears",     "pos": Vector3( 0.0,  52.0,  35.0), "look": Vector3(0,  52, 0), "fov": 38.0},
	{"name": "04_S3_S4_bumper_slots", "pos": Vector3(0.0, 39.0, 30.0), "look": Vector3(0, 39, 0), "fov": 36.0},
	{"name": "05_S5_plinko_bot","pos": Vector3( 0.0,  20.0,  45.0), "look": Vector3(0,  20, 0), "fov": 44.0},
	{"name": "06_S6_cannon",    "pos": Vector3( 0.0,   3.0,  35.0), "look": Vector3(0,   3, 0), "fov": 38.0},
	{"name": "07_S7_ramps",     "pos": Vector3( 0.0, -14.0,  40.0), "look": Vector3(0, -14, 0), "fov": 42.0},
	{"name": "08_finish",       "pos": Vector3( 0.0, -27.0,  25.0), "look": Vector3(0, -27, 0), "fov": 38.0},
]

func _ready() -> void:
	var dir := DirAccess.open("user://")
	if dir != null and not dir.dir_exists("capture"):
		dir.make_dir("capture")

	# Build environment so colours read correctly on the screenshot.
	var world_env := WorldEnvironment.new()
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.10, 0.10, 0.14)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.7, 0.7, 0.8)
	env.ambient_light_energy = 0.6
	world_env.environment = env
	add_child(world_env)

	# Directional sun.
	var sun := DirectionalLight3D.new()
	sun.transform = Transform3D(Basis.IDENTITY, Vector3(0, 100, 50))
	sun.rotate_x(deg_to_rad(-50))
	sun.rotate_y(deg_to_rad(-25))
	sun.light_energy = 1.4
	add_child(sun)

	# Build the track.
	var track := PlinkoTrack.new()
	add_child(track)

	# Camera.
	var cam := Camera3D.new()
	cam.current = true
	add_child(cam)

	# Wait two frames so the track finishes _ready and meshes are visible.
	await get_tree().process_frame
	await get_tree().process_frame

	for v in VIEWS:
		var pos: Vector3 = v["pos"]
		var look: Vector3 = v["look"]
		var fov: float = float(v["fov"])
		cam.global_transform = Transform3D(Basis.IDENTITY, pos)
		cam.look_at(look, Vector3.UP)
		cam.fov = fov
		# Two extra frames for the camera move to settle and render.
		await get_tree().process_frame
		await get_tree().process_frame

		var img: Image = get_viewport().get_texture().get_image()
		var rel: String = "user://capture/plinko_%s.png" % v["name"]
		img.save_png(rel)
		var abs_path: String = ProjectSettings.globalize_path(rel)
		print("CAPTURE: %s" % abs_path)

	get_tree().quit()
