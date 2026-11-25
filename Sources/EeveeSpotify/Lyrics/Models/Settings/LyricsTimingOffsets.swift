import Foundation

/// User-adjustable corrections for synced-lyrics timing: one global value
/// applied to every track, plus per-track values keyed by Spotify track ID.
///
/// Positive values delay the lyrics (each line is shown later than its
/// timestamp); negative values show them earlier. Only tracks the user
/// actually adjusted get a per-track entry, and an entry is dropped again
/// when it returns to zero, so the stored dictionary stays as small as the
/// number of corrected songs.
struct LyricsTimingOffsets: Codable, Hashable {
    var globalMs: Int = 0
    var perTrackMs: [String: Int] = [:]

    /// The correction in effect for a track: its own value on top of the
    /// global one.
    func effectiveMs(forTrackId trackId: String?) -> Int {
        globalMs + perTrackMs(forTrackId: trackId)
    }

    func perTrackMs(forTrackId trackId: String?) -> Int {
        guard let trackId, !trackId.isEmpty else { return 0 }
        return perTrackMs[trackId] ?? 0
    }

    mutating func setPerTrackMs(_ valueMs: Int, forTrackId trackId: String) {
        guard !trackId.isEmpty else { return }
        if valueMs == 0 {
            perTrackMs[trackId] = nil
        } else {
            perTrackMs[trackId] = valueMs
        }
    }

    static func format(_ ms: Int) -> String {
        ms == 0 ? "0.0s" : String(format: "%+.1fs", Double(ms) / 1000.0)
    }
}
