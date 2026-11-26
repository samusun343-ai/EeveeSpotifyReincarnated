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

    // MARK: - Recording (ISRC) identity
    //
    // A correction compensates the timing of one *recording's* audio,
    // so when the track's ISRC is known the value is filed under an
    // "isrc:" key in the same dictionary and shared by every duplicate
    // track ID of that recording. Fingerprint identity is deliberately
    // not used here: two different recordings can share a normalized
    // title/artist, and shifting one take by another's correction is
    // exactly the failure the ISRC-only rule exists to prevent.

    static func identityKey(forIsrc isrc: String) -> String {
        LyricsIdentity.isrcKey(isrc)
    }

    func perTrackMs(forTrackId trackId: String?, isrc: String?) -> Int {
        if let isrc, !isrc.isEmpty,
           let value = perTrackMs[Self.identityKey(forIsrc: isrc)] {
            return value
        }
        return perTrackMs(forTrackId: trackId)
    }

    func effectiveMs(forTrackId trackId: String?, isrc: String?) -> Int {
        globalMs + perTrackMs(forTrackId: trackId, isrc: isrc)
    }

    /// Writes the correction under the recording's ISRC key when one is
    /// known (retiring any track-ID entry for this track, so the two
    /// can never stack), and under the track ID otherwise. Zero clears
    /// both keys.
    mutating func setPerTrackMs(_ valueMs: Int, forTrackId trackId: String, isrc: String?) {
        guard let isrc, !isrc.isEmpty else {
            setPerTrackMs(valueMs, forTrackId: trackId)
            return
        }

        guard !trackId.isEmpty else { return }

        perTrackMs[trackId] = nil
        let key = Self.identityKey(forIsrc: isrc)
        if valueMs == 0 {
            perTrackMs[key] = nil
        } else {
            perTrackMs[key] = valueMs
        }
    }

    static func format(_ ms: Int) -> String {
        ms == 0 ? "0.0s" : String(format: "%+.1fs", Double(ms) / 1000.0)
    }
}
