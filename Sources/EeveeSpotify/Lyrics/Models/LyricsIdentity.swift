import Foundation

/// Recording identity for lyrics storage: the answer to "these two
/// Spotify track IDs are the same song" that the offline cache and the
/// timing offsets key on (see LyricsOfflineCache, format v3).
///
/// Spotify routinely lists one recording under several track IDs —
/// album cut, single, deluxe reissue, regional variant — and the lyrics
/// pipeline used to fetch and file every one of them separately. The
/// identity keys below let those track IDs share one entry, with a
/// strict sharing policy:
///
/// - `isrc:` — the recording's ISRC. The only identity trusted with
///   synced (timed) lyrics and timing offsets: an ISRC names one
///   recording, so timing data cannot bleed across different takes.
/// - `meta:` — a title/artist fingerprint, used only for plain
///   (untimed) lyrics. Two different recordings can share a normalized
///   title+artist (a re-recording under identical credits), so timed
///   data is never filed or served under a fingerprint.
/// - `track:` — the Spotify track ID itself; the no-sharing fallback.
enum LyricsIdentity {
    static func isrcKey(_ isrc: String) -> String {
        "isrc:\(isrc)"
    }

    static func trackKey(_ trackId: String) -> String {
        "track:\(trackId)"
    }

    static func isIsrcKey(_ key: String) -> Bool {
        key.hasPrefix("isrc:")
    }

    static func isFingerprintKey(_ key: String) -> Bool {
        key.hasPrefix("meta:")
    }

    static func isrc(fromKey key: String) -> String? {
        guard isIsrcKey(key) else { return nil }
        return String(key.dropFirst("isrc:".count))
    }

    /// The `meta:` fingerprint for a title/artist pair, or nil when
    /// either side normalizes to nothing (an empty side would make
    /// unrelated songs collide on the non-empty one).
    static func fingerprintKey(title: String, artist: String) -> String? {
        let titleComponent = fingerprintComponent(title)
        let artistComponent = fingerprintComponent(artist)

        guard !titleComponent.isEmpty, !artistComponent.isEmpty else { return nil }

        return "meta:\(titleComponent)|\(artistComponent)"
    }

    /// Normalizes one side of the fingerprint. The base form matches
    /// the search normalization used elsewhere (`normalizedForMatch`:
    /// bracketed suffixes and "- ..." tails stripped, lowercased,
    /// apostrophes removed, words split on non-alphanumerics) — with
    /// one deliberate difference: a featuring credit is *kept*, as a
    /// canonical " feat <names>" suffix. The search normalization drops
    /// "(feat. ...)" because a search should find the song either way,
    /// but a featured version's lyrics genuinely differ from the solo
    /// version's (the guest's verse), so the fingerprint must not merge
    /// them. Spellings that place the credit differently may still map
    /// to different keys; that direction is safe (a miss costs one
    /// refetch, never wrong lyrics).
    static func fingerprintComponent(_ value: String) -> String {
        var featSuffix = ""

        for marker in ["feat.", "feat ", "featuring ", "ft.", "ft "] {
            guard let markerRange = value.range(of: marker, options: .caseInsensitive) else { continue }

            var tail = value[markerRange.upperBound...]
            if let close = tail.firstIndex(where: { $0 == ")" || $0 == "]" }) {
                tail = tail[..<close]
            }

            let names = normalizedWords(String(tail))
            if !names.isEmpty {
                featSuffix = " feat \(names)"
            }
            break
        }

        return normalizedWords(value.strippedTrackTitle) + featSuffix
    }

    private static func normalizedWords(_ value: String) -> String {
        value
            .lowercased()
            .replacingOccurrences(of: "'", with: "")
            .replacingOccurrences(of: "\u{2018}", with: "")
            .replacingOccurrences(of: "\u{2019}", with: "")
            .replacingOccurrences(of: "`", with: "")
            .replacingOccurrences(of: "\u{00B4}", with: "")
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}
