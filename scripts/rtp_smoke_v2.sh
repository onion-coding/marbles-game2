#!/usr/bin/env bash
# RTP regression CI script for the v2 payout model (M15-M21).
#
# Two-tier validation:
#   1. Pure-Go Monte-Carlo RTP estimate (TestRTPSimulation in
#      server/rgs/multiplier_test.go) — 50 000 rounds, takes <50ms,
#      asserts empirical RTP lands at 0.95 ± 0.02.  This is the
#      authoritative gate: failure here means the math model has
#      drifted from the documented target.
#   2. End-to-end smoke against the deterministic Go server +
#      headless Godot (optional — only if GODOT_BIN is set).  Runs a
#      small batch (default 12 rounds) and re-verifies RTP from real
#      manifests via the v4-aware analyzer.
#
# Usage:
#   scripts/rtp_smoke_v2.sh                 # tier 1 only (CI default)
#   GODOT_BIN=... scripts/rtp_smoke_v2.sh   # tier 1 + tier 2
#   scripts/rtp_smoke_v2.sh 50              # tier 2 with 50 rounds
#
# Env:
#   GODOT_BIN     absolute path to Godot 4.6.x.  If unset, only tier 1 runs.
#   GAME_DIR      absolute path to the game/ directory (default: ./game).
#   RTP_BPS       house edge in basis points (default 9500 = 95%).
#   BUY_IN        per-marble mock buy-in (default 100).
#   MARBLES       marbles per round (default 30 — matches M20).
#   SIM_TIMEOUT   per-round Godot timeout (default 120s).
#
# Exit codes:
#   0   all checks passed.
#   1   tier 1 (Go RTP simulation) failed — math model regression.
#   2   tier 2 (end-to-end smoke) failed — sim/manifest regression.
#   3   prerequisite missing (Go toolchain, Python, etc.).

set -euo pipefail

ROUNDS="${1:-12}"
RTP_BPS="${RTP_BPS:-9500}"
BUY_IN="${BUY_IN:-100}"
MARBLES="${MARBLES:-30}"
SIM_TIMEOUT="${SIM_TIMEOUT:-120s}"
GAME_DIR="${GAME_DIR:-game}"

# ─── Prerequisites ─────────────────────────────────────────────────────────

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

if ! command -v go >/dev/null 2>&1; then
  echo "ERROR: Go toolchain required (https://go.dev/dl/)" >&2
  exit 3
fi

# ─── Tier 1: Pure-Go RTP simulation ────────────────────────────────────────

echo ">>> Tier 1: pure-Go RTP Monte-Carlo (50 000 rounds)..."
if ! ( cd server && go test -count=1 -run '^TestRTPSimulation$' ./rgs/... -v ) ; then
  echo "FAIL: tier 1 — RTP simulation drifted from 0.95 ± 0.02 target." >&2
  echo "      The v2 payout math model regressed.  Review docs/math-model.md" >&2
  echo "      and recent changes to server/rgs/multiplier.go." >&2
  exit 1
fi
echo "PASS: tier 1 — empirical RTP within tolerance.\n"

# Also run the static math regression tests so any param drift is caught.
echo ">>> Tier 1b: payout math regression tests..."
if ! ( cd server && go test -count=1 \
    -run '^(TestPayoutV2|TestComputeBetPayoff|TestNewRoundOutcome|TestDeriveTier2Active|TestTier2ProbForRTP|TestValidatePickupCounts|TestCasinoModels)$' \
    ./rgs/... ) ; then
  echo "FAIL: tier 1b — static math regression." >&2
  exit 1
fi
echo "PASS: tier 1b — static math intact.\n"

# ─── Tier 2: End-to-end smoke (optional) ───────────────────────────────────

if [[ -z "${GODOT_BIN:-}" ]]; then
  echo "INFO: GODOT_BIN unset — skipping end-to-end smoke (tier 2)."
  echo "      Set GODOT_BIN=/path/to/godot to also run a real $ROUNDS-round batch."
  echo
  echo "ALL: $ROUNDS-round CI smoke skipped, tier 1 PASSED."
  exit 0
fi

if [[ ! -x "$GODOT_BIN" && ! -f "$GODOT_BIN" ]]; then
  echo "ERROR: GODOT_BIN '$GODOT_BIN' not found" >&2
  exit 3
fi

if ! command -v python3 >/dev/null 2>&1 && ! command -v python >/dev/null 2>&1; then
  echo "ERROR: python3 required for replay analysis" >&2
  exit 3
fi
PY="$(command -v python3 || command -v python)"

echo ">>> Tier 2: end-to-end smoke ($ROUNDS rounds, $MARBLES marbles, RTP $RTP_BPS bps)..."

OUT_DIR="$(mktemp -d)/rtp_smoke_v2"
mkdir -p "$OUT_DIR"
ROUNDD="$(mktemp -d)/roundd"
echo "    building roundd → $ROUNDD"
( cd server && go build -o "$ROUNDD" ./cmd/roundd )

PROJ_ABS="$(cd "$GAME_DIR" && pwd)"
echo "    running $ROUNDS rounds → $OUT_DIR"
"$ROUNDD" \
  --godot-bin="$GODOT_BIN" \
  --project-path="$PROJ_ABS" \
  --replay-root="$OUT_DIR" \
  --rounds="$ROUNDS" --marbles="$MARBLES" --rtp-bps="$RTP_BPS" --buy-in="$BUY_IN" \
  --sim-timeout="$SIM_TIMEOUT"

echo
echo ">>> Tier 2: analyzing $OUT_DIR with v4-aware analyzer..."
"$PY" scripts/analyze_replays.py "$OUT_DIR" --rtp-bps "$RTP_BPS" --buy-in "$BUY_IN"

# Tier 2 success is reported by analyze_replays.py's exit code in v2
# mode (RTP drift > tolerance triggers exit 1).  Bash propagates via
# set -e.

echo
echo "ALL PASSED (tier 1: pure-Go RTP, tier 2: $ROUNDS-round smoke)"
