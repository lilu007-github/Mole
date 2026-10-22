#!/bin/bash
# Compile Burrow's sources with app/Tests/Checks and run the checks.
# Usage: app/scripts/run-checks.sh [filter]
#   BURROW_SKIP_LIVE=1  skip checks that run the real Mole CLI (all dry runs)
#
# Live checks use the Mole CLI from this checkout, never an installed `mo`.

set -euo pipefail

APP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO_DIR="$(cd "$APP_DIR/.." && pwd)"
OUT="$APP_DIR/build/checks"

if [[ "${BURROW_SKIP_LIVE:-0}" != "1" ]] &&
    [[ ! -x "$REPO_DIR/bin/status-go" || ! -x "$REPO_DIR/bin/analyze-go" ]]; then
    echo "Building Mole Go helpers for the live checks..."
    make -C "$REPO_DIR" build > /dev/null
fi

# Everything except the @main app entry point, plus the checks.
sources=()
for file in "$APP_DIR"/Sources/Burrow/*.swift; do
    [[ "$(basename "$file")" == "BurrowApp.swift" ]] || sources+=("$file")
done
sources+=("$APP_DIR"/Tests/Checks/*.swift)

mkdir -p "$(dirname "$OUT")"
swiftc -O -swift-version 5 -target "$(uname -m)-apple-macosx14.0" -o "$OUT" "${sources[@]}"

MOLE_PATH="$REPO_DIR/mole" "$OUT" "$@"
