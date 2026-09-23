#!/bin/bash
# Proves per-app volume actually attenuates one app's audio, by comparing
# metered peak levels rather than relying on listening.
#
# Plays a 0.3-amplitude tone from a single process and measures, at several
# tap volumes:
#   tapmix   - the tapped app's audio after its per-app gain
#   fallback - the path every untapped app rides
#   out      - the final mix sent to the output device
#
# Expected: tapmix tracks the requested percentage, and fallback stays at 0
# while the app is tapped (muteBehavior diverts it rather than duplicating it).
#
# Two requirements that are easy to get wrong:
#
#  1. The agent must run under launchd, not from a terminal. A terminal-started
#     process inherits the terminal as its TCC "responsible" process, so the
#     AudioCapture permission is attributed to the terminal; taps are then
#     created successfully but deliver pure silence.
#  2. The audio source must be a single, stable process for the whole run — a
#     tap binds to specific process objects, so a source that relaunches (e.g.
#     afplay in a loop) leaves each new instance untapped.
#
# Run with the system output set to Attenuator Device.

set -e

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/build/Attenuator.app"
BIN="$APP/Contents/MacOS/AttenuatorAgent"
TONEPLAYER="$ROOT/build/toneplayer"
TONE_AMPLITUDE=0.3
OUTPUT_DEVICE=BuiltInSpeakerDevice
LABEL=com.audioattenuator.verify
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

# The normal agent and this test job would both read the Attenuator Device and
# fight over its audio, so the agent is stopped for the duration — and put back
# on the way out, including on failure or Ctrl-C. Leaving it stopped silently
# kills the user's audio with no obvious cause.
AGENT_LABEL=com.audioattenuator.agent
AGENT_PLIST="$HOME/Library/LaunchAgents/$AGENT_LABEL.plist"
AGENT_WAS_RUNNING=no
if launchctl print "gui/$(id -u)/$AGENT_LABEL" >/dev/null 2>&1; then
    AGENT_WAS_RUNNING=yes
fi

wait_for_unload() {
    for _ in $(seq 1 20); do
        launchctl print "gui/$(id -u)/$1" >/dev/null 2>&1 || return 0
        sleep 0.5
    done
}

if [ "$AGENT_WAS_RUNNING" = yes ]; then
    echo "Stopping the running agent for the duration of the test..."
    launchctl bootout "gui/$(id -u)/$AGENT_LABEL" 2>/dev/null || true
    wait_for_unload "$AGENT_LABEL"
fi

if [ ! -x "$BIN" ]; then
    echo "Error: $BIN not found. Run scripts/package-app.sh first."
    exit 1
fi
if [ ! -x "$TONEPLAYER" ]; then
    echo "Error: $TONEPLAYER not found. Run scripts/build-testtools.sh first."
    exit 1
fi

cleanup() {
    launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
    rm -f "$PLIST"
    kill "$TONE_PID" 2>/dev/null || true
    wait "$TONE_PID" 2>/dev/null || true

    if [ "$AGENT_WAS_RUNNING" = yes ]; then
        wait_for_unload "$LABEL"
        echo "Restarting the agent..."
        launchctl bootstrap "gui/$(id -u)" "$AGENT_PLIST" 2>/dev/null || true
    fi
}
trap cleanup EXIT INT TERM

echo "Starting tone source (amplitude $TONE_AMPLITUDE)..."
"$TONEPLAYER" com.audioattenuator.device.v001 200 &
TONE_PID=$!
sleep 3
echo "tone pid=$TONE_PID"

run_case() {
    local pct="$1"
    local log="/tmp/attenuator-verify-$pct.log"
    : > "$log"

    cat > "$PLIST" <<PLISTEOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>$LABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>$BIN</string>
        <string>--output</string><string>$OUTPUT_DEVICE</string>
        <string>--duration</string><string>8</string>
        <string>--diag</string>
        <string>--tap</string><string>pid:$TONE_PID=$pct</string>
    </array>
    <key>RunAtLoad</key><true/>
    <key>StandardOutPath</key><string>$log</string>
    <key>StandardErrorPath</key><string>$log</string>
</dict>
</plist>
PLISTEOF

    # bootout is asynchronous; bootstrapping again too soon fails with EIO,
    # so wait for the label to actually disappear before re-registering.
    launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
    wait_for_unload "$LABEL"
    launchctl bootstrap "gui/$(id -u)" "$PLIST"
    sleep 11
    launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
    wait_for_unload "$LABEL"

    local line
    line=$(grep "peak" "$log" | tail -1)
    if [ -z "$line" ]; then
        echo "  ${pct}%: NO METER OUTPUT — check $log"
        echo "         (a rebuild invalidates the ad-hoc code identity, so macOS"
        echo "          may be waiting for the AudioCapture permission again)"
        return
    fi
    echo "  ${pct}%: $(echo "$line" | sed 's/.*| //')"
}

echo ""
echo "Tap volume -> measured levels (tone amplitude is $TONE_AMPLITUDE):"
for pct in 100 50 20 0; do
    run_case "$pct"
done

echo ""
echo "Expected tapmix: 100%->0.300  50%->0.150  20%->0.060  0%->0.000"
echo "Expected fallback: 0.000 in every case (tapped audio leaves the normal path)"
