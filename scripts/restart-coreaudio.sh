#!/bin/bash

echo "Restarting CoreAudio daemon..."

if [ "$EUID" -ne 0 ]; then
    echo "Please run with sudo: sudo $0"
    exit 1
fi

launchctl kickstart -kp system/com.apple.audio.coreaudiod

echo "CoreAudio restarted."
