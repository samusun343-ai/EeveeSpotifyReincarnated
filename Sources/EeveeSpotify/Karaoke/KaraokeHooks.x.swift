import Foundation
import Orion
import UIKit
import ObjectiveC.runtime

private var karaokeObserverRegistered = false
private let karaokeObserver = EeveeKaraokeObserver()

// didChangeState: is the confirmed real SPTPlayerObserver protocol method —
// found via binary string inspection (the type-encoding string
// `v24@0:8@"<SPTPlayerObserver>"16` next to it confirms the argument is
// exactly one object conforming to SPTPlayerObserver, matching this single-
// argument signature). This does NOT match the old, previously-assumed
// `player(_:stateDidChange:)` shape (two arguments) kept just below for
// backward compatibility with whatever older Spotify version that
// convention was originally written for — if this build's real object calls
// didChangeState:, the two-argument variants below simply never fire, which
// is harmless (extra unused @objc methods, not a conflict).
@objc final class EeveeKaraokeObserver: NSObject {
    @objc func didChangeState(_ newState: AnyObject) {
        KaraokePlaybackTracker.shared.processStateChange(state: newState)
        DispatchQueue.main.async {
            KaraokeGestureTrigger.shared.attachIfNeeded()
        }
    }

    @objc func player(_ player: AnyObject, stateDidChange newState: AnyObject) {
        KaraokePlaybackTracker.shared.processStateChange(state: newState)
        DispatchQueue.main.async {
            KaraokeGestureTrigger.shared.attachIfNeeded()
        }
    }

    @objc func player(_ player: AnyObject, stateDidChange newState: AnyObject, fromState oldState: AnyObject) {
        KaraokePlaybackTracker.shared.processStateChange(state: newState)
        DispatchQueue.main.async {
            KaraokeGestureTrigger.shared.attachIfNeeded()
        }
    }

    @objc func player(_ player: AnyObject, didEncounterError error: AnyObject) {}
    @objc func player(_ player: AnyObject, didMoveToRelativeTrack relativeIndex: Int) {}
    @objc func player(_ player: AnyObject, queueDidChange queue: AnyObject) {}
}

// Separate hook (not reusing SponsorBlock's PlayerServiceObserverHook) so the
// karaoke overlay's playback tracking works independently of whether
// SponsorBlock is enabled/active. addPlayerObserver supports multiple
// observers being registered, so this is additive and doesn't interfere
// with SponsorBlock's own observer registration.
//
// Kept as a fallback for older Spotify versions where
// SPTPlayerServiceImplementation itself might still have addPlayerObserver:
// directly (the shape this hook was originally written against). On the
// 9.1.78 IPA I inspected it doesn't — see KaraokeStateObservableProbeHook
// below for what actually replaced it on this build — so on that build this
// hook now just fails to attach (logged, harmless), the same outcome as
// before this was diagnosed.
class KaraokePlayerServiceObserverHook: ClassHook<NSObject> {
    typealias Group = KaraokeGroup

    // The two-name fallback (plain name stopped resolving as of 9.1.78; the
    // class is only registered under its mangled Swift name now) lives in
    // PlayerServiceObservation so SponsorBlock resolves the same target.
    static var targetName: String { PlayerServiceObservation.targetName }

    func addPlayerObserver(_ observer: AnyObject) {
        orig.addPlayerObserver(observer)
        if !karaokeObserverRegistered {
            karaokeObserverRegistered = true
            writeDebugLog("[Karaoke] registering playback observer on service")
            orig.addPlayerObserver(karaokeObserver)
        }
    }
}

struct KaraokeGroup: HookGroup {}

private var didDumpStateObservable = false

// provideStateObservable() is the real, currently-used method on this class
// (confirmed via the [KaraokeProbe] PlayerService(...) dump from
// activateKaraokeHooks below) — addPlayerObserver:/removePlayerObserver:
// don't exist on SPTPlayerServiceImplementation itself at all anymore.
// What it returns is a live SPTEsperantoPlayer instance (confirmed via the
// [KaraokeProbe] stateObservable dump this hook produces below), and THAT
// object is what actually has addPlayerObserver:/removePlayerObserver: —
// registering directly on it here, rather than waiting for Spotify's own UI
// to call addPlayerObserver: on it first, since there's no guarantee of
// exactly when (or whether, e.g. if the relevant screen is never opened)
// that would happen on its own.
//
// Registration on the returned observable goes through
// PlayerServiceObservation.register (shared with SponsorBlock).
class KaraokeStateObservableProbeHook: ClassHook<NSObject> {
    typealias Group = KaraokeGroup
    static var targetName: String { KaraokePlayerServiceObserverHook.targetName }

    func provideStateObservable() -> AnyObject {
        let observable = orig.provideStateObservable()
        if !didDumpStateObservable {
            didDumpStateObservable = true
            karaokeDumpClassMethods("stateObservable", of: observable)
        }
        if !karaokeObserverRegistered {
            karaokeObserverRegistered = true
            writeDebugLog("[Karaoke] registering playback observer on SPTEsperantoPlayer via provideStateObservable")
            PlayerServiceObservation.register(karaokeObserver, onStateObservable: observable)
        }
        return observable
    }
}

func activateKaraokeHooks() {
    _ = LyricsLaunchSource.value
    // Uses the same shared two-name resolution as the hooks themselves —
    // this is only the startup diagnostic log, but it should report the
    // same "found" outcome as whichever name the hooks resolve, or the log
    // becomes actively misleading (saying "missing" right above a hook that
    // then attaches fine).
    let resolvedClass = PlayerServiceObservation.resolvedClass
    let resolvedName = resolvedClass.map { NSStringFromClass($0) }
    writeDebugLog("[Karaoke] activate: class=\(resolvedName ?? "<missing>")")
    KaraokeGroup().activate()
    writeDebugLog("[Karaoke] hook group activated")

    // -addPlayerObserver: exists on this class (Orion found it enough to
    // report a hook failure rather than a missing-target error — see
    // KaraokePlayerServiceObserverHook's comment) but doesn't actually
    // attach, which most likely means the real observer-registration API
    // has moved elsewhere (possibly the generic SPTObserverManager<Protocol>
    // pattern also seen in this binary) rather than living on this class in
    // the shape Orion expects. This dumps the class's real, complete method
    // table — no live instance needed, `class_copyMethodList` works
    // directly on the Class — so the next debug log shows exactly what IS
    // callable here instead of guessing at another selector blind.
    if let resolvedClass = resolvedClass {
        karaokeDumpClassMethods("PlayerService(\(resolvedName ?? "?"))", ofClass: resolvedClass)
    }

    activateKaraokeFooterButton()
}
