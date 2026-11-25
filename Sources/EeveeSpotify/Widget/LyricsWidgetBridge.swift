import Foundation
import MediaPlayer
import WidgetKit

/// Publishes the now-playing track and its Eevee-fetched lyrics to the
/// EeveeLyricsWidget extension (Widget/Sources/EeveeLyricsWidget.swift).
///
/// Data path: the payload is written to UserDefaults under Spotify's own
/// widget suite, `group.com.spotify.client.widget`. On sideloaded installs,
/// zxPluginsInject (LC-injected into the main app and every .appex) mirrors
/// the main app's group-suite writes into the shared group container and
/// redirects the extension's reads of the same suite to that location, so
/// the widget sees this payload. On jailbroken (.deb) installs there is no
/// Eevee widget extension, so publishing is inert apart from the defaults
/// write itself.
///
/// Experimental and off by default (`UserDefaults.lyricsWidgetEnabled`).
enum LyricsWidgetBridge {
    static let suiteName = "group.com.spotify.client.widget"
    static let payloadKey = "eevee.widget.nowPlaying.v1"
    static let widgetKind = "EeveeLyricsWidget"

    private static let signatureLock = NSLock()
    private static var lastPublishedSignature: String?

    static func publish(trackId: String, title: String?, artist: String?, dto: LyricsDto) {
        guard UserDefaults.lyricsWidgetEnabled, !trackId.isEmpty else { return }

        // Lyrics are also fetched for tracks that are not playing (queue
        // prefetch, browsing). The widget is a now-playing surface, so only
        // publish for the track the player reports — or when the player
        // hasn't reported one yet. Same rule as the MPNowPlayingInfoCenter
        // metadata read in loadCustomLyricsForTrackId.
        if let reported = KaraokePlaybackTracker.shared.playerReportedTrackId(),
           reported != trackId {
            return
        }

        // loadCustomLyricsForTrackId can run several times for one track
        // (prefetch + real fetch + retries); don't rewrite the payload or
        // spend a WidgetKit reload on an identical result.
        let signature = [
            trackId,
            String(dto.lines.count),
            dto.lines.first?.content ?? "",
            dto.lines.last?.content ?? ""
        ].joined(separator: "|")

        signatureLock.lock()

        guard signature != lastPublishedSignature else {
            signatureLock.unlock()
            return
        }

        lastPublishedSignature = signature
        signatureLock.unlock()

        let tracker = KaraokePlaybackTracker.shared

        var payload: [String: Any] = [
            "version": 1,
            "trackId": trackId,
            "title": title ?? "",
            "artist": artist ?? "",
            "timeSynced": dto.timeSynced,
            "anchorPositionMs": tracker.currentPositionMs(),
            "anchorTimestamp": Date().timeIntervalSince1970,
            "isPlaying": tracker.isPlaying()
        ]

        if dto.timeSynced {
            payload["timedLines"] = dto.lines.map { [$0.offsetMs ?? 0, $0.content] as [Any] }
        } else {
            payload["plainLines"] = dto.lines.map { $0.content }
        }

        if let artworkData = currentArtworkData() {
            payload["artworkJPEG"] = artworkData
        }

        guard let defaults = UserDefaults(suiteName: suiteName) else { return }
        defaults.set(payload, forKey: payloadKey)

        WidgetCenter.shared.reloadTimelines(ofKind: widgetKind)

        writeDebugLog(
            "[Widget] published payload for \(trackId) "
            + "(\(dto.lines.count) lines, synced=\(dto.timeSynced))"
        )
    }

    /// Now-playing artwork as a small JPEG, read from MPNowPlayingInfoCenter
    /// on the main thread (same pattern as the metadata read in
    /// CustomLyrics). Kept inside the defaults payload so the widget never
    /// has to resolve a shared-container file path itself.
    private static func currentArtworkData() -> Data? {
        var data: Data?

        let read = {
            let info = MPNowPlayingInfoCenter.default().nowPlayingInfo

            if let artwork = info?[MPMediaItemPropertyArtwork] as? MPMediaItemArtwork {
                data = artwork
                    .image(at: CGSize(width: 240, height: 240))?
                    .jpegData(compressionQuality: 0.7)
            }
        }

        if Thread.isMainThread {
            read()
        } else {
            DispatchQueue.main.sync(execute: read)
        }

        return data
    }
}
