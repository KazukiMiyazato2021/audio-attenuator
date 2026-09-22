cmake_minimum_required(VERSION 3.20)
project(AudioAttenuator VERSION 1.0.0 LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

# macOS specific settings — Process Tap API requires 14.4+
set(CMAKE_OSX_DEPLOYMENT_TARGET "14.4")

add_subdirectory(driver)
