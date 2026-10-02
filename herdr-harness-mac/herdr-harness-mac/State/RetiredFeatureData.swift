import Foundation

/// Removes what features the Mac app no longer has left on disk, so a retired
/// feature does not keep stale data around forever. Each step is idempotent and
/// cheap, so it simply runs on every launch.
enum RetiredFeatureData {
    /// UserDefaults keys of retired features.
    static let defaultsKeys = [
        // 30-second response briefs, replaced by skims.
        "herdr.responseBrief.enabledChats.v1",
        "herdr.responseBrief.model.v1",
        "herdr.responseBrief.thinking.v1",
        "herdr.responseBrief.length.v1",
    ]

    /// Files under Application Support of retired features.
    static let applicationSupportFiles = [
        "Herdr/response-briefs-v1.json",
    ]

    static func purge(defaults: UserDefaults, fileManager: FileManager = .default, applicationSupport: URL? = nil) {
        for key in defaultsKeys where defaults.object(forKey: key) != nil {
            defaults.removeObject(forKey: key)
        }
        guard let root = applicationSupport
            ?? fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return }
        for path in applicationSupportFiles {
            let url = root.appending(path: path, directoryHint: .notDirectory)
            if fileManager.fileExists(atPath: url.path) {
                try? fileManager.removeItem(at: url)
            }
        }
    }
}
