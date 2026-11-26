import Foundation

struct PetitSong: Codable {
    var lyricsId: Int
    var title: String
    /// The song's artist credit. The search response carries it (the
    /// model never decoded it), and it is required to verify the
    /// returned song against the query before its lyrics are served —
    /// see PetitLyricsRepository. Optional only so a response without
    /// it fails verification instead of decoding.
    var artist: String?
    var availableLyricsType: PetitLyricsType
    var lyricsType: PetitLyricsType
    var lyricsData: String
}
