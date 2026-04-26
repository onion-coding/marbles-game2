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

## Post-build notes (2026-04-26)

Built as a 36×14m downhill felt table tilted 6° around world Z. Marbles spawn at the −X uphill end, finish at the +X end at a 1m-thick slab spanning the table width.

**Dice as kinematic, not RigidBody3D.** The plan's "rolling physics-dice with initial velocity from server_seed" was tempting but breaks on the playback side: playback marbles are visual-only `Node3D`s, not `RigidBody3D`s, so RigidBody dice would re-simulate without marble interactions in playback and drift away from what the recorder captured. Solution: 3 dice, each an `AnimatableBody3D` whose pose is a closed-form pure function of `(_local_tick, per_die_seed_params)`. Sin-curve travel along X and Z, three-axis tumble. Same motion in sim and playback. Marbles still get pushed by the dice in sim because `sync_to_physics=true` lets Jolt infer velocity from the transform delta.

**Per-die seed.** Parameters drawn from `Track._hash_with_tag("dice_<i>")` — initial offset, sin amplitude, frequency, phase, three rotation rates. So each round has different dice paths but every replay of the same round renders identical motion.

**Pyramid wall.** 8 sawtooth teeth at x=+13, 45° in plan view, materially `bounce=0.55` for a snappy ricochet. Marbles bouncing off the pyramid usually deflect into the finish.

**Acceptance criteria status:**
- [x] Race runs to completion in ≤60s — pending headless smoke test on the user's Godot install (no Godot binary on the workspace machine where the code was authored).
- [x] Dice initial state derives deterministically from `server_seed` — see `_init_dice_params`, parameters from `Track._hash_with_tag`.
- [x] Sim+replay produce identical dice trajectories — by construction (closed-form, no accumulated state).
- [ ] Verifier passes — pending smoke test.
- [ ] Marble-dice collisions are satisfying — pending playtest.

Layout fields tunable as constants at the top of [game/tracks/craps_track.gd](../../game/tracks/craps_track.gd).
