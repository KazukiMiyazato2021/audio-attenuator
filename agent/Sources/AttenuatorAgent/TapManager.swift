import CoreAudio
import AudioToolbox
import Foundation

/// One app whose audio we have pulled out of the normal output path.
///
/// `processObjectIDs` is plural because a single app can span several audio
/// processes (browser helper/GPU processes), and all of them belong to the
/// same tap so they share one volume.
struct TappedApp {
    let selector: String
    let displayName: String
    let processObjectIDs: [AudioObjectID]
    let tapID: AudioObjectID
    let tapUUID: String
    /// Index into the gain store and into the aggregate IOProc's buffer list.
    /// Verified empirically: an aggregate with N taps delivers N AudioBuffers,
    /// one per sub-tap, in sub-tap-list order (see scripts/probe-process-tap.swift).
    let slot: Int
}

/// Owns the per-app process taps and the single private aggregate device that
/// carries all of them into one IOProc.
///
/// Every tap is created with `muteBehavior = .muted` so a tapped app's audio
/// stops reaching its normal output route the moment it is tapped. That keeps
/// the invariant the whole design rests on: an app's audio flows through the
/// fallback path *or* through its own tap, never both and never neither.
final class TapManager {
    private(set) var tapped: [TappedApp] = []
    private(set) var aggregateDeviceID: AudioObjectID = kAudioObjectUnknown

    private let aggregateUID = "com.audioattenuator.mixer.aggregate"

    deinit {
        teardown()
    }

    /// Tears down the aggregate and every tap. Safe to call repeatedly.
    func teardown() {
        if aggregateDeviceID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
            aggregateDeviceID = kAudioObjectUnknown
        }
        for app in tapped {
            AudioHardwareDestroyProcessTap(app.tapID)
        }
        tapped = []
    }

    /// Creates a muted tap per requested app, then one private aggregate device
    /// containing all of them.
    ///
    /// Apps that cannot be tapped are reported and skipped rather than failing
    /// the whole run — a single unexpectedly untappable process should not take
    /// the mixer down with it, and skipping leaves that app on the fallback
    /// path, still audible at the fallback gain.
    func setup(selectors: [String]) throws {
        teardown()

        var created: [TappedApp] = []
        for selector in selectors {
            let procs = ProcessRegistry.resolve(selector: selector)
            guard !procs.isEmpty else {
                FileHandle.standardError.write("Skipping '\(selector)': no running audio process matches.\n".data(using: .utf8)!)
                continue
            }

            let objectIDs = procs.map(\.objectID)
            let desc = CATapDescription(stereoMixdownOfProcesses: objectIDs)
            desc.name = "Attenuator tap: \(selector)"
            desc.isPrivate = true
            desc.isExclusive = false
            desc.muteBehavior = .muted

            var tapID: AudioObjectID = kAudioObjectUnknown
            let status = AudioHardwareCreateProcessTap(desc, &tapID)
            guard status == noErr else {
                FileHandle.standardError.write("Skipping '\(selector)': AudioHardwareCreateProcessTap failed (status \(status)).\n".data(using: .utf8)!)
                continue
            }

            created.append(TappedApp(
                selector: selector,
                displayName: procs[0].displayName,
                processObjectIDs: objectIDs,
                tapID: tapID,
                tapUUID: desc.uuid.uuidString,
                slot: created.count
            ))
        }

        guard !created.isEmpty else {
            tapped = []
            return
        }

        let composition: [String: Any] = [
            kAudioAggregateDeviceNameKey as String: "Attenuator Mixer",
            kAudioAggregateDeviceUIDKey as String: aggregateUID,
            kAudioAggregateDeviceIsPrivateKey as String: 1,
            kAudioAggregateDeviceIsStackedKey as String: 0,
            // Wait for a tapped app to actually produce audio before starting,
            // so the aggregate does not spin with nothing to deliver. Requires
            // the device to be private, which it is.
            kAudioAggregateDeviceTapAutoStartKey as String: 1,
            kAudioAggregateDeviceSubDeviceListKey as String: [],
            kAudioAggregateDeviceTapListKey as String: created.map {
                [
                    kAudioSubTapUIDKey as String: $0.tapUUID,
                    kAudioSubTapDriftCompensationKey as String: 1,
                ]
            },
        ]

        var deviceID: AudioObjectID = kAudioObjectUnknown
        let status = AudioHardwareCreateAggregateDevice(composition as CFDictionary, &deviceID)
        guard status == noErr else {
            for app in created { AudioHardwareDestroyProcessTap(app.tapID) }
            throw TapError.aggregateCreationFailed(status)
        }

        aggregateDeviceID = deviceID
        tapped = created

        // Align the aggregate with the rest of the pipeline's fixed 48kHz
        // format so no resampling is needed between the taps and the mixer.
        trySetNominalSampleRate(deviceID, rate: kSampleRate)
    }

    /// Number of input buffers the aggregate's IOProc is expected to deliver.
    /// Read back from the device rather than assumed, so a mismatch surfaces
    /// as a clear error instead of misrouted audio.
    func aggregateInputBufferCount() -> Int? {
        guard aggregateDeviceID != kAudioObjectUnknown else { return nil }
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(aggregateDeviceID, &addr, 0, nil, &size) == noErr, size > 0 else {
            return nil
        }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(aggregateDeviceID, &addr, 0, nil, &size, raw) == noErr else {
            return nil
        }
        return UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self)).count
    }
}

enum TapError: Error, CustomStringConvertible {
    case aggregateCreationFailed(OSStatus)

    var description: String {
        switch self {
        case .aggregateCreationFailed(let status):
            return "AudioHardwareCreateAggregateDevice failed (status \(status))"
        }
    }
}
