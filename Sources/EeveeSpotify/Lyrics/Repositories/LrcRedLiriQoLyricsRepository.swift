import Foundation

/// Two-stage lyrics source combining lrc.red and LiriQo.
///
/// Stage 1 is lrc.red: a large, CDN-cached catalogue keyed by ISRC with
/// line- and word-synced lyrics, fast enough to hit on every track change.
/// Stage 2 is LiriQo, an aggregator over 11 providers (Apple Music,
/// Musixmatch, NetEase, PetitLyrics, LRCLIB, ...) that often has a song
/// when lrc.red does not — but it is slow (several seconds) and tightly
/// rate-limited, so it is only queried, once and without retries, when
/// stage 1 found nothing. If both stages fail, the error propagates and
/// the existing Genius fallback in CustomLyrics takes over as the final
/// fallback.
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

    // MARK: - LyricsRepository

    func getLyrics(_ query: LyricsSearchQuery, options: LyricsOptions) throws -> LyricsDto {
        do {
            let dto = try getLrcRedLyrics(query)
            if !dto.lines.isEmpty {
                return dto
            }
            writeDebugLog("[lrc.red+LiriQo] lrc.red returned no lines for \(query.title)/\(query.primaryArtist), trying LiriQo")
        } catch {
            writeDebugLog("[lrc.red+LiriQo] lrc.red failed for \(query.title)/\(query.primaryArtist): \(error), trying LiriQo")
        }

        return try getLiriQoLyrics(query)
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
        // lrc.red search fails on queries containing apostrophes
        // (observed by other integrators), so strip them beforehand.
        let searchText = "\(query.title) \(query.primaryArtist)".removingApostrophes
        let stringUrl = "\(Self.lrcRedBaseUrl)/search.json?\((["q": searchText]).queryString)"

        let (data, statusCode) = try perform(stringUrl, session: lrcRedSession, logTag: "lrc.red")

        guard statusCode == 200 else {
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

        guard let hits = response.hits, !hits.isEmpty else {
            throw LyricsError.noSuchSong
        }

        let hit = bestLrcRedHit(hits, query: query) ?? hits[0]

        guard let isrc = hit.isrc, !isrc.isEmpty else {
            throw LyricsError.noSuchSong
        }

        return isrc
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

        guard statusCode == 200, let lrcText = String(data: data, encoding: .utf8) else {
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

        for (index, timedLine) in timedLines.enumerated() {
            lines.append(LyricsLineDto(
                content: timedLine.text.lyricsNoteIfEmpty,
                offsetMs: timedLine.startMs
            ))

            guard !timedLine.words.isEmpty else { continue }

            let lineEndMs = index + 1 < timedLines.count
                ? timedLines[index + 1].startMs
                : timedLine.startMs + 4000

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
            throw LyricsError.noSuchSong
        }

        let parserDelegate = LrcRedTTMLPlainParser()
        let xmlParser = XMLParser(data: data)
        xmlParser.delegate = parserDelegate

        guard xmlParser.parse(), !parserDelegate.lines.isEmpty else {
            throw LyricsError.noSuchSong
        }

        let texts = parserDelegate.lines

        return LyricsDto(
            lines: texts.map { LyricsLineDto(content: $0) },
            timeSynced: false,
            romanization: texts.canBeRomanized ? .canBeRomanized : .original,
            providerCredit: "lrc.red"
        )
    }

    // MARK: - Stage 2: LiriQo

    private func getLiriQoLyrics(_ query: LyricsSearchQuery) throws -> LyricsDto {
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
            writeDebugLog("[LiriQo] HTTP \(statusCode) for \(query.title)/\(query.primaryArtist)")
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
        if let errorMessage = response.error, !errorMessage.isEmpty {
            writeDebugLog("[LiriQo] API error for \(query.title)/\(query.primaryArtist): \(errorMessage)")
            throw LyricsError.noSuchSong
        }

        if let count = response.count, count == 0 {
            throw LyricsError.noSuchSong
        }

        // Prefer the primary track; fall back to the first candidate that
        // actually carries lyrics (primary is normally also in tracks).
        let candidates = [response.primary].compactMap { $0 } + (response.tracks ?? [])

        guard let track = candidates.first(where: {
            ($0.timed?.isEmpty == false) || ($0.plain?.isEmpty == false)
        }) else {
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
            var lines: [LyricsLineDto] = []
            var karaokeLines: [KaraokeLineDto] = []

            for timedLine in timed {
                guard let text = timedLine.text else { continue }

                let startMs = Int(timedLine.start ?? 0)
                let endMs = Int(timedLine.end ?? Double(startMs))

                lines.append(LyricsLineDto(
                    content: text.lyricsNoteIfEmpty,
                    offsetMs: startMs
                ))

                guard let words = timedLine.words, !words.isEmpty, !text.isEmpty else { continue }

                let syllables = words.compactMap { word -> KaraokeSyllableDto? in
                    guard let wordText = word.text, !wordText.isEmpty else { return nil }

                    let wordStartMs = Int(word.start ?? Double(startMs))

                    return KaraokeSyllableDto(
                        text: wordText,
                        startMs: wordStartMs,
                        endMs: Int(word.end ?? Double(wordStartMs)),
                        isPartOfWord: false
                    )
                }

                if !syllables.isEmpty {
                    karaokeLines.append(KaraokeLineDto(
                        syllables: syllables,
                        startMs: startMs,
                        endMs: endMs
                    ))
                }
            }

            guard !lines.isEmpty else {
                throw LyricsError.noSuchSong
            }

            if !karaokeLines.isEmpty {
                KaraokeLyricsStore.shared.set(
                    trackId: query.spotifyTrackId,
                    lyrics: KaraokeLyricsDto(
                        lines: karaokeLines,
                        songWriters: [],
                        providerCode: track.provider,
                        providerName: "LiriQo"
                    )
                )
            }

            return LyricsDto(
                lines: lines,
                timeSynced: true,
                romanization: lines.map(\.content).canBeRomanized ? .canBeRomanized : .original,
                providerCredit: providerCredit
            )
        }

        guard let plainLyrics = track.plain, !plainLyrics.isEmpty else {
            throw LyricsError.noSuchSong
        }

        let texts = plainLyrics.components(separatedBy: "\n")

        return LyricsDto(
            lines: texts.map { LyricsLineDto(content: $0) },
            timeSynced: false,
            romanization: texts.canBeRomanized ? .canBeRomanized : .original,
            providerCredit: providerCredit
        )
    }
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

/// Extracts plain lyric lines from an lrc.red TTML document: every `<p>`
/// is one line, and all character data inside it (including nested
/// `<span>` word elements) is concatenated.
private class LrcRedTTMLPlainParser: NSObject, XMLParserDelegate {
    private(set) var lines: [String] = []

    private var insideParagraph = false
    private var currentLineText = ""

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        if elementName == "p" {
            insideParagraph = true
            currentLineText = ""
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if insideParagraph {
            currentLineText += string
        }
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        if elementName == "p" {
            let text = currentLineText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                lines.append(text)
            }
            insideParagraph = false
            currentLineText = ""
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
    var plain: String?
    var timed: [LiriQoTimedLine]?
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
