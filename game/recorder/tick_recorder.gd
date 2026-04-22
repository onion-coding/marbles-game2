class_name TickRecorder
extends Node

const EVENT_FINISH_CROSS := 1 << 0
const TAIL_TICKS := 60  # ~1s slowdown footage after winner crosses
const TICK_RATE_HZ := 60

signal finalized(path: String)

var marbles: Array[RigidBody3D] = []
var finish_line: FinishLine = null

var header: Array = []  # [{id, name, client_seed, slot}] per marble
var frames: Array = []  # [{tick, flags, states: [{pos, rot}]}]
var recording: bool = true

# If set, write the replay to this absolute path instead of user://replays/<round_id>.bin.
# Used by the Go invoker (see server/sim) to place the replay where the server wants it.
var _output_override: String = ""

# Optional live streamer: if set, HEADER is pushed after track() and TICK each
# _physics_process. DONE on _finalize. Disk write still happens unconditionally.
var _streamer: TickStreamer = null

func override_output_path(path: String) -> void:
	_output_override = path

func set_streamer(s: TickStreamer) -> void:
	_streamer = s

var _round_id: int = 0
var _server_seed: PackedByteArray = PackedByteArray()
var _server_seed_hash: PackedByteArray = PackedByteArray()
var _client_seeds: Array = []
var _slots: Array = []
var _colors: Array = []
var _slot_count: int = 0
var _track_id: int = 0

var _pending_flags: int = 0
var _stop_tick: int = -1

func set_round_context(
	round_id: int,
	server_seed: PackedByteArray,
	server_seed_hash: PackedByteArray,
	client_seeds: Array,
	slots: Array,
	colors: Array = [],
	track_id: int = 0,
) -> void:
	_round_id = round_id
	_server_seed = server_seed
	_server_seed_hash = server_seed_hash
	_client_seeds = client_seeds
	_slots = slots
	_colors = colors
	_slot_count = SpawnRail.SLOT_COUNT
	_track_id = track_id

func track(marble_list: Array[RigidBody3D], line: FinishLine) -> void:
	marbles = marble_list
	finish_line = line
	header.clear()
	for i in range(marbles.size()):
		var m := marbles[i]
		var rgba := FairSeed.color_to_rgba32(_colors[i]) if i < _colors.size() else 0
		header.append({
			"id": m.get_instance_id(),
			"name": m.name,
			"client_seed": String(_client_seeds[i]) if i < _client_seeds.size() else "",
			"slot": int(_slots[i]) if i < _slots.size() else 0,
			"rgba": rgba,
		})
	if finish_line:
		finish_line.marble_crossed.connect(_on_marble_crossed)
		finish_line.race_finished.connect(_on_race_finished)

	if _streamer != null:
		var header_bytes := ReplayWriter.encode_header({
			"round_id": _round_id,
			"tick_rate_hz": TICK_RATE_HZ,
			"server_seed": _server_seed,
			"server_seed_hash": _server_seed_hash,
			"slot_count": _slot_count,
			"track_id": _track_id,
			"header": header,
		})
		_streamer.send_header(header_bytes)

func _physics_process(_delta: float) -> void:
	if not recording:
		return
	var tick := Engine.get_physics_frames()
	var states: Array = []
	for m in marbles:
		states.append({
			"pos": m.global_position,
			"rot": m.global_basis.get_rotation_quaternion(),
		})
	var frame := {"tick": tick, "flags": _pending_flags, "states": states}
	frames.append(frame)
	if _streamer != null:
		_streamer.send_tick(ReplayWriter.encode_frame(frame))
	_pending_flags = 0
	if _stop_tick >= 0 and tick >= _stop_tick:
		_finalize()

func _on_marble_crossed(_marble: RigidBody3D, _tick: int) -> void:
	_pending_flags |= EVENT_FINISH_CROSS

func _on_race_finished(_winner: RigidBody3D, tick: int) -> void:
	_stop_tick = tick + TAIL_TICKS

func _finalize() -> void:
	recording = false
	if _streamer != null:
		_streamer.send_done()
	print("RECORDER: captured %d frames, %d marbles/frame" % [frames.size(), marbles.size()])
	print("REVEAL: server_seed=%s" % FairSeed.to_hex(_server_seed))

	var path := _output_override if not _output_override.is_empty() else "user://replays/%d.bin" % _round_id
	var err := ReplayWriter.write(path, {
		"round_id": _round_id,
		"tick_rate_hz": TICK_RATE_HZ,
		"server_seed": _server_seed,
		"server_seed_hash": _server_seed_hash,
		"slot_count": _slot_count,
		"track_id": _track_id,
		"header": header,
		"frames": frames,
	})
	if err != OK:
		push_error("replay write failed: %d" % err)
		return
	var size := FileAccess.get_file_as_bytes(path).size()
	print("WRITER: wrote %s (%d bytes)" % [path, size])

	_roundtrip_check(path)
	finalized.emit(path)

func _roundtrip_check(path: String) -> void:
	var replay := ReplayReader.read(path)
	if replay.is_empty():
		push_error("replay read failed")
		return
	var read_frames: Array = replay["frames"]
	var read_header: Array = replay["header"]
	var ok := read_frames.size() == frames.size() and read_header.size() == header.size()
	if ok and frames.size() > 0:
		var orig_last: Dictionary = frames[frames.size() - 1]
		var read_last: Dictionary = read_frames[read_frames.size() - 1]
		ok = (orig_last["states"][0]["pos"] as Vector3).is_equal_approx(read_last["states"][0]["pos"] as Vector3)
		ok = ok and orig_last["tick"] == read_last["tick"]
		ok = ok and (replay["server_seed"] as PackedByteArray) == _server_seed
		ok = ok and int(read_header[0]["slot"]) == int(header[0]["slot"])
	print("ROUNDTRIP: %s (%d frames, %d marbles)" % ["OK" if ok else "MISMATCH", read_frames.size(), read_header.size()])
