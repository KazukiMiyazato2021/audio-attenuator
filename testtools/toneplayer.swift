import CoreAudio
import AudioToolbox
import Foundation

// Plays a sine tone to an explicitly chosen output device, so a tap can be
// tested against a known target without touching the system default output.

guard CommandLine.arguments.count > 1 else {
    print("usage: toneplayer <device-uid> [seconds]")
    exit(1)
}
let targetUID = CommandLine.arguments[1]
let seconds = CommandLine.arguments.count > 2 ? Double(CommandLine.arguments[2]) ?? 30 : 30

let kSystemObject = AudioObjectID(kAudioObjectSystemObject)

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

guard let deviceID = findDeviceByUID(targetUID) else {
    print("FAIL: no device with UID \(targetUID)")
    exit(1)
}
print("toneplayer: pid \(getpid()) playing 440Hz to device \(deviceID) (\(targetUID)) for \(seconds)s")

final class Phase: @unchecked Sendable {
    var value: Double = 0
}
let phase = Phase()
let amplitude: Float32 = 0.3
let increment = 2.0 * Double.pi * 440.0 / 48000.0

var procID: AudioDeviceIOProcID?
let status = AudioDeviceCreateIOProcIDWithBlock(&procID, deviceID, nil) { _, _, _, outOutputData, _ in
    let list = UnsafeMutableAudioBufferListPointer(outOutputData)
    guard let buffer = list.first, let data = buffer.mData else { return }
    let channels = Int(buffer.mNumberChannels)
    let frames = Int(buffer.mDataByteSize) / (channels * MemoryLayout<Float32>.size)
    data.withMemoryRebound(to: Float32.self, capacity: frames * channels) { ptr in
        for f in 0..<frames {
            let v = Float32(sin(phase.value)) * amplitude
            phase.value += increment
            if phase.value > 2 * Double.pi { phase.value -= 2 * Double.pi }
            for ch in 0..<channels { ptr[f * channels + ch] = ch < 2 ? v : 0 }
        }
    }
}
guard status == noErr, let procID else {
    print("FAIL: could not create IOProc (status \(status))")
    exit(1)
}

guard AudioDeviceStart(deviceID, procID) == noErr else {
    print("FAIL: could not start device")
    exit(1)
}

Thread.sleep(forTimeInterval: seconds)

AudioDeviceStop(deviceID, procID)
AudioDeviceDestroyIOProcID(deviceID, procID)
print("toneplayer: done")
