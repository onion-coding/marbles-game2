#!/bin/bash
set -e

# Defaults
PRESET="${1:-quick}"
URL="${URL:-http://localhost:8080}"
HMAC_SECRET="${HMAC_SECRET:-dev-secret}"

# Preset configurations
case "$PRESET" in
    quick)
        CONCURRENCY=10
        DURATION="30s"
        BETS_PER_ROUND=5
        DESCRIPTION="Smoke test: 10 players, 30 seconds"
        ;;
    medium)
        CONCURRENCY=100
        DURATION="5m"
        BETS_PER_ROUND=20
        DESCRIPTION="CI-friendly: 100 players, 5 minutes"
        ;;
    full)
        CONCURRENCY=1000
        DURATION="30m"
        BETS_PER_ROUND=20
        DESCRIPTION="Release gate: 1000 players, 30 minutes"
        ;;
    *)
        echo "Usage: $0 {quick|medium|full}"
        exit 1
        ;;
esac

echo "Stress Test Runner"
echo "=================="
echo "Preset:      $PRESET ($DESCRIPTION)"
echo "URL:         $URL"
echo "Concurrency: $CONCURRENCY"
echo "Duration:    $DURATION"
echo "Bets/round:  $BETS_PER_ROUND"
echo ""

# Check if Go is installed
if ! command -v go &> /dev/null; then
    echo "Error: Go is not installed or not in PATH"
    exit 1
fi

# Get script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MAIN_GO_PATH="$SCRIPT_DIR/main.go"

if [ ! -f "$MAIN_GO_PATH" ]; then
    echo "Error: main.go not found at $MAIN_GO_PATH"
    exit 1
fi

# Build the stress test
echo "Building stress test binary..." >&2
TEMP_BUILD=$(mktemp -p /tmp marbles-stress.XXXXXX)
trap "rm -f $TEMP_BUILD" EXIT
go build -o "$TEMP_BUILD" "$MAIN_GO_PATH"

echo "Starting test..." >&2
echo ""

# Run the stress test
"$TEMP_BUILD" \
    -url="$URL" \
    -hmac-secret="$HMAC_SECRET" \
    -concurrency="$CONCURRENCY" \
    -duration="$DURATION" \
    -bets-per-round="$BETS_PER_ROUND" \
    -think-time=1s
