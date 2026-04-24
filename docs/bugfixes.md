# Bugfix log

Running log of bugs found and how they were fixed. One entry per bug. Purpose: searchable history of weird root causes and gotchas so we don't re-debug the same thing six months from now.

**When to add an entry:** a bug that took more than a trivial amount of time to track down, OR that had a non-obvious root cause, OR that touches an area likely to regress.

**When NOT to add:** one-line typo fixes, obvious compile errors, work-in-progress iteration. Git log already covers those.

## Entry format

```
## <short title> — YYYY-MM-DD
**Symptom:** what the user / developer saw.
**Root cause:** what was actually wrong.
**Fix:** what changed. Link to commit SHA or PR.
**Lesson:** (optional) what to remember for next time.
```

## Entries

## Marbles spawning at the downhill end of the ramp — 2026-04-14
**Symptom:** During M1 playtest, the 20 marbles appeared to spawn near "the end of the platform" and barely moved — hard to judge physics feel because there was no sustained rolling.
**Root cause:** The ramp is tilted `-20°` around X in [game/main.gd](game/main.gd). Under that rotation, world **Z=+15 is the uphill end and Z=-15 is the downhill end** — the opposite of what the naive "negative Z = back = top" intuition suggests. The spawn block placed marbles at Z ∈ [-15, -13] — i.e. the *bottom* of the ramp — so they just fell onto the downhill end and settled.
**Fix:** Flipped spawn Z to `RAMP_LENGTH*0.5 - rng.randf_range(0, 2.0)` (uphill end) and lowered `SPAWN_HEIGHT` from 12.0 to 5.8 (~1 unit above the tilted ramp surface at that Z) in [game/main.gd](game/main.gd). No physics-material changes needed.
**Lesson:** When a body is rotated around X by a negative angle in Godot, the +Z local axis tilts *up* in world space, not down. Always sanity-check spawn coordinates against the actual rotated ramp geometry (`y_world ≈ z_local * sin(angle)`) rather than trusting axis sign intuition.

## Half the marbles bouncing off the ramp at spawn — 2026-04-16
**Symptom:** First windowed race after M3 showed ~10 of 20 marbles bouncing off the ramp edges in the first second, never reaching the finish line. Spawns also looked visibly overlapped during the drop.
**Root cause:** Two compounding geometry mistakes, both invisible in headless runs:
1. `SpawnRail` used a fixed `Y_STAGGER=0.35` per drop-order slot across 20 marbles — a ~6.5m-tall column of marbles falling onto the ramp. The top marbles hit with enough vertical velocity to skip off the deck.
2. The spawn rail's Z was hardcoded to a value ~0.1m inside the uphill edge of the ramp. Any lateral drift at spawn put marbles past the wall before the walls' collision resolved.
**Fix:** Commit `311d16f`. [game/tracks/ramp_track.gd](game/tracks/ramp_track.gd) added `WALL_HEIGHT=3.0` + `DECK_THICKNESS` + static `surface_pos_at(local_z)` helper. [game/sim/spawn_rail.gd](game/sim/spawn_rail.gd) now derives Z and Y from `RampTrack.surface_pos_at(LENGTH/2 − UPHILL_MARGIN)` with a fixed `Y_CLEARANCE` above the surface; `Y_STAGGER` dropped 0.35 → 0.12 (column ~2.3m). `LENGTH` and `ANGLE_DEG` now auto-move the rail. Finish line and fixed camera also re-derive from ramp geometry.
**Lesson:** Hardcoded world coordinates for gameplay-critical positions are a trap when the underlying geometry is parameterized — the sim will happily run with wrong-but-not-crashing positions and you'll only notice at playtest. Derive from the geometry.

## HashingContext crash on empty client_seed — 2026-04-15
**Symptom:** `_hash_marble` threw inside Godot's `HashingContext.update` when a participant had no `client_seed` set (e.g. the first end-to-end test that passed zero-length client seeds).
**Root cause:** Godot's `HashingContext.update(PackedByteArray)` rejects zero-length buffers with an error, even though `update` is conceptually a no-op for empty input. The fairness spec allows empty client seeds (participants who didn't contribute entropy still hash under the server seed).
**Fix:** Commit `944d190`. [game/fairness/seed.gd](game/fairness/seed.gd) guards `if client_seed.size() > 0` before calling `update`. Hash output is unchanged for non-empty inputs; empty inputs now match the spec (treated as the empty string, as SHA-256 permits).
**Lesson:** Godot wraps several crypto primitives that are strict about empty inputs where the underlying algorithm isn't. Worth a guard whenever data originates from user input.

## Unix-nano round IDs lose precision as JSON numbers — 2026-04-16
**Symptom:** Browser-based Godot client built in M5.1 consistently fetched the wrong replay for the latest round. Round IDs in `/rounds` differed from the ID shown in `roundd`'s log by small trailing digits.
**Root cause:** Round IDs are `uint64` unix-nanoseconds (~19 digits). Serialized as JSON numbers, they overflow `float64`'s 53-bit mantissa and get silently rounded when parsed by Godot's `JSON.parse_string` or JavaScript's `Number`. `encoding/json` on the server preserves `uint64` fine, so Go-side tests didn't catch it.
**Fix:** Commit `311d16f`. [server/api/http.go](server/api/http.go) `GET /rounds` now returns IDs as JSON **strings**, not numbers. Manifest's `round_id` field is left as a number because only Go consumers (roundd, tests) read it; the `server_seed_hash_hex` hex string is precision-safe as-is. Documented in the file's package comment so a future change to the manifest doesn't regress it.
**Lesson:** Any integer wider than 2^53 that crosses a JSON boundary into a JavaScript or Godot client must be a string. Applies to anything wall-clock-nanosecond, most snowflake IDs, and `uint64` hashes truncated to <20 digits.

## HTTPRequest rejects relative URLs on Web export — 2026-04-16
**Symptom:** Web build of the M5.1 client logged `_parse_url` errors the moment it tried to fetch `/rounds`. Same code worked on desktop builds.
**Root cause:** Godot's `HTTPRequest.request()` on the Web platform requires an absolute URL (scheme + host). On desktop it tolerates relative paths because the HTTP client defaults host to `localhost`; the Web export's fetch polyfill does not.
**Fix:** Commit `311d16f`. [game/web_main.gd](game/web_main.gd) resolves `/rounds` and `/rounds/{id}/replay.bin` against `JavaScriptBridge.get_interface("window").location.origin` before calling `request()`. Gated behind `OS.has_feature("web")` so desktop runs stay origin-agnostic.
**Lesson:** `HTTPRequest` behavior diverges between Web and desktop in ways the editor can't catch. Always smoke-test the Web export end-to-end against a real server before declaring an HTTP-using feature done.

## Live WS stream silently dropping packets on close — 2026-04-17 / 2026-04-22
**Symptom:** Two related tail-drop issues surfaced during M5.3 live-streaming work:
1. WS client's `done_received` signal never fired on some rounds; playback hung instead of cleanly ending.
2. After fixing (1), disk replays still had exactly 1 more frame than the WS client received (e.g. 837 on disk, 836 over WS). Dismissed at the time as "within tolerance."

Both turned out to be real correctness bugs, not tolerance.
**Root cause:**
1. `LiveStreamClient._process` only drained `WebSocketPeer` while `get_ready_state() == STATE_OPEN`. When the server closed the socket cleanly, packets already sitting in the peer's inbound queue were silently discarded on the state transition to `STATE_CLOSED` before the next frame drained them.
2. Sim's [game/recorder/tick_streamer.gd](game/recorder/tick_streamer.gd) `send_done()` wrote DONE into the TCP send buffer and then *immediately* called `StreamPeerTCP.disconnect_from_host()`. Godot's disconnect issues a plain `close()` which can RST-drop whatever's still in the OS send queue, so the server (depending on scheduling) lost either the DONE frame or the final TICK. The server-side teardown in [server/stream/ingest.go](server/stream/ingest.go) (`MsgDone → return → defer round.Done() → conn.Close()`) already did the right thing; the sim's disconnect was fighting it.
**Fix:**
1. Commit `2b999bc`. [game/playback/live_stream_client.gd](game/playback/live_stream_client.gd) `_process` drains packets unconditionally each frame, independent of ready state. `_on_ws_closed` treats "close after HEADER seen without DONE" as implicit `end_stream()` so playback always terminates.
2. Commit `c474fc7`. Removed `disconnect_from_host()` from `send_done()` in [game/recorder/tick_streamer.gd](game/recorder/tick_streamer.gd). Socket tears down naturally when the sim process exits (spec mode) or when the server closes its end first. Smoke test 2026-04-22: 826 frames on disk, `HEADER=1 TICK=826 DONE=1` over WS — perfect match.
**Lesson:** Two traps in one: (a) "within tolerance" is a code smell when the tolerance is "exactly 1" — that's not jitter, that's a boundary condition. (b) On networked APIs, "close" and "flush" are two different operations and you rarely want to do the sender's close explicitly if the other side is already going to.

## WebSocketPeer default buffers drop tail of medium-sized streams — 2026-04-17
**Symptom:** Before the tail-drop fix above, even healthy rounds appeared to end ~10–30 frames early in the WS client's logs. Load-dependent: worse on larger rounds.
**Root cause:** Godot's `WebSocketPeer` defaults to a **64 KiB inbound buffer** and **2048 queued packets**. A full round streams ~500 KiB of back-to-back TICK frames (~800 frames × 600+ bytes). The peer was dropping frames under backpressure, not the network or the server.
**Fix:** Commit `2b999bc`. [game/playback/live_stream_client.gd](game/playback/live_stream_client.gd) sets `inbound_buffer_size = 4 MiB` and `max_queued_packets = 16384` on the peer before `connect_to_url`. Chosen to cover several worst-case rounds back-to-back without allocation pressure.
**Lesson:** Godot's networking primitives have conservative defaults sized for chat-style traffic. For anything that bursts more than ~100 packets or ~64 KiB between drains, bump both the byte buffer *and* the packet count — they're independent limits and either can silently drop.

## Godot / Jolt hangs with 0 CPU when PhysicsBody3Ds are nested — 2026-04-24
**Symptom:** First M6.1 Roulette smoke test hung indefinitely. Godot headless process sat at 5.5 MB memory with `0:00:00` CPU time, output file contained only the `COMMIT:` line — execution had reached the end of `main.gd`'s `_ready()` but never took a single physics tick. No script errors, no crash, no visible progress; kill-and-check was the only way to see state.
**Root cause:** `RouletteTrack._build_wheel()` built the wheel as an `AnimatableBody3D` (kinematic, rotating) with 24 `StaticBody3D` divider children — each divider a full nested PhysicsBody3D with its own CollisionShape3D + MeshInstance3D. Jolt (via Godot's physics server) apparently cannot reconcile 24 nested static bodies inside a kinematic parent at world-enter time: the physics thread gets wedged before the first step. The main thread then blocks on the physics thread and never schedules, which is why `tasklist` showed zero CPU time — the process wasn't running, it was deadlocked waiting.
**Fix:** Flatten the wheel to a single `AnimatableBody3D` with many `CollisionShape3D` + `MeshInstance3D` children at offset transforms — no nested bodies. [game/tracks/roulette_track.gd](game/tracks/roulette_track.gd) `_build_wheel()` now appends each divider's shape and mesh directly to `_wheel` with a pre-baked `Transform3D` positioning them around the rim. Smoke race went from "never completes" to 627-tick finish (~10.5s) on the first run post-fix.
**Lesson:** Multi-shape physics bodies in Godot attach *many CollisionShape3D children to one body*, not *many bodies nested inside a parent body*. The nested pattern often works at small N (it compiles, no script errors), but fails silently under load — exactly the kind of bug that won't show up on a 1-divider smoke test. Rule: one Body per thing that moves independently, many shapes per body is free.

