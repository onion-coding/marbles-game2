extends Node3D

const MARBLE_COUNT := 20
# How many seconds the WAITING / bet-placement window is open in RGS mode.
const RGS_BET_WINDOW_SEC := 10.0
# How many seconds to display the winner modal before starting the next round.
const RGS_BETWEEN_ROUNDS_SEC := 15.0

var _status_path: String = ""  # if non-empty, write status JSON on race completion
var _round_id: int = 0
var _server_seed_hash: PackedByteArray = PackedByteArray()
var _replay_path: String = ""

# Interactive-mode HUD + camera. Both are null in spec (headless) mode so all
# HUD/camera code is guarded. The tick counter drives the race timer display.
var _hud: HUD = null
var _freecam: FreeCamera = null
var _live_marbles: Array = []
var _live_finish_pos: Vector3 = Vector3.ZERO
var _live_tick: int = 0
var _live_racing: bool = false

# RGS mode state
var _rgs_client: RgsClient = null
var _pending_spec: Dictionary = {}       # spec dict waiting while bet window is open
var _pending_outcomes: Array = []        # round_bet_outcomes from server, may arrive before or after race ends
var _race_visually_finished: bool = false  # true once FinishLine fires race_finished
var _winner_idx_at_finish: int = -1      # marble index reported by local sim at race_finished

# Nodes created per-round (freed by _cleanup_round between rounds).
# These are populated inside _start_race and cleared by _cleanup_round.
var _live_track: Node = null
var _live_recorder: Node = null
var _live_finish: Node = null
var _live_streamer = null   # TickStreamer (RefCounted) or null; untyped to avoid Node constraint

func _ready() -> void:
	# Three modes (evaluated in this order of priority):
	# (a) Spec mode: a round-spec JSON is passed via CLI (++ --round-spec=<path>). Used
	#     by the Go server (server/sim) to drive deterministic rounds with supplied seeds.
	# (b) RGS mode: --rgs=<base_url> is present but no --round-spec. The client
	#     fetches a server-authoritative spec via POST /v1/rounds/start, opens a
	#     bet-placement window for RGS_BET_WINDOW_SEC seconds, then starts the race.
	# (c) Interactive mode: neither flag → generate a fresh local seed.
	var spec := _load_spec_from_cli()
	if not spec.is_empty():
		# (a) Spec mode — start immediately.
		_start_race(spec)
		return

	var rgs_url := _get_rgs_url()
	if rgs_url.is_empty():
		# (c) Interactive mode — start immediately with local seed.
		_start_race({})
		return

	# (b) RGS mode — create the persistent HTTP client node.
	_rgs_client = RgsClient.new()
	_rgs_client.base_url = rgs_url
	add_child(_rgs_client)
	# player_id is populated by RgsClient._ready() from user://player_id.txt.

	print("RGS: fetching round spec from %s/v1/rounds/start" % rgs_url)
	var http := HTTPRequest.new()
	add_child(http)
	http.request_completed.connect(_on_rgs_spec_received.bind(http))
	var err := http.request(
		rgs_url + "/v1/rounds/start",
		["Content-Type: application/json"],
		HTTPClient.METHOD_POST,
		"{}"
	)
	if err != OK:
		push_error("RGS: HTTPRequest.request() failed (err=%d); falling back to local seed" % err)
		remove_child(http)
		http.queue_free()
		_start_race({})

# Callback for the asynchronous RGS spec fetch (mode b).
func _on_rgs_spec_received(result: int, response_code: int, _headers: PackedStringArray,
		body: PackedByteArray, http: HTTPRequest) -> void:
	remove_child(http)
	http.queue_free()

	if result != HTTPRequest.RESULT_SUCCESS or response_code != 200:
		push_error("RGS: spec fetch failed (result=%d http=%d); falling back to local seed" \
				% [result, response_code])
		_start_race({})
		return

	var text := body.get_string_from_utf8()
	var parsed = JSON.parse_string(text)
	if typeof(parsed) != TYPE_DICTIONARY:
		push_error("RGS: spec response is not a JSON object; falling back to local seed")
		_start_race({})
		return

	var round_id_int: int = int(parsed.get("round_id", 0))
	print("RGS: received spec round_id=%d track_id=%d — opening %d s bet window" \
			% [round_id_int, int(parsed.get("track_id", 0)), int(RGS_BET_WINDOW_SEC)])

	# Expose round_id early so _on_bet_requested can use it during the window.
	_round_id = round_id_int
	# Store the spec so the countdown timer can pass it to _start_race.
	_pending_spec = parsed

	# Build the HUD now so the bet panel is visible during the waiting window.
	# We need enough info to populate the marble selector, so we build a
	# synthetic header from marble count (names become Marble_00…Marble_N).
	var marble_count: int = MARBLE_COUNT
	var client_seeds = parsed.get("client_seeds", [])
	if client_seeds is Array and (client_seeds as Array).size() > 0:
		marble_count = (client_seeds as Array).size()

	# Build a minimal HUD header with placeholder colors.  The real colors
	# come from FairSeed.derive_marble_colors once _start_race() runs, but
	# for the bet-selector we only need names.  Colors will be overwritten
	# by setup() when the race actually launches.
	var hud_header: Array = []
	for i in range(marble_count):
		hud_header.append({"name": "Marble_%02d" % i, "rgba": 0})

	# Reuse the existing HUD on auto-restart (round 2+). _cleanup_round()
	# keeps _hud alive across rounds; building a fresh HUD here would stack
	# overlays and double-connect every RgsClient signal below.
	var hud_is_new: bool = (_hud == null)
	if hud_is_new:
		_hud = HUD.new()
		add_child(_hud)
	_hud.setup(hud_header)

	# setup() puts the HUD into RACING phase; enable_rgs_mode() flips it
	# back to WAITING and reveals the bet panel.
	_hud.enable_rgs_mode(round_id_int)

	# Start the visible countdown inside the bet panel.
	_hud.start_bet_countdown(RGS_BET_WINDOW_SEC)

	# Wire bet signals only on first build — _hud and _rgs_client both
	# survive _cleanup_round, so re-connecting on auto-restart would
	# double-fire every callback.
	if hud_is_new:
		_hud.bet_requested.connect(_on_bet_requested)
		if _rgs_client != null:
			_rgs_client.bet_placed.connect(_on_bet_placed)
			_rgs_client.bet_failed.connect(_on_bet_failed)
			_rgs_client.round_completed.connect(_on_round_completed)
			_rgs_client.round_failed.connect(_on_round_failed)
			# Keep the balance label in sync: refresh once now and after every bet.
			_rgs_client.balance_loaded.connect(_hud.update_balance)

	# Always refresh balance at the start of each round (display gets
	# wiped by _cleanup_round → _hud.reset()).
	if _rgs_client != null:
		_rgs_client.fetch_balance()

	# Start the countdown; _start_race runs at expiry.
	_open_bet_countdown()

# Open a non-blocking countdown before the race starts.
# When the window expires: kick off server-side round settlement (async) AND
# start the local physics sim immediately — they run in parallel.
func _open_bet_countdown() -> void:
	await get_tree().create_timer(RGS_BET_WINDOW_SEC).timeout
	print("RGS: bet window closed — triggering server round + starting local race")
	# Fire server settlement first (non-blocking — result arrives via signal).
	if _rgs_client != null:
		_rgs_client.run_round()
	# Start the visual race immediately regardless; seed-aligned sim produces
	# the same winner.  _on_round_completed / _on_round_failed handle the
	# server response whenever it arrives.
	_start_race(_pending_spec)
	_pending_spec = {}

# Relay bet from HUD to RgsClient.
func _on_bet_requested(marble_idx: int, amount: float) -> void:
	if _rgs_client == null:
		return
	_rgs_client.place_bet(_round_id, marble_idx, amount)

# Relay confirmed bet back to HUD.
func _on_bet_placed(bet: Dictionary) -> void:
	if _hud != null:
		_hud.on_bet_confirmed(bet)
	# Re-fetch balance to stay in sync even if balance_after drifts.
	if _rgs_client != null:
		_rgs_client.fetch_balance()

# Relay bet error to HUD toast.
func _on_bet_failed(error: String) -> void:
	push_warning("RGS: bet failed: %s" % error)
	if _hud != null:
		_hud.show_error_toast("Bet failed: %s" % error)

# Called when POST /v1/rounds/run?wait=true returns successfully.
# `result` shape: {round_id, winner: {marble_index, finish_tick}, round_bet_outcomes: [...]}
# May arrive before or after the local visual race ends — handle both orders.
func _on_round_completed(result: Dictionary) -> void:
	var server_winner_idx: int = -1
	var winner_dict = result.get("winner", {})
	if typeof(winner_dict) == TYPE_DICTIONARY:
		server_winner_idx = int(winner_dict.get("marble_index", -1))

	# Filter outcomes for this player only.
	var all_outcomes = result.get("round_bet_outcomes", [])
	if typeof(all_outcomes) != TYPE_ARRAY:
		all_outcomes = []
	var my_id := _rgs_client.player_id if _rgs_client != null else ""
	var filtered: Array = []
	for o in all_outcomes:
		if typeof(o) == TYPE_DICTIONARY and String(o.get("player_id", "")) == my_id:
			filtered.append(o)

	# Cross-check with local sim winner (seed alignment invariant).
	if _winner_idx_at_finish >= 0 and server_winner_idx >= 0 and \
			server_winner_idx != _winner_idx_at_finish:
		push_error("RGS: server winner (%d) differs from local sim winner (%d) — " \
				% [server_winner_idx, _winner_idx_at_finish] +
				"seed misalignment; showing server result as authoritative")

	# Use server winner index as authoritative; fall back to local if missing.
	var authoritative_winner := server_winner_idx if server_winner_idx >= 0 else _winner_idx_at_finish

	if _race_visually_finished:
		# Race already ended locally — apply settlement now.
		if _hud != null:
			_hud.apply_settlement(filtered, authoritative_winner)
	else:
		# Race still running — store outcomes; _on_race_finished will pick them up.
		_pending_outcomes = filtered
		# Overwrite the local winner with the server's authoritative value so
		# _on_race_finished uses the correct index even if it fires before this.
		if authoritative_winner >= 0:
			_winner_idx_at_finish = authoritative_winner

# Called when POST /v1/rounds/run?wait=true fails (network, server error, etc.).
# The visual race still runs locally; no settlement overlay is shown.
func _on_round_failed(error: String) -> void:
	push_warning("RGS: round settlement failed: %s — player sees the race but no payout overlay" % error)
	_pending_outcomes = []

# Core race setup.  `spec` is a Dictionary that contains the round
# parameters (same schema as the file-based spec used in spec mode).
# Passing an empty Dictionary triggers the local-seed interactive path.
func _start_race(spec: Dictionary) -> void:
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
	_live_track = track
	_build_environment(track)
	var rail := SpawnRail.new(track)

	var server_seed_hash := FairSeed.hash_server_seed(server_seed)
	_round_id = round_id
	_server_seed_hash = server_seed_hash

	print("COMMIT: round_id=%d server_seed_hash=%s" % [round_id, FairSeed.to_hex(server_seed_hash)])

	var slots  := FairSeed.derive_spawn_slots(server_seed, round_id, client_seeds, SpawnRail.SLOT_COUNT)
	var colors := FairSeed.derive_marble_colors(server_seed, round_id, client_seeds)
	var marbles := MarbleSpawner.spawn(self, rail, slots, colors)

	var finish := FinishLine.new()
	finish.track = track
	add_child(finish)
	_live_finish = finish
	finish.race_finished.connect(func(winner: RigidBody3D, _tick: int) -> void:
		var winner_color: Color = colors[int(String(winner.name).trim_prefix("Marble_"))]
		WinnerReveal.spawn_confetti(self, winner.global_position, winner_color)
		WinnerReveal.boost_winner_emission(winner, get_tree())
		# Headless smoke-test convenience: when running with --headless and
		# no display server, auto-quit ~3s after race finishes so batch
		# scripts don't have to rely on --quit-after frame counts. With a
		# display attached (live editor / interactive mode), no quit — the
		# user wants to keep watching the confetti.
		if DisplayServer.get_name() == "headless":
			var quit_timer := get_tree().create_timer(3.0)
			quit_timer.timeout.connect(func() -> void: get_tree().quit())
	)
	var recorder := TickRecorder.new()
	recorder.set_round_context(round_id, server_seed, server_seed_hash, client_seeds, slots, colors, track_id)
	if not _replay_path.is_empty():
		recorder.override_output_path(_replay_path)
	var stream_addr := String(spec.get("live_stream_addr", "")) if not spec.is_empty() else ""
	_live_streamer = null
	if not stream_addr.is_empty():
		var colon := stream_addr.find(":")
		if colon > 0:
			var host := stream_addr.substr(0, colon)
			var port := int(stream_addr.substr(colon + 1))
			var streamer := TickStreamer.new()
			if streamer.connect_to(host, port, round_id):
				recorder.set_streamer(streamer)
				_live_streamer = streamer
				print("STREAM: connected to %s:%d" % [host, port])
			else:
				print("STREAM: connect to %s:%d failed, continuing without live stream" % [host, port])
	recorder.track(marbles, finish)
	add_child(recorder)
	_live_recorder = recorder
	if not _status_path.is_empty():
		recorder.finalized.connect(_on_finalized.bind(finish))

	var is_server_driven := not spec.is_empty() and not _status_path.is_empty()
	if is_server_driven:
		var cam := FixedCamera.new()
		cam.track = track
		add_child(cam)
	else:
		_freecam = FreeCamera.new()
		_freecam.track = track
		add_child(_freecam)

		# Build the full HUD header with real colors.
		var hud_header: Array = []
		for i in range(marbles.size()):
			var c: Color = colors[i]
			var rgba: int = (int(c.r * 255) << 24) | (int(c.g * 255) << 16) | \
					(int(c.b * 255) << 8) | 0xFF
			hud_header.append({"name": "Marble_%02d" % i, "rgba": rgba})

		# In RGS mode the HUD was already created during the bet window.
		# Re-call setup() with real colors; this also transitions to RACING phase.
		if _hud == null:
			_hud = HUD.new()
			add_child(_hud)
		_hud.setup(hud_header)
		_hud.set_track_name(TrackRegistry.name_of(track_id))
		_live_racing = true
		_live_tick = 0
		_live_marbles = marbles
		_live_finish_pos = track.finish_area_transform().origin

		_hud.marble_selected.connect(_freecam.follow_marble_index)
		_freecam.following_changed.connect(_hud.set_following)

		finish.race_finished.connect(func(winner: RigidBody3D, _tick: int) -> void:
			var winner_name: String = String(winner.name)
			var winner_idx: int = int(winner_name.trim_prefix("Marble_"))
			_live_racing = false
			_winner_idx_at_finish = winner_idx
			_race_visually_finished = true
			_hud.reveal_winner(winner_name, colors[winner_idx])
			# In RGS mode: apply settlement overlay if server result already arrived,
			# otherwise _on_round_completed will call apply_settlement when it lands.
			if _rgs_client != null:
				if not _pending_outcomes.is_empty():
					_hud.apply_settlement(_pending_outcomes, _winner_idx_at_finish)
					_pending_outcomes = []
				# If _pending_outcomes is empty it means either:
				# (a) server hasn't responded yet — _on_round_completed will call apply_settlement, or
				# (b) round_failed was emitted — no overlay shown (already push_warning'd).

				# Start the between-rounds countdown and then trigger the next round.
				_hud.start_next_round_countdown(RGS_BETWEEN_ROUNDS_SEC)
				await get_tree().create_timer(RGS_BETWEEN_ROUNDS_SEC).timeout
				_cleanup_round()
				_fetch_rgs_spec()
		)

# Free all per-round nodes and reset per-round state, keeping HUD and RgsClient alive.
# Safe to call even if some nodes were never created (guards against null).
func _cleanup_round() -> void:
	# Free marbles (direct children, tracked in _live_marbles).
	for m in _live_marbles:
		if is_instance_valid(m):
			m.queue_free()
	_live_marbles = []

	# Free named per-round nodes.
	if is_instance_valid(_live_streamer):
		_live_streamer.queue_free()
	_live_streamer = null
	if is_instance_valid(_live_recorder):
		_live_recorder.queue_free()
	_live_recorder = null
	if is_instance_valid(_live_finish):
		_live_finish.queue_free()
	_live_finish = null
	if is_instance_valid(_live_track):
		_live_track.queue_free()
	_live_track = null

	# Free FreeCamera (recreated each round; HUD is kept).
	if is_instance_valid(_freecam):
		_freecam.queue_free()
	_freecam = null

	# Reset per-round state.
	_live_racing = false
	_live_tick = 0
	_live_finish_pos = Vector3.ZERO
	_winner_idx_at_finish = -1
	_race_visually_finished = false
	_pending_outcomes = []

	# Reset the HUD so it shows WAITING for the next round.
	if _hud != null:
		_hud.reset()

# Kick off a fresh RGS spec fetch, identical to the sequence in _ready.
# Called by the auto-restart loop after _cleanup_round().
func _fetch_rgs_spec() -> void:
	var rgs_url := _get_rgs_url()
	if rgs_url.is_empty():
		push_error("RGS auto-restart: could not read --rgs URL; staying on finished screen")
		return

	print("RGS: fetching next round spec from %s/v1/rounds/start" % rgs_url)
	var http := HTTPRequest.new()
	add_child(http)
	http.request_completed.connect(_on_rgs_spec_received.bind(http))
	var err := http.request(
		rgs_url + "/v1/rounds/start",
		["Content-Type: application/json"],
		HTTPClient.METHOD_POST,
		"{}"
	)
	if err != OK:
		push_error("RGS auto-restart: HTTPRequest.request() failed (err=%d); staying on finished screen" % err)
		remove_child(http)
		http.queue_free()
		if _hud != null:
			_hud.show_error_toast("Auto-restart failed: network error. Reload to play again.")

func _physics_process(_delta: float) -> void:
	if _hud == null:
		return
	if _live_racing:
		_live_tick += 1
		_hud.update_tick(_live_tick, float(Engine.physics_ticks_per_second))
		if _live_tick % 6 == 0:
			_hud.update_standings(_live_marbles, _live_finish_pos)

# Return the --rgs=<url> value from the command-line user args, or empty
# string if the flag is absent.
func _get_rgs_url() -> String:
	var args := OS.get_cmdline_user_args()
	for a in args:
		if a.begins_with("--rgs="):
			var url := a.substr("--rgs=".length()).strip_edges()
			if url.ends_with("/"):
				url = url.left(url.length() - 1)
			return url
	return ""

# Pick a track for interactive mode. Honors --track=<name> if present,
# otherwise picks one of the 6 themed tracks at random (ramp legacy excluded).
#
# Accepted names:
#   forest / roulette  → ROULETTE  (id 1, M11 Forest theme)
#   volcano / craps    → CRAPS     (id 2, M11 Volcano theme)
#   ice / poker        → POKER     (id 3, M11 Ice theme)
#   cavern / slots     → SLOTS     (id 4, M11 Cavern theme)
#   sky / plinko       → PLINKO    (id 5, M11 Sky theme)
#   stadium            → STADIUM   (id 6, M11 Stadium theme)
#   ramp               → RAMP      (id 0, legacy — not in random pool)
#
# The "casino" technical aliases (roulette/craps/poker/slots/plinko) point to
# the same map as the M11 theme they replaced — class names + track_ids stayed
# stable across M11 so existing replays still decode through TrackRegistry.
func _pick_interactive_track() -> int:
	var args := OS.get_cmdline_user_args()
	for a in args:
		if a.begins_with("--track="):
			var name := a.substr("--track=".length()).to_lower()
			match name:
				"ramp":                         return TrackRegistry.RAMP
				"forest", "roulette":           return TrackRegistry.ROULETTE
				"volcano", "craps":             return TrackRegistry.CRAPS
				"ice", "poker":                 return TrackRegistry.POKER
				"cavern", "slots":              return TrackRegistry.SLOTS
				"sky", "plinko":                return TrackRegistry.PLINKO
				"stadium":                      return TrackRegistry.STADIUM
				_:
					push_warning("--track=%s not recognized; falling back to random themed track" % name)
					break
	# Random pick — all 6 themed tracks; ramp legacy excluded.
	var themed: Array = [
		TrackRegistry.ROULETTE,
		TrackRegistry.CRAPS,
		TrackRegistry.POKER,
		TrackRegistry.SLOTS,
		TrackRegistry.PLINKO,
		TrackRegistry.STADIUM,
	]
	randomize()
	return int(themed[randi() % themed.size()])

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
