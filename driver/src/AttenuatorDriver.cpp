// Attenuator Virtual Audio Driver
// Based on Apple NullAudio / SoundPusher pattern (ported from the MicLoop reference driver)

#include "AttenuatorDriver.h"

#include <CoreAudio/AudioServerPlugIn.h>
#include <CoreAudio/AudioHardware.h>
#include <CoreFoundation/CoreFoundation.h>
#include <AudioToolbox/AudioToolbox.h>
#include <mach/mach_time.h>
#include <os/lock.h>
#include <pthread.h>
#include <os/log.h>
#include <cstring>
#include <cstdlib>
#include <dispatch/dispatch.h>

#define LOG(fmt, ...) os_log(OS_LOG_DEFAULT, "AudioAttenuator: " fmt, ##__VA_ARGS__)

// Object IDs
enum {
    kObjectID_PlugIn        = kAudioObjectPlugInObject, // 1
    kObjectID_Box           = 2,
    kObjectID_Device        = 3,
    kObjectID_Stream_Input  = 4,
    kObjectID_Stream_Output = 5,
    kObjectID_Volume_Output = 6,
    kObjectID_Mute_Output   = 7,
};

// Constants
static const UInt32 kNumChannels        = 2;
static const Float64 kSampleRate        = 48000.0;
static const UInt32 kBitsPerChannel     = 32;
static const UInt32 kBytesPerFrame      = kNumChannels * sizeof(Float32);
static const UInt32 kBufferFrameSize    = 512;
static const UInt32 kRingBufferFrames   = 65536;
// How far behind the writer the reader is placed on resync: two IO periods
// (~21ms at 48kHz), enough slack for IO-cycle jitter without adding audible lag.
static const UInt32 kResyncSafetyFrames = 2 * kBufferFrameSize;

// Ring buffer for loopback
static Float32 gRingBuffer[kRingBufferFrames * kNumChannels] = {};
static volatile UInt32 gRingWritePos = 0;
static volatile UInt32 gRingReadPos  = 0;
// Set whenever a client starts IO (including a reader attaching after a
// writer has already been running); consumed on the next ReadInput call to
// snap the read position to the current write position. Without this, a
// reader that attaches after audio has already been flowing would start by
// draining stale, already-buffered audio instead of the live signal —
// audible as a fixed startup lag up to the ring buffer's ~1.36s capacity.
static volatile UInt32 gNeedInputResync = 1;

// Driver state
static AudioServerPlugInHostRef gPlugIn_Host = NULL;
static UInt32 gPlugIn_RefCount = 0;
static UInt32 gBox_Acquired = 1; // Start acquired so device is visible immediately

struct DeviceState {
    pthread_mutex_t     mutex;
    os_unfair_lock      unfairLock;

    UInt32              ioRunning;
    Float64             hostTicksPerFrame;
    UInt64              numberTimeStamps;
    Float64             anchorSampleTime;
    UInt64              anchorHostTime;
    UInt64              timelineSeed;

    bool                streamInputActive;
    bool                streamOutputActive;

    Float32             volumeOutput;    // 0.0 - 1.0
    bool                muteOutput;
};

static DeviceState gDevice = {
    .mutex          = PTHREAD_MUTEX_INITIALIZER,
    .unfairLock     = OS_UNFAIR_LOCK_INIT,
    .ioRunning      = 0,
    .hostTicksPerFrame = 0,
    .numberTimeStamps = 0,
    .anchorSampleTime = 0,
    .anchorHostTime   = 0,
    .timelineSeed     = 1,
    .streamInputActive  = true,
    .streamOutputActive = true,
    .volumeOutput       = 1.0f,
    .muteOutput         = false,
};

static AudioStreamBasicDescription gStreamFormat = {
    .mSampleRate       = kSampleRate,
    .mFormatID         = kAudioFormatLinearPCM,
    .mFormatFlags      = kAudioFormatFlagsNativeFloatPacked,
    .mBytesPerPacket   = kBytesPerFrame,
    .mFramesPerPacket  = 1,
    .mBytesPerFrame    = kBytesPerFrame,
    .mChannelsPerFrame = kNumChannels,
    .mBitsPerChannel   = kBitsPerChannel,
};

// Forward declarations
static Boolean Attenuator_HasProperty(AudioServerPlugInDriverRef, AudioObjectID, pid_t, const AudioObjectPropertyAddress*);
static OSStatus Attenuator_IsPropertySettable(AudioServerPlugInDriverRef, AudioObjectID, pid_t, const AudioObjectPropertyAddress*, Boolean*);
static OSStatus Attenuator_GetPropertyDataSize(AudioServerPlugInDriverRef, AudioObjectID, pid_t, const AudioObjectPropertyAddress*, UInt32, const void*, UInt32*);
static OSStatus Attenuator_GetPropertyData(AudioServerPlugInDriverRef, AudioObjectID, pid_t, const AudioObjectPropertyAddress*, UInt32, const void*, UInt32, UInt32*, void*);
static OSStatus Attenuator_SetPropertyData(AudioServerPlugInDriverRef, AudioObjectID, pid_t, const AudioObjectPropertyAddress*, UInt32, const void*, UInt32, const void*);

#pragma mark - Plugin Property Helpers

static Boolean HasPlugInProperty(AudioObjectID, pid_t, const AudioObjectPropertyAddress* addr) {
    switch (addr->mSelector) {
        case kAudioObjectPropertyBaseClass:
        case kAudioObjectPropertyClass:
        case kAudioObjectPropertyOwner:
        case kAudioObjectPropertyManufacturer:
        case kAudioObjectPropertyOwnedObjects:
        case kAudioPlugInPropertyBoxList:
        case kAudioPlugInPropertyTranslateUIDToBox:
        case kAudioPlugInPropertyDeviceList:
        case kAudioPlugInPropertyTranslateUIDToDevice:
        case kAudioPlugInPropertyResourceBundle:
            return true;
        default:
            return false;
    }
}

static OSStatus GetPlugInPropertyDataSize(const AudioObjectPropertyAddress* addr, UInt32* outSize) {
    switch (addr->mSelector) {
        case kAudioObjectPropertyBaseClass:
        case kAudioObjectPropertyClass:
            *outSize = sizeof(AudioClassID);
            return kAudioHardwareNoError;
        case kAudioObjectPropertyOwner:
            *outSize = sizeof(AudioObjectID);
            return kAudioHardwareNoError;
        case kAudioObjectPropertyManufacturer:
        case kAudioPlugInPropertyResourceBundle:
            *outSize = sizeof(CFStringRef);
            return kAudioHardwareNoError;
        case kAudioObjectPropertyOwnedObjects:
            *outSize = (gBox_Acquired ? 2 : 1) * sizeof(AudioObjectID);
            return kAudioHardwareNoError;
        case kAudioPlugInPropertyBoxList:
            *outSize = sizeof(AudioObjectID);
            return kAudioHardwareNoError;
        case kAudioPlugInPropertyTranslateUIDToBox:
        case kAudioPlugInPropertyTranslateUIDToDevice:
            *outSize = sizeof(AudioObjectID);
            return kAudioHardwareNoError;
        case kAudioPlugInPropertyDeviceList:
            *outSize = gBox_Acquired ? sizeof(AudioObjectID) : 0;
            return kAudioHardwareNoError;
        default:
            return kAudioHardwareUnknownPropertyError;
    }
}

static OSStatus GetPlugInPropertyData(const AudioObjectPropertyAddress* addr, UInt32* ioSize, void* outData) {
    switch (addr->mSelector) {
        case kAudioObjectPropertyBaseClass:
            *((AudioClassID*)outData) = kAudioObjectClassID;
            *ioSize = sizeof(AudioClassID);
            return kAudioHardwareNoError;
        case kAudioObjectPropertyClass:
            *((AudioClassID*)outData) = kAudioPlugInClassID;
            *ioSize = sizeof(AudioClassID);
            return kAudioHardwareNoError;
        case kAudioObjectPropertyOwner:
            *((AudioObjectID*)outData) = kAudioObjectUnknown;
            *ioSize = sizeof(AudioObjectID);
            return kAudioHardwareNoError;
        case kAudioObjectPropertyManufacturer:
            *((CFStringRef*)outData) = CFSTR("AudioAttenuator");
            *ioSize = sizeof(CFStringRef);
            return kAudioHardwareNoError;
        case kAudioObjectPropertyOwnedObjects: {
            AudioObjectID* ids = (AudioObjectID*)outData;
            ids[0] = kObjectID_Box;
            if (gBox_Acquired) {
                ids[1] = kObjectID_Device;
                *ioSize = 2 * sizeof(AudioObjectID);
            } else {
                *ioSize = sizeof(AudioObjectID);
            }
            return kAudioHardwareNoError;
        }
        case kAudioPlugInPropertyBoxList:
            *((AudioObjectID*)outData) = kObjectID_Box;
            *ioSize = sizeof(AudioObjectID);
            return kAudioHardwareNoError;
        case kAudioPlugInPropertyTranslateUIDToBox: {
            *((AudioObjectID*)outData) = kObjectID_Box;
            *ioSize = sizeof(AudioObjectID);
            return kAudioHardwareNoError;
        }
        case kAudioPlugInPropertyDeviceList:
            if (gBox_Acquired) {
                *((AudioObjectID*)outData) = kObjectID_Device;
                *ioSize = sizeof(AudioObjectID);
            } else {
                *ioSize = 0;
            }
            return kAudioHardwareNoError;
        case kAudioPlugInPropertyTranslateUIDToDevice: {
            *((AudioObjectID*)outData) = gBox_Acquired ? kObjectID_Device : kAudioObjectUnknown;
            *ioSize = sizeof(AudioObjectID);
            return kAudioHardwareNoError;
        }
        case kAudioPlugInPropertyResourceBundle:
            *((CFStringRef*)outData) = CFSTR("");
            *ioSize = sizeof(CFStringRef);
            return kAudioHardwareNoError;
        default:
            return kAudioHardwareUnknownPropertyError;
    }
}

#pragma mark - Box Property Helpers

static Boolean HasBoxProperty(AudioObjectID, pid_t, const AudioObjectPropertyAddress* addr) {
    switch (addr->mSelector) {
        case kAudioObjectPropertyBaseClass:
        case kAudioObjectPropertyClass:
        case kAudioObjectPropertyOwner:
        case kAudioObjectPropertyName:
        case kAudioObjectPropertyModelName:
        case kAudioObjectPropertyManufacturer:
        case kAudioObjectPropertyOwnedObjects:
        case kAudioBoxPropertyBoxUID:
        case kAudioBoxPropertyTransportType:
        case kAudioBoxPropertyHasAudio:
        case kAudioBoxPropertyHasVideo:
        case kAudioBoxPropertyHasMIDI:
        case kAudioBoxPropertyIsProtected:
        case kAudioBoxPropertyAcquired:
        case kAudioBoxPropertyAcquisitionFailed:
        case kAudioBoxPropertyDeviceList:
            return true;
        default:
            return false;
    }
}

static OSStatus GetBoxPropertyDataSize(const AudioObjectPropertyAddress* addr, UInt32* outSize) {
    switch (addr->mSelector) {
        case kAudioObjectPropertyBaseClass:
        case kAudioObjectPropertyClass:
            *outSize = sizeof(AudioClassID);
            return kAudioHardwareNoError;
        case kAudioObjectPropertyOwner:
            *outSize = sizeof(AudioObjectID);
            return kAudioHardwareNoError;
        case kAudioObjectPropertyName:
        case kAudioObjectPropertyModelName:
        case kAudioObjectPropertyManufacturer:
        case kAudioBoxPropertyBoxUID:
            *outSize = sizeof(CFStringRef);
            return kAudioHardwareNoError;
        case kAudioObjectPropertyOwnedObjects:
            *outSize = 0;
            return kAudioHardwareNoError;
        case kAudioBoxPropertyTransportType:
        case kAudioBoxPropertyHasAudio:
        case kAudioBoxPropertyHasVideo:
        case kAudioBoxPropertyHasMIDI:
        case kAudioBoxPropertyIsProtected:
        case kAudioBoxPropertyAcquired:
        case kAudioBoxPropertyAcquisitionFailed:
            *outSize = sizeof(UInt32);
            return kAudioHardwareNoError;
        case kAudioBoxPropertyDeviceList:
            *outSize = gBox_Acquired ? sizeof(AudioObjectID) : 0;
            return kAudioHardwareNoError;
        default:
            return kAudioHardwareUnknownPropertyError;
    }
}

static OSStatus GetBoxPropertyData(const AudioObjectPropertyAddress* addr, UInt32* ioSize, void* outData) {
    switch (addr->mSelector) {
        case kAudioObjectPropertyBaseClass:
            *((AudioClassID*)outData) = kAudioObjectClassID;
            *ioSize = sizeof(AudioClassID);
            return kAudioHardwareNoError;
        case kAudioObjectPropertyClass:
            *((AudioClassID*)outData) = kAudioBoxClassID;
            *ioSize = sizeof(AudioClassID);
            return kAudioHardwareNoError;
        case kAudioObjectPropertyOwner:
            *((AudioObjectID*)outData) = kObjectID_PlugIn;
            *ioSize = sizeof(AudioObjectID);
            return kAudioHardwareNoError;
        case kAudioObjectPropertyName:
            *((CFStringRef*)outData) = CFSTR("Attenuator Device");
            *ioSize = sizeof(CFStringRef);
            return kAudioHardwareNoError;
        case kAudioObjectPropertyModelName:
            *((CFStringRef*)outData) = CFSTR("Attenuator Virtual Audio");
            *ioSize = sizeof(CFStringRef);
            return kAudioHardwareNoError;
        case kAudioObjectPropertyManufacturer:
            *((CFStringRef*)outData) = CFSTR("AudioAttenuator");
            *ioSize = sizeof(CFStringRef);
            return kAudioHardwareNoError;
        case kAudioObjectPropertyOwnedObjects:
            *ioSize = 0;
            return kAudioHardwareNoError;
        case kAudioBoxPropertyBoxUID:
            *((CFStringRef*)outData) = CFSTR(kBox_UID);
            *ioSize = sizeof(CFStringRef);
            return kAudioHardwareNoError;
        case kAudioBoxPropertyTransportType:
            *((UInt32*)outData) = kAudioDeviceTransportTypeVirtual;
            *ioSize = sizeof(UInt32);
            return kAudioHardwareNoError;
        case kAudioBoxPropertyHasAudio:
            *((UInt32*)outData) = 1;
            *ioSize = sizeof(UInt32);
            return kAudioHardwareNoError;
        case kAudioBoxPropertyHasVideo:
        case kAudioBoxPropertyHasMIDI:
            *((UInt32*)outData) = 0;
            *ioSize = sizeof(UInt32);
            return kAudioHardwareNoError;
        case kAudioBoxPropertyIsProtected:
            *((UInt32*)outData) = 0;
            *ioSize = sizeof(UInt32);
            return kAudioHardwareNoError;
        case kAudioBoxPropertyAcquired:
            *((UInt32*)outData) = gBox_Acquired;
            *ioSize = sizeof(UInt32);
            return kAudioHardwareNoError;
        case kAudioBoxPropertyAcquisitionFailed:
            *((UInt32*)outData) = 0;
            *ioSize = sizeof(UInt32);
            return kAudioHardwareNoError;
        case kAudioBoxPropertyDeviceList:
            if (gBox_Acquired) {
                *((AudioObjectID*)outData) = kObjectID_Device;
                *ioSize = sizeof(AudioObjectID);
            } else {
                *ioSize = 0;
            }
            return kAudioHardwareNoError;
        default:
            return kAudioHardwareUnknownPropertyError;
    }
}

#pragma mark - Device Property Helpers

static Boolean HasDeviceProperty(AudioObjectID, pid_t, const AudioObjectPropertyAddress* addr) {
    switch (addr->mSelector) {
        case kAudioObjectPropertyBaseClass:
        case kAudioObjectPropertyClass:
        case kAudioObjectPropertyOwner:
        case kAudioObjectPropertyName:
        case kAudioObjectPropertyManufacturer:
        case kAudioObjectPropertyOwnedObjects:
        case kAudioDevicePropertyDeviceUID:
        case kAudioDevicePropertyModelUID:
        case kAudioDevicePropertyTransportType:
        case kAudioDevicePropertyRelatedDevices:
        case kAudioDevicePropertyClockDomain:
        case kAudioDevicePropertyDeviceIsAlive:
        case kAudioDevicePropertyDeviceIsRunning:
        case kAudioDevicePropertyDeviceCanBeDefaultDevice:
        case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice:
        case kAudioDevicePropertyLatency:
        case kAudioDevicePropertyStreams:
        case kAudioObjectPropertyControlList:
        case kAudioDevicePropertySafetyOffset:
        case kAudioDevicePropertyNominalSampleRate:
        case kAudioDevicePropertyAvailableNominalSampleRates:
        case kAudioDevicePropertyIsHidden:
        case kAudioDevicePropertyZeroTimeStampPeriod:
        case kAudioDevicePropertyPreferredChannelsForStereo:
        case kAudioDevicePropertyPreferredChannelLayout:
            return true;
        default:
            return false;
    }
}

static OSStatus GetDevicePropertyDataSize(const AudioObjectPropertyAddress* addr, UInt32* outSize) {
    switch (addr->mSelector) {
        case kAudioObjectPropertyBaseClass:
        case kAudioObjectPropertyClass:
            *outSize = sizeof(AudioClassID);
            return kAudioHardwareNoError;
        case kAudioObjectPropertyOwner:
            *outSize = sizeof(AudioObjectID);
            return kAudioHardwareNoError;
        case kAudioObjectPropertyName:
        case kAudioObjectPropertyManufacturer:
        case kAudioDevicePropertyDeviceUID:
        case kAudioDevicePropertyModelUID:
            *outSize = sizeof(CFStringRef);
            return kAudioHardwareNoError;
        case kAudioDevicePropertyStreams:
            if (addr->mScope == kAudioObjectPropertyScopeInput)
                *outSize = sizeof(AudioObjectID);
            else if (addr->mScope == kAudioObjectPropertyScopeOutput)
                *outSize = sizeof(AudioObjectID);
            else
                *outSize = 2 * sizeof(AudioObjectID);
            return kAudioHardwareNoError;
        case kAudioObjectPropertyOwnedObjects:
            // Streams + controls
            if (addr->mScope == kAudioObjectPropertyScopeInput)
                *outSize = sizeof(AudioObjectID); // input stream only
            else if (addr->mScope == kAudioObjectPropertyScopeOutput)
                *outSize = 3 * sizeof(AudioObjectID); // output stream + volume + mute
            else
                *outSize = 4 * sizeof(AudioObjectID); // 2 streams + volume + mute
            return kAudioHardwareNoError;
        case kAudioObjectPropertyControlList:
            *outSize = 2 * sizeof(AudioObjectID); // volume + mute
            return kAudioHardwareNoError;
        case kAudioDevicePropertyTransportType:
        case kAudioDevicePropertyClockDomain:
        case kAudioDevicePropertyDeviceIsAlive:
        case kAudioDevicePropertyDeviceIsRunning:
        case kAudioDevicePropertyDeviceCanBeDefaultDevice:
        case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice:
        case kAudioDevicePropertyLatency:
        case kAudioDevicePropertySafetyOffset:
        case kAudioDevicePropertyIsHidden:
        case kAudioDevicePropertyZeroTimeStampPeriod:
            *outSize = sizeof(UInt32);
            return kAudioHardwareNoError;
        case kAudioDevicePropertyRelatedDevices:
            *outSize = sizeof(AudioObjectID);
            return kAudioHardwareNoError;
        case kAudioDevicePropertyNominalSampleRate:
            *outSize = sizeof(Float64);
            return kAudioHardwareNoError;
        case kAudioDevicePropertyAvailableNominalSampleRates:
            *outSize = sizeof(AudioValueRange);
            return kAudioHardwareNoError;
        case kAudioDevicePropertyPreferredChannelsForStereo:
            *outSize = 2 * sizeof(UInt32);
            return kAudioHardwareNoError;
        case kAudioDevicePropertyPreferredChannelLayout:
            *outSize = (UInt32)(offsetof(AudioChannelLayout, mChannelDescriptions) + kNumChannels * sizeof(AudioChannelDescription));
            return kAudioHardwareNoError;
        default:
            return kAudioHardwareUnknownPropertyError;
    }
}

static OSStatus GetDevicePropertyData(const AudioObjectPropertyAddress* addr, UInt32* ioSize, void* outData) {
    switch (addr->mSelector) {
        case kAudioObjectPropertyBaseClass:
            *((AudioClassID*)outData) = kAudioObjectClassID;
            *ioSize = sizeof(AudioClassID);
            return kAudioHardwareNoError;
        case kAudioObjectPropertyClass:
            *((AudioClassID*)outData) = kAudioDeviceClassID;
            *ioSize = sizeof(AudioClassID);
            return kAudioHardwareNoError;
        case kAudioObjectPropertyOwner:
            *((AudioObjectID*)outData) = kObjectID_PlugIn;
            *ioSize = sizeof(AudioObjectID);
            return kAudioHardwareNoError;
        case kAudioObjectPropertyName:
            *((CFStringRef*)outData) = CFSTR("Attenuator Device");
            *ioSize = sizeof(CFStringRef);
            return kAudioHardwareNoError;
        case kAudioObjectPropertyManufacturer:
            *((CFStringRef*)outData) = CFSTR("AudioAttenuator");
            *ioSize = sizeof(CFStringRef);
            return kAudioHardwareNoError;
        case kAudioDevicePropertyDeviceUID:
            *((CFStringRef*)outData) = CFSTR(kDevice_UID);
            *ioSize = sizeof(CFStringRef);
            return kAudioHardwareNoError;
        case kAudioDevicePropertyModelUID:
            *((CFStringRef*)outData) = CFSTR(kDevice_ModelUID);
            *ioSize = sizeof(CFStringRef);
            return kAudioHardwareNoError;
        case kAudioDevicePropertyStreams: {
            AudioObjectID* ids = (AudioObjectID*)outData;
            if (addr->mScope == kAudioObjectPropertyScopeInput) {
                ids[0] = kObjectID_Stream_Input;
                *ioSize = sizeof(AudioObjectID);
            } else if (addr->mScope == kAudioObjectPropertyScopeOutput) {
                ids[0] = kObjectID_Stream_Output;
                *ioSize = sizeof(AudioObjectID);
            } else {
                ids[0] = kObjectID_Stream_Input;
                ids[1] = kObjectID_Stream_Output;
                *ioSize = 2 * sizeof(AudioObjectID);
            }
            return kAudioHardwareNoError;
        }
        case kAudioObjectPropertyOwnedObjects: {
            AudioObjectID* ids = (AudioObjectID*)outData;
            if (addr->mScope == kAudioObjectPropertyScopeInput) {
                ids[0] = kObjectID_Stream_Input;
                *ioSize = sizeof(AudioObjectID);
            } else if (addr->mScope == kAudioObjectPropertyScopeOutput) {
                ids[0] = kObjectID_Stream_Output;
                ids[1] = kObjectID_Volume_Output;
                ids[2] = kObjectID_Mute_Output;
                *ioSize = 3 * sizeof(AudioObjectID);
            } else {
                ids[0] = kObjectID_Stream_Input;
                ids[1] = kObjectID_Stream_Output;
                ids[2] = kObjectID_Volume_Output;
                ids[3] = kObjectID_Mute_Output;
                *ioSize = 4 * sizeof(AudioObjectID);
            }
            return kAudioHardwareNoError;
        }
        case kAudioDevicePropertyTransportType:
            *((UInt32*)outData) = kAudioDeviceTransportTypeVirtual;
            *ioSize = sizeof(UInt32);
            return kAudioHardwareNoError;
        case kAudioDevicePropertyRelatedDevices:
            *((AudioObjectID*)outData) = kObjectID_Device;
            *ioSize = sizeof(AudioObjectID);
            return kAudioHardwareNoError;
        case kAudioDevicePropertyClockDomain:
            *((UInt32*)outData) = 0;
            *ioSize = sizeof(UInt32);
            return kAudioHardwareNoError;
        case kAudioDevicePropertyDeviceIsAlive:
            *((UInt32*)outData) = 1;
            *ioSize = sizeof(UInt32);
            return kAudioHardwareNoError;
        case kAudioDevicePropertyDeviceIsRunning:
            pthread_mutex_lock(&gDevice.mutex);
            *((UInt32*)outData) = gDevice.ioRunning > 0 ? 1 : 0;
            pthread_mutex_unlock(&gDevice.mutex);
            *ioSize = sizeof(UInt32);
            return kAudioHardwareNoError;
        case kAudioDevicePropertyDeviceCanBeDefaultDevice:
        case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice:
            *((UInt32*)outData) = 1;
            *ioSize = sizeof(UInt32);
            return kAudioHardwareNoError;
        case kAudioDevicePropertyLatency:
        case kAudioDevicePropertySafetyOffset:
            *((UInt32*)outData) = 0;
            *ioSize = sizeof(UInt32);
            return kAudioHardwareNoError;
        case kAudioDevicePropertyNominalSampleRate:
            *((Float64*)outData) = kSampleRate;
            *ioSize = sizeof(Float64);
            return kAudioHardwareNoError;
        case kAudioDevicePropertyAvailableNominalSampleRates: {
            AudioValueRange* r = (AudioValueRange*)outData;
            r->mMinimum = kSampleRate;
            r->mMaximum = kSampleRate;
            *ioSize = sizeof(AudioValueRange);
            return kAudioHardwareNoError;
        }
        case kAudioObjectPropertyControlList: {
            AudioObjectID* ids = (AudioObjectID*)outData;
            ids[0] = kObjectID_Volume_Output;
            ids[1] = kObjectID_Mute_Output;
            *ioSize = 2 * sizeof(AudioObjectID);
            return kAudioHardwareNoError;
        }
        case kAudioDevicePropertyIsHidden:
            *((UInt32*)outData) = 0;
            *ioSize = sizeof(UInt32);
            return kAudioHardwareNoError;
        case kAudioDevicePropertyZeroTimeStampPeriod:
            *((UInt32*)outData) = kBufferFrameSize;
            *ioSize = sizeof(UInt32);
            return kAudioHardwareNoError;
        case kAudioDevicePropertyPreferredChannelsForStereo: {
            UInt32* channels = (UInt32*)outData;
            channels[0] = 1;
            channels[1] = 2;
            *ioSize = 2 * sizeof(UInt32);
            return kAudioHardwareNoError;
        }
        case kAudioDevicePropertyPreferredChannelLayout: {
            AudioChannelLayout* layout = (AudioChannelLayout*)outData;
            layout->mChannelLayoutTag = kAudioChannelLayoutTag_UseChannelDescriptions;
            layout->mChannelBitmap = 0;
            layout->mNumberChannelDescriptions = kNumChannels;
            for (UInt32 i = 0; i < kNumChannels; i++) {
                layout->mChannelDescriptions[i].mChannelLabel = (i == 0) ? kAudioChannelLabel_Left : kAudioChannelLabel_Right;
                layout->mChannelDescriptions[i].mChannelFlags = 0;
                layout->mChannelDescriptions[i].mCoordinates[0] = 0;
                layout->mChannelDescriptions[i].mCoordinates[1] = 0;
                layout->mChannelDescriptions[i].mCoordinates[2] = 0;
            }
            *ioSize = (UInt32)(offsetof(AudioChannelLayout, mChannelDescriptions) + kNumChannels * sizeof(AudioChannelDescription));
            return kAudioHardwareNoError;
        }
        default:
            return kAudioHardwareUnknownPropertyError;
    }
}

#pragma mark - Stream Property Helpers

static Boolean HasStreamProperty(AudioObjectID objectID, pid_t, const AudioObjectPropertyAddress* addr) {
    (void)objectID;
    switch (addr->mSelector) {
        case kAudioObjectPropertyBaseClass:
        case kAudioObjectPropertyClass:
        case kAudioObjectPropertyOwner:
        case kAudioStreamPropertyIsActive:
        case kAudioStreamPropertyDirection:
        case kAudioStreamPropertyTerminalType:
        case kAudioStreamPropertyStartingChannel:
        case kAudioStreamPropertyLatency:
        case kAudioStreamPropertyVirtualFormat:
        case kAudioStreamPropertyPhysicalFormat:
        case kAudioStreamPropertyAvailableVirtualFormats:
        case kAudioStreamPropertyAvailablePhysicalFormats:
            return true;
        default:
            return false;
    }
}

static OSStatus GetStreamPropertyDataSize(AudioObjectID objectID, const AudioObjectPropertyAddress* addr, UInt32* outSize) {
    (void)objectID;
    switch (addr->mSelector) {
        case kAudioObjectPropertyBaseClass:
        case kAudioObjectPropertyClass:
            *outSize = sizeof(AudioClassID);
            return kAudioHardwareNoError;
        case kAudioObjectPropertyOwner:
            *outSize = sizeof(AudioObjectID);
            return kAudioHardwareNoError;
        case kAudioStreamPropertyIsActive:
        case kAudioStreamPropertyDirection:
        case kAudioStreamPropertyTerminalType:
        case kAudioStreamPropertyStartingChannel:
        case kAudioStreamPropertyLatency:
            *outSize = sizeof(UInt32);
            return kAudioHardwareNoError;
        case kAudioStreamPropertyVirtualFormat:
        case kAudioStreamPropertyPhysicalFormat:
            *outSize = sizeof(AudioStreamBasicDescription);
            return kAudioHardwareNoError;
        case kAudioStreamPropertyAvailableVirtualFormats:
        case kAudioStreamPropertyAvailablePhysicalFormats:
            *outSize = sizeof(AudioStreamRangedDescription);
            return kAudioHardwareNoError;
        default:
            return kAudioHardwareUnknownPropertyError;
    }
}

static OSStatus GetStreamPropertyData(AudioObjectID objectID, const AudioObjectPropertyAddress* addr, UInt32* ioSize, void* outData) {
    bool isInput = (objectID == kObjectID_Stream_Input);
    switch (addr->mSelector) {
        case kAudioObjectPropertyBaseClass:
            *((AudioClassID*)outData) = kAudioObjectClassID;
            *ioSize = sizeof(AudioClassID);
            return kAudioHardwareNoError;
        case kAudioObjectPropertyClass:
            *((AudioClassID*)outData) = kAudioStreamClassID;
            *ioSize = sizeof(AudioClassID);
            return kAudioHardwareNoError;
        case kAudioObjectPropertyOwner:
            *((AudioObjectID*)outData) = kObjectID_Device;
            *ioSize = sizeof(AudioObjectID);
            return kAudioHardwareNoError;
        case kAudioStreamPropertyIsActive:
            *((UInt32*)outData) = isInput ? gDevice.streamInputActive : gDevice.streamOutputActive;
            *ioSize = sizeof(UInt32);
            return kAudioHardwareNoError;
        case kAudioStreamPropertyDirection:
            *((UInt32*)outData) = isInput ? 1 : 0;
            *ioSize = sizeof(UInt32);
            return kAudioHardwareNoError;
        case kAudioStreamPropertyTerminalType:
            *((UInt32*)outData) = isInput ? kAudioStreamTerminalTypeMicrophone : kAudioStreamTerminalTypeSpeaker;
            *ioSize = sizeof(UInt32);
            return kAudioHardwareNoError;
        case kAudioStreamPropertyStartingChannel:
            *((UInt32*)outData) = 1;
            *ioSize = sizeof(UInt32);
            return kAudioHardwareNoError;
        case kAudioStreamPropertyLatency:
            *((UInt32*)outData) = 0;
            *ioSize = sizeof(UInt32);
            return kAudioHardwareNoError;
        case kAudioStreamPropertyVirtualFormat:
        case kAudioStreamPropertyPhysicalFormat:
            *((AudioStreamBasicDescription*)outData) = gStreamFormat;
            *ioSize = sizeof(AudioStreamBasicDescription);
            return kAudioHardwareNoError;
        case kAudioStreamPropertyAvailableVirtualFormats:
        case kAudioStreamPropertyAvailablePhysicalFormats: {
            AudioStreamRangedDescription* desc = (AudioStreamRangedDescription*)outData;
            desc->mFormat = gStreamFormat;
            desc->mSampleRateRange.mMinimum = kSampleRate;
            desc->mSampleRateRange.mMaximum = kSampleRate;
            *ioSize = sizeof(AudioStreamRangedDescription);
            return kAudioHardwareNoError;
        }
        default:
            return kAudioHardwareUnknownPropertyError;
    }
}

#pragma mark - Control Property Helpers

static const Float32 kVolume_MinDB = -96.0f;
static const Float32 kVolume_MaxDB = 0.0f;

static Boolean HasControlProperty(AudioObjectID objectID, pid_t, const AudioObjectPropertyAddress* addr) {
    switch (addr->mSelector) {
        case kAudioObjectPropertyBaseClass:
        case kAudioObjectPropertyClass:
        case kAudioObjectPropertyOwner:
        case kAudioObjectPropertyOwnedObjects:
        case kAudioControlPropertyScope:
        case kAudioControlPropertyElement:
            return true;
        case kAudioLevelControlPropertyScalarValue:
        case kAudioLevelControlPropertyDecibelValue:
        case kAudioLevelControlPropertyDecibelRange:
            return (objectID == kObjectID_Volume_Output);
        case kAudioBooleanControlPropertyValue:
            return (objectID == kObjectID_Mute_Output);
        default:
            return false;
    }
}

static OSStatus GetControlPropertyDataSize(AudioObjectID objectID, const AudioObjectPropertyAddress* addr, UInt32* outSize) {
    switch (addr->mSelector) {
        case kAudioObjectPropertyBaseClass:
        case kAudioObjectPropertyClass:
            *outSize = sizeof(AudioClassID);
            return kAudioHardwareNoError;
        case kAudioObjectPropertyOwner:
            *outSize = sizeof(AudioObjectID);
            return kAudioHardwareNoError;
        case kAudioObjectPropertyOwnedObjects:
            *outSize = 0;
            return kAudioHardwareNoError;
        case kAudioControlPropertyScope:
        case kAudioControlPropertyElement:
            *outSize = sizeof(UInt32);
            return kAudioHardwareNoError;
        case kAudioLevelControlPropertyScalarValue:
            if (objectID != kObjectID_Volume_Output) return kAudioHardwareUnknownPropertyError;
            *outSize = sizeof(Float32);
            return kAudioHardwareNoError;
        case kAudioLevelControlPropertyDecibelValue:
            if (objectID != kObjectID_Volume_Output) return kAudioHardwareUnknownPropertyError;
            *outSize = sizeof(Float32);
            return kAudioHardwareNoError;
        case kAudioLevelControlPropertyDecibelRange:
            if (objectID != kObjectID_Volume_Output) return kAudioHardwareUnknownPropertyError;
            *outSize = sizeof(AudioValueRange);
            return kAudioHardwareNoError;
        case kAudioBooleanControlPropertyValue:
            if (objectID != kObjectID_Mute_Output) return kAudioHardwareUnknownPropertyError;
            *outSize = sizeof(UInt32);
            return kAudioHardwareNoError;
        default:
            return kAudioHardwareUnknownPropertyError;
    }
}

static OSStatus GetControlPropertyData(AudioObjectID objectID, const AudioObjectPropertyAddress* addr, UInt32* ioSize, void* outData) {
    switch (addr->mSelector) {
        case kAudioObjectPropertyBaseClass:
            if (objectID == kObjectID_Volume_Output)
                *((AudioClassID*)outData) = kAudioLevelControlClassID;
            else
                *((AudioClassID*)outData) = kAudioBooleanControlClassID;
            *ioSize = sizeof(AudioClassID);
            return kAudioHardwareNoError;
        case kAudioObjectPropertyClass:
            if (objectID == kObjectID_Volume_Output)
                *((AudioClassID*)outData) = kAudioVolumeControlClassID;
            else
                *((AudioClassID*)outData) = kAudioMuteControlClassID;
            *ioSize = sizeof(AudioClassID);
            return kAudioHardwareNoError;
        case kAudioObjectPropertyOwner:
            *((AudioObjectID*)outData) = kObjectID_Device;
            *ioSize = sizeof(AudioObjectID);
            return kAudioHardwareNoError;
        case kAudioObjectPropertyOwnedObjects:
            *ioSize = 0;
            return kAudioHardwareNoError;
        case kAudioControlPropertyScope:
            *((UInt32*)outData) = kAudioObjectPropertyScopeOutput;
            *ioSize = sizeof(UInt32);
            return kAudioHardwareNoError;
        case kAudioControlPropertyElement:
            *((UInt32*)outData) = kAudioObjectPropertyElementMain;
            *ioSize = sizeof(UInt32);
            return kAudioHardwareNoError;
        case kAudioLevelControlPropertyScalarValue:
            *((Float32*)outData) = gDevice.volumeOutput;
            *ioSize = sizeof(Float32);
            return kAudioHardwareNoError;
        case kAudioLevelControlPropertyDecibelValue: {
            // Convert scalar (0-1) to dB (kVolume_MinDB to kVolume_MaxDB)
            Float32 scalar = gDevice.volumeOutput;
            Float32 dB = (scalar > 0.0f) ? (kVolume_MinDB + scalar * (kVolume_MaxDB - kVolume_MinDB)) : -INFINITY;
            *((Float32*)outData) = dB;
            *ioSize = sizeof(Float32);
            return kAudioHardwareNoError;
        }
        case kAudioLevelControlPropertyDecibelRange: {
            AudioValueRange* range = (AudioValueRange*)outData;
            range->mMinimum = kVolume_MinDB;
            range->mMaximum = kVolume_MaxDB;
            *ioSize = sizeof(AudioValueRange);
            return kAudioHardwareNoError;
        }
        case kAudioBooleanControlPropertyValue:
            *((UInt32*)outData) = gDevice.muteOutput ? 1 : 0;
            *ioSize = sizeof(UInt32);
            return kAudioHardwareNoError;
        default:
            return kAudioHardwareUnknownPropertyError;
    }
}

#pragma mark - IUnknown

static HRESULT Attenuator_QueryInterface(void* inDriver, REFIID inUUID, LPVOID* outInterface) {
    (void)inDriver;
    CFUUIDRef reqUUID = CFUUIDCreateFromUUIDBytes(NULL, inUUID);
    if (CFEqual(reqUUID, IUnknownUUID) || CFEqual(reqUUID, kAudioServerPlugInDriverInterfaceUUID)) {
        CFRelease(reqUUID);
        gPlugIn_RefCount++;
        *outInterface = inDriver;
        return S_OK;
    }
    CFRelease(reqUUID);
    *outInterface = NULL;
    return E_NOINTERFACE;
}

static ULONG Attenuator_AddRef(void* inDriver) {
    (void)inDriver;
    return ++gPlugIn_RefCount;
}

static ULONG Attenuator_Release(void* inDriver) {
    (void)inDriver;
    if (gPlugIn_RefCount > 0) gPlugIn_RefCount--;
    return gPlugIn_RefCount;
}

#pragma mark - Basic Operations

static OSStatus Attenuator_Initialize(AudioServerPlugInDriverRef inDriver, AudioServerPlugInHostRef inHost) {
    (void)inDriver;
    LOG("Initialize called");
    gPlugIn_Host = inHost;

    // Calculate host ticks per frame
    struct mach_timebase_info timebase;
    mach_timebase_info(&timebase);
    Float64 nanosPerTick = (Float64)timebase.numer / (Float64)timebase.denom;
    Float64 nanosPerFrame = 1000000000.0 / kSampleRate;
    gDevice.hostTicksPerFrame = nanosPerFrame / nanosPerTick;

    return kAudioHardwareNoError;
}

static OSStatus Attenuator_CreateDevice(AudioServerPlugInDriverRef d, CFDictionaryRef desc, const AudioServerPlugInClientInfo* ci, AudioObjectID* out) {
    (void)d; (void)desc; (void)ci; (void)out;
    return kAudioHardwareUnsupportedOperationError;
}

static OSStatus Attenuator_DestroyDevice(AudioServerPlugInDriverRef d, AudioObjectID dev) {
    (void)d; (void)dev;
    return kAudioHardwareUnsupportedOperationError;
}

static OSStatus Attenuator_AddDeviceClient(AudioServerPlugInDriverRef d, AudioObjectID dev, const AudioServerPlugInClientInfo* ci) {
    (void)d; (void)dev; (void)ci;
    return kAudioHardwareNoError;
}

static OSStatus Attenuator_RemoveDeviceClient(AudioServerPlugInDriverRef d, AudioObjectID dev, const AudioServerPlugInClientInfo* ci) {
    (void)d; (void)dev; (void)ci;
    return kAudioHardwareNoError;
}

static OSStatus Attenuator_PerformDeviceConfigurationChange(AudioServerPlugInDriverRef d, AudioObjectID dev, UInt64 action, void* info) {
    (void)d; (void)dev; (void)action; (void)info;
    return kAudioHardwareNoError;
}

static OSStatus Attenuator_AbortDeviceConfigurationChange(AudioServerPlugInDriverRef d, AudioObjectID dev, UInt64 action, void* info) {
    (void)d; (void)dev; (void)action; (void)info;
    return kAudioHardwareNoError;
}

#pragma mark - Property Dispatch

static Boolean Attenuator_HasProperty(AudioServerPlugInDriverRef d, AudioObjectID objectID, pid_t clientPID, const AudioObjectPropertyAddress* addr) {
    (void)d;
    Boolean result = false;
    switch (objectID) {
        case kObjectID_PlugIn:      result = HasPlugInProperty(objectID, clientPID, addr); break;
        case kObjectID_Box:         result = HasBoxProperty(objectID, clientPID, addr); break;
        case kObjectID_Device:      result = HasDeviceProperty(objectID, clientPID, addr); break;
        case kObjectID_Stream_Input:
        case kObjectID_Stream_Output: result = HasStreamProperty(objectID, clientPID, addr); break;
        case kObjectID_Volume_Output:
        case kObjectID_Mute_Output: result = HasControlProperty(objectID, clientPID, addr); break;
        default: break;
    }
    return result;
}

static OSStatus Attenuator_IsPropertySettable(AudioServerPlugInDriverRef d, AudioObjectID objectID, pid_t clientPID, const AudioObjectPropertyAddress* addr, Boolean* outIsSettable) {
    (void)d; (void)clientPID;
    *outIsSettable = false;
    switch (objectID) {
        case kObjectID_Box:
            if (addr->mSelector == kAudioBoxPropertyAcquired) *outIsSettable = true;
            return kAudioHardwareNoError;
        case kObjectID_Stream_Input:
        case kObjectID_Stream_Output:
            if (addr->mSelector == kAudioStreamPropertyIsActive ||
                addr->mSelector == kAudioStreamPropertyVirtualFormat ||
                addr->mSelector == kAudioStreamPropertyPhysicalFormat)
                *outIsSettable = true;
            return kAudioHardwareNoError;
        case kObjectID_Volume_Output:
            if (addr->mSelector == kAudioLevelControlPropertyScalarValue ||
                addr->mSelector == kAudioLevelControlPropertyDecibelValue)
                *outIsSettable = true;
            return kAudioHardwareNoError;
        case kObjectID_Mute_Output:
            if (addr->mSelector == kAudioBooleanControlPropertyValue)
                *outIsSettable = true;
            return kAudioHardwareNoError;
        default:
            return kAudioHardwareNoError;
    }
}

static OSStatus Attenuator_GetPropertyDataSize(AudioServerPlugInDriverRef d, AudioObjectID objectID, pid_t clientPID, const AudioObjectPropertyAddress* addr, UInt32 qualSize, const void* qualData, UInt32* outSize) {
    (void)d; (void)clientPID; (void)qualSize; (void)qualData;
    OSStatus result;
    switch (objectID) {
        case kObjectID_PlugIn:  result = GetPlugInPropertyDataSize(addr, outSize); break;
        case kObjectID_Box:     result = GetBoxPropertyDataSize(addr, outSize); break;
        case kObjectID_Device:  result = GetDevicePropertyDataSize(addr, outSize); break;
        case kObjectID_Stream_Input:
        case kObjectID_Stream_Output: result = GetStreamPropertyDataSize(objectID, addr, outSize); break;
        case kObjectID_Volume_Output:
        case kObjectID_Mute_Output: result = GetControlPropertyDataSize(objectID, addr, outSize); break;
        default: result = kAudioHardwareBadObjectError; break;
    }
    return result;
}

static OSStatus Attenuator_GetPropertyData(AudioServerPlugInDriverRef d, AudioObjectID objectID, pid_t clientPID, const AudioObjectPropertyAddress* addr, UInt32 qualSize, const void* qualData, UInt32 inDataSize, UInt32* outDataSize, void* outData) {
    (void)d; (void)clientPID; (void)qualSize; (void)qualData; (void)inDataSize;
    OSStatus result;
    switch (objectID) {
        case kObjectID_PlugIn:  result = GetPlugInPropertyData(addr, outDataSize, outData); break;
        case kObjectID_Box:     result = GetBoxPropertyData(addr, outDataSize, outData); break;
        case kObjectID_Device:  result = GetDevicePropertyData(addr, outDataSize, outData); break;
        case kObjectID_Stream_Input:
        case kObjectID_Stream_Output: result = GetStreamPropertyData(objectID, addr, outDataSize, outData); break;
        case kObjectID_Volume_Output:
        case kObjectID_Mute_Output: result = GetControlPropertyData(objectID, addr, outDataSize, outData); break;
        default: result = kAudioHardwareBadObjectError; break;
    }
    return result;
}

static OSStatus Attenuator_SetPropertyData(AudioServerPlugInDriverRef d, AudioObjectID objectID, pid_t clientPID, const AudioObjectPropertyAddress* addr, UInt32 qualSize, const void* qualData, UInt32 inDataSize, const void* inData) {
    (void)d; (void)clientPID; (void)qualSize; (void)qualData; (void)inDataSize;
    if (objectID == kObjectID_Box && addr->mSelector == kAudioBoxPropertyAcquired) {
        gBox_Acquired = *((const UInt32*)inData) != 0;
        if (gPlugIn_Host) {
            dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
                AudioObjectPropertyAddress propAddr = { kAudioPlugInPropertyDeviceList, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
                gPlugIn_Host->PropertiesChanged(gPlugIn_Host, kObjectID_PlugIn, 1, &propAddr);
            });
        }
        return kAudioHardwareNoError;
    }
    if ((objectID == kObjectID_Stream_Input || objectID == kObjectID_Stream_Output) &&
        addr->mSelector == kAudioStreamPropertyIsActive) {
        bool val = *((const UInt32*)inData) != 0;
        if (objectID == kObjectID_Stream_Input)
            gDevice.streamInputActive = val;
        else
            gDevice.streamOutputActive = val;
        return kAudioHardwareNoError;
    }
    // Volume control
    if (objectID == kObjectID_Volume_Output) {
        if (addr->mSelector == kAudioLevelControlPropertyScalarValue) {
            Float32 val = *((const Float32*)inData);
            if (val < 0.0f) val = 0.0f;
            if (val > 1.0f) val = 1.0f;
            gDevice.volumeOutput = val;
            return kAudioHardwareNoError;
        }
        if (addr->mSelector == kAudioLevelControlPropertyDecibelValue) {
            Float32 dB = *((const Float32*)inData);
            // Convert dB to scalar
            Float32 scalar = (dB - kVolume_MinDB) / (kVolume_MaxDB - kVolume_MinDB);
            if (scalar < 0.0f) scalar = 0.0f;
            if (scalar > 1.0f) scalar = 1.0f;
            gDevice.volumeOutput = scalar;
            return kAudioHardwareNoError;
        }
    }
    // Mute control
    if (objectID == kObjectID_Mute_Output && addr->mSelector == kAudioBooleanControlPropertyValue) {
        gDevice.muteOutput = *((const UInt32*)inData) != 0;
        return kAudioHardwareNoError;
    }
    return kAudioHardwareNoError;
}

#pragma mark - IO Operations

static OSStatus Attenuator_StartIO(AudioServerPlugInDriverRef d, AudioObjectID deviceID, UInt32 clientID) {
    (void)d; (void)clientID;
    if (deviceID != kObjectID_Device) return kAudioHardwareBadObjectError;

    pthread_mutex_lock(&gDevice.mutex);
    if (gDevice.ioRunning == 0) {
        gDevice.numberTimeStamps = 0;
        gDevice.anchorSampleTime = 0;
        gDevice.anchorHostTime = mach_absolute_time();
        gDevice.timelineSeed++;
        memset(gRingBuffer, 0, sizeof(gRingBuffer));
        gRingWritePos = 0;
        gRingReadPos = 0;
        LOG("StartIO");
    }
    // Any client (re)starting IO — not just the very first one overall —
    // should resync the reader to "live" rather than replay whatever
    // backlog has piled up since the last time something read.
    gNeedInputResync = 1;
    gDevice.ioRunning++;
    pthread_mutex_unlock(&gDevice.mutex);
    return kAudioHardwareNoError;
}

static OSStatus Attenuator_StopIO(AudioServerPlugInDriverRef d, AudioObjectID deviceID, UInt32 clientID) {
    (void)d; (void)clientID;
    if (deviceID != kObjectID_Device) return kAudioHardwareBadObjectError;

    pthread_mutex_lock(&gDevice.mutex);
    if (gDevice.ioRunning > 0) {
        gDevice.ioRunning--;
        if (gDevice.ioRunning == 0) {
            LOG("StopIO");
        }
    }
    pthread_mutex_unlock(&gDevice.mutex);
    return kAudioHardwareNoError;
}

static OSStatus Attenuator_GetZeroTimeStamp(AudioServerPlugInDriverRef d, AudioObjectID deviceID, UInt32 clientID, Float64* outSampleTime, UInt64* outHostTime, UInt64* outSeed) {
    (void)d; (void)clientID;
    if (deviceID != kObjectID_Device) return kAudioHardwareBadObjectError;

    os_unfair_lock_lock(&gDevice.unfairLock);

    Float64 hostTicksPerPeriod = gDevice.hostTicksPerFrame * (Float64)kBufferFrameSize;
    UInt64 currentHostTime = mach_absolute_time();
    Float64 hostTicksSinceAnchor = (Float64)(currentHostTime - gDevice.anchorHostTime);
    UInt64 periods = (UInt64)(hostTicksSinceAnchor / hostTicksPerPeriod);

    gDevice.numberTimeStamps = periods;
    *outSampleTime = periods * kBufferFrameSize;
    *outHostTime = gDevice.anchorHostTime + (UInt64)(periods * hostTicksPerPeriod);
    *outSeed = gDevice.timelineSeed;

    os_unfair_lock_unlock(&gDevice.unfairLock);
    return kAudioHardwareNoError;
}

static OSStatus Attenuator_WillDoIOOperation(AudioServerPlugInDriverRef d, AudioObjectID deviceID, UInt32 clientID, UInt32 operationID, Boolean* outWillDo, Boolean* outWillDoInPlace) {
    (void)d; (void)deviceID; (void)clientID;
    *outWillDo = false;
    *outWillDoInPlace = true;
    switch (operationID) {
        case kAudioServerPlugInIOOperationWriteMix:
        case kAudioServerPlugInIOOperationReadInput:
            *outWillDo = true;
            break;
    }
    return kAudioHardwareNoError;
}

static OSStatus Attenuator_BeginIOOperation(AudioServerPlugInDriverRef d, AudioObjectID deviceID, UInt32 clientID, UInt32 operationID, UInt32 ioBufferFrameSize, const AudioServerPlugInIOCycleInfo* ioCycleInfo) {
    (void)d; (void)deviceID; (void)clientID; (void)operationID; (void)ioBufferFrameSize; (void)ioCycleInfo;
    return kAudioHardwareNoError;
}

static OSStatus Attenuator_DoIOOperation(AudioServerPlugInDriverRef d, AudioObjectID deviceID, AudioObjectID streamID, UInt32 clientID, UInt32 operationID, UInt32 ioBufferFrameSize, const AudioServerPlugInIOCycleInfo* ioCycleInfo, void* ioMainBuffer, void* ioSecondaryBuffer) {
    (void)d; (void)deviceID; (void)clientID; (void)ioCycleInfo; (void)ioSecondaryBuffer;
    Float32* buffer = (Float32*)ioMainBuffer;
    UInt32 sampleCount = ioBufferFrameSize * kNumChannels;
    UInt32 ringSize = kRingBufferFrames * kNumChannels;

    if (operationID == kAudioServerPlugInIOOperationWriteMix && streamID == kObjectID_Stream_Output) {
        UInt32 writePos = gRingWritePos;
        for (UInt32 i = 0; i < sampleCount; i++) {
            gRingBuffer[(writePos + i) % ringSize] = buffer[i];
        }
        gRingWritePos = (writePos + sampleCount) % ringSize;
    } else if (operationID == kAudioServerPlugInIOOperationReadInput && streamID == kObjectID_Stream_Input) {
        if (gNeedInputResync) {
            // Place the reader just *behind* the writer, not level with it.
            // readPos == writePos would point at the slot the writer has yet
            // to fill, so the reader would serve data from a full lap ago —
            // a fixed ~1.37s (kRingBufferFrames / kSampleRate) of latency.
            // Backing off by a couple of IO periods reads the freshest
            // written audio while still leaving slack for scheduling jitter
            // between the writer's and reader's IO cycles.
            UInt32 margin = kResyncSafetyFrames * kNumChannels;
            gRingReadPos = (gRingWritePos + ringSize - margin) % ringSize;
            gNeedInputResync = 0;
        }
        UInt32 readPos = gRingReadPos;
        for (UInt32 i = 0; i < sampleCount; i++) {
            buffer[i] = gRingBuffer[(readPos + i) % ringSize];
        }
        gRingReadPos = (readPos + sampleCount) % ringSize;
    }

    return kAudioHardwareNoError;
}

static OSStatus Attenuator_EndIOOperation(AudioServerPlugInDriverRef d, AudioObjectID deviceID, UInt32 clientID, UInt32 operationID, UInt32 ioBufferFrameSize, const AudioServerPlugInIOCycleInfo* ioCycleInfo) {
    (void)d; (void)deviceID; (void)clientID; (void)operationID; (void)ioBufferFrameSize; (void)ioCycleInfo;
    return kAudioHardwareNoError;
}

#pragma mark - Driver Interface

static AudioServerPlugInDriverInterface gAudioServerPlugInDriverInterface = {
    NULL,
    Attenuator_QueryInterface,
    Attenuator_AddRef,
    Attenuator_Release,
    Attenuator_Initialize,
    Attenuator_CreateDevice,
    Attenuator_DestroyDevice,
    Attenuator_AddDeviceClient,
    Attenuator_RemoveDeviceClient,
    Attenuator_PerformDeviceConfigurationChange,
    Attenuator_AbortDeviceConfigurationChange,
    Attenuator_HasProperty,
    Attenuator_IsPropertySettable,
    Attenuator_GetPropertyDataSize,
    Attenuator_GetPropertyData,
    Attenuator_SetPropertyData,
    Attenuator_StartIO,
    Attenuator_StopIO,
    Attenuator_GetZeroTimeStamp,
    Attenuator_WillDoIOOperation,
    Attenuator_BeginIOOperation,
    Attenuator_DoIOOperation,
    Attenuator_EndIOOperation,
};

static AudioServerPlugInDriverInterface* gAudioServerPlugInDriverInterfacePtr = &gAudioServerPlugInDriverInterface;
static AudioServerPlugInDriverRef gAudioServerPlugInDriverRef = &gAudioServerPlugInDriverInterfacePtr;

extern "C" void* AudioAttenuator_Create(CFAllocatorRef inAllocator, CFUUIDRef inRequestedTypeUUID) {
    (void)inAllocator;
    LOG("AudioAttenuator_Create called");
    if (CFEqual(inRequestedTypeUUID, kAudioServerPlugInTypeUUID)) {
        LOG("AudioAttenuator_Create: returning driver ref");
        return gAudioServerPlugInDriverRef;
    }
    return NULL;
}
