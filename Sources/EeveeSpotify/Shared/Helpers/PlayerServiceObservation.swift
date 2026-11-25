import Foundation
import ObjectiveC.runtime

/// Shared pieces of the current player-state observation path, used by both
/// Karaoke and SponsorBlock so the two features can't drift apart again
/// (Karaoke migrated to the Esperanto path; SponsorBlock stayed on the dead
/// pre-9.1 registration and silently stopped receiving state changes —
/// audits A-1-1 / B-1).
///
/// The current shape, confirmed against the 9.1.78 / 9.2.2 binaries:
/// `SPTPlayerServiceImplementation` no longer has `addPlayerObserver:` and
/// only resolves under its mangled Swift name. Playback state is observed by
/// registering an `SPTPlayerObserver` on the `SPTEsperantoPlayer` returned
/// from the service's `provideStateObservable()`; that object does have
/// `addPlayerObserver:` (exactly one object argument) and calls back
/// `didChangeState:` on its observers.
enum PlayerServiceObservation {
    static let legacyClassName = "SPTPlayerServiceImplementation"
    static let mangledClassName = "_TtC17Player_CommonImpl30SPTPlayerServiceImplementation"

    /// Two-name fallback for the player service class: the plain name first
    /// (what older Spotify versions exported), the mangled name second (the
    /// only registered form since at least 9.1.78). If neither resolves,
    /// returns the plain name — the same silent-no-op outcome each call site
    /// previously had with its own copy of this logic.
    static var targetName: String {
        if NSClassFromString(legacyClassName) != nil {
            return legacyClassName
        }
        if NSClassFromString(mangledClassName) != nil {
            return mangledClassName
        }
        return legacyClassName
    }

    /// The resolved player service class under either name, for diagnostics.
    static var resolvedClass: AnyClass? {
        NSClassFromString(legacyClassName) ?? NSClassFromString(mangledClassName)
    }

    /// Registers `observer` on the SPTEsperantoPlayer state observable.
    /// `.perform(_:with:)` rather than a typed call: the observable is only
    /// available as AnyObject, and `addPlayerObserver:` is confirmed to exist
    /// on it with exactly one object argument, so this is an ordinary
    /// Objective-C message send, not a guessed selector.
    static func register(_ observer: AnyObject, onStateObservable observable: AnyObject) {
        _ = observable.perform(Selector(("addPlayerObserver:")), with: observer)
    }
}
