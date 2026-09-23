import Foundation

/// Persists the user's volume choices across launches.
///
/// Keyed by bundle ID rather than PID or AudioObjectID: both of those change
/// every time an app restarts, and a per-app volume that silently reset on
/// relaunch would defeat the point of setting one.
struct GainSettings: Codable {
    /// Volume per app bundle ID, 0.0-1.5. Only apps the user has actually
    /// moved away from the default appear here — everything else rides the
    /// fallback path at `fallbackGain`.
    var perApp: [String: Float] = [:]
    var fallbackGain: Float = 1.0
    var masterGain: Float = 1.0
    var muteAll: Bool = false
    /// UID of the real device the mix is played through; nil means "pick the
    /// only non-virtual output".
    var outputDeviceUID: String? = nil
}

final class GainStore {
    private(set) var settings: GainSettings
    private let url: URL

    init() {
        let dir = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Attenuator", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        url = dir.appendingPathComponent("settings.json")

        if let data = try? Data(contentsOf: url),
           let decoded = try? JSONDecoder().decode(GainSettings.self, from: data) {
            settings = decoded
        } else {
            settings = GainSettings()
        }
    }

    func update(_ mutate: (inout GainSettings) -> Void) {
        mutate(&settings)
        save()
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        try? data.write(to: url, options: .atomic)
    }

    /// The apps that need their own tap: exactly those the user has given a
    /// non-default volume. Everything else stays on the fallback path, which
    /// keeps the tap count — and so the aggregate rebuilds — to a minimum.
    var tappedBundleIDs: [String] {
        settings.perApp.keys.sorted()
    }
}
