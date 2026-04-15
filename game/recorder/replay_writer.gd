class_name ReplayWriter
extends RefCounted

# Binary replay format v2 per docs/tick-schema.md + fairness.md.
# v2 adds the fairness block (server_seed, hash, per-marble slot + client_seed).
# v0 raw f32 for pos + quat; quantization deferred to M2.5.

const PROTOCOL_VERSION := 2

static func write(path: String, replay: Dictionary) -> Error:
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return FileAccess.get_open_error()
	f.store_buffer(_encode(replay).data_array)
	f.close()
	return OK

static func _encode(replay: Dictionary) -> StreamPeerBuffer:
	var b := StreamPeerBuffer.new()
	b.big_endian = false

	b.put_u8(PROTOCOL_VERSION)
	b.put_u64(int(replay["round_id"]))
	b.put_u32(int(replay["tick_rate_hz"]))

	var server_seed: PackedByteArray = replay["server_seed"]
	b.put_u8(server_seed.size())
	b.put_data(server_seed)
	var server_seed_hash: PackedByteArray = replay["server_seed_hash"]
	b.put_u8(server_seed_hash.size())
	b.put_data(server_seed_hash)
	b.put_u32(int(replay["slot_count"]))

	var header: Array = replay["header"]
	b.put_u32(header.size())
	for m in header:
		b.put_u32(int(m["id"]) & 0xFFFFFFFF)
		b.put_u32(0)  # rgba — still stubbed, see PROGRESS.md open question
		var name_bytes: PackedByteArray = String(m["name"]).to_utf8_buffer()
		b.put_u8(name_bytes.size())
		b.put_data(name_bytes)
		var cseed_bytes: PackedByteArray = String(m.get("client_seed", "")).to_utf8_buffer()
		b.put_u8(cseed_bytes.size())
		b.put_data(cseed_bytes)
		b.put_u32(int(m.get("slot", 0)))

	var frames: Array = replay["frames"]
	b.put_u32(frames.size())
	for frame in frames:
		b.put_u32(int(frame["tick"]))
		b.put_u8(int(frame["flags"]) & 0xFF)
		var states: Array = frame["states"]
		for s in states:
			var p: Vector3 = s["pos"]
			b.put_float(p.x); b.put_float(p.y); b.put_float(p.z)
			var q: Quaternion = s["rot"]
			b.put_float(q.x); b.put_float(q.y); b.put_float(q.z); b.put_float(q.w)
	return b
