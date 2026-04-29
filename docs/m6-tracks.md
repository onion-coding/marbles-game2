# M6 — Casino-game track library + polish

Master plan for the MVP track library. Started 2026-04-22 after closing the pre-M6 audit (Track abstraction, bundle compression, live-stream tail fix).

## 1. Concept

Every track **is a casino game at marble scale** — the marbles are tiny players physically navigating real casino equipment. Not "themed rooms decorated like a casino"; the track geometry *is* the roulette wheel, the craps table, the slot-machine internals. Every hazard comes from a real game mechanic, so a viewer who's been in a casino instantly reads what they're looking at.

This replaces the earlier "5 environments (ice/lava/neon/...)" direction.

## 1.5. Slow-motion gravity architecture

Every casino track uses an Area3D with `SPACE_OVERRIDE_REPLACE` gravity to extend race times from the raw physics (~6-32s per track) into a 40-50s viewing window. Per-track gravity values tune the multiplication factor based on obstacle density:

| Track | SLOW_GRAVITY_ACCEL | Race time | Obstacle density | Notes |
| --- | --- | --- | --- | --- |
| Craps | 0.21 m/s² | 48.7s | 13 chip rows + 4 pins + 3 wheels | Fine-tuned 2026-04-27 from 0.20 to avoid dice-corner traps |
| Poker | 0.29 m/s² | 47.5s | 4 cards + 7 chip rows + 3 wheels | Higher gravity/density than Craps |
| Slots | 2.0 m/s² | 41.6s | 3 reels + 8 gate cycles + funnel | Higher gravity because reel gates add their own waiting time |
| Plinko | 3.5 m/s² | 46.3s | 120+ collision pegs | Steepest tuning; high per-marble collision overhead |
| Roulette | 5.0 m/s² | 47.4s | 6 chip-stack pegs + circuit + split | Gentlest tuning; fewest deflections |

Implementation: [game/tracks/<name>.gd](../game/tracks/) `_build_slow_gravity_zone()` creates a BoxShape3D Area3D covering the play volume, rotates with the track for vertical courses (Slots/Plinko/etc), gravity_direction stays world (0,-1,0). Smoke-tested per-track; fairness invariants (spawn_points, marble colors) unaffected — verifier PASS on all six.

## 2. Track list

Five casino-game tracks at marble scale, each with a signature hazard:

| Track | Signature hazard | Race time | Doc |
| --- | --- | --- | --- |
| **Roulette** | spinning wheel + helical descent + chip-stack pegs | 47.4s | [roulette.md](tracks/roulette.md) |
| **Craps** | kinematic dice obstacles + pyramid bouncer | 48.7s | [craps.md](tracks/craps.md) |
| **Poker** | clock-driven card see-saws + chip funnels | 47.5s | [poker.md](tracks/poker.md) |
| **Slots** | spinning reels + 3 kinematic chip wheels | 41.6s | [slots.md](tracks/slots.md) |
| **Plinko** | vertical peg forest (120+ pegs) + slot catchers | 46.3s | [plinko.md](tracks/plinko.md) |

**Final race times (post-tuning, 2026-04-29):** Craps 48.7s, Poker 47.5s, Slots 41.6s, Plinko 46.3s, Roulette 47.4s. Ramp (untuned) 13.8s. All casino tracks land in the 40-50s window via slow-motion gravity tuning.

## 3. Track selection policy

**Deterministic-random with no immediate repeat.** For round N with round_id R:

```
candidate = hash(R) mod len(tracks)
if candidate == previous_track_id:
    candidate = (candidate + 1) mod len(tracks)
track_id = candidate
```

The hash is part of the fairness chain (so `track_id` is derivable from public inputs, like spawn slots already are). No operator input, no RNG state beyond `server_seed`. "No back-to-back" is enforced by the server between rounds, not in the derivation — from a fairness standpoint, each round's track is a pure function of the round seed; the anti-repeat step is a separate monotonic rule the server applies.

## 4. Replay format v3

`PROTOCOL_VERSION` bumps **2 → 3** as the first M6 task. Changes:

- New header field `track_id: u8` after `slot_count`. Value 0–4 maps to the enum in [`game/tracks/track_registry.gd`](../game/tracks/track_registry.gd) (to be added).
- No frame-format changes — this is a header-only bump.
- The verifier (`game/verify_main.gd`) gains a `TrackRegistry.instance(track_id)` call to know which track class to use when re-deriving spawn positions.
- The Go replay manifest (`server/replay/store.go`) gains a `TrackID` field — stays numeric (single-byte, no JSON precision concern).

Docs affected: [docs/tick-schema.md](tick-schema.md), [docs/fairness.md](fairness.md). Both updated in M6.0.

## 5. Track abstraction evolution

The current [`game/tracks/track.gd`](../game/tracks/track.gd) base class was minimal on purpose — geometry-shape-agnostic accessors for a single S-curve `RampTrack`. For the casino-game tracks we need:

- Each track as its own **`.tscn` scene** with a root script extending `Track`.
- Scene is free to parent arbitrary `StaticBody3D`, `RigidBody3D` (for moving obstacles like dice or the roulette wheel), `Area3D`, particles, lighting.
- Base class shrinks to the **fairness-relevant interface only**:
  - `spawn_points() -> Array[Vector3]` — must be stable across runs (fairness).
  - `finish_area_transform() -> Transform3D` — FinishLine uses this.
  - `camera_bounds() -> AABB` — FixedCamera / free-cam use this.
  - `physics_materials() -> { marble, track }` — per-track tuning.
- Anything track-specific (moving obstacles, event hooks, cinematic triggers) lives in the per-track scene's root script, not the base.

`RampTrack` will be retired at M6-end or kept as a "tutorial/default" if useful.

## 6. Camera

**Preferred:** per-player free camera on their screen (orbit + zoom, locked to the track bounds). Each viewer can follow their own marble, jump to cinematic angles, rewind on replay.

**Fallback** if free-cam proves too fiddly for the Web client: auto cinematic cuts (start shot, mid-race wide, finish closeup) — same on every viewer's screen.

Out of scope for M6: matchmaker-synced director-cam broadcast (post-MVP feature).

## 7. Polish focus

Per user direction: **graphics + physics feel**, not trails/impact FX.

- Track materials need to read clearly on stream (high-contrast, no visual noise behind marbles).
- Physics tuning is per-track — each has its own `PhysicsMaterial` values for marble + track. The goal is each track should "feel" distinct when you watch marbles roll on it (slippery metal vs grippy felt vs bouncy pinball rubber).
- Lighting per track to support the casino mood — warm golds in Roulette/Poker, cool chrome in Slots, saturated rainbow in Plinko.

Sound is user-sourced (not in the engine's M6 scope).

## 8. Build order (✓ completed 2026-04-29)

- ✓ **M6.0 — Scaffolding** (2026-04-23). Replay format v3 + `TrackRegistry` + track-selection policy. `RampTrack` becomes `track_id=0`.
- ✓ **M6.1 — Roulette** (2026-04-24). Helical-channel design v3 landed; earlier flat-tilted v1/v2 designs archived.
- ✓ **M6.2 — Craps** (2026-04-26). Kinematic dice (closed-form trajectories seeded per-die).
- ✓ **M6.3 — Poker** (2026-04-26). Clock-driven card see-saws (replay-deterministic sin-curves).
- ✓ **M6.4 — Slots** (2026-04-26). Spinning reels + 3 kinematic chip wheels.
- ✓ **M6.5 — Plinko** (2026-04-26). Vertical peg forest (fully static, no seed plumbing).
- ✓ **M6.6 — Camera** (2026-04-26). [FreeCamera](../game/cameras/free_camera.gd) orbit + pan + zoom; fixed cam fallback for sim/headless.
- ✓ **M6.7 — Polish** (2026-04-26). OmniLight3D per-track accent lighting (warm gold, cool chrome, magenta+cyan, etc).
- ✓ **Slow-motion gravity tuning** (2026-04-26 → 2026-04-29). Per-track Area3D gravity values to land races in 40-50s window.
- ✓ **Camera framing & fog** (2026-04-27). `camera_pose` per-track, fog tuning for readability on stream.
- ✓ **Interactive mode UX** (2026-04-27 → 2026-04-28). FreeCamera in interactive; `--track=<name>` flag; HUD marble numbers + STANDINGS; random casino track default.
- ✓ **RGS server-hosted rounds** (2026-04-28 → 2026-04-29). `POST /v1/rounds/start` endpoint; `--rgs=<url>` client flow.

## 9. Acceptance bar (✓ completed 2026-04-29)

"MVP demo-ready for a pretend operator":
- ✓ All 5 tracks rotate correctly per round (deterministic-with-no-back-to-back in `selectTrack()`).
- ✓ Verifier passes on a replay from each track (fairness invariants intact across slow-motion gravity tuning).
- ✓ Web export (compressed bundle 6.35 MB) loads any archived round and plays back cleanly.
- ✓ Live streaming works for each track (no frame drops observed in smoke tests).
- ✓ Bundle under 20 MB wire budget (actual 6.35 MB, 5.6× under target).
- ✓ Each track has distinct physics feel: grippy felt (Roulette), clinky bounces (Craps), card catapults (Poker), kinetic reels (Slots), pure collision chaos (Plinko).
- ✓ All five have intentional, readable geometry — no MoS-style tilted planes or placeholder boxes.

## 10. Open questions

- Moving/spinning obstacles and strict determinism: the sim records per-tick positions of *every* RigidBody (not just marbles) via [`TickRecorder`](../game/recorder/tick_recorder.gd) today. That should already capture dice / reel positions in the replay, but the header currently only tracks marbles. Decision needed in M6.0: do we extend the header to name the non-marble bodies, or does the client reinstantiate the track scene (which deterministically reproduces the obstacle layout from `track_id` alone) and *overlay* recorded marble positions? The latter is simpler and probably right — track scenes are deterministic-by-construction from `track_id`.
- Replay file size: Plinko at 60Hz for 50s with 20 marbles hits ~2 MB uncompressed. Acceptable for archive; live streaming is already fine. If this becomes a problem, M2.5 quantization lands.
