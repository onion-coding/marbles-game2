extends Node3D

# Network-sourced playback scene. Works as-is on desktop (a good test harness)
# and as the Web export (M5.1) once Godot's Web templates are installed.
# Fetches the latest round from the replay archive HTTP API (see server/api)
# and renders it via the existing PlaybackPlayer.
#
# CLI override: `++ --api-base=http://host:port` lets the desktop build point
# at a remote replayd. Web builds will read this from a JS-side query param
# in a later iteration.

# Default to same-origin when running in a browser (replayd serves both the
# game bundle and the API). On desktop there's no "origin" so we fall back to
# the dev replayd port. Override with `++ --api-base=http://host:port`.
const DESKTOP_DEFAULT_API_BASE := "http://127.0.0.1:8080"

var _api_base: String = _default_api_base()

static func _default_api_base() -> String:
	if OS.has_feature("web"):
		# Godot's HTTPRequest parses URLs itself and rejects relative paths, so
		# "/rounds" won't work even though browser fetch() would accept it. Pull
		# the current origin from window.location via JavaScriptBridge.
		var win := JavaScriptBridge.get_interface("window")
		if win != null:
			return String(win.location.origin)
		return ""
	return DESKTOP_DEFAULT_API_BASE
var _list_req: HTTPRequest
var _bin_req: HTTPRequest
var _player: PlaybackPlayer

func _ready() -> void:
	_build_environment()
	# Track is instantiated *after* we read the replay header (which carries
	# track_id in v3). Building env-only now keeps the first frame black
	# instead of flashing the wrong track before the fetch completes.

	for a in OS.get_cmdline_user_args():
		if a.begins_with("--api-base="):
			_api_base = a.substr("--api-base=".length())

	_list_req = HTTPRequest.new()
	add_child(_list_req)
	_list_req.request_completed.connect(_on_list_response)

	_bin_req = HTTPRequest.new()
	add_child(_bin_req)
	_bin_req.request_completed.connect(_on_bin_response)

	_player = PlaybackPlayer.new()
	add_child(_player)
	_player.playback_finished.connect(_on_playback_finished)

	print("WEB_CLIENT: fetching round list from %s/rounds" % _api_base)
	var err := _list_req.request(_api_base + "/rounds")
	if err != OK:
		push_error("list request failed to start: %d" % err)
		get_tree().quit(1)

func _on_list_response(result: int, code: int, _headers: PackedStringArray, body: PackedByteArray) -> void:
	if result != HTTPRequest.RESULT_SUCCESS or code != 200:
		push_error("list fetch failed: result=%d code=%d" % [result, code])
		get_tree().quit(1)
		return
	var parsed = JSON.parse_string(body.get_string_from_utf8())
	if typeof(parsed) != TYPE_DICTIONARY or not parsed.has("round_ids"):
		push_error("list response not a {round_ids: [...]} object: %s" % body.get_string_from_utf8())
		get_tree().quit(1)
		return
	var ids: Array = parsed["round_ids"]
	if ids.is_empty():
		push_error("no rounds in archive")
		get_tree().quit(1)
		return
	# API returns IDs as strings to dodge JSON-number precision loss (round IDs
	# are unix-nanos, ~19 digits, don't fit in float64). Leave as strings.
	var latest: String = String(ids[ids.size() - 1])
	print("WEB_CLIENT: latest round=%s, fetching replay" % latest)
	var err := _bin_req.request("%s/rounds/%s/replay.bin" % [_api_base, latest])
	if err != OK:
		push_error("replay request failed to start: %d" % err)
		get_tree().quit(1)

func _on_bin_response(result: int, code: int, _headers: PackedStringArray, body: PackedByteArray) -> void:
	if result != HTTPRequest.RESULT_SUCCESS or code != 200:
		push_error("replay fetch failed: result=%d code=%d" % [result, code])
		get_tree().quit(1)
		return
	var replay := ReplayReader.read_bytes(body)
	if replay.is_empty():
		push_error("replay parse failed (%d bytes)" % body.size())
		get_tree().quit(1)
		return
	var track_id := int(replay.get("track_id", TrackRegistry.RAMP))
	var track := TrackRegistry.instance(track_id)
	add_child(track)
	var cam := FixedCamera.new()
	cam.track = track
	add_child(cam)
	print("WEB_CLIENT: playing %d frames for %d marbles (track=%s)" % [(replay["frames"] as Array).size(), (replay["header"] as Array).size(), TrackRegistry.name_of(track_id)])
	_player.load_replay(replay)

func _on_playback_finished(last_tick: int, first_marble_pos: Vector3) -> void:
	print("WEB_CLIENT: done at tick=%d, first marble pos=%s" % [last_tick, first_marble_pos])
	# Hold the final frame for a bit so a human watcher sees the end of the race
	# rather than the window snapping shut. Headless runs use --quit-after, so
	# this doesn't stall CI.
	await get_tree().create_timer(3.0).timeout
	get_tree().quit(0)

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
