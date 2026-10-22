#!/bin/bash
# Build Burrow.app from the Swift package.
# Usage: app/build-app.sh [--open]
# The bundle records this checkout's path so it can run ../mole without an install.

set -euo pipefail

APP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$APP_DIR/.." && pwd)"
OUT="$APP_DIR/build/Burrow.app"

# mo status / mo analyze need the Go helpers next to the scripts.
if [[ ! -x "$REPO_DIR/bin/status-go" || ! -x "$REPO_DIR/bin/analyze-go" ]]; then
    echo "Building Mole Go helpers..."
    make -C "$REPO_DIR" build
fi

echo "Building Burrow (release)..."
swift build --package-path "$APP_DIR" -c release
BIN_DIR="$(swift build --package-path "$APP_DIR" -c release --show-bin-path)"

rm -rf "$OUT"
mkdir -p "$OUT/Contents/MacOS" "$OUT/Contents/Resources"
cp "$BIN_DIR/Burrow" "$OUT/Contents/MacOS/Burrow"

cat > "$OUT/Contents/Info.plist" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Burrow</string>
    <key>CFBundleDisplayName</key><string>Burrow</string>
    <key>CFBundleIdentifier</key><string>dev.burrow.app</string>
    <key>CFBundleExecutable</key><string>Burrow</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>MoleRepoPath</key><string>$REPO_DIR</string>
</dict>
</plist>
EOF

# Ad-hoc signature so macOS will launch the locally built bundle.
codesign --force --sign - "$OUT" > /dev/null

echo "Built $OUT"
if [[ "${1:-}" == "--open" ]]; then
    open "$OUT"
fi
