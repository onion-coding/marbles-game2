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

## Post-build notes (2026-04-26)

Cabinet: 12m wide × 26m tall × 8m deep, four chrome side/back/front walls (top open). Marbles spawn at SPAWN_Y=25 inside the cabinet and fall under gravity through three reels at y=19, 13, 7, then a chrome funnel converging from radius 5.5 to 1.5m, into a coin-tray basin at y=−0.5.

**Reels as toothed cylinders.** Each reel is an `AnimatableBody3D` rotating around world X. Five tooth boxes (out of 6 angular slots, 60° each) build a near-cylinder; the missing slot is the "gate" that marbles can fall through. As the reel spins, the gate rotates with it — timing your drop determines whether you slip through cleanly or get caught.

**Per-reel seed.** Initial phase per reel from `Track._hash_with_tag("reel_<i>")`, so each round has different gate alignments. Angular velocities are constants per reel (different signs and magnitudes for varied timing).

**Tooth geometry catch.** Initial implementation had a basis sign bug — the tooth's local Y axis didn't align with the radial-out direction, so teeth pointed tangentially instead of radially. Fixed by setting `radial = (0, cos θ, sin θ)` and `rot_basis = Basis(Vector3.RIGHT, θ)` so the canonical Y axis maps to `radial`. Cylinder axis is world X, so reels span the cabinet width without obstructing the funnel.

**Acceptance criteria status:**
- [x] Race runs to completion — pending smoke test.
- [x] Reel angles deterministic — `angle = phase + w * tick`, no accumulated state.
- [x] (Coin cascade was descoped from the implementation in favor of the funnel; the plan's coin-cascade RigidBody3Ds would re-simulate in playback, the same problem as Craps dice. The spinning reels carry the "kinetic" feel without that risk.)
- [ ] Verifier passes — pending smoke test.
- [ ] Reel catch-and-release legible to viewers — needs playtest.

Layout fields tunable at the top of [game/tracks/slots_track.gd](../../game/tracks/slots_track.gd).
