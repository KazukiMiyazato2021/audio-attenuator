import CAudioShim
import CoreAudio
import AudioToolbox
import Foundation

// Keep stdout unbuffered so diagnostic lines survive even when the process is
// killed mid-run or its output is redirected to a file (where stdout would
// otherwise be block-buffered and lost).
setvbuf(stdout, nil, _IONBF, 0)

// MARK: - CLI

func printUsage() {
    print("""
    Usage: AttenuatorAgent [options]

    Routes audio sent to the Attenuator Device out to a real output device,
    applying an independent volume to each app you choose to tap. Apps you do
    not tap keep playing through the fallback path at the fallback gain, so
    nothing is ever silently dropped.

    Options:
      --list-devices        List output-capable devices and exit
      --list-apps           List audio-producing processes and exit
      --tap <bundle>=<pct>  Give one app its own volume, 0-150 (repeatable).
                             e.g. --tap com.google.Chrome.beta=30
      --fallback <pct>      Volume for every app that is not tapped (default 100)
      --master <pct>        Overall volume applied to the final mix (default 100)
      --output <uid|name>   Real output device to play the mix through
                             (defaults to the only non-virtual output device)
      --source <uid>        Capture from this device instead of the Attenuator
                             Device (for A/B comparisons against other drivers)
      --duration <seconds>  Stop automatically after N seconds (0 = until Ctrl+C)
      --diag                Log ring backlogs and silence->sound onsets. Adds
                             per-sample scanning and printing inside the audio
                             callbacks, which is not real-time safe — for
                             measurement runs only.
      --help                Show this message
    """)
}

func parsePercent(_ raw: String, label: String) -> Float {
    guard let pct = Float(raw), pct >= 0, pct <= 150 else {
        FileHandle.standardError.write("Invalid \(label) '\(raw)': expected a number between 0 and 150.\n".data(using: .utf8)!)
        exit(1)
    }
    return pct / 100.0
}

var outputArg: String? = nil
var sourceArg: String? = nil
var duration: Double = 0
var diagEnabled = false
var fallbackGain: Float = 1.0
var masterGain: Float = 1.0
var requestedTaps: [(bundleID: String, gain: Float)] = []

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
    case "--list-apps":
        for p in ProcessRegistry.outputCapable() {
            let mark = p.isRunningOutput ? "  <-- playing now" : ""
            print("\(p.bundleID)\tpid=\(p.pid)\t\(p.displayName)\(mark)")
        }
        exit(0)
    case "--tap":
        i += 1
        guard i < args.count else { printUsage(); exit(1) }
        let parts = args[i].split(separator: "=", maxSplits: 1)
        guard parts.count == 2 else {
            FileHandle.standardError.write("--tap expects <bundleID>=<percent>, got '\(args[i])'.\n".data(using: .utf8)!)
            exit(1)
        }
        requestedTaps.append((String(parts[0]), parsePercent(String(parts[1]), label: "tap volume")))
    case "--fallback":
        i += 1
        guard i < args.count else { printUsage(); exit(1) }
        fallbackGain = parsePercent(args[i], label: "fallback volume")
    case "--master":
        i += 1
        guard i < args.count else { printUsage(); exit(1) }
        masterGain = parsePercent(args[i], label: "master volume")
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
guard let fallbackDeviceID = findDeviceByUID(sourceUID) else {
    FileHandle.standardError.write("Source device not found (UID \(sourceUID)). Is the driver installed? See scripts/install.sh.\n".data(using: .utf8)!)
    exit(1)
}
print("Source device: AudioObjectID \(fallbackDeviceID) (UID \(sourceUID))")

let outputDevices = listOutputDevices()
var resolvedOutput: AudioObjectID? = nil

if let outputArg {
    resolvedOutput = outputDevices.first { $0.uid == outputArg || $0.name == outputArg || $0.name.contains(outputArg) }?.deviceID
    if resolvedOutput == nil {
        FileHandle.standardError.write("No output device matching '\(outputArg)'. Use --list-devices to see options.\n".data(using: .utf8)!)
        exit(1)
    }
} else {
    let nonVirtual = outputDevices.filter { !$0.isVirtual }
    if nonVirtual.count == 1 {
        resolvedOutput = nonVirtual[0].deviceID
        print("Defaulting to the only non-virtual output device: \(nonVirtual[0].name)")
    } else {
        FileHandle.standardError.write("Multiple (or zero) non-virtual output devices found; pass --output explicitly.\n".data(using: .utf8)!)
        for d in nonVirtual { FileHandle.standardError.write("  \(d.name)\t\(d.uid)\n".data(using: .utf8)!) }
        exit(1)
    }
}

guard let outputDeviceID = resolvedOutput else { exit(1) }
print("Output device: \(getDeviceName(outputDeviceID))")

trySetNominalSampleRate(outputDeviceID, rate: kSampleRate)

guard let outFormat = queryStreamFormat(outputDeviceID, scope: kAudioObjectPropertyScopeOutput) else {
    FileHandle.standardError.write("Could not read output device's stream format.\n".data(using: .utf8)!)
    exit(1)
}
print("Output format: \(outFormat.mChannelsPerFrame)ch @ \(outFormat.mSampleRate)Hz")

let outChannels = Int(outFormat.mChannelsPerFrame)
let outIsFloat = (outFormat.mFormatID == kAudioFormatLinearPCM) && (outFormat.mFormatFlags & kAudioFormatFlagIsFloat) != 0
let outIsInterleaved = (outFormat.mFormatFlags & kAudioFormatFlagIsNonInterleaved) == 0

if !outIsFloat || !outIsInterleaved || outChannels < 2 {
    FileHandle.standardError.write("Output device format unsupported: needs interleaved Float32 with >=2 channels (got channels=\(outChannels) float=\(outIsFloat) interleaved=\(outIsInterleaved)).\n".data(using: .utf8)!)
    exit(1)
}

// MARK: - Set up taps

let tapManager = TapManager()
if !requestedTaps.isEmpty {
    do {
        try tapManager.setup(selectors: requestedTaps.map(\.bundleID))
    } catch {
        FileHandle.standardError.write("Tap setup failed: \(error)\n".data(using: .utf8)!)
        exit(1)
    }

    if tapManager.tapped.isEmpty {
        print("No requested app could be tapped; everything will play through the fallback path.")
    } else {
        print("Tapped \(tapManager.tapped.count) app(s):")
        for app in tapManager.tapped {
            print("  slot \(app.slot): \(app.selector) -> \(app.processObjectIDs.count) process(es), \(app.displayName)")
        }
        // The buffer-per-sub-tap layout is what the gain slots rely on, so
        // verify it against the device rather than trusting the assumption.
        if let bufferCount = tapManager.aggregateInputBufferCount(), bufferCount != tapManager.tapped.count {
            FileHandle.standardError.write("Warning: aggregate reports \(bufferCount) input buffer(s) for \(tapManager.tapped.count) tap(s); per-app gains may be misapplied.\n".data(using: .utf8)!)
        }
    }
}

// MARK: - Start the relay

let relay: AudioRelay
do {
    relay = try AudioRelay(
        fallbackDeviceID: fallbackDeviceID,
        outputDeviceID: outputDeviceID,
        outputChannels: outChannels,
        aggregateDeviceID: tapManager.aggregateDeviceID,
        tapCount: tapManager.tapped.count
    )
} catch {
    FileHandle.standardError.write("Relay setup failed: \(error)\n".data(using: .utf8)!)
    tapManager.teardown()
    exit(1)
}

// Apply the requested gains. Tapped apps use their slot; anything not tapped
// rides the fallback gain, so no app is ever left silent by default.
for app in tapManager.tapped {
    if let requested = requestedTaps.first(where: { $0.bundleID == app.selector }) {
        relay.setGain(slot: app.slot, value: requested.gain)
    }
}
relay.setFallbackGain(fallbackGain)
relay.setMasterGain(masterGain)

do {
    try relay.start()
} catch {
    FileHandle.standardError.write("Failed to start audio: \(error)\n".data(using: .utf8)!)
    tapManager.teardown()
    exit(1)
}

print("")
print("Running. Set Attenuator Device as your system output and play audio.")
print("  fallback (untapped apps): \(Int(fallbackGain * 100))%   master: \(Int(masterGain * 100))%")
for app in tapManager.tapped {
    print("  \(app.selector): \(Int(relay.gain(slot: app.slot) * 100))%")
}
print(duration > 0 ? "Stopping automatically after \(duration)s." : "Press Ctrl+C to stop.")

// MARK: - Run loop

final class ShutdownFlag: @unchecked Sendable {
    var shouldStop = false
}
let shutdownFlag = ShutdownFlag()

signal(SIGINT) { _ in shutdownFlag.shouldStop = true }
signal(SIGTERM) { _ in shutdownFlag.shouldStop = true }

let startTime = Date()
var lastReport = Date.distantPast
while !shutdownFlag.shouldStop {
    if duration > 0 && Date().timeIntervalSince(startTime) >= duration { break }
    if diagEnabled && Date().timeIntervalSince(lastReport) >= 1.0 {
        let b = relay.backlogs
        let p = relay.takePeaks()
        print(String(
            format: "[diag] backlog fallback=%d (%.1f ms) taps=%d (%.1f ms) | peak tapmix=%.4f fallback=%.4f out=%.4f",
            b.fallback, Double(b.fallback) / kSampleRate * 1000.0,
            b.taps, Double(b.taps) / kSampleRate * 1000.0,
            p.tapMix, p.fallback, p.output
        ))
        lastReport = Date()
    }
    usleep(200_000)
}

print("\nStopping...")
relay.stop()
tapManager.teardown()
print("Stopped.")
