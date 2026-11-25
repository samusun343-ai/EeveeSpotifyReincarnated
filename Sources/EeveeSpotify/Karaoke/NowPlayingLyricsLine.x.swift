import Foundation
import MediaPlayer
import Orion

/// Experimental: show the currently-singing lyric line on the Lock Screen
/// and in the Dynamic Island, without a Live Activity.
///
/// The system renders an app's Now Playing info from MPNowPlayingInfoCenter,
/// and the only text slot in it that is safe to borrow is the album title:
/// the lock-screen subtitle reads "Artist — Album", so the line appears
/// there. Title and artist are NOT touched — CustomLyrics itself reads
/// those two back from the center to identify the playing track, and
/// Spotify's own UI never reads the published info at all. Nothing in this
/// tweak reads the album title back from the center either (only title,
/// artist and artwork are read, see CustomLyrics.x.swift and
/// AlbumArtColorExtractor.swift), so the substitution cannot feed back
/// into any other feature. The cost is that the real album name is not
/// shown on system surfaces while a line is active; the moment no line is
/// active (intro, instrumental gap after the last line, unsynced or
/// missing lyrics, feature off) Spotify's original info is published
/// again untouched.
///
/// Data flow:
/// - Playback position / track: KaraokePlaybackTracker (fed by the
///   SPTEsperantoPlayer observer registered in KaraokeHooks.x.swift).
/// - Lyrics: KaraokeLyricsStore, which the CustomLyrics fetch path fills
///   for every replacing source — word-synced DTOs directly, line-synced
///   ones via KaraokeLyricsDto.lineSynced(from:). Plain (unsynced) lyrics
///   never land there, so unsynced tracks simply never produce a line.
/// - The setter hook below merges the line into Spotify's own writes, so
///   the line survives Spotify's frequent republishes (track change,
///   play/pause, seek). A 0.3s timer covers the remaining case — the line
///   changing while Spotify publishes nothing — and only republishes when
///   the line actually changed.
///
/// Off by default: KaraokeOptions.lockScreenLineEnabled.
final class NowPlayingLyricsLineController {
    static let shared = NowPlayingLyricsLineController()

    private let lock = NSLock()
    /// The most recent info dictionary Spotify itself published, recorded
    /// in the setter hook before any modification. Our own writes are
    /// excluded via isApplyingOwnWrite, so this always holds the pristine
    /// values the original album title is restored from.
    private var spotifyInfo: [String: Any]?
    /// When spotifyInfo was recorded; used to keep the elapsed-playback-
    /// time key honest when republishing (see infoForPublishing).
    private var spotifyInfoStamp = Date()
    /// The line we most recently injected, or nil when the published info
    /// currently carries Spotify's original album title.
    private var publishedLine: String?
    private var isApplyingOwnWrite = false

    private var didBootstrap = false
    private var timer: Timer?

    private init() {}

    private var isEnabled: Bool { UserDefaults.karaokeOptions.lockScreenLineEnabled }

    // MARK: - Setter hook entry point

    /// Called for every MPNowPlayingInfoCenter write that did not originate
    /// here. Records the pristine info and, when the feature is on and a
    /// line is active, returns a copy of the info with the line as its
    /// album title. Otherwise returns the info unchanged.
    func processOutgoingInfo(_ info: [String: Any]?) -> [String: Any]? {
        lock.lock()
        let ownWrite = isApplyingOwnWrite
        if !ownWrite {
            spotifyInfo = info
            spotifyInfoStamp = Date()
        }
        lock.unlock()

        guard !ownWrite, isEnabled, let info else { return info }
        guard let line = currentLineText() else { return info }

        lock.lock()
        publishedLine = line
        lock.unlock()

        var modified = info
        modified[MPMediaItemPropertyAlbumTitle] = line
        return modified
    }

    // MARK: - Lifecycle

    /// Starts the toggle watcher and the line timer (when the setting is
    /// on). Called once from activateKaraokeHooks().
    func bootstrap() {
        lock.lock()
        guard !didBootstrap else { lock.unlock(); return }
        didBootstrap = true
        lock.unlock()

        NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.refreshTimerState() }

        NotificationCenter.default.addObserver(
            forName: .eeveeKaraokeLyricsChanged, object: nil, queue: .main
        ) { [weak self] _ in self?.tick() }

        refreshTimerState()
    }

    private func refreshTimerState() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }

            if self.isEnabled {
                guard self.timer == nil else { return }
                writeDebugLog("[NowPlayingLine] experimental lock-screen line enabled")
                let timer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] _ in
                    self?.tick()
                }
                self.timer = timer
                self.tick()
            } else {
                guard self.timer != nil else { return }
                writeDebugLog("[NowPlayingLine] experimental lock-screen line disabled, restoring original info")
                self.timer?.invalidate()
                self.timer = nil
                self.restoreOriginalInfo()
            }
        }
    }

    // MARK: - Line tracking

    /// Republishes Now Playing info when the active line changed since the
    /// last publish. Runs on the main queue (timer / notifications).
    private func tick() {
        guard isEnabled else { return }

        let line = currentLineText()

        lock.lock()
        let changed = line != publishedLine
        if changed { publishedLine = line }
        let base = spotifyInfo
        let stamp = spotifyInfoStamp
        lock.unlock()

        guard changed, let base else { return }
        applyOwnWrite(infoForPublishing(base: base, stamp: stamp, albumOverride: line))
    }

    private func restoreOriginalInfo() {
        lock.lock()
        publishedLine = nil
        let base = spotifyInfo
        let stamp = spotifyInfoStamp
        lock.unlock()

        guard let base else { return }
        applyOwnWrite(infoForPublishing(base: base, stamp: stamp, albumOverride: nil))
    }

    /// Builds the dictionary to publish from Spotify's pristine info.
    /// albumOverride replaces the album title; nil keeps the original.
    ///
    /// The elapsed-playback-time key is advanced by (age × rate): the
    /// system anchors its progress extrapolation at the moment the info is
    /// set, so republishing Spotify's stale elapsed value as-is would make
    /// the lock-screen progress bar jump backwards until Spotify's next
    /// own publish.
    private func infoForPublishing(base: [String: Any], stamp: Date, albumOverride: String?) -> [String: Any] {
        var info = base

        if let albumOverride {
            info[MPMediaItemPropertyAlbumTitle] = albumOverride
        }

        if let elapsed = (base[MPNowPlayingInfoPropertyElapsedPlaybackTime] as? NSNumber)?.doubleValue,
           let rate = (base[MPNowPlayingInfoPropertyPlaybackRate] as? NSNumber)?.doubleValue {
            info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = elapsed + Date().timeIntervalSince(stamp) * rate
        }

        return info
    }

    private func applyOwnWrite(_ info: [String: Any]) {
        lock.lock()
        isApplyingOwnWrite = true
        lock.unlock()

        MPNowPlayingInfoCenter.default().nowPlayingInfo = info

        lock.lock()
        isApplyingOwnWrite = false
        lock.unlock()
    }

    /// The lyric line active at the current playback position, or nil when
    /// there is none: no track, no synced lyrics for it, the position is
    /// before the first line, or past the last line's end (plus a small
    /// grace period). Lines are in ascending start order, as produced by
    /// every lyrics source and assumed by the karaoke view as well.
    private func currentLineText() -> String? {
        let tracker = KaraokePlaybackTracker.shared

        guard let trackId = tracker.playerReportedTrackId() ?? tracker.currentTrackId(),
              let lyrics = KaraokeLyricsStore.shared.lyrics(forTrackId: trackId),
              !lyrics.lines.isEmpty else { return nil }

        let positionMs = tracker.currentPositionMs()

        var candidate: KaraokeLineDto?
        var nextStartMs: Int?
        for line in lyrics.lines {
            if line.startMs <= positionMs {
                candidate = line
            } else {
                nextStartMs = line.startMs
                break
            }
        }

        guard let line = candidate else { return nil }

        // During a gap the previous line stays up until the next one starts
        // (same rule as the karaoke view); after the final line it clears
        // shortly after that line's end.
        let limit = nextStartMs ?? (line.endMs + 2000)
        guard positionMs < limit else { return nil }

        let text = line.plainText.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }
}

/// Merges the current lyric line into every Now Playing info Spotify
/// publishes (see NowPlayingLyricsLineController). Installed with the
/// karaoke hooks and a pass-through unless the experimental setting is on,
/// so the setting takes effect without re-injection.
class NowPlayingInfoCenterLyricsLineHook: ClassHook<MPNowPlayingInfoCenter> {
    typealias Group = KaraokeGroup

    func setNowPlayingInfo(_ newInfo: [String: Any]?) {
        orig.setNowPlayingInfo(NowPlayingLyricsLineController.shared.processOutgoingInfo(newInfo))
    }
}
