#!/bin/bash
# Measures how long it takes for audio played by an app to reach our capture
# IOProc via the Attenuator Device, versus how long our own relay adds.
#
# Splits the end-to-end delay into two halves:
#   afplay launch -> capture onset   = driver / CoreAudio routing cost
#   capture onset -> playback onset  = our relay (ring buffer + IOProcs)
#
# Plays sounds of differing durations so a fixed latency can be told apart
# from one that tracks the source file's length.
#
# Run with the system output already set to Attenuator Device.

set -e

AGENT="$(dirname "$0")/../agent/.build/release/AttenuatorAgent"
LOG=$(mktemp /tmp/attenuator-onset.XXXXXX)
RUN_SECONDS=22

# name:duration pairs, deliberately spanning a ~3x range
SOUNDS=(Tink Basso Pop)

echo "Starting agent for ${RUN_SECONDS}s (log: $LOG)..."
"$AGENT" --output BuiltInSpeakerDevice --duration "$RUN_SECONDS" --diag > "$LOG" 2>&1 &
AGENT_PID=$!
trap 'kill $AGENT_PID 2>/dev/null || true' EXIT

# Let the agent finish device setup and start both IOProcs.
sleep 3

if ! kill -0 $AGENT_PID 2>/dev/null; then
    echo "Agent exited early. Log:"
    cat "$LOG"
    exit 1
fi

for name in "${SOUNDS[@]}"; do
    SOUND="/System/Library/Sounds/${name}.aiff"
    DUR=$(afinfo "$SOUND" | awk '/estimated duration/ {print $3}')
    T0=$(python3 -c 'import time; print("%.3f" % time.time())')
    echo "[test] $name (duration ${DUR}s) afplay launched at $T0"
    afplay "$SOUND"
    sleep 3
done

# Let the agent hit its own --duration deadline and exit cleanly.
wait $AGENT_PID 2>/dev/null || true
trap - EXIT

echo ""
echo "=== agent onset log ==="
grep -E "onset" "$LOG" || echo "(no onset lines — agent may not have captured any audio)"
echo ""
echo "Log kept at: $LOG"
