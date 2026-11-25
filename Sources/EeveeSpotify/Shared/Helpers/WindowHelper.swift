import UIKit

struct WindowHelper {
    static let shared = WindowHelper()

    private init() { }

    // Resolved on every access instead of being captured (and
    // force-unwrapped) once at first use: the window and its root
    // controller are rebuilt when the scene reconnects, so the captured
    // pair went stale, and the force unwrap crashed outright if the
    // helper was first touched before any window existed.
    var window: UIWindow? {
        let sceneWindows = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)

        return sceneWindows.first(where: \.isKeyWindow)
            ?? sceneWindows.first
            ?? UIApplication.shared.windows.first
    }

    var rootViewController: UIViewController? {
        window?.rootViewController
    }

    func present(_ viewController: UIViewController) {
        rootViewController?.present(viewController, animated: true)
    }

    // Callers pass a literal class name, so this is a plain name
    // comparison instead of the old regex match (which also built a
    // class-name string and ran a regex evaluation for every view in
    // the hierarchy). A name matches either the full "Module.Class"
    // string or the unqualified name of a class from any module.
    private func className(of object: AnyObject, matches name: String) -> Bool {
        let fullName = NSStringFromClass(type(of: object))
        return fullName == name || fullName.hasSuffix("." + name)
    }

    func findFirstSubview(_ className: String, in view: UIView) -> UIView? {
        for subview in view.subviews {
            if self.className(of: subview, matches: className) {
                return subview
            }
            if let found = findFirstSubview(className, in: subview) {
                return found
            }
        }

        return nil
    }

    func findFirstViewController(_ className: String) -> UIViewController? {
        guard let rootView = rootViewController?.view else {
            return nil
        }
        var result: UIViewController?

        func searchViews(_ view: UIView) {
            if let viewController = self.viewController(for: view) {
                if self.className(of: viewController, matches: className) {
                    result = viewController
                    return
                }
            }

            for subview in view.subviews {
                searchViews(subview)
            }
        }

        searchViews(rootView)
        return result
    }

    func dismissCurrentViewController() {
        rootViewController?.dismiss(animated: true)
    }

    func overrideUserInterfaceStyle(_ style: UIUserInterfaceStyle) {
        window?.overrideUserInterfaceStyle = style
    }

    func viewController(for view: UIView) -> UIViewController? {
        var responder: UIResponder? = view
        while let nextResponder = responder?.next {
            if let viewController = nextResponder as? UIViewController {
                return viewController
            }
            responder = nextResponder
        }
        return nil
    }
}
