extends Node3D

# Live-playback scene. Polls the replayd /live endpoint for active rounds,
# subscribes to the newest one over WebSocket, and renders frame-by-frame as
# TICK messages arrive. Archive sibling: web_main.gd.
#
# CLI override: `++ --api-base=http://host:port` lets desktop builds point at
# a remote replayd. On Web we read window.location.origin the same way
# web_main does.

const DESKTOP_DEFAULT_API_BASE := "http://127.0.0.1:8087"
const LIVE_POLL_INTERVAL_SEC := 0.5
const LIVE_POLL_TIMEOUT_SEC := 30.0

var _api_base: String = _default_api_base()

static func _default_api_base() -> String:
	if OS.has_feature("web"):
		var win := JavaScriptBridge.get_interface("window")
		if win != null:
			return String(win.location.origin)
		return ""
	return DESKTOP_DEFAULT_API_BASE

var _list_req: HTTPRequest
var _player: PlaybackPlayer
var _client: LiveStreamClient
var _poll_deadline_ms: int = 0

func _ready() -> void:
	# Environment is deferred until the WS HEADER tells us which track is
	# running — each track picks its own sky/fog/ambient.
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--api-base="):
			_api_base = a.substr("--api-base=".length())

	_list_req = HTTPRequest.new()
	add_child(_list_req)
	_list_req.request_completed.connect(_on_list_response)

	_player = PlaybackPlayer.new()
	add_child(_player)
	_player.playback_finished.connect(_on_playback_finished)

	_poll_deadline_ms = Time.get_ticks_msec() + int(LIVE_POLL_TIMEOUT_SEC * 1000.0)
	print("LIVE_CLIENT: polling %s/live for active rounds" % _api_base)
	_request_live_list()

func _request_live_list() -> void:
	var err := _list_req.request(_api_base + "/live")
	if err != OK:
		push_error("live list request failed to start: %d" % err)
		get_tree().quit(1)

func _on_list_response(result: int, code: int, _headers: PackedStringArray, body: PackedByteArray) -> void:
	if result != HTTPRequest.RESULT_SUCCESS or code != 200:
		push_error("live list fetch failed: result=%d code=%d" % [result, code])
		get_tree().quit(1)
		return
	var parsed = JSON.parse_string(body.get_string_from_utf8())
	if typeof(parsed) != TYPE_DICTIONARY or not parsed.has("round_ids"):
		push_error("live list response malformed: %s" % body.get_string_from_utf8())
		get_tree().quit(1)
		return
	var ids: Array = parsed["round_ids"]
	if ids.is_empty():
		if Time.get_ticks_msec() > _poll_deadline_ms:
			push_error("no active rounds after %d s" % int(LIVE_POLL_TIMEOUT_SEC))
			get_tree().quit(1)
			return
		# Retry after a short delay; HTTPRequest is single-shot so we reuse it.
		await get_tree().create_timer(LIVE_POLL_INTERVAL_SEC).timeout
		_request_live_list()
		return
	# Round IDs are unix-nanos as strings (JSON-number precision-safe). "Newest"
	# = numerically largest. Compare as ints; 19-digit unix-nanos fit in
	# Godot's int (int64).
	var newest := String(ids[0])
	for id in ids:
		if int(id) > int(newest):
			newest = String(id)
	print("LIVE_CLIENT: %d active, subscribing to newest=%s" % [ids.size(), newest])
	_subscribe(newest)

func _subscribe(round_id: String) -> void:
	var ws_base := _api_base
	if ws_base.begins_with("https://"):
		ws_base = "wss://" + ws_base.substr("https://".length())
	elif ws_base.begins_with("http://"):
		ws_base = "ws://" + ws_base.substr("http://".length())
	var url := "%s/live/%s" % [ws_base, round_id]

	_client = LiveStreamClient.new()
	add_child(_client)
	_client.header_received.connect(_on_header)
	_client.tick_received.connect(_on_tick)
	_client.done_received.connect(_on_done)
	_client.connection_failed.connect(_on_ws_failed)
	_client.closed.connect(_on_ws_closed)
	print("LIVE_CLIENT: opening %s" % url)
	var err := _client.connect_to_url(url)
	if err != OK:
		push_error("ws connect failed: %d" % err)
		get_tree().quit(1)

func _on_header(header: Dictionary) -> void:
	var marbles: int = (header["header"] as Array).size()
	var track_id := int(header.get("track_id", TrackRegistry.RAMP))
	var track := TrackRegistry.instance(track_id)
	track.configure(int(header["round_id"]), header["server_seed"] as PackedByteArray)
	add_child(track)
	_build_environment(track)
	var cam := FreeCamera.new()
	cam.track = track
	add_child(cam)
	print("LIVE_CLIENT: HEADER round=%d marbles=%d tick_rate=%d track=%s" % [int(header["round_id"]), marbles, int(header["tick_rate_hz"]), TrackRegistry.name_of(track_id)])
	_player.begin_stream(header)

var _tick_count: int = 0

func _on_tick(_frame: Dictionary) -> void:
	_player.append_frame(_frame)
	_tick_count += 1
	# Log sparingly — ticks arrive at 60Hz and the full buffer dump would spam
	# the CI log, but a heartbeat lets a human see the stream is flowing.
	if _tick_count == 1 or _tick_count % 60 == 0:
		print("LIVE_CLIENT: TICK count=%d latest=%d" % [_tick_count, int(_frame["tick"])])

func _on_done() -> void:
	print("LIVE_CLIENT: DONE after %d ticks" % _tick_count)
	_player.end_stream()

func _on_ws_failed(reason: String) -> void:
	push_error("live ws failed: %s" % reason)
	get_tree().quit(1)

func _on_ws_closed() -> void:
	# Expected after DONE. If DONE was lost (e.g. server closed before the
	# client drained its receive buffer), treat close-after-header as implicit
	# end-of-stream so playback still terminates cleanly. No-op if end_stream
	# was already called from _on_done.
	print("LIVE_CLIENT: socket closed (ticks=%d)" % _tick_count)
	_player.end_stream()

func _on_playback_finished(last_tick: int, first_marble_pos: Vector3) -> void:
	print("LIVE_CLIENT: playback done tick=%d first_marble_pos=%s" % [last_tick, first_marble_pos])
	await get_tree().create_timer(3.0).timeout
	get_tree().quit(0)

func _build_environment(track: Track) -> void:
	var overrides: Dictionary = track.environment_overrides()
	add_child(EnvironmentBuilder.build_sun(overrides))
	add_child(EnvironmentBuilder.build_environment(overrides))
