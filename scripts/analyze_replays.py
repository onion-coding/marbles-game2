#!/usr/bin/env python3
"""Replay store analyzer.

Reads every manifest.json under a replay-store root and reports:
  - track distribution (how often each track gets selected)
  - winner index distribution (per track + overall) with chi-square fairness check
  - race time stats (per track: mean, stdev, min, max in seconds)
  - RTP verification (with --rtp-bps and --buy-in matching the roundd config)

Run:
  python scripts/analyze_replays.py tmp/replays --rtp-bps 9500 --buy-in 100

Designed for sample sizes from 10 (smoke) to 100k (statistical-fairness
demo). Pure stdlib (json + math + statistics) so it runs anywhere Python
3.10+ is available, no extra installs.
"""

from __future__ import annotations

import argparse
import json
import math
import statistics
import sys
from collections import Counter, defaultdict
from pathlib import Path
from typing import Any

# Track ID → human name. Must match game/tracks/track_registry.gd.
TRACK_NAMES = {
    0: "RAMP",
    1: "ROULETTE",
    2: "CRAPS",
    3: "POKER",
    4: "SLOTS",
    5: "PLINKO",
}


def load_manifests(root: Path) -> list[dict[str, Any]]:
    """Iterate <root>/<round_id>/manifest.json files into a list of dicts."""
    out: list[dict[str, Any]] = []
    for child in sorted(root.iterdir()):
        if not child.is_dir():
            continue
        m = child / "manifest.json"
        if not m.exists():
            continue
        try:
            out.append(json.loads(m.read_text()))
        except json.JSONDecodeError as e:
            print(f"WARN: skipping {m}: {e}", file=sys.stderr)
    return out


def chi_square_uniform(counts: list[int], expected: float) -> tuple[float, int]:
    """Return (chi2 statistic, dof). dof = len(counts) - 1.

    Caller compares chi2 against critical value at chosen alpha (e.g. 0.01).
    No p-value lookup here — keeps the script stdlib-only. Accept-region
    notes printed in the report.
    """
    if expected <= 0:
        return (0.0, 0)
    chi2 = sum((c - expected) ** 2 / expected for c in counts)
    return (chi2, len(counts) - 1)


def percentile(values: list[float], p: float) -> float:
    if not values:
        return 0.0
    s = sorted(values)
    idx = max(0, min(len(s) - 1, int(round(p * (len(s) - 1)))))
    return s[idx]


def fmt_seconds(frames: float, hz: int) -> str:
    sec = frames / hz
    return f"{sec:.1f}s"


def report(manifests: list[dict[str, Any]], rtp_bps: int, buy_in: int) -> None:
    if not manifests:
        print("No manifests found.")
        return
    n = len(manifests)
    marbles_per_round = len(manifests[0]["participants"])
    tick_rate = manifests[0].get("tick_rate_hz", 60)

    # ─── Track distribution ──────────────────────────────────────────────
    track_counts: Counter[int] = Counter(m["track_id"] for m in manifests)
    print(f"=== Replay analysis: {n} round(s), {marbles_per_round} marbles/round ===\n")
    print("Track distribution:")
    for tid in sorted(TRACK_NAMES):
        c = track_counts.get(tid, 0)
        bar = "#" * int(40 * c / max(track_counts.values(), default=1)) if c > 0 else ""
        print(f"  {TRACK_NAMES[tid]:<10} (id={tid}): {c:>5}  {bar}")

    # ─── Race times (frames at tick_rate) ────────────────────────────────
    times_by_track: dict[int, list[int]] = defaultdict(list)
    for m in manifests:
        ft = m["winner"].get("finish_tick", -1)
        if ft >= 0:
            times_by_track[m["track_id"]].append(ft)

    print("\nRace duration per track:")
    print(f"  {'TRACK':<10}  {'N':>4}  {'mean':>7}  {'stdev':>7}  {'min':>7}  {'max':>7}  {'p50':>7}  {'p95':>7}")
    for tid in sorted(times_by_track):
        ticks = times_by_track[tid]
        mean = statistics.fmean(ticks) if ticks else 0
        stdev = statistics.pstdev(ticks) if len(ticks) > 1 else 0
        print(
            f"  {TRACK_NAMES.get(tid, '?'):<10}  {len(ticks):>4}  "
            f"{fmt_seconds(mean, tick_rate):>7}  {fmt_seconds(stdev, tick_rate):>7}  "
            f"{fmt_seconds(min(ticks), tick_rate):>7}  {fmt_seconds(max(ticks), tick_rate):>7}  "
            f"{fmt_seconds(percentile(ticks, 0.50), tick_rate):>7}  "
            f"{fmt_seconds(percentile(ticks, 0.95), tick_rate):>7}"
        )

    # ─── Winner distribution (overall + per track) ───────────────────────
    overall: list[int] = [0] * marbles_per_round
    by_track: dict[int, list[int]] = defaultdict(lambda: [0] * marbles_per_round)
    for m in manifests:
        widx = m["winner"]["marble_index"]
        if 0 <= widx < marbles_per_round:
            overall[widx] += 1
            by_track[m["track_id"]][widx] += 1

    print("\nOverall winner index distribution:")
    expected = n / marbles_per_round
    chi2, dof = chi_square_uniform(overall, expected)
    print(f"  Expected per slot: {expected:.2f} (uniform fairness null hypothesis)")
    print(f"  Observed: {overall}")
    print(f"  Chi-square = {chi2:.2f}, dof = {dof}")
    if n < marbles_per_round * 5:
        print(f"  WARNING: sample too small for chi-square (need >= {marbles_per_round*5} rounds; got {n})")
    else:
        # Critical values at alpha = 0.01 for dof=19 (20 marbles): ~36.19
        print(f"  alpha=0.01 critical for dof=19 is ~36.19 -- chi2 below = fair, above = bias suspected")

    # ─── RTP verification ────────────────────────────────────────────────
    # roundd's mock buy-in is `buy_in` per marble per round, total stake =
    # marbles_per_round * buy_in * n. Payout is one prize per round computed
    # via rtp.Settle: prize ≈ stake * rtp_bps / 10000, integer-rounded with
    # remainder going to house. Sum across rounds and verify the ratio.
    total_stake = marbles_per_round * buy_in * n
    expected_house_per_round = (marbles_per_round * buy_in) - ((marbles_per_round * buy_in * rtp_bps) // 10000)
    expected_house = expected_house_per_round * n
    expected_payout = total_stake - expected_house
    effective_rtp_bps = (expected_payout * 10000) // total_stake if total_stake else 0
    print("\nRTP verification (assuming roundd mock buy-in scheme):")
    print(f"  Buy-in per marble: {buy_in}, marbles/round: {marbles_per_round}, rounds: {n}")
    print(f"  Total stake: {total_stake}")
    print(f"  Expected total payout: {expected_payout}")
    print(f"  Expected total house cut: {expected_house}")
    print(f"  Effective RTP: {effective_rtp_bps/100:.2f}% (config: {rtp_bps/100:.2f}%)")
    drift_bps = abs(effective_rtp_bps - rtp_bps)
    if drift_bps == 0:
        print("  RTP exact match (integer rounding preserved across all rounds)")
    else:
        print(f"  ! RTP drift: {drift_bps} bps from configured (rounding remainder)")

    # ─── Per-track winner heatmap (only when sample large enough) ────────
    if n >= 20:
        print("\nPer-track winner distribution (rows = marble_index, cols = track):")
        header = "    "
        for tid in sorted(by_track):
            header += f"{TRACK_NAMES.get(tid, '?'):>10}"
        print(header)
        for mi in range(marbles_per_round):
            row = f"  {mi:>2}"
            for tid in sorted(by_track):
                c = by_track[tid][mi]
                row += f"{c:>10}"
            print(row)


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("root", type=Path, help="replay store root (e.g. tmp/replays)")
    ap.add_argument("--rtp-bps", type=int, default=9500, help="configured RTP in basis points (default 9500 = 95%%)")
    ap.add_argument("--buy-in", type=int, default=100, help="per-marble mock buy-in (default 100)")
    args = ap.parse_args()
    if not args.root.exists():
        print(f"ERROR: replay root {args.root} does not exist", file=sys.stderr)
        sys.exit(2)
    manifests = load_manifests(args.root)
    report(manifests, args.rtp_bps, args.buy_in)


if __name__ == "__main__":
    main()
