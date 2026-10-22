#!/bin/bash
# Build Burrow.app from the Swift package, with the Mole CLI bundled inside.
# Usage: app/build-app.sh [--open]
#
# The CLI from this checkout (mole, bin/, lib/ and universal Go helpers) goes to
# Contents/Resources/mole, so the app runs without a separate Mole install.
# Signing uses the identity from app/scripts/setup-signing.sh when present and
# falls back to an ad-hoc signature otherwise.

set -euo pipefail

APP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$APP_DIR/.." && pwd)"
BUILD_DIR="$APP_DIR/build"
OUT="$BUILD_DIR/Burrow.app"
SIGN_NAME="Burrow Local Signing"
SIGN_KEYCHAIN="$HOME/Library/Keychains/burrow-signing.keychain-db"
SIGN_PASS_FILE="$HOME/.config/burrow/signing-keychain-password"

# One build per architecture, merged with lipo: the single-command universal
# build needs full Xcode, while per-triple builds work with Command Line Tools.
echo "Building Burrow (release, universal)..."
SWIFT_SLICES=()
for triple in arm64-apple-macosx14.0 x86_64-apple-macosx14.0; do
    swift build --package-path "$APP_DIR" -c release --triple "$triple"
    SWIFT_SLICES+=("$(swift build --package-path "$APP_DIR" -c release --triple "$triple" --show-bin-path)/Burrow")
done

# Pure-Go helpers for both architectures, like Mole's own release targets.
echo "Building Mole Go helpers (universal)..."
GO_OUT="$BUILD_DIR/go"
mkdir -p "$GO_OUT"
for tool in analyze status; do
    for arch in arm64 amd64; do
        (cd "$REPO_DIR" && CGO_ENABLED=0 GOOS=darwin GOARCH=$arch \
            go build -ldflags="-s -w" -o "$GO_OUT/$tool-$arch" "./cmd/$tool")
    done
    lipo -create "$GO_OUT/$tool-arm64" "$GO_OUT/$tool-amd64" -output "$GO_OUT/$tool-go"
done

rm -rf "$OUT"
mkdir -p "$OUT/Contents/MacOS" "$OUT/Contents/Resources/mole/bin"

# The icon is drawn in code (scripts/make-icon.swift); no image assets in the repo.
rm -rf "$BUILD_DIR/AppIcon.iconset"
swift "$APP_DIR/scripts/make-icon.swift" "$BUILD_DIR/AppIcon.iconset"
iconutil -c icns -o "$OUT/Contents/Resources/AppIcon.icns" "$BUILD_DIR/AppIcon.iconset"
lipo -create "${SWIFT_SLICES[@]}" -output "$OUT/Contents/MacOS/Burrow"

CLI="$OUT/Contents/Resources/mole"
cp "$REPO_DIR/mole" "$REPO_DIR/LICENSE" "$CLI/"
cp "$REPO_DIR"/bin/*.sh "$CLI/bin/"
cp "$GO_OUT/analyze-go" "$GO_OUT/status-go" "$CLI/bin/"
cp -R "$REPO_DIR/lib" "$CLI/lib"
MOLE_VERSION="$("$CLI/mole" --version 2> /dev/null | sed -n 's/^Mole version //p')"
MOLE_COMMIT="$(git -C "$REPO_DIR" rev-parse --short HEAD 2> /dev/null || echo unknown)"

cat > "$OUT/Contents/Info.plist" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Burrow</string>
    <key>CFBundleDisplayName</key><string>Burrow</string>
    <key>CFBundleIdentifier</key><string>dev.burrow.app</string>
    <key>CFBundleExecutable</key><string>Burrow</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.2.0</string>
    <key>CFBundleVersion</key><string>2</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>BundledMoleVersion</key><string>$MOLE_VERSION ($MOLE_COMMIT)</string>
</dict>
</plist>
EOF

# Sign nested executables first, then the bundle that seals them.
SIGN_ID="-"
if [[ -f "$SIGN_KEYCHAIN" && -f "$SIGN_PASS_FILE" ]]; then
    security unlock-keychain -p "$(cat "$SIGN_PASS_FILE")" "$SIGN_KEYCHAIN"
    SIGN_ID="$(security find-identity -p codesigning "$SIGN_KEYCHAIN" |
        awk -v name="\"$SIGN_NAME\"" '$0 ~ name { print $2; exit }')"
    [[ -n "$SIGN_ID" ]] || SIGN_ID="-"
fi
if [[ "$SIGN_ID" == "-" ]]; then
    echo "warning: signing ad-hoc; macOS permissions reset on every build." >&2
    echo "         Run app/scripts/setup-signing.sh once for a stable signature." >&2
fi
for helper in "$CLI/bin/analyze-go" "$CLI/bin/status-go"; do
    codesign --force --sign "$SIGN_ID" "$helper"
done
codesign --force --sign "$SIGN_ID" "$OUT"

echo "Built $OUT"
echo "  Mole CLI: $MOLE_VERSION ($MOLE_COMMIT)"
echo "  Signature: $(codesign -d -r- "$OUT" 2>&1 | sed -n 's/^designated => //p')"
if [[ "${1:-}" == "--open" ]]; then
    open "$OUT"
fi
