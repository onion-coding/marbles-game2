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

## Post-build notes
_Fill in after M6.4._
