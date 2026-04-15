# Progress

Running log of what's done, mapped against [PLAN.md](PLAN.md) milestones. Update when a task is completed or status changes — not a git-log replacement, a status-at-a-glance.

## Current milestone

**M3 — seeded spawns + provably-fair.** Bar hit (2026-04-15): server_seed → SHA-256 commit → seeded spawn slots → race → reveal → third-party verifier re-derives slots + confirms first-frame positions match `SpawnRail`. Only M2.5 quantization remains optional. Next: M4 round state machine + server glue.

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
  - 20 color-randomized marbles spawned with a fixed seed (42) for M1 repeatability, released from the uphill end (Z=+13..+15, Y≈5.8) so they roll the full length.
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

## In progress

_Nothing — M3 bar hit; next is M4._

## Not started

- **M2.5 — quantization pass (optional)** — swap raw floats for i24 mm + smallest-three quat per [docs/tick-schema.md:39-42](docs/tick-schema.md#L39-L42). Defer unless file size matters.
- **M4** — round state machine + [server/](server/) glue.
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
- **Marble color plumbing.** Writer stubs `rgba=0` because color was random-per-spawn in the sim and isn't surfaced to the recorder header. Fix either in M2.5 (thread color through `MarbleSpawner.spawn` return) or M3 (seeded spawns make color deterministic anyway).
