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

# TCC keys its grants to the code identity. An ad-hoc signature ("-") changes
# on every build, so the microphone and audio-capture permissions have to be
# re-approved after each rebuild. Signing with a stable certificate avoids
# that: see scripts/create-signing-identity.sh.
IDENTITY="${CODESIGN_IDENTITY:-}"
if [ -z "$IDENTITY" ]; then
    # Prefer a local dev identity if one exists, so permissions survive rebuilds.
    if security find-identity -v -p codesigning 2>/dev/null | grep -q "Attenuator Dev"; then
        IDENTITY="Attenuator Dev"
    else
        IDENTITY="-"
    fi
fi

if [ "$IDENTITY" = "-" ]; then
    echo "Signing (ad-hoc — permissions will need re-approving after each rebuild)..."
else
    echo "Signing with identity '$IDENTITY'..."
fi
codesign --force --sign "$IDENTITY" --timestamp=none "$APP"

echo "Done: $APP"
echo ""
echo "Run it with:"
echo "  $APP/Contents/MacOS/AttenuatorAgent --help"
