extends Node3D

const MARBLE_COUNT_DEFAULT := 30
# TEMP --marbles=N override (revert before commit). Lets the demo run with
# a lighter marble count to isolate the slide-geometry review from the
# 30-marble physics-tick spike. Resolved in _ready().
var MARBLE_COUNT: int = MARBLE_COUNT_DEFAULT
# How many seconds the WAITING / bet-placement window is open in RGS mode.
const RGS_BET_WINDOW_SEC := 10.0
# How many seconds to display the winner modal before starting the next round.
const RGS_BETWEEN_ROUNDS_SEC := 15.0
# How many seconds the live finishers panel (top-right) shows BEFORE the
# full leaderboard modal appears. Hold the leaderboard back so spectators
# can watch the rest of the field cross the line. Per user spec.
const POST_FINISH_SETTLE_SEC := 15.0

# Interactive (HUD v2) round timings.
const INTERACTIVE_ROUND_SECONDS  := 30.0   # IDLE / bet window before each race
# Legacy HUD's start_finish_settle holds the winner modal for
# POST_FINISH_SETTLE_SEC (15 s); the v2 RESOLVE banner needs to outlast it
# so cleanup_round() doesn't free the marbles before the modal renders.
const INTERACTIVE_RESOLVE_HOLD   := POST_FINISH_SETTLE_SEC + 5.0
# Approximate gap-seconds-per-metre conversion for the position card. Plinko
# marbles average ~5 m/s descent — close enough for a player-visible gap
# readout. Server-authoritative gameplay would replace this with the real
# per-marble crossing-tick deltas.
const V2_GAP_SEC_PER_M := 0.18

# Payout table when a player has bet on this round (HudV2 picks marble 0 as
# "your marble" for now). Values mirror docs/plinko-spec.md §Payout rules.
const V2_PAYOUT_1ST := 9.0
const V2_PAYOUT_2ND := 4.5
const V2_PAYOUT_3RD := 3.0
const V2_PLAYER_MARBLE_IDX := 0

var _status_path: String = ""  # if non-empty, write status JSON on race completion
var _round_id: int = 0
var _server_seed_hash: PackedByteArray = PackedByteArray()
var _replay_path: String = ""

# Interactive-mode HUD + camera. Both are null in spec (headless) mode so all
# HUD/camera code is guarded. The tick counter drives the race timer display.
var _hud: HUD = null
var _hud_v2: HudV2 = null    # new spec-based HUD; populated only in interactive mode
var _freecam: FreeCamera = null
var _director: BroadcastDirector = null  # broadcast director (replaces bare FreeCamera in interactive mode)
var _live_marbles: Array = []
var _live_marble_colors: Array = []
var _live_finish_pos: Vector3 = Vector3.ZERO
var _live_tick: int = 0
var _live_racing: bool = false
var _v2_pending_round_id: int = 0
var _v2_settled: bool = false

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

# Casino broadcast (M29). Active when --casino-video=host:port and
# --casino-meta=host:port are passed on the CLI. Streams raw RGBA frames
# of THIS scene's main viewport to rgsd's TCP listeners; rgsd encodes
# H.264 + fans out via WebRTC. No new game state — re-uses _live_marbles
# and the active Camera3D set by the BroadcastDirector. See
# game/casino/{frame,meta}_streamer.gd.
var _casino_frames: CasinoFrameStreamer = null
var _casino_meta: CasinoMetaStreamer = null
var _casino_minimap_accum: float = 0.0
const CASINO_BROADCAST_W := 854
const CASINO_BROADCAST_H := 480
const CASINO_BROADCAST_FPS := 30.0

# TEMP perf-logging (revert before commit). Prints frame stats every 2s so we
# can quantify the lag the user reported before changing renderer settings.
var _perf_accum: float = 0.0
var _perf_min_fps: float = 999.0
var _perf_shot_count: int = 0
var _perf_shot_dir: String = "C:/tmp/marbles-perf"
var _demo_mode: bool = false   # --demo: HUDs hidden, race starts immediately

func _ready() -> void:
	# Casino broadcast: if --casino-video / --casino-meta were passed,
	# pin the window/viewport size to a known resolution before anything
	# renders. The frame streamer captures from the main viewport, and
	# rgsd was launched with --casino-video-width/-height set to the same
	# numbers — any mismatch produces corrupted encoded frames.
	_maybe_setup_casino_window()

	# Two modes remain (evaluated in priority order):
	#   (a) Spec mode: a round-spec JSON is passed via CLI (++ --round-spec=<path>).
	#       Used by the Go server (server/sim) to drive deterministic rounds
	#       with server-supplied seeds.
	#   (c) Interactive mode: no flag → generate a fresh local seed.
	#
	# Mode (b) — RGS client-physics (--rgs=<base_url>, fetch /v1/rounds/start,
	# run physics locally with the server seed) — was retired with the M29
	# casino architecture. Player-facing rendering is now server-side via the
	# /casino/ WebRTC pipeline; there's no scenario where a desktop or browser
	# client should run physics with a server-supplied seed. The handler
	# functions (_on_rgs_spec_received, _on_bet_*, _on_round_*, _fetch_rgs_spec,
	# RgsClient bindings) stay on disk as orphaned code — the dispatch below
	# is the only thing keeping them in scope, so flipping --rgs back on is a
	# one-line revert if needed.
	var spec := _load_spec_from_cli()
	if not spec.is_empty():
		_start_race(spec)
		return

	if not _get_rgs_url().is_empty():
		push_warning("main.gd: --rgs=<url> ignored; RGS client-physics mode was retired with the M29 casino architecture (player rendering is server-side via /casino/). Falling back to interactive mode.")

	# TEMP --demo flag: skip HUDs + IDLE bet window, run a single race, quit.
	# Used by the curve_demo screenshot capture so the slide isn't covered by
	# HUD panels. Reverts with the rest of the TEMP perf-logging code.
	for a in OS.get_cmdline_user_args():
		if a == "--demo":
			_demo_mode = true
		elif a.begins_with("--marbles="):
			var n := int(a.substr("--marbles=".length()))
			if n > 0 and n <= SpawnRail.SLOT_COUNT:
				MARBLE_COUNT = n
				print("[DEMO] marble count override: %d" % n)
	if _demo_mode:
		print("[DEMO] skipping HUDs and IDLE window; starting race immediately")
		_start_race({})
		return

	_begin_interactive_session()

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

	var slots  := FairSeed.derive_spawn_slots(server_seed, round_id, client_seeds, rail.slot_count())
	var colors := FairSeed.derive_marble_colors(server_seed, round_id, client_seeds)
	var marbles := MarbleSpawner.spawn(self, rail, slots, colors)

	var finish := FinishLine.new()
	finish.track = track
	add_child(finish)
	_live_finish = finish
	# Per-marble finish animation — every marble that crosses gets a confetti
	# burst tinted with its own colour. The race-winner gets the emission
	# boost + the headless auto-quit timer on top.
	# TEMP --demo: skip per-marble confetti so the cascade of 12+ bursts at
	# the finish doesn't strobe. Winner-only burst still fires below.
	if not _demo_mode:
		finish.marble_crossed.connect(func(marble: RigidBody3D, _tick: int) -> void:
			var idx_str := String(marble.name).trim_prefix("Marble_")
			if not idx_str.is_valid_int():
				return
			var idx := int(idx_str)
			if idx < 0 or idx >= colors.size():
				return
			WinnerReveal.spawn_confetti(self, marble.global_position, colors[idx])
		)
	finish.race_finished.connect(func(winner: RigidBody3D, _tick: int) -> void:
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
	# TEMP --demo: skip TickRecorder entirely. With 30 marbles × 60Hz it
	# walks every marble's global_position + quaternion every tick and
	# allocates a Dictionary per state — measurable cost in GDScript that
	# shows up in TIME_PHYSICS_PROCESS. Replays aren't needed for the
	# visual demo.
	if _demo_mode:
		_live_recorder = null
		_live_streamer = null
	else:
		var recorder := TickRecorder.new()
		recorder.set_round_context(round_id, server_seed, server_seed_hash, client_seeds, slots, colors, track_id, rail.slot_count())
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
		# Broadcast director manages all cameras (WIDE / LEADER / FINISH /
		# FREE). FreeCamera lives inside the director and is exposed via
		# director.freecam for the marble-follow signal connection below.
		_director = BroadcastDirector.new()
		add_child(_director)
		_director.setup(track, marbles, track.finish_area_transform().origin)

		# Keep _freecam pointing at the embedded instance so legacy code that
		# checks _freecam (e.g. _cleanup_round) still works.
		_freecam = _director.freecam

		_live_racing = true
		_live_tick = 0
		_live_marbles = marbles
		_live_marble_colors = colors
		_live_finish_pos = track.finish_area_transform().origin

		# Build the full HUD header with real colors. The legacy HUD always
		# runs — it owns the timing tower / podium / finishers list / winner
		# modal / track-name top bar. HUD v2 (if present) is rendered on top
		# of it as an *additional* layer for balance, bet card, round timer,
		# and position card.
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
		_hud.set_track_node(track)
		# TEMP --demo: hide both HUD layers so the curve geometry is unobscured.
		if _demo_mode:
			_hud.visible = false
			if _hud_v2 != null:
				_hud_v2.visible = false
		# Connect marble-follow through the director's embedded freecam.
		if _freecam != null:
			_hud.marble_selected.connect(_freecam.follow_marble_index)
			_freecam.following_changed.connect(_hud.set_following)
		# Wire HUD camera mode requests into the director.
		if _hud.camera_mode_requested.is_connected(_director.set_mode):
			pass  # already connected (RGS multi-round)
		else:
			_hud.camera_mode_requested.connect(_director.set_mode)

		# Start auto-cut scheduling once everything is wired.
		_director.start_directing()
		# TEMP --demo: strip per-marble trail particles + pin camera to
		# FREE mode so the user can fly around and inspect the geometry
		# themselves. Auto-cycling broadcast cuts make it impossible to
		# investigate specific spots ("show me the flying blocks").
		if _demo_mode:
			for m in marbles:
				var t := m.get_node_or_null("Trail")
				if t != null:
					t.queue_free()
			_director.set_mode("free")
			# Anti-aliasing: silhouette aliasing on small fast-moving
			# spheres reads as "flicker" even when there's no actual
			# pixel-content change. FXAA is cheap and kills the worst of
			# it. TAA would be smoother but produces ghost trails on
			# fast-rotating marbles (which is most of them) — pass on it.
			var vp := get_viewport()
			vp.msaa_3d = Viewport.MSAA_4X
			vp.screen_space_aa = Viewport.SCREEN_SPACE_AA_FXAA

		# Casino broadcast streamers, if --casino-video/--casino-meta CLI
		# flags were passed. No-op when not in broadcast mode.
		_maybe_start_casino_streamers()

		# v2 overlay (interactive mode): kick off LIVE phase, hand it the
		# round id + field size + player marble.
		if _hud_v2 != null:
			_hud_v2.set_track_name(TrackRegistry.name_of(track_id))
			_hud_v2.set_field_size(marbles.size())
			_hud_v2.set_player_marble_idx(V2_PLAYER_MARBLE_IDX)
			_hud_v2.begin_live(_v2_pending_round_id)
			_v2_settled = false

		# Per-marble crossing → finisher banner (legacy HUD).
		finish.marble_crossed.connect(func(marble: RigidBody3D, _tick: int) -> void:
			if _hud == null:
				return
			var nm := String(marble.name)
			var trimmed := nm.trim_prefix("Marble_")
			if not trimmed.is_valid_int():
				return
			var idx: int = int(trimmed)
			if idx < 0 or idx >= colors.size():
				return
			_hud.add_finisher(idx, colors[idx], nm)
		)

		finish.race_finished.connect(func(winner: RigidBody3D, _tick: int) -> void:
			var winner_name: String = String(winner.name)
			var winner_idx: int = int(winner_name.trim_prefix("Marble_"))
			_live_racing = false
			_winner_idx_at_finish = winner_idx
			_race_visually_finished = true

			# Freeze the broadcast director on its current camera (normally
			# FINISH_LINE_LOWANGLE at this point).
			if _director != null:
				_director.notify_race_finished()

			# Legacy HUD: 15-s settle window before the winner modal — keeps
			# spectators on the live finishers list while the rest of the
			# field crosses.
			_hud.start_finish_settle(POST_FINISH_SETTLE_SEC,
				winner_name, colors[winner_idx])

			# v2 overlay (interactive mode): settle bet + queue next IDLE
			# round. Runs in parallel with the legacy settle window.
			if _hud_v2 != null and not _v2_settled:
				_v2_settled = true
				_v2_resolve_and_loop(winner_idx)
				return

			# In RGS mode: apply settlement overlay if server result already arrived,
			# otherwise _on_round_completed will call apply_settlement when it lands.
			if _rgs_client != null:
				if not _pending_outcomes.is_empty():
					_hud.apply_settlement(_pending_outcomes, _winner_idx_at_finish)
					_pending_outcomes = []
				# If _pending_outcomes is empty it means either:
				# (a) server hasn't responded yet — _on_round_completed will call apply_settlement, or
				# (b) round_failed was emitted — no overlay shown (already push_warning'd).

				# Wait the settle window first, THEN show the next-round
				# countdown (so the leaderboard sits visible for its full 15s).
				await get_tree().create_timer(POST_FINISH_SETTLE_SEC).timeout
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

	# Casino broadcast streamers — close before freeing the director so
	# the last frame doesn't capture a half-torn-down scene.
	_maybe_close_casino_streamers()

	# Free the broadcast director (owns FreeCamera internally).
	# In spec/server mode _director is null; guard before freeing.
	if is_instance_valid(_director):
		_director.queue_free()
	_director = null
	# _freecam is either null (spec mode) or a child of _director (already freed above).
	# Clear the pointer so callers don't access a stale reference.
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
	# Both HUDs run together in interactive v2 mode — the legacy HUD owns
	# the timing tower / podium / finishers / winner modal, and v2 owns the
	# balance / bet card / round timer / position card overlay.
	if _hud == null and _hud_v2 == null:
		return
	# TEMP perf: skip HUD update walks when neither HUD is visible (--demo).
	# update_standings sorts 30 marbles by distance every 6 ticks; pointless
	# when the result isn't drawn. Caller pays the GDScript loop cost otherwise.
	var hud_visible: bool = (_hud != null and _hud.visible)
	var hud_v2_visible: bool = (_hud_v2 != null and _hud_v2.visible)
	if not hud_visible and not hud_v2_visible:
		return
	var rate := float(Engine.physics_ticks_per_second)
	if _live_racing:
		_live_tick += 1
		if _hud != null:
			_hud.update_tick(_live_tick, rate)
		if _live_tick % 6 == 0:
			if _hud != null:
				_hud.update_standings(_live_marbles, _live_finish_pos)
			if _hud_v2 != null and _live_marbles.size() > 0:
				_hud_v2.update_standings(_compute_v2_standings())
	elif _race_visually_finished and not _live_marbles.is_empty():
		# Race ended but marbles still settling — keep both leaderboards
		# refreshing so finished marbles slot into their final rows. Don't
		# increment _live_tick (timer is frozen at the winner's crossing).
		if Engine.get_physics_frames() % 6 == 0:
			if _hud != null:
				_hud.update_standings(_live_marbles, _live_finish_pos)
			if _hud_v2 != null:
				_hud_v2.update_standings(_compute_v2_standings())

# ─── HUD v2 interactive flow ───────────────────────────────────────────────
#
# State machine: IDLE (HUD timer counting down + bet card unlocked) → LIVE
# (race spawns + bet locked) → RESOLVE (balance flashes win/loss + winner
# label) → IDLE (next round).
#
# The legacy HUD (game/ui/hud.gd) is intentionally bypassed in this path —
# v2 owns balance, betting, multiplier, and standings UI for interactive
# mode. RGS / spec / replay paths still drive the legacy HUD so we don't
# break the existing server flow until those modes are migrated too.

func _begin_interactive_session() -> void:
	# Build HudV2 once and reuse across rounds — the player's balance
	# carries over.
	if _hud_v2 == null:
		_hud_v2 = HudV2.new()
		add_child(_hud_v2)
		_hud_v2.bet_placed.connect(_on_v2_bet_placed)
		_hud_v2.force_start_requested.connect(_on_v2_force_start)
	_v2_settled = false
	_hud_v2.begin_idle(INTERACTIVE_ROUND_SECONDS)

func _on_v2_bet_placed(_amount: float) -> void:
	# HudV2 already tracks `_open_bet_amount` internally; the actual debit
	# happens when begin_live() runs at the IDLE→LIVE transition. Nothing
	# to do here today, but the hook is in place so we can record the bet
	# for replay / server confirmation later.
	pass

func _on_v2_force_start() -> void:
	# Either the round timer hit zero or the player clicked the debug
	# FORCE START button. Generate a fresh round and run it.
	_v2_pending_round_id = int(Time.get_unix_time_from_system())
	_start_race({})

# Resolve the current bet against the finishing podium, hold the RESOLVE
# banner for INTERACTIVE_RESOLVE_HOLD seconds, then clean up and start the
# next IDLE round. Mirrors the RGS auto-restart loop, just driven by HudV2.
func _v2_resolve_and_loop(winner_idx: int) -> void:
	var podium: Array[RigidBody3D] = []
	if _live_finish != null:
		podium = _live_finish.get_podium(3)
	var podium_ids: Array = []
	for m in podium:
		if m == null:
			podium_ids.append(-1)
		else:
			podium_ids.append(int(String(m.name).trim_prefix("Marble_")))
	var payouts: Dictionary = {}
	# Hard-coded position payouts for now (V2_PAYOUT_*). The math model
	# allows for slot multipliers stacking on top — wiring those requires
	# coupling HudV2 to PickupZone, deferred until the server-authoritative
	# split (see docs/architecture.md §Client/server separation).
	if podium_ids.size() > 0 and int(podium_ids[0]) >= 0:
		payouts[int(podium_ids[0])] = V2_PAYOUT_1ST
	if podium_ids.size() > 1 and int(podium_ids[1]) >= 0:
		payouts[int(podium_ids[1])] = V2_PAYOUT_2ND
	if podium_ids.size() > 2 and int(podium_ids[2]) >= 0:
		payouts[int(podium_ids[2])] = V2_PAYOUT_3RD
	_hud_v2.begin_resolve(winner_idx, payouts)
	# Wait for the post-finish settle, then loop back to IDLE.
	await get_tree().create_timer(INTERACTIVE_RESOLVE_HOLD).timeout
	_cleanup_round()
	_begin_interactive_session()

# Compute the per-marble standings rows that HudV2's position card consumes.
# Distance to finish is a workable proxy in 2-D plinko-style tracks; the
# leader is the closest marble; gap_sec is rough (distance / avg-speed).
func _compute_v2_standings() -> Array:
	var raw: Array = []
	for i in range(_live_marbles.size()):
		var m: RigidBody3D = _live_marbles[i]
		if not is_instance_valid(m):
			continue
		raw.append({
			"idx": i,
			"dist": (m.global_position - _live_finish_pos).length(),
		})
	raw.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return float(a["dist"]) < float(b["dist"]))
	var leader_dist: float = float(raw[0]["dist"]) if raw.size() > 0 else 0.0
	var rows: Array = []
	for r in raw:
		var idx: int = int(r["idx"])
		var col: Color = _live_marble_colors[idx] if idx < _live_marble_colors.size() else Color.WHITE
		rows.append({
			"idx": idx,
			"name": "M%02d" % idx,
			"colour": col,
			"gap_sec": (float(r["dist"]) - leader_dist) * V2_GAP_SEC_PER_M,
		})
	return rows

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
				"serpent", "snake":             return TrackRegistry.SERPENT
				"spiral", "spiral_drop":
					push_warning("--track=spiral: SpiralDropTrack is experimental and known to deadlock " +
							"(marbles get stuck mid-helix, race never finishes). Use only for diagnostic.")
					return TrackRegistry.SPIRAL_DROP
				"curve", "curve_demo", "slide": return TrackRegistry.CURVE_DEMO
				_:
					push_warning("--track=%s not recognized; falling back to random themed track" % name)
					break
	# Default interactive: random pick from SELECTABLE (the M11 themed
	# tracks: forest / volcano / ice / cavern / sky / stadium). Spiral
	# Drop was the prior default during Phase 6 design exploration but
	# is currently broken (race times out — marbles deadlock in the
	# inner-curb / split-merge geometry). Removed from default until
	# fixed; still accessible via explicit --track=spiral with a
	# warning, and still in TrackRegistry for old replay decode.
	var pool := TrackRegistry.SELECTABLE
	if pool.is_empty():
		return TrackRegistry.STADIUM   # last-ditch fallback
	randomize()
	return int(pool[randi() % pool.size()])

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
	# Podium top-3 (added in M16, payout v2). Each entry is the marble's
	# drop-order index. -1 = no marble in that podium slot (incomplete race
	# — at most 2 marbles crossed during the recorder's 1s tail). The order
	# is finish-tick ascending (earliest crosser first = 1°). The legacy
	# `winner_marble_index` field is kept untouched for backward compat with
	# the M9 server payout flow; it equals podium_marble_indices[0] when the
	# race completed normally.
	var crossings: Dictionary = finish.get_crossings()
	var podium_indices := [-1, -1, -1]
	var podium_ticks := [-1, -1, -1]
	var podium_marbles: Array = finish.get_podium(3)
	for i in range(podium_marbles.size()):
		if i >= 3:
			break
		var m: RigidBody3D = podium_marbles[i]
		if m == null:
			continue
		podium_indices[i] = int(String(m.name).trim_prefix("Marble_"))
		podium_ticks[i] = int(crossings.get(m, -1))

	# Pickup zones (added in M17, payout v2). Walk every PickupZone under
	# the active track, sort marbles by entry tick across all zones of the
	# same tier, and trim to the math-model caps (4 Tier 1, 1 Tier 2). The
	# server applies the `Tier 2 active` flag at payoff time; we always
	# emit the raw "what physics produced" data so the manifest is stable.
	var tier1_marbles: Array = []
	var tier2_marble: int = -1
	if _live_track != null:
		var aggregated := _aggregate_pickups(_live_track)
		tier1_marbles = aggregated["tier1"] as Array
		tier2_marble = int(aggregated["tier2"])

	var status := {
		"round_id": _round_id,
		"ok": winner != null,
		"winner_marble_index": winner_idx,
		"finish_tick": finish_tick,
		# v4 additions — server constructs RoundOutcome from these:
		"podium_marble_indices": podium_indices,    # [1°, 2°, 3°] drop-order
		"podium_finish_ticks":   podium_ticks,      # tick of each crossing
		"pickup_tier_1_marbles": tier1_marbles,     # up to 4 marble indices
		"pickup_tier_2_marble":  tier2_marble,      # single marble index, or -1
		"protocol_version":      4,
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

# Walk the track tree, find every PickupZone, and aggregate pickups by tier.
# Enforces the math-model caps:
#   - Tier 1 (2×): up to 4 distinct marbles. If more than 4 collected
#     (across all Tier 1 zones combined), keep the 4 earliest by tick.
#   - Tier 2 (3×): exactly 1 marble. If more than 1 collected, keep the
#     earliest by tick.
# Returns {"tier1": Array[int], "tier2": int}.
#
# Since each zone already self-caps (Tier 1 zones cap at 4 each, Tier 2 at 1),
# the aggregator only re-applies the cap when multiple zones are placed
# (a track with 3 Tier 1 zones could otherwise produce 12 Tier 1 marbles).
func _aggregate_pickups(track: Node) -> Dictionary:
	var tier1_collected: Array = []   # array of {idx, tick}
	var tier2_collected: Array = []
	for zone in track.find_children("*", "PickupZone", true, false):
		var pz := zone as PickupZone
		if pz == null:
			continue
		var collected: Dictionary = pz.get_collected()
		var tier: int = pz.tier
		for idx in collected.keys():
			var entry := {"idx": int(idx), "tick": int(collected[idx])}
			if tier == PickupZone.TIER_2:
				tier2_collected.append(entry)
			else:
				tier1_collected.append(entry)

	# Sort by tick, dedup by idx (a marble can enter multiple zones; only
	# the FIRST entry counts toward the cap), trim to caps.
	tier1_collected.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return a["tick"] < b["tick"]
	)
	tier2_collected.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return a["tick"] < b["tick"]
	)

	var tier1_idxs: Array = []
	var seen: Dictionary = {}
	for e in tier1_collected:
		var idx: int = int(e["idx"])
		if seen.has(idx):
			continue
		seen[idx] = true
		tier1_idxs.append(idx)
		if tier1_idxs.size() >= PickupZone.MAX_TIER_1:
			break

	var tier2_idx: int = -1
	for e in tier2_collected:
		var idx: int = int(e["idx"])
		# Tier 2 marble can ALSO be in tier1 list; the server resolves the
		# conflict (Tier 2 takes precedence as MAX). Keep the tier1 list
		# as-is for replay completeness.
		if tier2_idx == -1:
			tier2_idx = idx
			break
	return {"tier1": tier1_idxs, "tier2": tier2_idx}

func _build_environment(track: Track) -> void:
	var overrides: Dictionary = track.environment_overrides()
	add_child(EnvironmentBuilder.build_sun(overrides))
	add_child(EnvironmentBuilder.build_environment(overrides))

# ─── Casino broadcast (M29) ────────────────────────────────────────────────
#
# Hooks into the existing race lifecycle:
#   _maybe_setup_casino_window()    — _ready() head, before any rendering
#   _maybe_start_casino_streamers() — after _director.start_directing()
#   _process()                       — per-frame tick + HUD/minimap metadata
#   _maybe_close_casino_streamers() — _cleanup_round() teardown
#
# All four are no-ops when --casino-video/--casino-meta CLI flags are
# absent. The streamers reuse _live_marbles + the active Camera3D from
# get_viewport().get_camera_3d() — no parallel scene state.

func _process(delta: float) -> void:
	if _casino_frames != null and _casino_frames.is_streaming():
		_casino_frames.tick(delta)
	if _casino_meta != null and _casino_meta.is_streaming() and _live_racing:
		_send_casino_meta(delta)

	# TEMP perf-logging (revert before commit).
	var fps_now: float = Performance.get_monitor(Performance.TIME_FPS)
	if fps_now > 0.0 and fps_now < _perf_min_fps:
		_perf_min_fps = fps_now
	_perf_accum += delta
	if _perf_accum >= 1.0:
		_perf_accum = 0.0
		var process_t: float = Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0
		var physics_t: float = Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0
		var draws: int = int(Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME))
		var prims: int = int(Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME))
		var objs: int = int(Performance.get_monitor(Performance.OBJECT_COUNT))
		var nodes: int = int(Performance.get_monitor(Performance.OBJECT_NODE_COUNT))
		var vp_size := get_viewport().get_visible_rect().size
		print("[PERF] fps=%.1f min=%.1f vp=%dx%d process=%.2fms physics=%.2fms draws=%d prims=%d objs=%d nodes=%d marbles=%d racing=%s"
			% [fps_now, _perf_min_fps, int(vp_size.x), int(vp_size.y),
			   process_t, physics_t, draws, prims, objs, nodes,
			   _live_marbles.size(), str(_live_racing)])
		_perf_min_fps = 999.0
		# TEMP screenshot capture (revert with the rest of TEMP perf code).
		# Once racing, save one PNG every 2s so the user can review without
		# watching the window live.
		# Screenshots disabled: synchronous PNG save blocks the main thread
		# ~150-250ms per shot, causing visible stutter the user could see.
		# Flip the condition to `if true and ...` for verification runs.
		if false and _live_racing and _perf_shot_count < 10:
			# Cycle camera mode between leader-follow (close) and wide so the
			# user gets both close-up and overall framings of the same race.
			if _director != null:
				if _perf_shot_count == 0:
					_director.set_mode("leader")
				elif _perf_shot_count == 4:
					_director.set_mode("wide")
				elif _perf_shot_count == 8:
					_director.set_mode("finish_line")
			var img := get_viewport().get_texture().get_image()
			if img != null:
				DirAccess.make_dir_recursive_absolute(_perf_shot_dir)
				var p := "%s/shot_%02d.png" % [_perf_shot_dir, _perf_shot_count]
				img.save_png(p)
				print("[PERF] screenshot %s" % p)
				_perf_shot_count += 1

func _maybe_setup_casino_window() -> void:
	var addrs := _get_casino_broadcast_addrs()
	if addrs.is_empty():
		return
	var w := get_window()
	w.size = Vector2i(CASINO_BROADCAST_W, CASINO_BROADCAST_H)
	# Borderless eliminates the OS chrome that otherwise inflates the
	# viewport size beyond the window.size we just set.
	w.borderless = true
	w.unresizable = true
	w.title = "Marbles broadcast"

func _maybe_start_casino_streamers() -> void:
	var addrs := _get_casino_broadcast_addrs()
	if addrs.is_empty():
		return
	# Close any prior session (round 2+ on auto-restart re-enters this path).
	_maybe_close_casino_streamers()

	# Strip the render profile to broadcast-server defaults: no SSAO, no
	# glow, no shadows, no MSAA, no TAA, conservative LOD. Done after
	# _build_environment ran so the WorldEnvironment / DirectionalLight
	# nodes already exist and we just override their fields. Cheaper to
	# do this once per round than to refactor EnvironmentBuilder.
	_apply_broadcast_render_profile()

	_casino_frames = CasinoFrameStreamer.new()
	if not _casino_frames.connect_to(
			addrs.video_host, addrs.video_port, get_viewport(), CASINO_BROADCAST_FPS):
		push_error("casino: frame streamer failed to connect to %s:%d"
				% [addrs.video_host, addrs.video_port])
		_casino_frames = null

	_casino_meta = CasinoMetaStreamer.new()
	if not _casino_meta.connect_to(addrs.meta_host, addrs.meta_port):
		push_error("casino: meta streamer failed to connect to %s:%d"
				% [addrs.meta_host, addrs.meta_port])
		_casino_meta = null
	elif _live_marbles.size() > 0:
		# Names are stable for the whole round — push once at start. Use
		# the marble Node's name (set by the round runner upstream) so
		# bettor IDs survive into the browser overlay verbatim.
		var names := {}
		for i in range(_live_marbles.size()):
			var m: Node = _live_marbles[i]
			names[str(i)] = String(m.name) if is_instance_valid(m) else "marble_%02d" % i
		_casino_meta.send_names(names)

func _send_casino_meta(delta: float) -> void:
	# Active camera = whatever the BroadcastDirector currently has set
	# as `current` on its viewport. Fetching from the viewport rather
	# than the director keeps this loose-coupled — works whether _director
	# is alive, in spotlight pass, free-cam mode, or replaced.
	var cam := get_viewport().get_camera_3d()
	if cam == null or _live_marbles.is_empty():
		return
	_casino_meta.send_hud(_live_tick, _live_marbles, cam)

	_casino_minimap_accum += delta
	if _casino_minimap_accum >= 0.1:
		_casino_minimap_accum = 0.0
		_casino_meta.send_minimap(_live_tick, _live_marbles)

func _maybe_close_casino_streamers() -> void:
	if _casino_frames != null:
		_casino_frames.close()
		_casino_frames = null
	if _casino_meta != null:
		_casino_meta.close()
		_casino_meta = null
	_casino_minimap_accum = 0.0

# Strip the render profile to broadcast-server defaults. There is no
# local viewer for this Godot subprocess — only the H.264 stream — so
# every shader/effect cost we pay shows up as encoded fps lost. The
# toggles below mirror the list spec'd in the M29 broadcast plan:
# WorldEnvironment SSAO/SSR/glow/volumetric-fog OFF, MSAA OFF, FXAA on,
# DirectionalLight shadows OFF, mesh-LOD bias toward lower detail.
#
# Each change is logged so we can read the rgsd-side ffmpeg fps before/
# after and keep only the cheapest ones if we want to dial visual
# quality back in later.
func _apply_broadcast_render_profile() -> void:
	# 1. Find the active WorldEnvironment node and override its Environment.
	#    The scene's WorldEnvironment was added by EnvironmentBuilder.build_environment().
	var env_node: WorldEnvironment = null
	for child in get_children():
		if child is WorldEnvironment:
			env_node = child
			break
	if env_node != null and env_node.environment != null:
		var env: Environment = env_node.environment
		var prev_glow := env.glow_enabled
		var prev_ssao := env.ssao_enabled
		var prev_ssil := env.ssil_enabled
		var prev_ssr  := env.ssr_enabled
		var prev_fog  := env.fog_enabled
		var prev_volfog := env.volumetric_fog_enabled
		var prev_sdfgi := env.sdfgi_enabled
		env.glow_enabled = false
		env.ssao_enabled = false
		env.ssil_enabled = false
		env.ssr_enabled = false
		env.volumetric_fog_enabled = false
		env.sdfgi_enabled = false
		# Keep linear fog: cheap and used for atmospheric depth cues.
		print("[broadcast-profile] env: glow=%s→off ssao=%s→off ssil=%s→off ssr=%s→off volfog=%s→off sdfgi=%s→off (linear fog kept=%s)"
				% [prev_glow, prev_ssao, prev_ssil, prev_ssr, prev_volfog, prev_sdfgi, prev_fog])
	else:
		print("[broadcast-profile] no WorldEnvironment found — skipped env tweaks")

	# 2. Disable shadows on every DirectionalLight3D in the tree. The
	#    casino sun is added directly under main.gd by _build_environment;
	#    tracks may add their own. Walk recursively to catch them all.
	var shadowed_lights := 0
	_disable_shadows_recursive(self, shadowed_lights)
	# (The recursive helper logs its own count.)

	# 3. Viewport: MSAA off, FXAA on (very cheap), TAA off, debanding off,
	#    LOD bias toward less detail. mesh_lod_threshold default is 1.0
	#    (pixels of error before stepping down a LOD); 8.0 is a noticeable
	#    drop in distant detail and visibly cheaper.
	var vp := get_viewport()
	if vp != null:
		var prev_msaa := vp.msaa_3d
		var prev_aa := vp.screen_space_aa
		var prev_taa := vp.use_taa
		var prev_debanding := vp.use_debanding
		var prev_lod := vp.mesh_lod_threshold
		vp.msaa_3d = Viewport.MSAA_DISABLED
		vp.screen_space_aa = Viewport.SCREEN_SPACE_AA_FXAA
		vp.use_taa = false
		vp.use_debanding = false
		vp.mesh_lod_threshold = 8.0
		print("[broadcast-profile] viewport: msaa3d=%s→DISABLED ssaa=%s→FXAA taa=%s→false debanding=%s→false lod_threshold=%s→8.0"
				% [prev_msaa, prev_aa, prev_taa, prev_debanding, prev_lod])

func _disable_shadows_recursive(node: Node, count: int) -> int:
	for child in node.get_children():
		if child is DirectionalLight3D and child.shadow_enabled:
			child.shadow_enabled = false
			count += 1
			print("[broadcast-profile] sun-shadows: %s.shadow_enabled = false" % child.name)
		# Optionally include OmniLight3D / SpotLight3D shadows too — the
		# tracks set their own; turn them off here for a uniform profile.
		elif (child is OmniLight3D or child is SpotLight3D) and child.shadow_enabled:
			child.shadow_enabled = false
			count += 1
			print("[broadcast-profile] light-shadows: %s.shadow_enabled = false" % child.name)
		count = _disable_shadows_recursive(child, count)
	return count

func _get_casino_broadcast_addrs() -> Dictionary:
	# Parse `--casino-video=host:port` and `--casino-meta=host:port` from
	# the CLI tail (Godot exposes these via OS.get_cmdline_user_args()).
	# Returns empty dict when either is missing — both are required.
	var args := OS.get_cmdline_user_args()
	var video := ""
	var meta := ""
	for a in args:
		if a.begins_with("--casino-video="):
			video = a.substr("--casino-video=".length())
		elif a.begins_with("--casino-meta="):
			meta = a.substr("--casino-meta=".length())
	if video == "" or meta == "":
		return {}
	var v_bits := video.split(":")
	var m_bits := meta.split(":")
	if v_bits.size() != 2 or m_bits.size() != 2:
		push_error("casino: --casino-video / --casino-meta must be host:port")
		return {}
	return {
		"video_host": v_bits[0],
		"video_port": int(v_bits[1]),
		"meta_host":  m_bits[0],
		"meta_port":  int(m_bits[1]),
	}
