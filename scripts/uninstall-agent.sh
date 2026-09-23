#!/bin/bash
# Removes the menu bar agent and its LaunchAgent registration.
set -e

if [ "$EUID" -eq 0 ]; then
    echo "Do not run this with sudo — the agent is installed per-user."
    exit 1
fi

LABEL=com.audioattenuator.agent
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
rm -f "$PLIST"
rm -rf /Applications/Attenuator.app

echo "Agent removed. Saved volumes remain in:"
echo "  ~/Library/Application Support/Attenuator/settings.json"
