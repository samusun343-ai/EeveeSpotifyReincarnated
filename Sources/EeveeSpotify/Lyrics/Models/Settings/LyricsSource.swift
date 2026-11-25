import Foundation

enum LyricsSource: Int, CaseIterable, CustomStringConvertible {
    // Raw values are persisted in UserDefaults; keep them stable.
    case genius = 0
    case lrclib = 1
    case petit = 3
    case notReplaced = 4
    case spicylyrics = 5
    case lrcRedLiriQo = 6

    public static var allCases: [LyricsSource] {
        return [.spicylyrics, .lrclib, .lrcRedLiriQo, .genius, .petit]
    }

    var description: String {
        switch self {
        case .genius:       return "Genius"
        case .lrclib:       return "LRCLIB"
        case .petit:        return "PetitLyrics"
        case .notReplaced:  return "Spotify"
        case .spicylyrics:  return "SpicyLyrics"
        case .lrcRedLiriQo: return "lrc.red + LiriQo"
        }
    }

    var isReplacingLyrics: Bool { self != .notReplaced }

    /// The custom lyrics view needs time-synced lyrics; Genius only has plain text.
    var supportsCustomLyricsView: Bool { isReplacingLyrics && self != .genius }

    static var defaultSource: LyricsSource {
        .spicylyrics
    }
}
