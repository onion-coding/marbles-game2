class_name FairSeed
extends RefCounted

# Provably-fair primitives. Protocol defined in docs/fairness.md.
# Keep this file pure: no engine state, only hashing + byte math.

const SEED_BYTES := 32

static func generate_server_seed() -> PackedByteArray:
	var crypto := Crypto.new()
	return crypto.generate_random_bytes(SEED_BYTES)

static func hash_server_seed(server_seed: PackedByteArray) -> PackedByteArray:
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_SHA256)
	ctx.update(server_seed)
	return ctx.finish()

static func to_hex(bytes: PackedByteArray) -> String:
	return bytes.hex_encode()

static func from_hex(s: String) -> PackedByteArray:
	var out := PackedByteArray()
	for i in range(0, s.length(), 2):
		out.append(s.substr(i, 2).hex_to_int())
	return out

# Derive spawn slots for a round. Returns an Array[int] of length marble_count,
# where each entry is the assigned slot in [0, slot_count). Collisions resolved
# by deterministic linear probing per docs/fairness.md §spawn derivation.
static func derive_spawn_slots(
	server_seed: PackedByteArray,
	round_id: int,
	client_seeds: Array,  # Array[String] per marble; "" if none
	slot_count: int,
) -> Array:
	var marble_count := client_seeds.size()
	var taken := {}
	var slots: Array = []
	for i in range(marble_count):
		var raw := _hash_marble(server_seed, round_id, String(client_seeds[i]), i)
		var slot := _bytes_to_u32_be(raw, 0) % slot_count
		while taken.has(slot):
			slot = (slot + 1) % slot_count
		taken[slot] = true
		slots.append(slot)
	return slots

# Derive per-marble RGBA colors from the same hash as the slot. See docs/fairness.md §Color derivation.
# Bytes 4/5/6 → R/G/B, alpha fixed 0xFF. Returns an Array[Color].
static func derive_marble_colors(
	server_seed: PackedByteArray,
	round_id: int,
	client_seeds: Array,
) -> Array:
	var colors: Array = []
	for i in range(client_seeds.size()):
		var raw := _hash_marble(server_seed, round_id, String(client_seeds[i]), i)
		colors.append(Color8(raw[4], raw[5], raw[6], 0xFF))
	return colors

# Pack a Color into the replay's u32 rgba field (R << 24 | G << 16 | B << 8 | A).
static func color_to_rgba32(c: Color) -> int:
	return (int(round(c.r * 255.0)) << 24) | (int(round(c.g * 255.0)) << 16) | (int(round(c.b * 255.0)) << 8) | int(round(c.a * 255.0))

static func _hash_marble(
	server_seed: PackedByteArray,
	round_id: int,
	client_seed: String,
	marble_index: int,
) -> PackedByteArray:
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_SHA256)
	ctx.update(server_seed)
	ctx.update(_u64_be(round_id))
	var cs := client_seed.to_utf8_buffer()
	if cs.size() > 0:
		ctx.update(cs)
	ctx.update(_u32_be(marble_index))
	return ctx.finish()

static func _u64_be(n: int) -> PackedByteArray:
	var out := PackedByteArray()
	out.resize(8)
	for i in range(8):
		out[7 - i] = (n >> (i * 8)) & 0xFF
	return out

static func _u32_be(n: int) -> PackedByteArray:
	var out := PackedByteArray()
	out.resize(4)
	for i in range(4):
		out[3 - i] = (n >> (i * 8)) & 0xFF
	return out

static func _bytes_to_u32_be(bytes: PackedByteArray, offset: int) -> int:
	return (bytes[offset] << 24) | (bytes[offset + 1] << 16) | (bytes[offset + 2] << 8) | bytes[offset + 3]
