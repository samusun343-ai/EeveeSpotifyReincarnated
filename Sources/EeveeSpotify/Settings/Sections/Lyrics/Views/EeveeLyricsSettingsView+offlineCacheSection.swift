import SwiftUI

extension EeveeLyricsSettingsView {
    func refreshLyricsCacheUsage() {
        let stats = LyricsOfflineCache.shared.statistics()
        lyricsCacheUsageCount = stats.count
        lyricsCacheUsageBytes = stats.totalBytes
    }

    private var lyricsCacheUsageText: String {
        let size = ByteCountFormatter.string(
            fromByteCount: Int64(lyricsCacheUsageBytes),
            countStyle: .file
        )

        return "lyrics_offline_cache_usage".localizeWithFormat(lyricsCacheUsageCount, size)
    }

    @ViewBuilder func offlineCacheSection() -> some View {
        Section {
            Toggle(
                "lyrics_offline_cache".localized,
                isOn: $lyricsOfflineCacheEnabled
            )

            HStack {
                Text("lyrics_offline_cache_usage_label".localized)
                Spacer()
                Text(lyricsCacheUsageText)
                    .foregroundColor(.gray)
            }

            NavigationLink(destination: LyricsCacheManageView()) {
                Text("lyrics_offline_cache_manage".localized)
            }
        } header: {
            Text("lyrics_offline_cache_section".localized)
        } footer: {
            Text("lyrics_offline_cache_description".localized)
        }
    }
}
