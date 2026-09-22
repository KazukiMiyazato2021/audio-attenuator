cmake_minimum_required(VERSION 3.20)

set(DRIVER_NAME "Attenuator")
set(DRIVER_BUNDLE_ID "com.audioattenuator.driver")

# Source files (single-file driver, SoundPusher pattern)
set(DRIVER_SOURCES
    src/AttenuatorDriver.cpp
)

set(DRIVER_HEADERS
    src/AttenuatorDriver.h
)

# Create the driver bundle
add_library(${DRIVER_NAME} MODULE ${DRIVER_SOURCES} ${DRIVER_HEADERS})

# Set bundle properties
set_target_properties(${DRIVER_NAME} PROPERTIES
    BUNDLE TRUE
    BUNDLE_EXTENSION "driver"
    MACOSX_BUNDLE_INFO_PLIST "${CMAKE_CURRENT_SOURCE_DIR}/Info.plist"
    MACOSX_BUNDLE_BUNDLE_NAME "${DRIVER_NAME}"
    MACOSX_BUNDLE_BUNDLE_VERSION "${PROJECT_VERSION}"
    MACOSX_BUNDLE_SHORT_VERSION_STRING "${PROJECT_VERSION}"
    MACOSX_BUNDLE_GUI_IDENTIFIER "${DRIVER_BUNDLE_ID}"
    XCODE_ATTRIBUTE_PRODUCT_BUNDLE_IDENTIFIER "${DRIVER_BUNDLE_ID}"
)

# Link frameworks
target_link_libraries(${DRIVER_NAME} PRIVATE
    "-framework CoreFoundation"
    "-framework CoreAudio"
    "-framework AudioToolbox"
)

# Include directories
target_include_directories(${DRIVER_NAME} PRIVATE
    ${CMAKE_CURRENT_SOURCE_DIR}/src
)

# Compiler flags
target_compile_options(${DRIVER_NAME} PRIVATE
    -Wall
    -Wextra
    -Wpedantic
)

# Install to HAL plug-ins directory
install(TARGETS ${DRIVER_NAME}
    LIBRARY DESTINATION "/Library/Audio/Plug-Ins/HAL/${DRIVER_NAME}.driver/Contents/MacOS"
)

# Install Info.plist
install(FILES "${CMAKE_CURRENT_SOURCE_DIR}/Info.plist"
    DESTINATION "/Library/Audio/Plug-Ins/HAL/${DRIVER_NAME}.driver/Contents"
)
