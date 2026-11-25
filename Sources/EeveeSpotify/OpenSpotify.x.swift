import Orion
import UIKit

class UIOpenURLContextHook: ClassHook<UIOpenURLContext> {
    func URL() -> URL {
        let url = orig.URL()

        if url.isOpenSpotifySafariExtension,
           let rewrittenURL = Foundation.URL(string: "https:/\(url.path)") {
            return rewrittenURL
        }

        return url
    }
}
