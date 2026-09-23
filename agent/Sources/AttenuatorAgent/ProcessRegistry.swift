import AppKit
import CoreAudio
import AudioToolbox
import Foundation

/// One audio-producing process as CoreAudio sees it.
///
/// `objectID` is CoreAudio's handle and is what taps are built from, but it is
/// not stable across relaunches — gains are keyed by `bundleID` instead so a
/// user's setting survives quitting and reopening the app.
struct AudioProcessInfo {
    let objectID: AudioObjectID
    let pid: pid_t
    /// The bundle ID CoreAudio reports for the process itself. For browser
    /// helpers this is the shared helper ID, which is the same for every tab,
    /// so it is not a usable identity to group or persist volumes by.
    let bundleID: String
    let isRunningOutput: Bool

    /// The application a user would say this audio belongs to, found by walking
    /// up the process tree to the nearest pid macOS treats as an application.
    ///
    /// This is what separates, say, a Chrome web app from ordinary Chrome tabs:
    /// both run as `com.google.Chrome.helper` processes, but the web app
    /// registers itself as its own application while a tab's helper resolves
    /// up to the browser.
    let ownerBundleID: String
    let ownerName: String

    /// Stable key to group rows by and to persist a volume against.
    var appKey: String { ownerBundleID.isEmpty ? bundleID : ownerBundleID }

    var displayName: String {
        if !ownerName.isEmpty { return ownerName }
        if let exe = executableName(pid: pid), !exe.isEmpty { return exe }
        if !bundleID.isEmpty { return bundleID }
        return "pid \(pid)"
    }
}

/// The pid's parent, or nil at the top of the tree.
private func parentPID(_ pid: pid_t) -> pid_t? {
    var info = kinfo_proc()
    var size = MemoryLayout<kinfo_proc>.size
    var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
    guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
    let ppid = info.kp_eproc.e_ppid
    return ppid > 0 ? ppid : nil
}

/// Nearest ancestor (including the process itself) that macOS reports as a
/// running application, which is the level users recognise and the level at
/// which a volume makes sense.
private func owningApplication(of pid: pid_t) -> (name: String, bundleID: String)? {
    var current: pid_t? = pid
    var hops = 0
    while let p = current, hops < 6 {
        if let app = NSRunningApplication(processIdentifier: p), let name = app.localizedName {
            return (name, app.bundleIdentifier ?? "")
        }
        current = parentPID(p)
        hops += 1
    }
    return nil
}

/// Last-resort name for daemons and helpers that are not applications.
private func executableName(pid: pid_t) -> String? {
    var name: String? = nil
    var size: Int = 0
    var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
    guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 0 else { return nil }
    var buffer = [CChar](repeating: 0, count: size)
    guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return nil }
    // KERN_PROCARGS2 layout: [argc: Int32][exec path NUL-terminated]...
    let pathStart = MemoryLayout<Int32>.size
    guard size > pathStart else { return nil }
    buffer.withUnsafeBufferPointer { raw in
        guard let base = raw.baseAddress else { return }
        let path = String(cString: base + pathStart)
        if !path.isEmpty {
            name = (path as NSString).lastPathComponent
        }
    }
    return name
}

enum ProcessRegistry {
    /// All process objects CoreAudio currently knows about.
    static func all() -> [AudioProcessInfo] {
        processObjectIDs().map { objectID in
            let pid: pid_t = property(objectID, kAudioProcessPropertyPID, default: pid_t(-1))
            let owner = owningApplication(of: pid)
            return AudioProcessInfo(
                objectID: objectID,
                pid: pid,
                bundleID: bundleID(objectID),
                isRunningOutput: property(objectID, kAudioProcessPropertyIsRunningOutput, default: UInt32(0)) != 0,
                ownerBundleID: owner?.bundleID ?? "",
                ownerName: owner?.name ?? ""
            )
        }
    }

    /// Processes worth showing to a user: they have an identity and are (or
    /// could be) producing output.
    /// Excluded by bundle ID rather than pid: a second copy of the agent (the
    /// CLI alongside the running menu bar agent, say) is still us.
    private static let ownBundleID = Bundle.main.bundleIdentifier ?? "com.audioattenuator.agent"

    static func outputCapable() -> [AudioProcessInfo] {
        all().filter { proc in
            guard !proc.appKey.isEmpty else { return false }
            // The agent shows up because it writes the mix to the output
            // device. Offering it as something to tap would route our own
            // output back into our own input.
            return proc.appKey != ownBundleID && proc.bundleID != ownBundleID
        }
    }

    /// Resolves a user-supplied selector to *every* matching process.
    ///
    /// Returning all matches rather than the first is essential for browsers:
    /// Chrome and Safari play audio from helper/GPU processes that share the
    /// parent's bundle ID, so tapping only one of them would miss the audio.
    /// A single tap description can hold several process objects, so all
    /// matches end up in one tap sharing one gain.
    ///
    /// Accepted forms: an exact bundle ID, `pid:<number>`, or an exact
    /// executable name (useful for helper binaries with no bundle ID).
    static func resolve(selector: String) -> [AudioProcessInfo] {
        let processes = all()

        if selector.hasPrefix("pid:"), let pid = pid_t(selector.dropFirst(4)) {
            return processes.filter { $0.pid == pid }
        }

        // Match the grouping key first, so tapping a row picks up every
        // process that row represents.
        let byAppKey = processes.filter { $0.appKey == selector }
        if !byAppKey.isEmpty { return byAppKey }

        let byBundle = processes.filter { $0.bundleID == selector }
        if !byBundle.isEmpty { return byBundle }

        return processes.filter { $0.displayName == selector }
    }

    private static func processObjectIDs() -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(kSystemObject, &address, 0, nil, &size) == noErr, size > 0 else {
            return []
        }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(kSystemObject, &address, 0, nil, &size, &ids) == noErr else {
            return []
        }
        return ids
    }

    private static func property<T>(_ objectID: AudioObjectID, _ selector: AudioObjectPropertySelector, default def: T) -> T {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value = def
        var size = UInt32(MemoryLayout<T>.size)
        let status = withUnsafeMutablePointer(to: &value) { ptr in
            AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, ptr)
        }
        return status == noErr ? value : def
    }

    private static func bundleID(_ objectID: AudioObjectID) -> String {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyBundleID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: CFString? = nil
        var size = UInt32(MemoryLayout<CFString?>.size)
        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, $0)
        }
        guard status == noErr, let value else { return "" }
        return value as String
    }
}
