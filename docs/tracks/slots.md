# Track 4 — Slots

Part of the M6 track library. See [m6-tracks.md](../m6-tracks.md) for the master plan.

## Concept
Marbles drop inside a giant slot machine. Spinning reels catch them in the window cutouts, the pulled lever flings them forward, coins cascade from a "jackpot" obstacle that blocks lanes, exit through the coin tray at the bottom.

## Signature hazard
**Spinning reels.** Three cylindrical `AnimatableBody3D` reels rotating on fixed axes (kinematic, not physics — driven by `_physics_process` angle update). Each has window cutouts that marbles can fall into and get carried around by; timing of your drop determines which "symbol" you land on and where you exit.

## Physics feel
Slippery chrome metal everywhere. Loud bouncy coins (high bounce, low friction on the cascade). Kinetic and fast — this is the "chaos" track.

## Layout sketch
_Fill in during M6.4._ Rough phases:
1. Spawn above the reels → marbles drop.
2. Pass through 3 spinning reels, each catches or deflects.
3. Land on a slope into the coin-cascade zone — a stream of `RigidBody3D` coins pouring from above that marbles have to punch through.
4. Lever mechanism kicks surviving marbles forward (one big whack).
5. Coin tray at the bottom as finish — big bowl-shaped collector.

## Physics materials
| Surface | Friction | Bounce | Notes |
| --- | --- | --- | --- |
| Reel cylinder | TBD | TBD | Slippery chrome |
| Reel window edges | TBD | TBD | Catches marbles, mild bounce |
| Lever | TBD | TBD | Rigid launcher |
| Coin cascade | TBD | TBD | The coins themselves — small RigidBody3D, mass << marble |
| Coin tray walls | TBD | TBD | Smooth, funnels to finish |

## Camera notes
Front view of the reels at start (the iconic slot-machine shot). Mid-race: inside-the-machine angle. Finish: top-down on the coin tray.

## Acceptance criteria (M6.4)
- [ ] Race runs to completion in ≤60s.
- [ ] Reel angles are deterministic (`angle = initial + speed * tick / tick_rate`).
- [ ] Coin cascade is replay-deterministic (initial state derives from `server_seed`, same as dice in Craps).
- [ ] Verifier passes.
- [ ] The reel catch-and-release is visually legible — viewer can see "that marble got carried around."

## Post-build notes (final — 2026-04-29)

**Race time: 41.6s** (via slow-motion gravity zone + 3 spinning chip wheels). **SLOW_GRAVITY_ACCEL = 2.0 m/s²** (vs 9.8 default).

Cabinet: 12m wide × 26m tall × 8m deep. Marbles spawn at SPAWN_Y=25 inside the cabinet and fall through three reels (y=19, 13, 7), then a chrome funnel converging from radius 5.5 to 1.5m, into a coin-tray basin at y=−0.5.

**Reels as toothed cylinders.** Each reel is an `AnimatableBody3D` rotating around world X. Five teeth + one missing "gate" slot (60° each) — timing the drop determines if a marble falls through cleanly. Gate phase per reel from `Track._hash_with_tag("reel_<i>")`, so each round has different alignments.

**3 spinning chip wheels.** Between reel pairs at Y = 41.5, 26.5, 11.5 (radius 2.2m, 6 amber pegs per wheel). Rotation rate and phase per-wheel seeded, same vocabulary as Craps/Poker. Adds kinetic visual energy without re-simulation risk (kinematic, not RigidBody3D).

**Slow-motion gravity zone.** Area3D with `SPACE_OVERRIDE_REPLACE` gravity = 2.0 m/s². Slots uses higher effective gravity than Craps/Poker because the 8 reel-gate cycles add significant waiting time. Tuned by physics-tuner agent: tried 0.3 (173s), 1.0 (63.9s), 1.5 (81.4s—gate resonance bump), 2.0 (41.6s ✓). Fairness invariants intact — verifier PASS.

**OmniLight3D accent** (cool-chrome blue + warm-tray fill) added in M6.7.

Layout fields tunable at the top of [game/tracks/slots_track.gd](../../game/tracks/slots_track.gd).
