import Orion
import UIKit

private var shouldOverrideLocalTrackURI = false

// 9.1.x+ counterpart of SPTPlayerTrackHook's metadata() forcing, below.
// The original hook sits in LyricsErrorHandlingGroup, which the 9.1.x init
// path never activates — so on current Spotify the has_lyrics injection
// never happened, and for tracks without official lyrics the client never
// issued the /color-lyrics/v2 request Eevee replaces. The target is
// verified present in the 9.2.2 binary: SPTPlayerTrack is in the ObjC
// class list and implements metadata()/setMetadata:/URI, and "has_lyrics"
// appears among its track metadata keys. Only metadata() is hooked here:
// the original's URI() behavior (local-track override + prefetch trigger)
// stays legacy-only, as 9.1.x has its own prefetch path and the override
// was never active there. Activated from the 9.1.x init path only when a
// custom lyrics source is selected (lyricsSource.isReplacingLyrics).
class SPTPlayerTrackAvailabilityHook: ClassHook<NSObject> {
    typealias Group = LyricsAvailabilityGroup
    static let targetName = "SPTPlayerTrack"

    func metadata() -> [String: String] {
        var meta = orig.metadata()
        meta["has_lyrics"] = "true"
        return meta
    }
}

// SPTPlayerTrack metadata hooks not compatible with 9.1.x
class SPTPlayerTrackHook: ClassHook<NSObject> {
    typealias Group = LyricsErrorHandlingGroup  // Not activated for 9.1.x
    static let targetName = HookTargetNameHelper.playerTrack

    func metadata() -> [String: String] {
        var meta = orig.metadata()
        meta["has_lyrics"] = "true"
        return meta
    }
    
    func URI() -> NSURL? {
        let uri = orig.URI()

        guard shouldOverrideLocalTrackURI,
              let absoluteString = uri?.absoluteString,
              absoluteString.isLocalTrackIdentifier else {

            // Trigger a background lyrics prefetch as soon as the track URI is
            // observed — well before Spotify fires its /color-lyrics/v2 request.
            if let uriString = uri?.absoluteString,
               uriString.hasPrefix("spotify:track:") {
                let trackId = uriString.replacingOccurrences(of: "spotify:track:", with: "")
                if !trackId.isEmpty {
                    prefetchLyricsIfNeeded(trackId: trackId)
                }
            }

            return uri
        }

        return NSURL(string: "spotify:track:")!
    }
}

// LyricsScrollProvider not compatible with 9.1.x
class LyricsScrollProviderHook: ClassHook<NSObject> {
    typealias Group = LyricsErrorHandlingGroup  // Not activated for 9.1.x
    static let targetName = "Lyrics_CoreImpl.LyricsScrollProvider"
    
    func isEnabledForTrack(_ track: SPTPlayerTrack) -> Bool {
        return true
    }
}

// NPVScrollViewController not compatible with 9.1.x  
class NPVScrollViewControllerHook: ClassHook<NSObject> {
    typealias Group = LyricsErrorHandlingGroup  // Not activated for 9.1.x (moved from ModernLyricsGroup)
    static var targetName = "NowPlaying_ScrollImpl.NPVScrollViewController"

    func viewWillAppear(_ animated: Bool) {
        shouldOverrideLocalTrackURI = true
        orig.viewWillAppear(animated)
    }
    
    func viewWillDisappear(_ animated: Bool) {
        shouldOverrideLocalTrackURI = false
        orig.viewWillDisappear(animated)
    }
}

// V91-compatible version of NPVScrollViewController hook
class NPVScrollViewControllerV91Hook: ClassHook<NSObject> {
    typealias Group = V91LyricsGroup
    static var targetName = "NowPlaying_ScrollImpl.NPVScrollViewController"

    func viewWillAppear(_ animated: Bool) {
        shouldOverrideLocalTrackURI = true
        orig.viewWillAppear(animated)
    }
    
    func viewWillDisappear(_ animated: Bool) {
        shouldOverrideLocalTrackURI = false
        orig.viewWillDisappear(animated)
    }
}

class NowPlayingScrollViewControllerHook: ClassHook<NSObject> {
    typealias Group = LegacyLyricsGroup
    static var targetName = HookTargetNameHelper.nowPlayingScrollViewController
    
    func nowPlayingScrollViewModelWithDidLoadComponentsFor(
        _ track: SPTPlayerTrack,
        withDifferentProviders: Bool,
        scrollEnabledValueChanged: Bool
    ) -> NowPlayingScrollViewController {
        let controller = orig.nowPlayingScrollViewModelWithDidLoadComponentsFor(
            track,
            withDifferentProviders: withDifferentProviders,
            scrollEnabledValueChanged: scrollEnabledValueChanged
        )
        
        if !scrollEnabledValueChanged {
            controller.scrollEnabled = true
            controller.nowPlayingScrollViewModelDidChangeScrollEnabledValue()
        }
        
        return controller
    }
}
