extends Node3D

const MARBLE_COUNT := 20

var _status_path: String = ""  # if non-empty, write status JSON on race completion
var _round_id: int = 0
var _server_seed_hash: PackedByteArray = PackedByteArray()
var _replay_path: String = ""

func _ready() -> void:
	# Two modes:
	# (a) Spec mode: a round-spec JSON is passed via CLI (++ --round-spec=<path>). Used
	#     by the Go server (server/sim) to drive deterministic rounds with supplied seeds.
	# (b) Interactive mode: no args → generate a fresh random seed. Used from the editor.
	var spec := _load_spec_from_cli()
	var round_id: int
	var server_seed: PackedByteArray
	var client_seeds: Array
	var client_count: int
	var track_id: int
	if spec.is_empty():
		round_id = int(Time.get_unix_time_from_system())
		server_seed = FairSeed.generate_server_seed()
		client_seeds = []
		client_count = MARBLE_COUNT
		for i in range(client_count):
			client_seeds.append("")  # MVP: no per-player seed mixing yet
		# Interactive mode: prefer the rich casino tracks. RAMP (the dev
		# track) is intentionally sparse — the player who launches the
		# editor expects to see the obstacle-heavy maps. Honor an explicit
		# --track=<name> flag, otherwise pick a random casino track.
		track_id = _pick_interactive_track()
	else:
		round_id = int(spec["round_id"])
		server_seed = FairSeed.from_hex(String(spec["server_seed_hex"]))
		client_seeds = spec["client_seeds"]
		client_count = client_seeds.size()
		_status_path = String(spec.get("status_path", ""))
		_replay_path = String(spec.get("replay_path", ""))
		track_id = int(spec.get("track_id", TrackRegistry.RAMP))

	var track := TrackRegistry.instance(track_id)
	track.configure(round_id, server_seed)
	add_child(track)
	_build_environment(track)
	var rail := SpawnRail.new(track)

	var server_seed_hash := FairSeed.hash_server_seed(server_seed)
	_round_id = round_id
	_server_seed_hash = server_seed_hash

	print("COMMIT: round_id=%d server_seed_hash=%s" % [round_id, FairSeed.to_hex(server_seed_hash)])

	var slots := FairSeed.derive_spawn_slots(server_seed, round_id, client_seeds, SpawnRail.SLOT_COUNT)
	var colors := FairSeed.derive_marble_colors(server_seed, round_id, client_seeds)
	var marbles := MarbleSpawner.spawn(self, rail, slots, colors)

	var finish := FinishLine.new()
	finish.track = track
	add_child(finish)
	# Visual celebration when the first marble crosses — confetti burst at the
	# winner's position, tinted by the winner's color, plus a brief emission
	# boost so viewers can read which marble actually won.
	finish.race_finished.connect(func(winner: RigidBody3D, _tick: int) -> void:
		var winner_color: Color = colors[int(String(winner.name).trim_prefix("Marble_"))]
		WinnerReveal.spawn_confetti(self, winner.global_position, winner_color)
		WinnerReveal.boost_winner_emission(winner, get_tree())
	)
	var recorder := TickRecorder.new()
	recorder.set_round_context(round_id, server_seed, server_seed_hash, client_seeds, slots, colors, track_id)
	if not _replay_path.is_empty():
		recorder.override_output_path(_replay_path)
	# If the spec requested live streaming, try to connect before track(): track()
	# immediately emits the HEADER message when a streamer is set.
	var stream_addr := String(spec.get("live_stream_addr", "")) if not spec.is_empty() else ""
	if not stream_addr.is_empty():
		var colon := stream_addr.find(":")
		if colon > 0:
			var host := stream_addr.substr(0, colon)
			var port := int(stream_addr.substr(colon + 1))
			var streamer := TickStreamer.new()
			if streamer.connect_to(host, port, round_id):
				recorder.set_streamer(streamer)
				print("STREAM: connected to %s:%d" % [host, port])
			else:
				print("STREAM: connect to %s:%d failed, continuing without live stream" % [host, port])
	recorder.track(marbles, finish)
	add_child(recorder)
	if not _status_path.is_empty():
		recorder.finalized.connect(_on_finalized.bind(finish))
	# Interactive (no spec) → FreeCamera so the player can orbit/WASD-fly
	# around the track. Spec mode (server-driven recording) keeps FixedCamera
	# so the captured replay reflects a consistent canonical view.
	if spec.is_empty():
		var freecam := FreeCamera.new()
		freecam.track = track
		add_child(freecam)
	else:
		var cam := FixedCamera.new()
		cam.track = track
		add_child(cam)

# Pick a track for interactive mode. Honors --track=<name> if present,
# otherwise picks one of the 5 casino tracks at random (RAMP excluded —
# it's the bare dev track and not what a player launching the editor
# wants to see). Falls back to PLINKO on a parse miss.
func _pick_interactive_track() -> int:
	var args := OS.get_cmdline_user_args()
	for a in args:
		if a.begins_with("--track="):
			var name := a.substr("--track=".length()).to_lower()
			match name:
				"ramp":     return TrackRegistry.RAMP
				"roulette": return TrackRegistry.ROULETTE
				"craps":    return TrackRegistry.CRAPS
				"poker":    return TrackRegistry.POKER
				"slots":    return TrackRegistry.SLOTS
				"plinko":   return TrackRegistry.PLINKO
				_:
					push_warning("--track=%s not recognized; falling back to random casino track" % name)
					break
	# Random pick from casino tracks (skip index 0 = RAMP).
	var casino: Array = [
		TrackRegistry.ROULETTE,
		TrackRegistry.CRAPS,
		TrackRegistry.POKER,
		TrackRegistry.SLOTS,
		TrackRegistry.PLINKO,
	]
	randomize()
	return int(casino[randi() % casino.size()])

# Parse "--key=value" pairs from the user-args portion of the command line.
func _load_spec_from_cli() -> Dictionary:
	var args := OS.get_cmdline_user_args()
	var spec_path := ""
	for a in args:
		if a.begins_with("--round-spec="):
			spec_path = a.substr("--round-spec=".length())
			break
	if spec_path.is_empty():
		return {}
	var f := FileAccess.open(spec_path, FileAccess.READ)
	if f == null:
		push_error("could not open round-spec %s (err=%d)" % [spec_path, FileAccess.get_open_error()])
		return {}
	var text := f.get_as_text()
	f.close()
	var parsed = JSON.parse_string(text)
	if typeof(parsed) != TYPE_DICTIONARY:
		push_error("round-spec %s is not a JSON object" % spec_path)
		return {}
	return parsed

func _on_finalized(_path: String, finish: FinishLine) -> void:
	var winner := finish.get_winner()
	var winner_idx := -1
	var finish_tick := -1
	if winner != null:
		winner_idx = int(String(winner.name).trim_prefix("Marble_"))
		finish_tick = int(finish.get_crossings().get(winner, -1))
	var status := {
		"round_id": _round_id,
		"ok": winner != null,
		"winner_marble_index": winner_idx,
		"finish_tick": finish_tick,
		"replay_path": _replay_path,
		"server_seed_hash_hex": FairSeed.to_hex(_server_seed_hash),
		"tick_rate_hz": TickRecorder.TICK_RATE_HZ,
	}
	var f := FileAccess.open(_status_path, FileAccess.WRITE)
	if f == null:
		push_error("could not write status %s (err=%d)" % [_status_path, FileAccess.get_open_error()])
	else:
		f.store_string(JSON.stringify(status))
		f.close()
	get_tree().quit(0)

func _build_environment(track: Track) -> void:
	var overrides: Dictionary = track.environment_overrides()
	add_child(EnvironmentBuilder.build_sun(overrides))
	add_child(EnvironmentBuilder.build_environment(overrides))
