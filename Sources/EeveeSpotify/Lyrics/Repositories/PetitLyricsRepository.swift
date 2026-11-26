import Foundation

class PetitLyricsRepository: LyricsRepository {
    private let url = "https://p1.petitlyrics.com/api/GetPetitLyricsData.php"
    private let session: URLSession

    init() {
        let configuration = URLSessionConfiguration.default
        configuration.httpAdditionalHeaders = [
            "Content-Type": "application/x-www-form-urlencoded"
        ]
        
        session = URLSession(configuration: configuration)
    }
    
    private func perform(_ data: [String: Any]) throws -> PetitResponse {
        var finalData = data

        finalData["clientAppId"] = "p1110417"
        finalData["terminalType"] = 10
        
        guard let requestUrl = URL(string: url) else {
            throw LyricsError.unknownError
        }

        var request = URLRequest(url: requestUrl)
        
        request.httpMethod = "POST"
        request.httpBody = finalData.queryString.data(using: .utf8)

        let semaphore = DispatchSemaphore(value: 0)
        var data: Data?
        var error: Error?
        
        let task = session.dataTask(with: request) { response, _, err in
            error = err
            data = response
            semaphore.signal()
        }

        try LyricsDownloadHTTP.start(task)
        // Bounded wait (audit P4): this session uses the default
        // configuration (60s request timeout), so a completion that
        // never arrives would block the calling worker indefinitely.
        // 5s is generous for this API, and getLyrics makes at most two
        // sequential calls (search + fetch), so one lookup stays within
        // 10s. A timeout is a transient failure, like a network error.
        try LyricsDownloadHTTP.wait(semaphore, task: task, timeout: 5)

        if let error = error {
            throw error
        }

        guard let data,
              let response = try? XMLDecoder().decode(PetitResponse.self, from: data) else {
            throw LyricsError.decodingError
        }

        return response
    }
    
    
    /// Whether a returned Petit song is the queried track. The
    /// server-side search is comparatively strict (title+artist AND),
    /// but its answer was adopted with no check at all; a song whose
    /// title or artist does not verify is a miss, not a result.
    private func songMatchesQuery(_ song: PetitSong, query: LyricsSearchQuery) -> Bool {
        guard let artist = song.artist else {
            return false
        }

        return LyricsMatchVerification.titlesMatch(queryTitle: query.title, candidateTitle: song.title)
            && LyricsMatchVerification.artistsMatch(queryArtist: query.primaryArtist, candidateArtist: artist)
    }

    private func searchSong(_ query: LyricsSearchQuery) throws -> PetitSong {
        let response = try perform(
            ["key_title": query.title, "key_artist": query.primaryArtist, "max_count": 1]
        )

        guard let song = response.songs.first else {
            throw LyricsError.noSuchSong
        }

        guard songMatchesQuery(song, query: query) else {
            writeDebugLog("[Petit] Search result \(song.title)/\(song.artist ?? "?") failed verification against \(query.title)/\(query.primaryArtist), treating as a miss")
            throw LyricsError.noSuchSong
        }

        return song
    }
    
    
    private func getSong(_ lyricsId: Int, availableLyricsType: PetitLyricsType) throws -> PetitSong {
        var lyricsType: PetitLyricsType
        
        if availableLyricsType == .linesSynced {
            lyricsType = .plain
        }
        else {
            lyricsType = availableLyricsType
        }
        
        let response = try perform(
            ["key_lyricsId": lyricsId, "lyricsType": lyricsType.rawValue]
        )
        
        guard let song = response.songs.first else {
            throw LyricsError.noSuchSong
        }
        
        return song
    }
    
    
    func getLyrics(_ query: LyricsSearchQuery, options: LyricsOptions) throws -> LyricsDto {
        let searchResult = try searchSong(query)
        let song = try getSong(
            searchResult.lyricsId,
            availableLyricsType: searchResult.availableLyricsType
        )

        // The fetched record is verified again: its lyrics are what
        // gets served, so it — not only the search hit that pointed at
        // it — must be the queried track.
        guard songMatchesQuery(song, query: query) else {
            writeDebugLog("[Petit] Fetched song \(song.title)/\(song.artist ?? "?") failed verification against \(query.title)/\(query.primaryArtist), treating as a miss")
            throw LyricsError.noSuchSong
        }
        
        guard let lyricsData = Data(base64Encoded: song.lyricsData) else {
            throw LyricsError.decodingError
        }
        
        switch song.lyricsType {
            
        case .wordsSynced:
            guard let lyrics = try? XMLDecoder().decode(PetitLyricsData.self, from: lyricsData) 
            else {
                throw LyricsError.decodingError
            }
            
            return LyricsDto(
                lines: lyrics.lines.map {
                    LyricsLineDto(
                        content: $0.linestring,
                        offsetMs: $0.words.first?.starttime ?? 0
                    )
                },
                timeSynced: true,
                romanization: lyrics.lines.map { $0.linestring }.canBeRomanized
                    ? .canBeRomanized
                    : .original
            )
            
        case .plain:
            guard let stringLyrics = String(data: lyricsData, encoding: .utf8) else {
                throw LyricsError.decodingError
            }
            let lines = stringLyrics.components(separatedBy: "\n")
            
            return LyricsDto(
                lines: lines.map { LyricsLineDto(content: $0) },
                timeSynced: false,
                romanization: lines.canBeRomanized ? .canBeRomanized : .original
            )
            
        default:
            throw LyricsError.decodingError
        }
    }
}
