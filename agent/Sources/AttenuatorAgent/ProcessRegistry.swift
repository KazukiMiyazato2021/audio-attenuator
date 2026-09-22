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
    let bundleID: String
    let isRunningOutput: Bool

    /// Human-readable name, falling back through the running-app list and then
    /// the bundle ID itself, since CoreAudio exposes no display name here.
    var displayName: String {
        if let app = NSRunningApplicationName(pid: pid), !app.isEmpty { return app }
        if !bundleID.isEmpty { return bundleID }
        return "pid \(pid)"
    }
}

private func NSRunningApplicationName(pid: pid_t) -> String? {
    // Deliberately avoids importing AppKit so this stays usable from the
    // headless CLI; the UI phase can swap in a richer lookup.
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
            AudioProcessInfo(
                objectID: objectID,
                pid: property(objectID, kAudioProcessPropertyPID, default: pid_t(-1)),
                bundleID: bundleID(objectID),
                isRunningOutput: property(objectID, kAudioProcessPropertyIsRunningOutput, default: UInt32(0)) != 0
            )
        }
    }

    /// Processes worth showing to a user: they have an identity and are (or
    /// could be) producing output.
    static func outputCapable() -> [AudioProcessInfo] {
        all().filter { !$0.bundleID.isEmpty }
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
