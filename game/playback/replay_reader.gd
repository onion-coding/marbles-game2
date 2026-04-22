class_name ReplayReader
extends RefCounted

# Returns {} on failure. See replay_writer.gd for format v2.
static func read(path: String) -> Dictionary:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return {}
	var bytes := f.get_buffer(f.get_length())
	f.close()
	return read_bytes(bytes)

# Same as read() but takes bytes directly — used by the web client which
# fetches replay.bin over HTTP instead of reading from the local filesystem.
static func read_bytes(bytes: PackedByteArray) -> Dictionary:
	var b := StreamPeerBuffer.new()
	b.big_endian = false
	b.data_array = bytes

	var header_dict := _read_header_into(b)
	if header_dict.is_empty():
		return {}
	var marble_count: int = (header_dict["header"] as Array).size()

	var frame_count := b.get_u32()
	var frames: Array = []
	for i in range(frame_count):
		frames.append(_read_frame_into(b, marble_count))

	header_dict["frames"] = frames
	return header_dict

# Decode just the HEADER payload from the live-stream protocol (same byte
# layout as the replay-file header, minus the trailing frame count). Returns
# {} on failure.
static func decode_header_bytes(bytes: PackedByteArray) -> Dictionary:
	var b := StreamPeerBuffer.new()
	b.big_endian = false
	b.data_array = bytes
	return _read_header_into(b)

# Decode one TICK payload: tick(u32) + flags(u8) + marble_count × (pos+quat).
# Caller supplies marble_count from the previously-decoded header.
static func decode_frame_bytes(bytes: PackedByteArray, marble_count: int) -> Dictionary:
	var b := StreamPeerBuffer.new()
	b.big_endian = false
	b.data_array = bytes
	return _read_frame_into(b, marble_count)

static func _read_header_into(b: StreamPeerBuffer) -> Dictionary:
	var protocol_version := b.get_u8()
	if protocol_version != 3:
		push_error("unsupported replay protocol_version=%d (expected 3 — see docs/tick-schema.md)" % protocol_version)
		return {}
	var round_id := b.get_u64()
	var tick_rate_hz := b.get_u32()

	var seed_len := b.get_u8()
	var server_seed: PackedByteArray = b.get_data(seed_len)[1]
	var hash_len := b.get_u8()
	var server_seed_hash: PackedByteArray = b.get_data(hash_len)[1]
	var slot_count := b.get_u32()
	var track_id := b.get_u8()

	var marble_count := b.get_u32()
	var header: Array = []
	for i in range(marble_count):
		var id := b.get_u32()
		var rgba := b.get_u32()
		var name_len := b.get_u8()
		var name_bytes: PackedByteArray = b.get_data(name_len)[1]
		var cseed_len := b.get_u8()
		var cseed_bytes: PackedByteArray = b.get_data(cseed_len)[1]
		var slot := b.get_u32()
		header.append({
			"id": id,
			"rgba": rgba,
			"name": name_bytes.get_string_from_utf8(),
			"client_seed": cseed_bytes.get_string_from_utf8(),
			"slot": slot,
		})

	return {
		"protocol_version": protocol_version,
		"round_id": round_id,
		"tick_rate_hz": tick_rate_hz,
		"server_seed": server_seed,
		"server_seed_hash": server_seed_hash,
		"slot_count": slot_count,
		"track_id": track_id,
		"header": header,
	}

static func _read_frame_into(b: StreamPeerBuffer, marble_count: int) -> Dictionary:
	var tick := b.get_u32()
	var flags := b.get_u8()
	var states: Array = []
	for _j in range(marble_count):
		var px := b.get_float(); var py := b.get_float(); var pz := b.get_float()
		var qx := b.get_float(); var qy := b.get_float(); var qz := b.get_float(); var qw := b.get_float()
		states.append({
			"pos": Vector3(px, py, pz),
			"rot": Quaternion(qx, qy, qz, qw),
		})
	return {"tick": tick, "flags": flags, "states": states}
