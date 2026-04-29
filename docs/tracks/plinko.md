# Track 5 — Plinko

Part of the M6 track library. See [m6-tracks.md](../m6-tracks.md) for the master plan.

## Concept
Giant vertical plinko wall. Marbles drop from the top into a forest of pegs, bouncing randomly (read: deterministically from initial position and physics, but visually chaotic), landing in numbered slot catchers at the bottom. The finish is the slot row — first marble to fully settle into any slot wins.

This is the "most marble-race-on-stream DNA" track — the format already matches what viewers have seen on Plinko / Pachinko streams.

## Signature hazard
**The peg forest.** Hundreds of static cylindrical pegs arranged in a staggered grid, no moving parts needed. Chaos comes entirely from compound collisions as marbles fan out. Tune peg spacing vs marble diameter so it's not a guaranteed pile-up but also not a free-fall.

## Physics feel
Pure pinball rubber — high bounce, low friction. Every peg-hit is a clean deflection. The track with the loudest audio footprint (all those rapid peg clicks).

## Layout sketch
_Fill in during M6.5._ Rough phases:
1. Spawn in a funnel at the top — marbles drop one-by-one through a hopper (this serializes their release to match staggered spawn-drop behavior from RampTrack).
2. Peg field — ~10 rows × 15 pegs, staggered. Dimensions tuned so a typical run takes ~30s from top of field to bottom.
3. Slot row — 10–15 numbered catchers at the bottom. First marble to fully settle into any slot wins.
4. Optional: a "walls close in" funnel below the pegs so marbles are forced into the slots rather than bouncing back out.

## Physics materials
| Surface | Friction | Bounce | Notes |
| --- | --- | --- | --- |
| Pegs | TBD | TBD | High bounce — 0.7+ restitution for pinball feel |
| Outer walls | TBD | TBD | Similar bounce, contain the field |
| Slot catchers | TBD | TBD | Grippy inside so marbles settle |

## Camera notes
Iconic shot: front-facing view of the whole peg wall at race start. Maybe a picture-in-picture zoom on the lead marble. Finish: close-up on the slot row.

## Acceptance criteria (M6.5)
- [ ] Race runs to completion in ≤60s with all 20 marbles making it to a slot (no indefinite pinging in the peg field).
- [ ] Replay serializer handles the collision load without frame-size blowup — measure on-disk size, confirm it's in the same order of magnitude as other tracks.
- [ ] Live streaming works without dropping frames.
- [ ] Verifier passes.
- [ ] Peg spacing tuned so outcome distribution is visibly varied across 10 test races (no one marble winning every time).

## Post-build notes (final — 2026-04-29)

**Race time: 46.3s** (via slow-motion gravity zone). **SLOW_GRAVITY_ACCEL = 3.5 m/s²** (vs 9.8 default).

Vertical play field 20m wide × ~24m tall × 1.4m deep — the depth is intentionally shallow so marbles stay roughly in the X-Y plane (cylinders run along world Z). Frame walls on +/-X (sides) and +/-Z (front/back) keep marbles inside.

**Hopper.** Two angled walls funnel marbles from spawn (2m wide) to throat (1m). Spawn 24 points clustered tightly so they drop cleanly.

**Peg forest.** 12 staggered rows (11 pegs in even rows, 10 in odd rows, offset 0.7m). Each peg is a static cylinder along world Z. PEG_RADIUS=0.2m + marble RADIUS=0.3m → ~0.7m gaps, tight enough to deflect but not pile up.

**Slot row.** 9 catchers at the bottom with gold/red dividers. Finish slab at y=0.6 (below dividers); first marble to any slot wins.

**Fully static geometry.** No kinematic obstacles — chaos is pure collision entropy from peg arrangement + initial spawn. Deterministic-by-construction from `track_id` alone.

**Slow-motion gravity zone.** Area3D with `SPACE_OVERRIDE_REPLACE` gravity = 3.5 m/s². Tuned by physics-tuner agent: 1.0 (130.7s), 3.5 (46.3s ✓). Plinko has more collision overhead per marble than Craps/Poker, so gravity tuning is steeper. Fairness invariants intact — verifier PASS.

**OmniLight3D accent** (magenta + cyan rim) added in M6.7.

Layout fields tunable at the top of [game/tracks/plinko_track.gd](../../game/tracks/plinko_track.gd).
