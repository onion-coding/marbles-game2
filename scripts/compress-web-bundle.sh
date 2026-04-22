#!/usr/bin/env bash
# Re-generates .br and .gz sidecars for the Godot Web export bundle so that
# replayd can serve precompressed bytes (see server/cmd/replayd/main.go
# servePrecompressed). Run this after every Godot Web export — otherwise the
# handler silently falls through to the raw 37 MB .wasm.
#
# Usage: ./scripts/compress-web-bundle.sh [dir]
#          default dir: tmp/web_export

set -euo pipefail

dir="${1:-tmp/web_export}"
if [ ! -d "$dir" ]; then
	echo "error: $dir is not a directory" >&2
	exit 1
fi

for f in "$dir"/index.wasm "$dir"/index.js; do
	if [ ! -f "$f" ]; then
		echo "warn: $f missing, skipping" >&2
		continue
	fi
	echo "compressing $f"
	gzip  -k -9  -f "$f"
	brotli -k -q 11 -f "$f"
done

echo ""
echo "sizes:"
ls -la "$dir"/index.wasm* "$dir"/index.js* 2>/dev/null | awk '{printf "%10s  %s\n", $5, $NF}'
