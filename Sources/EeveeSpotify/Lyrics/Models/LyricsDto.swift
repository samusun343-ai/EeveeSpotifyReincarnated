import Foundation

struct LyricsDto {
    var lines: [LyricsLineDto]
    var timeSynced: Bool
    var romanization: LyricsRomanizationStatus
    var translation: LyricsTranslationDto?
    var providerCredit: String? = nil
    /// The ISRC of the recording these lyrics actually came from, when
    /// the producing stage resolved one *and* verified the match
    /// (currently the lrc.red stage of the combined source: its search
    /// hit must match the query on normalized title/artist — an
    /// unverified first-hit fallback never sets this). The offline
    /// cache files the entry under this identity so duplicate track
    /// IDs of the same recording share it (LyricsIdentity). It is
    /// provenance, not display data, and is never adopted from another
    /// track's metadata.
    var resolvedIsrc: String? = nil

    /// Returns a copy with every line's timestamp shifted by `offsetMs`
    /// (clamped at zero), applying the user's timing correction for the
    /// native lyrics view. The karaoke overlay compensates on the
    /// playback-position side instead (see KaraokeLyricsView), so DTOs
    /// handed to it — directly or via `KaraokeLyricsDto.lineSynced` —
    /// must stay unshifted.
    func applyingTimingOffset(_ offsetMs: Int) -> LyricsDto {
        guard offsetMs != 0 else { return self }

        var copy = self
        copy.lines = lines.map { line in
            var line = line
            if let offset = line.offsetMs {
                line.offsetMs = max(0, offset + offsetMs)
            }
            return line
        }
        return copy
    }

    func toSpotifyLyricsData(source: String) -> LyricsData {
        var lyricsData = LyricsData.with {
            // Real response schema field 1 is a 3-value syncType enum;
            // .lineSynced (1) encodes exactly like the old Bool `true`.
            $0.syncType = timeSynced ? .lineSynced : .unsynced
            // Eevee serves complete lyrics, never a capped preview, so
            // the truthful cap status is .uncapped. The client's
            // internal v3 lyrics model likewise stores a capStatus, and
            // the NPV lyrics surfaces are fed from that model — leaving
            // it at the .none default reports Eevee-served lyrics as of
            // unknown capping state.
            $0.capStatus = .uncapped
            $0.provider = providerCredit ?? source
            $0.providedBy = "\(providerCredit ?? source) (EeveeSpotify)"
        }
        
        let shouldRomanize = UserDefaults.lyricsOptions.romanization
        
        if lines.isEmpty {
            lyricsData.lines = [
                LyricsLine.with {
                    $0.content = "song_is_instrumental".localized
                },
                LyricsLine.with {
                    $0.content = "let_the_music_play".localized
                },
                LyricsLine.with {
                    $0.content = ""
                }
            ]
        }
        else {
            let sortedLines = lines.sorted {
                ($0.offsetMs ?? 0) < ($1.offsetMs ?? 0)
            }
            lyricsData.lines = sortedLines.enumerated().map { index, line in
                let startMs = line.offsetMs ?? 0
                // Spotify's native lyrics block needs a per-line end time
                // (endTimeMs, schema field 4) to highlight and seek.
                // Derive it exactly like the karaoke side does
                // (KaraokeLyricsDto.lineSynced): the next line's start —
                // searching the full sorted list, so a trailing empty
                // end-marker line still terminates the previous line —
                // or start + 4s for the final line.
                var endTimeMs: Int64 = 0
                if timeSynced {
                    let nextStartMs = sortedLines[(index + 1)...]
                        .first { ($0.offsetMs ?? 0) > startMs }
                        .map { $0.offsetMs ?? 0 }
                    endTimeMs = Int64(nextStartMs ?? startMs + 4000)
                }
                return LyricsLine.with {
                    $0.content = (shouldRomanize && romanization == .canBeRomanized)
                        ? line.content.applyingTransform(.toLatin, reverse: false)!
                        : line.content
                    $0.offsetMs = Int32(startMs)
                    $0.endTimeMs = endTimeMs
                }
            }
        }
        
        if !lines.isEmpty {
            // Real schema field 17 is `previewLines`: the short preview
            // the NPV lyrics card shows (the card element has dedicated
            // snippet states). Official responses carry the opening
            // lines there; mirror that with the first lines of the
            // lyrics actually served above.
            lyricsData.previewLines = Array(lyricsData.lines.prefix(4))
        }

        if let translation = translation {
            // Real schema field 9 is `alternatives` (repeated): the
            // client reads a translation as an alternative-language
            // version of the lyrics. The wire layout is unchanged from
            // the previous singular `translation` modelling.
            lyricsData.alternatives = [
                LyricsAlternative.with {
                    $0.language = translation.languageCode
                    $0.lines = translation.lines
                }
            ]
        }
        
        return lyricsData
    }
}

// Codable for the offline lyrics cache (LyricsOfflineCache.swift).
extension LyricsDto: Codable {}
