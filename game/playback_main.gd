extends Node3D

func _ready() -> void:
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
	track.configure(int(replay["round_id"]), replay["server_seed"] as PackedByteArray)
	add_child(track)
	_build_environment(track)
	var cam := FixedCamera.new()
	cam.track = track
	add_child(cam)
	print("PLAYBACK: loaded %s (%d frames, %d marbles, track=%s)" % [path, (replay["frames"] as Array).size(), (replay["header"] as Array).size(), TrackRegistry.name_of(track_id)])

	var player := PlaybackPlayer.new()
	add_child(player)
	player.set_track(track)
	player.playback_finished.connect(_on_playback_finished)

	var hud := HUD.new()
	add_child(hud)
	hud.setup(replay["header"])
	hud.set_track_name(TrackRegistry.name_of(track_id))

	var audio := AudioController.new()
	add_child(audio)
	audio.start_ambient(track_id, track.audio_overrides())

	# Capture locals for the closure (GDScript closures capture by reference but
	# local vars go out of scope at end of _ready — store what we need).
	var finish_pos_capture := track.finish_area_transform().origin
	player.tick_advanced.connect(func(t: int) -> void:
		hud.update_tick(t, 60.0)
		if t % 6 == 0:
			hud.update_standings(player.get_marbles(), finish_pos_capture)
	)
	player.winner_revealed.connect(func(_idx: int, name: String, color: Color) -> void:
		hud.reveal_winner(name, color)
		audio.play_winner_jingle()
	)

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

func _build_environment(track: Track) -> void:
	var overrides: Dictionary = track.environment_overrides()
	add_child(EnvironmentBuilder.build_sun(overrides))
	add_child(EnvironmentBuilder.build_environment(overrides))
