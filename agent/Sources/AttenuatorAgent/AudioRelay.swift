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
/// The tap section attaches and detaches independently of the fallback and
/// output paths, so changing which apps are tapped — which requires rebuilding
/// the aggregate device — never interrupts audio for everything else.
///
/// Everything inside the three IOProcs is allocation-, lock-, and syscall-free:
/// gains come from an atomic table and audio moves through lock-free rings.
final class AudioRelay {
    /// Gain slots are allocated once for this many taps so that adding or
    /// removing an app at runtime never resizes the table the audio threads
    /// read from. Far more than anyone will assign individual volumes to.
    static let maxTaps = 64

    private let fallbackDeviceID: AudioObjectID
    private let outputDeviceID: AudioObjectID

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
    /// Frames each path has moved since the last report. Every path should run
    /// at the pipeline's fixed rate; a path running at a different rate is how
    /// a pitch shift gets in, since samples are passed through one-for-one and
    /// nothing resamples them.
    private static let counterFallbackFrames = 4
    private static let counterTapFrames = 5
    private static let counterOutputFrames = 6
    private static let meterSlots = 7

    /// Scratch space for the aggregate IOProc to accumulate its gain-applied
    /// stereo mix, and for the output IOProc to pull each ring into. Allocated
    /// once here, never inside a callback.
    private let tapScratch: UnsafeMutablePointer<Float32>
    private let fallbackScratch: UnsafeMutablePointer<Float32>
    private let mixScratch: UnsafeMutablePointer<Float32>
    private let scratchFrames: Int

    private var fallbackProcID: AudioDeviceIOProcID?
    private var outputUnit: AudioUnit?

    private var aggregateProcID: AudioDeviceIOProcID?
    private var attachedAggregateID: AudioObjectID = kAudioObjectUnknown

    /// Frames moved per path since the last call, then reset. Divided by the
    /// elapsed time this gives each path's real sample rate.
    func takeFrameCounts() -> (fallback: Int, taps: Int, output: Int) {
        let result = (
            Int(catt_gain_store_get(meters, Self.counterFallbackFrames)),
            Int(catt_gain_store_get(meters, Self.counterTapFrames)),
            Int(catt_gain_store_get(meters, Self.counterOutputFrames))
        )
        catt_gain_store_set(meters, Self.counterFallbackFrames, 0)
        catt_gain_store_set(meters, Self.counterTapFrames, 0)
        catt_gain_store_set(meters, Self.counterOutputFrames, 0)
        return result
    }

    /// Read by the output IOProc to decide whether to pull the tap ring.
    /// Stored in the atomic meter table so the audio thread never reads a
    /// value the control thread is mid-write on.
    private let tapActiveSlot = 3

    private var fallbackGainSlot: Int { Self.maxTaps }
    private var masterGainSlot: Int { Self.maxTaps + 1 }

    init(
        fallbackDeviceID: AudioObjectID,
        outputDeviceID: AudioObjectID,
        maxFramesPerCallback: Int = 8192
    ) throws {
        self.fallbackDeviceID = fallbackDeviceID
        self.outputDeviceID = outputDeviceID
        self.scratchFrames = maxFramesPerCallback

        guard let fallbackRing = catt_ring_buffer_create(kRingBufferFrames, Int(kChannels)),
              let tapMixRing = catt_ring_buffer_create(kRingBufferFrames, Int(kChannels)),
              let gains = catt_gain_store_create(Self.maxTaps + 2),
              let meters = catt_gain_store_create(Self.meterSlots) else {
            throw RelayError.allocationFailed
        }
        self.fallbackRing = fallbackRing
        self.tapMixRing = tapMixRing
        self.gains = gains
        self.meters = meters
        for slot in 0..<Self.meterSlots { catt_gain_store_set(meters, slot, 0) }

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

    var fallbackGain: Float { catt_gain_store_get(gains, fallbackGainSlot) }
    var masterGain: Float { catt_gain_store_get(gains, masterGainSlot) }

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

    /// Starts the fallback capture and the output. These stay running for the
    /// lifetime of the relay; the tap section comes and goes around them.
    func start() throws {
        let ring = fallbackRing
        let meterStore = meters
        let scratchCap = scratchFrames * Int(kChannels)

        var fallbackID: AudioDeviceIOProcID?
        let fallbackStatus = AudioDeviceCreateIOProcIDWithBlock(&fallbackID, fallbackDeviceID, nil) { _, inInputData, _, _, _ in
            let list = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inInputData))
            guard let buffer = list.first, let data = buffer.mData else { return }
            let frames = Int(buffer.mDataByteSize) / (Int(kChannels) * MemoryLayout<Float32>.size)
            guard frames > 0 else { return }
            data.withMemoryRebound(to: Float32.self, capacity: frames * Int(kChannels)) { ptr in
                _ = catt_ring_buffer_write(ring, ptr, frames)
            }
            catt_gain_store_set(meterStore, Self.counterFallbackFrames,
                                catt_gain_store_get(meterStore, Self.counterFallbackFrames) + Float(frames))
        }
        guard fallbackStatus == noErr, let fallbackID else {
            throw RelayError.ioProcCreationFailed("fallback capture", fallbackStatus)
        }
        fallbackProcID = fallbackID

        // --- Output: sum both paths, apply master, clamp, hand to the device ---
        //
        // Output goes through a HAL Output AudioUnit rather than a raw IOProc
        // so the unit converts our fixed 48kHz stereo mix to whatever rate the
        // device actually runs at. Writing 48kHz frames straight into a device
        // running at 44.1kHz — which is what most Bluetooth headsets do — plays
        // them ~8.8% slow, about 1.5 semitones flat.
        try startOutputUnit()


        // Start capture before output so the output never runs dry waiting for
        // its first frames.
        let fbStart = AudioDeviceStart(fallbackDeviceID, fallbackID)
        guard fbStart == noErr else { throw RelayError.startFailed("fallback capture", fbStart) }

        guard let unit = outputUnit else { throw RelayError.outputUnitFailed("unit missing", noErr) }
        let unitStart = AudioOutputUnitStart(unit)
        guard unitStart == noErr else { throw RelayError.startFailed("output unit", unitStart) }
    }

    /// Builds the HAL output unit: bound to the chosen device, fed by a render
    /// callback in the pipeline's fixed format, converting on the way out.
    private func startOutputUnit() throws {
        var description = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_HALOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0
        )
        guard let component = AudioComponentFindNext(nil, &description) else {
            throw RelayError.outputUnitFailed("no HAL output component", noErr)
        }

        var unit: AudioUnit?
        var status = AudioComponentInstanceNew(component, &unit)
        guard status == noErr, let unit else {
            throw RelayError.outputUnitFailed("AudioComponentInstanceNew", status)
        }
        outputUnit = unit

        var device = outputDeviceID
        status = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice,
                                      kAudioUnitScope_Global, 0, &device,
                                      UInt32(MemoryLayout<AudioObjectID>.size))
        guard status == noErr else {
            throw RelayError.outputUnitFailed("set CurrentDevice", status)
        }

        // Our side of the unit is always the pipeline format; the unit handles
        // the device's own rate and channel count.
        var format = AudioStreamBasicDescription(
            mSampleRate: kSampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagsNativeFloatPacked,
            mBytesPerPacket: UInt32(Int(kChannels) * MemoryLayout<Float32>.size),
            mFramesPerPacket: 1,
            mBytesPerFrame: UInt32(Int(kChannels) * MemoryLayout<Float32>.size),
            mChannelsPerFrame: kChannels,
            mBitsPerChannel: 32,
            mReserved: 0
        )
        status = AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat,
                                      kAudioUnitScope_Input, 0, &format,
                                      UInt32(MemoryLayout<AudioStreamBasicDescription>.size))
        guard status == noErr else {
            throw RelayError.outputUnitFailed("set input StreamFormat", status)
        }

        var callback = AURenderCallbackStruct(
            inputProc: { refCon, _, _, _, frameCount, ioData in
                let relay = Unmanaged<AudioRelay>.fromOpaque(refCon).takeUnretainedValue()
                return relay.render(frameCount: Int(frameCount), ioData: ioData)
            },
            inputProcRefCon: Unmanaged.passUnretained(self).toOpaque()
        )
        status = AudioUnitSetProperty(unit, kAudioUnitProperty_SetRenderCallback,
                                      kAudioUnitScope_Input, 0, &callback,
                                      UInt32(MemoryLayout<AURenderCallbackStruct>.size))
        guard status == noErr else {
            throw RelayError.outputUnitFailed("set render callback", status)
        }

        status = AudioUnitInitialize(unit)
        guard status == noErr else {
            throw RelayError.outputUnitFailed("AudioUnitInitialize", status)
        }
    }

    /// Render callback body. Allocation-, lock- and syscall-free: gains come
    /// from the atomic table and audio from the lock-free rings.
    private func render(frameCount: Int, ioData: UnsafeMutablePointer<AudioBufferList>?) -> OSStatus {
        guard let ioData else { return noErr }
        let list = UnsafeMutableAudioBufferListPointer(ioData)
        guard let buffer = list.first, let data = buffer.mData else { return noErr }
        guard frameCount > 0, frameCount <= scratchFrames else { return noErr }

        let sampleCount = frameCount * Int(kChannels)
        _ = catt_ring_buffer_read(fallbackRing, fallbackScratch, frameCount)
        if catt_gain_store_get(meters, tapActiveSlot) > 0.5 {
            _ = catt_ring_buffer_read(tapMixRing, mixScratch, frameCount)
        } else {
            mixScratch.update(repeating: 0, count: sampleCount)
        }

        let fallbackGainValue = catt_gain_store_get(gains, Self.maxTaps)
        let masterValue = catt_gain_store_get(gains, Self.maxTaps + 1)

        // Tap contributions already carry their per-app gain; the fallback
        // stream gets its own gain here. Master scales the sum. Boosts above
        // 100% can clip, so hard-limit to [-1, 1] — the same trade-off a
        // Windows-style per-app mixer makes.
        var fbPeak: Float32 = 0
        var outPeak: Float32 = 0
        for i in 0..<sampleCount {
            fbPeak = max(fbPeak, abs(fallbackScratch[i]))
            var v = (fallbackScratch[i] * fallbackGainValue + mixScratch[i]) * masterValue
            if v > 1.0 { v = 1.0 } else if v < -1.0 { v = -1.0 }
            mixScratch[i] = v
            outPeak = max(outPeak, abs(v))
        }
        if fbPeak > catt_gain_store_get(meters, Self.meterFallback) {
            catt_gain_store_set(meters, Self.meterFallback, fbPeak)
        }
        if outPeak > catt_gain_store_get(meters, Self.meterOutput) {
            catt_gain_store_set(meters, Self.meterOutput, outPeak)
        }
        catt_gain_store_set(meters, Self.counterOutputFrames,
                            catt_gain_store_get(meters, Self.counterOutputFrames) + Float(frameCount))

        data.withMemoryRebound(to: Float32.self, capacity: sampleCount) { ptr in
            ptr.update(from: mixScratch, count: sampleCount)
        }
        return noErr
    }

    /// Attaches a tap aggregate. Replaces any previously attached one.
    ///
    /// `tapCount` is the number of sub-taps, and a sub-tap's index is its gain
    /// slot — the aggregate delivers one AudioBuffer per sub-tap in
    /// sub-tap-list order.
    func attachTapAggregate(deviceID: AudioObjectID, tapCount: Int) throws {
        detachTapAggregate()
        guard deviceID != kAudioObjectUnknown, tapCount > 0 else { return }

        let tapRing = tapMixRing
        let gainStore = gains
        let meterStore = meters
        let scratch = tapScratch
        let scratchCap = scratchFrames * Int(kChannels)
        let expectedTaps = min(tapCount, Self.maxTaps)

        var aggID: AudioDeviceIOProcID?
        let status = AudioDeviceCreateIOProcIDWithBlock(&aggID, deviceID, nil) { _, inInputData, _, _, _ in
            let list = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inInputData))
            guard let first = list.first else { return }
            let frames = Int(first.mDataByteSize) / (Int(first.mNumberChannels) * MemoryLayout<Float32>.size)
            guard frames > 0, frames * Int(kChannels) <= scratchCap else { return }

            let sampleCount = frames * Int(kChannels)
            scratch.update(repeating: 0, count: sampleCount)

            for (slot, buffer) in list.enumerated() {
                guard slot < expectedTaps, let data = buffer.mData else { continue }
                let gain = catt_gain_store_get(gainStore, slot)
                if gain == 0 { continue }
                let channels = Int(buffer.mNumberChannels)
                data.withMemoryRebound(to: Float32.self, capacity: frames * channels) { ptr in
                    if channels == Int(kChannels) {
                        for i in 0..<sampleCount { scratch[i] += ptr[i] * gain }
                    } else if channels == 1 {
                        for f in 0..<frames {
                            let v = ptr[f] * gain
                            scratch[f * 2] += v
                            scratch[f * 2 + 1] += v
                        }
                    } else {
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

            catt_gain_store_set(meterStore, Self.counterTapFrames,
                                catt_gain_store_get(meterStore, Self.counterTapFrames) + Float(frames))
            _ = catt_ring_buffer_write(tapRing, scratch, frames)
        }
        guard status == noErr, let aggID else {
            throw RelayError.ioProcCreationFailed("tap aggregate", status)
        }

        let startStatus = AudioDeviceStart(deviceID, aggID)
        guard startStatus == noErr else {
            AudioDeviceDestroyIOProcID(deviceID, aggID)
            throw RelayError.startFailed("tap aggregate", startStatus)
        }

        aggregateProcID = aggID
        attachedAggregateID = deviceID
        catt_gain_store_set(meters, tapActiveSlot, 1)
    }

    func detachTapAggregate() {
        // Tell the output IOProc to stop pulling the tap ring before the
        // producer goes away, so it fills with silence instead of replaying
        // whatever was left in the ring.
        catt_gain_store_set(meters, tapActiveSlot, 0)
        if let aggregateProcID, attachedAggregateID != kAudioObjectUnknown {
            AudioDeviceStop(attachedAggregateID, aggregateProcID)
            AudioDeviceDestroyIOProcID(attachedAggregateID, aggregateProcID)
        }
        aggregateProcID = nil
        attachedAggregateID = kAudioObjectUnknown
        catt_ring_buffer_clear(tapMixRing)
    }

    func stop() {
        detachTapAggregate()
        if let outputUnit {
            AudioOutputUnitStop(outputUnit)
            AudioUnitUninitialize(outputUnit)
            AudioComponentInstanceDispose(outputUnit)
            self.outputUnit = nil
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
    case outputUnitFailed(String, OSStatus)

    var description: String {
        switch self {
        case .allocationFailed:
            return "Failed to allocate ring buffers or gain store"
        case .ioProcCreationFailed(let which, let status):
            return "Failed to create \(which) IOProc (status \(status))"
        case .startFailed(let which, let status):
            return "Failed to start \(which) (status \(status))"
        case .outputUnitFailed(let step, let status):
            return "Output unit setup failed at \(step) (status \(status))"
        }
    }
}
