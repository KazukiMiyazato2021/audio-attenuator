#!/bin/bash
# Installs the menu bar agent and registers it with launchd.
#
# Runs as the normal user, not root: the agent needs the user's GUI session to
# own a menu bar item, and its privacy permissions are per-user. (The driver
# install is the part that needs sudo — see install.sh.)
#
# Starting through launchd is required, not just convenient: a process started
# from a terminal inherits the terminal as its TCC "responsible" process, so
# the audio permissions granted to Attenuator would not apply and audio would
# silently come through as zeros.

set -e

if [ "$EUID" -eq 0 ]; then
    echo "Do not run this with sudo — the agent must be installed for your user."
    exit 1
fi

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_SRC="$ROOT/build/Attenuator.app"
APP_DST="/Applications/Attenuator.app"
LABEL=com.audioattenuator.agent
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

if [ ! -d "$APP_SRC" ]; then
    echo "Building the app first..."
    "$ROOT/scripts/package-app.sh"
fi

echo "Stopping any running agent..."
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
# bootout is asynchronous; wait for the label to disappear before re-registering.
for _ in $(seq 1 20); do
    launchctl print "gui/$(id -u)/$LABEL" >/dev/null 2>&1 || break
    sleep 0.5
done

echo "Installing $APP_DST ..."
rm -rf "$APP_DST"
cp -R "$APP_SRC" "$APP_DST"
# Re-sign in place: copying can disturb the signature, and TCC keys its grants
# to the code identity.
codesign --force --sign - "$APP_DST"

echo "Installing LaunchAgent..."
mkdir -p "$HOME/Library/LaunchAgents"
cp "$ROOT/launchd/$LABEL.plist" "$PLIST"
launchctl bootstrap "gui/$(id -u)" "$PLIST"

cat <<'NOTE'

Installed. The menu bar icon should appear shortly.

Two permissions are required, and *both* fail silently (no error, just
silence) if missing:

  System Settings -> Privacy & Security -> Microphone
      -> enable Attenuator
      (reading the virtual device's input counts as microphone access)

  System Settings -> Privacy & Security -> Screen & System Audio Recording
      -> enable Attenuator
      (required for per-app volume)

A grant only applies to processes started afterwards, so restart the agent
once you have granted them:

  launchctl kickstart -k gui/$(id -u)/com.audioattenuator.agent

Then set the system output device to "Attenuator Device".
NOTE
