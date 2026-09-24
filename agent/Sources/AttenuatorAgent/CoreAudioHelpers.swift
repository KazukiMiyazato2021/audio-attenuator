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

struct OutputDeviceInfo: Equatable {
    let deviceID: AudioObjectID
    let name: String
    let uid: String
    let transportType: UInt32

    var isVirtual: Bool { transportType == kAudioDeviceTransportTypeVirtual }

    /// Aggregate and multi-output devices are real enough to appear in the
    /// device list but are usually built *on top of* other devices — including,
    /// potentially, our own virtual device. Auto-selecting one can route the
    /// mix back into the loop or into a device that plays nothing, so they are
    /// offered but never chosen automatically.
    var isAggregate: Bool {
        transportType == kAudioDeviceTransportTypeAggregate
    }

    /// True for actual hardware the user can hear.
    var isPhysical: Bool { !isVirtual && !isAggregate }
}

func listOutputDevices() -> [OutputDeviceInfo] {
    allDeviceIDs()
        .filter { deviceHasStreams($0, scope: kAudioObjectPropertyScopeOutput) }
        .map { id in
            OutputDeviceInfo(
                deviceID: id,
                name: getDeviceName(id),
                uid: getDeviceUID(id),
                transportType: getTransportType(id)
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



/// The device macOS is currently using as the system default output.
func defaultOutputDeviceID() -> AudioObjectID? {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var deviceID: AudioObjectID = kAudioObjectUnknown
    var size = UInt32(MemoryLayout<AudioObjectID>.size)
    guard AudioObjectGetPropertyData(kSystemObject, &address, 0, nil, &size, &deviceID) == noErr,
          deviceID != kAudioObjectUnknown else { return nil }
    return deviceID
}

/// Picks where the final mix should play when the user has not chosen.
///
/// Prefers built-in hardware, then any other physical device. Aggregate and
/// multi-output devices are skipped: they are frequently built on top of the
/// Attenuator Device itself, so routing the mix into one can feed our own
/// output back into our own input.
func autoSelectOutputDevice(from devices: [OutputDeviceInfo]) -> OutputDeviceInfo? {
    let physical = devices.filter(\.isPhysical)
    if let builtIn = physical.first(where: { $0.transportType == kAudioDeviceTransportTypeBuiltIn }) {
        return builtIn
    }
    return physical.first
}

// MARK: - Device volume / mute

/// The device's main output volume, 0.0-1.0, as the OS volume keys and the
/// Sound settings slider set it.
///
/// Our driver stores this but does not apply it to the samples it passes
/// through — CoreAudio leaves that to the driver, and applying it there would
/// miss audio that reaches the mix through process taps instead of through the
/// device. The agent applies it to the final mix so it affects everything.
func deviceVolumeScalar(_ deviceID: AudioObjectID) -> Float? {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyVolumeScalar,
        mScope: kAudioObjectPropertyScopeOutput,
        mElement: kAudioObjectPropertyElementMain
    )
    var value: Float32 = 0
    var size = UInt32(MemoryLayout<Float32>.size)
    guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &value) == noErr else { return nil }
    return value
}

func deviceMuted(_ deviceID: AudioObjectID) -> Bool? {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyMute,
        mScope: kAudioObjectPropertyScopeOutput,
        mElement: kAudioObjectPropertyElementMain
    )
    var value: UInt32 = 0
    var size = UInt32(MemoryLayout<UInt32>.size)
    guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &value) == noErr else { return nil }
    return value != 0
}

/// Watches a device property, calling `handler` on the main queue whenever it
/// changes. Returns the block needed to unregister, or nil if registration
/// failed.
func addDevicePropertyListener(
    _ deviceID: AudioObjectID,
    selector: AudioObjectPropertySelector,
    scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeOutput,
    handler: @escaping () -> Void
) -> AudioObjectPropertyListenerBlock? {
    var address = AudioObjectPropertyAddress(
        mSelector: selector,
        mScope: scope,
        mElement: kAudioObjectPropertyElementMain
    )
    let block: AudioObjectPropertyListenerBlock = { _, _ in handler() }
    guard AudioObjectAddPropertyListenerBlock(deviceID, &address, DispatchQueue.main, block) == noErr else {
        return nil
    }
    return block
}

func removeDevicePropertyListener(
    _ deviceID: AudioObjectID,
    selector: AudioObjectPropertySelector,
    scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeOutput,
    block: @escaping AudioObjectPropertyListenerBlock
) {
    var address = AudioObjectPropertyAddress(
        mSelector: selector,
        mScope: scope,
        mElement: kAudioObjectPropertyElementMain
    )
    AudioObjectRemovePropertyListenerBlock(deviceID, &address, DispatchQueue.main, block)
}

// MARK: - Latency

/// A device's reported output latency in frames, plus its safety offset.
func deviceOutputLatencyFrames(_ deviceID: AudioObjectID) -> UInt32 {
    func read(_ selector: AudioObjectPropertySelector) -> UInt32 {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &value) == noErr else { return 0 }
        return value
    }
    return read(kAudioDevicePropertyLatency) + read(kAudioDevicePropertySafetyOffset)
}

/// Tells the Attenuator Device how far behind the real output is, so that apps
/// asking it for latency get a truthful answer.
///
/// Without this, every app sees the virtual device's own latency — effectively
/// zero — and video players line video up against that. Play through a
/// Bluetooth headset, which can be 200ms+ behind on its own, and the result is
/// audio that visibly trails the picture even though nothing in the mixer is
/// slow.
/// Custom selector — must match kAttenuatorProperty_DownstreamLatency in the
/// driver. A custom one is required: the HAL rejects client writes to
/// kAudioDevicePropertyLatency with 'nope' before they ever reach the driver.
let kAttenuatorPropertyDownstreamLatency: AudioObjectPropertySelector = 0x61746C73  // 'atls'

func publishDownstreamLatency(toDevice deviceID: AudioObjectID, frames: UInt32) -> OSStatus {
    var address = AudioObjectPropertyAddress(
        mSelector: kAttenuatorPropertyDownstreamLatency,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    // Custom plug-in properties travel as CFString or CFPropertyList only, so
    // the frame count rides in a CFNumber rather than going across as a UInt32.
    var value = CFNumberCreate(nil, .sInt32Type, [Int32(min(frames, UInt32(Int32.max)))]) as CFPropertyList?
    return withUnsafeMutablePointer(to: &value) { ptr in
        AudioObjectSetPropertyData(deviceID, &address, 0, nil,
                                   UInt32(MemoryLayout<CFPropertyList?>.size), ptr)
    }
}
