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
    /// The track's duration in seconds, when the resolution step that
    /// supplied the metadata carried one (currently only the Web API
    /// step — its response has `duration_ms`). Unlike the ISRC this
    /// *is* a search input: LRCLIB's signature matching treats it as
    /// crucial (it only serves a record whose duration matches within
    /// ±2 seconds), LiriQo accepts it alongside the ISRC, and the
    /// acceptance checks (LyricsMatchVerification) compare returned
    /// records against it. It comes from the same ID-keyed response as
    /// the ISRC, so it is certainly this track's own duration.
    var durationSeconds: Int? = nil
}
