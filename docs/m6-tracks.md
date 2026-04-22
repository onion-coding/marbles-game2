# M6 — Casino-game track library + polish

Master plan for the MVP track library. Started 2026-04-22 after closing the pre-M6 audit (Track abstraction, bundle compression, live-stream tail fix).

## 1. Concept

Every track **is a casino game at marble scale** — the marbles are tiny players physically navigating real casino equipment. Not "themed rooms decorated like a casino"; the track geometry *is* the roulette wheel, the craps table, the slot-machine internals. Every hazard comes from a real game mechanic, so a viewer who's been in a casino instantly reads what they're looking at.

This replaces the earlier "5 environments (ice/lava/neon/...)" direction.

## 2. Track list

Five tracks, each with a one-word memorable name and a signature hazard:

| # | Track | Signature hazard | Physics feel | Stub |
| --- | --- | --- | --- | --- |
| 1 | **Roulette** | spinning wheel pockets, chip-stack obstacles | felt friction, slight bounce — controlled | [tracks/roulette.md](tracks/roulette.md) |
| 2 | **Craps** | rolling physics-dice obstacles, rail bumper | medium grip, clinking bounces | [tracks/craps.md](tracks/craps.md) |
| 3 | **Poker** | card-flip catapults, chip funnels, dealer shoe | smooth card surfaces + felt slopes | [tracks/poker.md](tracks/poker.md) |
| 4 | **Slots** | spinning reel catchers, pulled lever, coin cascades | slippery metal, loud and kinetic | [tracks/slots.md](tracks/slots.md) |
| 5 | **Plinko** | vertical peg forest, numbered slot catchers | pure pinball bounce, high chaos | [tracks/plinko.md](tracks/plinko.md) |

Average race target: **~50 seconds** per track.

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

## 8. Build order

- **M6.0 — Scaffolding.** Replay format v3 + `TrackRegistry` + track-selection policy in `roundd`. No new tracks yet; `RampTrack` becomes `track_id=0` for continuity until it's retired. Acceptance: existing sim/verify/playback paths work end-to-end against v3.
- **M6.1 — Roulette.** First real casino track. Builds the scene template everyone copies. Acceptance: race runs cleanly to finish, physics feel distinct from RampTrack.
- **M6.2 — Craps.** Introduces **moving obstacles** (the dice are RigidBody3Ds). Opens the "how does fairness handle dice rng?" question — resolved by deriving dice initial state from `server_seed` and letting physics do the rest.
- **M6.3 — Poker.** Introduces **marble-triggered dynamic geometry** (card flips on Area3D enter). Tests whether triggered geometry breaks replay determinism (sim-recorded is the source of truth, so it shouldn't, but worth an explicit smoke test).
- **M6.4 — Slots.** Introduces **kinematic animated obstacles** (reels spinning on a clock). Similar story to dice but simpler — no per-tick RNG.
- **M6.5 — Plinko.** Tests the replay serializer under heavy collision load. Also the "pure marble-race-on-stream" vibe check.
- **M6.6 — Camera.** Per-player free-cam in the Web client; auto cuts as fallback path.
- **M6.7 — Pass across all five.** Physics tuning, material polish, lighting pass, acceptance check against §9.

Between each track: commit, playtest headless + desktop, write the per-track doc's "post-build notes" section.

## 9. Acceptance bar

"MVP demo-ready for a pretend operator":
- All 5 tracks rotate correctly per round.
- Verifier passes on a replay from each track.
- Web export (with compressed bundle) loads any archived round and plays back cleanly.
- Live streaming works for each track.
- Bundle still under 20 MB wire budget.
- Each track has a distinct physics feel that's obvious to a first-time watcher.
- No placeholder-looking geometry — all five look intentional.

## 10. Open questions

- Moving/spinning obstacles and strict determinism: the sim records per-tick positions of *every* RigidBody (not just marbles) via [`TickRecorder`](../game/recorder/tick_recorder.gd) today. That should already capture dice / reel positions in the replay, but the header currently only tracks marbles. Decision needed in M6.0: do we extend the header to name the non-marble bodies, or does the client reinstantiate the track scene (which deterministically reproduces the obstacle layout from `track_id` alone) and *overlay* recorded marble positions? The latter is simpler and probably right — track scenes are deterministic-by-construction from `track_id`.
- Replay file size: Plinko at 60Hz for 50s with 20 marbles hits ~2 MB uncompressed. Acceptable for archive; live streaming is already fine. If this becomes a problem, M2.5 quantization lands.
