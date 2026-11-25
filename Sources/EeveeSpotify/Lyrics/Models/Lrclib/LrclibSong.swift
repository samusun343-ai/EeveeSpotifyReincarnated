import Foundation

struct LrclibSong: Decodable {
    var name: String
    var plainLyrics: String?
    var syncedLyrics: String?
    var instrumental: Bool
    /// Whether the record carries per-word timings. They are not in
    /// `syncedLyrics` (always line-level LRC) but in the Lyricsfile
    /// below. Optional because older mirrors may not serve the fields.
    var hasWordSync: Bool?
    /// The record's Lyricsfile: a YAML document whose lines carry
    /// start/end times and per-word start times.
    var lyricsfile: String?
}