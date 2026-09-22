#!/bin/bash
set -e

DRIVER_NAME="Attenuator.driver"
HAL_DIR="/Library/Audio/Plug-Ins/HAL"

echo "Uninstalling Attenuator driver..."

# Check if running as root
if [ "$EUID" -ne 0 ]; then
    echo "Please run with sudo: sudo $0"
    exit 1
fi

# Remove driver if present
if [ -d "$HAL_DIR/$DRIVER_NAME" ]; then
    echo "Removing driver..."
    rm -rf "$HAL_DIR/$DRIVER_NAME"
else
    echo "Driver not found at $HAL_DIR/$DRIVER_NAME"
fi

# Restart CoreAudio
echo "Restarting CoreAudio..."
launchctl kickstart -kp system/com.apple.audio.coreaudiod

echo "Uninstallation complete!"
