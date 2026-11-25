import Orion
import UIKit
import SwiftUI

struct DarkPopUps: HookGroup { }

class EncoreLabelHook: ClassHook<UIView> {
    typealias Group = DarkPopUps

    static var targetName: String {
        return HookTargetNameHelper.encoreLabel
    }

    func intrinsicContentSize() -> CGSize {
        if let viewController = WindowHelper.shared.viewController(for: target),
            NSStringFromClass(type(of: viewController)) == HookTargetNameHelper.popUpContainer
        {
            if let firstSubview = target.subviews.first {
                let label = Dynamic.convert(firstSubview, to: UILabel.self)

                if !label.hasParent(matching: "Primary") {
                    label.textColor = .white
                }
            }
        }

        return orig.intrinsicContentSize()
    }
}

class SPTEncorePopUpContainerHook: ClassHook<UIViewController> {
    typealias Group = DarkPopUps
    static var targetName: String {
        return HookTargetNameHelper.popUpContainer
    }
    
    func containedView() -> SPTEncorePopUpDialog {
        return orig.containedView()
    }
    
    func viewDidAppear(_ animated: Bool) {
        orig.viewDidAppear(animated)
        containedView().uiView().backgroundColor = UIColor(Color(hex: "#242424"))
    }
}
