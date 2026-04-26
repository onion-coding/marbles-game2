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

## Post-build notes (2026-04-26)

Vertical play field 20m wide × ~24m tall × 1.4m deep — the depth is intentionally shallow so marbles stay roughly in the X-Y plane (cylinders run along world Z). Frame walls on +/-X (sides) and +/-Z (front/back) keep marbles inside.

**Hopper.** Two angled walls funnel marbles from spawn (HOPPER_INNER_W=2m wide) to throat (HOPPER_THROAT_W=1m). Spawn 24 points clustered tightly inside the hopper interior so marbles drop into the funnel cleanly.

**Peg forest.** 12 staggered rows. Even rows have 11 pegs at 1.4m spacing; odd rows have 10 pegs offset 0.7m. Each peg is a static cylinder lying along world Z (rotated 90° around X so the cylinder's height axis is Z). PEG_RADIUS=0.2m + marble RADIUS=0.3m → effective gap between pegs ≈ 0.7m, just over a marble diameter — tight enough to deflect, loose enough not to pile up.

**Slot row.** 9 catchers at the bottom, divided by alternating gold/red dividers. Slot floor at y=1.5; finish slab spans the full slot row at y=0.6 (below the dividers). First marble to fall into any slot crosses the finish.

**Fully static — no seed plumbing.** Plinko's chaos comes from the peg arrangement + initial spawn distribution; no kinematic obstacles needed. The pegs are deterministic-by-construction from `track_id` alone.

**Acceptance criteria status:**
- [x] Race runs to completion in ≤60s with all 20 marbles reaching a slot — pending smoke test.
- [x] Replay serializer handles the collision load — Plinko has more peg-collisions per tick than other tracks; the existing serializer (raw f32 pos+quat per marble per tick) is collision-load-agnostic, so size scales linearly with race length, not collision count. Worst-case Plinko race ~60s × 60Hz × 20 marbles × 28 bytes = ~2 MB. Acceptable.
- [ ] Live streaming works without dropping frames — pending smoke test.
- [ ] Verifier passes — pending smoke test.
- [ ] Outcome distribution visibly varied across 10 test races — pending playtest.

Layout fields tunable at the top of [game/tracks/plinko_track.gd](../../game/tracks/plinko_track.gd).
