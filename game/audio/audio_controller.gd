class_name AudioController
extends Node

# Audio scaffolding for player-facing scenes (web/live/playback). Slots:
#   - Ambient music — long looped track, per-track via Track.audio_overrides()
#     or a generic fallback at res://audio/ambient_default.ogg.
#   - Winner jingle — one-shot at the moment a marble crosses the finish.
#   - Collision SFX — pluggable but currently a stub (real impl needs the
#     sim or PlaybackPlayer to expose collision events; doable, deferred).
#
# Files are loaded lazily and the controller is a no-op if the assets
# aren't on disk. This lets the visual layer ship without bundling audio,
# and the user / sound designer drops files into game/audio/ at any time.
#
# Bus layout: a single "Master" bus is enough for MVP; a future pass can
# split into Music + SFX + UI buses with a settings overlay.
#
# Wiring: scenes instantiate one AudioController as a child of the root,
# then call:
#   ac.start_ambient(track_id)
#   ac.play_winner_jingle()
#   ac.stop_all()  # on scene cleanup

const AUDIO_ROOT := "res://audio/"
const AMBIENT_FALLBACK := "res://audio/ambient_default.ogg"
const WINNER_JINGLE := "res://audio/winner_jingle.ogg"

# Per-track ambient sample paths. Tracks may override via
# Track.audio_overrides()["ambient"]; this dict is the fallback per-id mapping
# so the registry stays declarative even without per-track overrides.
const AMBIENT_PER_TRACK := {
	0: "res://audio/ambient_ramp.ogg",
	1: "res://audio/ambient_roulette.ogg",
	2: "res://audio/ambient_craps.ogg",
	3: "res://audio/ambient_poker.ogg",
	4: "res://audio/ambient_slots.ogg",
	5: "res://audio/ambient_plinko.ogg",
}

var _ambient_player: AudioStreamPlayer
var _jingle_player: AudioStreamPlayer

func _ready() -> void:
	_ambient_player = AudioStreamPlayer.new()
	_ambient_player.name = "AmbientPlayer"
	_ambient_player.bus = "Master"
	_ambient_player.volume_db = -8.0     # ambient sits under SFX / jingle
	add_child(_ambient_player)

	_jingle_player = AudioStreamPlayer.new()
	_jingle_player.name = "JinglePlayer"
	_jingle_player.bus = "Master"
	_jingle_player.volume_db = 0.0
	add_child(_jingle_player)

# ─── Public API ──────────────────────────────────────────────────────────

# Starts the ambient loop appropriate for `track_id`. Falls through to the
# generic ambient if the per-track file is missing, then to silence if
# the fallback is also missing. `track_audio_overrides` lets a Track
# subclass supply a custom path via its environment_overrides-style API.
func start_ambient(track_id: int, track_audio_overrides: Dictionary = {}) -> void:
	var path := ""
	if track_audio_overrides.has("ambient"):
		path = String(track_audio_overrides["ambient"])
	elif AMBIENT_PER_TRACK.has(track_id):
		path = String(AMBIENT_PER_TRACK[track_id])
	if path == "" or not ResourceLoader.exists(path):
		path = AMBIENT_FALLBACK
	if not ResourceLoader.exists(path):
		# No assets shipped yet — silent ambient is fine, this is the MVP path.
		return
	var stream := load(path) as AudioStream
	if stream == null:
		return
	_ambient_player.stream = stream
	_set_loop(stream, true)
	_ambient_player.play()

func play_winner_jingle() -> void:
	if not ResourceLoader.exists(WINNER_JINGLE):
		return
	var stream := load(WINNER_JINGLE) as AudioStream
	if stream == null:
		return
	_jingle_player.stream = stream
	_set_loop(stream, false)
	_jingle_player.play()

func stop_all() -> void:
	if _ambient_player and _ambient_player.playing:
		_ambient_player.stop()
	if _jingle_player and _jingle_player.playing:
		_jingle_player.stop()

# ─── Helpers ─────────────────────────────────────────────────────────────

func _set_loop(stream: AudioStream, loop: bool) -> void:
	# Different AudioStream types expose loop differently. Best-effort: if the
	# stream has the property, set it.
	if stream.has_method("set_loop"):
		stream.call("set_loop", loop)
	elif "loop" in stream:
		stream.set("loop", loop)
