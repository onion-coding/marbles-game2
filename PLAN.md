# Marbles Game — Development Plan

A 3D physics-based marble race game, built for integration with online casinos (crypto-first, tier-1 ready). This document covers **development scope only** — business, licensing, and operator-sales strategy are out of scope here.

## 1. Game concept

- **Genre:** 3D physics marble race.
- **Round format:** First-to-finish-line race, up to **20 marbles per round**.
- **Entry:** Players pay to spawn a marble into a **random spawn slot** at the top of the track during a fixed buy-in window. No skill input during the race.
- **Round cadence:** Fixed-interval rounds (e.g. 60s cycle):
  1. `WAITING` — idle between rounds
  2. `BUY_IN` — buy-in window open (~30s), marbles spawn as players pay
  3. `RACING` — buy-in locked, physics simulation runs, clients replay
  4. `SETTLE` — winner confirmed, payouts dispatched, replay archived
- **Win condition:** First marble to cross the finish line wins the pot (minus configurable house edge).
- **Feel goal:** "Satisfying physics" — weighty collisions, clean bounces, readable camera. No RNG-feeling jank.

## 2. Architecture

**Server-authoritative headless simulation; clients render a recorded replay.**

```
 ┌───────────────────┐       ┌──────────────────────┐       ┌─────────────────┐
 │ Headless Godot    │──────▶│ Tick recorder +      │──────▶│ Replay store    │
 │ sim (Jolt)        │       │ state serializer     │       │ (seed → ticks)  │
 └───────────────────┘       └──────────────────────┘       └─────────────────┘
           ▲                            │
           │ seed + marbles             ▼
 ┌───────────────────┐       ┌──────────────────────┐
 │ Round state       │       │ Replay stream API    │
 │ machine           │       │ (WS: tick frames)    │
 └───────────────────┘       └──────────────────────┘
           ▲                            │
           │                            ▼
 ┌───────────────────┐       ┌──────────────────────┐
 │ Provably-fair     │       │ Godot Web client     │
 │ commit/reveal     │       │ (renders from ticks) │
 └───────────────────┘       └──────────────────────┘
```

### Key decisions

- **Engine:** Godot 4 (4.4+) with **Jolt** as the 3D physics backend (Godot's default from 4.4). Single Godot project with two export presets: a **Dedicated Server** build (headless sim) and a **Web** build (HTML5 / WASM client).
- **Determinism model:** We do **not** require cross-platform bit-deterministic physics. The server runs the sim once, records per-tick state (position + rotation of every marble, plus event markers), and streams that recording to clients. Clients render by interpolating recorded state — they never re-simulate. This sidesteps floating-point divergence entirely.
- **Physics config:** Fixed timestep via `_physics_process` (Project Settings → Physics → Common → Physics Ticks Per Second). High-quality concave mesh colliders on tracks (trimesh), convex/sphere on marbles. Tuned physics materials (bounce/friction) per track.
- **Replay delivery:** Tick data (compressed positions/rotations) streamed to clients over WebSocket. Client renders in Godot Web with local camera control (free look, follow-cam, cinematic cuts).
- **Fairness:** Server-seed hash is published **before** buy-in closes. Player marbles' spawn positions are derived from `hash(server_seed || round_id || per-player-client-seed || marble_index)`. Server seed revealed in the `SETTLE` phase; anyone can re-derive spawn order and verify.
- **Language:** **GDScript** as default (fast iteration, no build step, Godot-native). Open to selectively dropping into **C#** (.NET) for CPU-hot paths like tick serialization if profiling demands it. Avoid mixing until there's a measured reason.

## 3. MVP scope

The MVP is **the physics simulation + the client renderer + the scaffolding needed to make it casino-ready later.** No real money, no operator integration, no cosmetics economy.

### In scope for MVP

1. **Record-and-replay physics core**
   - Fixed-timestep Jolt sim, seeded RNG for spawn positions.
   - Per-tick state recorder (marble id, position, rotation, velocity, finish-line crossings).
   - Seed → replay-bytes pipeline.
2. **Provably-fair commit/reveal module**
   - Server-seed generation, pre-round hash publication, post-round reveal.
   - Client-seed mixing hook (even if unused in MVP).
3. **Round state machine**
   - `WAITING → BUY_IN → RACING → SETTLE` transitions, timers, event emission.
4. **RTP / house-edge configuration hook**
   - Stubbed payout calculator that reads an `rtp` config value. Mocked payouts; signals certification-readiness to operators later.
5. **Replay store**
   - Every round persisted as `{seed, tick_data, result, participants}` for audit / dispute / regulator review.
6. **Game client (Godot Web export)**
   - Loads replay stream, renders race in 3D with decent camera work.
   - UI: round timer, buy-in button (stub), marble list with player name + color, winner announcement.
7. **Track library: 3–5 hand-crafted tracks**
   - Rotated per round. Each tuned for fair finish-time distribution and physics stability.
8. **Marble identity**
   - Random color + player name label. No skins, no cosmetics.

### Explicitly out of scope for MVP

- Real-money integration, wallet, KYC
- Operator/aggregator API (RGS layer) — comes after MVP
- Cosmetic system, skins, NFTs, player accounts
- Procedural tracks
- Server-rendered video streaming
- Mobile native builds (Web only)
- Certification submissions (GLI-19 etc.)

## 4. Repo layout (proposed)

Single Godot project with multiple export presets. This keeps the tick-schema, seed derivation, and physics config in one place — no cross-project sharing pain.

```
marbles-game/
├── game/                      # Godot 4 project root (contains project.godot)
│   ├── physics/               # Physics config, materials, shared constants
│   ├── tracks/                # 3-5 track scenes + colliders
│   ├── sim/                   # Marble controller, spawn logic, finish detection
│   ├── recorder/              # Tick recorder, serializer
│   ├── playback/              # Tick deserializer, interpolation (client-side)
│   ├── cameras/               # Follow-cam, free-cam, cinematic cuts (client-side)
│   ├── ui/                    # HUD, buy-in, winner, marble list (client-side)
│   ├── fx/                    # Trails, impact sparks, sounds (post-MVP juice)
│   ├── fairness/              # Seed derivation, hash helpers (shared)
│   ├── tick_schema/           # Wire format definitions (shared)
│   └── export_presets.cfg     # Dedicated Server + Web presets
├── server/                    # Backend glue (Go) — round SM, seed mgmt, replay store, WS fan-out
│   ├── round/                 # pure round state machine (WAITING/BUY_IN/RACING/SETTLE)
│   ├── sim/                   # Godot headless invoker — subprocess + JSON spec/status glue
│   ├── replay/                # replay store (per-round audit trail on disk)
│   ├── rtp/                   # house-edge config hook (stubbed payout calc)
│   └── api/                   # WS for clients, internal REST for sim trigger
├── ops/                       # Dockerfiles, local compose, CI
└── docs/
    ├── fairness.md            # How provably-fair works here
    ├── tick-schema.md         # Wire format for replay data
    └── integration.md         # (future) operator integration spec
```

Notes on the single-project choice:
- The sim (headless) and client (web) run the **same scene tree** but with different autoloads enabled: sim autoloads the recorder, client autoloads the playback driver and disables physics on marble nodes.
- An alternative is **two Godot projects with a shared submodule** for `tick_schema` / `fairness`. Revisit if the single-project approach causes coupling problems, e.g. client bundle bloated by sim-only code.

## 5. Build order (milestones)

### M1 — Physics prototype (single-player, no server)
- One track, 20 marbles, Jolt physics, fixed physics tick rate.
- Get the **feel** right: physics materials, collider quality, tick rate, camera.
- Bar: "looks satisfying" when watched locally in the editor.

### M2 — Deterministic record & playback
- Tick recorder in sim, serializer to compact binary.
- Playback scene reads the file and renders identically (visually — not bit-exact).
- Bar: save a race → replay it from file → outcome matches visually.

### M3 — Seeded spawns + fairness module
- Seed → spawn positions derivation.
- Commit/reveal flow (server prints hash, runs race, reveals seed; verify script confirms).
- Bar: given revealed seed, anyone can reproduce the exact recorded race.

### M4 — Round state machine + server glue
- `WAITING/BUY_IN/RACING/SETTLE` states with timers.
- Mock buy-in endpoint, replay store writes per round.
- RTP hook in payout stub.
- Headless Godot sim triggered by server, replay bytes returned.
- Bar: server runs rounds on a loop, each round leaves a complete audit trail.

### M5 — Web client + replay streaming
- Client (Godot Web build) connects over WS, receives tick frames, renders.
- Basic HUD, marble-name labels, winner screen.
- Bar: open browser → watch live rounds with no desync.

### M6 — Casino-game track library + polish
- **Master plan:** [docs/m6-tracks.md](docs/m6-tracks.md). Per-track stubs under [docs/tracks/](docs/tracks/).
- 5 tracks, each is a real casino game at marble scale: **Roulette / Craps / Poker / Slots / Plinko**. See [docs/m6-tracks.md §2](docs/m6-tracks.md#2-track-list).
- Selection policy: deterministic-random (`hash(round_id) mod 5`) with no back-to-back repeats.
- Replay format v3 adds a `track_id` header field so the verifier knows which track to re-derive against.
- Polish focus: graphics + physics feel per track. Per-player free-cam in the Web client (fallback: cinematic cuts). Sound is user-sourced.
- Scope and acceptance bar in [docs/m6-tracks.md §9](docs/m6-tracks.md#9-acceptance-bar). Timeline: take-time-until-satisfying, not a deadline.

## 6. Post-MVP (what this scaffolding is setting up)

- RGS backend + operator API (REST/WebSocket per common aggregator specs).
- Real-money wallet integration, session tokens, rollback/timeout handling.
- RTP configurable per operator; jackpot / pot-boost mechanics.
- Certification work (RNG testing, GLI-19 submission, MGA/Curaçao pathway).
- Cosmetics, operator-branded marble skins, leaderboards.
- More tracks; possibly procedural.

## 7. Open questions to resolve during M1

- **Target tick rate** for the recorder (60Hz? 30Hz interpolated on client?) — bandwidth vs smoothness tradeoff.
- **Wire format** for tick data — delta-encoded floats vs quantized fixed-point. Godot's `StreamPeerBuffer` + `compress()` gives us a decent baseline.
- **Web bundle budget** — Godot Web exports are typically 15–30MB compressed (engine + WASM + assets). Aim < 20MB for casino-iframe friendliness; strip unused modules via custom engine build if we blow past it.
- **Headless Jolt stability** — confirm no platform-specific oddities between editor runs and the Linux Dedicated Server export; this is where platform physics divergence would show up first.
- **GDScript vs C#** — start GDScript-only. Revisit only if tick-serializer profiling shows GDScript is the bottleneck; switching costs are low at M1 scale.
