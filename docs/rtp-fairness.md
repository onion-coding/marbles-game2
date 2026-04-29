# RTP and fairness analysis

This document explains the tooling that ingests a replay-store directory
(produced by `roundd`) and reports the statistics that operators / regulators
will eventually want to see during certification.

It is **not** a substitute for a GLI / MGA certification process. It is the
*shape* of the deliverables that those processes require, scaled to whatever
sample size you can run.

## Files

| Path                                  | Purpose                                             |
| ------------------------------------- | --------------------------------------------------- |
| [scripts/analyze_replays.py](../scripts/analyze_replays.py) | Pure-Python reader; takes a replay root, prints stats. |
| [scripts/rtp_smoke.sh](../scripts/rtp_smoke.sh)             | Convenience wrapper: build `roundd`, run N rounds, then call the analyzer. |

## Quick start

```bash
GODOT_BIN=/path/to/Godot.exe ./scripts/rtp_smoke.sh 100 tmp/rtp_100
```

This builds `roundd`, runs 100 rounds (≈ 15-25 minutes depending on track
mix and hardware), persists the audit entries under `tmp/rtp_100/`, and
prints the analyzer report.

To run the analyzer alone against an existing store:

```bash
python3 scripts/analyze_replays.py tmp/rtp_100 --rtp-bps 9500 --buy-in 100
```

## What the report contains

### 1. Track distribution

Frequency at which each track gets selected. With `selectableTrackIDs =
[0..5]` and the deterministic-with-no-repeat selector in [server/cmd/roundd/main.go](../server/cmd/roundd/main.go),
the long-run distribution should be roughly uniform across the six tracks.
Short-run skew (e.g. POKER 25% over 6 rounds) is expected sampling noise.

### 2. Race duration per track

`mean / stdev / min / max / p50 / p95` of the finish-tick over the rounds
that ran on each track, expressed in seconds.

For player experience the **target window is 40-50 s**. Anything below 10s feels rushed; anything above 60s loses attention. Post-M6 race times: Craps 48.7s, Poker 47.5s, Slots 41.6s, Plinko 46.3s, Roulette 47.4s. Ramp (legacy, untuned) 13.8s — see [docs/tracks/](tracks/) for per-track post-build notes.

### 3. Winner index distribution

Per-marble win count across all rounds. **The fairness null hypothesis is
that every marble_index has equal P(win) = 1/N**. The analyzer computes a
chi-square statistic against a uniform expectation and prints the dof
(degrees of freedom = N-1).

For 20 marbles, the χ² critical value at α = 0.01, dof = 19 is **36.19**.
A χ² *below* that means we cannot reject fairness at the 1% level; *above*
suggests a slot-derivation bug or a track that systematically favours
certain spawn slots.

Pearson's heuristic for "use chi-square at all": expected count per cell
≥ 5, i.e. `n_rounds ≥ 5 * n_marbles = 100`. The analyzer prints a warning
below that threshold.

### 4. RTP verification

Re-derives the expected payouts and house cut from the configured RTP
basis points, the buy-in, and the round count, then prints whether the
math comes out exact (every round hits the same prize so there's no drift
across rounds). With integer-only `rtp.Settle` math (basis-point
denominator 10000), drift ≤ 1 bp is the expected behaviour.

### 5. Per-track winner heatmap (n ≥ 20)

Two-dimensional table: rows are marble_index 0..N-1, columns are track_id.
Useful for spotting per-track bias. E.g. if marble_19 always wins on
ROULETTE but is uniform elsewhere, the helix's spawn-slot ordering may
need rebalancing for that geometry.

## Sample sizes vs. confidence

| Sample (rounds) | What you can claim                                                   |
| --------------- | -------------------------------------------------------------------- |
| 6               | Smoke test. Distribution noise dominates; report is shape-only.      |
| 100             | Reaches Pearson's chi-square threshold. Fairness signal first reads. |
| 1,000           | Race-time stdev tightens; per-track fairness becomes meaningful.     |
| 100,000         | What GLI-style RTP certification expects. Multi-day run.             |

For the MVP demo we recommend **100 rounds** as the smallest "real" smoke
that produces a credible report. Anything beyond 1,000 needs a multi-host
or batch-Godot setup that's deferred work.

## What's intentionally not here

- **Operator-side telemetry** (concurrent users, error rates, dropped
  rounds). That's production-infra work and lives in the Go server's
  observability layer, not in replay analysis.
- **Player-level RTP** (what an individual player got back from their
  stake over a session). The current `roundd` synthesizes mock players
  with one buy-in per round, so per-player RTP collapses to "win once,
  pocket prize" for a single round. Real RGS integration will plumb
  player IDs through the manifest and unlock that view.
- **Race outcome predictability** (knowing the seed before commit lets
  an operator pick winners). Already prevented by the commit/reveal
  protocol — see [docs/fairness.md](fairness.md).
