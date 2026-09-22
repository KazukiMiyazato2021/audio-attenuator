import CAudioShim
import CoreAudio
import AudioToolbox
import Foundation

/// Wires the three audio paths together:
///
///   Attenuator Device (input)  --> fallbackRing  --\
///                                                   >--> mix --> real output device
///   tap aggregate (N sub-taps) --> tapMixRing    --/
///
/// The fallback path carries every app that is *not* individually tapped; the
/// aggregate carries the tapped apps, each in its own buffer, gain-applied and
/// summed down to stereo before it reaches the ring. That keeps the ring count
/// at two regardless of how many apps are tapped, so adding or removing a tap
/// never allocates a buffer on the audio thread.
///
/// Everything inside the three IOProcs is allocation-, lock-, and syscall-free:
/// gains come from an atomic table and audio moves through lock-free rings.
final class AudioRelay {
    private let fallbackDeviceID: AudioObjectID
    private let outputDeviceID: AudioObjectID
    private let outputChannels: Int
    private let aggregateDeviceID: AudioObjectID
    private let tapCount: Int

    private let fallbackRing: OpaquePointer
    private let tapMixRing: OpaquePointer
    private let gains: OpaquePointer

    /// Peak levels published by the audio threads for the control thread to
    /// read: slot 0 = tap mix, slot 1 = fallback, slot 2 = final output.
    /// Same atomic-float table as the gains — computing a peak and storing it
    /// is allocation- and lock-free, so unlike printing it is safe to do in an
    /// IOProc. Reading and reporting happens on the control thread.
    private let meters: OpaquePointer
    private static let meterTapMix = 0
    private static let meterFallback = 1
    private static let meterOutput = 2

    /// Scratch space for the aggregate IOProc to accumulate its gain-applied
    /// stereo mix, and for the output IOProc to pull each ring into. Allocated
    /// once here, never inside a callback.
    private let tapScratch: UnsafeMutablePointer<Float32>
    private let fallbackScratch: UnsafeMutablePointer<Float32>
    private let mixScratch: UnsafeMutablePointer<Float32>
    private let scratchFrames: Int

    private var fallbackProcID: AudioDeviceIOProcID?
    private var outputProcID: AudioDeviceIOProcID?
    private var aggregateProcID: AudioDeviceIOProcID?

    /// Slot `tapCount` holds the fallback gain, slot `tapCount + 1` the master.
    private var fallbackGainSlot: Int { tapCount }
    private var masterGainSlot: Int { tapCount + 1 }

    init(
        fallbackDeviceID: AudioObjectID,
        outputDeviceID: AudioObjectID,
        outputChannels: Int,
        aggregateDeviceID: AudioObjectID,
        tapCount: Int,
        maxFramesPerCallback: Int = 8192
    ) throws {
        self.fallbackDeviceID = fallbackDeviceID
        self.outputDeviceID = outputDeviceID
        self.outputChannels = outputChannels
        self.aggregateDeviceID = aggregateDeviceID
        self.tapCount = tapCount
        self.scratchFrames = maxFramesPerCallback

        guard let fallbackRing = catt_ring_buffer_create(kRingBufferFrames, Int(kChannels)),
              let tapMixRing = catt_ring_buffer_create(kRingBufferFrames, Int(kChannels)),
              let gains = catt_gain_store_create(tapCount + 2),
              let meters = catt_gain_store_create(3) else {
            throw RelayError.allocationFailed
        }
        self.fallbackRing = fallbackRing
        self.tapMixRing = tapMixRing
        self.gains = gains
        self.meters = meters
        for slot in 0..<3 { catt_gain_store_set(meters, slot, 0) }

        let scratchSamples = maxFramesPerCallback * Int(kChannels)
        tapScratch = .allocate(capacity: scratchSamples)
        tapScratch.initialize(repeating: 0, count: scratchSamples)
        fallbackScratch = .allocate(capacity: scratchSamples)
        fallbackScratch.initialize(repeating: 0, count: scratchSamples)
        mixScratch = .allocate(capacity: scratchSamples)
        mixScratch.initialize(repeating: 0, count: scratchSamples)
    }

    deinit {
        stop()
        catt_ring_buffer_destroy(fallbackRing)
        catt_ring_buffer_destroy(tapMixRing)
        catt_gain_store_destroy(gains)
        catt_gain_store_destroy(meters)
        tapScratch.deallocate()
        fallbackScratch.deallocate()
        mixScratch.deallocate()
    }

    // MARK: - Gain control (called from the control thread)

    func setGain(slot: Int, value: Float) {
        catt_gain_store_set(gains, slot, value)
    }

    func setFallbackGain(_ value: Float) {
        catt_gain_store_set(gains, fallbackGainSlot, value)
    }

    func setMasterGain(_ value: Float) {
        catt_gain_store_set(gains, masterGainSlot, value)
    }

    func gain(slot: Int) -> Float {
        catt_gain_store_get(gains, slot)
    }

    /// Current ring backlogs in frames, for diagnostics.
    var backlogs: (fallback: Int, taps: Int) {
        (catt_ring_buffer_available_for_read(fallbackRing),
         catt_ring_buffer_available_for_read(tapMixRing))
    }

    /// Peak levels seen since the last call, then reset. Lets a caller verify
    /// that a gain change actually moved the signal, without needing to listen.
    func takePeaks() -> (tapMix: Float, fallback: Float, output: Float) {
        let result = (
            catt_gain_store_get(meters, Self.meterTapMix),
            catt_gain_store_get(meters, Self.meterFallback),
            catt_gain_store_get(meters, Self.meterOutput)
        )
        for slot in 0..<3 { catt_gain_store_set(meters, slot, 0) }
        return result
    }

    // MARK: - Lifecycle

    func start() throws {
        let ring = fallbackRing
        let scratchCap = scratchFrames * Int(kChannels)

        // --- Fallback capture: everything not individually tapped ---
        var fallbackID: AudioDeviceIOProcID?
        let fallbackStatus = AudioDeviceCreateIOProcIDWithBlock(&fallbackID, fallbackDeviceID, nil) { _, inInputData, _, _, _ in
            let list = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inInputData))
            guard let buffer = list.first, let data = buffer.mData else { return }
            let frames = Int(buffer.mDataByteSize) / (Int(kChannels) * MemoryLayout<Float32>.size)
            guard frames > 0 else { return }
            data.withMemoryRebound(to: Float32.self, capacity: frames * Int(kChannels)) { ptr in
                _ = catt_ring_buffer_write(ring, ptr, frames)
            }
        }
        guard fallbackStatus == noErr, let fallbackID else {
            throw RelayError.ioProcCreationFailed("fallback capture", fallbackStatus)
        }
        fallbackProcID = fallbackID

        // --- Tap aggregate capture: per-app buffers, gain-applied and summed ---
        if aggregateDeviceID != kAudioObjectUnknown && tapCount > 0 {
            let tapRing = tapMixRing
            let gainStore = gains
            let meterStore = meters
            let scratch = tapScratch
            let expectedTaps = tapCount

            var aggID: AudioDeviceIOProcID?
            let aggStatus = AudioDeviceCreateIOProcIDWithBlock(&aggID, aggregateDeviceID, nil) { _, inInputData, _, _, _ in
                let list = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inInputData))
                guard let first = list.first else { return }
                let frames = Int(first.mDataByteSize) / (Int(first.mNumberChannels) * MemoryLayout<Float32>.size)
                guard frames > 0, frames * Int(kChannels) <= scratchCap else { return }

                let sampleCount = frames * Int(kChannels)
                scratch.update(repeating: 0, count: sampleCount)

                // One buffer per sub-tap, in sub-tap-list order — so buffer
                // index is the app's gain slot.
                for (slot, buffer) in list.enumerated() {
                    guard slot < expectedTaps, let data = buffer.mData else { continue }
                    let gain = catt_gain_store_get(gainStore, slot)
                    if gain == 0 { continue }
                    let channels = Int(buffer.mNumberChannels)
                    data.withMemoryRebound(to: Float32.self, capacity: frames * channels) { ptr in
                        if channels == Int(kChannels) {
                            for i in 0..<sampleCount { scratch[i] += ptr[i] * gain }
                        } else if channels == 1 {
                            // Mono tap: duplicate into both output channels.
                            for f in 0..<frames {
                                let v = ptr[f] * gain
                                scratch[f * 2] += v
                                scratch[f * 2 + 1] += v
                            }
                        } else {
                            // Wider than stereo: take the first two channels.
                            for f in 0..<frames {
                                scratch[f * 2] += ptr[f * channels] * gain
                                scratch[f * 2 + 1] += ptr[f * channels + 1] * gain
                            }
                        }
                    }
                }

                var peak: Float32 = 0
                for i in 0..<sampleCount { peak = max(peak, abs(scratch[i])) }
                if peak > catt_gain_store_get(meterStore, Self.meterTapMix) {
                    catt_gain_store_set(meterStore, Self.meterTapMix, peak)
                }

                _ = catt_ring_buffer_write(tapRing, scratch, frames)
            }
            guard aggStatus == noErr, let aggID else {
                throw RelayError.ioProcCreationFailed("tap aggregate", aggStatus)
            }
            aggregateProcID = aggID
        }

        // --- Output: sum both paths, apply master, clamp, write to hardware ---
        let tapRing = tapMixRing
        let gainStore = gains
        let meterStore = meters
        let fbScratch = fallbackScratch
        let mix = mixScratch
        let outChannels = outputChannels
        let fbSlot = fallbackGainSlot
        let mSlot = masterGainSlot
        let hasTaps = tapCount > 0

        var outID: AudioDeviceIOProcID?
        let outStatus = AudioDeviceCreateIOProcIDWithBlock(&outID, outputDeviceID, nil) { _, _, _, outOutputData, _ in
            let list = UnsafeMutableAudioBufferListPointer(outOutputData)
            guard let buffer = list.first, let data = buffer.mData else { return }
            let frames = Int(buffer.mDataByteSize) / (outChannels * MemoryLayout<Float32>.size)
            guard frames > 0, frames * Int(kChannels) <= scratchCap else { return }

            let sampleCount = frames * Int(kChannels)
            _ = catt_ring_buffer_read(ring, fbScratch, frames)
            if hasTaps {
                _ = catt_ring_buffer_read(tapRing, mix, frames)
            } else {
                mix.update(repeating: 0, count: sampleCount)
            }

            let fallbackGain = catt_gain_store_get(gainStore, fbSlot)
            let master = catt_gain_store_get(gainStore, mSlot)

            // Tap contributions already carry their per-app gain; the fallback
            // stream gets its own gain here. Master scales the sum. Boosts
            // above 100% can clip, so hard-limit to [-1, 1] — the same
            // trade-off a Windows-style per-app mixer makes.
            var fbPeak: Float32 = 0
            var outPeak: Float32 = 0
            for i in 0..<sampleCount {
                fbPeak = max(fbPeak, abs(fbScratch[i]))
                var v = (fbScratch[i] * fallbackGain + mix[i]) * master
                if v > 1.0 { v = 1.0 } else if v < -1.0 { v = -1.0 }
                mix[i] = v
                outPeak = max(outPeak, abs(v))
            }
            if fbPeak > catt_gain_store_get(meterStore, Self.meterFallback) {
                catt_gain_store_set(meterStore, Self.meterFallback, fbPeak)
            }
            if outPeak > catt_gain_store_get(meterStore, Self.meterOutput) {
                catt_gain_store_set(meterStore, Self.meterOutput, outPeak)
            }

            data.withMemoryRebound(to: Float32.self, capacity: frames * outChannels) { ptr in
                if outChannels == Int(kChannels) {
                    ptr.update(from: mix, count: sampleCount)
                } else {
                    for f in 0..<frames {
                        for ch in 0..<outChannels {
                            ptr[f * outChannels + ch] = ch < Int(kChannels) ? mix[f * Int(kChannels) + ch] : 0
                        }
                    }
                }
            }
        }
        guard outStatus == noErr, let outID else {
            throw RelayError.ioProcCreationFailed("output", outStatus)
        }
        outputProcID = outID

        // Start capture paths before the output, so the output never runs dry
        // waiting for its first frames.
        let fbStart = AudioDeviceStart(fallbackDeviceID, fallbackID)
        guard fbStart == noErr else { throw RelayError.startFailed("fallback capture", fbStart) }

        if let aggregateProcID {
            let aggStart = AudioDeviceStart(aggregateDeviceID, aggregateProcID)
            guard aggStart == noErr else { throw RelayError.startFailed("tap aggregate", aggStart) }
        }

        let outStart = AudioDeviceStart(outputDeviceID, outID)
        guard outStart == noErr else { throw RelayError.startFailed("output", outStart) }
    }

    func stop() {
        if let outputProcID {
            AudioDeviceStop(outputDeviceID, outputProcID)
            AudioDeviceDestroyIOProcID(outputDeviceID, outputProcID)
            self.outputProcID = nil
        }
        if let aggregateProcID {
            AudioDeviceStop(aggregateDeviceID, aggregateProcID)
            AudioDeviceDestroyIOProcID(aggregateDeviceID, aggregateProcID)
            self.aggregateProcID = nil
        }
        if let fallbackProcID {
            AudioDeviceStop(fallbackDeviceID, fallbackProcID)
            AudioDeviceDestroyIOProcID(fallbackDeviceID, fallbackProcID)
            self.fallbackProcID = nil
        }
    }
}

enum RelayError: Error, CustomStringConvertible {
    case allocationFailed
    case ioProcCreationFailed(String, OSStatus)
    case startFailed(String, OSStatus)

    var description: String {
        switch self {
        case .allocationFailed:
            return "Failed to allocate ring buffers or gain store"
        case .ioProcCreationFailed(let which, let status):
            return "Failed to create \(which) IOProc (status \(status))"
        case .startFailed(let which, let status):
            return "Failed to start \(which) (status \(status))"
        }
    }
}
