import Foundation
import Orion

private let traceNet:   Bool = false
private let traceNotif: Bool = false
// TESTING: dumps ad-class methods/ivars on launch.
private let traceAds:   Bool = false
// TESTING: dumps SPTPlayer* surface + widens notif filter to include
// "player/track/position" so SponsorBlock can find episode-uri/seek path.
private let traceSB:    Bool = false
// TESTING: dumps SmartShuffle / FreeShuffle service classes so we can
// pick real selectors for a TrueShuffle hook on this Spotify version.
private let traceShuffle: Bool = false

private let importantNotifSubstrings: [String] = [
    "premium", "product", "account", "session", "login", "logout",
    "authState", "authSession", "subscription"
]

private let sbNotifSubstrings: [String] = [
    "player", "track", "position", "episode", "playback", "queue"
]

// All probe log output is funneled through this one serial queue.
// Probes sit on hot paths (every notification post, every session
// task resume) and run at points where the caller's thread should
// not pay for NSLog's formatting and log-daemon I/O. So a probe
// makes its keep/drop decision on the spot, captures the finished
// values, and hands the NSLog itself to this queue. The set, text,
// and per-source order of emitted lines are unchanged — only the
// emitting thread moves. (Ordering across concurrent posters was
// never guaranteed anyway: NSLog calls from several threads
// interleave just as appends to this queue do.)
private let probeLogQueue = DispatchQueue(label: "EeveeSpotify.probe.log", qos: .utility)

class TaskResumeProbeHook: ClassHook<NSObject> {
    typealias Group = ProbeNetGroup
    static let targetName = "NSURLSessionTask"

    func resume() {
        if traceNet, let task = target as? URLSessionTask,
           let url = task.currentRequest?.url ?? task.originalRequest?.url {
            let host = url.host ?? "?"
            if host.contains("spotify") || host.contains("scdn") || host.contains("spclient")
                || host.contains("googleapis") || host.contains("apresolve") {
                let method = task.currentRequest?.httpMethod ?? "?"
                let path = url.path
                // Same line, emitted from probeLogQueue: resume()
                // should not block on log I/O (see probeLogQueue).
                probeLogQueue.async { NSLog("[PROBE][NET] >> %@ %@%@", method, host, path) }
            }
        }
        orig.resume()
    }
}

// Notification-post probe. Deliberately kept as light as possible:
//
// - Only the two name-only post variants are hooked. The
//   postNotificationName:object:userInfo: variant is NOT hooked: it is
//   the most-called post API in the app, and hooking it forces the
//   userInfo dictionary to bridge into Swift on every single post,
//   app-wide. Its only extra payload was the userInfo *key names*,
//   which were logged but never used for any decision — the
//   notification name alone carries the auth/product signal this
//   probe exists to trace.
// - Fast path first: with traceNotif on, every post is logged and no
//   matching work happens at all. With it off, the name is lowercased
//   once and checked against the precomputed lowercase pattern lists;
//   non-matching posts go straight to orig with no logging.
// - Even a matching post does no log I/O itself: the keep/drop
//   decision is made on the posting thread, but the NSLog runs on
//   probeLogQueue, so the post path costs one decision plus one
//   queue append. The emitted lines are identical to the old
//   synchronous ones.
//
// Caveat: this lightening only reduces the per-post cost. The
// 2026-11-25 playback-start deadlock was not caused by the hook being
// heavy — it was caused by the hook *existing* in every post path at
// all (Spotify's playback threads blocked inside the hooked post's
// observer delivery while the main thread waited on those same
// queues). An enabled probe therefore still carries structural risk;
// the real fix is that ProbeNotifGroup is only activated when
// traceNotif is on, and traceNotif is false in normal builds.
class NotifPostHook: ClassHook<NSObject> {
    typealias Group = ProbeNotifGroup
    static let targetName = "NSNotificationCenter"

    // The pattern lists are already lowercase literals, so matching is
    // one lowercasing of the incoming name plus substring checks.
    private static func isImportant(_ name: String) -> Bool {
        let lower = name.lowercased()
        if importantNotifSubstrings.contains(where: { lower.contains($0) }) {
            return true
        }
        // traceSB only widens the filter of an already-active probe;
        // it never activates the probe by itself (see activateEeveeProbes).
        if traceSB {
            return sbNotifSubstrings.contains { lower.contains($0) }
        }
        return false
    }

    private static func trace(_ name: String) {
        if traceNotif || isImportant(name) {
            probeLogQueue.async { NSLog("[PROBE][NOTIF] %@", name) }
        }
    }

    // Don't touch notification.object — can be a zombie ref. type(of:) on a
    // dealloc'd NSObject dispatches to __NSGenericDeallocHandler and aborts.
    func postNotification(_ notification: Notification) {
        Self.trace(notification.name.rawValue)
        orig.postNotification(notification)
    }

    func postNotificationName(_ aName: NSNotification.Name, object anObject: Any?) {
        Self.trace(aName.rawValue)
        orig.postNotificationName(aName, object: anObject)
    }
}

struct ProbeNetGroup: HookGroup {}
struct ProbeNotifGroup: HookGroup {}

private let classesToDump: [String] = [
    "Authentication_ForcedLogoutImpl.ForcedLogoutDaemon",
    "Authentication_AuthImpl.AccessTokenRevokerDaemon",
    "Authentication_AuthImpl.AccessTokenUpdateTask",
    "Authentication_AuthImpl.AuthTaskV",
    "Authentication_AuthImpl.Login",
    "Authentication_LogoutAPI.LogoutService",
    "Authentication_ReloginAPI.ReloginService",
    "Authentication_AuthAPI.LogoutNotifierService",
    "Authentication_AuthAPI.AuthLoginNotifierService",
    "Connectivity_SessionImpl.SessionServiceImpl",
    "Connectivity_SessionImpl.SessionFactoryImpl",
]

// TESTING: ad-class targets for traceAds dump.
private let adClassesToDump: [String] = [
    "_TtC19AdsPlatform_AdsImpl14AdsServiceImpl",
    "_TtC19AdsPlatform_AdsImpl16AdPreviewHandler",
    "_TtC29AdsNowPlaying_EmbeddedNPVImpl22EmbeddedNPVServiceImpl",
    "_TtC29AdsNowPlaying_InStreamAdsImpl18InStreamAdsService",
    "_TtC20NativeAds_LoggerImpl26NativeAdsLoggerServiceImpl",
    "_TtC21NativeAds_ElementImpl27NativeAdsElementServiceImpl",
    "_TtC48AdsEmbedded_AdsSponsoredContextNPBAttachmentImpl25AdModelChangedEventSource",
    "_TtC16Home_EvoPageImpl27SectionProviderRegistryImpl",
    "_TtC16Home_EvoPageImpl24AdPreviewSectionProvider",
    "_TtC16Home_EvoPageImpl31VideoBrandAdITGCSectionProvider",
    "_TtC16Home_EvoPageImpl33DisplayBrandAdITGCSectionProvider",
]

private let runClassDump = false

private let shuffleClassesToDump: [String] = [
    "FreeShuffle_RecommendationsImpl.FreeShuffleRecommendationsServiceImplementation",
    "FreeShuffle_RecommendationsImpl.FreeSmartShuffleServiceImplementation",
    "FreeShuffle_RecommendationsImpl.FreeSmartShuffleConfigurationImplementation",
    "FreeShuffle_RecommendationsImpl.PlayingTrackImplementation",
    "FreeShuffle_RecommendationsImpl.PlayingTrackProviderImplementation",
    "FreeShuffle_RecommendationsImpl.PlayingTrackResolverImplementation",
    "FreeShuffle_RecommendationsImpl.PlayingTrackContextProviderImplementation",
    "FreeShuffle_RecommendationsImpl.ApplicationStateObserverImplementation",
    "FreeShuffle_RecommendationsImpl.TestManagerImplementation",
    "SmartShuffle_CoreImpl.SmartShuffleCoreServiceImpl",
    "SmartShuffle_CoreImpl.SmartShuffleHandlerImplementation",
    "SmartShuffle_CoreImpl.CentralizedShuffleStateDataLoaderImplementation",
    "SmartShuffle_CoreImpl.SmartShufflePredicatesImplementation",
    "SmartShuffle_CoreImpl.SmartShuffleSignalsHandlerImplementation",
    "SmartShuffle_CoreImpl.SmartShufflePlayerContextControllerImplementation",
    "SmartShuffle_CoreImpl.SmartShuffleStateReactiveValue",
    "SmartShuffle_CoreImpl.SmartShuffleHandlerObserverWrapper",
    "Queue_ViewImpl.QueueTrackShuffledList",
]

private let sbClassesToDump: [String] = [
    "SPTVideoCoordinatorPlayerRouter",
    "SPTVideoCoordinatorDataSavingVideoDisabler",
    "AdsPlatform_ComScoreImpl.ComScorePlayerObserver",
    "_TtC24AdsPlatform_ComScoreImpl22ComScorePlayerObserver",
    "Player_ReactiveValueKit.ReactivePlayerState",
]
private var classDumpDone = false

private func dumpClass(_ name: String) {
    guard let cls = NSClassFromString(name) else {
        NSLog("[PROBE][CLASS] %@: <not found>", name)
        return
    }
    NSLog("[PROBE][CLASS] %@", name)
    var count: UInt32 = 0
    if let methods = class_copyMethodList(cls, &count) {
        for i in 0..<Int(count) {
            let m = methods[i]
            let sel = method_getName(m)
            let enc = method_getTypeEncoding(m).map { String(cString: $0) } ?? "?"
            NSLog("[PROBE][CLASS]   - %@  (enc=%@)", NSStringFromSelector(sel), enc)
        }
        free(methods)
    }
    if let metaCls = object_getClass(cls) {
        var ccount: UInt32 = 0
        if let cmethods = class_copyMethodList(metaCls, &ccount) {
            for i in 0..<Int(ccount) {
                let m = cmethods[i]
                let sel = method_getName(m)
                let enc = method_getTypeEncoding(m).map { String(cString: $0) } ?? "?"
                NSLog("[PROBE][CLASS]   + %@  (enc=%@)", NSStringFromSelector(sel), enc)
            }
            free(cmethods)
        }
    }
    var ivCount: UInt32 = 0
    if let ivars = class_copyIvarList(cls, &ivCount) {
        for i in 0..<Int(ivCount) {
            let iv = ivars[i]
            let nm = ivar_getName(iv).map { String(cString: $0) } ?? "?"
            let tp = ivar_getTypeEncoding(iv).map { String(cString: $0) } ?? "?"
            NSLog("[PROBE][CLASS]   * %@ :: %@", nm, tp)
        }
        free(ivars)
    }
}

private func dumpClassesOnce() {
    guard runClassDump || traceAds || traceSB || traceShuffle, !classDumpDone else { return }
    classDumpDone = true
    if runClassDump {
        for n in classesToDump { dumpClass(n) }
    }
    // TESTING: ad-class dump (independent of runClassDump)
    if traceAds {
        NSLog("[PROBE][ADS] === ad class dump begin ===")
        for n in adClassesToDump { dumpClass(n) }
        NSLog("[PROBE][ADS] === ad class dump end ===")
    }
    // SponsorBlock: dump player classes to find episode-uri / position / seek path.
    if traceSB {
        NSLog("[PROBE][SB] === sponsorblock class dump begin ===")
        for n in sbClassesToDump { dumpClass(n) }
        NSLog("[PROBE][SB] === sponsorblock class dump end ===")
    }
    // TrueShuffle: dump FreeShuffle / SmartShuffle service surface.
    // NSClassFromString("Module.Class") is unreliable for Swift; iterate the
    // runtime and dump methods inline when the name matches a target suffix.
    if traceShuffle {
        let targetSuffixes: [String] = [
            ".FreeShuffleRecommendationsServiceImplementation",
            ".FreeSmartShuffleServiceImplementation",
            ".FreeSmartShuffleConfigurationImplementation",
            ".PlayingTrackProviderImplementation",
            ".PlayingTrackResolverImplementation",
            ".PlayingTrackContextProviderImplementation",
            ".SmartShuffleCoreServiceImpl",
            ".SmartShuffleHandlerImplementation",
            ".CentralizedShuffleStateDataLoaderImplementation",
            ".SmartShufflePredicatesImplementation",
            ".SmartShuffleSignalsHandlerImplementation",
            ".SmartShufflePlayerContextControllerImplementation",
            ".SmartShuffleStateReactiveValue",
            ".SmartShuffleAllowedSettingImpl",
            ".SmartShuffleAllowedSettingAlwaysEnabled",
            ".ShuffleSettingsServiceImpl",
            ".MixingShuffleHandlerImpl",
            ".ShuffledListEffectHandler",
            ".ReshuffleEffectHandler",
            ".QueueTrackShuffledList",
            ".SmartShufflePlayerAdapter",
            ".SmartShuffleInteropImpl",
            ".ShuffleControllerImpl",
            ".HeaderShuffleActionManager",
            ".ContextualShuffleService",
            ".ContextualShuffleLocalEntityModelImpl",
            ".ShuffleManagerImpl",
            ".ShuffleElementServiceImpl",
        ]
        NSLog("[PROBE][SHUF] === shuffle class dump begin ===")
        let total = objc_getClassList(nil, 0)
        let buf = UnsafeMutablePointer<AnyClass>.allocate(capacity: Int(total))
        defer { buf.deallocate() }
        let cn = objc_getClassList(AutoreleasingUnsafeMutablePointer<AnyClass>(buf), total)
        for i in 0..<Int(cn) {
            let raw = UnsafeRawPointer(buf).load(fromByteOffset: i * MemoryLayout<UnsafeRawPointer>.size,
                                                  as: UnsafeRawPointer.self)
            let cls: AnyClass = unsafeBitCast(raw, to: AnyClass.self)
            let nm = String(cString: class_getName(cls))
            let hit = targetSuffixes.first { nm.hasSuffix($0) }
            guard hit != nil else { continue }
            NSLog("[PROBE][SHUF][CLS] %s", class_getName(cls))
            var mc: UInt32 = 0
            if let methods = class_copyMethodList(cls, &mc) {
                for j in 0..<Int(mc) {
                    let m = methods[j]
                    let sel = method_getName(m)
                    let enc = method_getTypeEncoding(m).map { String(cString: $0) } ?? "?"
                    NSLog("[PROBE][SHUF]   - %@  (enc=%@)", NSStringFromSelector(sel), enc)
                }
                free(methods)
            }
            var ic: UInt32 = 0
            if let ivars = class_copyIvarList(cls, &ic) {
                for j in 0..<Int(ic) {
                    let iv = ivars[j]
                    let inm = ivar_getName(iv).map { String(cString: $0) } ?? "?"
                    let itp = ivar_getTypeEncoding(iv).map { String(cString: $0) } ?? "?"
                    NSLog("[PROBE][SHUF]   * %@ :: %@", inm, itp)
                }
                free(ivars)
            }
        }
        NSLog("[PROBE][SHUF] === shuffle class dump end ===")
    }

    // The full class-list scan below belongs to the general class dump
    // only. It used to run whenever *any* dump flag was on (asking for
    // the ad-class dump also paid for a whole-runtime scan); gate it on
    // runClassDump so each flag pays only for its own dump.
    guard runClassDump else { return }

    // objc_copyClassList returns AutoreleasingUnsafeMutablePointer; subscripting
    // triggers retain/autorelease msgSend which aborts on iOS 26's baked-in
    // __NSGenericDeallocHandler entries. objc_getClassList with a raw buffer
    // sidesteps it.
    let total = objc_getClassList(nil, 0)
    NSLog("[PROBE][CLASSLIST] scanning %d classes…", Int(total))
    let buf = UnsafeMutablePointer<AnyClass>.allocate(capacity: Int(total))
    defer { buf.deallocate() }
    let n = objc_getClassList(AutoreleasingUnsafeMutablePointer<AnyClass>(buf), total)
    for i in 0..<Int(n) {
        let raw = UnsafeRawPointer(buf).load(fromByteOffset: i * MemoryLayout<UnsafeRawPointer>.size,
                                              as: UnsafeRawPointer.self)
        let cstr = class_getName(unsafeBitCast(raw, to: AnyClass.self))
        let nm = String(cString: cstr)
        if nm.contains("ProductState") || nm.contains("AccountAttribute")
            || nm.contains("PremiumOnly") || nm.contains("Subscription")
            || (nm.contains("SPT") && (nm.contains("Account") || nm.contains("User")))
            || nm.contains("Esperanto") || nm.contains("ProductType") {
            NSLog("[PROBE][CLASSLIST] %s", cstr)
        }
    }
    NSLog("[PROBE][CLASSLIST] done")
}

func activateEeveeProbes() {
    let netOn = traceNet
    // The notification probe hooks NSNotificationCenter posts app-wide.
    // It must only be active when a trace flag that actually consumes
    // it is on: left always-on, it sits in the post path of every Spotify
    // thread while doing nothing (all trace flags are false), and the
    // 2026-11-25 crash log (0x8BADF00D watchdog) shows Spotify's playback
    // threads blocked inside the hooked post's observer delivery while the
    // main thread waits on those same queues — a cross-thread deadlock at
    // playback start.
    //
    // traceNotif is the ONLY flag that may activate this probe. traceSB
    // must never arm it by itself: an earlier version of this gate used
    // `traceNotif || traceSB`, so a build made just to investigate
    // SponsorBlock (traceSB) silently re-armed the notification hook —
    // with its filter widened to player/track notifications, the exact
    // traffic that deadlocked — and recreated the crash configuration.
    // traceSB now only widens the filter inside an already-active probe.
    let notifOn = traceNotif
    NSLog("[PROBE] activating: net=%@ notif=%@ ads=%@ sb=%@",
          netOn ? "on" : "off",
          notifOn ? "on" : "off",
          traceAds ? "on" : "off",
          traceSB ? "on" : "off")
    if netOn { ProbeNetGroup().activate() }
    if notifOn { ProbeNotifGroup().activate() }
    // The class dump is one-shot debug output (runtime introspection
    // plus a long run of NSLog). Run it on the probe log queue so
    // activation never pays for it synchronously; the emitted lines
    // are unchanged. classDumpDone is only touched inside
    // dumpClassesOnce, which now only ever runs on that serial queue,
    // so the one-shot guard stays race-free.
    probeLogQueue.async { dumpClassesOnce() }
}
