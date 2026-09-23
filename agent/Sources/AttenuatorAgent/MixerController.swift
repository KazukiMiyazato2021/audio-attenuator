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

    /// The OS-level volume of the Attenuator Device — what the volume keys and
    /// the Sound settings slider control while it is the system output. Our
    /// driver records it but does not apply it to the samples it passes on, and
    /// applying it there would miss everything arriving through process taps,
    /// so it is folded into the final mix here instead.
    private var systemVolume: Float = 1.0
    private var systemMuted = false
    private var volumeListener: AudioObjectPropertyListenerBlock?
    private var muteListener: AudioObjectPropertyListenerBlock?
    private var watchedDeviceID: AudioObjectID = kAudioObjectUnknown
    /// Backstop for the listeners: a driver that forgets to notify on a
    /// control change would otherwise leave the volume keys doing nothing,
    /// with no visible error. Reading two properties a few times a second is
    /// cheap next to that failure mode.
    private var volumePollTimer: Timer?

    /// Fires when devices appear or disappear, which is also how a coreaudiod
    /// restart shows up. Every AudioObjectID and IOProc the relay holds is
    /// invalidated by that restart, so the graph has to be rebuilt or the
    /// agent goes silently dead — exactly what happens after reinstalling the
    /// driver.
    private var deviceListListener: AudioObjectPropertyListenerBlock?
    private var rebuildAfterDeviceChangePending = false

    /// The object IDs the relay's IOProcs were built against. CoreAudio hands
    /// out fresh IDs after coreaudiod restarts, so an ID that no longer
    /// matches the one the UID resolves to is a precise signal that the
    /// relay is pointing at objects that no longer exist.
    private var openedFallbackID: AudioObjectID = kAudioObjectUnknown
    private var openedOutputID: AudioObjectID = kAudioObjectUnknown
    /// Devices reappear a little after coreaudiod comes back, so the first
    /// restart attempt can legitimately find nothing to play through. Without
    /// a retry the agent would sit silent until the next unrelated device
    /// change happened to wake it.
    private var startRetries = 0
    private static let maxStartRetries = 10

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
        watchDeviceList()
        log("controller start complete (isRunning=\(isRunning), status=\(status))")
    }

    private func watchDeviceList() {
        guard deviceListListener == nil else { return }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor in self?.handleDeviceListChanged() }
        }
        if AudioObjectAddPropertyListenerBlock(kSystemObject, &address, DispatchQueue.main, block) == noErr {
            deviceListListener = block
        }
    }

    private func handleDeviceListChanged() {
        // Device churn arrives in bursts (a coreaudiod restart republishes
        // everything), so settle before rebuilding rather than thrashing.
        guard !rebuildAfterDeviceChangePending else { return }
        rebuildAfterDeviceChangePending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self else { return }
            self.rebuildAfterDeviceChangePending = false
            self.outputDevices = listOutputDevices()

            // If our device vanished, or the relay is dead, start over. Object
            // IDs from before a coreaudiod restart are meaningless now.
            let deviceGone = findDeviceByUID(kAttenuatorDeviceUID) == nil
            if deviceGone {
                self.log("Attenuator Device disappeared; waiting for it to come back")
                self.status = "Attenuator Device unavailable"
                return
            }
            if !self.isRunning || self.audioObjectsAreStale() {
                self.log("audio objects are stale or audio stopped; restarting")
                self.restartAudio()
            }
        }
    }

    /// True when the IDs the relay was built on no longer refer to the devices
    /// we meant. After a coreaudiod restart the IOProcs keep firing on schedule
    /// with plausible-looking buffers, so waiting for the audio to stop flowing
    /// does not catch this — the buffers are simply silent.
    private func audioObjectsAreStale() -> Bool {
        guard relay != nil else { return true }
        guard let currentFallback = findDeviceByUID(kAttenuatorDeviceUID) else { return true }
        if currentFallback != openedFallbackID { return true }

        if let uid = selectedOutputUID,
           let current = outputDevices.first(where: { $0.uid == uid })?.deviceID,
           current != openedOutputID {
            return true
        }
        return false
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
        if let deviceListListener {
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyDevices,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            AudioObjectRemovePropertyListenerBlock(kSystemObject, &address, DispatchQueue.main, deviceListListener)
            self.deviceListListener = nil
        }
        refreshTimer?.invalidate()
        refreshTimer = nil
        diagTimer?.invalidate()
        diagTimer = nil
        unwatchSystemVolume()
        relay?.stop()
        relay = nil
        tapManager.teardown()
        isRunning = false
    }

    private func startAudio() {
        guard let fallbackID = findDeviceByUID(kAttenuatorDeviceUID) else {
            status = "Attenuator Device not found — is the driver installed?"
            isRunning = false
            scheduleStartRetry(reason: "Attenuator Device not present")
            return
        }

        guard let outputID = resolveOutputDevice() else {
            status = "Waiting for an output device…"
            isRunning = false
            scheduleStartRetry(reason: "no output device yet")
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
            watchSystemVolume(on: fallbackID)
            startRetries = 0
            relay = newRelay
            openedFallbackID = fallbackID
            openedOutputID = outputID
            isRunning = true
            status = "Routing to \(getDeviceName(outputID))"
            log("relay started -> \(getDeviceName(outputID)) (\(channels)ch)")
            applyGains()
            rebuildTaps()
        } catch {
            status = "Audio start failed: \(error)"
            isRunning = false
            log("relay start FAILED: \(error)")
            scheduleStartRetry(reason: "relay start failed")
        }
    }

    private func scheduleStartRetry(reason: String) {
        guard startRetries < Self.maxStartRetries else {
            log("giving up restarting audio after \(startRetries) attempts (\(reason))")
            return
        }
        startRetries += 1
        log("\(reason); retrying in 1s (attempt \(startRetries))")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self, !self.isRunning else { return }
            self.outputDevices = listOutputDevices()
            self.startAudio()
        }
    }

    /// Tracks the device's own volume/mute so OS volume changes take effect
    /// immediately rather than only on the next restart.
    private func watchSystemVolume(on deviceID: AudioObjectID) {
        unwatchSystemVolume()
        watchedDeviceID = deviceID
        systemVolume = deviceVolumeScalar(deviceID) ?? 1.0
        systemMuted = deviceMuted(deviceID) ?? false
        log(String(format: "system volume %.3f muted=%@", systemVolume, systemMuted ? "yes" : "no"))

        volumeListener = addDevicePropertyListener(deviceID, selector: kAudioDevicePropertyVolumeScalar) { [weak self] in
            guard let self else { return }
            self.systemVolume = deviceVolumeScalar(deviceID) ?? self.systemVolume
            self.applyGains()
        }
        muteListener = addDevicePropertyListener(deviceID, selector: kAudioDevicePropertyMute) { [weak self] in
            guard let self else { return }
            self.systemMuted = deviceMuted(deviceID) ?? self.systemMuted
            self.applyGains()
        }

        volumePollTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.pollSystemVolume() }
        }
    }

    private func pollSystemVolume() {
        guard watchedDeviceID != kAudioObjectUnknown else { return }
        let volume = deviceVolumeScalar(watchedDeviceID) ?? systemVolume
        let muted = deviceMuted(watchedDeviceID) ?? systemMuted
        guard abs(volume - systemVolume) > 0.0001 || muted != systemMuted else { return }
        systemVolume = volume
        systemMuted = muted
        applyGains()
    }

    private func unwatchSystemVolume() {
        volumePollTimer?.invalidate()
        volumePollTimer = nil
        guard watchedDeviceID != kAudioObjectUnknown else { return }
        if let volumeListener {
            removeDevicePropertyListener(watchedDeviceID, selector: kAudioDevicePropertyVolumeScalar, block: volumeListener)
        }
        if let muteListener {
            removeDevicePropertyListener(watchedDeviceID, selector: kAudioDevicePropertyMute, block: muteListener)
        }
        volumeListener = nil
        muteListener = nil
        watchedDeviceID = kAudioObjectUnknown
    }

    private func restartAudio() {
        unwatchSystemVolume()
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
        // Grouped by owning application rather than by the process's own
        // bundle ID: browser helpers all share one helper bundle ID, so
        // grouping on that would merge unrelated web apps into a single row
        // and make one slider move several apps at once.
        var grouped: [String: (name: String, pids: [pid_t], playing: Bool)] = [:]
        for proc in ProcessRegistry.outputCapable() {
            var entry = grouped[proc.appKey] ?? (proc.displayName, [], false)
            entry.pids.append(proc.pid)
            entry.playing = entry.playing || proc.isRunningOutput
            grouped[proc.appKey] = entry
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

    /// Applies a per-app volume.
    ///
    /// `live` is true for every intermediate value while a slider is being
    /// dragged, so the volume follows the drag instead of jumping when the
    /// mouse is released. The cheap part — writing the gain the audio thread
    /// reads — happens on every call; the expensive part (rebuilding the tap
    /// aggregate, re-enumerating processes) is debounced or deferred to the
    /// end of the drag.
    func setVolume(_ volume: Float, for bundleID: String, live: Bool = false) {
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

        // Re-enumerating processes on every drag sample would be wasteful, and
        // replacing the rows mid-drag can interrupt the gesture.
        if !live { refreshApps() }
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
        logGains()
    }

    /// Pushes every current volume into the atomic table the audio threads read.
    private func applyGains() {
        guard let relay else { return }
        let settings = store.settings
        // The OS volume multiplies the app's own master so that both the
        // volume keys and the in-app slider behave as users expect.
        let muted = settings.muteAll || systemMuted
        let master = muted ? 0 : settings.masterGain * systemVolume

        for app in tapManager.tapped {
            relay.setGain(slot: app.slot, value: settings.perApp[app.selector] ?? 1.0)
        }
        relay.setFallbackGain(settings.fallbackGain)
        relay.setMasterGain(master)
    }

    /// Logged on structural changes only — applyGains runs per drag sample and
    /// would otherwise flood the log.
    private func logGains() {
        let settings = store.settings
        log("gains: master=\(settings.muteAll ? 0 : settings.masterGain) fallback=\(settings.fallbackGain) perApp=\(settings.perApp) tapped=\(tapManager.tapped.map(\.selector))")
    }
}
