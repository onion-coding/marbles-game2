# Track 2 — Craps

Part of the M6 track library. See [m6-tracks.md](../m6-tracks.md) for the master plan.

## Concept
Marbles traverse a giant craps table. Pass line / don't pass grid as terrain, wooden rail as bouncy wall, pyramid rubber along the back rail, stickman's chip piles as obstacles. The hazard: **actual pairs of rolling dice** (d6 RigidBody3Ds) moving around the table you have to dodge.

## Signature hazard
**Rolling physics-dice.** Two or three d6-shaped RigidBody3Ds with initial velocity/angular velocity derived deterministically from `server_seed`. They tumble across the table during the race, kicking marbles off-course. Because they're recorded in the replay (per-tick pos+rot for every RigidBody), their paths are fixed per replay — same replay = same dice roll every time.

## Physics feel
Medium grip (felt on the table proper, rubber on the rail), satisfying clinky bounces when marbles hit the dice or the pyramid rail. Slower-feeling than Roulette — this is the "deliberate" track.

## Layout sketch
_Fill in during M6.2._ Rough phases:
1. Spawn at the "come" end of the table → drop onto the felt.
2. Navigate the pass-line grid (letters as low walls?) with dice tumbling through.
3. Chip-stack obstacles mid-table.
4. Back rail pyramid rubber → finish at the stickman's position.

## Physics materials
| Surface | Friction | Bounce | Notes |
| --- | --- | --- | --- |
| Table felt | TBD | TBD | Grippy, predictable |
| Wooden rail | TBD | TBD | Low bounce |
| Rubber pyramid | TBD | TBD | High bounce — characteristic craps feel |
| Dice | TBD | TBD | Heavy, clinky |
| Chip stacks | TBD | TBD | Same as roulette for consistency |

## Camera notes
Low-angle sweep along the table length. Close-up on the dice collision area mid-race. Overhead at finish.

## Acceptance criteria (M6.2)
- [ ] Race runs to completion in ≤60s.
- [ ] Dice initial state derives deterministically from `server_seed` (document the derivation).
- [ ] Sim+replay produce identical dice trajectories.
- [ ] Verifier passes.
- [ ] Marble-dice collisions are satisfying — neither "marble passes through dice" nor "marble gets stuck on dice corner" in playtest.

## Post-build notes
_Fill in after M6.2._
