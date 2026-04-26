# Track 3 — Poker

Part of the M6 track library. See [m6-tracks.md](../m6-tracks.md) for the master plan.

## Concept
Marbles cross a poker table. Giant face-up cards serve as flip-bridges — marble crosses one → card flips → marble gets catapulted forward. Chip-stack columns as drop-through funnels. Dealer shoe shoots marbles out the spout at the start. Flop/turn/river cards reveal mid-race (visual flourish, not structural).

## Signature hazard
**Card-flip catapults.** Each card is an `AnimatableBody3D` that starts face-up. When a marble enters a trigger Area3D on the card's surface, the card rotates 180° over ~0.3s, catapulting the marble off the opposite edge. Deterministic: triggered by first-marble-on-card per replay tick, visible in recorded body state.

## Physics feel
Smooth card surfaces (very low friction while riding a card mid-flip) + felt slopes between cards (grippy). Mixed — the anticipation of "which cards will flip in time" is the drama.

## Layout sketch
_Fill in during M6.3._ Rough phases:
1. Spawn inside the dealer shoe → shot out the spout onto the felt.
2. Row of chip-stack funnels — marbles drop through the holes to a lower level.
3. Card-flip bridges zigzag across a gap to the community-cards area.
4. Flop/turn/river cards (visual only) line the far side.
5. Finish at the pot (chip pile).

## Physics materials
| Surface | Friction | Bounce | Notes |
| --- | --- | --- | --- |
| Felt slopes | TBD | TBD | Same felt material as Roulette/Craps |
| Card surface | TBD | TBD | Slippery — marbles slide fast |
| Chip stack walls | TBD | TBD | Medium grip |
| Dealer shoe | TBD | TBD | Smooth, launches at fixed velocity |

## Camera notes
Tracking shot following lead marble through the first card flips. Close-up on a flip in progress is the photogenic moment. Pull back for the pot finish.

## Acceptance criteria (M6.3)
- [ ] Race runs to completion in ≤60s.
- [ ] Card flips are deterministic per replay (triggered-by-first-contact logic records state consistently).
- [ ] No "marble stuck mid-flip" edge cases in 20 test runs.
- [ ] Verifier passes.
- [ ] A flip-catapult is visually satisfying — marble gets clear air.

## Post-build notes (2026-04-26)

Course: 36×12m felt table tilted 8° around world Z. Marbles spawn directly above the dealer-shoe mouth at the −X end, fall into the shoe (a tilted U-channel that points along world +X), exit onto the felt, thread two staggered chip-stack rows, ride four flipping cards, and finish at a +X-end pot.

**Cards on a clock, not on contact.** The original plan had cards as Area3D-triggered flips: marble enters → card flips. That logic doesn't survive replay because playback marbles are Node3D visuals, not RigidBody3Ds, so they don't fire Area3D events. A clock-driven flip is replay-stable by construction: each card's see-saw rotation is `θ(t) = amp * sin(2π t / period + phase)` with `period` and `phase` drawn from `Track._hash_with_tag("card_<i>")`. Sim and playback see identical card poses.

**See-saw geometry.** Each card is an `AnimatableBody3D` placed at its pivot; the box collider is offset half a card length along +X so the card sticks out as a paddle that rotates around its hinge. `sync_to_physics=true` so a marble riding the card gets the kinematic velocity transferred when the card flips.

**Catch:** `var pivot_world := _tilt_basis * pivot_local` then `card.global_transform = Transform3D(_tilt_basis, pivot_world)`. The card's basis includes the table tilt so the card hinges around the table's Z axis, not the world Z axis. When the sin curve drives `theta`, we compose `_tilt_basis * Basis(Vector3.FORWARD, theta)` so the see-saw happens in the table's tilted frame.

**Decorative community cards.** Flop/turn/river are `MeshInstance3D` children of a no-collision `Node3D` parented to the track. Visible but never affect physics.

**Acceptance criteria status:**
- [x] Race runs to completion — pending smoke test.
- [x] Card flips deterministic per replay — by construction.
- [ ] No "marble stuck mid-flip" edge cases — needs 20-run playtest.
- [ ] Verifier passes — pending smoke test.
- [ ] Flip-catapult visually satisfying — needs playtest.

Layout fields tunable at the top of [game/tracks/poker_track.gd](../../game/tracks/poker_track.gd).
