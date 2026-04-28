#!/usr/bin/env bash
# Run N rounds of roundd and analyze the resulting replay store.
# Used to spot-check fairness + RTP behavior without spinning up a full
# certification batch — meant for ~10-100 rounds in a few minutes.
#
# Usage:
#   GODOT_BIN=/path/to/godot scripts/rtp_smoke.sh [rounds] [out_dir]
#
# Defaults: 20 rounds, tmp/rtp_smoke as the replay root.
#
# Env:
#   GODOT_BIN     absolute path to the Godot executable (required)
#   GAME_DIR      absolute path to the game/ directory (default: ./game)
#   ROUNDD        path to the roundd Go binary (default: builds via `go build`)
#   RTP_BPS       house edge in basis points (default 9500 = 95%)
#   BUY_IN        per-marble mock buy-in (default 100)
#   MARBLES       marbles per round (default 20)
#   SIM_TIMEOUT   per-round Godot timeout (default 120s)

set -euo pipefail

ROUNDS="${1:-20}"
OUT_DIR="${2:-tmp/rtp_smoke}"
GAME_DIR="${GAME_DIR:-game}"
RTP_BPS="${RTP_BPS:-9500}"
BUY_IN="${BUY_IN:-100}"
MARBLES="${MARBLES:-20}"
SIM_TIMEOUT="${SIM_TIMEOUT:-120s}"

if [[ -z "${GODOT_BIN:-}" ]]; then
  echo "ERROR: set GODOT_BIN to the path of your Godot executable" >&2
  exit 2
fi

if [[ ! -x "$GODOT_BIN" && ! -f "$GODOT_BIN" ]]; then
  echo "ERROR: GODOT_BIN '$GODOT_BIN' not found" >&2
  exit 2
fi

# Build roundd if not provided.
ROUNDD="${ROUNDD:-}"
if [[ -z "$ROUNDD" ]]; then
  ROUNDD="$(mktemp -d)/roundd"
  echo ">>> building roundd to $ROUNDD"
  ( cd server && go build -o "$ROUNDD" ./cmd/roundd )
fi

# Reset output dir.
echo ">>> resetting $OUT_DIR"
rm -rf "$OUT_DIR"
mkdir -p "$OUT_DIR"

# Convert paths to forward-slash form so the spec-file JSON Godot reads is
# happy regardless of platform.
PROJ_ABS="$(cd "$GAME_DIR" && pwd)"
OUT_ABS="$(cd "$OUT_DIR" && pwd)"

echo ">>> running $ROUNDS rounds (rtp=$RTP_BPS bps, buy_in=$BUY_IN, marbles=$MARBLES)"
"$ROUNDD" \
  --godot-bin="$GODOT_BIN" \
  --project-path="$PROJ_ABS" \
  --replay-root="$OUT_ABS" \
  --rounds="$ROUNDS" --marbles="$MARBLES" --rtp-bps="$RTP_BPS" --buy-in="$BUY_IN" \
  --sim-timeout="$SIM_TIMEOUT"

echo ""
echo ">>> analyzing $OUT_DIR"
python3 scripts/analyze_replays.py "$OUT_DIR" --rtp-bps "$RTP_BPS" --buy-in "$BUY_IN"
