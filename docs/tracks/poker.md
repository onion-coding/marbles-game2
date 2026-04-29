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

## Post-build notes (final — 2026-04-29)

**Race time: 47.5s** (via slow-motion gravity zone, fine-tuned 2026-04-27). **SLOW_GRAVITY_ACCEL = 0.29 m/s²** (vs 9.8 default).

Course: 36×12m felt table tilted 8° around world Z. Marbles spawn directly above the dealer-shoe mouth at the −X end, fall into the shoe (a tilted U-channel that points along world +X), exit onto the felt, thread two staggered chip-stack rows, ride four flipping cards, and finish at a +X-end pot.

**Cards on a clock.** Each card's see-saw rotation is a sin-curve `θ(t) = amp * sin(2π t / period + phase)` seeded per-card from `Track._hash_with_tag("card_<i>")`. Replay-deterministic by construction — playback marbles are Node3Ds, not physics bodies, so clock-driven motion survives playback without re-simulation.

**Slow-motion gravity zone.** Area3D with `SPACE_OVERRIDE_REPLACE` gravity = 0.29 m/s². Initial design 0.25 (56.2s) fine-tuned to 0.29 to land 47.5s. Poker's obstacle density (4 cards + 7 chip rows + 3 wheels) is higher than Craps', so higher gravity per unit density. Tuned by physics-tuner agent. Fairness invariants intact — verifier PASS.

**OmniLight3D accent** (pendant warm) added in M6.7.

Layout fields tunable at the top of [game/tracks/poker_track.gd](../../game/tracks/poker_track.gd).
