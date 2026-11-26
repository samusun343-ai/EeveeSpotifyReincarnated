import Foundation

private class LrclibTLSDelegate: NSObject, URLSessionTaskDelegate {
    let expectedHost: String

    init(expectedHost: String) {
        self.expectedHost = expectedHost
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let serverTrust = challenge.protectionSpace.serverTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }

        // Build a fresh trust object from the peer's certificate chain, evaluated
        // against the original hostname. Re-using and mutating the trust object
        // supplied by URLSession for a raw-IP connection can fail chain building
        // (errSSLXCertChainInvalid / -9802) even when the certificate is valid.
        //
        // SecTrustGetCertificateAtIndex is deprecated in iOS 15 and returns nil on
        // iOS 16+ / iOS 26+. Use SecTrustCopyCertificateChain where available.
        //
        // FIX: SecTrustCopyCertificateChain returns a plain CFTypeRef/CFArray on
        // iOS 26; the Swift conditional cast `as? [SecCertificate]` can silently
        // return nil on some OS builds when the bridging isn't automatic.
        // Use CFArrayGetCount / CFArrayGetValueAtIndex to extract the chain safely.
        let certChain: [SecCertificate]
        if #available(iOS 15.0, *) {
            guard let chainRef = SecTrustCopyCertificateChain(serverTrust) else {
                completionHandler(.cancelAuthenticationChallenge, nil)
                return
            }
            let count = CFArrayGetCount(chainRef)
            guard count > 0 else {
                completionHandler(.cancelAuthenticationChallenge, nil)
                return
            }
            certChain = (0..<count).compactMap { i in
                CFArrayGetValueAtIndex(chainRef, i)
                    .map { Unmanaged<SecCertificate>.fromOpaque($0).takeUnretainedValue() }
            }
        } else {
            let count = SecTrustGetCertificateCount(serverTrust)
            guard count > 0 else {
                completionHandler(.cancelAuthenticationChallenge, nil)
                return
            }
            certChain = (0..<count).compactMap { SecTrustGetCertificateAtIndex(serverTrust, $0) }
            guard !certChain.isEmpty else {
                completionHandler(.cancelAuthenticationChallenge, nil)
                return
            }
        }

        let policy = SecPolicyCreateSSL(true, expectedHost as CFString)

        var freshTrust: SecTrust?
        guard SecTrustCreateWithCertificates(certChain as CFArray, policy, &freshTrust) == errSecSuccess,
              let freshTrust else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }

        var error: CFError?
        if SecTrustEvaluateWithError(freshTrust, &error) {
            completionHandler(.useCredential, URLCredential(trust: freshTrust))
        } else {
            writeDebugLog("[LRCLIB] TLS validation failed for \(expectedHost): \(String(describing: error))")
            completionHandler(.cancelAuthenticationChallenge, nil)
        }
    }
}

private func resolveIPv4(_ host: String) -> String? {
    var hints = addrinfo(
        ai_flags: 0, ai_family: AF_INET, ai_socktype: SOCK_STREAM,
        ai_protocol: 0, ai_addrlen: 0, ai_canonname: nil, ai_addr: nil, ai_next: nil
    )
    var result: UnsafeMutablePointer<addrinfo>?

    guard getaddrinfo(host, nil, &hints, &result) == 0, let addr = result else {
        return nil
    }
    defer { freeaddrinfo(result) }

    var ipBuffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
    let sockaddrIn = addr.pointee.ai_addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0 }
    var sinAddr = sockaddrIn.pointee.sin_addr

    guard inet_ntop(AF_INET, &sinAddr, &ipBuffer, socklen_t(INET6_ADDRSTRLEN)) != nil else {
        return nil
    }

    return String(cString: ipBuffer)
}

class LrclibLyricsRepository: LyricsRepository {
    var apiUrl: String
    private let session: URLSession

    private init(apiUrl: String) {
        self.apiUrl = apiUrl
        
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpAdditionalHeaders = [
            "User-Agent": "EeveeSpotify v\(EeveeSpotify.version) https://github.com/whoeevee/EeveeSpotify"
        ]
        // FIX: 4 seconds is far too short — LRCLIB can be slow to respond,
        // and the IPv4-direct attempt + fallback each consumed the full 4s in
        // the debug log, causing guaranteed timeouts. Use 10s instead.
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 10
        configuration.allowsExpensiveNetworkAccess = true
        configuration.allowsConstrainedNetworkAccess = true
        configuration.waitsForConnectivity = false

        if let host = URL(string: apiUrl)?.host {
            session = URLSession(
                configuration: configuration,
                delegate: LrclibTLSDelegate(expectedHost: host),
                delegateQueue: nil
            )
        } else {
            session = URLSession(configuration: configuration)
        }
    }
    
    static let originalApiUrl = "https://lrclib.net/api"
    
    static let shared = LrclibLyricsRepository(
        apiUrl: UserDefaults.lyricsOptions.lrclibUrl
    )

    // Hosts whose IPv4-direct attempt has already failed in this process.
    // Some environments fail that attempt every single time — observed on
    // a real device where the direct connection to lrclib.net's Cloudflare
    // address dies in the TLS handshake (NSURLError -1200 / errSSL -9824)
    // and only the hostname retry succeeds. Remembering the failure means
    // later requests skip the doomed attempt and go straight to the
    // hostname URL the fallback would have used anyway: the request that
    // ultimately runs is identical, only the wasted round trip (and its
    // timeout risk inside the lyrics chain's budget) is gone. Memory-only
    // and per-host, so a network change is picked up on the next launch.
    private static var ipv4DirectFailedHosts: Set<String> = []
    private static let ipv4DirectFailedHostsLock = NSLock()

    private static func ipv4DirectFailed(forHost host: String) -> Bool {
        ipv4DirectFailedHostsLock.lock()
        defer { ipv4DirectFailedHostsLock.unlock() }
        return ipv4DirectFailedHosts.contains(host)
    }

    private static func markIPv4DirectFailed(host: String) {
        ipv4DirectFailedHostsLock.lock()
        ipv4DirectFailedHosts.insert(host)
        ipv4DirectFailedHostsLock.unlock()
    }
    
    private func perform(
        _ path: String, 
        query: [String:Any] = [:]
    ) throws -> Data {
        var stringUrl = "\(apiUrl)\(path)"

        if !query.isEmpty {
            let queryString = query.queryString
            stringUrl += "?\(queryString)"
        }
        
        guard let url = URL(string: stringUrl) else {
            throw LyricsError.decodingError
        }

        var request = URLRequest(url: url)

        // Some networks have broken/unroutable IPv6 paths to lrclib.net that cause
        // ETIMEDOUT at the TCP layer for custom URLSession instances. Resolve to
        // an IPv4 address explicitly and connect to it directly (TLS hostname
        // validation against the original host is handled by LrclibTLSDelegate).
        // Hosts where this direct attempt already failed once in this process
        // are skipped — see ipv4DirectFailedHosts above.
        if let host = url.host, !Self.ipv4DirectFailed(forHost: host), let ip = resolveIPv4(host) {
            var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
            components?.host = ip
            if let ipUrl = components?.url {
                request = URLRequest(url: ipUrl)
                request.setValue(host, forHTTPHeaderField: "Host")
            }
        }

        request.setValue(
            "EeveeSpotify v\(EeveeSpotify.version) https://github.com/whoeevee/EeveeSpotify",
            forHTTPHeaderField: "User-Agent"
        )

        let semaphore = DispatchSemaphore(value: 0)
        var data: Data?
        var error: Error?

        let task = session.dataTask(with: request) { responseData, _, err in
            error = err
            data = responseData
            semaphore.signal()
        }

        try LyricsDownloadHTTP.start(task)
        // Bounded wait (audit P4): 10s is this session's own
        // request/resource timeout, so any response the session would
        // deliver still arrives; only a completion that never fires is
        // cut, and the no-data path below throws as before.
        try LyricsDownloadHTTP.wait(semaphore, task: task, accepting: [404], timeout: 10, onTimeout: .cancelAndReturn)

        if error != nil, request.url != url {
            // IPv4-direct attempt failed; retry with the original hostname URL.
            // Remember the failure so later requests for this host skip the
            // direct attempt entirely (see ipv4DirectFailedHosts above).
            if let host = url.host {
                Self.markIPv4DirectFailed(host: host)
            }
            writeDebugLog("[LRCLIB] IPv4-direct attempt failed (\(error!)), retrying via hostname")

            let fallbackSemaphore = DispatchSemaphore(value: 0)
            var fallbackRequest = URLRequest(url: url)
            fallbackRequest.setValue(
                "EeveeSpotify v\(EeveeSpotify.version) https://github.com/whoeevee/EeveeSpotify",
                forHTTPHeaderField: "User-Agent"
            )

            let fallbackTask = session.dataTask(with: fallbackRequest) { response, _, err in
                error = err
                data = response
                fallbackSemaphore.signal()
            }

            try LyricsDownloadHTTP.start(fallbackTask)
            // Bounded wait (audit P4): same 10s session bound as above.
            try LyricsDownloadHTTP.wait(fallbackSemaphore, task: fallbackTask, accepting: [404], timeout: 10, onTimeout: .cancelAndReturn)
        }

        if let error = error {
            writeDebugLog("[LRCLIB] Request error for \(stringUrl): \(error)")
            throw error
        }

        guard let data else {
            writeDebugLog("[LRCLIB] No data returned for \(stringUrl)")
            throw LyricsError.decodingError
        }
        writeDebugLog("[LRCLIB] \(stringUrl) -> \(data.count) bytes")
        return data
    }
    
    private func getSong(trackName: String, artistName: String, durationSeconds: Int?) throws -> LrclibSong {
        // LRCLIB's signature matching treats the duration as crucial:
        // when one is provided it only serves a record whose duration
        // matches within ±2 seconds. Send it whenever the query knows
        // the track's duration (the Web API resolution step supplies
        // it); without one the endpoint falls back to name matching
        // alone, and the client-side verification in getRecord is the
        // only guard.
        var parameters: [String: Any] = [
            "track_name": trackName,
            "artist_name": artistName
        ]

        if let durationSeconds, durationSeconds > 0 {
            parameters["duration"] = durationSeconds
        }

        let data: Data = try perform("/get", query: parameters)
        do {
            return try JSONDecoder().decode(LrclibSong.self, from: data)
        } catch {
            let body = String(data: data, encoding: .utf8) ?? "<non-utf8>"
            writeDebugLog("[LRCLIB] Decode error for \(trackName)/\(artistName): \(error). Body: \(body.prefix(300))")
            throw error
        }
    }
    
    private func mapSyncedLyricsLines(_ lines: [String]) -> [LyricsLineDto] {
        return lines.compactMap { line in
            guard let match = line.firstMatch(
                "\\[(?<minute>\\d*):(?<seconds>\\d+\\.\\d+|\\d+)\\] ?(?<content>.*)"
            ) else {
                return nil
            }
            
            var captures: [String: String] = [:]
            
            for name in ["minute", "seconds", "content"] {
                let matchRange = match.range(withName: name)
                
                if let substringRange = Range(matchRange, in: line) {
                    captures[name] = String(line[substringRange])
                }
            }
            
            let minute = Int(captures["minute"]!)!
            let seconds = Float(captures["seconds"]!)!
            let content = captures["content"]!
            
            return LyricsLineDto(
                content: content.lyricsNoteIfEmpty,
                offsetMs: Int(minute * 60 * 1000 + Int(seconds * 1000))
            )
        }
    }

    /// Fetches the raw LRCLIB record for a query, trying the title
    /// as-is first and the stripped title second — the same two
    /// attempts getLyrics makes. Exposed for the combined
    /// lrc.red/LRCLIB/LiriQo source, whose LRCLIB stage needs record
    /// fields (the word timings in the Lyricsfile) that the flattened
    /// LyricsDto drops.
    ///
    /// Every returned record is verified against the query before it
    /// may be used (title, artist, duration — see
    /// LyricsMatchVerification). The stripped-title attempt needs this
    /// most: LRCLIB answers it with the record for the *stripped* name,
    /// so for "Our Memories (Instrumental)" it returns the vocal
    /// version's record, whose name was previously never compared to
    /// the query at all. A record that fails verification is a miss,
    /// exactly like a 404.
    func getRecord(_ query: LyricsSearchQuery) throws -> LrclibSong {
        let attempts = [query.title, query.title.strippedTrackTitle]

        for (index, attemptTitle) in attempts.enumerated() {
            if index > 0, attemptTitle == attempts[0] {
                continue
            }

            do {
                let song = try getSong(
                    trackName: attemptTitle,
                    artistName: query.primaryArtist,
                    durationSeconds: query.durationSeconds
                )

                guard recordMatchesQuery(song, query: query) else {
                    writeDebugLog("[LRCLIB] Record for \(attemptTitle)/\(query.primaryArtist) failed verification (record: \(song.name)/\(song.artistName ?? "?")), treating as a miss")
                    continue
                }

                return song
            } catch {
                // A failed download request is not a missing song.
                if LyricsDownloadHTTP.isDownloading, !(error is DecodingError) { throw error }
                continue
            }
        }

        throw LyricsError.noSuchSong
    }

    /// Whether a record LRCLIB returned may be served for the query:
    /// its name must be the queried title (version descriptors
    /// included — an instrumental query must not adopt the vocal
    /// record), its artist the queried artist, and its duration the
    /// queried duration when both are known.
    private func recordMatchesQuery(_ song: LrclibSong, query: LyricsSearchQuery) -> Bool {
        guard let artistName = song.artistName,
              LyricsMatchVerification.artistsMatch(queryArtist: query.primaryArtist, candidateArtist: artistName) else {
            return false
        }

        guard LyricsMatchVerification.titlesMatch(queryTitle: query.title, candidateTitle: song.name) else {
            return false
        }

        return LyricsMatchVerification.durationsCompatible(
            querySeconds: query.durationSeconds,
            candidateSeconds: song.duration
        )
    }

    func getLyrics(_ query: LyricsSearchQuery, options: LyricsOptions) throws -> LyricsDto {
        let song = try getRecord(query)

        if song.instrumental {
            return LyricsDto(
                lines: [],
                timeSynced: false,
                romanization: .original
            )
        }

        if let syncedLyrics = song.syncedLyrics, !syncedLyrics.isEmpty {
            let rawLines = Array(syncedLyrics.components(separatedBy: "\n").dropLast())
            let mappedLines = mapSyncedLyricsLines(rawLines)

            if !mappedLines.isEmpty {
                return LyricsDto(
                    lines: mappedLines,
                    timeSynced: true,
                    romanization: rawLines.canBeRomanized ? .canBeRomanized : .original
                )
            }

            // Synced text that parses to zero timed lines (e.g. only LRC
            // metadata tags) is not a result either — fall through to the
            // plain text, and to the miss below if there is none.
        }
        
        guard let plainLyrics = song.plainLyrics, !plainLyrics.isEmpty else {
            // The record exists but carries no lyrics text at all, and it
            // is not flagged instrumental (that case returned above). That
            // is a miss, not a result: returning an empty DTO here made
            // "LRCLIB has no lyrics for this song" indistinguishable from
            // "this song is instrumental" downstream — the Genius fallback
            // in CustomLyrics only runs on a throw, and the empty DTO is
            // rendered as the instrumental placeholder, so a song that
            // simply has no lyrics was presented as if it had some. The
            // combined source's LRCLIB stage (LrcRedLiriQoLyricsRepository)
            // already throws in exactly this case; match it.
            throw LyricsError.noSuchSong
        }
        
        let lines = Array(plainLyrics.components(separatedBy: "\n").dropLast())

        // A plain text made only of blank lines (LRCLIB records exist in
        // that shape) is no lyrics at all: as a DTO it would pass the
        // offline cache's non-empty-lines guard and be stored and served
        // as if the song had lyrics. Blank lines *within* real lyrics
        // are untouched — this only fires when every line is blank.
        guard lines.contains(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) else {
            throw LyricsError.noSuchSong
        }

        return LyricsDto(
            lines: lines.map { content in LyricsLineDto(content: content) },
            timeSynced: false,
            romanization: lines.canBeRomanized ? .canBeRomanized : .original
        )
    }
}
