import Foundation

/// Acceptance checks applied to every record a lyrics provider returns
/// before its lyrics may be served for a query.
///
/// Search endpoints return *candidates*: a provider's best guess is not
/// the queried track until the record itself proves it. The wrong-
/// lyrics audit (audit-wrong-lyrics-attachment.md) found every source
/// adopting records with little or no checking — lrc.red's unverified
/// first-hit fallback, Genius's degrading pool, LRCLIB's stripped-title
/// retry, LiriQo's match-nothing candidates, Petit's unchecked first
/// hit — so a song with no sung lyrics could be served another song's
/// lyrics (an instrumental "Spring" received a choir piece's text, and
/// "X (Instrumental)" received the vocal X's lyrics). The rule now is
/// uniform: no verification, no lyrics.
///
/// The title check reuses the identity fingerprint
/// (`LyricsIdentity.fingerprintComponent`: bracket/dash suffixes
/// stripped, lowercased, words split on non-alphanumerics, featuring
/// credit preserved as a canonical suffix) and adds two rules on top:
///
/// - Featuring credits: when *both* titles carry one, the credits must
///   agree. When only one side carries one, the titles still match —
///   provider catalogues routinely omit the credit from the record name
///   while carrying the full lyrics, so a one-sided credit is the norm,
///   not a different song.
/// - Version descriptors: the parts `strippedTrackTitle` throws away
///   (parenthesised / bracketed segments and "- ..." tails) are
///   compared as token sets, minus featuring credits and minus
///   packaging-only words (remaster, explicit, ...). "(Instrumental)",
///   "(Karaoke)", "- Live", "( sped up)" and friends change what the
///   lyrics are or whether there are any, so a record whose
///   descriptors differ from the query's is a different version and is
///   rejected — this is what stops the stripped-title retry from
///   adopting the vocal version for an instrumental query.
enum LyricsMatchVerification {
    /// Whether a provider record's title may be accepted as the
    /// queried track's title.
    static func titlesMatch(queryTitle: String, candidateTitle: String) -> Bool {
        let query = fingerprintParts(queryTitle)
        let candidate = fingerprintParts(candidateTitle)

        guard !query.base.isEmpty, query.base == candidate.base else {
            return false
        }

        // Featuring credits are compared as name sets (the word
        // "feat" itself excluded — an unbracketed credit leaves it
        // inside the fingerprint's base words, and the split in
        // fingerprintParts can carry it into the suffix).
        if let queryFeat = query.feat, let candidateFeat = candidate.feat,
           queryFeat != candidateFeat {
            return false
        }

        return hardDescriptorTokens(queryTitle) == hardDescriptorTokens(candidateTitle)
    }

    /// Whether a provider record's artist credit may be accepted as
    /// the queried primary artist. Exact normalized equality, or one
    /// side's word set containing the other's: Spotify reports only
    /// the primary artist while provider credits list every
    /// collaborator ("A & B", "A/B", "A, B"), and aggregator credits
    /// append cataloguers after the real artist.
    static func artistsMatch(queryArtist: String, candidateArtist: String) -> Bool {
        let query = Set(words(queryArtist))
        let candidate = Set(words(candidateArtist))

        guard !query.isEmpty, !candidate.isEmpty else {
            return false
        }

        return query == candidate || query.isSubset(of: candidate) || candidate.isSubset(of: query)
    }

    /// Whether two durations may describe the same recording. A
    /// missing duration on either side proves nothing and passes;
    /// a large gap means a different version (an extended cut, a
    /// medley) even when the names agree.
    static func durationsCompatible(querySeconds: Int?, candidateSeconds: Double?) -> Bool {
        guard let querySeconds, let candidateSeconds else {
            return true
        }

        return abs(Double(querySeconds) - candidateSeconds) <= 10
    }

    /// Provider placeholder text that aggregators (chiefly the Chinese
    /// providers behind LiriQo) serve in place of lyrics: "no lyrics
    /// yet", "instrumental, please enjoy", and similar. A line of this
    /// is not a lyric line; a track whose whole content is such lines
    /// has no lyrics.
    static func isPlaceholderLyricLine(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmed.isEmpty else {
            return false
        }

        // "暂无歌词…" ("no lyrics yet") arrives with varying suffixes
        // (暂无歌词信息 / 暂无歌词,敬请期待 / …); the four-character
        // prefix on a short line is the placeholder, never a lyric.
        if trimmed.hasPrefix("暂无歌词"), trimmed.count <= 12 {
            return true
        }

        let compact = trimmed.replacingOccurrences(of: " ", with: "")

        return placeholderLines.contains(compact)
    }

    private static let placeholderLines: Set<String> = [
        "纯音乐，请欣赏",
        "纯音乐,敬请期待",
        "纯音乐，请期待",
        "无歌词",
        "Nolyricsavailable",
        "Nolyricsfound",
        "Lyricsnotavailable"
    ]

    // MARK: - Title decomposition

    /// Splits the identity fingerprint into its base title and the
    /// set of featured-artist names from its canonical suffix
    /// (" feat <names>"), when present.
    private static func fingerprintParts(_ value: String) -> (base: String, feat: Set<String>?) {
        let fingerprint = LyricsIdentity.fingerprintComponent(value)

        guard let range = fingerprint.range(of: " feat ") else {
            return (fingerprint, nil)
        }

        let names = Set(words(String(fingerprint[range.upperBound...])))
            .subtracting(["feat"])

        return (
            String(fingerprint[..<range.lowerBound]),
            names.isEmpty ? nil : names
        )
    }

    /// Packaging-only descriptor words: they describe the release, not
    /// the performance, and the lyrics are the same with or without
    /// them.
    private static let softDescriptorWords: Set<String> = [
        "remaster", "remastered", "remastering",
        "explicit", "clean", "mono", "stereo"
    ]

    /// The version-descriptor tokens of a title: the words inside its
    /// parenthesised / bracketed segments and its "- ..." tail(s) —
    /// exactly the material `strippedTrackTitle` discards — minus
    /// featuring credits and packaging-only segments.
    private static func hardDescriptorTokens(_ title: String) -> Set<String> {
        var segments: [String] = []
        var remainder = title

        for pattern in ["\\(([^)]*)\\)", "\\[([^]]*)\\]"] {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }

            for match in regex.matches(in: remainder, range: remainder.range).reversed() {
                if let group = Range(match.range(at: 1), in: remainder) {
                    segments.append(String(remainder[group]))
                }

                if let whole = Range(match.range, in: remainder) {
                    remainder.replaceSubrange(whole, with: " ")
                }
            }
        }

        // Mirror strippedTrackTitle: everything from the first " - "
        // on is a tail segment.
        if let tail = remainder.range(of: " - ") {
            segments.append(String(remainder[tail.upperBound...]))
            remainder = String(remainder[..<tail.lowerBound])
        }

        var tokens = Set<String>()

        for segment in segments {
            let segmentWords = words(segment)

            guard let first = segmentWords.first else { continue }

            // A featuring credit is not a version descriptor; it is
            // compared by the feat rule in titlesMatch.
            if ["feat", "featuring", "ft"].contains(first) {
                continue
            }

            // A segment made only of packaging words and digits (a
            // year, "Remastered") carries no version information.
            if segmentWords.allSatisfy({
                softDescriptorWords.contains($0) || $0.allSatisfy(\.isNumber)
            }) {
                continue
            }

            tokens.formUnion(segmentWords)
        }

        return tokens
    }

    /// The word normalization the identity fingerprint uses:
    /// lowercased, apostrophes removed, words split on
    /// non-alphanumerics.
    private static func words(_ value: String) -> [String] {
        value
            .lowercased()
            .replacingOccurrences(of: "'", with: "")
            .replacingOccurrences(of: "\u{2018}", with: "")
            .replacingOccurrences(of: "\u{2019}", with: "")
            .replacingOccurrences(of: "`", with: "")
            .replacingOccurrences(of: "\u{00B4}", with: "")
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }
}
