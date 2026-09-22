#!/bin/bash
set -e

DRIVER_NAME="Attenuator.driver"
BUILD_DIR="build"
HAL_DIR="/Library/Audio/Plug-Ins/HAL"

echo "Installing Attenuator driver..."

# Check if running as root
if [ "$EUID" -ne 0 ]; then
    echo "Please run with sudo: sudo $0"
    exit 1
fi

# Check if driver exists in build directory
if [ ! -d "$BUILD_DIR/driver/$DRIVER_NAME" ]; then
    echo "Error: Driver not found in $BUILD_DIR/driver/"
    echo "Please build the project first: cmake --build build"
    exit 1
fi

# Create HAL directory if it doesn't exist
mkdir -p "$HAL_DIR"

# Remove existing driver if present
if [ -d "$HAL_DIR/$DRIVER_NAME" ]; then
    echo "Removing existing driver..."
    rm -rf "$HAL_DIR/$DRIVER_NAME"
fi

# Copy new driver
echo "Copying driver to $HAL_DIR..."
cp -R "$BUILD_DIR/driver/$DRIVER_NAME" "$HAL_DIR/"

# Set permissions
chown -R root:wheel "$HAL_DIR/$DRIVER_NAME"
chmod -R 755 "$HAL_DIR/$DRIVER_NAME"

# Try to restart CoreAudio
echo "Restarting CoreAudio..."
if launchctl kickstart -kp system/com.apple.audio.coreaudiod 2>/dev/null; then
    echo "CoreAudio restarted successfully."
else
    echo ""
    echo "Note: Could not restart CoreAudio automatically (SIP is enabled)."
    echo ""
    echo "To load the driver, choose one of these options:"
    echo "  1. Kill coreaudiod manually:"
    echo "     sudo killall coreaudiod"
    echo ""
    echo "  2. Or log out and log back in"
    echo ""
    echo "  3. Or restart your Mac"
    echo ""

    # Try killall as fallback
    read -p "Try 'sudo killall coreaudiod' now? [y/N] " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        killall coreaudiod 2>/dev/null || true
        sleep 2
        echo "CoreAudio process killed. It should restart automatically."
    fi
fi

echo ""
echo "Installation complete!"
echo "Driver location: $HAL_DIR/$DRIVER_NAME"
echo ""
echo "Check Audio MIDI Setup.app to verify 'Attenuator Device' is visible."
