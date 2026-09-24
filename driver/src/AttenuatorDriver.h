#pragma once

#define kDevice_UID          "com.audioattenuator.device.v001"
#define kDevice_ModelUID     "com.audioattenuator.device"
#define kBox_UID             "com.audioattenuator.box.v001"

// Custom device property the mixer writes to publish the latency of whatever
// it is playing through, which the driver then reports as the device's own
// latency. A custom selector is required because the HAL refuses client writes
// to kAudioDevicePropertyLatency itself ('nope'), so it never reaches us.
#define kAttenuatorProperty_DownstreamLatency 'atls'  // UInt32, frames at 48kHz
