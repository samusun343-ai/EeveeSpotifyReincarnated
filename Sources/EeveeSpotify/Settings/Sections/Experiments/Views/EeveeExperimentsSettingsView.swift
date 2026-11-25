import SwiftUI
import UIKit

struct EeveeExperimentsSettingsView: View {
    @State var experimentsOptions = UserDefaults.experimentsOptions

    var body: some View {
        List {
            Section(footer: Text("livecontainer_sharing_description".localized)) {
                Toggle(
                    "livecontainer_sharing".localized,
                    isOn: $experimentsOptions.liveContainerSharing
                )
            }
            
            // ShowInstagramDestination hooks SPTSharingSDK and
            // SPTShare_FoundationImplProperties; both classes are gone in
            // Spotify 9.2.2, so only offer the toggle where its targets
            // exist and it can actually take effect (same pair the
            // activation guard in Tweak init checks).
            if NSClassFromString("SPTSharingSDK") != nil,
               NSClassFromString("SPTShare_FoundationImplProperties") != nil {
                Section(
                    footer: Text("show_instagram_destination_description"
                        .localizeWithFormat("restart_is_required_description".localized))
                ) {
                    Toggle(
                        "show_instagram_destination".localized,
                        isOn: $experimentsOptions.showInstagramDestination
                    )
                }
            }

        }
        .onChange(of: experimentsOptions) { options in
            UserDefaults.experimentsOptions = options
            
            if options.showInstagramDestination {
                OfflineHelper.resetData()
            }
        }
        
        .eeveeSettingsStyle()
        .animation(.default, value: experimentsOptions)
    }
}
