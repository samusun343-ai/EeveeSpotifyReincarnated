import Orion
import SwiftUI
import MediaPlayer

struct BaseLyricsGroup: HookGroup { }

struct LegacyLyricsGroup: HookGroup { }
struct ModernLyricsGroup: HookGroup { }
struct V91LyricsGroup: HookGroup { }            // 9.1.x-safe subset
struct LyricsErrorHandlingGroup: HookGroup { }  // not activated on 9.1.x

var lyricsState = LyricsLoadingState()

// lyricsState is mutated by whichever fetch is running (a prefetch and a
// real fetch can overlap during rapid skipping) and read by the attributes
// UI. All access goes through this lock so the struct is never observed
// half-updated. Concurrent fetches can still replace each other's state,
// but always as a whole — last writer wins.
private let lyricsStateLock = NSLock()

func updateLyricsState(_ update: (inout LyricsLoadingState) -> Void) {
    lyricsStateLock.lock()
    update(&lyricsState)
    lyricsStateLock.unlock()
}

func currentLyricsState() -> LyricsLoadingState {
    lyricsStateLock.lock()
    defer { lyricsStateLock.unlock() }
    return lyricsState
}


private let geniusLyricsRepository = GeniusLyricsRepository()
private let petitLyricsRepository = PetitLyricsRepository()

// Overload for 9.1.6 where we only have track ID from URL
private func loadCustomLyricsForTrackId(_ trackId: String) throws -> Lyrics {

    var source = UserDefaults.lyricsSource

    var currentTitle: String? = nil
    var currentArtist: String? = nil
    var hasMetadata = false

    let needsMetadata = source == .genius || source == .lrclib || source == .petit

    // 1. Use cached metadata if it's for the same track
    if let captured = capturedTrackMetadata(for: trackId) {
        currentTitle = captured.title
        currentArtist = captured.artist
        hasMetadata = true
    }

    // 2. Try statefulPlayer (most reliable on modern Spotify)
    if !hasMetadata {
        if let player = statefulPlayer,
           let track = player.currentTrack() {
            let currentId = track.URI().spt_trackIdentifier()

            if currentId == trackId {
                currentTitle = track.trackTitle()
                currentArtist = track.artistName()
                hasMetadata = true
                storeCapturedTrackMetadata(trackId: trackId, title: currentTitle, artist: currentArtist)
            }
        }
    }

    // 3. MPNowPlayingInfoCenter — must be read on the main thread.
    // It always describes the playing track, so it must not be used for another track
    // (Spotify also loads lyrics for tracks that aren't playing yet).
    let nowPlayingIsThisTrack = KaraokePlaybackTracker.shared.playerReportedTrackId().map { $0 == trackId } ?? true
    if !hasMetadata && nowPlayingIsThisTrack {
        var npTitle: String? = nil
        var npArtist: String? = nil
        if Thread.isMainThread {
            npTitle = MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPMediaItemPropertyTitle] as? String
            npArtist = MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPMediaItemPropertyArtist] as? String
        } else {
            DispatchQueue.main.sync {
                npTitle = MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPMediaItemPropertyTitle] as? String
                npArtist = MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPMediaItemPropertyArtist] as? String
            }
        }
        if let title = npTitle, let artist = npArtist, !title.isEmpty, !artist.isEmpty {
            currentTitle = title
            currentArtist = artist
            hasMetadata = true
            storeCapturedTrackMetadata(trackId: trackId, title: title, artist: artist)
        }
    }

    // 4. Spotify Web API fallback using captured Bearer token
    if !hasMetadata, let token = spotifyAccessToken {
        if let info = fetchTrackDetails(trackId: trackId, token: token) {
            currentTitle = info.title
            currentArtist = info.artist
            hasMetadata = true
            storeCapturedTrackMetadata(trackId: trackId, title: currentTitle, artist: currentArtist)
        }
    }

    if needsMetadata && !hasMetadata {
        writeDebugLog("[Lyrics] \(trackId): no title/artist for \(source.description), cannot search")
        throw LyricsError.noSuchSong
    }

    let searchQuery = LyricsSearchQuery(
        title: currentTitle ?? "",
        primaryArtist: currentArtist ?? "",
        spotifyTrackId: trackId
    )
    
    let options = UserDefaults.lyricsOptions
    
    var repository: LyricsRepository

    switch source {
    case .genius:
        repository = geniusLyricsRepository
    case .lrclib:
        repository = LrclibLyricsRepository.shared
    case .lrcRedLiriQo:
        repository = LrcRedLiriQoLyricsRepository.shared
    case .petit:
        repository = petitLyricsRepository
    case .spicylyrics:
        repository = SpicyLyricsRepository.shared
    case .notReplaced:
        throw LyricsError.invalidSource
    }
    
    let lyricsDto: LyricsDto
    // Karaoke data the repository itself published while fetching (word-synced
    // sources), captured so the offline cache can store it with the DTO.
    var repositoryKaraoke: KaraokeLyricsDto?
    var servedFromOfflineCache = false

    updateLyricsState { $0 = LyricsLoadingState() }

    if let cached = LyricsOfflineCache.shared.cachedLyrics(for: searchQuery, source: source) {
        // Offline cache hit — no network fetch at all. Stored karaoke data is
        // republished exactly as the fresh fetch would have published it.
        servedFromOfflineCache = true
        lyricsDto = cached.dto

        KaraokeLyricsStore.shared.remove(trackId: searchQuery.spotifyTrackId)

        if let karaoke = cached.karaoke {
            KaraokeLyricsStore.shared.set(trackId: searchQuery.spotifyTrackId, lyrics: karaoke)
        }

        writeDebugLog("[Lyrics] \(trackId): offline cache hit, \(lyricsDto.lines.count) lines")
    } else {
        // A fresh fetch starts from nothing, so the custom lyrics button only shows
        // for lyrics this fetch actually produced.
        KaraokeLyricsStore.shared.remove(trackId: searchQuery.spotifyTrackId)
    
        do {
            lyricsDto = try repository.getLyrics(searchQuery, options: options)
        }
        catch let error {
            if let lyricsError = error as? LyricsError {
                updateLyricsState { $0.fallbackError = lyricsError }
            } else {
                updateLyricsState { $0.fallbackError = .unknownError }
            }

            // Attempt Genius fallback if enabled and the primary source isn't already Genius.
            // Genius requires title + artist to search — only attempt if we have them.
            let canFallbackToGenius = source != .genius
                && UserDefaults.lyricsOptions.geniusFallback
                && !(currentTitle ?? "").isEmpty
                && !(currentArtist ?? "").isEmpty
            if canFallbackToGenius {
                source = .genius
                lyricsDto = try geniusLyricsRepository.getLyrics(searchQuery, options: options)
            } else {
                throw error
            }
        }

        repositoryKaraoke = KaraokeLyricsStore.shared.lyrics(forTrackId: searchQuery.spotifyTrackId)
    }
    
    updateLyricsState {
        $0.isEmpty = lyricsDto.lines.isEmpty
        $0.wasRomanized = lyricsDto.romanization == .romanized
            || (lyricsDto.romanization == .canBeRomanized && UserDefaults.lyricsOptions.romanization)
        $0.loadedSuccessfully = true
    }

    writeDebugLog("[Lyrics] \(trackId): \(source.description), \(lyricsDto.lines.count) lines, synced=\(lyricsDto.timeSynced)")
    publishLineSyncedKaraokeLyrics(lyricsDto, trackId: searchQuery.spotifyTrackId, source: source)
    LyricsWidgetBridge.publish(
        trackId: searchQuery.spotifyTrackId,
        title: currentTitle,
        artist: currentArtist,
        dto: lyricsDto
    )

    // The user's timing correction applies to the native lyrics view only.
    // The karaoke overlay compensates on the playback-position side (see
    // KaraokeLyricsView), so the DTO handed to it above stays unshifted.
    let timingOffsetMs = UserDefaults.lyricsTimingOffsets.effectiveMs(forTrackId: searchQuery.spotifyTrackId)

    if !servedFromOfflineCache {
        LyricsOfflineCache.shared.store(
            dto: lyricsDto,
            karaoke: repositoryKaraoke,
            query: searchQuery,
            source: source
        )
    }

    let lyrics = Lyrics.with {
        $0.data = lyricsDto
            .applyingTimingOffset(timingOffsetMs)
            .toSpotifyLyricsData(source: source.description)
    }
    
    return lyrics
}

/// Feeds the custom lyrics view for sources that only have line-level timing.
/// Spicy Lyrics publishes its own (word/syllable) data while parsing, so an
/// existing entry for the track is never overwritten.
private func publishLineSyncedKaraokeLyrics(_ dto: LyricsDto, trackId: String, source: LyricsSource) {
    guard source.supportsCustomLyricsView, !trackId.isEmpty,
          KaraokeLyricsStore.shared.lyrics(forTrackId: trackId) == nil else { return }
    guard let karaoke = KaraokeLyricsDto.lineSynced(from: dto, providerName: source.description) else { return }
    KaraokeLyricsStore.shared.set(trackId: trackId, lyrics: karaoke)
}

private func loadCustomLyricsForCurrentTrack() throws -> Lyrics {
    
    guard
        let track = statefulPlayer?.currentTrack() ??
                    nowPlayingScrollViewController?.loadedTrack
        else {
            throw LyricsError.noCurrentTrack
        }
    
    let trackTitle = track.trackTitle()
    let artistName = track.artistName()

    let searchQuery = LyricsSearchQuery(
        title: trackTitle,
        primaryArtist: artistName,
        spotifyTrackId: track.trackIdentifier
    )
    
    let options = UserDefaults.lyricsOptions
    var source = UserDefaults.lyricsSource
    
    // switched to swift 5.8 syntax to compile with Theos on Linux.
    var repository: LyricsRepository

    switch source {
    case .genius:
        repository = geniusLyricsRepository
    case .lrclib:
        repository = LrclibLyricsRepository.shared
    case .lrcRedLiriQo:
        repository = LrcRedLiriQoLyricsRepository.shared
    case .petit:
        repository = petitLyricsRepository
    case .spicylyrics:
        repository = SpicyLyricsRepository.shared
    case .notReplaced:
        throw LyricsError.invalidSource
    }
    
    let lyricsDto: LyricsDto
    // Karaoke data the repository itself published while fetching (word-synced
    // sources), captured so the offline cache can store it with the DTO.
    var repositoryKaraoke: KaraokeLyricsDto?
    var servedFromOfflineCache = false

    updateLyricsState { $0 = LyricsLoadingState() }

    if let cached = LyricsOfflineCache.shared.cachedLyrics(for: searchQuery, source: source) {
        // Offline cache hit — no network fetch at all. Stored karaoke data is
        // republished exactly as the fresh fetch would have published it.
        servedFromOfflineCache = true
        lyricsDto = cached.dto

        KaraokeLyricsStore.shared.remove(trackId: searchQuery.spotifyTrackId)

        if let karaoke = cached.karaoke {
            KaraokeLyricsStore.shared.set(trackId: searchQuery.spotifyTrackId, lyrics: karaoke)
        }

        writeDebugLog("[Lyrics] \(searchQuery.spotifyTrackId): offline cache hit, \(lyricsDto.lines.count) lines")
    } else {
        // A fresh fetch starts from nothing, so the custom lyrics button only shows
        // for lyrics this fetch actually produced.
        KaraokeLyricsStore.shared.remove(trackId: searchQuery.spotifyTrackId)
    
        do {
            lyricsDto = try repository.getLyrics(searchQuery, options: options)
        }
        catch let error {
            if let error = error as? LyricsError {
                updateLyricsState { $0.fallbackError = error }
            }
            else {
                updateLyricsState { $0.fallbackError = .unknownError }
            }
        
            if source == .genius || !UserDefaults.lyricsOptions.geniusFallback {
                throw error
            }
        
            source = .genius
            repository = GeniusLyricsRepository()
        
            lyricsDto = try repository.getLyrics(searchQuery, options: options)
        }

        repositoryKaraoke = KaraokeLyricsStore.shared.lyrics(forTrackId: searchQuery.spotifyTrackId)
    }
    
    updateLyricsState {
        $0.isEmpty = lyricsDto.lines.isEmpty
        $0.wasRomanized = lyricsDto.romanization == .romanized
            || (lyricsDto.romanization == .canBeRomanized && UserDefaults.lyricsOptions.romanization)
        $0.loadedSuccessfully = true
    }

    publishLineSyncedKaraokeLyrics(lyricsDto, trackId: searchQuery.spotifyTrackId, source: source)

    if !servedFromOfflineCache {
        LyricsOfflineCache.shared.store(
            dto: lyricsDto,
            karaoke: repositoryKaraoke,
            query: searchQuery,
            source: source
        )
    }

    // Same timing-correction split as in loadCustomLyricsForTrackId: only
    // the native view's payload is shifted; the karaoke overlay compensates
    // on its own side.
    let timingOffsetMs = UserDefaults.lyricsTimingOffsets.effectiveMs(forTrackId: searchQuery.spotifyTrackId)

    let lyrics = Lyrics.with {
        $0.data = lyricsDto
            .applyingTimingOffset(timingOffsetMs)
            .toSpotifyLyricsData(source: source.description)
    }

    return lyrics
}

/// Extracts the Spotify track ID from a `/color-lyrics/v2/track/{trackId}` URL path.
/// Returns nil if the path doesn't match the expected format.
func extractTrackId(from path: String) -> String? {
    guard let range = path.range(of: #"/track/([a-zA-Z0-9]+)"#, options: .regularExpression) else {
        return nil
    }
    let trackId = String(path[range].split(separator: "/").last ?? "")
    return trackId.isEmpty ? nil : trackId
}

// MARK: - Lyrics prefetch
// Holds the result of the most recently completed prefetch. It's consumed (and
// cleared) by the next getLyricsDataForCurrentTrack call for the same track. If
// the real request arrives before prefetch finishes, or is for a different
// track, the prefetch result is simply ignored — this is a best-effort handoff,
// not a general cache.
private struct PrefetchedLyrics {
    let trackId: String
    let source: LyricsSource
    let data: Data
}
private var prefetchedResult: PrefetchedLyrics?

// Track ID currently being prefetched, to avoid duplicate background fetches.
private var prefetchingTrackId: String?

/// Coordinates the bounded wait in getLyricsDataForCurrentTrack with the
/// fetch it waits on: if the fetch finishes after the caller has already
/// given up and fallen back to Spotify's own response, the result is handed
/// over via storeLateLyricsResult instead of being dropped.
private final class LyricsFetchHandoff {
    let lock = NSLock()
    var callerGaveUp = false
}

// Guards both prefetch variables: the result is produced on a global queue,
// consumed on Spotify's own request threads, and invalidated from the
// settings UI, so every check-and-set sequence below runs under this lock.
private let prefetchStateLock = NSLock()

/// Drops everything remembered from the previous provider. Call when the lyrics
/// source changes so the next visit to any track fetches from the new one.
func invalidateLyricsForSourceChange() {
    prefetchStateLock.lock()
    prefetchedResult = nil
    prefetchingTrackId = nil
    prefetchStateLock.unlock()
    KaraokeLyricsStore.shared.clear()
    writeDebugLog("[Lyrics] provider changed — cleared prefetch and custom lyrics view caches")
}

/// Kicks off a background lyrics fetch for `trackId` so the result is ready
/// before Spotify fires its `/color-lyrics/v2` request.
/// Safe to call multiple times — duplicate calls for the same track are ignored.
func prefetchLyricsIfNeeded(trackId: String) {
    let source = UserDefaults.lyricsSource
    guard source.isReplacingLyrics else { return }
    
    prefetchStateLock.lock()
    // A waiting result from another provider is stale, not "already done".
    if let waiting = prefetchedResult, waiting.source != source { prefetchedResult = nil }
    // Already have a result waiting, or already fetching — nothing to do.
    let shouldFetch = prefetchedResult?.trackId != trackId && prefetchingTrackId != trackId
    if shouldFetch { prefetchingTrackId = trackId }
    prefetchStateLock.unlock()
    
    guard shouldFetch else { return }

    writeDebugLog("[Lyrics] prefetch start for \(trackId)")

    DispatchQueue.global(qos: .userInitiated).async {
        defer {
            prefetchStateLock.lock()
            if prefetchingTrackId == trackId {
                prefetchingTrackId = nil
            }
            prefetchStateLock.unlock()
        }
        do {
            var lyrics = try loadCustomLyricsForTrackId(trackId)

            // Apply color so the prefetched payload is fully valid on its own.
            // Mirrors the logic in getLyricsDataForCurrentTrack; prefetch has no
            // access to Spotify's original lyrics object, so displayOriginalColors
            // can't be honored here — falls back to the static/bg/gray logic.
            let lyricsColorsSettings = UserDefaults.lyricsColors
            if !lyricsColorsSettings.displayOriginalColors {
                let color: Color
                if lyricsColorsSettings.useStaticColor {
                    color = Color(hex: lyricsColorsSettings.staticColor)
                } else if let uiColor = backgroundViewModel?.color() {
                    color = Color(uiColor).normalized(lyricsColorsSettings.normalizationFactor)
                } else {
                    color = Color.gray
                }
                lyrics.colors = LyricsColors.with {
                    $0.backgroundColor = color.uInt32
                    $0.lineColor = Color.black.uInt32
                    $0.activeLineColor = Color.white.uInt32
                }
            }

            // The provider may have been switched while this was in flight.
            guard UserDefaults.lyricsSource == source else {
                writeDebugLog("[Lyrics] prefetch for \(trackId) discarded: provider changed")
                KaraokeLyricsStore.shared.remove(trackId: trackId)
                return
            }

            if let data = try? lyrics.serializedData() {
                prefetchStateLock.lock()
                prefetchedResult = PrefetchedLyrics(trackId: trackId, source: source, data: data)
                prefetchStateLock.unlock()
                writeDebugLog("[Lyrics] prefetch complete for \(trackId)")
            }
        } catch {
            writeDebugLog("[Lyrics] prefetch failed for \(trackId): \(error)")
        }
    }
}

/// Returns a serialized empty `Lyrics` protobuf payload.
/// Used as a fallback when every lyrics source (including Genius fallback) fails,
/// so we show "no lyrics" instead of leaking Spotify's own response.
func emptyLyricsData(originalLyrics: Lyrics? = nil) -> Data? {
    let emptyDto = LyricsDto(lines: [], timeSynced: false, romanization: .original, translation: nil)
    var lyrics = Lyrics.with {
        $0.data = emptyDto.toSpotifyLyricsData(source: "")
    }
    if let originalLyrics = originalLyrics {
        lyrics.colors = originalLyrics.colors
    }
    return try? lyrics.serializedData()
}

/// Hands over the result of a fetch that outlived the bounded wait in
/// getLyricsDataForCurrentTrack. The Now Playing lyrics card is fed by a
/// one-shot /color-lyrics response substitution: once the caller fell back
/// to Spotify's own response, the card's content is settled for that
/// request, and the finished lyrics used to be dropped on the floor — they
/// reached KaraokeLyricsStore (so the custom lyrics button and the one-line
/// bar appeared), but nothing ever served them to the card. Storing the
/// colored, serialized payload as the track's prefetched result means the
/// next lyrics request for the same track (re-entering Now Playing,
/// replaying the track, a queue revisit) is served instantly, and the Now
/// Playing scroll view is nudged to re-render in case its lyrics provider
/// re-evaluates on reload.
private func storeLateLyricsResult(_ fetched: Lyrics, trackId: String, source: LyricsSource, originalLyrics: Lyrics?) {
    // The provider may have been switched while this was in flight.
    guard UserDefaults.lyricsSource == source else {
        writeDebugLog("[Lyrics] late result for \(trackId) discarded: provider changed")
        return
    }

    var lyrics = fetched

    // Same coloring as the on-time path in getLyricsDataForCurrentTrack.
    let lyricsColorsSettings = UserDefaults.lyricsColors

    if lyricsColorsSettings.displayOriginalColors, let originalLyrics = originalLyrics {
        lyrics.colors = originalLyrics.colors
    }
    else {
        var color: Color

        if lyricsColorsSettings.useStaticColor {
            color = Color(hex: lyricsColorsSettings.staticColor)
        }
        else if let uiColor = backgroundViewModel?.color() {
            color = Color(uiColor)
                .normalized(lyricsColorsSettings.normalizationFactor)
        }
        else {
            color = Color.gray
        }

        lyrics.colors = LyricsColors.with {
            $0.backgroundColor = color.uInt32
            $0.lineColor = Color.black.uInt32
            $0.activeLineColor = Color.white.uInt32
        }
    }

    guard let data = try? lyrics.serializedData() else { return }

    prefetchStateLock.lock()
    // Single slot, same rule as the prefetch path: never evict another
    // track's waiting result for this one.
    let slotFree = prefetchedResult == nil || prefetchedResult?.trackId == trackId
    if slotFree {
        prefetchedResult = PrefetchedLyrics(trackId: trackId, source: source, data: data)
    }
    prefetchStateLock.unlock()

    guard slotFree else {
        writeDebugLog("[Lyrics] late result for \(trackId) not stored: a result for another track is waiting")
        return
    }

    writeDebugLog("[Lyrics] late result for \(trackId) stored; will be served on the next lyrics request for this track")

    // If this is the track on screen, ask the Now Playing scroll view to
    // re-render (the same reloadData the HideOnError path performs after
    // mutating providers). If Spotify's lyrics provider keeps the state it
    // already settled on, this is a no-op and the stored result still lands
    // on the next natural re-request. A nil reported track ID means the
    // player observer isn't attached (9.1.x), where the lyrics request
    // itself is the current-track signal — assume this is the track, as
    // loadCustomLyricsForTrackId does for metadata.
    let isCurrentTrack = KaraokePlaybackTracker.shared.playerReportedTrackId().map { $0 == trackId } ?? true
    guard isCurrentTrack else { return }

    DispatchQueue.main.async {
        if let controller = nowPlayingScrollViewController {
            controller.collectionView().reloadData()
        }
        else if let controller = npvScrollViewController {
            controller.collectionView().reloadData()
        }
    }
}

func getLyricsDataForCurrentTrack(_ originalPath: String, originalLyrics: Lyrics? = nil) throws -> Data {
    
    // track id from URL path; player objects are nil on 9.1.6
    // path: /color-lyrics/v2/track/{trackId}
    guard let trackIdentifier = extractTrackId(from: originalPath), !trackIdentifier.isEmpty else {
        throw LyricsError.noCurrentTrack
    }

    // The player observer doesn't attach on 9.1.x, so the lyrics request is the current-track signal.
    KaraokePlaybackTracker.shared.updateTrackIdFromLyricsFetch(trackIdentifier)

    clearCapturedTrackMetadata(unlessTrackId: trackIdentifier)

    // Use a prefetched result if one finished in time for this track.
    // Note: if displayOriginalColors is on, the prefetched payload won't carry
    // Spotify's true original colors (prefetch has no access to `originalLyrics`),
    // so it falls back to static/bg/gray coloring in that case — see the caveat
    // in prefetchLyricsIfNeeded.
    prefetchStateLock.lock()
    var consumedPrefetch: PrefetchedLyrics?
    if let prefetched = prefetchedResult, prefetched.trackId == trackIdentifier,
       prefetched.source == UserDefaults.lyricsSource {
        consumedPrefetch = prefetched
        prefetchedResult = nil
    }
    prefetchStateLock.unlock()
    
    if let prefetched = consumedPrefetch {
        writeDebugLog("[Lyrics] using prefetched result for \(trackIdentifier)")
        return prefetched.data
    }

    // Bounded wait around the synchronous fallback fetch, specifically
    // because a track stuck "queued" (503) on SpicyLyrics has a retry loop
    // (performQuery) that can legitimately run for up to ~26s — and this
    // function runs on whatever thread Spotify itself calls it from, not a
    // background one. Without a bound, skipping through several
    // back-to-back queued tracks could each block that thread for a long
    // stretch, one after another. This is the leading theory for lyrics
    // "breaking" after rapid skipping and needing an app restart to
    // recover — a real, reachable blocking path — though I don't have a
    // direct log capture of that exact failure to confirm the mechanism
    // beyond this.
    //
    // The underlying fetch keeps running in the background past the
    // timeout. Its result still reaches KaraokeLyricsStore through
    // loadCustomLyricsForTrackId itself, and the handoff below stores the
    // finished payload as this track's prefetched result (see
    // storeLateLyricsResult), so the Now Playing card — whose content was
    // already settled by the fallback response this caller returns — is
    // served on its next request for the track. Only THIS caller stops
    // waiting; a slow fetch isn't wasted, it's just no longer something
    // Spotify's own thread sits through.
    let fallbackTimeout: TimeInterval = 12.0
    let semaphore = DispatchSemaphore(value: 0)
    var fetchedLyrics: Lyrics?
    var fetchedError: Error?
    let handoff = LyricsFetchHandoff()
    let sourceAtStart = UserDefaults.lyricsSource
    DispatchQueue.global(qos: .userInitiated).async {
        do {
            let lyrics = try loadCustomLyricsForTrackId(trackIdentifier)

            handoff.lock.lock()
            let callerGaveUp = handoff.callerGaveUp
            if !callerGaveUp {
                fetchedLyrics = lyrics
            }
            handoff.lock.unlock()

            if callerGaveUp {
                storeLateLyricsResult(lyrics, trackId: trackIdentifier, source: sourceAtStart, originalLyrics: originalLyrics)
            }
        } catch {
            handoff.lock.lock()
            if !handoff.callerGaveUp {
                fetchedError = error
            }
            handoff.lock.unlock()
        }
        semaphore.signal()
    }
    guard semaphore.wait(timeout: .now() + fallbackTimeout) == .success else {
        handoff.lock.lock()
        handoff.callerGaveUp = true
        let finishedInRaceWindow = fetchedLyrics
        handoff.lock.unlock()

        // The fetch completed in the same instant the wait expired — its
        // closure saw a caller that hadn't given up yet, so the handoff is
        // this caller's job.
        if let finishedInRaceWindow = finishedInRaceWindow {
            storeLateLyricsResult(finishedInRaceWindow, trackId: trackIdentifier, source: sourceAtStart, originalLyrics: originalLyrics)
        }

        writeDebugLog("[Lyrics] \(trackIdentifier): \(UserDefaults.lyricsSource.description) took longer than \(fallbackTimeout)s — Spotify's own lyrics are used for this song")
        throw LyricsError.noSuchSong
    }
    if let fetchedError = fetchedError {
        writeDebugLog("[Lyrics] \(trackIdentifier): \(UserDefaults.lyricsSource.description) failed: \(fetchedError)")
        throw fetchedError
    }
    guard var lyrics = fetchedLyrics else {
        throw LyricsError.noSuchSong
    }
    
    let lyricsColorsSettings = UserDefaults.lyricsColors
    
    if lyricsColorsSettings.displayOriginalColors, let originalLyrics = originalLyrics {
        lyrics.colors = originalLyrics.colors
    }
    else {
        // no track object on 9.1.6: static color, else background color, else gray
        var color: Color
        
        if lyricsColorsSettings.useStaticColor {
            color = Color(hex: lyricsColorsSettings.staticColor)
        }
        else if let uiColor = backgroundViewModel?.color() {
            color = Color(uiColor)
                .normalized(lyricsColorsSettings.normalizationFactor)
        }
        else {
            color = Color.gray
        }
        
        lyrics.colors = LyricsColors.with {
            $0.backgroundColor = color.uInt32
            $0.lineColor = Color.black.uInt32
            $0.activeLineColor = Color.white.uInt32
        }
    }
    
    return try lyrics.serializedData()
}
