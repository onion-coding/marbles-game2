# Tick schema — replay wire format

Binary format streamed from server to client over WebSocket. One message per physics tick (or batched).

Status: **v2 implemented** (M2 + M3, 2026-04-15) in [game/recorder/replay_writer.gd](../game/recorder/replay_writer.gd) / [game/playback/replay_reader.gd](../game/playback/replay_reader.gd). v0/v1 of this sketch was extended to v2 in M3 to carry the fairness block (`server_seed`, hash, per-marble `client_seed` + `spawn_slot`). Quantization (§Quantization below) is **not** yet implemented — current writer uses raw f32 pos + quat (~28 B/marble/tick instead of the planned ~15 B). Tracked as M2.5; deferred until bandwidth pressure is real.

## Constraints

- **Bandwidth:** each client watches one live round. Up to 20 marbles. Race length ~30–60s.
- **Smoothness:** client interpolates between ticks. 30Hz tick rate on the wire is likely enough if we interpolate on render; 60Hz is safe default.
- **Casino iframe friendly:** keep total replay < a few MB compressed. 20 marbles × 60Hz × 60s × (pos+rot) ≈ 20 × 3600 × 28 bytes ≈ 2 MB uncompressed. Comfortably compresses.
- **Deterministic decoding:** same bytes → same render on every client.

## Byte order

The format uses **two different byte orders on purpose**. A verifier in another language (Python, JS, Go) must respect both or it will disagree with the reference implementation.

- **Replay file / wire frames: little-endian.** Every multi-byte field in the header and every tick frame — `round_id`, `tick_rate_hz`, `marble_count`, `tick_index`, the f32 pos/quat components, and (future) quantized i24/i16 components — is little-endian. This matches `StreamPeerBuffer` with `big_endian = false`, which is the default on the writer ([game/recorder/replay_writer.gd](../game/recorder/replay_writer.gd)) and reader ([game/playback/replay_reader.gd](../game/playback/replay_reader.gd)). Chosen because little-endian is the native layout on every platform we ship to (x86-64 servers, ARM64, WASM), so no byte-swap cost on the hot path.
- **Hash inputs (fairness only): big-endian.** Inside `_hash_marble`, the integers fed into SHA-256 — `round_id` as u64 and `marble_index` as u32 — are serialized **big-endian** ([game/fairness/seed.gd](../game/fairness/seed.gd) `_u64_be` / `_u32_be`). This is the "network byte order" convention used in virtually every crypto spec (TLS, Bitcoin, SSH, JOSE) and matches the protocol description in [fairness.md](fairness.md) §Spawn derivation. A verifier that accidentally hashes these little-endian will produce entirely different `spawn_slot` values and reject every round as tampered.
- **Bytes already in byte form** (`server_seed`, `client_seed` UTF-8, `server_seed_hash`) have no endianness — they are fed to SHA-256 and written to disk as-is.

Rule of thumb: **if it goes into a hash, it's big-endian; if it goes into a file or wire frame, it's little-endian.**

## Frame structure (v0 sketch)

```
header (once per round):
  u8   protocol_version            # 1
  u64  round_id
  u32  tick_rate_hz                # 60 for now
  u32  marble_count                # N
  for each marble:
    u32 marble_id
    u32 rgba                       # marble color
    u8  name_len; bytes[name_len]  # UTF-8 player label

tick frame (repeated):
  u32  tick_index
  u8   event_flags                 # bit 0: finish-line crossing this tick
  for each marble (N):
    i24  x, y, z                   # quantized position (see below)
    i16  qx, qy, qz                # compressed quaternion (smallest-3 or similar)
  if event_flags & 0x1:
    u32  marble_id                 # who crossed
    u32  crossing_tick
```

## Quantization

- **Position:** track-space bounding box is ~40m on the long axis. Quantize to millimeters (i24 = ±8388 m range, resolution 1mm). Encodes as 9 bytes per marble per tick.
- **Rotation:** smallest-three quaternion compression to 48 bits (6 bytes). Three i16 components of the quaternion excluding the largest; 2 bits to identify which.
- **Per-marble per-tick cost:** ~15 bytes. For 20 marbles × 60Hz × 60s = **~1.0 MB uncompressed**, ~300–500 KB gzipped.

## Delivery

- **Live mode (M5):** WebSocket, ticks batched every 100ms (6 ticks at 60Hz). Client buffers ~200ms and interpolates.
- **Replay-from-archive mode:** single compressed blob served over HTTP, replay scrubbable.

## Open questions

- **Tick rate on the wire.** Sim runs at 60Hz. Do we send every tick (1.0 MB) or decimate to 30Hz (0.5 MB) and interpolate? Decimation is lossy for fast collisions.
- **Delta encoding.** Position tends to be continuous — first-order delta (tick-to-tick diff) is 2–3× smaller again before gzip. Worth it if we hit bandwidth limits.
- **Event channel separate from state?** Currently events are per-tick flags; an out-of-band event stream simplifies delta-encoding the position data.
- **Backpressure.** If a client's WS buffer grows, do we skip ticks (accept visual jitter) or disconnect?
- **Version negotiation.** Clients pinned to `protocol_version` for a whole round; upgrade between rounds only.
