---
tags: [product, game-design, map]
status: concept
map: Casino Drop (Plinko)
---

# Map: Casino Drop (Plinko)

> [!info] How to use this file
> Self-contained map spec. Key payout rules and design targets are summarised inline. Full derivations in [[Payout System]] and [[Map Design Principles]].

---

## Concept

A vertical casino plinko map. All 30 balls spawn at the top and fall through an asymmetric, creative peg arrangement — not a grid. Three mechanical events punctuate the descent: **The Tube** (a rare shortcut), **The Bumper** (a 3-way launcher), and **The Multiplier Zone** (mid-map slot reveal). After the multiplier zone, balls continue falling to the finish line. Both the multiplier and finish position matter and stack.

**Why this map works:**
- Three distinct dramatic moments in one race: tube steal, bumper chaos, multiplier reveal
- Multiplier hits at the midpoint — the second half of the race is still a real contest
- The peg arrangement is readable without being predictable — you can follow your ball
- Recognisable plinko DNA but nothing like players have seen before

**Race duration:** ~40–50 seconds

---

## Payout rules (summary)

**Finish position payouts** (fixed, every race):
- 1st place: 9× their stake
- 2nd place: 4.5× their stake
- 3rd place: 3× their stake
- 4th–30th: 0 (lose their stake)

**Map multiplier** (hit in the multiplier zone, mid-race):
- Multiplier ≥ 1× triggers **consolation**: the ball gets M× its stake regardless of where it finishes. Even last place walks away with something.
- Multiplier = 0.5× is a **penalty**: no consolation floor. If you hit 0.5× and finish 4th–30th, you still get 0. If you finish top-3, your finish payout is halved.
- Stacking is **multiplicative**: map multiplier × finish multiplier. Example: 3× map + 1st place = 3 × 9 = **27× their stake**.

**House target:** 96% RTP (house keeps 4%). Finish payouts consume 55% of stakes, leaving 41% budget for the multiplier zone.

---

## Map Layout (top → bottom, 2D side view)

```
────────────────────────────────────────────
 SPAWN — all 30 balls released from the top
────────────────────────────────────────────

 SECTION 1 — THE DESCENT  (0–15s)
 ─────────────────────────────────
 Peg arrangement: asymmetric clusters, not a grid.
 Diagonal rows, open void sections, dense zones.
 Natural funnel — board wide at top, narrower mid.

 ◄ THE TUBE ►
   Narrow neon-lit slot in the left wall.
   Only reachable by far-left ball trajectories.
   Ball enters → warp flash → reappears 5 rows below.
   ~0–3 balls reach it per race. Pure shortcut, no risk.
   Visible to all spectators at all times.

────────────────────────────────────────────

 SECTION 2 — THE BUMPER  (15–20s)
 ──────────────────────────────────
 A 3-zone launcher pad — casino flipper aesthetic.
 When a ball lands on the pad it gets sent into one
 of three fixed trajectories based on incoming angle:

   Zone A (centre) → fast lane, better multiplier position
   Zone B (left)   → moderate speed, mid-board
   Zone C (right)  → slower, pushed toward outer edge

 All three zones are always active. Trajectory is
 determined by physics — where the ball happens to land.
 Creates a visible "sorting" moment: spectators see their
 ball get flung and know immediately which path it's on.

────────────────────────────────────────────

 SECTION 3 — THE MULTIPLIER ZONE  (20–30s)
 ───────────────────────────────────────────
 7 glowing casino-style slots across the board.
 Every ball hits exactly one slot — no gaps to fall through.
 Slot machine reel aesthetic. Number flashes on contact.

 Slot layout (see distribution table below):

  ┌──────┬──────┬──────┬──────┬──────┬──────┬──────┐
  │  3×  │  2×  │  1×  │ 0.5× │  1×  │  2×  │  3×  │
  └──────┴──────┴──────┴──────┴──────┴──────┴──────┘
   edge L  rare   less   most   less   rare  edge R
                  rare   common rare

 Pegs funnel most balls toward the 0.5× centre (penalty).
 Values step up gradually toward the edges: 0.5→1→2→3×.
 Edge slots only reachable via Bumper Zone C — roughly
 1 ball hits 3× per race on average.

────────────────────────────────────────────

 SECTION 4 — THE CHASE  (30–50s)
 ─────────────────────────────────
 Sparser pegs — faster movement, finish race begins.
 Multiplier is locked. Finish position now the only variable.

 Two obstacles:
   • Angled deflector barrier — nudges straggling balls
     back into the pack (subtle catch-up mechanic)
   • Narrow gap 5s before finish — splits into a fast
     lane and a slow lane for the final stretch

────────────────────────────────────────────
 FINISH LINE
────────────────────────────────────────────
```

---

## Casino Visual Identity

| Element | Visual treatment |
|---|---|
| Pegs | Casino chip shapes — cylindrical, neon-rimmed, lit from inside |
| The Tube | Neon pipe (gold/pink glow). Brief warp flash when ball enters and exits |
| Bumper | Metal flipper pad with casino felt texture. Zone A/B/C marked on the pad |
| Multiplier slots | Slot machine reel panels — number and glow colour pop on ball contact |
| Board background | Dark felt, gold trim border, soft casino floor lighting |
| Ball trail | Short light trail as it falls — colour changes to match multiplier hit |
| Camera | Fixed 2D side view, slight depth cue on pegs for 3D feel without rotation |

---

## Multiplier distribution

> [!warning] Exact ball counts depend on peg physics simulation. Verify with sim before launch.

### Slot tiers explained

- **0.5× (penalty):** ball gets half its normal finish payout if top-3, nothing if 4th–30th. No consolation floor. This is where most balls land — it's what makes the bonus slots mathematically possible.
- **1× (consolation floor):** ball gets its stake back no matter what. If it finishes top-3, it gets its finish payout instead (1× doesn't reduce anything for top-3 — it's neutral).
- **2× / 3× (bonus):** ball gets M× its stake guaranteed, regardless of finish. If it also finishes top-3, stacks multiplicatively (e.g. 3× + 1st = 27×).

### Slot layout (7 slots, symmetric)

```
┌──────┬──────┬──────┬──────┬──────┬──────┬──────┐
│  3×  │  2×  │  1×  │ 0.5× │  1×  │  2×  │  3×  │
└──────┴──────┴──────┴──────┴──────┴──────┴──────┘
 edge L                centre                edge R
 rare                  most balls            rare
```

### Ball distribution (~30 balls per race)

| Slot | Value | ~Balls | Notes |
|---|---|---|---|
| 1 — edge L | 3× | ~0–1 | Zone C only. Jackpot. |
| 2 | 2× | ~1–2 | Zone B/C |
| 3 | 1× | ~3–4 | Outer Zone A / Zone B |
| 4 — centre | 0.5× | ~19 | Zone A. Most balls. |
| 5 | 1× | ~3–4 | Outer Zone A / Zone B |
| 6 | 2× | ~1–2 | Zone B/C |
| 7 — edge R | 3× | ~0–1 | Zone C only. Jackpot. |

On average per race: ~1 ball hits 3×, ~3 hit 2×, ~7 hit 1×, ~19 hit 0.5×.

### Budget verification

The house targets 96% RTP. Finish position payouts (9×+4.5×+3×) use up exactly 55% of stakes — fixed. That leaves **41% of stakes (= 12.3 units across 30 balls)** as the multiplier zone budget.

| Tier | ~Balls | Extra payout per ball | Total |
|---|---|---|---|
| 0.5× penalty | 19 | −0.275 | −5.23 |
| 1× consolation | 7 | +0.90 | +6.30 |
| 2× consolation | 3 | +2.35 | +7.05 |
| 3× consolation | 1 | +3.80 | +3.80 |
| **Net** | **30** | | **+11.92 of 12.3 budget** ✓ |

→ ~95% RTP. Shifting 1–2 balls from 0.5× to 1× after simulation will close the gap to 96%.

---

## Payout examples

| Scenario | Calculation | Total |
|---|---|---|
| Hits 0.5×, finishes 4th | 0 (penalty, no consolation) | **0×** |
| Hits 0.5×, finishes 1st | 0.5 × 9 | **4.5×** |
| Hits 1×, finishes 4th | consolation floor | **1×** |
| Hits 2×, finishes 3rd | 2 × 3 | **6×** |
| Hits 3×, finishes 1st | 3 × 9 | **27×** — dream scenario |
| Tube + 3×, finishes 1st | 3 × 9 (tube is positional, not a multiplier) | **27×** |

---

## Map design principles

Every Marbles map must balance two competing forces: the leader should have a real advantage (otherwise 1st place means nothing), but back-of-pack balls need a credible path to catch up (otherwise the race is over in 10 seconds and nobody watches).

**Calibration targets for this map:**
- Ball leading at the midpoint (after the multiplier zone) should win **30–50%** of the time
- A ball in the back 10 should still produce a 1st-place finish **5–15%** of the time
- Both unverified — need simulation

| Principle | How this map addresses it |
|---|---|
| **Front-runner advantage** | Faster balls reach Bumper Zone A → funnel to centre slots → keep finish position lead. The leader benefits from momentum. |
| **Catch-up mechanic** | The Bumper randomises all trajectories — a slow ball can still land Zone A. The Section 4 deflector barrier nudges stragglers back into the pack. The narrow gap in the final 5s creates one last position swap. |

---

## EV check (fill in before launch)

| Component | Budget | Estimated actual | Status |
|---|---|---|---|
| Finish position payouts | 55% of stakes | 55% (fixed) | ✓ |
| Multiplier zone | ≤ 41% of stakes | ~39.7% (needs sim) | ⬜ |
| House edge | ≥ 4% | ~5% (needs sim) | ⬜ |
| **Total payout** | **≤ 96%** | **~95% (needs sim)** | **⬜** |

---

## Open design questions

- [ ] **Centre slot feel**: should hitting the 0.5× centre give a distinct penalty animation (e.g. red flash)? Makes the bad outcome legible without confusing players
- [ ] **Tube frequency**: target 1–3 balls per race reaching the tube. Tune peg density on left side of Section 1 accordingly
- [ ] **Bumper zone ratios**: should Zone A / B / C be roughly equal probability, or weighted toward A? Weighted toward A means more balls funnel to centre (penalty) — tighter house edge but less exciting multiplier zone
- [ ] **Section 4 gap**: fixed map element or varies per race? Fixed is more learnable
- [ ] **Ball colour change on multiplier hit**: strongly recommend yes — lets spectators track their ball through the crowded Section 4 chase
- [ ] **Dream combo screen event**: define trigger condition (Tube + 3× edge + 1st place = 27×) and what the visual event looks like

---

## Related
- [[Payout System]]
- [[Map Design Principles]]
- [[Game Ideas]]
