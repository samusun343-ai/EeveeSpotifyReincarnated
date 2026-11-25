import Foundation

/// Three-stage lyrics source combining lrc.red, LRCLIB and LiriQo.
///
/// Stage 1 is lrc.red: a large, CDN-cached catalogue keyed by ISRC with
/// line- and word-synced lyrics, fast enough to hit on every track change.
/// Stage 2 is LRCLIB: also fast (about a second), with a large community
/// catalogue that often has synced lyrics where lrc.red has only plain
/// text or nothing at all — it upgrades Koruru's "Our Memories" from
/// plain to line-synced and has Elijah N's "Stick Together", which
/// lrc.red does not carry. Stage 3 is LiriQo, an aggregator over 11
/// providers (Apple Music, Musixmatch, NetEase, PetitLyrics, LRCLIB,
/// ...) that often has a song when both earlier stages do not — but it
/// is slow (several seconds) and tightly rate-limited, so it is only
/// queried, once and without retries, after both earlier stages.
///
/// The traversal is coverage-first: a synced result from any stage
/// ends the chain at once, and later stages are only asked while every
/// earlier stage missed or produced untimed (plain) text. Plain
/// results are kept as a floor and compete with each other — the one
/// with the most lines wins, ties keep the earlier stage's — so a
/// failure in a later stage never loses lyrics an earlier stage had.
/// LiriQo outcomes are cached in memory for the session (LRU, 100
/// entries) so repeat plays never re-ask — but only definitive
/// outcomes are cached: a 429, a server error or a network failure is
/// never recorded as a miss, so a rate-limited track is asked about
/// again on the next play instead of staying lyric-less for the whole
/// session. If all stages fail, the error propagates and the existing
/// Genius fallback in CustomLyrics takes over as the final fallback.
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

    private static let userAgent = "EeveeSpotifyReincarnated v\(EeveeSpotify.version) (+https://github.com/samusun343-ai/EeveeSpotifyReincarnated; contact: https://github.com/samusun343-ai/EeveeSpotifyReincarnated/issues)"
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
        // Bounded wait (audit P4): the bound is the session's own
        // configured request timeout (lrc.red 10s, LiriQo 30s — LiriQo
        // normally answers in ~6s and its session was deliberately
        // given room), so any response the session would deliver still
        // arrives; only a completion that never fires is cut, and the
        // no-data path below throws, which the stage logic treats as a
        // transient failure (floor kept, next stage tried, never cached
        // as a miss).
        let waitTimeout: TimeInterval = session === liriQoSession ? 30 : 10
        if semaphore.wait(timeout: .now() + waitTimeout) == .timedOut {
            task.cancel()
        }

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
        // The best untimed (plain) result so far. A synced result from
        // any stage returns at once; plain text only ever competes with
        // plain text from later stages (see betterPlainFloor), and a
        // stage that fails or finds nothing leaves the floor untouched.
        var plainFloor: LyricsDto?

        // Stage 1: lrc.red
        do {
            let dto = try getLrcRedLyrics(query)

            if dto.timeSynced, !dto.lines.isEmpty {
                return dto
            }

            if !dto.lines.isEmpty {
                plainFloor = dto
                writeDebugLog("[lrc.red+LRCLIB+LiriQo] lrc.red returned plain-only lyrics for \(query.title)/\(query.primaryArtist), trying LRCLIB")
            } else {
                writeDebugLog("[lrc.red+LRCLIB+LiriQo] lrc.red returned no lines for \(query.title)/\(query.primaryArtist), trying LRCLIB")
            }
        } catch {
            writeDebugLog("[lrc.red+LRCLIB+LiriQo] lrc.red failed for \(query.title)/\(query.primaryArtist): \(error), trying LRCLIB")
        }

        // Stage 2: LRCLIB
        do {
            let dto = try getLrclibStageLyrics(query)

            if dto.timeSynced, !dto.lines.isEmpty {
                return dto
            }

            if !dto.lines.isEmpty {
                plainFloor = plainFloor.map { betterPlainFloor($0, dto) } ?? dto
                writeDebugLog("[lrc.red+LRCLIB+LiriQo] LRCLIB returned plain-only lyrics for \(query.title)/\(query.primaryArtist), trying LiriQo")
            } else {
                writeDebugLog("[lrc.red+LRCLIB+LiriQo] LRCLIB returned no lines for \(query.title)/\(query.primaryArtist), trying LiriQo")
            }
        } catch {
            writeDebugLog("[lrc.red+LRCLIB+LiriQo] LRCLIB failed for \(query.title)/\(query.primaryArtist): \(error), trying LiriQo")
        }

        // Stage 3: LiriQo
        do {
            let dto = try getLiriQoLyrics(query, options: options)

            if dto.timeSynced, !dto.lines.isEmpty {
                return dto
            }

            if !dto.lines.isEmpty {
                return plainFloor.map { betterPlainFloor($0, dto) } ?? dto
            }

            // LiriQo answered but had nothing usable (e.g. an
            // instrumental record): an earlier stage's plain text, if
            // any, is still the best available answer.
            if let plainFloor {
                return plainFloor
            }

            return dto
        } catch {
            if let plainFloor {
                return plainFloor
            }

            throw error
        }
    }

    /// Plain (untimed) results compete on completeness only: the one
    /// with more lines wins, and a tie keeps the current floor — stage
    /// order is the priority order, so a later stage must be strictly
    /// fuller to displace an earlier stage's text.
    private func betterPlainFloor(_ current: LyricsDto, _ candidate: LyricsDto) -> LyricsDto {
        candidate.lines.count > current.lines.count ? candidate : current
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

        var dto = LyricsDto(
            lines: lines,
            timeSynced: true,
            romanization: lines.map(\.content).canBeRomanized ? .canBeRomanized : .original,
            providerCredit: "lrc.red"
        )

        // The synced DTO is built from the .lrc file, but the track's
        // TTML can carry a translation keyed by line — the same
        // document the plain path reads. Attach it under the strict
        // gate in lrcRedSyncedTranslation; any doubt leaves the DTO
        // untranslated rather than risking a shifted translation.
        if dto.translation == nil {
            dto.translation = lrcRedSyncedTranslation(
                isrc: isrc,
                track: track,
                lineTexts: timedLines.map(\.text)
            )
        }

        return dto
    }

    /// Fetches the track's TTML once more on the synced path and
    /// extracts its embedded translation, but only when alignment
    /// with the DTO built from the .lrc file is exact: the TTML's
    /// line texts must equal the DTO's line texts in count and in
    /// every position. The translation itself is then keyed by line
    /// through the parser, which additionally requires every key to
    /// resolve. Any failure — fetch, parse, count or text mismatch,
    /// missing keys — returns nil; a missing or shifted translation
    /// must never fail or corrupt a synced result that already works.
    private func lrcRedSyncedTranslation(
        isrc: String,
        track: LrcRedTrackResponse,
        lineTexts: [String]
    ) -> LyricsTranslationDto? {
        let ttmlUrl = track.files?.ttml ?? "\(Self.lrcRedBaseUrl)/s/\(isrc).ttml"

        let data: Data

        do {
            let (fetchedData, statusCode) = try perform(ttmlUrl, session: lrcRedSession, logTag: "lrc.red")

            guard statusCode == 200 else {
                logHttpFailure(logTag: "lrc.red", statusCode: statusCode, context: "TTML (synced translation) for \(isrc)")
                return nil
            }

            data = fetchedData
        } catch {
            writeDebugLog("[lrc.red] TTML fetch for synced translation of \(isrc) failed: \(error)")
            return nil
        }

        let parserDelegate = LrcRedTTMLParser()
        let xmlParser = XMLParser(data: data)
        xmlParser.delegate = parserDelegate

        guard xmlParser.parse() else {
            return nil
        }

        let entries = parserDelegate.lineEntries

        guard entries.count == lineTexts.count else {
            writeDebugLog("[lrc.red] Synced translation for \(isrc) rejected: TTML has \(entries.count) lines, DTO has \(lineTexts.count)")
            return nil
        }

        for (entry, lineText) in zip(entries, lineTexts) {
            guard entry.text == lineText else {
                writeDebugLog("[lrc.red] Synced translation for \(isrc) rejected: TTML line text differs from the synced lyrics")
                return nil
            }
        }

        return parserDelegate.translation(matchingLineKeys: entries.map(\.key))
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

    // MARK: - Stage 2: LRCLIB

    /// Stage 2 fetches through the standalone LRCLIB source's machinery
    /// (`LrclibLyricsRepository.getRecord`), so this stage inherits its
    /// custom-URL setting, IPv4-direct connection and TLS handling, and
    /// asks exactly the same two title forms it asks. The DTO is built
    /// here rather than by the standalone source because the record
    /// carries word timings (the Lyricsfile) that its flattened DTO
    /// drops — this stage publishes them to the karaoke store itself,
    /// the way stage 1 does, and credits LRCLIB on the DTO.
    private func getLrclibStageLyrics(_ query: LyricsSearchQuery) throws -> LyricsDto {
        let song = try LrclibLyricsRepository.shared.getRecord(query)

        if song.instrumental {
            return LyricsDto(
                lines: [],
                timeSynced: false,
                romanization: .original,
                providerCredit: "LRCLIB"
            )
        }

        if let syncedLyrics = song.syncedLyrics, !syncedLyrics.isEmpty {
            var timedLines: [(startMs: Int, text: String)] = []

            for rawLine in syncedLyrics.components(separatedBy: "\n") {
                let line = rawLine.trimmingCharacters(in: .whitespaces)

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

                timedLines.append((
                    startMs: minute * 60 * 1000 + Int(seconds * 1000),
                    text: content.trimmingCharacters(in: .whitespaces)
                ))
            }

            if !timedLines.isEmpty {
                let lines = timedLines.map {
                    LyricsLineDto(content: $0.text.lyricsNoteIfEmpty, offsetMs: $0.startMs)
                }

                // Word timings, when the record carries them, are
                // published to the karaoke store directly — the shared
                // line-synced fill in CustomLyrics then skips this
                // track, exactly as with stage 1's word tracks.
                if song.hasWordSync == true,
                   let lyricsfile = song.lyricsfile,
                   let karaoke = lrclibKaraoke(fromLyricsfile: lyricsfile, timedLines: timedLines) {
                    KaraokeLyricsStore.shared.set(
                        trackId: query.spotifyTrackId,
                        lyrics: karaoke
                    )
                }

                return LyricsDto(
                    lines: lines,
                    timeSynced: true,
                    romanization: lines.map(\.content).canBeRomanized ? .canBeRomanized : .original,
                    providerCredit: "LRCLIB"
                )
            }
        }

        guard let plainLyrics = song.plainLyrics, !plainLyrics.isEmpty else {
            throw LyricsError.noSuchSong
        }

        var texts = plainLyrics.components(separatedBy: "\n")

        if texts.last?.isEmpty == true {
            texts.removeLast()
        }

        return LyricsDto(
            lines: texts.map { LyricsLineDto(content: $0) },
            timeSynced: false,
            romanization: texts.canBeRomanized ? .canBeRomanized : .original,
            providerCredit: "LRCLIB"
        )
    }

    /// Line text reduced to its comparison form for Lyricsfile
    /// alignment: trimmed, lowercased, whitespace runs collapsed.
    private func normalizedLineText(_ text: String) -> String {
        text
            .lowercased()
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
    }

    /// Builds word karaoke from a record's Lyricsfile, aligned to the
    /// synced-LRC lines the DTO carries. The two are separate records
    /// LRCLIB merged into one entry, and measured samples show they
    /// routinely diverge: extra or missing lines on either side
    /// (intros, chorus repeats) and occasional wording variants
    /// ("You're so fuckin' special" vs "So fucking special"). A strict
    /// index-by-index match fired on only 1 of 5 measured word-synced
    /// records, so lines are instead paired sequentially — in order,
    /// by normalized text, skipping lines only one side has — and the
    /// pairing is adopted only when at least half of the LRC lines
    /// found a partner. A pair requires exact normalized-text
    /// equality, so a paired line's words always belong to that line's
    /// text; unpaired LRC lines are pseudo-filled line-style, the way
    /// the other stages fill wordless lines.
    ///
    /// The file's timings also disagree with the LRC's by a fraction
    /// of a second (Creep, line 1: file 19,980ms vs LRC 19,160ms), so
    /// each line's words are re-anchored to the LRC line's start —
    /// the DTO lines are what the native view seeks by, and the
    /// karaoke must agree with them. A word ends where the next word
    /// starts; the last word of a line ends at the line's end, the
    /// same convention stage 1 uses.
    private func lrclibKaraoke(
        fromLyricsfile yaml: String,
        timedLines: [(startMs: Int, text: String)]
    ) -> KaraokeLyricsDto? {
        let fileLines = parseLyricsfile(yaml)

        guard !fileLines.isEmpty, fileLines.contains(where: { !$0.words.isEmpty }) else {
            return nil
        }

        // Sequential pairing: timedLine index -> fileLine index.
        var pairs: [Int: Int] = [:]
        var timedIndex = 0
        var fileIndex = 0

        while timedIndex < timedLines.count, fileIndex < fileLines.count {
            let timedText = normalizedLineText(timedLines[timedIndex].text)
            let fileText = normalizedLineText(fileLines[fileIndex].text)

            if timedText == fileText {
                pairs[timedIndex] = fileIndex
                timedIndex += 1
                fileIndex += 1
            } else if timedIndex + 1 < timedLines.count,
                      normalizedLineText(timedLines[timedIndex + 1].text) == fileText {
                // A line only the LRC has (an extra intro, a repeat).
                timedIndex += 1
            } else if fileIndex + 1 < fileLines.count,
                      timedText == normalizedLineText(fileLines[fileIndex + 1].text) {
                // A line only the file has.
                fileIndex += 1
            } else {
                // A wording variant on both sides: leave both
                // unpaired and move on.
                timedIndex += 1
                fileIndex += 1
            }
        }

        guard pairs.count * 2 >= timedLines.count else {
            return nil
        }

        var karaokeLines: [KaraokeLineDto] = []

        for (index, timedLine) in timedLines.enumerated() {
            let lineStartMs = timedLine.startMs
            let lineEndMs = index + 1 < timedLines.count
                ? timedLines[index + 1].startMs
                : lineStartMs + 4000

            if let pairedIndex = pairs[index], !fileLines[pairedIndex].words.isEmpty, !timedLine.text.isEmpty {
                let fileLine = fileLines[pairedIndex]
                let anchorMs = fileLine.words[0].startMs
                let shiftMs = lineStartMs - anchorMs

                var syllables: [KaraokeSyllableDto] = []

                for (wordIndex, word) in fileLine.words.enumerated() {
                    let text = word.text.trimmingCharacters(in: .whitespaces)

                    guard !text.isEmpty else { continue }

                    let wordStartMs = word.startMs + shiftMs
                    let wordEndMs = wordIndex + 1 < fileLine.words.count
                        ? fileLine.words[wordIndex + 1].startMs + shiftMs
                        : lineEndMs

                    syllables.append(KaraokeSyllableDto(
                        text: text,
                        startMs: wordStartMs,
                        endMs: max(wordEndMs, wordStartMs),
                        isPartOfWord: false
                    ))
                }

                if !syllables.isEmpty {
                    karaokeLines.append(KaraokeLineDto(
                        syllables: syllables,
                        startMs: lineStartMs,
                        endMs: lineEndMs
                    ))
                }
            } else if !timedLine.text.isEmpty {
                // Wordless line inside a word-synced track: fill it the
                // way the other stages fill theirs, so publishing word
                // karaoke leaves no hole in the custom lyrics view.
                let pseudoSyllables = timedLine.text
                    .split(whereSeparator: { $0.isWhitespace })
                    .map {
                        KaraokeSyllableDto(
                            text: String($0),
                            startMs: lineStartMs,
                            endMs: lineStartMs,
                            isPartOfWord: false
                        )
                    }

                if !pseudoSyllables.isEmpty {
                    karaokeLines.append(KaraokeLineDto(
                        syllables: pseudoSyllables,
                        startMs: lineStartMs,
                        endMs: lineEndMs
                    ))
                }
            }
        }

        guard !karaokeLines.isEmpty else {
            return nil
        }

        return KaraokeLyricsDto(
            lines: karaokeLines,
            songWriters: [],
            providerCode: nil,
            providerName: "LRCLIB"
        )
    }

    /// One line of a Lyricsfile, with its word start times.
    private struct LyricsfileLine {
        var text: String
        var startMs: Int
        var words: [(text: String, startMs: Int)] = []
    }

    /// A tolerant line-based parser for the Lyricsfile subset LRCLIB
    /// emits — a full YAML parser would be out of place here. Shape:
    /// a top-level `lines:` list whose entries start at column 0 with
    /// `- text:`, followed by indented `start_ms:`/`end_ms:` and a
    /// `words:` list of indented `- text:` entries, each with its own
    /// indented `start_ms:`. Words carry no end time. Scalars may be
    /// plain, single-quoted (with '' escaping an apostrophe), or
    /// double-quoted (backslash escapes).
    private func parseLyricsfile(_ yaml: String) -> [LyricsfileLine] {
        var lines: [LyricsfileLine] = []
        var inLinesList = false
        var inWords = false

        for rawLine in yaml.components(separatedBy: "\n") {
            if !inLinesList {
                if rawLine.trimmingCharacters(in: .whitespaces) == "lines:" {
                    inLinesList = true
                }
                continue
            }

            if rawLine.hasPrefix("- ") || rawLine.hasPrefix("-") && rawLine.count == 1 {
                // A column-0 dash starts a new lyric line entry.
                let body = rawLine.hasPrefix("- ") ? String(rawLine.dropFirst(2)) : ""

                guard body.hasPrefix("text:") else { continue }

                lines.append(LyricsfileLine(
                    text: yamlScalar(String(body.dropFirst("text:".count))),
                    startMs: 0
                ))
                inWords = false
                continue
            }

            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)

            if trimmed.hasPrefix("- ") {
                // An indented dash is a word entry of the current line.
                let body = String(trimmed.dropFirst(2))

                guard body.hasPrefix("text:"), !lines.isEmpty else { continue }

                lines[lines.count - 1].words.append((
                    text: yamlScalar(String(body.dropFirst("text:".count))),
                    startMs: 0
                ))
                continue
            }

            if trimmed == "words:" {
                inWords = true
                continue
            }

            if trimmed.hasPrefix("start_ms:"), !lines.isEmpty {
                let value = Int(trimmed.dropFirst("start_ms:".count)
                    .trimmingCharacters(in: .whitespaces)) ?? 0

                if inWords, !lines[lines.count - 1].words.isEmpty {
                    lines[lines.count - 1].words[lines[lines.count - 1].words.count - 1].startMs = value
                } else {
                    lines[lines.count - 1].startMs = value
                }
            }
        }

        return lines
    }

    /// Reads one YAML scalar: single-quoted (with '' for an embedded
    /// apostrophe), double-quoted (backslash escapes, including the
    /// \' form LRCLIB's generator emits), or plain. Whitespace
    /// outside the quotes is trimmed; whitespace inside them (a
    /// word's trailing space) is preserved.
    private func yamlScalar(_ raw: String) -> String {
        let value = raw.trimmingCharacters(in: .whitespaces)

        if value.hasPrefix("'"), value.hasSuffix("'"), value.count >= 2 {
            return String(value.dropFirst().dropLast())
                .replacingOccurrences(of: "''", with: "'")
        }

        if value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 {
            var result = ""
            var iterator = value.dropFirst().dropLast().makeIterator()
            var escaped = false

            while let character = iterator.next() {
                if escaped {
                    switch character {
                    case "n": result.append("\n")
                    case "t": result.append("\t")
                    default: result.append(character)
                    }
                    escaped = false
                } else if character == "\\" {
                    escaped = true
                } else {
                    result.append(character)
                }
            }

            if escaped {
                result.append("\\")
            }

            return result
        }

        return value
    }

    // MARK: - Stage 3: LiriQo

    /// Cache-fronted stage 3 entry point. A cached hit replays its DTOs
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
