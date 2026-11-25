import Orion
import UIKit

class LyricsFullscreenViewControllerHook: ClassHook<UIViewController> {
    typealias Group = BaseLyricsGroup
    
    static var targetName: String {
        return HookTargetNameHelper.lyricsFullscreenViewController
    }

    func viewDidLoad() {
        orig.viewDidLoad()
        
        // 9.1.x has different view structure - skip headerView access
        if EeveeSpotify.hookTarget == .v91 {
            return
        }
        
        if EeveeSpotify.hookTarget == .v90 {
            guard let fullscreenView = WindowHelper.shared.findFirstSubview(
                "Lyrics_FullscreenElementPageImpl.FullscreenView",
                in: target.view
            ) else {
                return
            }
            
            let controlsView = Ivars<UIView>(fullscreenView).controlsView
            let contextMenuButtonContainer = Ivars<UIView>(controlsView).contextMenuButtonContainer
            
            if let contextButton = contextMenuButtonContainer.subviews(
                matching: "Encore6Button"
            ).first as? UIControl {
                contextButton.isEnabled = false
            }
            
            return
        }
        
        let headerView = Ivars<UIView>(target.view).headerView
        
        // The report button is the second EncoreButton in the header. If a
        // layout change ever leaves fewer than two, leave the header as-is
        // instead of indexing out of bounds.
        let headerButtons = headerView.subviews(matching: "EncoreButton")
        
        if headerButtons.count > 1, let reportButton = headerButtons[1] as? UIButton {
            reportButton.isEnabled = false
        }
    }
}
