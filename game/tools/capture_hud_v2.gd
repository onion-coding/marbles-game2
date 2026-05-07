extends Node3D

# Boots HUD v2 in IDLE state and takes screenshots at fixed timestamps so
# I can verify the new layout without depending on a live race. Captures:
#   t=1s   IDLE state (timer almost full, bet card fresh)
#   t=4s   IDLE w/ bet placed
#   t=5s   LIVE state (force-start triggered, position card visible)
#   t=8s   LIVE mid-race
#
# Run via:
#   Godot --path game res://tools/capture_hud_v2.tscn

const SHOTS = [1, 4, 5, 8]
const CAM_FOV = 48.0

func _ready() -> void:
	var dir := DirAccess.open("user://")
	if dir != null and not dir.dir_exists("capture"):
		dir.make_dir("capture")

	# Plain dark background so the HUD pops.
	var world_env := WorldEnvironment.new()
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color8(0x07, 0x08, 0x0c)   # spec BG
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.7, 0.7, 0.8)
	env.ambient_light_energy = 0.6
	world_env.environment = env
	add_child(world_env)

	var cam := Camera3D.new()
	cam.current = true
	cam.fov = CAM_FOV
	cam.position = Vector3(0, 0, 5)
	add_child(cam)

	var hud := HudV2.new()
	add_child(hud)
	hud.set_track_name("PLINKO")
	hud.set_seed("#04471")
	hud.set_field_size(30)
	hud.set_player_marble_idx(0)

	await get_tree().process_frame
	await get_tree().process_frame

	hud.begin_idle(30.0)

	var t_start := Time.get_ticks_msec() / 1000.0
	var idx := 0
	while idx < SHOTS.size():
		var target_t := float(SHOTS[idx])
		while (Time.get_ticks_msec() / 1000.0 - t_start) < target_t:
			await get_tree().process_frame

		# Trigger state changes at the right moments.
		if SHOTS[idx] == 4:
			# Simulate placing a $50 bet. Calls into the public API.
			hud._on_bet_pressed.call(50.0)
		elif SHOTS[idx] == 5:
			# Force-start.
			hud.begin_live(int(Time.get_unix_time_from_system()))
			# Push fake standings.
			var rows: Array = []
			for j in range(6):
				rows.append({
					"idx": j,
					"name": "M%02d" % j,
					"colour": Color.from_hsv(float(j) / 6.0, 0.7, 0.95),
					"gap_sec": float(j) * 0.4,
				})
			hud.update_standings(rows)
			hud.update_player_multiplier(2.0)
			hud.push_event("M03 hit BUMPER")

		var img: Image = get_viewport().get_texture().get_image()
		var rel: String = "user://capture/hud_v2_t%02d.png" % SHOTS[idx]
		img.save_png(rel)
		var abs_path: String = ProjectSettings.globalize_path(rel)
		print("HUD_V2_CAPTURE: t=%ds %s" % [SHOTS[idx], abs_path])
		idx += 1

	get_tree().quit()
