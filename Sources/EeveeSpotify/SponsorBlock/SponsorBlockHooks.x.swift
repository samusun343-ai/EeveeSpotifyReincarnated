import Foundation
import Orion
import UIKit

private var eeveeObserverRegistered = false
private let eeveeObserver = EeveeSponsorBlockObserver()

@objc final class EeveeSponsorBlockObserver: NSObject {
    /// The SPTEsperantoPlayer this observer was registered on (set by
    /// SponsorBlockStateObservableHook before registration). The current
    /// `didChangeState:` callback carries no player argument, but the
    /// skipper needs a player object to seek on — the Esperanto player is
    /// that object on the current path.
    weak var esperantoPlayer: AnyObject?

    /// The confirmed current SPTPlayerObserver callback (same shape the
    /// Karaoke observer uses): SPTEsperantoPlayer calls this, not the
    /// two-argument variants below — those are kept for the legacy
    /// registration path (PlayerServiceObserverHook) on older Spotify.
    @objc func didChangeState(_ newState: AnyObject) {
        guard let player = esperantoPlayer else { return }
        SponsorBlockSkipper.shared.processStateChange(player: player, state: newState)
    }

    @objc func player(_ player: AnyObject, stateDidChange newState: AnyObject) {
        SponsorBlockSkipper.shared.processStateChange(player: player, state: newState)
    }

    @objc func player(_ player: AnyObject, stateDidChange newState: AnyObject, fromState oldState: AnyObject) {
        SponsorBlockSkipper.shared.processStateChange(player: player, state: newState)
    }

    @objc func player(_ player: AnyObject, didEncounterError error: AnyObject) {}
    @objc func player(_ player: AnyObject, didMoveToRelativeTrack relativeIndex: Int) {}
    @objc func player(_ player: AnyObject, queueDidChange queue: AnyObject) {}
}

class ProgressBarSliderHook: ClassHook<UIView> {
    typealias Group = SponsorBlockGroup
    static let targetName = "_TtCO17NowPlaying_ECMKit11ProgressBar6Slider"

    func layoutSubviews() {
        orig.layoutSubviews()
        SponsorBlockOverlay.shared.attach(to: target)
    }
}

// Legacy registration path, kept as a fallback for older Spotify versions
// where SPTPlayerServiceImplementation itself still has addPlayerObserver:.
// On current builds (9.1.78+, incl. 9.2.2) that method no longer exists on
// the service — registration moved to the SPTEsperantoPlayer returned by
// provideStateObservable() (see SponsorBlockStateObservableHook below) —
// so on those builds this hook simply doesn't attach. The target name uses
// the shared two-name fallback (the plain name no longer resolves; the
// class is registered under its mangled Swift name).
class PlayerServiceObserverHook: ClassHook<NSObject> {
    typealias Group = SponsorBlockGroup
    static var targetName: String { PlayerServiceObservation.targetName }

    func addPlayerObserver(_ observer: AnyObject) {
        orig.addPlayerObserver(observer)
        if !eeveeObserverRegistered {
            eeveeObserverRegistered = true
            writeDebugLog("[SB] registering observer on service")
            orig.addPlayerObserver(eeveeObserver)
        }
    }
}

// Current registration path (mirrors Karaoke's
// KaraokeStateObservableProbeHook): provideStateObservable() is the real
// method on the player service, and the SPTEsperantoPlayer it returns is
// what has addPlayerObserver:. Registering there is what makes
// SponsorBlockSkipper receive state changes again on 9.1.78+/9.2.2 — before
// this, the only registration was the dead hook above, so segment fetching
// and skipping never fired at all (audit A-1-1).
class SponsorBlockStateObservableHook: ClassHook<NSObject> {
    typealias Group = SponsorBlockGroup
    static var targetName: String { PlayerServiceObservation.targetName }

    func provideStateObservable() -> AnyObject {
        let observable = orig.provideStateObservable()
        if !eeveeObserverRegistered {
            eeveeObserverRegistered = true
            eeveeObserver.esperantoPlayer = observable
            writeDebugLog("[SB] registering observer on SPTEsperantoPlayer via provideStateObservable")
            PlayerServiceObservation.register(eeveeObserver, onStateObservable: observable)
        }
        return observable
    }
}

struct SponsorBlockGroup: HookGroup {}

func activateSponsorBlock() {
    let opts = UserDefaults.sponsorBlockOptions
    // Same shared two-name resolution the hooks use, so this log reports
    // "found" whenever either name resolves (the plain name alone reports
    // <missing> on current builds even though the class exists mangled).
    let resolvedName = PlayerServiceObservation.resolvedClass.map { NSStringFromClass($0) }
    writeDebugLog("[SB] activate: enabled=\(opts.enabled ? "Y" : "N") logOnly=\(opts.logOnly ? "Y" : "N") cats=\(opts.enabledCategoriesArray().joined(separator: ",")) server=\(opts.serverURL) class=\(resolvedName ?? "<missing>")")
    SponsorBlockGroup().activate()
    writeDebugLog("[SB] hook group activated")
}
