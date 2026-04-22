# Track 1 — Roulette

Part of the M6 track library. See [m6-tracks.md](../m6-tracks.md) for the master plan.

## Concept
Marbles are dropped onto a giant spinning roulette wheel, bounce through the numbered pockets, and fall off onto the felt layout below. The rest of the track is the table — rolling across the number grid, past chip-stack obstacles, to the finish at the dealer's rack.

## Signature hazard
**The spinning wheel.** A giant Godot `RigidBody3D` (or `AnimatableBody3D` driven kinematically — TBD) rotating at constant angular velocity. Marbles spawn at the rim, roll down into the numbered pockets, and get flicked off as the wheel rotates. Each marble's exit direction depends on which pocket it fell into and when it exits — built-in visual randomness that's actually deterministic from spawn + physics.

## Physics feel
Felt friction (grippy, slows marbles between hazards) + slight bounce on the wooden rail. Controlled and readable — marbles should track in predictable lines across the felt so viewers can pick their horse early.

## Layout sketch
_Fill in during M6.1._ Rough phases:
1. Spawn above the wheel → drop onto the rim → roll into pockets.
2. Pockets → wheel rotation flicks marbles onto the green felt layout.
3. Layout slope with chip-stack obstacles → finish rack at the far end.

## Physics materials
| Surface | Friction | Bounce | Notes |
| --- | --- | --- | --- |
| Wheel rim | TBD | TBD | Metal-on-metal feel |
| Pocket walls | TBD | TBD | Shallow bounces inside pockets |
| Felt layout | TBD | TBD | Grippy, predictable |
| Chip stacks | TBD | TBD | Wobbly — maybe RigidBody? |

## Camera notes
Start above the wheel for the drop-in shot. Mid-race overhead on the felt. Near-finish: low angle looking up the table toward the dealer rack.

## Acceptance criteria (M6.1)
- [ ] Race runs to completion with 20 marbles in ≤60s.
- [ ] Wheel rotation doesn't de-sync between sim and playback (deterministic initial angle + fixed angular velocity).
- [ ] Verifier passes against a recorded replay.
- [ ] Visually distinct from RampTrack (no grey boxes, no mistaking this for the dev track).
- [ ] Physics feel matches the "controlled / readable" target.

## Post-build notes
_Fill in after M6.1._
