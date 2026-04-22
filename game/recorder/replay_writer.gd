class_name ReplayWriter
extends RefCounted

# Binary replay format v3 per docs/tick-schema.md + fairness.md.
# v3 adds `track_id: u8` after `slot_count` so the playback/verify paths know
# which Track class to re-instantiate (see game/tracks/track_registry.gd).
# v2 added the fairness block (server_seed, hash, per-marble slot + client_seed).
# v0 raw f32 for pos + quat; quantization deferred to M2.5.
#
# The same byte encoding is reused by the live stream (server/stream): the
# HEADER message carries what `encode_header()` produces and each TICK message
# carries what `encode_frame()` produces. Clients get one decoder for both
# archive-replay and live-stream paths.

const PROTOCOL_VERSION := 3

static func write(path: String, replay: Dictionary) -> Error:
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return FileAccess.get_open_error()
	f.store_buffer(_encode(replay).data_array)
	f.close()
	return OK

# Header bytes only — PROTOCOL_VERSION through per-marble entries, no frame count.
# Suitable as the HEADER payload for live streaming.
static func encode_header(replay: Dictionary) -> PackedByteArray:
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
	b.put_u8(int(replay["track_id"]) & 0xFF)

	var header: Array = replay["header"]
	b.put_u32(header.size())
	for m: Dictionary in header:
		b.put_u32(int(m["id"]) & 0xFFFFFFFF)
		b.put_u32(int(m.get("rgba", 0)) & 0xFFFFFFFF)
		var name_bytes: PackedByteArray = String(m["name"]).to_utf8_buffer()
		b.put_u8(name_bytes.size())
		b.put_data(name_bytes)
		var cseed_bytes: PackedByteArray = String(m.get("client_seed", "")).to_utf8_buffer()
		b.put_u8(cseed_bytes.size())
		b.put_data(cseed_bytes)
		b.put_u32(int(m.get("slot", 0)))
	return b.data_array

# One frame's encoding: tick, flags, then `marble_count` × (pos+quat).
# Suitable as a TICK payload for live streaming.
static func encode_frame(frame: Dictionary) -> PackedByteArray:
	var b := StreamPeerBuffer.new()
	b.big_endian = false
	b.put_u32(int(frame["tick"]))
	b.put_u8(int(frame["flags"]) & 0xFF)
	var states: Array = frame["states"]
	for s: Dictionary in states:
		var p: Vector3 = s["pos"]
		b.put_float(p.x); b.put_float(p.y); b.put_float(p.z)
		var q: Quaternion = s["rot"]
		b.put_float(q.x); b.put_float(q.y); b.put_float(q.z); b.put_float(q.w)
	return b.data_array

static func _encode(replay: Dictionary) -> StreamPeerBuffer:
	var out := StreamPeerBuffer.new()
	out.big_endian = false
	out.put_data(encode_header(replay))
	var frames: Array = replay["frames"]
	out.put_u32(frames.size())
	for frame: Dictionary in frames:
		out.put_data(encode_frame(frame))
	return out
