import CAudioShim
import CoreAudio
import AudioToolbox
import Foundation

// Keep stdout unbuffered so diagnostic lines survive even when the process is
// killed mid-run or its output is redirected to a file (where stdout would
// otherwise be block-buffered and lost).
setvbuf(stdout, nil, _IONBF, 0)

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

// MARK: - CLI

func printUsage() {
    print("""
    Usage: AttenuatorAgent [options]

    Phase 2 smoke test: reads whatever apps write to the Attenuator Device
    (virtual output) and forwards it to a real output device, unmodified.
    No per-app volume control yet (that's Phase 3).

    Options:
      --list-devices        List output-capable devices and exit
      --output <uid|name>   Real output device to forward audio to
                             (defaults to the only non-virtual output device,
                             if exactly one is found)
      --source <uid>        Virtual device to capture from instead of the
                             Attenuator Device (for A/B latency comparisons
                             against other virtual drivers, e.g. BlackHole)
      --duration <seconds>  Stop automatically after N seconds (0 = run until Ctrl+C, default)
      --diag                Log ring buffer backlog and silence->sound onset
                             timestamps. Adds per-sample scanning and printing
                             inside the audio callbacks, which is not
                             real-time safe — use for measurement only.
      --help                Show this message
    """)
}

var outputArg: String? = nil
var sourceArg: String? = nil
var duration: Double = 0
var diagEnabled = false

var args = Array(CommandLine.arguments.dropFirst())
var i = 0
while i < args.count {
    switch args[i] {
    case "--list-devices":
        for d in listOutputDevices() {
            let tag = d.isVirtual ? " [virtual]" : ""
            print("\(d.name)\t\(d.uid)\(tag)")
        }
        exit(0)
    case "--output":
        i += 1
        guard i < args.count else { printUsage(); exit(1) }
        outputArg = args[i]
    case "--source":
        i += 1
        guard i < args.count else { printUsage(); exit(1) }
        sourceArg = args[i]
    case "--duration":
        i += 1
        guard i < args.count, let v = Double(args[i]) else { printUsage(); exit(1) }
        duration = v
    case "--diag":
        diagEnabled = true
    case "--help", "-h":
        printUsage()
        exit(0)
    default:
        FileHandle.standardError.write("Unknown argument: \(args[i])\n".data(using: .utf8)!)
        printUsage()
        exit(1)
    }
    i += 1
}

// MARK: - Resolve devices

let sourceUID = sourceArg ?? kAttenuatorDeviceUID
guard let attenuatorDeviceID = findDeviceByUID(sourceUID) else {
    FileHandle.standardError.write("Source device not found (UID \(sourceUID)). Is the driver installed? See scripts/install.sh.\n".data(using: .utf8)!)
    exit(1)
}
print("Found source device: AudioObjectID \(attenuatorDeviceID) (UID \(sourceUID))")

let outputDevices = listOutputDevices()
var realOutputID: AudioObjectID? = nil

if let outputArg {
    realOutputID = outputDevices.first { $0.uid == outputArg || $0.name == outputArg || $0.name.contains(outputArg) }?.deviceID
    if realOutputID == nil {
        FileHandle.standardError.write("No output device matching '\(outputArg)'. Use --list-devices to see options.\n".data(using: .utf8)!)
        exit(1)
    }
} else {
    let nonVirtual = outputDevices.filter { !$0.isVirtual }
    if nonVirtual.count == 1 {
        realOutputID = nonVirtual[0].deviceID
        print("Defaulting to the only non-virtual output device: \(nonVirtual[0].name)")
    } else {
        FileHandle.standardError.write("Multiple (or zero) non-virtual output devices found; pass --output explicitly. Use --list-devices to see options.\n".data(using: .utf8)!)
        for d in nonVirtual { FileHandle.standardError.write("  \(d.name)\t\(d.uid)\n".data(using: .utf8)!) }
        exit(1)
    }
}

guard let outputDeviceID = realOutputID else { exit(1) }
print("Forwarding to real output device: \(getDeviceName(outputDeviceID))")

// Sanity-check the Attenuator Device's format (should always be 48kHz/stereo/Float32 per the driver).
if let inFormat = queryStreamFormat(attenuatorDeviceID, scope: kAudioObjectPropertyScopeInput) {
    print("Attenuator Device input format: \(inFormat.mChannelsPerFrame)ch @ \(inFormat.mSampleRate)Hz")
}

// Try to align the real device's nominal rate with our fixed internal 48kHz pipeline.
// Known Phase 2 limitation: if the device refuses (e.g. it's shared/locked, or doesn't
// support 48kHz), audio will still play but pitch/speed will be off until a proper
// AudioConverter-based resampling stage is added (see plan §3/§8 risk 6).
trySetNominalSampleRate(outputDeviceID, rate: kSampleRate)

guard let outFormat = queryStreamFormat(outputDeviceID, scope: kAudioObjectPropertyScopeOutput) else {
    FileHandle.standardError.write("Could not read output device's stream format.\n".data(using: .utf8)!)
    exit(1)
}
print("Real output device format: \(outFormat.mChannelsPerFrame)ch @ \(outFormat.mSampleRate)Hz")

let outChannels = Int(outFormat.mChannelsPerFrame)
let outIsFloat = (outFormat.mFormatID == kAudioFormatLinearPCM) && (outFormat.mFormatFlags & kAudioFormatFlagIsFloat) != 0
let outIsInterleaved = (outFormat.mFormatFlags & kAudioFormatFlagIsNonInterleaved) == 0

if !outIsFloat || !outIsInterleaved || outChannels < 2 {
    FileHandle.standardError.write("Real output device format is not interleaved Float32 with >=2 channels; Phase 2 only supports the common case. Got channels=\(outChannels) float=\(outIsFloat) interleaved=\(outIsInterleaved).\n".data(using: .utf8)!)
    exit(1)
}

// MARK: - Ring buffer + IOProcs

guard let ringBuffer = catt_ring_buffer_create(kRingBufferFrames, Int(kChannels)) else {
    FileHandle.standardError.write("Failed to allocate ring buffer.\n".data(using: .utf8)!)
    exit(1)
}
defer { catt_ring_buffer_destroy(ringBuffer) }

var captureProcID: AudioDeviceIOProcID? = nil
var playbackProcID: AudioDeviceIOProcID? = nil

// Onset (silence -> sound) timestamp logging, to bisect where added latency
// comes from: a small, stable gap between "capture onset" and "playback
// onset" means the relay itself (ring buffer + IOProcs) is fine and the
// delay is happening upstream (driver or app-side routing); a large gap
// there would point at the relay itself.
//
// NOT real-time safe: scans every sample and calls print() (which allocates
// and does I/O) from the audio thread. Enabled only under --diag, for
// measurement runs like scripts/measure-onset-latency.sh — never in normal
// operation, where the IOProcs must stay allocation- and lock-free.
final class OnsetTracker: @unchecked Sendable {
    private var wasSilent = true
    private let label: String
    private let threshold: Float32 = 0.01
    init(label: String) { self.label = label }
    func check(_ samples: UnsafePointer<Float32>, count: Int) {
        var peak: Float32 = 0
        for i in 0..<count { peak = max(peak, abs(samples[i])) }
        let isSilent = peak < threshold
        if wasSilent && !isSilent {
            let t = Date().timeIntervalSince1970
            print(String(format: "[diag] %@ onset at %.3f (peak=%.3f)", label, t, peak))
        }
        wasSilent = isSilent
    }
}
let captureOnset = diagEnabled ? OnsetTracker(label: "capture") : nil
let playbackOnset = diagEnabled ? OnsetTracker(label: "playback") : nil

let captureStatus = AudioDeviceCreateIOProcIDWithBlock(&captureProcID, attenuatorDeviceID, nil) { _, inInputData, _, _, _ in
    let bufferList = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inInputData))
    guard let buffer = bufferList.first, let data = buffer.mData else { return }
    let frameCount = Int(buffer.mDataByteSize) / (Int(kChannels) * MemoryLayout<Float32>.size)
    guard frameCount > 0 else { return }
    data.withMemoryRebound(to: Float32.self, capacity: frameCount * Int(kChannels)) { floatPtr in
        captureOnset?.check(floatPtr, count: frameCount * Int(kChannels))
        _ = catt_ring_buffer_write(ringBuffer, floatPtr, frameCount)
    }
}
guard captureStatus == noErr, let captureProcID else {
    FileHandle.standardError.write("Failed to create capture IOProc (status \(captureStatus)).\n".data(using: .utf8)!)
    exit(1)
}

let playbackStatus = AudioDeviceCreateIOProcIDWithBlock(&playbackProcID, outputDeviceID, nil) { _, _, _, outOutputData, _ in
    let bufferList = UnsafeMutableAudioBufferListPointer(outOutputData)
    guard let buffer = bufferList.first, let data = buffer.mData else { return }
    let frameCount = Int(buffer.mDataByteSize) / (outChannels * MemoryLayout<Float32>.size)
    guard frameCount > 0 else { return }

    if outChannels == Int(kChannels) {
        data.withMemoryRebound(to: Float32.self, capacity: frameCount * outChannels) { floatPtr in
            _ = catt_ring_buffer_read(ringBuffer, floatPtr, frameCount)
            playbackOnset?.check(floatPtr, count: frameCount * outChannels)
        }
    } else {
        // Real device has more than 2 channels: read stereo into a scratch
        // buffer, then spread into channels 0/1 and zero the rest.
        var scratch = [Float32](repeating: 0, count: frameCount * Int(kChannels))
        _ = catt_ring_buffer_read(ringBuffer, &scratch, frameCount)
        data.withMemoryRebound(to: Float32.self, capacity: frameCount * outChannels) { floatPtr in
            for frame in 0..<frameCount {
                for ch in 0..<outChannels {
                    floatPtr[frame * outChannels + ch] = ch < Int(kChannels) ? scratch[frame * Int(kChannels) + ch] : 0
                }
            }
            playbackOnset?.check(floatPtr, count: frameCount * outChannels)
        }
    }
}
guard playbackStatus == noErr, let playbackProcID else {
    FileHandle.standardError.write("Failed to create playback IOProc (status \(playbackStatus)).\n".data(using: .utf8)!)
    exit(1)
}

guard AudioDeviceStart(attenuatorDeviceID, captureProcID) == noErr else {
    FileHandle.standardError.write("Failed to start capture on Attenuator Device.\n".data(using: .utf8)!)
    exit(1)
}
guard AudioDeviceStart(outputDeviceID, playbackProcID) == noErr else {
    FileHandle.standardError.write("Failed to start playback on real output device.\n".data(using: .utf8)!)
    exit(1)
}

print("Running. Set Attenuator Device as your system output and play audio in any app.")
print(duration > 0 ? "Stopping automatically after \(duration)s." : "Press Ctrl+C to stop.")

// MARK: - Graceful shutdown

final class ShutdownFlag: @unchecked Sendable {
    var shouldStop = false
}
let shutdownFlag = ShutdownFlag()

signal(SIGINT) { _ in
    shutdownFlag.shouldStop = true
}

let startTime = Date()
var lastReport = Date.distantPast
while !shutdownFlag.shouldStop {
    if duration > 0 && Date().timeIntervalSince(startTime) >= duration {
        break
    }
    if diagEnabled && Date().timeIntervalSince(lastReport) >= 1.0 {
        let backlogFrames = catt_ring_buffer_available_for_read(ringBuffer)
        let backlogMs = Double(backlogFrames) / kSampleRate * 1000.0
        print(String(format: "[diag] agent ring buffer backlog: %d frames (%.1f ms)", backlogFrames, backlogMs))
        lastReport = Date()
    }
    usleep(200_000)
}

print("\nStopping...")
AudioDeviceStop(attenuatorDeviceID, captureProcID)
AudioDeviceStop(outputDeviceID, playbackProcID)
AudioDeviceDestroyIOProcID(attenuatorDeviceID, captureProcID)
AudioDeviceDestroyIOProcID(outputDeviceID, playbackProcID)
print("Stopped.")
