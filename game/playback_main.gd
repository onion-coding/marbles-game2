extends Node3D

func _ready() -> void:
	_build_environment()

	var path := _latest_replay_path()
	if path.is_empty():
		push_error("no replays found in user://replays/")
		return
	var replay := ReplayReader.read(path)
	if replay.is_empty():
		push_error("failed to read replay: %s" % path)
		return
	var track_id := int(replay.get("track_id", TrackRegistry.RAMP))
	var track := TrackRegistry.instance(track_id)
	add_child(track)
	var cam := FixedCamera.new()
	cam.track = track
	add_child(cam)
	print("PLAYBACK: loaded %s (%d frames, %d marbles, track=%s)" % [path, (replay["frames"] as Array).size(), (replay["header"] as Array).size(), TrackRegistry.name_of(track_id)])

	var player := PlaybackPlayer.new()
	add_child(player)
	player.playback_finished.connect(_on_playback_finished)
	player.load_replay(replay)

func _on_playback_finished(last_tick: int, first_marble_pos: Vector3) -> void:
	print("PLAYBACK: done at tick=%d, first marble pos=%s" % [last_tick, first_marble_pos])
	get_tree().quit()

func _latest_replay_path() -> String:
	var dir := DirAccess.open("user://replays/")
	if dir == null:
		return ""
	var best := ""
	var best_mod := 0
	for name in dir.get_files():
		if not name.ends_with(".bin"):
			continue
		var full := "user://replays/%s" % name
		var mod := FileAccess.get_modified_time(full)
		if mod >= best_mod:
			best_mod = mod
			best = full
	return best

func _build_environment() -> void:
	var light := DirectionalLight3D.new()
	light.rotation_degrees = Vector3(-50, -30, 0)
	light.shadow_enabled = true
	add_child(light)

	var env := WorldEnvironment.new()
	var e := Environment.new()
	e.background_mode = Environment.BG_SKY
	var sky := Sky.new()
	sky.sky_material = ProceduralSkyMaterial.new()
	e.sky = sky
	e.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	env.environment = e
	add_child(env)
