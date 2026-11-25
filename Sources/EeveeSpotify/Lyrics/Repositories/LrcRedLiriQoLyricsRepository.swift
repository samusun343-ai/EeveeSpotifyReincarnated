import Foundation

/// Two-stage lyrics source combining lrc.red and LiriQo.
///
/// Stage 1 is lrc.red: a large, CDN-cached catalogue keyed by ISRC with
/// line- and word-synced lyrics, fast enough to hit on every track change.
/// Stage 2 is LiriQo, an aggregator over 11 providers (Apple Music,
/// Musixmatch, NetEase, PetitLyrics, LRCLIB, ...) that often has a song
/// when lrc.red does not — but it is slow (several seconds) and tightly
/// rate-limited, so it is only queried, once and without retries, when
/// stage 1 found nothing, and once more as an upgrade attempt when
/// stage 1 only had untimed (plain) lyrics: a synced LiriQo result then
/// replaces the plain text, while any LiriQo failure keeps it. LiriQo
/// outcomes are cached in memory for the session (LRU, 100 entries) so
/// repeat plays never re-ask — but only definitive outcomes are cached:
/// a 429, a server error or a network failure is never recorded as a
/// miss, so a rate-limited track is asked about again on the next play
/// instead of staying lyric-less for the whole session. If both stages
/// fail, the error propagates and the existing Genius fallback in
/// CustomLyrics takes over as the final fallback.
///
/// Where an upstream supplies a translation that can be aligned to the
/// lyric lines with certainty — TTML translations keyed by line, or a
/// timestamped translation whose timestamps match the lines exactly —
/// it is revived into `LyricsDto.translation`; the display plumbing for
/// it (LyricsDto.toSpotifyLyricsData) was never removed. Plain-text
/// translations whose line count differs from the body (NetEase's, which
/// skips untranslated credit lines) are deliberately not used: a shifted
/// translation is worse than none.
///
/// lrc.red's terms require an identifying User-Agent and a visible
/// credit, so every request carries the app name + repository link and
/// every returned LyricsDto carries providerCredit "lrc.red". LiriQo
/// asks for attribution too, so its credits name the upstream provider.
class LrcRedLiriQoLyricsRepository: LyricsRepository {
    static let shared = LrcRedLiriQoLyricsRepository()

    private let lrcRedSession: URLSession
    private let liriQoSession: URLSession

    private static let userAgent = "EeveeSpotifyReincarnated v\(EeveeSpotify.version) (+https://github.com/samusun343-ai/EeveeSpotifyReincarnated)"
    private static let lrcRedBaseUrl = "https://lrc.red"
    private static let liriQoBaseUrl = "https://api.liriqo-alfarrizi.my.id/v1"

    // MARK: - LiriQo session cache

    /// One cached LiriQo outcome. A hit keeps only the DTOs needed to
    /// replay the result — never the raw response or extra metadata —
    /// and a miss is a bare marker. Memory-only: nothing is written to
    /// disk or UserDefaults, and the cache dies with the process.
    private enum LiriQoCacheEntry {
        case hit(dto: LyricsDto, karaoke: KaraokeLyricsDto?)
        case miss
    }

    private static let liriQoCacheCapacity = 100

    private let liriQoCacheLock = NSLock()
    private var liriQoCache: [String: LiriQoCacheEntry] = [:]
    private var liriQoCacheOrder: [String] = []

    private init() {
        let lrcRedConfiguration = URLSessionConfiguration.ephemeral
        lrcRedConfiguration.httpAdditionalHeaders = [
            "User-Agent": Self.userAgent
        ]
        lrcRedConfiguration.timeoutIntervalForRequest = 10
        lrcRedConfiguration.timeoutIntervalForResource = 10
        lrcRedConfiguration.allowsExpensiveNetworkAccess = true
        lrcRedConfiguration.allowsConstrainedNetworkAccess = true
        lrcRedConfiguration.waitsForConnectivity = false
        lrcRedSession = URLSession(configuration: lrcRedConfiguration)

        // LiriQo answers in ~6s on a good day; give it room, but only ever
        // ask once per track (see the type comment about its rate limit).
        let liriQoConfiguration = URLSessionConfiguration.ephemeral
        liriQoConfiguration.httpAdditionalHeaders = [
            "User-Agent": Self.userAgent
        ]
        liriQoConfiguration.timeoutIntervalForRequest = 30
        liriQoConfiguration.timeoutIntervalForResource = 30
        liriQoConfiguration.allowsExpensiveNetworkAccess = true
        liriQoConfiguration.allowsConstrainedNetworkAccess = true
        liriQoConfiguration.waitsForConnectivity = false
        liriQoSession = URLSession(configuration: liriQoConfiguration)
    }

    // MARK: - Network

    private func perform(
        _ stringUrl: String,
        session: URLSession,
        logTag: String
    ) throws -> (Data, Int) {
        guard let url = URL(string: stringUrl) else {
            throw LyricsError.decodingError
        }

        var request = URLRequest(url: url)
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")

        let semaphore = DispatchSemaphore(value: 0)
        var data: Data?
        var statusCode = 0
        var error: Error?

        let task = session.dataTask(with: request) { responseData, response, err in
            data = responseData
            statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            error = err
            semaphore.signal()
        }

        task.resume()
        semaphore.wait()

        if let error = error {
            writeDebugLog("[\(logTag)] Request error for \(stringUrl): \(error)")
            throw error
        }

        guard let data else {
            writeDebugLog("[\(logTag)] No data returned for \(stringUrl)")
            throw LyricsError.decodingError
        }

        writeDebugLog("[\(logTag)] \(stringUrl) -> \(data.count) bytes (HTTP \(statusCode))")
        return (data, statusCode)
    }

    /// Logs a non-200 response with its failure category distinguished —
    /// rate limited (429), server busy (503), not found (404), anything
    /// else by bare status — so field reports ("this one song shows no
    /// lyrics") can be told apart from logs alone.
    private func logHttpFailure(logTag: String, statusCode: Int, context: String) {
        let category: String

        switch statusCode {
        case 429:
            category = "rate limited (HTTP 429)"
        case 503:
            category = "server busy (HTTP 503)"
        case 404:
            category = "not found (HTTP 404)"
        default:
            category = "HTTP \(statusCode)"
        }

        writeDebugLog("[\(logTag)] \(context) failed: \(category)")
    }

    // MARK: - LyricsRepository

    func getLyrics(_ query: LyricsSearchQuery, options: LyricsOptions) throws -> LyricsDto {
        var lrcRedPlainLyrics: LyricsDto?

        do {
            let dto = try getLrcRedLyrics(query)

            if dto.timeSynced, !dto.lines.isEmpty {
                return dto
            }

            if !dto.lines.isEmpty {
                // lrc.red has the song, but only as untimed (plain) text.
                // Keep it as a floor and let stage 2 try to upgrade it to
                // a synced version below: plain text beats no lyrics, but
                // a synced LiriQo result beats plain text.
                lrcRedPlainLyrics = dto
                writeDebugLog("[lrc.red+LiriQo] lrc.red returned plain-only lyrics for \(query.title)/\(query.primaryArtist), trying LiriQo for a synced version")
            } else {
                writeDebugLog("[lrc.red+LiriQo] lrc.red returned no lines for \(query.title)/\(query.primaryArtist), trying LiriQo")
            }
        } catch {
            writeDebugLog("[lrc.red+LiriQo] lrc.red failed for \(query.title)/\(query.primaryArtist): \(error), trying LiriQo")
        }

        if let lrcRedPlainLyrics {
            if let upgraded = try? getLiriQoLyrics(query, options: options), upgraded.timeSynced, !upgraded.lines.isEmpty {
                return upgraded
            }

            return lrcRedPlainLyrics
        }

        return try getLiriQoLyrics(query, options: options)
    }

    // MARK: - Stage 1: lrc.red

    private func getLrcRedLyrics(_ query: LyricsSearchQuery) throws -> LyricsDto {
        let isrc = try searchLrcRed(query: query)
        let track = try fetchLrcRedTrack(isrc: isrc)

        switch track.sync ?? "" {
        case "word", "line":
            return try fetchLrcRedSyncedLyrics(isrc: isrc, track: track, query: query)
        default:
            // "none" (or unknown): the track exists but has no timing.
            // The TTML still carries the text, so serve it as plain lyrics.
            return try fetchLrcRedPlainLyrics(isrc: isrc, track: track)
        }
    }

    private func searchLrcRed(query: LyricsSearchQuery) throws -> String {
        var hits = try fetchLrcRedSearchHits(title: query.title, artist: query.primaryArtist)

        if hits.isEmpty {
            // lrc.red search matches against its catalog titles, which omit
            // "(feat. …)"-style suffixes that Spotify track titles carry —
            // searching with the raw title returns zero hits for such tracks
            // (verified with Koruru "Our Memories (feat. Nakasa)"). Retry
            // once with the stripped title before giving up on this stage.
            let strippedTitle = query.title.strippedTrackTitle

            if strippedTitle != query.title {
                writeDebugLog("[lrc.red] No hits for raw title \(query.title), retrying with stripped title \(strippedTitle)")
                hits = try fetchLrcRedSearchHits(title: strippedTitle, artist: query.primaryArtist)
            }
        }

        guard !hits.isEmpty else {
            throw LyricsError.noSuchSong
        }

        let hit = bestLrcRedHit(hits, query: query) ?? hits[0]

        guard let isrc = hit.isrc, !isrc.isEmpty else {
            throw LyricsError.noSuchSong
        }

        return isrc
    }

    private func fetchLrcRedSearchHits(title: String, artist: String) throws -> [LrcRedSearchResponse.Hit] {
        // lrc.red search fails on queries containing apostrophes
        // (observed by other integrators), so strip them beforehand.
        let searchText = "\(title) \(artist)".removingApostrophes
        let stringUrl = "\(Self.lrcRedBaseUrl)/search.json?\((["q": searchText]).queryString)"

        let (data, statusCode) = try perform(stringUrl, session: lrcRedSession, logTag: "lrc.red")

        guard statusCode == 200 else {
            logHttpFailure(logTag: "lrc.red", statusCode: statusCode, context: "Search for \(title)/\(artist)")
            throw LyricsError.noSuchSong
        }

        let response: LrcRedSearchResponse
        do {
            response = try JSONDecoder().decode(LrcRedSearchResponse.self, from: data)
        } catch {
            let body = String(data: data, encoding: .utf8) ?? "<non-utf8>"
            writeDebugLog("[lrc.red] Search decode error: \(error). Body: \(body.prefix(300))")
            throw LyricsError.decodingError
        }

        return response.hits ?? []
    }

    /// Prefers a hit whose normalized title and artist both match the
    /// query, then a title-only match. Normalization removes "(...)"
    /// suffixes and "- ..." tails (via strippedTrackTitle), case, and
    /// punctuation, so remaster/version variants still match.
    private func bestLrcRedHit(_ hits: [LrcRedSearchResponse.Hit], query: LyricsSearchQuery) -> LrcRedSearchResponse.Hit? {
        let wantedTitle = normalizedForMatch(query.title)
        let wantedArtist = normalizedForMatch(query.primaryArtist)

        return hits.first { hit in
            normalizedForMatch(hit.title ?? "") == wantedTitle
                && normalizedForMatch(hit.artist ?? "") == wantedArtist
        } ?? hits.first { hit in
            normalizedForMatch(hit.title ?? "") == wantedTitle
        }
    }

    private func normalizedForMatch(_ value: String) -> String {
        value
            .strippedTrackTitle
            .lowercased()
            .removingApostrophes
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private func fetchLrcRedTrack(isrc: String) throws -> LrcRedTrackResponse {
        let (data, statusCode) = try perform(
            "\(Self.lrcRedBaseUrl)/s/\(isrc).json",
            session: lrcRedSession,
            logTag: "lrc.red"
        )

        guard statusCode == 200 else {
            logHttpFailure(logTag: "lrc.red", statusCode: statusCode, context: "Track metadata for \(isrc)")
            throw LyricsError.noSuchSong
        }

        do {
            return try JSONDecoder().decode(LrcRedTrackResponse.self, from: data)
        } catch {
            writeDebugLog("[lrc.red] Track decode error for \(isrc): \(error)")
            throw LyricsError.decodingError
        }
    }

    private func fetchLrcRedSyncedLyrics(
        isrc: String,
        track: LrcRedTrackResponse,
        query: LyricsSearchQuery
    ) throws -> LyricsDto {
        let lrcUrl = track.files?.lrc ?? "\(Self.lrcRedBaseUrl)/s/\(isrc).lrc"
        let (data, statusCode) = try perform(lrcUrl, session: lrcRedSession, logTag: "lrc.red")

        guard statusCode == 200 else {
            logHttpFailure(logTag: "lrc.red", statusCode: statusCode, context: "Synced lyrics file for \(isrc)")
            throw LyricsError.noSuchSong
        }

        guard let lrcText = String(data: data, encoding: .utf8) else {
            throw LyricsError.noSuchSong
        }

        var timedLines: [(startMs: Int, text: String, words: [LrcRedTimedWord])] = []

        for rawLine in lrcText.components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)

            // Lines without a leading timestamp are metadata tags
            // ([ti:], [ar:], [length:], ...) or untimed text — skip them.
            guard let match = line.firstMatch(
                "\\[(?<minute>\\d+):(?<seconds>\\d+\\.\\d+|\\d+)\\] ?(?<content>.*)"
            ) else {
                continue
            }

            var captures: [String: String] = [:]

            for name in ["minute", "seconds", "content"] {
                let matchRange = match.range(withName: name)

                if let substringRange = Range(matchRange, in: line) {
                    captures[name] = String(line[substringRange])
                }
            }

            guard let minute = captures["minute"].flatMap(Int.init),
                  let seconds = captures["seconds"].flatMap(Float.init),
                  let content = captures["content"] else {
                continue
            }

            let parsed = parseEnhancedLrcLine(content)

            timedLines.append((
                startMs: minute * 60 * 1000 + Int(seconds * 1000),
                text: parsed.text,
                words: parsed.words
            ))
        }

        guard !timedLines.isEmpty else {
            throw LyricsError.noSuchSong
        }

        var lines: [LyricsLineDto] = []
        var karaokeLines: [KaraokeLineDto] = []
        let hasWordTimedLines = timedLines.contains { !$0.words.isEmpty }

        for (index, timedLine) in timedLines.enumerated() {
            lines.append(LyricsLineDto(
                content: timedLine.text.lyricsNoteIfEmpty,
                offsetMs: timedLine.startMs
            ))

            let lineEndMs = index + 1 < timedLines.count
                ? timedLines[index + 1].startMs
                : timedLine.startMs + 4000

            if !timedLine.words.isEmpty {
                var syllables: [KaraokeSyllableDto] = []

                for (wordIndex, word) in timedLine.words.enumerated() {
                    let wordEndMs = wordIndex + 1 < timedLine.words.count
                        ? timedLine.words[wordIndex + 1].startMs
                        : lineEndMs

                    syllables.append(KaraokeSyllableDto(
                        text: word.text,
                        startMs: word.startMs,
                        endMs: wordEndMs,
                        isPartOfWord: false
                    ))
                }

                karaokeLines.append(KaraokeLineDto(
                    syllables: syllables,
                    startMs: timedLine.startMs,
                    endMs: lineEndMs
                ))
            } else if hasWordTimedLines, !timedLine.text.isEmpty {
                // Mixed track: this line has no word timings, but other
                // lines do — and because a karaoke entry is published
                // below, CustomLyrics' line-synced fill (which skips
                // tracks that already have an entry) would never cover
                // this line. Fill it the way SpicyLyrics fills Line-type
                // songs: split the line into words that all light up at
                // the line's start. Pure line tracks (no word timings
                // anywhere) still publish nothing here and keep using
                // that shared fill.
                let pseudoSyllables = timedLine.text
                    .split(whereSeparator: { $0.isWhitespace })
                    .map {
                        KaraokeSyllableDto(
                            text: String($0),
                            startMs: timedLine.startMs,
                            endMs: timedLine.startMs,
                            isPartOfWord: false
                        )
                    }

                if !pseudoSyllables.isEmpty {
                    karaokeLines.append(KaraokeLineDto(
                        syllables: pseudoSyllables,
                        startMs: timedLine.startMs,
                        endMs: lineEndMs
                    ))
                }
            }
        }

        if !karaokeLines.isEmpty {
            KaraokeLyricsStore.shared.set(
                trackId: query.spotifyTrackId,
                lyrics: KaraokeLyricsDto(
                    lines: karaokeLines,
                    songWriters: track.songwriters ?? [],
                    providerCode: nil,
                    providerName: "lrc.red"
                )
            )
        }

        return LyricsDto(
            lines: lines,
            timeSynced: true,
            romanization: lines.map(\.content).canBeRomanized ? .canBeRomanized : .original,
            providerCredit: "lrc.red"
        )
    }

    /// Splits one enhanced-LRC line body into its plain text and its
    /// word timings. Word tags look like `<00:28.25>the ` — the text after
    /// a tag runs until the next tag and usually carries its own spacing.
    private func parseEnhancedLrcLine(_ content: String) -> (text: String, words: [LrcRedTimedWord]) {
        guard content.contains("<") else {
            return (content, [])
        }

        guard let regex = try? NSRegularExpression(
            pattern: "<(?<minute>\\d+):(?<seconds>\\d+\\.\\d+|\\d+)>(?<segment>[^<]*)"
        ) else {
            return (content.removeMatches("<[^>]*>"), [])
        }

        var rawText = ""
        var words: [LrcRedTimedWord] = []

        for match in regex.matches(in: content, range: content.range) {
            var captures: [String: String] = [:]

            for name in ["minute", "seconds", "segment"] {
                let matchRange = match.range(withName: name)

                if let substringRange = Range(matchRange, in: content) {
                    captures[name] = String(content[substringRange])
                }
            }

            guard let minute = captures["minute"].flatMap(Int.init),
                  let seconds = captures["seconds"].flatMap(Float.init),
                  let segment = captures["segment"] else {
                continue
            }

            rawText += segment

            let wordText = segment.trimmingCharacters(in: .whitespaces)
            if !wordText.isEmpty {
                words.append(LrcRedTimedWord(
                    text: wordText,
                    startMs: minute * 60 * 1000 + Int(seconds * 1000)
                ))
            }
        }

        if words.isEmpty {
            // Tags present but none of them were word timings.
            return (content.removeMatches("<[^>]*>"), [])
        }

        return (rawText.trimmingCharacters(in: .whitespaces), words)
    }

    private func fetchLrcRedPlainLyrics(isrc: String, track: LrcRedTrackResponse) throws -> LyricsDto {
        let ttmlUrl = track.files?.ttml ?? "\(Self.lrcRedBaseUrl)/s/\(isrc).ttml"
        let (data, statusCode) = try perform(ttmlUrl, session: lrcRedSession, logTag: "lrc.red")

        guard statusCode == 200 else {
            logHttpFailure(logTag: "lrc.red", statusCode: statusCode, context: "TTML for \(isrc)")
            throw LyricsError.noSuchSong
        }

        let parserDelegate = LrcRedTTMLParser()
        let xmlParser = XMLParser(data: data)
        xmlParser.delegate = parserDelegate

        guard xmlParser.parse(), !parserDelegate.lineEntries.isEmpty else {
            throw LyricsError.noSuchSong
        }

        let texts = parserDelegate.lineEntries.map(\.text)

        var dto = LyricsDto(
            lines: texts.map { LyricsLineDto(content: $0) },
            timeSynced: false,
            romanization: texts.canBeRomanized ? .canBeRomanized : .original,
            providerCredit: "lrc.red"
        )

        // The plain lines come from this very document, so a translation
        // keyed to the same lines aligns exactly — the parser only
        // returns one when every line's key resolves (see its comment).
        dto.translation = parserDelegate.translation(matchingLineKeys: parserDelegate.lineEntries.map(\.key))

        return dto
    }

    // MARK: - Stage 2: LiriQo

    /// Cache-fronted stage 2 entry point. A cached hit replays its DTOs
    /// (including the karaoke store handoff) without any network request;
    /// a cached miss rethrows `noSuchSong` so callers keep their existing
    /// fallback behaviour. Successes and definitive "no lyrics" outcomes
    /// are stored, so such a track is never asked about twice in a
    /// session — but transient failures (rate limit, server error,
    /// network error, undecodable body) are NOT stored: recording them
    /// as misses would pin a momentary failure as "no lyrics" until the
    /// app restarts.
    private func getLiriQoLyrics(_ query: LyricsSearchQuery, options: LyricsOptions) throws -> LyricsDto {
        let cacheKey = liriQoCacheKey(for: query, options: options)

        if let entry = cachedLiriQoEntry(for: cacheKey) {
            switch entry {
            case .hit(let dto, let karaoke):
                writeDebugLog("[LiriQo] Session cache hit for \(query.title)/\(query.primaryArtist)")

                if let karaoke {
                    KaraokeLyricsStore.shared.set(trackId: query.spotifyTrackId, lyrics: karaoke)
                }

                return dto
            case .miss:
                writeDebugLog("[LiriQo] Session cache hit (no lyrics) for \(query.title)/\(query.primaryArtist)")
                throw LyricsError.noSuchSong
            }
        }

        do {
            let (dto, karaoke) = try fetchLiriQoLyrics(query, options: options)
            storeLiriQoEntry(.hit(dto: dto, karaoke: karaoke), for: cacheKey)

            if let karaoke {
                KaraokeLyricsStore.shared.set(trackId: query.spotifyTrackId, lyrics: karaoke)
            }

            return dto
        } catch {
            // Only a definitive "no lyrics" may be remembered. Anything
            // else (LiriQoTransientError, URLError, decodingError, ...)
            // leaves no trace, so the next play asks again.
            if (error as? LyricsError) == .noSuchSong {
                storeLiriQoEntry(.miss, for: cacheKey)
            } else {
                writeDebugLog("[LiriQo] Transient failure for \(query.title)/\(query.primaryArtist), not caching: \(error)")
            }

            throw error
        }
    }

    /// The Spotify track ID is the stable identity; fall back to the
    /// normalized title/artist pair when a query carries none. The
    /// romanization flag is part of the key because a fetch with it on
    /// can return romanized line text (see fetchLiriQoLyrics) — replaying
    /// that for a romanization-off request, or vice versa, would be wrong.
    private func liriQoCacheKey(for query: LyricsSearchQuery, options: LyricsOptions) -> String {
        let base: String

        if !query.spotifyTrackId.isEmpty {
            base = "id:\(query.spotifyTrackId)"
        } else {
            base = "meta:\(normalizedForMatch(query.title))|\(normalizedForMatch(query.primaryArtist))"
        }

        return options.romanization ? base + "#rom" : base
    }

    private func cachedLiriQoEntry(for key: String) -> LiriQoCacheEntry? {
        liriQoCacheLock.lock()
        defer { liriQoCacheLock.unlock() }

        guard let entry = liriQoCache[key] else {
            return nil
        }

        // Refresh recency so replayed tracks survive eviction.
        liriQoCacheOrder.removeAll { $0 == key }
        liriQoCacheOrder.append(key)

        return entry
    }

    private func storeLiriQoEntry(_ entry: LiriQoCacheEntry, for key: String) {
        liriQoCacheLock.lock()
        defer { liriQoCacheLock.unlock() }

        liriQoCache[key] = entry
        liriQoCacheOrder.removeAll { $0 == key }
        liriQoCacheOrder.append(key)

        while liriQoCacheOrder.count > Self.liriQoCacheCapacity {
            liriQoCache[liriQoCacheOrder.removeFirst()] = nil
        }
    }

    private func fetchLiriQoLyrics(_ query: LyricsSearchQuery, options: LyricsOptions) throws -> (dto: LyricsDto, karaoke: KaraokeLyricsDto?) {
        let queryString = ([
            "title": query.title,
            "artist": query.primaryArtist
        ] as [String: String]).queryString

        let (data, statusCode) = try perform(
            "\(Self.liriQoBaseUrl)/lyrics?\(queryString)",
            session: liriQoSession,
            logTag: "LiriQo"
        )

        guard statusCode == 200 else {
            logHttpFailure(logTag: "LiriQo", statusCode: statusCode, context: "Lyrics for \(query.title)/\(query.primaryArtist)")

            // A rate limit or a server-side failure may clear by the next
            // play, so it must not be remembered as "no lyrics" (the
            // session cache only stores noSuchSong — see getLiriQoLyrics).
            // A 404 means the aggregator has nothing for this query, and
            // other 4xx would repeat identically: both are definitive.
            if statusCode == 429 || statusCode >= 500 {
                throw LiriQoTransientError.transient
            }

            throw LyricsError.noSuchSong
        }

        let response: LiriQoLyricsResponse
        do {
            response = try JSONDecoder().decode(LiriQoLyricsResponse.self, from: data)
        } catch {
            let body = String(data: data, encoding: .utf8) ?? "<non-utf8>"
            writeDebugLog("[LiriQo] Decode error for \(query.title)/\(query.primaryArtist): \(error). Body: \(body.prefix(300))")
            throw LyricsError.decodingError
        }

        // LiriQo reports some failures as HTTP 200 with an error field.
        // Its wording does not say whether the failure is definitive, so
        // treat it as transient: the worst case is one repeated request
        // on the next play, never a session-long false "no lyrics".
        if let errorMessage = response.error, !errorMessage.isEmpty {
            writeDebugLog("[LiriQo] API error for \(query.title)/\(query.primaryArtist): \(errorMessage)")
            throw LiriQoTransientError.transient
        }

        if let count = response.count, count == 0 {
            throw LyricsError.noSuchSong
        }

        // Pick the best usable candidate (primary is normally also in
        // tracks, and stays first in the list so it wins ties).
        let candidates = [response.primary].compactMap { $0 } + (response.tracks ?? [])

        guard let track = bestLiriQoTrack(candidates, query: query) else {
            throw LyricsError.noSuchSong
        }

        let providerCredit: String
        if let upstreamProvider = track.upstreamProvider, !upstreamProvider.isEmpty {
            providerCredit = "LiriQo (\(upstreamProvider))"
        } else if let provider = track.provider, !provider.isEmpty {
            providerCredit = "LiriQo (\(provider))"
        } else {
            providerCredit = "LiriQo"
        }

        if let timed = track.timed, !timed.isEmpty {
            // Upstream timing is not trustworthy as-is (zero-filled
            // starts, null ends, out-of-order lines have all been
            // observed), so everything below works on normalized lines.
            let entries = normalizeTimedLines(timed)

            guard !entries.isEmpty else {
                throw LyricsError.noSuchSong
            }

            var lines: [LyricsLineDto] = []
            var karaokeLines: [KaraokeLineDto] = []
            let hasWordTimedLines = entries.contains { !$0.words.isEmpty }

            for entry in entries {
                lines.append(LyricsLineDto(
                    content: entry.text.lyricsNoteIfEmpty,
                    offsetMs: entry.startMs
                ))

                if !entry.words.isEmpty, !entry.text.isEmpty {
                    let syllables = entry.words.map {
                        KaraokeSyllableDto(
                            text: $0.text,
                            startMs: $0.startMs,
                            endMs: $0.endMs,
                            isPartOfWord: false
                        )
                    }

                    karaokeLines.append(KaraokeLineDto(
                        syllables: syllables,
                        startMs: entry.startMs,
                        endMs: max(entry.endMs, syllables.last?.endMs ?? entry.endMs)
                    ))
                } else if hasWordTimedLines, !entry.text.isEmpty {
                    // Wordless line inside a word-synced track (an
                    // instrumental break, a backing line): publishing
                    // karaoke without it would leave a hole in the custom
                    // lyrics view, and CustomLyrics' line-synced fill
                    // skips tracks that already have an entry. Fill it
                    // SpicyLyrics Line-style — every word lights up at the
                    // line's start. Pure line tracks publish no karaoke
                    // here at all and keep using that shared fill.
                    let pseudoSyllables = entry.text
                        .split(whereSeparator: { $0.isWhitespace })
                        .map {
                            KaraokeSyllableDto(
                                text: String($0),
                                startMs: entry.startMs,
                                endMs: entry.startMs,
                                isPartOfWord: false
                            )
                        }

                    if !pseudoSyllables.isEmpty {
                        karaokeLines.append(KaraokeLineDto(
                            syllables: pseudoSyllables,
                            startMs: entry.startMs,
                            endMs: entry.endMs
                        ))
                    }
                }
            }

            var dto = LyricsDto(
                lines: lines,
                timeSynced: true,
                romanization: lines.map(\.content).canBeRomanized ? .canBeRomanized : .original,
                providerCredit: providerCredit
            )

            // Translation, when the payload carries one that aligns with
            // certainty: the track's TTML holds translations keyed by the
            // same line keys its timed lines carry (verified live with
            // YOASOBI "アイドル": 74/74 keys covered). A timestamped
            // `translation` string whose timestamps match the lines
            // exactly is the only other accepted form.
            if let ttml = track.ttml, !ttml.isEmpty {
                dto.translation = ttmlTranslation(from: ttml, lineKeys: entries.map(\.key))
            }

            if dto.translation == nil, let translationText = track.translation {
                dto.translation = translationFromTimedLrc(translationText, dtoLines: lines)
            }

            // Handed to the caller instead of the karaoke store directly,
            // so the result can be cached and replayed as-is.
            var karaoke = karaokeLines.isEmpty ? nil : KaraokeLyricsDto(
                lines: karaokeLines,
                songWriters: [],
                providerCode: track.provider,
                providerName: "LiriQo"
            )

            // A provider-supplied romanization replaces the line text
            // itself (the Genius Romanizations model), so the word
            // karaoke built from the original script no longer matches
            // the body and is dropped — CustomLyrics then rebuilds
            // line-style karaoke from the romanized lines.
            if options.romanization,
               let romanizationText = track.romanization,
               let romanized = romanizedDto(from: dto, romanizationText: romanizationText) {
                dto = romanized
                karaoke = nil
            }

            return (dto: dto, karaoke: karaoke)
        }

        // Tracks that carry only an `lrc` string: parse it into timed
        // lines when it has timestamps, plain lines otherwise.
        if let lrc = track.lrc, !lrc.isEmpty {
            let parsed = Self.parseLrc(lrc)

            if !parsed.timed.isEmpty {
                let lines = parsed.timed.map {
                    LyricsLineDto(content: $0.text.lyricsNoteIfEmpty, offsetMs: $0.startMs)
                }

                var dto = LyricsDto(
                    lines: lines,
                    timeSynced: true,
                    romanization: lines.map(\.content).canBeRomanized ? .canBeRomanized : .original,
                    providerCredit: providerCredit
                )

                if let translationText = track.translation {
                    dto.translation = translationFromTimedLrc(translationText, dtoLines: lines)
                }

                if options.romanization,
                   let romanizationText = track.romanization,
                   let romanized = romanizedDto(from: dto, romanizationText: romanizationText) {
                    dto = romanized
                }

                return (dto: dto, karaoke: nil)
            }

            if !parsed.plain.isEmpty {
                return (dto: LyricsDto(
                    lines: parsed.plain.map { LyricsLineDto(content: $0) },
                    timeSynced: false,
                    romanization: parsed.plain.canBeRomanized ? .canBeRomanized : .original,
                    providerCredit: providerCredit
                ), karaoke: nil)
            }
        }

        guard let plainLyrics = track.plain, !plainLyrics.isEmpty else {
            throw LyricsError.noSuchSong
        }

        let texts = plainLyrics.components(separatedBy: "\n")

        return (dto: LyricsDto(
            lines: texts.map { LyricsLineDto(content: $0) },
            timeSynced: false,
            romanization: texts.canBeRomanized ? .canBeRomanized : .original,
            providerCredit: providerCredit
        ), karaoke: nil)
    }

    /// One LiriQo timed line after normalization, with its TTML line key
    /// and word timings carried along.
    private struct NormalizedTimedLine {
        var text: String
        var startMs: Int
        var endMs: Int
        var key: String?
        var words: [(text: String, startMs: Int, endMs: Int)]
    }

    /// Makes LiriQo's timed data safe to build DTOs from. Upstream
    /// payloads arrive with zero-filled starts (one observed track had
    /// 24 lines all starting at 0), null ends and occasionally
    /// out-of-order lines; fed downstream as-is, that breaks the native
    /// view's seek/highlight assumptions. Following SpicyLyrics'
    /// normalizeMonotonicTiming: sort by start (stable, so equal starts
    /// keep their payload order), clamp line starts to be non-decreasing
    /// with every end at or after its start, then chain the syllables so
    /// no syllable starts before the previous one ends.
    private func normalizeTimedLines(_ timed: [LiriQoTimedLine]) -> [NormalizedTimedLine] {
        var entries: [NormalizedTimedLine] = []

        for line in timed {
            guard let text = line.text else { continue }

            let startMs = max(0, Int(line.start ?? 0))
            let endMs = Int(line.end ?? Double(startMs))

            let words = (line.words ?? []).compactMap { word -> (text: String, startMs: Int, endMs: Int)? in
                guard let wordText = word.text, !wordText.isEmpty else { return nil }

                let wordStartMs = Int(word.start ?? Double(startMs))

                return (text: wordText, startMs: wordStartMs, endMs: Int(word.end ?? Double(wordStartMs)))
            }

            entries.append(NormalizedTimedLine(
                text: text,
                startMs: startMs,
                endMs: endMs,
                key: line.key,
                words: words
            ))
        }

        entries.sort { $0.startMs < $1.startMs }

        var previousStartMs = Int.min
        for index in entries.indices {
            entries[index].startMs = max(entries[index].startMs, previousStartMs)
            entries[index].endMs = max(entries[index].endMs, entries[index].startMs)
            previousStartMs = entries[index].startMs
        }

        var previousSyllableEndMs = Int.min
        for lineIndex in entries.indices {
            for wordIndex in entries[lineIndex].words.indices {
                var word = entries[lineIndex].words[wordIndex]
                word.startMs = max(word.startMs, previousSyllableEndMs)
                word.endMs = max(word.endMs, word.startMs)
                previousSyllableEndMs = word.endMs
                entries[lineIndex].words[wordIndex] = word
            }
        }

        return entries
    }

    /// Extracts the translation embedded in a TTML document (the form
    /// Apple Music payloads carry), aligned by line key: the caller
    /// passes the key of every DTO line in order, and a translation is
    /// returned only when every key resolves — a partial or shifted
    /// translation is never attached.
    private func ttmlTranslation(from ttml: String, lineKeys: [String?]) -> LyricsTranslationDto? {
        let parserDelegate = LrcRedTTMLParser()
        let xmlParser = XMLParser(data: Data(ttml.utf8))
        xmlParser.delegate = parserDelegate

        guard xmlParser.parse() else {
            return nil
        }

        return parserDelegate.translation(matchingLineKeys: lineKeys)
    }

    /// Accepts a track's `translation` string only in its timestamped
    /// (LRC) form, and only when alignment is provable: same line count
    /// as the body, unique timestamps, and every body line's offset
    /// present among them. The plain-text form LiriQo currently serves
    /// for NetEase tracks fails this on real songs (米津玄師 "Lemon":
    /// 42 translation lines vs 43 body lines — the untranslated credit
    /// line is simply omitted), so it is not used. The language code is
    /// detected from the text itself rather than guessed.
    private func translationFromTimedLrc(_ translationText: String, dtoLines: [LyricsLineDto]) -> LyricsTranslationDto? {
        let parsed = Self.parseLrc(translationText)

        guard !parsed.timed.isEmpty, parsed.timed.count == dtoLines.count else {
            return nil
        }

        var textByTimestamp: [Int: String] = [:]

        for entry in parsed.timed {
            // A repeated timestamp would make the mapping ambiguous.
            guard textByTimestamp[entry.startMs] == nil else {
                return nil
            }

            textByTimestamp[entry.startMs] = entry.text
        }

        var lines: [String] = []

        for line in dtoLines {
            guard let offsetMs = line.offsetMs, let text = textByTimestamp[offsetMs] else {
                return nil
            }

            lines.append(text)
        }

        guard let languageCode = NSLinguisticTagger.dominantLanguage(for: lines.joined(separator: "\n")) else {
            return nil
        }

        return LyricsTranslationDto(languageCode: languageCode, lines: lines)
    }

    /// Adopts a provider-supplied romanization the way Genius adopts a
    /// "Genius Romanizations" entry: the romanized text becomes the line
    /// text and the DTO is marked `.romanized`. Only an exact line-count
    /// match is accepted — a romanization whose lines do not correspond
    /// one-to-one with the body is a crash risk (the original project's
    /// issue #452 was exactly that), so any mismatch keeps the local
    /// `.canBeRomanized` / `.original` judgement.
    private func romanizedDto(from dto: LyricsDto, romanizationText: String) -> LyricsDto? {
        let parsed = Self.parseLrc(romanizationText)

        let romanizedLines: [String]

        if !parsed.timed.isEmpty {
            // Timestamped form: pair lines by timestamp, not by
            // position, so the pairing is provable rather than assumed.
            // Duplicate timestamps would make it ambiguous — reject.
            var textByTimestamp: [Int: String] = [:]

            for entry in parsed.timed {
                guard textByTimestamp[entry.startMs] == nil else {
                    return nil
                }

                textByTimestamp[entry.startMs] = entry.text
            }

            guard textByTimestamp.count == dto.lines.count else {
                return nil
            }

            var lines: [String] = []

            for line in dto.lines {
                guard let offsetMs = line.offsetMs, let text = textByTimestamp[offsetMs] else {
                    return nil
                }

                lines.append(text)
            }

            romanizedLines = lines
        } else {
            romanizedLines = parsed.plain
        }

        guard romanizedLines.count == dto.lines.count else {
            return nil
        }

        var romanized = dto
        romanized.lines = zip(dto.lines, romanizedLines).map { line, text in
            var line = line
            line.content = text
            return line
        }
        romanized.romanization = .romanized

        return romanized
    }

    /// Picks the best usable LiriQo candidate. A normalized title+artist
    /// match beats a title-only match beats no match; at equal match
    /// quality, word sync beats line sync beats plain — judged from the
    /// payload itself (timed lines carrying word timings), not from the
    /// server's syncLevel label. Candidates are listed primary-first and
    /// earlier candidates win full ties, so the server's own choice still
    /// prevails whenever nothing outranks it.
    private func bestLiriQoTrack(_ candidates: [LiriQoTrack], query: LyricsSearchQuery) -> LiriQoTrack? {
        let usable = candidates.filter {
            ($0.timed?.isEmpty == false) || ($0.plain?.isEmpty == false)
                || ($0.lrc?.isEmpty == false)
        }

        let wantedTitle = normalizedForMatch(query.title)
        let wantedArtist = normalizedForMatch(query.primaryArtist)

        func rank(of track: LiriQoTrack, index: Int) -> (Int, Int, Int) {
            let titleMatches = normalizedForMatch(track.title ?? "") == wantedTitle
            let artistMatches = normalizedForMatch(track.artist ?? "") == wantedArtist
            let match = titleMatches && artistMatches ? 2 : (titleMatches ? 1 : 0)

            let sync: Int
            if let timed = track.timed, !timed.isEmpty {
                sync = timed.contains { $0.words?.isEmpty == false } ? 2 : 1
            } else if let lrc = track.lrc, !lrc.isEmpty, !Self.parseLrc(lrc).timed.isEmpty {
                sync = 1
            } else {
                sync = 0
            }

            return (match, sync, -index)
        }

        return usable.enumerated().max { lhs, rhs in
            rank(of: lhs.element, index: lhs.offset) < rank(of: rhs.element, index: rhs.offset)
        }?.element
    }

    /// Parses a raw LRC string into timed lines and plain lines. Metadata
    /// tags ([ti:], [ar:], [al:], [by:], [length:], …) are dropped, as are
    /// empty lines. A line with at least one [mm:ss.xx] timestamp counts
    /// as timed (first timestamp wins); any other text line is plain.
    static func parseLrc(_ lrc: String) -> (timed: [(startMs: Int, text: String)], plain: [String]) {
        var timed: [(startMs: Int, text: String)] = []
        var plain: [String] = []

        guard let timestampRegex = try? NSRegularExpression(
            pattern: "\\[(\\d+):(\\d+(?:\\.\\d+)?)\\]"
        ) else {
            return (timed, plain)
        }

        for rawLine in lrc.components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)

            guard !line.isEmpty else { continue }

            let matches = timestampRegex.matches(in: line, range: line.range)

            if let first = matches.first,
               let minuteRange = Range(first.range(at: 1), in: line),
               let secondsRange = Range(first.range(at: 2), in: line),
               let minute = Int(line[minuteRange]),
               let seconds = Double(line[secondsRange]) {
                let text = timestampRegex
                    .stringByReplacingMatches(in: line, range: line.range, withTemplate: "")
                    .trimmingCharacters(in: .whitespaces)

                if !text.isEmpty {
                    timed.append((startMs: minute * 60 * 1000 + Int(seconds * 1000), text: text))
                }

                continue
            }

            // Metadata tag line: [key:value] with a non-numeric key.
            if line.hasPrefix("["), line.contains(":") {
                continue
            }

            plain.append(line)
        }

        return (timed, plain)
    }
}

/// A LiriQo failure that may succeed on a later attempt (rate limit,
/// server error, or an API error field of unknown definiteness). Kept
/// distinct from `LyricsError.noSuchSong` — a definitive "no lyrics" —
/// because only the latter may be recorded in the session cache.
private enum LiriQoTransientError: Error {
    case transient
}

// MARK: - lrc.red response models

private struct LrcRedSearchResponse: Decodable {
    struct Hit: Decodable {
        var isrc: String?
        var title: String?
        var artist: String?
        var album: String?
        var duration: Double?
    }

    var hits: [Hit]?
    var next: String?
}

private struct LrcRedTrackResponse: Decodable {
    struct Files: Decodable {
        var ttml: String?
        var lrc: String?
        var lyricsfile: String?
    }

    var isrc: String?
    var title: String?
    var artist: String?
    var sync: String?
    var lines: Int?
    var songwriters: [String]?
    var files: Files?
}

private struct LrcRedTimedWord {
    var text: String
    var startMs: Int
}

/// Parses a TTML document of the shape lrc.red serves and LiriQo
/// embeds: every `<p>` is one lyric line (all character data inside it,
/// including nested `<span>` word elements, is concatenated), each
/// carrying a line key when the document provides one (`lrc:key`), and
/// the head can hold `<translations>` — `<text for="L1">` elements keyed
/// to those same line keys, grouped per language in `<translation>`
/// elements. Only the first translation language is collected.
private class LrcRedTTMLParser: NSObject, XMLParserDelegate {
    private(set) var lineEntries: [(key: String?, text: String)] = []

    private var insideParagraph = false
    private var currentLineText = ""
    private var currentLineKey: String?

    private var translationsDepth = 0
    private var translationLanguageCode: String?
    private var translationLinesByKey: [String: String] = [:]
    private var insideFirstTranslation = false
    private var firstTranslationEnded = false
    private var insideTranslationText = false
    private var currentTranslationKey: String?
    private var currentTranslationText = ""

    /// The collected translation, aligned to the given line keys in
    /// order — or nil unless a language was found and EVERY key
    /// resolves. Partial coverage is rejected outright: Spotify renders
    /// translation lines positionally against the body, so a gap would
    /// silently shift every line after it.
    func translation(matchingLineKeys keys: [String?]) -> LyricsTranslationDto? {
        guard let languageCode = translationLanguageCode, !translationLinesByKey.isEmpty else {
            return nil
        }

        var lines: [String] = []

        for key in keys {
            guard let key, let text = translationLinesByKey[key] else {
                return nil
            }

            lines.append(text)
        }

        return LyricsTranslationDto(languageCode: languageCode, lines: lines)
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        switch elementName {
        case "p":
            insideParagraph = true
            currentLineText = ""
            currentLineKey = attributeDict["lrc:key"]
                ?? attributeDict["itunes:key"]
                ?? attributeDict["key"]
                ?? attributeDict["xml:id"]
        case "translations":
            translationsDepth += 1
        case "translation":
            translationsDepth += 1

            if !firstTranslationEnded {
                insideFirstTranslation = true
                translationLanguageCode = attributeDict["xml:lang"]
            }
        case "text":
            if translationsDepth > 0, insideFirstTranslation, let key = attributeDict["for"] {
                insideTranslationText = true
                currentTranslationKey = key
                currentTranslationText = ""
            }
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if insideParagraph {
            currentLineText += string
        }

        if insideTranslationText {
            currentTranslationText += string
        }
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        switch elementName {
        case "p":
            let text = currentLineText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                lineEntries.append((key: currentLineKey, text: text))
            }
            insideParagraph = false
            currentLineText = ""
            currentLineKey = nil
        case "translations":
            translationsDepth = max(0, translationsDepth - 1)
        case "translation":
            translationsDepth = max(0, translationsDepth - 1)

            if insideFirstTranslation {
                insideFirstTranslation = false
                firstTranslationEnded = true
            }
        case "text":
            if insideTranslationText, let key = currentTranslationKey {
                translationLinesByKey[key] = currentTranslationText
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
            insideTranslationText = false
            currentTranslationKey = nil
            currentTranslationText = ""
        default:
            break
        }
    }
}

// MARK: - LiriQo response models

private struct LiriQoLyricsResponse: Decodable {
    var error: String?
    var count: Int?
    var primary: LiriQoTrack?
    var tracks: [LiriQoTrack]?
}

private struct LiriQoTrack: Decodable {
    var provider: String?
    var upstreamProvider: String?
    var syncLevel: String?
    var title: String?
    var artist: String?
    var plain: String?
    var timed: [LiriQoTimedLine]?
    /// Some providers (notably Apple Music via LiriQo) ship lyrics only as
    /// a raw LRC string instead of `plain`/`timed` — observed live with
    /// Koruru "Our Memories", whose primary track carries nothing else.
    var lrc: String?
    /// The source TTML document, when the upstream provides one (Apple
    /// Music does). Its embedded translations are keyed by the same line
    /// keys the `timed` lines carry, which is what makes them safely
    /// alignable — see ttmlTranslation(from:lineKeys:).
    var ttml: String?
    /// Provider-supplied translation text (NetEase's tlyric, via LiriQo).
    /// Observed live as untimed plain text whose line count differs from
    /// the body, which cannot be aligned safely; only a timestamped form
    /// is ever used — see translationFromTimedLrc(_:dtoLines:).
    var translation: String?
    /// Provider-supplied romanization text (e.g. a romalrc). Adopted
    /// only on an exact line-count match — see romanizedDto(from:...).
    var romanization: String?
}

private struct LiriQoTimedLine: Decodable {
    var text: String?
    // Times are absolute milliseconds. They arrive as integers, but are
    // decoded as Double so a fractional value from any upstream provider
    // cannot fail the whole response.
    var start: Double?
    var end: Double?
    var words: [LiriQoWord]?
    var isInstrumental: Bool?
    /// Line key ("L1", "L2", ...) matching the `for` attributes of the
    /// translations embedded in the track's TTML, when present.
    var key: String?
}

private struct LiriQoWord: Decodable {
    var text: String?
    var start: Double?
    var end: Double?
}

// MARK: - Helpers

private extension String {
    /// lrc.red search misses results when the query contains apostrophes,
    /// so queries are sent without them (both straight and typographic).
    var removingApostrophes: String {
        self
            .replacingOccurrences(of: "'", with: "")
            .replacingOccurrences(of: "\u{2018}", with: "")
            .replacingOccurrences(of: "\u{2019}", with: "")
            .replacingOccurrences(of: "`", with: "")
            .replacingOccurrences(of: "\u{00B4}", with: "")
    }
}
