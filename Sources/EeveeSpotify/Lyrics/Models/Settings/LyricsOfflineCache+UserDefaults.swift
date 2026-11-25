import Foundation

extension UserDefaults {
    private static let lyricsOfflineCacheEnabledKey = "lyricsOfflineCacheEnabled"

    /// Whether fetched lyrics are persisted on device (see
    /// `LyricsOfflineCache`). Kept as its own key instead of a field on
    /// `LyricsOptions`: adding a field there would make previously stored
    /// options JSON fail to decode and reset every lyrics setting.
    /// Defaults to true — the cache is size-capped and user-clearable,
    /// and the feature only exists if it is on.
    static var lyricsOfflineCacheEnabled: Bool {
        get {
            if let value = container.object(forKey: lyricsOfflineCacheEnabledKey) as? Bool {
                return value
            }

            return true
        }
        set (newValue) {
            container.set(newValue, forKey: lyricsOfflineCacheEnabledKey)
        }
    }
}
