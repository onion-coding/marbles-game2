# Progress

Running log of what's done, mapped against [PLAN.md](PLAN.md) milestones. Update when a task is completed or status changes — not a git-log replacement, a status-at-a-glance.

## Current milestone

**M5 — Web client + replay streaming.** Started 2026-04-16. M5.0 (archive HTTP API) landed: `GET /rounds`, `GET /rounds/{id}`, `GET /rounds/{id}/replay.bin` with ETag + immutable Cache-Control + Range support. Next: M5.1 Godot Web export + client scene that fetches from the archive API; M5.2 live WebSocket streaming (requires making the sim emit ticks in real-time vs. batch-writing at end).

## Done

### Planning / docs
- [PLAN.md](PLAN.md) written and rewritten once (Unity → Godot switch).
- [README.md](README.md) — repo overview, dev setup, how to run.
- [docs/fairness.md](docs/fairness.md) — provably-fair protocol sketch (targets M3).
- [docs/tick-schema.md](docs/tick-schema.md) — replay wire format sketch (targets M2).

### Tooling
- Godot 4.6.2-stable installed at `C:\Users\sergi\Godot\` (win64, no Hub).
- [.gitignore](.gitignore) configured for Godot (+ future C# / Mono).

### M1 scaffolding
- [game/project.godot](game/project.godot) — Jolt physics, 60Hz fixed tick, Forward+ renderer.
- [game/main.tscn](game/main.tscn) + [game/main.gd](game/main.gd) — programmatically builds:
  - Directional light + procedural sky.
  - Tilted ramp (-20° X) with side walls (static bodies, physics material with moderate friction and bounce).
  - 20 color-randomized marbles spawned at the uphill end so they roll the full length. Spawn-rail geometry is now derived from `RampTrack` constants (see "Game-feel hardening" below) rather than hardcoded.
  - Fixed camera framing the ramp from behind the high end.
- Headless `--import` and headless run smoke-tested: no script errors.

### M2 progress
- **M2.0 — carve-up** done. `main.gd` split into [game/physics/materials.gd](game/physics/materials.gd), [game/tracks/ramp_track.gd](game/tracks/ramp_track.gd), [game/sim/marble_spawner.gd](game/sim/marble_spawner.gd), [game/cameras/fixed_camera.gd](game/cameras/fixed_camera.gd).
- **M2.1 — finish-line detection** done. [game/sim/finish_line.gd](game/sim/finish_line.gd) — world-aligned Area3D at ramp's downhill end (marbles clear the ramp and drop through it); latches first crosser, emits `marble_crossed` + `race_finished` signals, exposes `get_crossings()` dict for the recorder to sample.
- **M2.2 — tick recorder** done. [game/recorder/tick_recorder.gd](game/recorder/tick_recorder.gd) — in-memory only; samples `global_position` and `global_basis.get_rotation_quaternion()` each `_physics_process`, flags ticks with finish crossings, and records a 1s tail after `race_finished` so playback has slowdown frames.
- **M2.3 — serializer v0** done. [game/recorder/replay_writer.gd](game/recorder/replay_writer.gd) + [game/playback/replay_reader.gd](game/playback/replay_reader.gd) implement the v0 header + frames format from [docs/tick-schema.md](docs/tick-schema.md) using raw f32 pos + quat (28 bytes/marble/tick). Recorder's `_finalize()` writes the file and runs a round-trip check comparing frame count and last-frame first-marble position. Seed-42 race → ~200KB for 5.9s; extrapolates to ~2MB/60s raw (M2.5 quantization can cut ~2×). Post-review cleanups: reader returns a plain Dictionary (nested `class Replay` tripped GDScript class registration), writer uses `DirAccess.make_dir_recursive_absolute` directly.

- **M2.4 — playback scene** done. [game/playback_main.tscn](game/playback_main.tscn) + [game/playback_main.gd](game/playback_main.gd) build a no-physics scene (ramp + camera + env, no RigidBodies), auto-load the latest `user://replays/*.bin`, and drive visual-only marbles via [game/playback/playback_player.gd](game/playback/playback_player.gd). Playback advances by wall-clock delta × `tick_rate_hz`, interpolates pos (`lerp`) + rot (`slerp`) between frames, emits `playback_finished` at the end. Color currently falls back to a deterministic HSV-by-index because the writer stubs `rgba=0` (see open question below).

### M3 progress
- **M3.0 — fairness primitives** done. [game/fairness/seed.gd](game/fairness/seed.gd) — 32-byte `server_seed` from `Crypto.generate_random_bytes`, SHA-256 commit hash, `derive_spawn_slots(server_seed, round_id, client_seeds, slot_count)` per [docs/fairness.md](docs/fairness.md) with deterministic linear-probe collision resolution. Guards empty client_seed to avoid `HashingContext.update` rejecting zero-length buffers.
- **M3.1 — slot-based spawns** done. [game/sim/spawn_rail.gd](game/sim/spawn_rail.gd) defines 24 slots across the ramp width at the uphill end with `Y_STAGGER` per drop-order so marbles don't overlap at spawn. [game/sim/marble_spawner.gd](game/sim/marble_spawner.gd) now takes `slots: Array` + optional `colors: Array` and drops the old random-jitter spawn.
- **M3.2 — commit/reveal in main** done. [game/main.gd](game/main.gd) generates `server_seed`, prints `COMMIT: round_id=... server_seed_hash=...` at start, derives slots, spawns, and prints `REVEAL: server_seed=...` at end.
- **M3.3 — replay format v2** done. `PROTOCOL_VERSION = 2` in [game/recorder/replay_writer.gd](game/recorder/replay_writer.gd); format now carries `server_seed`, `server_seed_hash`, `slot_count`, and per-marble `client_seed` + `spawn_slot`. Writer signature changed to a single `replay: Dictionary` arg. Reader rejects non-v2 files up front. Round-trip still verifies seed + slot fidelity alongside tick/pos.
- **M3.4 — verifier** done. [game/verify_main.tscn](game/verify_main.tscn) + [game/verify_main.gd](game/verify_main.gd) headless scene: loads the latest replay, checks `SHA-256(server_seed) == server_seed_hash`, re-derives all slots from public inputs, and confirms first-frame positions equal `SpawnRail.slot_position(slot, i)` for every marble. Exits with status 0/1.
- **M3.5 — byte order + test vectors** done (M3 hardening, 2026-04-16).
  - [docs/tick-schema.md](docs/tick-schema.md) §Byte order spells out the mixed-endianness rule (file/wire: little-endian; hash inputs: big-endian) so a verifier in another language can't get it silently wrong.
  - [docs/fairness.md](docs/fairness.md) §Spawn derivation now locks in the **marble-order invariant** (linear probing requires ascending `marble_index`; any implementation that iterates out of order is off-spec, not a different convention).
  - [scripts/gen_fairness_vectors.py](scripts/gen_fairness_vectors.py) is an independent Python reference that produces [docs/fairness-vectors.json](docs/fairness-vectors.json) (4 vectors: zero-seed baseline, empty client_seeds, forced-collision small slot_count, realistic 20-marble round). Vectors record `server_seed_hash`, every `_hash_marble` output, the derived spawn slots, and per-marble RGBA color.
  - [game/test_vectors_main.tscn](game/test_vectors_main.tscn) + [game/test_vectors_main.gd](game/test_vectors_main.gd) headless regression: reads the JSON, runs `FairSeed` against every vector, exits non-zero on any drift. All 4/4 pass on Godot 4.6.2-stable.
- **M3.6 — deterministic marble color** done (2026-04-16).
  - Protocol extension in [docs/fairness.md](docs/fairness.md) §Color derivation: `R=h[4], G=h[5], B=h[6], A=0xFF` where `h` is the `_hash_marble` output; packed as big-endian `u32 rgba` in the replay header.
  - [game/fairness/seed.gd](game/fairness/seed.gd) gained `derive_marble_colors()` + `color_to_rgba32()`. [game/main.gd](game/main.gd) derives and passes colors into `MarbleSpawner.spawn` and `TickRecorder.set_round_context`. [game/recorder/replay_writer.gd](game/recorder/replay_writer.gd) now writes the real `rgba` (no more stub `0`). [game/verify_main.gd](game/verify_main.gd) re-derives colors and rejects tampered replays. [game/playback/playback_player.gd](game/playback/playback_player.gd) already read `rgba` and uses it directly; the HSV-by-index fallback is now a legacy path only triggered if `rgba == 0`.
  - Closes the "Marble color plumbing" open question from the list below — no PROTOCOL_VERSION bump needed because the field already existed; only its contents changed.

### M4 progress
- **M4.0 — server Go module scaffolded** (2026-04-16). [server/go.mod](server/go.mod) at `github.com/onion-coding/marbles-game2/server`, Go 1.26. Laid out with flat package tree (`round/`, future `replay/`, `sim/`, `rtp/`). No external deps yet — stdlib-only until a real reason to add one.
- **M4.1 — round state machine** done (2026-04-16). [server/round/round.go](server/round/round.go) — pure phase machine `WAITING → BUY_IN → RACING → SETTLE`, no timers/goroutines. Enforces: commit hash available from construction, seed only readable in SETTLE, participants only addable in BUY_IN, out-of-order transitions rejected with `ErrWrongPhase`, monotonic phase-start timestamps. Participants get `MarbleIndex` assigned by join order to preserve the fairness order invariant (see docs/fairness.md). 8 tests in [server/round/round_test.go](server/round/round_test.go), all green; `go vet` clean.
- **M4.2 — Godot headless invoker** done (2026-04-16). Two sides:
  - **Godot:** [game/main.gd](game/main.gd) gained a "spec mode" — if `++ --round-spec=<path>` is on the CLI, it reads `{round_id, server_seed_hex, client_seeds[], replay_path, status_path}` JSON instead of generating a random seed, writes the replay to the supplied path, and emits a status JSON `{ok, winner_marble_index, finish_tick, server_seed_hash_hex, tick_rate_hz, replay_path}` when the race completes. [game/recorder/tick_recorder.gd](game/recorder/tick_recorder.gd) gained `override_output_path()` + `finalized(path)` signal. Editor/F5 path is unchanged — no spec → interactive mode with a fresh random seed.
  - **Go:** [server/sim/invoker.go](server/sim/invoker.go) — `Run(ctx, Request) (Result, error)` writes the spec, spawns Godot via `exec.CommandContext`, waits with timeout, parses the status. Windows backslash paths are normalized to forward-slash in JSON so they don't escape.
  - **Test:** [server/sim/invoker_test.go](server/sim/invoker_test.go) integration test spawns real Godot, runs a 20-marble race with a supplied seed, asserts the returned commit hash = `SHA-256(supplied_seed)` and the replay lands in the test's tempdir. Skipped unless `MARBLES_GODOT_BIN` + `MARBLES_PROJECT_PATH` env vars are set. Passes in ~8s (race ~7s + subprocess overhead).
- **M4.3 — replay store** done (2026-04-16). [server/replay/store.go](server/replay/store.go) — filesystem-backed, append-only audit log. Layout `<root>/<round_id>/{manifest.json, replay.bin}`. `Save` refuses to overwrite (`ErrRoundExists`) so audit data can't silently mutate; writes are atomic via temp-dir + rename so a crash mid-Save doesn't leave a half-populated round. `Manifest` records the reveal (`server_seed_hex`), the commit (`server_seed_hash_hex`), participants with client_seeds in marble_index order, the winner, protocol version, and SHA-256 of `replay.bin`. `Verify(id)` recomputes the replay SHA and rejects bit-rot / tampering (this is integrity-of-storage, separate from the fairness commit). 7 tests in [server/replay/store_test.go](server/replay/store_test.go): round-trip, overwrite-refusal, missing round, list-sorted-and-ignores-strays, verify-detects-tampering, manifest validation, SHA-256 lowercase hex.
- **M4.4 — RTP / payout hook** done (2026-04-16). [server/rtp/rtp.go](server/rtp/rtp.go) — `Settle(cfg, buyIns, winnerIndex) (prize, houseCut, err)`. RTP expressed in basis points (e.g. 9500 = 95.00%) so the math is integer-only and overflow-checked; rounding remainder goes to house ("player never paid more than displayed; house absorbs the dust"). Invariant `prize + houseCut == sum(buyIns)` enforced by tests. No currency type / wallet — this is the math API a real RGS would call with cents / satoshis / USDC-6. 8 tests in [server/rtp/rtp_test.go](server/rtp/rtp_test.go): standard RTP, 0% and 100% edge cases, rounding, freeroll participants, input validation, overflow guards, invariant check across 5 combos.
- **M4 coordinator** done (2026-04-16). [server/cmd/roundd/main.go](server/cmd/roundd/main.go) — single binary (~150 lines) that orchestrates one full round per iteration: generate seed → `round.New` → `OpenBuyIn` → synthesize N mock `player_NN` participants → `StartRace` → `sim.Run` (spawns Godot headless) → `FinishRace` with the reported winner → `rtp.Settle` → `store.Save` with the revealed seed and the replay.bin streamed from the sim's workdir. Smoke-tested with `--rounds=2 --marbles=20 --rtp-bps=9500 --buy-in=100`: both rounds produced complete audit entries on disk (`tmp/replays/<round_id>/{manifest.json, replay.bin}`), commit hashes matched reveals, payouts 1900/100 as expected. This is the M4 bar.

### Game-feel hardening (2026-04-16)
Bug surfaced watching the first windowed race: spawns overlapped, balls fell from a ~6.5m column, and the uphill edge was 0.1m from the spawn rail — ~half the marbles bounced off the ramp immediately. Fixed by:
- [game/tracks/ramp_track.gd](game/tracks/ramp_track.gd): `WALL_HEIGHT` constant (3.0, was 1.0) + `DECK_THICKNESS` + new static `surface_pos_at(local_z)` helper so downstream code can compute world positions from ramp geometry. `LENGTH` doubled 30 → 60 for more runway (test-only, real track library lives in M6).
- [game/sim/spawn_rail.gd](game/sim/spawn_rail.gd): Z and Y are now derived from `RampTrack.surface_pos_at(LENGTH/2 − UPHILL_MARGIN)` with a fixed `Y_CLEARANCE` above the surface. `Y_STAGGER` 0.35 → 0.12 (column ~2.3m instead of ~6.65m). Changing `LENGTH` or `ANGLE_DEG` now auto-moves the spawn rail correctly.
- [game/sim/finish_line.gd](game/sim/finish_line.gd) + [game/cameras/fixed_camera.gd](game/cameras/fixed_camera.gd): positions derived from ramp geometry instead of hardcoded.

### M5 progress
- **M5.0 — archive HTTP API** done (2026-04-16). [server/api/http.go](server/api/http.go) + [server/cmd/replayd/main.go](server/cmd/replayd/main.go) — small HTTP server wrapping the replay store. Routes: `GET /rounds` (ascending IDs), `GET /rounds/{id}` (manifest JSON), `GET /rounds/{id}/replay.bin` (raw bytes with `Accept-Ranges`, `ETag="<sha256>"`, `Cache-Control: public, immutable`). `http.ServeContent` handles Range requests so clients can resume. Permissive CORS (`Access-Control-Allow-Origin: *`) so Web-export clients from any origin can fetch — archive is read-only and public. 7 tests in [server/api/http_test.go](server/api/http_test.go): list-sorted, manifest fetch, streaming-with-ETag, 404 on missing, 400 on bad id, CORS headers + preflight, partial-content on Range. Live-tested against the real replay store from the M4 demo.
  - **Gotcha captured in code:** `GET /rounds` returns IDs as JSON **strings**, not numbers. Round IDs are unix-nanoseconds (~19 digits) which overflow JSON-number float64 precision (Godot `JSON.parse_string`, JavaScript `Number`). The hex-decoded `server_seed_hash_hex` in the manifest is similarly precision-safe; the manifest's `round_id` field is still a number because the Go-side consumers that read it (`roundd`, tests) use `encoding/json` which preserves uint64. If a Godot client ever needs to parse the manifest's round_id, switch that field to a string too.
- **M5.1 — network-sourced client scene + browser export** done (2026-04-16). [game/web_main.tscn](game/web_main.tscn) + [game/web_main.gd](game/web_main.gd) — same scene composition as `playback_main` (env + `RampTrack` + `FixedCamera` + `PlaybackPlayer`) but the replay source is the archive API instead of `user://replays/`. `HTTPRequest` → `/rounds` → pick latest ID → `HTTPRequest` → `/rounds/{id}/replay.bin` → `ReplayReader.read_bytes()` → `PlaybackPlayer.load_replay()`. [game/playback/replay_reader.gd](game/playback/replay_reader.gd) gained `read_bytes(PackedByteArray)` as a sibling of `read(path)`.
  - **Platform router:** [game/launcher.gd](game/launcher.gd) + [game/launcher.tscn](game/launcher.tscn) set as `run/main_scene` in [game/project.godot](game/project.godot). On Web feature → `web_main.tscn`; otherwise → `main.tscn` (sim). `change_scene_to_file` must be called via `call_deferred` because direct invocation in `_ready` trips the scene tree's "busy adding/removing children" guard.
  - **Web export:** HTML5 export templates (web_release.zip, web_nothreads_release.zip + debug variants) installed at `%APPDATA%\Godot\export_templates\4.6.2.stable\` from the official 4.6.2 `.tpz`. [game/export_presets.cfg](game/export_presets.cfg) defines preset `Web` with `thread_support=false` (broadest deployability — no need for COOP/COEP headers or `SharedArrayBuffer`). Export output lives in `tmp/web_export/`.
  - **Combined serving:** [server/cmd/replayd/main.go](server/cmd/replayd/main.go) gained `--static-root` so it serves both the archive API and the game bundle from one origin (no CORS juggling). Dev mode uses `Cache-Control: no-store` on static files so re-exports are visible without cache-busting.
  - **Godot Web gotchas captured in code:**
    - `HTTPRequest.request()` in Web rejects relative URLs (`/rounds`) with `_parse_url` error. Resolve to an absolute URL via `JavaScriptBridge.get_interface("window").location.origin`.
    - JSON numbers → float64 precision loss for 19-digit unix-nano IDs; fixed in M5.0 by serializing `round_ids` as strings.
  - Validated end-to-end in Firefox against replayd serving `tmp/web_export/` + `tmp/replays/`.

- **M5.2 — live WS streaming infrastructure** done (2026-04-16). Full pipeline: `sim → TCP → server hub → WS → browser-ready client`.
  - **Wire protocol** (identical sim↔server and server↔client, so the hub forwards bytes without re-encoding): `u8 msg_type; u32 le_len; payload`. Types `0x01 HEADER` (replay-v2 header bytes, no frame count), `0x02 TICK` (one frame), `0x03 DONE`. HEADER and TICK payloads are produced by [ReplayWriter.encode_header](game/recorder/replay_writer.gd) and [encode_frame](game/recorder/replay_writer.gd) — same encoders the archive replay file uses.
  - **Godot producer:** [game/recorder/tick_streamer.gd](game/recorder/tick_streamer.gd) (`StreamPeerTCP`, poll-for-connect with timeout, `set_no_delay=true`, non-fatal failures). [TickRecorder](game/recorder/tick_recorder.gd) gained a `set_streamer()` slot that emits HEADER at `track()` time, TICK on every `_physics_process`, DONE on `_finalize`. Disk write still happens unconditionally — the stream is an optional live side-channel, not the correctness path.
  - **Server infra:** [server/stream/stream.go](server/stream/stream.go) — pure in-memory `Hub` → `Round` → `Subscriber` tree with synchronous backfill under lock (late subs still get HEADER + all prior TICKs + live TICKs in order), slow subscribers kicked on full channel. [server/stream/ingest.go](server/stream/ingest.go) — TCP listener accepting sim connections, initial handshake is `u64 round_id` LE, message loop dispatches to `Round`. [server/stream/ws.go](server/stream/ws.go) — `ActiveListHandler` at `GET /live` (list of active round IDs, as strings), `WSHandler` at `GET /live/{id}` using `github.com/coder/websocket` (new dep). 7 unit tests in [stream_test.go](server/stream/stream_test.go) plus a full-stack integration test [integration_test.go](server/stream/integration_test.go) exercising TCP → WS round-trip.
  - **Glue:** [server/sim/invoker.go](server/sim/invoker.go) `Request.LiveStreamAddr` → spec file `live_stream_addr` → [game/main.gd](game/main.gd) reads and hands to `TickStreamer`. [server/cmd/roundd/main.go](server/cmd/roundd/main.go) gains `--live-stream-addr`. [server/cmd/replayd/main.go](server/cmd/replayd/main.go) gains `--stream-tcp` and two new routes (`/live`, `/live/{id}`).
  - **Dev smoke tool:** [server/cmd/streamtest/main.go](server/cmd/streamtest/main.go) — tiny Go WS client that polls `/live`, subscribes, counts messages. End-to-end run (replayd + roundd + streamtest) delivered 1 HEADER / 795 TICK / 1 DONE messages to the WS client for a ~13s round.

## In progress

- **M5.3 — Godot live client scene.** Needs a new `.tscn` that WebSocket-subscribes to `/live/{id}`, decodes the binary protocol (reuse `ReplayReader`-style logic or a new `LiveStreamClient` class), feeds a `PlaybackPlayer` variant that accepts streaming frames (vs. the current all-at-once `load_replay`). Also should pick "the round with the newest start time" from `/live` to mirror the archive client's UX.

## Not started

- **M2.5 — quantization pass (optional)** — swap raw floats for i24 mm + smallest-three quat per [docs/tick-schema.md:39-42](docs/tick-schema.md#L39-L42). Defer unless file size matters.
- **M5** — Godot Web client + WebSocket replay streaming.
- **M6** — track library (3–5 tracks) + polish / juice.

## Decisions locked in (since PLAN.md was rewritten)

- Engine: **Godot 4.6.2**, Jolt as 3D physics backend.
- Language: **GDScript** first. Revisit C# only if tick-serializer profiling forces it.
- Repo structure: **single Godot project** with multiple export presets (sim vs web), not two separate projects.
- Physics tick rate: **60 Hz** for M1. Wire tick rate TBD in M2 (see [docs/tick-schema.md](docs/tick-schema.md) open questions).

## Open questions (see PLAN.md §7 and doc stubs)

- Wire tick rate (60 vs 30 with interpolation).
- Tick byte layout (raw vs delta-encoded).
- Web bundle budget — Godot Web typically 15–30 MB; target <20 MB for casino iframes.
- Headless Jolt stability on Linux Dedicated Server export vs Windows editor.
- ~~**Marble color plumbing.**~~ Resolved 2026-04-16 in M3.6 — color derived from the same `_hash_marble` output as the slot, written to `rgba`, verified end-to-end.
