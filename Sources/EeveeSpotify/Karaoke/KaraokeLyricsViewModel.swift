import SwiftUI

/// Keeps the open custom lyrics view in step with the playing track. When a song ends and the
/// next one starts, it swaps in that song's lyrics (fetching them if Spotify hasn't), and gives up
/// — closing the view — only if none turn up.
@available(iOS 15.0, *)
final class KaraokeLyricsViewModel: ObservableObject {
    @Published private(set) var trackId: String?
    @Published private(set) var lyrics: KaraokeLyricsDto?
    @Published private(set) var layouts: [KaraokeLineLayout] = []

    /// Timing correction in effect for the current track (global + per-track),
    /// and this track's own component of it. The view subtracts
    /// `timingOffsetMs` from the playback position on every frame, so changes
    /// made through the overlay's buttons are visible immediately.
    @Published private(set) var timingOffsetMs: Int = 0
    @Published private(set) var trackTimingOffsetMs: Int = 0

    private let onNoLyrics: () -> Void
    private var observer: NSObjectProtocol?
    private var retryWork: DispatchWorkItem?
    private var attempts = 0

    private let maxAttempts = 4
    private let retryInterval: TimeInterval = 2.0

    init(trackId: String?, lyrics: KaraokeLyricsDto, onNoLyrics: @escaping () -> Void) {
        self.trackId = trackId
        self.onNoLyrics = onNoLyrics
        refreshTimingOffset()
        apply(lyrics)
        observer = NotificationCenter.default.addObserver(
            forName: .eeveeKaraokeLyricsChanged, object: nil, queue: .main
        ) { [weak self] _ in self?.sync() }
    }

    deinit {
        retryWork?.cancel()
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    private func apply(_ lyrics: KaraokeLyricsDto?) {
        self.lyrics = lyrics
        let songIsRTL = lyrics?.isRTL ?? false
        layouts = lyrics?.lines.map { line in
            let direction = line.strongDirection
            return KaraokeLineLayout(words: line.words, isRTL: direction.map { $0 == .rightToLeft } ?? songIsRTL)
        } ?? []
    }

    private func sync() {
        // The player's own track, not the one a lyrics request last named: Spotify also loads
        // lyrics for songs that haven't started yet.
        let tracker = KaraokePlaybackTracker.shared
        guard let playing = tracker.playerReportedTrackId() ?? tracker.currentTrackId() else { return }

        let stored = KaraokeLyricsStore.shared.lyrics(forTrackId: playing)
        if playing != trackId {
            retryWork?.cancel()
            retryWork = nil
            attempts = 0
            trackId = playing
            refreshTimingOffset()
            apply(stored)
        } else if lyrics == nil, let stored {
            apply(stored)
        }

        if lyrics == nil {
            fetchMissingLyrics()
        } else {
            retryWork?.cancel()
            retryWork = nil
        }
    }

    private func refreshTimingOffset() {
        let offsets = UserDefaults.lyricsTimingOffsets
        timingOffsetMs = offsets.effectiveMs(forTrackId: trackId)
        trackTimingOffsetMs = offsets.perTrackMs(forTrackId: trackId)
    }

    /// Steps this track's own timing correction by `stepMs` (the overlay's
    /// buttons use ±100 ms) and persists it. The correction is clamped to
    /// ±10 s; stepping back to zero removes the per-track entry entirely.
    func adjustTimingOffset(by stepMs: Int) {
        guard let trackId, !trackId.isEmpty else { return }

        var offsets = UserDefaults.lyricsTimingOffsets
        let newValue = min(10_000, max(-10_000, offsets.perTrackMs(forTrackId: trackId) + stepMs))
        offsets.setPerTrackMs(newValue, forTrackId: trackId)
        UserDefaults.lyricsTimingOffsets = offsets
        refreshTimingOffset()
        writeDebugLog("[Karaoke] timing offset for \(trackId): track \(newValue) ms, effective \(timingOffsetMs) ms")
    }

    /// Removes this track's own timing correction (the global one, if any,
    /// still applies).
    func resetTimingOffset() {
        guard let trackId, !trackId.isEmpty else { return }

        var offsets = UserDefaults.lyricsTimingOffsets
        offsets.setPerTrackMs(0, forTrackId: trackId)
        UserDefaults.lyricsTimingOffsets = offsets
        refreshTimingOffset()
    }

    private func fetchMissingLyrics() {
        guard retryWork == nil, let trackId else { return }
        guard attempts < maxAttempts else {
            writeDebugLog("[Karaoke] no lyrics for \(trackId) after \(attempts) attempts, closing custom lyrics view")
            onNoLyrics()
            return
        }
        attempts += 1
        writeDebugLog("[Karaoke] track changed to \(trackId) with the custom lyrics view open, fetching lyrics (attempt \(attempts))")
        prefetchLyricsIfNeeded(trackId: trackId)

        let work = DispatchWorkItem { [weak self] in
            self?.retryWork = nil
            self?.sync()
        }
        retryWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + retryInterval, execute: work)
    }
}
