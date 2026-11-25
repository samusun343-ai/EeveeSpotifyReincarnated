import SwiftUI

struct EeveeLyricsSettingsView: View {
    @StateObject var viewModel = EeveeLyricsSettingsViewModel()
    @State private var karaokeOptions: KaraokeOptions = UserDefaults.karaokeOptions
    @State private var timingOffsets: LyricsTimingOffsets = UserDefaults.lyricsTimingOffsets
    @State var spicyLyricsApiKey: String = UserDefaults.spicyLyricsApiKey
    @State private var lyricsWidgetEnabled: Bool = UserDefaults.lyricsWidgetEnabled
    @State var lyricsOfflineCacheEnabled: Bool = UserDefaults.lyricsOfflineCacheEnabled
    @State var lyricsCacheUsageCount: Int = 0
    @State var lyricsCacheUsageBytes: Int = 0

    var body: some View {
        List {
            lyricsSourceSection()

            if viewModel.lyricsSource != .notReplaced {
                if viewModel.lyricsSource != .genius {
                    geniusFallbackSection()
                }
                
                hideOnErrorSection()
                romanizedLyricsSection()
                lyricsTimingOffsetSection()
                widgetSection()
                offlineCacheSection()
                
                if viewModel.lyricsSource.supportsCustomLyricsView {
                    karaokeAppearanceSection()
                    SettingsResetSection(visible: karaokeOptions != KaraokeOptions()) { karaokeOptions = KaraokeOptions() }
                }
            }

            SpacerView()
        }
        .eeveeSettingsStyle()
        .animation(.default, value: viewModel.animationValues)
        .onChange(of: karaokeOptions) { UserDefaults.karaokeOptions = $0 }
        .onChange(of: timingOffsets) { UserDefaults.lyricsTimingOffsets = $0 }
        .onChange(of: spicyLyricsApiKey) { UserDefaults.spicyLyricsApiKey = $0 }
        .onChange(of: lyricsWidgetEnabled) { UserDefaults.lyricsWidgetEnabled = $0 }
        .onChange(of: lyricsOfflineCacheEnabled) { UserDefaults.lyricsOfflineCacheEnabled = $0 }
        .onAppear { refreshLyricsCacheUsage() }
    }

    @ViewBuilder private func widgetSection() -> some View {
        Section {
            Toggle(
                "lyrics_widget_enabled".localized,
                isOn: $lyricsWidgetEnabled
            )
        } footer: {
            Text("lyrics_widget_description".localized)
        }
    }

    @ViewBuilder private func karaokeAppearanceSection() -> some View {
        Section {
            Toggle(
                "karaoke_enabled".localized,
                isOn: $karaokeOptions.enabled
            )

            if karaokeOptions.enabled {
                Picker("karaoke_alignment".localized, selection: $karaokeOptions.textAlignment) {
                    ForEach(KaraokeTextAlignment.allCases, id: \.self) { alignment in
                        Text(alignment.displayName).tag(alignment)
                    }
                }

                Toggle(
                    "karaoke_reversed_direction".localized,
                    isOn: $karaokeOptions.reversedDirection
                )

                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Text("karaoke_blur_intensity".localized)
                        Spacer()
                        Text(String(format: "%.1f", karaokeOptions.blurIntensity))
                            .foregroundColor(.gray)
                    }
                    Slider(value: $karaokeOptions.blurIntensity, in: 0...4, step: 0.1)
                }
            }

            // Independent of the custom lyrics view above: this publishes
            // to the system Now Playing info, not to any in-app view.
            Toggle(
                "karaoke_lock_screen_line".localized,
                isOn: $karaokeOptions.lockScreenLineEnabled
            )
        } header: {
            Text("karaoke_section".localized)
        } footer: {
            Text("karaoke_section_footer".localized)
        }
    }
    
    @ViewBuilder private func geniusFallbackSection() -> some View {
        Section {
            Toggle(
                "genius_fallback".localized,
                isOn: $viewModel.lyricsOptions.geniusFallback
            )
            
            if viewModel.lyricsOptions.geniusFallback {
                Toggle(
                    "show_fallback_reasons".localized,
                    isOn: $viewModel.lyricsOptions.showFallbackReasons
                )
            }
        } footer: {
            Text("genius_fallback_description"
                .localizeWithFormat(viewModel.lyricsSource.description))
        }
    }
    
    @ViewBuilder private func romanizedLyricsSection() -> some View {
        Section {
            Toggle(
                "romanized_lyrics".localized,
                isOn: $viewModel.lyricsOptions.romanization
            )
        } footer: {
            Text("romanized_lyrics_description".localized)
        }
    }
    
    @ViewBuilder private func lyricsTimingOffsetSection() -> some View {
        Section {
            Stepper(value: $timingOffsets.globalMs, in: -2_000...2_000, step: 100) {
                HStack {
                    Text("lyrics_timing_offset_global".localized)
                    Spacer()
                    Text(LyricsTimingOffsets.format(timingOffsets.globalMs))
                        .foregroundColor(.gray)
                }
            }
        } header: {
            Text("lyrics_timing_offset_section".localized)
        } footer: {
            Text("lyrics_timing_offset_description".localized)
        }
    }

    @ViewBuilder private func hideOnErrorSection() -> some View {
        Section {
            Toggle(
                "hide_lyrics_on_error".localized,
                isOn: $viewModel.lyricsOptions.hideOnError
            )
        } footer: {
            Text("hide_lyrics_on_error_description".localized)
        }
    }
}
