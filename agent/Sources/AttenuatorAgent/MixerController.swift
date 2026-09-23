import AppKit
import CoreAudio
import AudioToolbox
import Combine
import Foundation

/// One row in the menu bar UI.
struct AppRow: Identifiable, Equatable {
    var id: String { bundleID }
    let bundleID: String
    let displayName: String
    let pids: [pid_t]
    let isPlaying: Bool
    /// 0.0-1.5. Apps the user has not touched sit at the default and ride the
    /// fallback path instead of getting their own tap.
    var volume: Float
    var isTapped: Bool

    var icon: NSImage? {
        guard let pid = pids.first,
              let app = NSRunningApplication(processIdentifier: pid) else { return nil }
        return app.icon
    }
}

/// Owns the audio plumbing and publishes the state the menu bar UI renders.
///
/// The UI only ever calls into this class; it never touches Core Audio
/// directly, so all the real-time-sensitive lifecycle rules stay in one place.
@MainActor
final class MixerController: ObservableObject {
    @Published private(set) var apps: [AppRow] = []
    @Published private(set) var status: String = "Starting…"
    @Published private(set) var isRunning = false
    @Published private(set) var outputDevices: [OutputDeviceInfo] = []
    @Published var selectedOutputUID: String? {
        didSet {
            guard oldValue != selectedOutputUID, isRunning else { return }
            store.update { $0.outputDeviceUID = selectedOutputUID }
            restartAudio()
        }
    }

    private let store = GainStore()
    private let tapManager = TapManager()
    private var relay: AudioRelay?
    private var refreshTimer: Timer?
    private var diagTimer: Timer?

    /// Set while the tap set is being rebuilt, so overlapping slider moves
    /// coalesce into one rebuild instead of racing each other.
    private var rebuildPending = false

    /// The agent normally runs headless under launchd, so without this there
    /// is no way to see why audio is not behaving.
    private func log(_ message: String) {
        print("[mixer] \(message)")
    }

    // Published rather than computed: a plain computed property on an
    // ObservableObject never fires objectWillChange, so the UI and the real
    // state drift apart as soon as anything changes them.
    @Published var masterVolume: Float = 1.0 {
        didSet {
            guard oldValue != masterVolume else { return }
            store.update { $0.masterGain = masterVolume }
            applyGains()
        }
    }

    @Published var fallbackVolume: Float = 1.0 {
        didSet {
            guard oldValue != fallbackVolume else { return }
            store.update { $0.fallbackGain = fallbackVolume }
            applyGains()
        }
    }

    @Published var muteAll: Bool = false {
        didSet {
            guard oldValue != muteAll else { return }
            store.update { $0.muteAll = muteAll }
            applyGains()
        }
    }

    // MARK: - Lifecycle

    func start() {
        masterVolume = store.settings.masterGain
        fallbackVolume = store.settings.fallbackGain
        muteAll = store.settings.muteAll
        outputDevices = listOutputDevices()
        selectedOutputUID = store.settings.outputDeviceUID

        // Opening the input device can block for as long as it takes the user
        // to answer a privacy prompt, so it must not run inline during
        // applicationDidFinishLaunching — that would leave the menu bar icon
        // missing and the app looking hung while the prompt sits unanswered.
        status = "Waiting for audio permission…"
        DispatchQueue.main.async { [weak self] in
            self?.startAudio()
        }

        refreshApps()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshApps() }
        }
        // A headless agent gives no other way to tell whether audio is
        // actually moving, so publish levels periodically to the log.
        diagTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.logLevels() }
        }
        log("controller start complete (isRunning=\(isRunning), status=\(status))")
    }

    private func logLevels() {
        guard let relay else {
            log("levels: relay is nil (status: \(status))")
            return
        }
        let p = relay.takePeaks()
        let b = relay.backlogs
        log(String(format: "levels: fallback=%.4f tapmix=%.4f out=%.4f | backlog fb=%d taps=%d",
                   p.fallback, p.tapMix, p.output, b.fallback, b.taps))
    }

    func stop() {
        refreshTimer?.invalidate()
        refreshTimer = nil
        diagTimer?.invalidate()
        diagTimer = nil
        relay?.stop()
        relay = nil
        tapManager.teardown()
        isRunning = false
    }

    private func startAudio() {
        guard let fallbackID = findDeviceByUID(kAttenuatorDeviceUID) else {
            status = "Attenuator Device not found — is the driver installed?"
            isRunning = false
            log("Attenuator Device not found")
            return
        }

        guard let outputID = resolveOutputDevice() else {
            status = "No output device selected"
            isRunning = false
            return
        }

        trySetNominalSampleRate(outputID, rate: kSampleRate)
        guard let format = queryStreamFormat(outputID, scope: kAudioObjectPropertyScopeOutput) else {
            status = "Could not read output device format"
            isRunning = false
            log("could not read output device format")
            return
        }

        let channels = Int(format.mChannelsPerFrame)
        let isFloat = (format.mFormatID == kAudioFormatLinearPCM) && (format.mFormatFlags & kAudioFormatFlagIsFloat) != 0
        let isInterleaved = (format.mFormatFlags & kAudioFormatFlagIsNonInterleaved) == 0
        guard isFloat, isInterleaved, channels >= 2 else {
            status = "Output device format unsupported (needs interleaved Float32, ≥2ch)"
            isRunning = false
            log("unsupported output format: ch=\(channels) float=\(isFloat) interleaved=\(isInterleaved)")
            return
        }

        do {
            let newRelay = try AudioRelay(
                fallbackDeviceID: fallbackID,
                outputDeviceID: outputID,
                outputChannels: channels
            )
            try newRelay.start()
            relay = newRelay
            isRunning = true
            status = "Routing to \(getDeviceName(outputID))"
            log("relay started -> \(getDeviceName(outputID)) (\(channels)ch)")
            applyGains()
            rebuildTaps()
        } catch {
            status = "Audio start failed: \(error)"
            isRunning = false
            log("relay start FAILED: \(error)")
        }
    }

    private func restartAudio() {
        relay?.stop()
        relay = nil
        tapManager.teardown()
        startAudio()
    }

    private func resolveOutputDevice() -> AudioObjectID? {
        if let uid = selectedOutputUID, let device = outputDevices.first(where: { $0.uid == uid }) {
            return device.deviceID
        }
        if let auto = autoSelectOutputDevice(from: outputDevices) {
            selectedOutputUID = auto.uid
            log("auto-selected output device: \(auto.name)")
            return auto.deviceID
        }
        log("no physical output device found among: \(outputDevices.map(\.name))")
        return nil
    }

    // MARK: - App list

    private func refreshApps() {
        outputDevices = listOutputDevices()

        // Collapse the several audio processes an app can have (browser helper
        // and GPU processes share the parent's bundle ID) into one row, so the
        // user sees "Chrome" rather than four indistinguishable entries.
        var grouped: [String: (name: String, pids: [pid_t], playing: Bool)] = [:]
        for proc in ProcessRegistry.outputCapable() {
            var entry = grouped[proc.bundleID] ?? (proc.displayName, [], false)
            entry.pids.append(proc.pid)
            entry.playing = entry.playing || proc.isRunningOutput
            grouped[proc.bundleID] = entry
        }

        let tappedIDs = Set(tapManager.tapped.map(\.selector))
        let rows = grouped.map { bundleID, entry in
            AppRow(
                bundleID: bundleID,
                displayName: entry.name,
                pids: entry.pids,
                isPlaying: entry.playing,
                volume: store.settings.perApp[bundleID] ?? 1.0,
                isTapped: tappedIDs.contains(bundleID)
            )
        }
        // Apps making sound now float to the top — that's what the user came
        // to adjust.
        let sorted = rows.sorted {
            if $0.isPlaying != $1.isPlaying { return $0.isPlaying }
            return $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }
        if sorted != apps { apps = sorted }
    }

    // MARK: - Volume changes

    func setVolume(_ volume: Float, for bundleID: String) {
        let wasTapped = store.settings.perApp[bundleID] != nil

        store.update { settings in
            if abs(volume - 1.0) < 0.001 {
                // Back to default: drop the tap and let the app rejoin the
                // fallback path, keeping the tap count (and rebuild cost) down.
                settings.perApp.removeValue(forKey: bundleID)
            } else {
                settings.perApp[bundleID] = volume
            }
        }

        let isTapped = store.settings.perApp[bundleID] != nil
        if wasTapped != isTapped {
            // The set of tapped apps changed, so the aggregate has to be
            // rebuilt. Audio for everything else keeps flowing because the
            // fallback and output IOProcs are untouched.
            scheduleTapRebuild()
        } else {
            applyGains()
        }
        refreshApps()
    }

    func volume(for bundleID: String) -> Float {
        store.settings.perApp[bundleID] ?? 1.0
    }

    func resetAll() {
        store.update { $0.perApp.removeAll() }
        scheduleTapRebuild()
        refreshApps()
    }

    // MARK: - Tap management

    private func scheduleTapRebuild() {
        guard !rebuildPending else { return }
        rebuildPending = true
        // Coalesce rapid slider changes into one rebuild — dragging a slider
        // across the default value would otherwise thrash the aggregate.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self else { return }
            self.rebuildPending = false
            self.rebuildTaps()
            self.refreshApps()
        }
    }

    private func rebuildTaps() {
        guard let relay else { return }

        relay.detachTapAggregate()

        let wanted = store.tappedBundleIDs
        guard !wanted.isEmpty else {
            tapManager.teardown()
            applyGains()
            return
        }

        do {
            try tapManager.setup(selectors: wanted)
        } catch {
            status = "Tap setup failed: \(error)"
            applyGains()
            return
        }

        guard !tapManager.tapped.isEmpty else {
            log("no requested app could be tapped: \(wanted)")
            applyGains()
            return
        }

        applyGains()

        do {
            try relay.attachTapAggregate(
                deviceID: tapManager.aggregateDeviceID,
                tapCount: tapManager.tapped.count
            )
        } catch {
            status = "Could not start per-app mixing: \(error)"
            tapManager.teardown()
        }
    }

    /// Pushes every current volume into the atomic table the audio threads read.
    private func applyGains() {
        guard let relay else { return }
        let settings = store.settings
        let master = settings.muteAll ? 0 : settings.masterGain

        for app in tapManager.tapped {
            relay.setGain(slot: app.slot, value: settings.perApp[app.selector] ?? 1.0)
        }
        relay.setFallbackGain(settings.fallbackGain)
        relay.setMasterGain(master)
        log("gains: master=\(master) fallback=\(settings.fallbackGain) perApp=\(settings.perApp) tapped=\(tapManager.tapped.map(\.selector))")
    }
}
