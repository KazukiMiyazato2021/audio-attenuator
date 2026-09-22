#!/bin/bash
# Assembles the SwiftPM executable into a real .app bundle and ad-hoc signs it.
#
# This is not cosmetic: Core Audio process taps are gated by the AudioCapture
# TCC permission, and macOS can only attribute that permission to an app with
# a bundle identity, an Info.plist usage string, and a code signature. Run as a
# bare CLI binary the taps are created successfully but deliver pure silence.

set -e

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
AGENT_DIR="$ROOT/agent"
CONFIG="${CONFIG:-release}"
APP="$ROOT/build/Attenuator.app"
BINARY="$AGENT_DIR/.build/$CONFIG/AttenuatorAgent"

echo "Building agent ($CONFIG)..."
(cd "$AGENT_DIR" && swift build -c "$CONFIG")

if [ ! -f "$BINARY" ]; then
    echo "Error: built binary not found at $BINARY"
    exit 1
fi

echo "Assembling $APP ..."
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BINARY" "$APP/Contents/MacOS/AttenuatorAgent"
cp "$AGENT_DIR/Sources/AttenuatorAgent/Resources/Info.plist" "$APP/Contents/Info.plist"

# Ad-hoc signature. TCC keys the grant to the code identity, so the grant is
# invalidated whenever the binary changes and must be re-approved after a
# rebuild. A Developer ID signature would make the grant stable; that is a
# distribution concern, not needed for local development.
echo "Signing (ad-hoc)..."
codesign --force --sign - --timestamp=none "$APP"

echo "Done: $APP"
echo ""
echo "Run it with:"
echo "  $APP/Contents/MacOS/AttenuatorAgent --help"
