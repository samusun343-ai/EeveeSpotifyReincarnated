import UIKit
import Orion

// Every version-dependent hook target name lives here, so adding a
// Spotify version means extending this one switchboard instead of
// editing a switch in every hook file. The mapping for each name is
// exactly what the per-file switches/ternaries returned before the
// consolidation — no version loses or gains a target.
struct HookTargetNameHelper {
    static var lyricsScrollProvider: String {
        switch EeveeSpotify.hookTarget {
        case .lastAvailableiOS14, .v91:
            return "Lyrics_CoreImpl.ScrollProvider"
        default:
            return "Lyrics_NPVCommunicatorImpl.ScrollProvider"
        }
    }

    static var lyricsFullscreenViewController: String {
        switch EeveeSpotify.hookTarget {
        case .lastAvailableiOS14:
            return "Lyrics_CoreImpl.FullscreenViewController"
        case .lastAvailableiOS15:
            return "Lyrics_FullscreenPageImpl.FullscreenViewController"
        default:
            return "Lyrics_FullscreenElementPageImpl.FullscreenElementViewController"
        }
    }

    static var lyricsOnlyViewController: String {
        switch EeveeSpotify.hookTarget {
        case .lastAvailableiOS14:
            return "Lyrics_CoreImpl.LyricsOnlyViewController"
        default:
            return "Lyrics_NPVCommunicatorImpl.LyricsOnlyViewController"
        }
    }

    static var errorViewController: String {
        switch EeveeSpotify.hookTarget {
        case .lastAvailableiOS14:
            return "Lyrics_CoreImpl.ErrorViewController"
        default:
            return "Lyrics_NPVCommunicatorImpl.ErrorViewController"
        }
    }

    static var playerTrack: String {
        switch EeveeSpotify.hookTarget {
        case .v90:
            return "SPTPlayerTrackImplementation"
        default:
            return "SPTPlayerTrack"
        }
    }

    static var nowPlayingScrollViewController: String {
        switch EeveeSpotify.hookTarget {
        case .v91:
            return "UIView" // Dummy target for 9.1.6
        default:
            return "NowPlaying_ScrollImpl.NowPlayingScrollViewController"
        }
    }

    static var sessionDelegateBootstrap: String {
        switch EeveeSpotify.hookTarget {
        case .lastAvailableiOS14:
            return "SPTCoreURLSessionDataDelegate"
        default:
            return "SPTDataLoaderService"
        }
    }

    static var popUpContainer: String {
        switch EeveeSpotify.hookTarget {
        case .v91:
            // For 9.1.x, use dummy UIView to avoid crashes
            return "UIView"
        case .lastAvailableiOS14:
            return "SPTEncorePopUpContainer"
        default:
            return "SPTEncorePopUpContainer" // Use older class for compatibility
        }
    }

    static var encoreLabel: String {
        switch EeveeSpotify.hookTarget {
        case .v91:
            return "UIView"
        default:
            return "SPTEncoreLabel"
        }
    }

    static var freeTierArtistHubResolver: String {
        switch EeveeSpotify.hookTarget {
        case .v91:
            return "UIView"
        default:
            return "SPTFreeTierArtistHubRemoteURLResolver"
        }
    }
}
