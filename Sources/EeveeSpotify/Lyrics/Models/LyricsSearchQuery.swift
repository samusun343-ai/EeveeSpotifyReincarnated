import Foundation

struct LyricsSearchQuery: Hashable {
    var title: String
    var primaryArtist: String
    var spotifyTrackId: String
    /// The track's own ISRC, when metadata resolution could supply one
    /// (currently only the Web API step returns it — its response is the
    /// one place that carries `external_ids.isrc`). It is only ever set
    /// from a resolution step that positively matched this query's
    /// track ID, and feeds the offline cache's identity keying
    /// (LyricsIdentity) — never the provider searches themselves.
    var isrc: String? = nil
}
