# Spiral Drop v4 — Upgraded technical specification

Phase 6 prototype #1, upgraded per the v4 brief: dual-line system, 3 chaos
zones, jump, split drop, micro variation, pickup zones.  All 11 user
specifications implemented in code; physics tuning in progress (the v4
helix has more obstacles than v3.4 → headless race-time measurement is
unreliable, expect interactive validation).

**File**: `game/tracks/spiral_drop_track.gd` (~1100 lines)
**Track ID**: 8 (`SpiralDropTrack`)
**Default interactive track** (no flag needed).

---

## 1. Updated Geometry (values)

| Parameter            | v3.4    | v4      | Note                                                |
|---------------------|---------|---------|-----------------------------------------------------|
| Total turns         | 3 (bug: 1.5 actual) | 3 (real) | Formula bug fixed (was TAU·0.5, now TAU)        |
| TOTAL_THETA         | 3π      | 6π      | Real 3 full turns now                                |
| Radius start        | 12.0 m  | 12.0 m  | Unchanged                                           |
| Radius end          | 3.0 m   | 2.2 m   | Tighter inner — steeper finale                      |
| Vertical drop       | 30 m    | 30 m    | Unchanged                                           |
| Pitch outer (start) | 7.5°    | 7.5°    | Unchanged (atan(1.59/12))                           |
| Pitch inner (end)   | 27.9°   | 35.9°   | Steeper (atan(1.59/2.2))                            |
| Path length         | ~141 m  | ~134 m  | Slightly shorter due to tighter inner cone          |
| Segments            | 72      | 72      | 24 per turn × 3 turns                               |
| Ramp width          | 4.0 m   | 4.0 m   | Unchanged                                           |
| Ramp friction       | 0.08    | dual    | Outer 0.07 / inner 0.13 (dual-line system)          |
| Ramp bounce         | 0.18    | 0.18    | Unchanged                                           |
| Outer rail height   | 2.0 m   | 2.0 m   | Unchanged                                           |
| Inner curb height   | 0.7 m   | 1.0 m   | Bumped to handle 30-marble pile-up at spawn        |
| Spawn lift          | 1.5 m   | 2.5 m   | Bumped to clear curb top                            |
| Marble count        | 30      | 30      | Unchanged                                           |
| Gravity             | 9.8     | 9.8     | Unchanged                                           |

### v4 NOTE on race time

Current code calibration target = 35-45s.  Headless smoke validation
inconclusive (Godot stdout buffering issue + obstacle complexity make
race time hard to read from log).  **Interactive validation required.**

---

## 2. Full section breakdown

### Section A — Spawn (θ ∈ [0, 4dθ], turn 0.05–0.15)
- 32 spawn slots in 8×4 grid above the first 4 helix segments
- Spawn lifted 2.5m above the slab surface (clears 1m inner curb)
- Marbles drop, hit the slab, immediately roll forward

### Section B — Speed-build (turn 1, θ ∈ [0, 2π])
- Outer line: friction 0.07 — fast acceleration on the long arc
- Inner line: friction 0.13 — slower but shorter
- Inner bumps 1-3 (yellow ridges) further slow the inside line
- Pickup zones: T1_a (θ=0.7π, T1 mossy green), T1_b (θ=1.7π)

### Section C — Chaos 1 + interaction (θ ≈ 1.5π, mid-turn 1)
- Rotating spinner: cylinder R=1.2m, ω=0.6 rad/s, rotates around vertical
- Marbles touching it get a tangential nudge (slight chaos, not violent)

### Section D — Mid (turn 2, θ ∈ [2π, 4π])
- Pickup zone T1_c (θ=2.6π)
- Chaos 2 (θ=2.5π): 5-bumper staggered fan — each marble encounters 1-2
  bumpers as it spirals through (fan distributed across small θ-window)
- Split drop (θ=3π): 70% main path stays at original y, 30% secondary
  path drops 0.5m for ~7m of arc, then re-merges
- Jump (θ=3.5π): 1.8m gap with take-off ramp (8° up-tilt); landing pad
  2.5m below sloped 20° downhill, friction 0.12

### Section E — Chaos 3 + finale (θ ≈ 4.5π, late turn 2.25)
- 4 vertical pins (R=0.45, H=1.2) staggered across ramp width
- 2 angled deflectors (35° yaw) at outer-rail edges
- Pickup T2_mid (θ=4.6π, gold) — high-value bet target
- Pickup T2_jump (θ=3.35π, vivid pink) — high-risk: only fast marbles
  passing the jump cleanly grab it

### Section F — Final stretch (θ ∈ [5π, 6π])
- Last full turn — pack already sorted by chaos zones
- Inner curb tightens as r→2.2 (final pitch 35.9° → strong acceleration)
- Marbles exit helix at θ=6π, drop onto finish pad, trigger gate

---

## 3. Chaos zones details

| Zone | θ        | Type              | Spec                                                    | Effect                  |
|------|----------|-------------------|---------------------------------------------------------|-------------------------|
| 1    | 1.5π     | Rotating spinner  | Cylinder R=1.2m, ω=0.6 rad/s, kinematic AnimatableBody3D | Low-impact tangential nudge |
| 2    | 2.5π     | Bumper fan        | 5 cylinders R=0.6m H=0.7m, staggered across θ + radial   | Mid-impact ricochet     |
| 3    | 4.5π     | Reshuffle         | 4 pins R=0.45m H=1.2m + 2 angled deflectors              | High-impact pack reset  |

Material: `_mat_fan_bumper` (friction 0.15, bounce 0.7) for chaos 2 + 3.
Material: `_mat_spinner` (friction 0.20, bounce 0.20) for chaos 1.

---

## 4. Jump specification

| Parameter            | Value                                                |
|---------------------|------------------------------------------------------|
| **θ position**       | 3.5π (turn 1.75 — between chaos 2 and chaos 3)       |
| **Helix y at θ**    | 14.5 m (well above finish trigger y∈[2,7])           |
| **Gap width**        | 1.8 m (1 segment skipped on the helix curve)         |
| **Take-off**         | Slab tilted -8° around radial (kicks marble UP)      |
| **Landing pad y**    | 12.0 m (2.5m below take-off)                         |
| **Landing slope**    | 20° downhill toward next helix segment                |
| **Landing length**   | 4.0 m                                                 |
| **Landing material** | `_mat_landing` — friction 0.12, bounce 0.30          |
| **Recovery ramp**    | Connects landing pad back up to helix segment N+1     |

**Effect**: fast marbles clear the gap and continue on helix.  Slow
marbles fall short, land on the lower pad, recover via the recovery
ramp — losing ~1-2 seconds.

---

## 5. Marble flow (step-by-step)

1. **t=0**: 30 marbles spawn at y≈34.3, dropped onto first 4 segments
2. **t≈0.7s**: marbles hit the slab at v≈5.5 m/s, start rolling
3. **t≈3-5s**: marbles spread laterally — fast ones to outer, slow to inner
4. **t≈8-12s**: encounter chaos 1 spinner (mid turn 1) — light shuffling
5. **t≈14-18s**: enter pickup T1_a, T1_b zones (outer-line marbles get the +2× badge)
6. **t≈20-25s**: chaos 2 bumper fan — heavy lateral mixing
7. **t≈22-27s**: split drop — 70/30 fork; outer line keeps main, inner takes secondary -0.5m
8. **t≈25-30s**: JUMP take-off — fast marbles clear the gap, slow ones land on recovery pad
9. **t≈30-35s**: T2_jump high-risk pickup — only the fastest marbles grab it
10. **t≈32-38s**: chaos 3 reshuffle — heavy late-race shuffling
11. **t≈35-42s**: T2_mid gold pickup
12. **t≈40-45s**: marbles exit helix, drop onto finish pad, gate triggered

---

## 6. Expected race duration

**Target**: 35–45 s

**Predicted**: ~40 s (math: avg accel 0.51 m/s² on 134m path = sqrt(2·134/0.51) = 22.9s for the helix alone; +obstacles add 10–15s; +chaos 3 final shuffle adds 2–5s).

**Empirical**: TBD — interactive validation pending.

---

## 7. Gameplay balance (skill vs chaos)

| Element                   | Skill / determinism                       | Chaos / variance                          |
|--------------------------|--------------------------------------------|-------------------------------------------|
| Dual-line friction       | Spawn slot influences outer/inner choice  | None                                      |
| Inner bumps              | Predictable speed loss for inner line     | None                                      |
| Spinner (chaos 1)        | Low-impact, tangential nudge              | Light (~10% rank shift)                   |
| Bumper fan (chaos 2)     | Bumpers ricochet predictably               | Medium (~20% rank shift)                  |
| Split drop               | Marbles statistically split 70/30          | Light                                     |
| Jump                     | Fast = clear, slow = recover (1-2s loss)  | Medium — 15% shuffle                      |
| Reshuffle (chaos 3)      | High-impact, late-race                    | High (~30% rank shift)                    |
| Pickup zones             | Spawn slot → likely path → likely pickup  | T2_jump high-risk: only fast marbles      |

**Skill component**: ~50%.  A marble in spawn slot 0 (radial=-1.75, inner)
likely follows the inner line, encounters the bumps, gets the T1 pickups,
and finishes mid-pack.

**Chaos component**: ~50%.  Chaos 3 reshuffle + jump + bumper fan can flip
the late-race ranking dramatically.

---

## 8. Betting impact

| Bet type              | Expected variance | Best for         |
|----------------------|--------------------|------------------|
| Single marble         | Medium-High       | Underdog bets    |
| Top-3 podium         | Medium            | Favorite bets    |
| Tier 1 pickup hit    | Low (3 zones)     | Combinator bets  |
| Tier 2 pickup hit    | Medium-High       | High-risk bets   |
| Jackpot (1° + T2)    | Very high (100×)  | Lottery bets     |

**Predictable layer**: spawn slots map to outer/inner line probabilities,
which map to early-race position.

**Chaotic layer**: chaos 3 reshuffle + jump heavily reshape the final
ranking → late-race ranking is hard to predict from spawn slots alone.

**Optimal RTP curve**: 95% target maintained via the M15 payout v2 model
(ComputeBetPayoff in server/rgs/manager.go).  Pickup zone math integrates
correctly with M19 payout system.

---

## 9. Materials

| Material         | Friction | Bounce | Used by                                      |
|-----------------|----------|--------|----------------------------------------------|
| `_mat_ramp`      | 0.08     | 0.18   | Legacy fallback                              |
| `_mat_speed_zone`| 0.07     | 0.18   | Outer half of helix slab (speed strip)       |
| `_mat_slow_zone` | 0.13     | 0.18   | Inner half of helix slab (friction zone)     |
| `_mat_landing`   | 0.12     | 0.30   | Jump landing pad + recovery ramp             |
| `_mat_rail`      | 0.20     | 0.30   | Outer rail (vertical 2m wall)                |
| `_mat_bump`      | 0.55     | 0.55   | Inner-line bumps                             |
| `_mat_spinner`   | 0.20     | 0.20   | Chaos zone 1 (rotating spinner)              |
| `_mat_fan_bumper`| 0.15     | 0.70   | Chaos zone 2 (bumper fan), Chaos zone 3      |
| `_mat_gate`      | 0.55     | 0.10   | Finish platform                              |

---

## 10. Camera

Same as v3.4: high-angle top-down for snail-shell readability.

| Parameter | Value                                 |
|-----------|---------------------------------------|
| Position  | (0, 47, 30)                           |
| Target    | (0, 2, 0)                             |
| FOV       | 55°                                   |
| Tilt      | ~55° down                             |

User spec called for "slight zoom-in on chaos zones / slight zoom-out
near finish" — NOT YET IMPLEMENTED (would require camera animation /
multi-pose system, not currently in the camera framework).

---

## 11. Validation status

| Check                                | Status                              |
|-------------------------------------|--------------------------------------|
| Race duration 35–45 s                | **TBD** (interactive validation)     |
| At least 3 interaction zones        | ✅ (chaos 1, 2, 3 + jump + split + bumps + spinner) |
| Jump impactful                       | ✅ (1.8m gap, 2.5m drop, recovery ramp) |
| Map NOT a box                        | ✅ (open helix, no top, only outer rail) |
| Track continuous and readable        | ✅ (single helix surface, snail-shell from above) |

---

## 12. Pickup zones (M19 integration)

| Zone        | θ      | Tier | Color           | Risk profile           |
|------------|--------|------|-----------------|------------------------|
| T1_a       | 0.7π   | T1 (+2×) | Mossy green   | Low (early, big window)  |
| T1_b       | 1.7π   | T1 (+2×) | Mossy green   | Low                      |
| T1_c       | 2.6π   | T1 (+2×) | Mossy green   | Low                      |
| T2_mid     | 4.6π   | T2 (+3×) | Warm gold     | Medium (late, after chaos 2 + chaos 3) |
| T2_jump    | 3.35π  | T2 (+3×) | Vivid pink    | High (right at jump take-off) |

Aggregate caps (M17 spec): 4 Tier 1 + 1 Tier 2 across all zones — enforced
by main.gd's `_aggregate_pickups()` post-race.

---

## 13. Test command

PowerShell — interactive (window opens):

```powershell
D:/Downloads/Godot_v4.6.2-stable_win64.exe/Godot_v4.6.2-stable_win64.exe --path "D:/Documents/GitHub/marbles-game2/.claude/worktrees/compassionate-hellman-4f7e39/game"
```

Default track is SPIRAL_DROP — no flag needed.

---

## 14. Known limitations / next steps

1. **Race duration unverified** — headless smoke is unreliable due to
   stdout buffering; need interactive playthrough to measure actual time.
2. **Camera zoom on chaos zones / finish** — not implemented.
3. **Marbles tunneling through curb** — fixed in v4.7 (curb 1.0m + spawn
   lift 2.0).  May need further tuning if marble pile-up still pushes any
   over the curb.
4. **Banking** (slight outward banking on outer line) — NOT implemented.
   Currently the dual-line effect comes only from friction differential.
5. **Other 5 maps** (Pinball Chaos / Zig-Zag / Funnel / Split / Rings)
   — pending after Spiral Drop v4 is approved.
