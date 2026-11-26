import Foundation

struct GeniusSong: Decodable {
    var lyrics: GeniusLyrics
    var language: String
    /// The song's own title and artist credit, decoded so the fetched
    /// record can be verified against the query before its lyrics are
    /// served (see GeniusLyricsRepository.getLyrics). Optional: a
    /// response that omits them simply skips that second check.
    var title: String?
    var artistNames: String?
}
