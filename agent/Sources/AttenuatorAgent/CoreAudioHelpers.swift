import CoreAudio
import AudioToolbox
import Foundation

// MARK: - Constants

let kAttenuatorDeviceUID = "com.audioattenuator.device.v001"
let kSystemObject = AudioObjectID(kAudioObjectSystemObject)
let kChannels: UInt32 = 2
let kSampleRate: Float64 = 48000.0
let kRingBufferFrames = 65536

// MARK: - CoreAudio helpers

func cfStringToSwift(_ ref: CFString?) -> String {
    guard let ref else { return "" }
    return ref as String
}

func getDeviceName(_ deviceID: AudioObjectID) -> String {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioObjectPropertyName,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var name: CFString? = nil
    var size = UInt32(MemoryLayout<CFString?>.size)
    let status = withUnsafeMutablePointer(to: &name) {
        AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, $0)
    }
    guard status == noErr else { return "?" }
    return cfStringToSwift(name)
}

func getDeviceUID(_ deviceID: AudioObjectID) -> String {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyDeviceUID,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var uid: CFString? = nil
    var size = UInt32(MemoryLayout<CFString?>.size)
    let status = withUnsafeMutablePointer(to: &uid) {
        AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, $0)
    }
    guard status == noErr else { return "" }
    return cfStringToSwift(uid)
}

func deviceHasStreams(_ deviceID: AudioObjectID, scope: AudioObjectPropertyScope) -> Bool {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyStreams,
        mScope: scope,
        mElement: kAudioObjectPropertyElementMain
    )
    var size: UInt32 = 0
    let status = AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size)
    return status == noErr && size > 0
}

func getTransportType(_ deviceID: AudioObjectID) -> UInt32 {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyTransportType,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var transportType: UInt32 = 0
    var size = UInt32(MemoryLayout<UInt32>.size)
    _ = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &transportType)
    return transportType
}

func allDeviceIDs() -> [AudioObjectID] {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDevices,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(kSystemObject, &address, 0, nil, &size) == noErr else {
        return []
    }
    let count = Int(size) / MemoryLayout<AudioObjectID>.size
    var ids = [AudioObjectID](repeating: 0, count: count)
    guard AudioObjectGetPropertyData(kSystemObject, &address, 0, nil, &size, &ids) == noErr else {
        return []
    }
    return ids
}

struct OutputDeviceInfo {
    let deviceID: AudioObjectID
    let name: String
    let uid: String
    let isVirtual: Bool
}

func listOutputDevices() -> [OutputDeviceInfo] {
    allDeviceIDs()
        .filter { deviceHasStreams($0, scope: kAudioObjectPropertyScopeOutput) }
        .map { id in
            OutputDeviceInfo(
                deviceID: id,
                name: getDeviceName(id),
                uid: getDeviceUID(id),
                isVirtual: getTransportType(id) == kAudioDeviceTransportTypeVirtual
            )
        }
}

func findDeviceByUID(_ uid: String) -> AudioObjectID? {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyTranslateUIDToDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var uidRef: CFString = uid as CFString
    var deviceID: AudioObjectID = kAudioObjectUnknown
    var size = UInt32(MemoryLayout<AudioObjectID>.size)
    let status = withUnsafeMutablePointer(to: &uidRef) { uidPtr -> OSStatus in
        withUnsafeMutablePointer(to: &deviceID) { devPtr in
            AudioObjectGetPropertyData(kSystemObject, &address, UInt32(MemoryLayout<CFString>.size), uidPtr, &size, devPtr)
        }
    }
    guard status == noErr, deviceID != kAudioObjectUnknown else { return nil }
    return deviceID
}

/// Reads channel count + sample rate of a device's first stream in the given scope.
func queryStreamFormat(_ deviceID: AudioObjectID, scope: AudioObjectPropertyScope) -> AudioStreamBasicDescription? {
    var streamsAddr = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyStreams,
        mScope: scope,
        mElement: kAudioObjectPropertyElementMain
    )
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(deviceID, &streamsAddr, 0, nil, &size) == noErr, size >= UInt32(MemoryLayout<AudioObjectID>.size) else {
        return nil
    }
    let count = Int(size) / MemoryLayout<AudioObjectID>.size
    var streamIDs = [AudioObjectID](repeating: 0, count: count)
    guard AudioObjectGetPropertyData(deviceID, &streamsAddr, 0, nil, &size, &streamIDs) == noErr, let firstStream = streamIDs.first else {
        return nil
    }

    var formatAddr = AudioObjectPropertyAddress(
        mSelector: kAudioStreamPropertyVirtualFormat,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var format = AudioStreamBasicDescription()
    var formatSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
    guard AudioObjectGetPropertyData(firstStream, &formatAddr, 0, nil, &formatSize, &format) == noErr else {
        return nil
    }
    return format
}

func trySetNominalSampleRate(_ deviceID: AudioObjectID, rate: Float64) {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyNominalSampleRate,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var current: Float64 = 0
    var size = UInt32(MemoryLayout<Float64>.size)
    guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &current) == noErr else { return }
    guard abs(current - rate) > 0.5 else { return }

    var newRate = rate
    let status = AudioObjectSetPropertyData(deviceID, &address, 0, nil, UInt32(MemoryLayout<Float64>.size), &newRate)
    if status != noErr {
        FileHandle.standardError.write("Warning: could not set nominal sample rate to \(rate) Hz on device (status \(status)); leaving at \(current) Hz.\n".data(using: .utf8)!)
    }
}

