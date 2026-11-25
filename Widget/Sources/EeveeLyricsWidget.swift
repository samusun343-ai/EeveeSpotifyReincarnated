import WidgetKit
import SwiftUI

// Eevee Lyrics widget — shows the track playing in Spotify and the current
// lyric line (from the lyrics EeveeSpotify fetched in the main app).
//
// Data contract (keep in sync with LyricsWidgetBridge.swift in the tweak):
// the tweak writes a property-list dictionary to
// UserDefaults(suiteName: "group.com.spotify.client.widget") under
// "eevee.widget.nowPlaying.v1":
//
//   version          Int     payload schema version (1)
//   trackId          String  Spotify track id
//   title, artist    String
//   artworkJPEG      Data?   240x240 JPEG of the album artwork
//   timeSynced       Bool
//   timedLines       [[Int, String]]?  [startMs, text] per line, when synced
//   plainLines       [String]?         when not synced
//   anchorPositionMs Int     playback position when the payload was written
//   anchorTimestamp  Double  wall-clock time (seconds since 1970) of the write
//   isPlaying        Bool    playback state at write time
//
// Neither side talks to the other's container directly: on sideloaded
// installs, zxPluginsInject (LC-injected into the main app and into this
// appex by ipapatch) mirrors the main app's group-suite writes into the
// shared group container and redirects this extension's suite reads to the
// same location. See research-widget.md / EeveeLyricsWidget.entitlements
// for why the group list mirrors Spotify.app's own, in the same order.

private enum EeveeWidgetShared {
    static let suiteName = "group.com.spotify.client.widget"
    static let payloadKey = "eevee.widget.nowPlaying.v1"
    static let kind = "EeveeLyricsWidget"
    static let maxTimelineEntries = 100
}

// MARK: - Payload

private struct WidgetPayload {
    var title: String
    var artist: String
    var artworkData: Data?
    var timedLines: [(startMs: Int, text: String)]
    var plainLines: [String]
    var anchorPositionMs: Int
    var anchorDate: Date
    var isPlaying: Bool

    static func load() -> WidgetPayload? {
        guard let defaults = UserDefaults(suiteName: EeveeWidgetShared.suiteName),
              let dict = defaults.dictionary(forKey: EeveeWidgetShared.payloadKey)
        else { return nil }

        var timed: [(startMs: Int, text: String)] = []

        if let rawLines = dict["timedLines"] as? [Any] {
            for case let pair as [Any] in rawLines where pair.count >= 2 {
                let startMs = (pair[0] as? NSNumber)?.intValue ?? 0
                let text = pair[1] as? String ?? ""
                timed.append((startMs: startMs, text: text))
            }
        }

        timed.sort { $0.startMs < $1.startMs }

        return WidgetPayload(
            title: dict["title"] as? String ?? "",
            artist: dict["artist"] as? String ?? "",
            artworkData: dict["artworkJPEG"] as? Data,
            timedLines: timed,
            plainLines: dict["plainLines"] as? [String] ?? [],
            anchorPositionMs: (dict["anchorPositionMs"] as? NSNumber)?.intValue ?? 0,
            anchorDate: Date(
                timeIntervalSince1970: (dict["anchorTimestamp"] as? NSNumber)?.doubleValue ?? 0
            ),
            isPlaying: dict["isPlaying"] as? Bool ?? false
        )
    }

    /// Wall-clock date at which the line starting at `startMs` should be on
    /// screen, assuming uninterrupted playback since the payload was written.
    func date(forLineStartMs startMs: Int) -> Date {
        anchorDate.addingTimeInterval(Double(startMs - anchorPositionMs) / 1000.0)
    }
}

// MARK: - Timeline

private struct LyricsEntry: TimelineEntry {
    var date: Date
    var title: String = ""
    var artist: String = ""
    var currentLine: String = ""
    var nextLine: String = ""
    var plainLines: [String] = []
    var artworkData: Data? = nil
    var hasContent: Bool = false
}

private struct Provider: TimelineProvider {
    func placeholder(in context: Context) -> LyricsEntry {
        placeholderEntry(Date())
    }

    func getSnapshot(in context: Context, completion: @escaping (LyricsEntry) -> Void) {
        completion(makeTimeline().entries.first ?? placeholderEntry(Date()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<LyricsEntry>) -> Void) {
        completion(makeTimeline())
    }

    // MARK: Timeline construction

    private func placeholderEntry(_ date: Date) -> LyricsEntry {
        LyricsEntry(
            date: date,
            title: "Eevee Lyrics",
            currentLine: "Play a song in Spotify"
        )
    }

    private func baseEntry(_ payload: WidgetPayload, date: Date) -> LyricsEntry {
        LyricsEntry(
            date: date,
            title: payload.title,
            artist: payload.artist,
            artworkData: payload.artworkData,
            hasContent: true
        )
    }

    private func makeTimeline() -> Timeline<LyricsEntry> {
        let now = Date()

        guard let payload = WidgetPayload.load(),
              payload.anchorDate.timeIntervalSince1970 > 0
        else {
            return Timeline(
                entries: [placeholderEntry(now)],
                policy: .after(now.addingTimeInterval(1800))
            )
        }

        if !payload.timedLines.isEmpty {
            return timedTimeline(payload, now: now)
        }

        if !payload.plainLines.isEmpty {
            var entry = baseEntry(payload, date: now)
            entry.currentLine = payload.plainLines.first ?? ""
            entry.plainLines = Array(payload.plainLines.prefix(4))
            return Timeline(entries: [entry], policy: .after(now.addingTimeInterval(900)))
        }

        // Track metadata only (lyrics not synced, or not fetched yet).
        return Timeline(
            entries: [baseEntry(payload, date: now)],
            policy: .after(now.addingTimeInterval(900))
        )
    }

    /// One entry per lyric line, dated from the payload's playback anchor.
    /// Entries already inside a delivered timeline render at their dates
    /// without consuming WidgetKit's reload budget; only the reload on a
    /// track change (requested by the tweak via WidgetCenter) spends budget.
    private func timedTimeline(_ payload: WidgetPayload, now: Date) -> Timeline<LyricsEntry> {
        let lines = payload.timedLines

        func entry(at index: Int, date: Date) -> LyricsEntry {
            var entry = baseEntry(payload, date: date)
            entry.currentLine = lines[index].text
            entry.nextLine = index + 1 < lines.count ? lines[index + 1].text : ""
            return entry
        }

        // Paused when the payload was written: freeze on the anchor line
        // instead of projecting dates that will never match reality.
        guard payload.isPlaying else {
            let active = lines.lastIndex {
                $0.startMs <= payload.anchorPositionMs
            } ?? 0
            return Timeline(
                entries: [entry(at: active, date: now)],
                policy: .after(now.addingTimeInterval(900))
            )
        }

        var active = 0

        for (index, line) in lines.enumerated()
        where payload.date(forLineStartMs: line.startMs) <= now {
            active = index
        }

        let lastLineDate = payload.date(forLineStartMs: lines[lines.count - 1].startMs)

        // The track this payload belongs to ended a while ago; don't build
        // a timeline entirely in the past (WidgetKit would keep asking for
        // a new one). Show the final line until the next track publishes.
        if lastLineDate < now.addingTimeInterval(-120) {
            return Timeline(
                entries: [entry(at: lines.count - 1, date: now)],
                policy: .after(now.addingTimeInterval(1800))
            )
        }

        var entries: [LyricsEntry] = []
        var index = active

        while index < lines.count && entries.count < EeveeWidgetShared.maxTimelineEntries {
            let lineDate = payload.date(forLineStartMs: lines[index].startMs)
            entries.append(entry(at: index, date: entries.isEmpty ? now : lineDate))
            index += 1
        }

        return Timeline(entries: entries, policy: .atEnd)
    }
}

// MARK: - Views

private struct LyricsWidgetEntryView: View {
    @Environment(\.widgetFamily) private var family
    var entry: LyricsEntry

    var body: some View {
        Group {
            if family == .systemMedium {
                mediumBody
            } else {
                smallBody
            }
        }
        .widgetURL(URL(string: "spotify:"))
    }

    @ViewBuilder private var artwork: some View {
        if let data = entry.artworkData, let image = UIImage(data: data) {
            Image(uiImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
        } else {
            ZStack {
                Color.gray.opacity(0.25)
                Image(systemName: "music.note")
                    .foregroundColor(.secondary)
            }
        }
    }

    @ViewBuilder private var lyricText: some View {
        if !entry.plainLines.isEmpty {
            Text(entry.plainLines.joined(separator: "\n"))
                .font(.callout)
                .lineLimit(4)
        } else {
            Text(entry.currentLine)
                .font(.callout)
                .fontWeight(.semibold)
                .lineLimit(3)

            if !entry.nextLine.isEmpty {
                Text(entry.nextLine)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
        }
    }

    private var smallBody: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                artwork
                    .frame(width: 34, height: 34)
                    .clipShape(RoundedRectangle(cornerRadius: 7))

                VStack(alignment: .leading, spacing: 1) {
                    Text(entry.title.isEmpty ? "Eevee Lyrics" : entry.title)
                        .font(.caption)
                        .fontWeight(.semibold)
                        .lineLimit(1)

                    Text(entry.artist)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
            }

            lyricText

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding()
    }

    private var mediumBody: some View {
        HStack(alignment: .top, spacing: 12) {
            artwork
                .frame(width: 76, height: 76)
                .clipShape(RoundedRectangle(cornerRadius: 10))

            VStack(alignment: .leading, spacing: 4) {
                Text(entry.title.isEmpty ? "Eevee Lyrics" : entry.title)
                    .font(.headline)
                    .lineLimit(1)

                Text(entry.artist)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .lineLimit(1)

                Spacer(minLength: 2)

                lyricText
            }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding()
    }
}

// MARK: - Widget definition

private struct EeveeLyricsWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: EeveeWidgetShared.kind, provider: Provider()) { entry in
            LyricsWidgetEntryView(entry: entry)
        }
        .configurationDisplayName("Eevee Lyrics")
        .description("The current lyric line for what's playing in Spotify.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

@main
struct EeveeLyricsWidgetBundle: WidgetBundle {
    var body: some Widget {
        EeveeLyricsWidget()
    }
}
