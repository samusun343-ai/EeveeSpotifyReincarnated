import Foundation

struct LyricsDto {
    var lines: [LyricsLineDto]
    var timeSynced: Bool
    var romanization: LyricsRomanizationStatus
    var translation: LyricsTranslationDto?
    var providerCredit: String? = nil
    
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
            $0.timeSynchronized = timeSynced
            $0.restriction = .unrestricted
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
            lyricsData.lines = sortedLines.map { line in
                LyricsLine.with {
                    $0.content = (shouldRomanize && romanization == .canBeRomanized)
                        ? line.content.applyingTransform(.toLatin, reverse: false)!
                        : line.content
                    $0.offsetMs = Int32(line.offsetMs ?? 0)
                }
            }
        }
        
        if let translation = translation {
            lyricsData.translation = LyricsTranslation.with {
                $0.languageCode = translation.languageCode
                $0.lines = translation.lines
            }
        }
        
        return lyricsData
    }
}
