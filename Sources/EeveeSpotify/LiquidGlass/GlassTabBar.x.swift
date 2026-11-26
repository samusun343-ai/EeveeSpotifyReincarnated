import Darwin
import EeveeSpotifyC
import Orion
import UIKit

struct GlassTabBarGroup: HookGroup {}

// A real UITabBar over Spotify's hidden one: iOS 26 renders it as native Liquid Glass, and taps are replayed on Spotify's items.
@available(iOS 26.0, *)
final class GlassSystemTabBar: UITabBar, UITabBarDelegate {
    weak var stock: UIView?
    var sources: [GlassTabSource] = []

    func tabBar(_ tabBar: UITabBar, didSelect item: UITabBarItem) {
        guard let index = items?.firstIndex(of: item), index < sources.count else { return }
        switch sources[index] {
        case .stock(let source):
            CustomTabs.deselect()
            let stockViews = sources.compactMap { entry -> UIView? in
                if case .stock(let view) = entry { return view } else { return nil }
            }
            let selected = stockViews.contains(where: { $0 === source })
                ? GlassTabBar.selectStockTab(source, among: stockViews)
                : false
            if !selected {
                eeveeLog("[EeveeSpotify][Glass] Tab %d '%@' tap FAILED", index, item.title ?? "")
            }
        case .custom(let tab):
            CustomTabs.open(tab)
            if let stock { GlassTabBar.sync(stock) }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            if let stock = self?.stock { GlassTabBar.sync(stock) }
        }
    }
}

enum GlassTabSource: Equatable {
    case stock(UIView)
    case custom(CustomTab)
}

@available(iOS 26.0, *)
enum GlassTabBar {
    static let meter = PerfMeter("Glass][TabBar")
    static weak var stock: UIView?
    // The create menu's state manager, captured by CreateMenuStateManagerHook:
    // a DI-owned service with no other runtime handle from the tab bar.
    static weak var createMenuManager: NSObject?

    static func noteCreateMenuManager(_ manager: NSObject) {
        if createMenuManager !== manager { createMenuManager = manager }
    }
    private static var barKey: UInt8 = 0
    private static var iconCache: [IconKey: UIImage] = [:]
    private static var liveMisses: [IconKey: Int] = [:]
    private static weak var row: UIStackView?
    private static weak var platterView: UIView?
    private static var retries = 0
    private static var waitRetries = 0
    private static var waitScheduled = false
    private static var revealedWhileInactive = false
    private static var launchTabApplied = false
    private static var filmKey: UInt8 = 0
    private static var platterLogged = false
    private static let tintObserver = NotificationCenter.default.addObserver(
        forName: .eeveeAlbumColorChanged, object: nil, queue: .main
    ) { _ in
        if let stock, let bar = objc_getAssociatedObject(stock, &barKey) as? GlassSystemTabBar { applyTint(bar) }
    }
    private static var options = UserDefaults.tabBarOptions
    private static var appliedOptions: TabBarOptions?
    private static let observer = NotificationCenter.default.addObserver(
        forName: .eeveeTabBarOptionsChanged, object: nil, queue: .main
    ) { _ in
        options = UserDefaults.tabBarOptions
        // Launch skips the hook when no custom tab is saved yet, so the first add has to arm it before the bar syncs.
        activateGlassCustomTabs()
        if let stock { sync(stock) }
    }
    // A cold launch can lay the stock bar out before its tabs exist, and sometimes nothing lays it out
    // again until the app is backgrounded and reopened. Becoming active is what used to rescue the bar,
    // so sync here as well and rebuild once if the first reveal happened before the scene was active.
    private static let activationObserver = NotificationCenter.default.addObserver(
        forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main
    ) { _ in
        guard let stock else { return }
        waitRetries = 0
        waitScheduled = false
        if revealedWhileInactive,
           let bar = objc_getAssociatedObject(stock, &barKey) as? GlassSystemTabBar, !bar.isHidden {
            revealedWhileInactive = false
            rebuild(bar)
            eeveeLog("[EeveeSpotify][Glass] Tab bar rebuilt after activation")
        }
        sync(stock)
    }

    static func sync(_ stock: UIView) {
        _ = observer
        _ = tintObserver
        _ = activationObserver
        self.stock = stock
        let bar = systemBar(on: stock)
        guard let row = tabRow(in: stock) else {
            waitForTabs(stock)
            return
        }
        row.superview?.layoutIfNeeded()

        let tabs = row.arrangedSubviews.filter { !$0.isHidden && $0.bounds.width >= 20 }
        guard !tabs.isEmpty else {
            waitForTabs(stock)
            return
        }
        waitRetries = 0
        let labels = Dictionary(tabs.map { (ObjectIdentifier($0), label(in: $0)) }) { first, _ in first }
        func labelOf(_ tab: UIView) -> UILabel? { labels[ObjectIdentifier(tab)] ?? nil }
        func title(_ tab: UIView) -> String? { labelOf(tab)?.text }

        rememberTitles(tabs.compactMap(title), of: tabs.count)
        func key(_ source: GlassTabSource) -> String? {
            switch source {
            case .stock(let tab): return title(tab)
            case .custom(let tab): return tab.key
            }
        }
        func name(_ source: GlassTabSource) -> String? {
            switch source {
            case .stock(let tab): return title(tab)
            case .custom(let tab): return tab.displayTitle
            }
        }
        let customTabs = CustomTabs.available ? options.customTabs : []
        let sources = options.arrange(tabs.map(GlassTabSource.stock) + customTabs.map(GlassTabSource.custom), title: key)
        if sources != bar.sources || appliedOptions != options {
            bar.sources = sources
            appliedOptions = options
            bar.setItems(sources.enumerated().map {
                UITabBarItem(title: options.hideLabels ? nil : name($0.element), image: nil, tag: $0.offset)
            }, animated: false)
        }

        var missing = false
        let items = bar.items ?? []
        let activeFlags = sources.map { source -> Bool in
            guard case .stock(let tab) = source else { return false }
            return isActive(tab, label: labelOf(tab))
        }
        for ((item, entry), active) in zip(zip(items, sources), activeFlags) {
            let shownTitle = options.hideLabels ? nil : name(entry)
            if shownTitle != item.title { item.title = shownTitle }
            switch entry {
            case .custom(let tab):
                if item.image == nil {
                    item.image = tab.outlineImage
                    item.selectedImage = tab.image
                }
            case .stock(let source):
                let stockTitle = title(source)
                let normal = glyph(of: source, title: stockTitle, active: false, isActive: active)
                let filled = glyph(of: source, title: stockTitle, active: true, isActive: active)
                if let image = normal ?? filled, item.image !== image { item.image = image }
                if let image = filled ?? normal, item.selectedImage !== image { item.selectedImage = image }
            }
            missing = missing || item.image == nil
        }
        let custom = CustomTabs.selectedKey.flatMap { key in sources.firstIndex { if case .custom(let tab) = $0 { return tab.key == key } else { return false } } }
        let active = custom ?? activeFlags.firstIndex(of: true)
        if let active, active < items.count, bar.selectedItem !== items[active] { bar.selectedItem = items[active] }
        if missing && retries < 40 {
            retries += 1
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { sync(stock) }
        }

        reveal(bar, over: stock, ready: !missing || retries >= 40)
        applyLaunchTab(tabs, title: title, label: labelOf)
        applyTint(bar)

        let frame = barFrame(in: stock)
        if bar.frame != frame { bar.frame = frame }
        if stock.subviews.last !== bar { stock.bringSubviewToFront(bar) }
    }

    // Spotify's own bar stays up until ours has every icon, so launch never shows an empty glass bar.
    private static func reveal(_ bar: GlassSystemTabBar, over stock: UIView, ready: Bool) {
        guard ready else { return }
        if bar.isHidden {
            for sub in stock.subviews where sub !== bar && sub.alpha != 0 {
                sub.alpha = 0
                sub.isUserInteractionEnabled = false
            }
            bar.alpha = 0
            bar.isHidden = false
            rebuild(bar)
            UIView.animate(withDuration: 0.2) { bar.alpha = 1 }
            eeveeLog("[EeveeSpotify][Glass] Tab bar revealed after %d retries", retries)
        }
        // Revealing before the scene is active can leave the glass platter blank until another layout
        // pass, which is why switching apps used to bring the bar back.
        if stock.window?.windowScene?.activationState != .foregroundActive {
            revealedWhileInactive = true
        }
    }

    // Items laid out while hidden (or before the scene is active) keep squashed or blank labels, so
    // they are rebuilt once the bar is on screen.
    private static func rebuild(_ bar: GlassSystemTabBar) {
        let selected = bar.selectedItem.flatMap { bar.items?.firstIndex(of: $0) }
        let fresh = (bar.items ?? []).map { UITabBarItem(title: $0.title, image: $0.image, selectedImage: $0.selectedImage) }
        bar.setItems(fresh, animated: false)
        if let selected, selected < fresh.count { bar.selectedItem = fresh[selected] }
        bar.setNeedsLayout()
        bar.layoutIfNeeded()
    }

    // A cold launch can run layout before Spotify adds or unhides its tab items, and no later layout
    // pass is guaranteed. Poll briefly while the glass bar is still hidden; once it is revealed the
    // normal layout/tap/foreground paths keep it in sync.
    private static func waitForTabs(_ stock: UIView) {
        guard !waitScheduled, waitRetries < 60,
              let bar = objc_getAssociatedObject(stock, &barKey) as? GlassSystemTabBar, bar.isHidden else { return }
        waitScheduled = true
        waitRetries += 1
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak stock] in
            waitScheduled = false
            guard let stock else { return }
            sync(stock)
        }
    }

    private static func applyTint(_ bar: GlassSystemTabBar) {
        let color = options.albumTint == true ? AlbumColor.current?.withAlphaComponent(0.2) : nil
        guard let platter = platter(in: bar) else {
            if !platterLogged, color != nil {
                platterLogged = true
                eeveeLog("[EeveeSpotify][Glass] Tab bar platter not found, tint skipped")
            }
            return
        }
        let host = (platter as? UIVisualEffectView)?.contentView ?? platter
        let film: UIView
        if let existing = objc_getAssociatedObject(bar, &filmKey) as? UIView {
            film = existing
        } else {
            film = UIView()
            film.isUserInteractionEnabled = false
            objc_setAssociatedObject(bar, &filmKey, film, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        }
        if film.superview !== host { host.insertSubview(film, at: 0) }
        film.frame = host.bounds
        film.layer.cornerRadius = host.bounds.height / 2
        film.layer.cornerCurve = .continuous
        if film.backgroundColor != color {
            UIView.animate(withDuration: 0.4) { film.backgroundColor = color }
        }
    }

    private static func platter(in bar: UIView) -> UIView? {
        if let platterView, platterView.isDescendant(of: bar), platterView.bounds.width > 100 { return platterView }
        platterView = bar.eeveeFirst(UIView.self) {
            $0 !== bar && NSStringFromClass(type(of: $0)).hasSuffix("PlatterView") && $0.bounds.width > 100
        }
        return platterView
    }

    private static func rememberTitles(_ titles: [String], of count: Int) {
        let titles = titles.filter { !$0.isEmpty }
        guard titles.count == count, titles != UserDefaults.knownTabs else { return }
        UserDefaults.knownTabs = titles
    }

    // Selects a stock tab, in layers, most-proven first. There is no gesture-replay
    // fallback in any layer. Replaying the item's tap recognizer (the old EeveeFireTap
    // path) invokes TabBarItemElementUI.handleTap out of band, with no real gesture
    // cycle, on items that are hidden and interaction-disabled under the glass bar.
    // Inside the container's didSelect handler the selection itself completes first;
    // the handler then fans the interaction out through SPTTabBarLogger, and a
    // subscriber's page presentation installs a SwiftUI page's bare
    // UIHostingController as the content of the page-context SPNavigationController,
    // tripping the assertion at SPNavigationController.swift:488 (frame- and
    // instruction-verified against the 9.2.2 binary). A synthetic touch event would
    // not be equivalent to a real tap either: UIKit would never deliver one to the
    // hidden, interaction-disabled stock views, and the coordinator's reaction
    // depends on runtime presentation state — so no form of tap replay returns.
    //
    // Layer 1/2 — direct selection through the container's selectedViewController
    // setter, the same internal containment swap Spotify's own programmatic
    // selection funnels through (it never touches the event fan-out). The mapping
    // from the tapped item to a controller is the delicate part. The container's
    // tabViewControllers getter walks its per-index accessor in tab order, and
    // that accessor materializes a tab's view controller on first use — it asks
    // the tab's TabBarItemViewControllerFactory and caches the result in the
    // container's index-keyed dictionary — so an unvisited tab IS present after
    // one read. What the getter skips is an index whose factory produces no
    // controller at all: an action item such as the creation button, which has
    // no page. Those gaps compact the array, so an ordinal maps directly only
    // when there are no gaps (layer 1), when the gap positions are known
    // exactly (layer 2a), or when the gap positions relative to the active tab
    // pin the target's position down (layer 2b, see tabTarget).
    //
    // Layer 2a knows the gap positions exactly: an action item's item view is
    // the create menu's own view class, not the tab bar's element view, so the
    // gap ordinals are read off the views themselves. When the number of
    // identified action items equals the gap, every page tab's position is
    // ordinal minus the action items before it — wherever the gaps sit,
    // including a gap trailing the active tab, which layer 2b cannot reach.
    // A tap on an identified action item itself selects nothing; it drives
    // the create menu's state manager instead (see triggerCreateMenu).
    //
    // Layer 3 — when no controller can be identified, navigate Spotify's own
    // link dispatcher to the tab's URI: the official navigation entry that deep
    // links and push notifications land on, which runs the whole
    // materialize-and-present machinery itself. This needs the tab's identity,
    // taken from the item's accessibility identifier (locale-independent);
    // without one, the tap fails with a log line rather than a guess. On the
    // 9.2.2 device configuration the items carry no such identifier, so this
    // layer never fired there; it stays as a last resort for configurations
    // that do carry one, behind the direct layers.
    static func selectStockTab(_ source: UIView, among stockViews: [UIView]) -> Bool {
        guard let ordinal = stockViews.firstIndex(where: { $0 === source }) else { return false }
        let stockCount = stockViews.count
        // The anchor for layer 2b is only trusted when exactly one stock item
        // reads as active; zero or several matches mean the heuristic state is
        // not reliable enough to arithmetic on.
        let activeViews = stockViews.indices.filter { isActive(stockViews[$0], label: label(in: stockViews[$0])) }
        let activeOrdinal = activeViews.count == 1 ? activeViews[0] : nil
        let actionOrdinals = Set(stockViews.indices.filter { isActionItem(stockViews[$0]) })

        var fallbackCount: Int?
        for start in [source, stock].compactMap({ $0 }) {
            var responder: UIResponder? = start
            while let current = responder {
                if let container = current as? UIViewController,
                   container.responds(to: NSSelectorFromString("setSelectedViewController:")),
                   let controllers = tabControllers(of: container) {
                    if fallbackCount == nil { fallbackCount = controllers.count }
                    switch tabTarget(in: controllers, ordinal: ordinal, stockCount: stockCount,
                                     activeOrdinal: activeOrdinal, actionOrdinals: actionOrdinals,
                                     container: container) {
                    case .controller(let target):
                        container.setValue(target, forKey: "selectedViewController")
                        return true
                    case .actionItem:
                        return triggerCreateMenu(ordinal: ordinal)
                    case .unmappable:
                        break
                    }
                }
                responder = current.next
            }
        }
        if isActive(source, label: label(in: source)) {
            return true
        }
        if let uri = stockTabURI(for: source), CustomTabs.navigateStockURI(uri) {
            eeveeLog("[EeveeSpotify][Glass] selectStockTab: ordinal %d opened via URI %@", ordinal, uri)
            return true
        }
        if let fallbackCount {
            eeveeLog(
                "[EeveeSpotify][Glass] selectStockTab: %d controllers for %d stock tabs; ordinal %d not mappable",
                fallbackCount, stockCount, ordinal
            )
        } else {
            eeveeLog("[EeveeSpotify][Glass] selectStockTab: no tab container for ordinal %d/%d", ordinal, stockCount)
        }
        logTabDiagnostics(stockViews: stockViews, actionOrdinals: actionOrdinals)
        return false
    }

    private enum TabTarget {
        case controller(UIViewController)
        case actionItem
        case unmappable
    }

    // Maps a tapped stock item to the container's view controller for it, an
    // action item with no controller at all, or unmappable when the position
    // cannot be determined without guessing. See the layer discussion above
    // selectStockTab.
    private static func tabTarget(in controllers: [UIViewController], ordinal: Int, stockCount: Int,
                                  activeOrdinal: Int?, actionOrdinals: Set<Int>,
                                  container: UIViewController) -> TabTarget {
        // No gaps: the array is in tab order and the ordinal is the index.
        if controllers.count == stockCount {
            return ordinal < controllers.count ? .controller(controllers[ordinal]) : .unmappable
        }
        let gap = stockCount - controllers.count
        guard gap > 0 else { return .unmappable }

        // Layer 2a: the gap positions are known exactly when the identified
        // action items account for the whole gap. The target's position is
        // then its ordinal minus the action items before it, wherever the
        // gaps sit. When the active anchor is measurable it must agree with
        // the identified mapping; a disagreement means the identification
        // does not describe this container, and layer 2b decides instead.
        if actionOrdinals.count == gap {
            if actionOrdinals.contains(ordinal) { return .actionItem }
            let pos = ordinal - actionOrdinals.filter { $0 < ordinal }.count
            if pos >= 0, pos < controllers.count {
                var identified: TabTarget? = .controller(controllers[pos])
                if let activeOrdinal, !actionOrdinals.contains(activeOrdinal),
                   container.responds(to: NSSelectorFromString("selectedViewController")),
                   let selected = container.value(forKey: "selectedViewController") as? UIViewController,
                   let selectedPos = controllers.firstIndex(of: selected) {
                    let activePos = activeOrdinal - actionOrdinals.filter { $0 < activeOrdinal }.count
                    if activePos != selectedPos { identified = nil }
                }
                if let identified {
                    eeveeLog(
                        "[EeveeSpotify][Glass] selectStockTab: ordinal %d mapped to position %d via identified action items %@",
                        ordinal, pos, actionOrdinals.sorted().map { String($0) }.joined(separator: ",")
                    )
                    return identified
                }
            }
        }

        // Layer 2b: with gaps in unknown positions, the target's position
        // shifts by the number of gap items before it. The one measurable
        // quantity is the gaps before the active tab: its ordinal minus the
        // selected controller's position in the compacted array. That
        // determines the target's position only when all gaps are known to
        // sit on one side of the active tab.
        guard gap <= 2,
              let activeOrdinal,
              container.responds(to: NSSelectorFromString("selectedViewController")),
              let selected = container.value(forKey: "selectedViewController") as? UIViewController,
              let selectedPos = controllers.firstIndex(of: selected) else { return .unmappable }
        let gapsBeforeActive = activeOrdinal - selectedPos
        guard gapsBeforeActive >= 0, gapsBeforeActive <= gap else { return .unmappable }
        if ordinal == activeOrdinal { return .controller(selected) }
        if ordinal > activeOrdinal, gapsBeforeActive == gap {
            // Every gap is at or before the active tab, so all later tabs
            // shift by the full gap count.
            let pos = ordinal - gap
            return pos > selectedPos && pos < controllers.count ? .controller(controllers[pos]) : .unmappable
        }
        if ordinal < activeOrdinal, gapsBeforeActive == 0 {
            // No gap at or before the active tab, so earlier tabs are
            // unshifted.
            return ordinal < selectedPos ? .controller(controllers[ordinal]) : .unmappable
        }
        return .unmappable
    }

    // An item is an action item when its view (or a view inside it) is the
    // create menu's own item view class. Page tabs use the tab bar's element
    // view instead; the create item's view is a passive display view whose
    // open state the menu's state manager drives, with no page behind it.
    // The class is a property of the view itself, unlike titles (localized)
    // or accessibility identifiers (absent on the 9.2.2 items).
    private static func isActionItem(_ view: UIView) -> Bool {
        view.eeveeFirst(UIView.self) {
            NSStringFromClass(type(of: $0)).hasSuffix("CreateMenuTabBarItemView")
        } != nil
    }

    // Drives the create menu for a tap on the create item. The item has no
    // page, so there is nothing to select; in the stock bar its tap ends at
    // the create menu's state manager (CreateMenuStateManagerImpl), whose
    // setCreateMenuOpen(isOpen:) is the single mutation point for the menu's
    // open state — it stores the flag and notifies the observers that present
    // and dismiss the menu UI and mark the item open. Toggling that entry,
    // as a tap on the item toggles the menu, is the equivalent of the stock
    // tap. The stock caller reaches it through Swift protocol-witness
    // dispatch (there are no ObjC call sites), so the instance cannot be
    // looked up from the bar; CreateMenuStateManagerHook captures it during
    // feature setup instead.
    private static func triggerCreateMenu(ordinal: Int) -> Bool {
        guard let manager = createMenuManager else {
            eeveeLog("[EeveeSpotify][Glass] selectStockTab: ordinal %d is the create item but no create menu state manager captured yet", ordinal)
            return false
        }
        let selector = NSSelectorFromString("setCreateMenuOpenWithIsOpen:")
        guard manager.responds(to: selector) else {
            eeveeLog("[EeveeSpotify][Glass] selectStockTab: captured create menu state manager does not respond to setCreateMenuOpenWithIsOpen:")
            return false
        }
        let isOpen = (manager.value(forKey: "isCreateMenuOpen") as? Bool) ?? false
        typealias SetCreateMenuOpen = @convention(c) (AnyObject, Selector, Bool) -> Void
        unsafeBitCast(manager.method(for: selector), to: SetCreateMenuOpen.self)(manager, selector, !isOpen)
        eeveeLog("[EeveeSpotify][Glass] selectStockTab: ordinal %d create item; menu %@ via state manager", ordinal, isOpen ? "closed" : "opened")
        return true
    }

    // One line per stock item with the properties the mapping layers consult,
    // emitted when a tap fails, so a device log settles what the items
    // actually carry (class, identifiers, title, active/action reads) instead
    // of another round of guessing from afar.
    private static func logTabDiagnostics(stockViews: [UIView], actionOrdinals: Set<Int>) {
        for (index, view) in stockViews.enumerated() {
            let subID = view.eeveeFirst(UIView.self) { !($0.accessibilityIdentifier ?? "").isEmpty }?.accessibilityIdentifier
            eeveeLog(
                "[EeveeSpotify][Glass] tab diag %d: class=%@ a11y=%@ subA11y=%@ title=%@ active=%@ action=%@",
                index,
                NSStringFromClass(type(of: view)),
                view.accessibilityIdentifier ?? "-",
                subID ?? "-",
                label(in: view)?.text ?? "-",
                isActive(view, label: label(in: view)) ? "yes" : "no",
                actionOrdinals.contains(index) ? "yes" : "no"
            )
        }
    }

    // The tab's URI, when the stock item carries one of the tab identifiers
    // the 9.2.2 binary names its tabs by ("home", "search", "your_library").
    // Identifiers are locale-independent, unlike the item titles, which are
    // not in the app bundle's localizations at all. Only URIs present as
    // literal strings in the binary are produced; anything else returns nil
    // and the caller logs the failure instead of guessing.
    private static func stockTabURI(for source: UIView) -> String? {
        let uris = [
            "home": "spotify:home",
            "search": "spotify:search",
            "your_library": "spotify:collection",
            "yourlibrary": "spotify:collection",
            "library": "spotify:collection",
        ]
        var view: UIView? = source
        var depth = 0
        while let current = view, depth < 8 {
            if let id = current.accessibilityIdentifier?.lowercased(), let uri = uris[id] { return uri }
            view = current.superview
            depth += 1
        }
        for sub in source.subviews {
            if let id = sub.accessibilityIdentifier?.lowercased(), let uri = uris[id] { return uri }
        }
        return nil
    }

    private static func tabControllers(of container: UIViewController) -> [UIViewController]? {
        for key in ["tabViewControllers", "viewControllers"] {
            if container.responds(to: NSSelectorFromString(key)),
               let controllers = container.value(forKey: key) as? [UIViewController],
               !controllers.isEmpty {
                return controllers
            }
        }
        return nil
    }

    private static func applyLaunchTab(_ tabs: [UIView], title: (UIView) -> String?, label: (UIView) -> UILabel?) {
        guard !launchTabApplied, tabs.allSatisfy({ !(title($0) ?? "").isEmpty }) else { return }
        launchTabApplied = true
        guard let wanted = options.launchTab,
              let tab = tabs.first(where: { title($0) == wanted }),
              !isActive(tab, label: label(tab)) else { return }
        let fired = selectStockTab(tab, among: tabs)
        eeveeLog("[EeveeSpotify][Glass] Launch tab '%@' %@", wanted, fired ? "opened" : "FAILED")
    }

    private static func isActive(_ tab: UIView, label: UILabel?) -> Bool {
        iconIsActive(tab) == true || label?.textColor.isWhite == true
    }

    // Spotify lays its iPad tab bar out as a short full-width strip, well under the height a tab bar
    // needs for an icon plus a label. Inheriting that height squashes the items, so the glass bar gets
    // a floor of its own and is centred on Spotify's strip to keep the row where it was.
    // A bare 49pt strip is not enough on iOS 26: the glass platter is 62pt and squeezes its
    // labels into whatever height it is given. Grow upward instead of centring so banners that
    // shrink the strip (offline/data-saver) cannot cover the labels.
    private static let minimumBarHeight: CGFloat = 62

    // How much taller the glass bar had to grow than Spotify's current strip, so the now-playing
    // bar can move up by the same amount and keep its usual gap above the tab bar.
    static var extraHeight: CGFloat {
        guard let stock else { return 0 }
        let bounds = stock.bounds
        guard bounds.height > 0, bounds.height < minimumBarHeight else { return 0 }
        return minimumBarHeight - bounds.height
    }

    private static func barFrame(in stock: UIView) -> CGRect {
        let bounds = stock.bounds
        guard bounds.height > 0, bounds.height < minimumBarHeight else { return bounds }
        return CGRect(x: bounds.minX, y: bounds.maxY - minimumBarHeight,
                      width: bounds.width, height: minimumBarHeight)
    }

    private static func systemBar(on stock: UIView) -> GlassSystemTabBar {
        if let bar = objc_getAssociatedObject(stock, &barKey) as? GlassSystemTabBar { return bar }
        let bar = GlassSystemTabBar(frame: barFrame(in: stock))
        bar.isHidden = true
        bar.overrideUserInterfaceStyle = .dark
        bar.tintColor = UIColor(red: 0.12, green: 0.84, blue: 0.38, alpha: 1)
        bar.delegate = bar
        bar.stock = stock
        // The bar is a touch taller than Spotify's strip on iPad, so it must not be clipped away.
        stock.clipsToBounds = false
        retries = 0
        waitRetries = 0
        waitScheduled = false
        revealedWhileInactive = false
        objc_setAssociatedObject(stock, &barKey, bar, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        stock.addSubview(bar)
        return bar
    }

    private static func tabRow(in stock: UIView) -> UIStackView? {
        if let row, row.isDescendant(of: stock), row.arrangedSubviews.count >= 3 { return row }
        row = firstRow(in: stock)
        return row
    }

    private static func firstRow(in view: UIView) -> UIStackView? {
        var queue = view.subviews
        while !queue.isEmpty {
            let next = queue.removeFirst()
            if let stack = next as? UIStackView, stack.arrangedSubviews.count >= 3 { return stack }
            if !(next is GlassSystemTabBar) { queue += next.subviews }
        }
        return nil
    }

    private static func label(in item: UIView) -> UILabel? {
        item.eeveeFirst(UILabel.self) { !($0.text ?? "").isEmpty }
    }

    private static func iconView(in item: UIView) -> UIView? {
        item.eeveeFirst(UIView.self) { NSStringFromClass(type(of: $0)) == "SPTEncoreIconView" && $0.bounds.width >= 2 }
    }

    private static func iconIsActive(_ item: UIView) -> Bool? {
        guard let icon = iconView(in: item), icon.responds(to: NSSelectorFromString("isActive")) else { return nil }
        return icon.value(forKey: "isActive") as? Bool
    }

    private struct IconKey: Hashable {
        let title: String
        let active: Bool
        var file: String { active ? "\(title)-active" : title }
    }

    // Disk icons stand in until a live render replaces them, or for good once live renders keep failing.
    private static func glyph(of item: UIView, title: String?, active: Bool, isActive: Bool) -> UIImage? {
        guard let title else { return nil }
        let key = IconKey(title: title, active: active)
        if let cached = iconCache[key] { return cached }
        let stored = TabIconStore.load(key.file)
        guard stored == nil || liveMisses[key, default: 0] < 20 else { return stored }
        if let image = iconView(in: item).flatMap({ EeveeEncoreIconImage($0, active) ?? (isActive == active ? EeveeRenderTemplate($0) : nil) }) {
            TabIconStore.save(image, for: key.file)
            iconCache[key] = image
            return image
        }
        liveMisses[key, default: 0] += 1
        return stored
    }
}

class GlassTabBarViewHook: ClassHook<UIView> {
    typealias Group = GlassTabBarGroup
    static let targetName = "_TtC23NavigationUI_TabBarImpl10TabBarView"

    func layoutSubviews() {
        orig.layoutSubviews()
        guard #available(iOS 26.0, *) else { return }
        activateGlassCustomTabs()
        GlassTabBar.meter.measure { GlassTabBar.sync(target) }
    }
}

class GlassTabBarContainerHook: ClassHook<UIViewController> {
    typealias Group = GlassTabBarGroup
    static let targetName = "_TtC23NavigationUI_TabBarImpl19TabBarContainerImpl"

    func setSelectedViewController(_ controller: UIViewController) {
        orig.setSelectedViewController(controller)
        guard #available(iOS 26.0, *) else { return }
        DispatchQueue.main.async {
            CustomTabs.recheckSelection()
            guard let stock = GlassTabBar.stock else { return }
            GlassTabBar.meter.measure { GlassTabBar.sync(stock) }
        }
    }
}

// Captures the create menu's state manager so a glass tap on the create item
// can drive the same state entry the stock tap ends at (see
// GlassTabBar.triggerCreateMenu). The manager is a DI-owned service; its
// observer registration, button-view assignment and state changes all run
// during create-feature setup, before a glass tap on the item can happen.
// The hooks only record the instance and call through unchanged.
class CreateMenuStateManagerHook: ClassHook<NSObject> {
    typealias Group = GlassTabBarGroup
    static let targetName = "_TtC23CreateMenu_PlatformImpl26CreateMenuStateManagerImpl"

    func setCreateMenuOpenWithIsOpen(_ isOpen: Bool) {
        orig.setCreateMenuOpenWithIsOpen(isOpen)
        GlassTabBar.noteCreateMenuManager(target)
    }

    func addObserverWithObserver(_ observer: AnyObject) {
        orig.addObserverWithObserver(observer)
        GlassTabBar.noteCreateMenuManager(target)
    }

    func setCreateButtonView(_ view: UIView?) {
        orig.setCreateButtonView(view)
        GlassTabBar.noteCreateMenuManager(target)
    }
}

struct CustomTabsGroup: HookGroup {}

enum CustomTabs {
    static weak var dispatcher: NSObject?
    fileprivate(set) static var available = false
    private(set) static var selectedKey: String?
    private static weak var page: UIViewController?
    private static var watch: Timer?
    private static let navigateShort = NSSelectorFromString("navigateToURI:options:interactionID:")
    private static let navigateFull = NSSelectorFromString("navigateToURI:options:reason:completionHandler:resultHandler:")

    // Spotify's own link dispatcher keeps the URI in-app; the system route would ask to open the other Spotify install.
    static func open(_ tab: CustomTab) {
        guard let url = URL(string: tab.uri) else {
            eeveeLog("[EeveeSpotify][CustomTabs] '%@' has an invalid URI %@", tab.title, tab.uri)
            return
        }
        guard let dispatcher else {
            eeveeLog("[EeveeSpotify][CustomTabs] '%@' not opened: link dispatcher not captured yet", tab.title)
            return
        }
        if dispatcher.responds(to: navigateShort) {
            typealias Navigate = @convention(c) (NSObject, Selector, NSURL, Int64, AnyObject?) -> Void
            unsafeBitCast(dispatcher.method(for: navigateShort), to: Navigate.self)(dispatcher, navigateShort, url as NSURL, 0, nil)
        } else if dispatcher.responds(to: navigateFull) {
            let reason: AnyObject? = {
                guard let reasonClass = NSClassFromString("SPTUBINavigationReason") else { return nil }
                let allocSel = NSSelectorFromString("alloc")
                let initSel = NSSelectorFromString("initWithSourceApplication:interactionID:")
                guard reasonClass.responds(to: allocSel), reasonClass.instancesRespond(to: initSel) else { return nil }
                guard let msgSend = dlsym(dlopen(nil, RTLD_LAZY), "objc_msgSend") else { return nil }
                typealias AllocFn = @convention(c) (AnyClass, Selector) -> Unmanaged<AnyObject>
                let allocFn = unsafeBitCast(msgSend, to: AllocFn.self)
                let raw = allocFn(reasonClass, allocSel)
                typealias InitFn = @convention(c) (Unmanaged<AnyObject>, Selector, AnyObject?, AnyObject?) -> Unmanaged<AnyObject>?
                let initFn = unsafeBitCast(msgSend, to: InitFn.self)
                guard let result = initFn(raw, initSel, nil, nil) else {
                    raw.release()
                    return nil
                }
                return result.takeRetainedValue()
            }()
            guard let reason else {
                eeveeLog("[EeveeSpotify][CustomTabs] '%@' not opened: navigation reason could not be created", tab.title)
                return
            }
            typealias Navigate = @convention(c) (NSObject, Selector, NSURL, Int64, AnyObject?, AnyObject?, AnyObject?) -> Void
            unsafeBitCast(dispatcher.method(for: navigateFull), to: Navigate.self)(dispatcher, navigateFull, url as NSURL, 0, reason, nil, nil)
        } else {
            eeveeLog("[EeveeSpotify][CustomTabs] '%@' not opened: link dispatcher has no known navigation method", tab.title)
            return
        }
        select(tab)
    }

    // Opens a stock tab through the link dispatcher — the same official
    // navigation entry deep links land on — for the cases where the tab's
    // view controller cannot be identified in the tab container (see
    // GlassTabBar.selectStockTab). Unlike open(_:), this does not touch the
    // custom-tab selection state: the destination is a stock tab, and the
    // caller has already cleared any custom selection. Returns whether the
    // navigation was dispatched.
    static func navigateStockURI(_ uri: String) -> Bool {
        guard let url = URL(string: uri) else { return false }
        guard let dispatcher else {
            eeveeLog("[EeveeSpotify][Glass] Stock tab %@ not opened: link dispatcher not captured yet", uri)
            return false
        }
        if dispatcher.responds(to: navigateShort) {
            typealias Navigate = @convention(c) (NSObject, Selector, NSURL, Int64, AnyObject?) -> Void
            unsafeBitCast(dispatcher.method(for: navigateShort), to: Navigate.self)(dispatcher, navigateShort, url as NSURL, 0, nil)
            return true
        } else if dispatcher.responds(to: navigateFull) {
            let reason: AnyObject? = {
                guard let reasonClass = NSClassFromString("SPTUBINavigationReason") else { return nil }
                let allocSel = NSSelectorFromString("alloc")
                let initSel = NSSelectorFromString("initWithSourceApplication:interactionID:")
                guard reasonClass.responds(to: allocSel), reasonClass.instancesRespond(to: initSel) else { return nil }
                guard let msgSend = dlsym(dlopen(nil, RTLD_LAZY), "objc_msgSend") else { return nil }
                typealias AllocFn = @convention(c) (AnyClass, Selector) -> Unmanaged<AnyObject>
                let allocFn = unsafeBitCast(msgSend, to: AllocFn.self)
                let raw = allocFn(reasonClass, allocSel)
                typealias InitFn = @convention(c) (Unmanaged<AnyObject>, Selector, AnyObject?, AnyObject?) -> Unmanaged<AnyObject>?
                let initFn = unsafeBitCast(msgSend, to: InitFn.self)
                guard let result = initFn(raw, initSel, nil, nil) else {
                    raw.release()
                    return nil
                }
                return result.takeRetainedValue()
            }()
            guard let reason else {
                eeveeLog("[EeveeSpotify][Glass] Stock tab %@ not opened: navigation reason could not be created", uri)
                return false
            }
            typealias Navigate = @convention(c) (NSObject, Selector, NSURL, Int64, AnyObject?, AnyObject?, AnyObject?) -> Void
            unsafeBitCast(dispatcher.method(for: navigateFull), to: Navigate.self)(dispatcher, navigateFull, url as NSURL, 0, reason, nil, nil)
            return true
        } else {
            eeveeLog("[EeveeSpotify][Glass] Stock tab %@ not opened: link dispatcher has no known navigation method", uri)
            return false
        }
    }

    // The page is pushed on the current Spotify tab, so the custom tab stays selected only while that page is on screen.
    private static func select(_ tab: CustomTab) {
        selectedKey = tab.key
        page = nil
        watch?.invalidate()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
            guard selectedKey == tab.key else { return }
            page = topController()
            watch?.invalidate()
            // The page is captured once, up front. At the old 0.5s
            // cadence, a not-yet-captured page repeated the full
            // scene/window walk in topController() on every tick; now
            // the walk only repeats (at a thinned 2s cadence) while the
            // capture is still missing, and tab switches re-run the
            // check immediately via recheckSelection().
            watch = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { _ in
                recheckSelection(captureIfNeeded: true)
            }
            watch?.fire()
        }
    }

    // Drops the custom-tab selection once the pushed page's view has
    // left its window (popped, or its tab switched away). Driven by the
    // watch timer and, as an event, by tab-selection changes.
    static func recheckSelection(captureIfNeeded: Bool = false) {
        guard selectedKey != nil else { return }
        guard let current = page else {
            if captureIfNeeded {
                page = topController()
            }
            return
        }
        guard current.view.window == nil else { return }
        deselect()
    }

    static func deselect() {
        guard selectedKey != nil else { return }
        selectedKey = nil
        page = nil
        watch?.invalidate()
        watch = nil
        if #available(iOS 26.0, *), let stock = GlassTabBar.stock { GlassTabBar.sync(stock) }
    }

    private static func topController() -> UIViewController? {
        let window = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows).first(where: \.isKeyWindow)
        var controller = window?.rootViewController
        while let current = controller {
            if let presented = current.presentedViewController { controller = presented; continue }
            if let nav = current as? UINavigationController, let top = nav.topViewController { controller = top; continue }
            if let visible = current.children.last(where: { $0.viewIfLoaded?.window != nil && $0.view.bounds.height > 300 }) {
                controller = visible
                continue
            }
            return current
        }
        return nil
    }

    static func capture(_ object: NSObject, _ via: String) {
        guard dispatcher !== object else { return }
        dispatcher = object
        eeveeLog("[EeveeSpotify][CustomTabs] Link dispatcher captured via %@", via)
    }
}

class LinkDispatcherHook: ClassHook<NSObject> {
    typealias Group = CustomTabsGroup
    static let targetName = "SPTLinkDispatcherImplementation"

    func setMainUILoaded(_ loaded: Bool) {
        orig.setMainUILoaded(loaded)
        CustomTabs.capture(target, "setMainUILoaded")
    }

    func navigateToURI(_ uri: NSURL, options: Int64, interactionID: AnyObject?) {
        CustomTabs.capture(target, "navigation")
        orig.navigateToURI(uri, options: options, interactionID: interactionID)
    }

    func navigateToURI(_ uri: NSURL, options: Int64, reason: AnyObject?, completionHandler: AnyObject?, resultHandler: AnyObject?) {
        CustomTabs.capture(target, "navigation")
        orig.navigateToURI(uri, options: options, reason: reason, completionHandler: completionHandler, resultHandler: resultHandler)
    }
}

func activateGlassCustomTabs() {
    guard !CustomTabs.available else { return }
    let glass = LiquidGlass.launchOptions
    let count = UserDefaults.tabBarOptions.customTabs.count
    guard glass.enabled, glass.tabBar, count > 0 else { return }
    guard #available(iOS 26.0, *) else { return }
    let start = CFAbsoluteTimeGetCurrent()
    let found = NSClassFromString(LinkDispatcherHook.targetName) != nil
    if found {
        CustomTabsGroup().activate()
        CustomTabs.available = true
    }
    eeveeLog("[EeveeSpotify][CustomTabs] %d tabs, link dispatcher %@ (%.2f ms)", count, found ? "hooked" : "MISSING, custom tabs hidden",
             (CFAbsoluteTimeGetCurrent() - start) * 1000)
}
