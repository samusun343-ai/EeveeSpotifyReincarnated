import SwiftUI

/// Lists the offline lyrics cache (see `LyricsOfflineCache`) so the user
/// can inspect what is stored, delete individual tracks, or wipe the
/// whole cache. Deleting an entry only costs a refetch the next time
/// that track plays.
struct LyricsCacheManageView: View {
    @State private var entries: [LyricsOfflineCache.EntryInfo] = []
    @State private var isConfirmingClearAll = false

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .none
        return formatter
    }()

    var body: some View {
        List {
            if entries.isEmpty {
                Text("lyrics_cache_empty".localized)
                    .foregroundColor(.gray)
            } else {
                Section {
                    ForEach(entries, id: \.trackId) { entry in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.title.isEmpty ? entry.trackId : entry.title)
                                .lineLimit(1)

                            Text(subtitle(for: entry))
                                .font(.footnote)
                                .foregroundColor(.gray)
                                .lineLimit(1)
                        }
                    }
                    .onDelete(perform: deleteEntries)
                }

                Section {
                    Button {
                        isConfirmingClearAll = true
                    } label: {
                        Text("lyrics_cache_clear_all".localized)
                            .foregroundColor(.red)
                    }
                }
            }
        }
        .navigationTitle("lyrics_cache_title".localized)
        .onAppear {
            entries = LyricsOfflineCache.shared.allEntryInfos()
        }
        .alert(isPresented: $isConfirmingClearAll) {
            Alert(
                title: Text("lyrics_cache_clear_confirm_title".localized),
                message: Text("lyrics_cache_clear_confirm_message".localized),
                primaryButton: .destructive(Text("lyrics_cache_clear_all".localized)) {
                    LyricsOfflineCache.shared.clearAll()
                    entries = []
                },
                secondaryButton: .cancel()
            )
        }
    }

    private func subtitle(for entry: LyricsOfflineCache.EntryInfo) -> String {
        var parts: [String] = []

        if !entry.artist.isEmpty {
            parts.append(entry.artist)
        }

        if let source = entry.source {
            parts.append(source.description)
        }

        parts.append(ByteCountFormatter.string(
            fromByteCount: Int64(entry.fileSize),
            countStyle: .file
        ))

        parts.append(Self.dateFormatter.string(from: entry.savedAt))

        return parts.joined(separator: " · ")
    }

    private func deleteEntries(at offsets: IndexSet) {
        for index in offsets {
            LyricsOfflineCache.shared.remove(trackId: entries[index].trackId)
        }

        entries.remove(atOffsets: offsets)
    }
}
