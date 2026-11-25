import Orion
import UIKit

// ErrorViewController doesn't exist in Spotify 9.1.x - separate group to avoid crashes
class ErrorViewControllerHook: ClassHook<UIViewController> {
    typealias Group = LyricsErrorHandlingGroup  // Not activated for 9.1.x
    
    static var targetName: String {
        switch EeveeSpotify.hookTarget {
        case .lastAvailableiOS14: return "Lyrics_CoreImpl.ErrorViewController"
        default: return "Lyrics_NPVCommunicatorImpl.ErrorViewController"
        }
    }
    
    func loadView() {
        orig.loadView()
        
        guard UserDefaults.lyricsOptions.hideOnError else {
            return
        }
        
        if let controller = nowPlayingScrollViewController {
            controller.dataSource.activeProviders.removeAll {
                NSStringFromClass(type(of: $0)) == HookTargetNameHelper.lyricsScrollProvider
            }
            
            controller.collectionView().reloadData()
        }
        else if let controller = npvScrollViewController, let dataSource = scrollDataSource {
            // This branch used to force-unwrap both the provider index and
            // collectionView.dataSource. If the lyrics provider isn't among
            // the active providers, or the collection view has no data source
            // yet, there is nothing to hide — bail out instead of crashing.
            guard let lyricsProviderIndex = dataSource.activeProviders.firstIndex(where: {
                NSStringFromClass(type(of: $0)) == HookTargetNameHelper.lyricsScrollProvider
            }) else {
                return
            }
            
            let collectionView = controller.collectionView()
            
            guard let collectionViewDataSource = collectionView.dataSource else {
                return
            }
            
            let diffableDataSource = Ivars<__UIDiffableDataSource>(collectionViewDataSource)._impl
            
            let itemIdentifiers = diffableDataSource.itemIdentifiers()
            
            guard lyricsProviderIndex < itemIdentifiers.count else {
                return
            }
            
            diffableDataSource.deleteItemsWithIdentifiers([itemIdentifiers[lyricsProviderIndex]])
        }
    }
}
