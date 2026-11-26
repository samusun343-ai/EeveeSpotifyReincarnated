import Foundation

class GeniusLyricsRepository: LyricsRepository {
    static let shared = GeniusLyricsRepository()
    private let jsonDecoder: JSONDecoder
    private let apiUrl = "https://api.genius.com"
    private let session: URLSession

    init() {
        let configuration = URLSessionConfiguration.default
        configuration.httpAdditionalHeaders = [
            "X-Genius-iOS-Version": "6.21.0",
            "X-Genius-Logged-Out": "true",
            "User-Agent": "Genius/1109 \(URLSessionHelper.CFNetworkVersion) \(URLSessionHelper.DarwinVersion)"
        ]
        
        session = URLSession(configuration: configuration)
        
        jsonDecoder = JSONDecoder()
        jsonDecoder.keyDecodingStrategy = .convertFromSnakeCase
    }
    
    private func perform(
        _ path: String, 
        query: [String:Any] = [:]
    ) throws -> GeniusDataResponse? {
        var stringUrl = "\(apiUrl)\(path)"

        if !query.isEmpty {
            let queryString = query.queryString
            stringUrl += "?\(queryString)"
        }
        
        // The path/query are built from track metadata; a malformed
        // string must fail the lookup, not crash it.
        guard let url = URL(string: stringUrl) else {
            throw LyricsError.unknownError
        }

        let request = URLRequest(url: url)

        let semaphore = DispatchSemaphore(value: 0)
        var data: Data?
        var error: Error?

        let task = session.dataTask(with: request) { response, _, err in
            error = err
            data = response
            semaphore.signal()
        }

        task.resume()
        // Bounded wait (audit P4): this session uses the default
        // configuration (60s request timeout), so a completion that
        // never arrives would block the calling worker indefinitely.
        // 5s is generous for Genius's JSON API, and getLyrics makes at
        // most two sequential calls, keeping one lookup inside the
        // callers' budgets (12s Genius-fallback waiter, 18s delegate
        // budget). A timeout is a transient failure, like a network
        // error — never a "no such song".
        if semaphore.wait(timeout: .now() + 5) == .timedOut {
            task.cancel()
            throw LyricsError.unknownError
        }

        if let error = error {
            throw error
        }

        guard let data,
              let rootResponse = try? jsonDecoder.decode(GeniusRootResponse.self, from: data) else {
            throw LyricsError.decodingError
        }
        return rootResponse.response
    }
    
    
    private func searchSong(_ query: String) throws -> [GeniusHit] {
        let data = try perform("/search/song", query: ["q": query])
        
        guard
            case .sections(let sectionsResponse) = data,
            let section = sectionsResponse.sections.first
        else {
            throw LyricsError.decodingError
        }
        
        return section.hits
    }

    private func getSongInfo(_ songId: Int) throws -> GeniusSong {
        let data = try perform("/songs/\(songId)", query: ["text_format": "plain"])
        
        guard case .song(let songResponse) = data else {
            throw LyricsError.decodingError
        }
        
        return songResponse.song
    }
    
    
    /// The best hit that *verifies* against the query — title and
    /// artist must both agree (see LyricsMatchVerification) — or nil
    /// when none does. Search is only candidate retrieval: the pool
    /// used to degrade title+artist → title-only (substring!) → the
    /// first hit overall, unverified, so a query nothing matched still
    /// adopted some song's lyrics (measured: an instrumental "Spring"
    /// adopted a Vivaldi sonnet entry). A hit that cannot be verified
    /// is not this song, however the search ranked it.
    ///
    /// The one deliberate exception is Genius's own romanization
    /// account: when romanization is requested, an entry credited to
    /// "Genius Romanizations" whose title verifies is the romanized
    /// edition of this song by construction (the search itself was
    /// scoped to this title and artist), so it is preferred over a
    /// verified original-language hit.
    private func mostRelevantHitResult(
        hits: [GeniusHit],
        query: LyricsSearchQuery,
        romanized: Bool,
        hasFoundRomanizedLyrics: inout Bool
    ) -> GeniusHitResult? {
        let results = hits.map { $0.result }

        if romanized, let romanizedSong = results.first(where: {
            $0.artistNames == "Genius Romanizations"
                && LyricsMatchVerification.titlesMatch(queryTitle: query.title, candidateTitle: $0.title)
        }) {
            hasFoundRomanizedLyrics = true
            return romanizedSong
        }

        return results.first { result in
            LyricsMatchVerification.titlesMatch(queryTitle: query.title, candidateTitle: result.title)
                && LyricsMatchVerification.artistsMatch(queryArtist: query.primaryArtist, candidateArtist: result.artistNames)
        }
    }
    
    private func mapLyricsLines(_ rawLines: [String]) -> [String] {
        var lines = rawLines
            .map { $0.trimmingCharacters(in: .whitespaces) }
        
        lines.removeAll { $0 ~= "\\[.*\\]" }

        lines = Array(
            lines
                .drop(while: { $0.isEmpty })
                .dropLast(while: { $0.isEmpty })
        )
        
        return lines
    }
    
    func getLyrics(_ query: LyricsSearchQuery, options: LyricsOptions) throws -> LyricsDto {
        let strippedTitle = query.title.strippedTrackTitle
        let hits = try searchSong("\(strippedTitle) \(query.primaryArtist)")

        guard !hits.isEmpty else {
            throw LyricsError.noSuchSong
        }

        var hasFoundRomanizedLyrics = false

        guard let song = mostRelevantHitResult(
            hits: hits,
            query: query,
            romanized: options.romanization,
            hasFoundRomanizedLyrics: &hasFoundRomanizedLyrics
        ) else {
            throw LyricsError.noSuchSong
        }

        let songInfo = try getSongInfo(song.id)

        // Verify the fetched song itself, not just the search hit that
        // pointed at it: the lyrics below come from this record. A
        // romanization entry is exempt from the artist check (its
        // credit is the romanization account, by design) but not the
        // title check.
        if let songTitle = songInfo.title,
           !LyricsMatchVerification.titlesMatch(queryTitle: query.title, candidateTitle: songTitle) {
            throw LyricsError.noSuchSong
        }

        if !hasFoundRomanizedLyrics, let songArtist = songInfo.artistNames,
           !LyricsMatchVerification.artistsMatch(queryArtist: query.primaryArtist, candidateArtist: songArtist) {
            throw LyricsError.noSuchSong
        }
        let plainLines = songInfo.lyrics.plain.components(separatedBy: "\n")
        
        var romanization = LyricsRomanizationStatus.original
        
        if hasFoundRomanizedLyrics {
            romanization = .romanized
        }
        else if songInfo.language.isCanBeRomanizedLanguage {
            romanization = .canBeRomanized
        }
    
        return LyricsDto(
            lines: mapLyricsLines(plainLines).map { line in LyricsLineDto(content: line) },
            timeSynced: false,
            romanization: romanization
        )
    }
}
