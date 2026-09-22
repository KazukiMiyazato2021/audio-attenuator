#!/bin/bash
# Builds the small helper binaries the verification scripts drive.
set -e

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$ROOT/build"

echo "Building toneplayer..."
swiftc -O -o "$ROOT/build/toneplayer" "$ROOT/testtools/toneplayer.swift" \
    -framework CoreAudio -framework AudioToolbox

echo "Done: $ROOT/build/toneplayer"
