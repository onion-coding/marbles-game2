class_name ReplayReader
extends RefCounted

# Returns {} on failure. See replay_writer.gd for format v2.
static func read(path: String) -> Dictionary:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return {}
	var bytes := f.get_buffer(f.get_length())
	f.close()

	var b := StreamPeerBuffer.new()
	b.big_endian = false
	b.data_array = bytes

	var protocol_version := b.get_u8()
	if protocol_version != 2:
		push_error("unsupported replay protocol_version=%d" % protocol_version)
		return {}
	var round_id := b.get_u64()
	var tick_rate_hz := b.get_u32()

	var seed_len := b.get_u8()
	var server_seed: PackedByteArray = b.get_data(seed_len)[1]
	var hash_len := b.get_u8()
	var server_seed_hash: PackedByteArray = b.get_data(hash_len)[1]
	var slot_count := b.get_u32()

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

	var frame_count := b.get_u32()
	var frames: Array = []
	for i in range(frame_count):
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
		frames.append({"tick": tick, "flags": flags, "states": states})

	return {
		"protocol_version": protocol_version,
		"round_id": round_id,
		"tick_rate_hz": tick_rate_hz,
		"server_seed": server_seed,
		"server_seed_hash": server_seed_hash,
		"slot_count": slot_count,
		"header": header,
		"frames": frames,
	}
