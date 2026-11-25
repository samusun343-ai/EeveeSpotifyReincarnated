import Compression
import Foundation

/// Persistent on-disk cache of fetched lyrics, one file per Spotify track.
///
/// The in-memory pieces of the lyrics pipeline (the prefetch handoff in
/// CustomLyrics, KaraokeLyricsStore) die with the process, so every cold
/// start used to re-fetch every song — slow on replay, useless offline, and
/// hard on rate-limited providers (LiriQo allows only a handful of requests
/// per window). This store keeps the fetched `LyricsDto` (plus the
/// word-synced karaoke data the fetch published, when any) in Application
/// Support so a replay is served instantly with no network at all.
///
/// Entries are keyed by track ID but record the source that produced them:
/// a read only hits when the entry's source is the currently selected one,
/// which keeps the semantics of `invalidateLyricsForSourceChange()` — after
/// a provider switch the next visit fetches from the new provider (the old
/// entry is simply never served, and is overwritten if that track is
/// fetched again). Title/artist are stored too and checked against the
/// query, so a track ID that resolves to different metadata can never
/// serve the wrong song's lyrics.
///
/// Payloads are JSON, zlib-compressed: measured on representative songs,
/// a line-synced entry shrinks ~5.6 KB → ~1.2 KB and a word-synced karaoke
/// entry ~64 KB → ~10 KB. A file that fails to decompress or decode is
/// corrupt by definition here — it is deleted on the spot and the caller
/// falls back to a fresh fetch for that one track.
///
/// Accumulation is bounded two ways (LRU by file modification time, which
/// is refreshed on every hit): at most `maxEntries` tracks and at most
/// `maxTotalBytes` on disk. Typical compressed entries are 1–10 KB, so the
/// count cap binds first in practice; the byte cap is a safety net for
/// pathologically large songs.
final class LyricsOfflineCache {
    static let shared = LyricsOfflineCache()

    struct CachedLyrics {
        var dto: LyricsDto
        var karaoke: KaraokeLyricsDto?
    }

    /// Display metadata for the settings management screen.
    struct EntryInfo {
        var trackId: String
        var title: String
        var artist: String
        var source: LyricsSource?
        var savedAt: Date
        var fileSize: Int
    }

    private struct Entry: Codable {
        var version: Int
        var trackId: String
        var sourceRawValue: Int
        var title: String
        var artist: String
        var savedAt: TimeInterval
        var lyrics: LyricsDto
        var karaoke: KaraokeLyricsDto?
    }

    static let maxEntries = 300
    static let maxTotalBytes = 16 * 1024 * 1024

    /// "ELC1" — Eevee Lyrics Cache frame, version 1.
    private static let frameMagic: [UInt8] = [0x45, 0x4C, 0x43, 0x31]
    /// Sanity ceiling for a single decompressed payload (a JSON DTO is
    /// never remotely this large; anything above it is corrupt data).
    private static let maxPayloadBytes = 64 * 1024 * 1024

    private static let cacheDirectory: URL = {
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        )[0]
        let directory = base.appendingPathComponent("EeveeSpotify/LyricsCache", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }()

    private let lock = NSLock()
    private let fileManager = FileManager.default

    private init() {}

    // MARK: - Lookup

    /// Returns the cached lyrics for a query, or nil on any kind of miss
    /// (disabled, absent, wrong source, mismatched metadata, corrupt file).
    /// Never touches the network, so it behaves identically offline.
    func cachedLyrics(for query: LyricsSearchQuery, source: LyricsSource) -> CachedLyrics? {
        guard UserDefaults.lyricsOfflineCacheEnabled, !query.spotifyTrackId.isEmpty else {
            return nil
        }

        lock.lock()
        defer { lock.unlock() }

        let url = fileURL(forTrackId: query.spotifyTrackId)

        guard let entry = readEntry(at: url) else { return nil }

        // Only serve what the currently selected provider produced.
        guard entry.sourceRawValue == source.rawValue else { return nil }

        // Identity check: if the metadata this entry was fetched under no
        // longer matches the query, the entry cannot be trusted — drop it.
        if !query.title.isEmpty, !entry.title.isEmpty,
           query.title.caseInsensitiveCompare(entry.title) != .orderedSame {
            try? fileManager.removeItem(at: url)
            return nil
        }
        if !query.primaryArtist.isEmpty, !entry.artist.isEmpty,
           query.primaryArtist.caseInsensitiveCompare(entry.artist) != .orderedSame {
            try? fileManager.removeItem(at: url)
            return nil
        }

        // Refresh LRU position.
        try? fileManager.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)

        return CachedLyrics(dto: entry.lyrics, karaoke: entry.karaoke)
    }

    // MARK: - Store

    func store(dto: LyricsDto, karaoke: KaraokeLyricsDto?, query: LyricsSearchQuery, source: LyricsSource) {
        guard UserDefaults.lyricsOfflineCacheEnabled,
              !query.spotifyTrackId.isEmpty,
              !dto.lines.isEmpty else { return }

        let entry = Entry(
            version: 1,
            trackId: query.spotifyTrackId,
            sourceRawValue: source.rawValue,
            title: query.title,
            artist: query.primaryArtist,
            savedAt: Date().timeIntervalSince1970,
            lyrics: dto,
            karaoke: karaoke
        )

        guard let json = try? JSONEncoder().encode(entry),
              let frame = Self.compress(json) else { return }

        lock.lock()
        defer { lock.unlock() }

        let url = fileURL(forTrackId: query.spotifyTrackId)

        guard (try? frame.write(to: url, options: .atomic)) != nil else { return }

        evictIfNeeded(protecting: url)
    }

    // MARK: - Management (settings)

    func statistics() -> (count: Int, totalBytes: Int) {
        lock.lock()
        defer { lock.unlock() }

        let urls = cacheFileURLs()
        var totalBytes = 0
        for url in urls {
            totalBytes += fileSize(of: url)
        }
        return (urls.count, totalBytes)
    }

    /// Metadata for every readable entry, newest first. Corrupt files are
    /// purged as a side effect (same policy as the lookup path).
    func allEntryInfos() -> [EntryInfo] {
        lock.lock()
        defer { lock.unlock() }

        return cacheFileURLs().compactMap { url in
            guard let entry = readEntry(at: url) else { return nil }

            return EntryInfo(
                trackId: entry.trackId,
                title: entry.title,
                artist: entry.artist,
                source: LyricsSource(rawValue: entry.sourceRawValue),
                savedAt: Date(timeIntervalSince1970: entry.savedAt),
                fileSize: fileSize(of: url)
            )
        }.sorted { $0.savedAt > $1.savedAt }
    }

    func remove(trackId: String) {
        guard !trackId.isEmpty else { return }

        lock.lock()
        defer { lock.unlock() }

        try? fileManager.removeItem(at: fileURL(forTrackId: trackId))
    }

    func clearAll() {
        lock.lock()
        defer { lock.unlock() }

        for url in cacheFileURLs() {
            try? fileManager.removeItem(at: url)
        }
    }

    // MARK: - Files

    private func fileURL(forTrackId trackId: String) -> URL {
        let safeName = trackId.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? trackId
        return Self.cacheDirectory
            .appendingPathComponent(safeName)
            .appendingPathExtension("elc")
    }

    private func cacheFileURLs() -> [URL] {
        let urls = (try? fileManager.contentsOfDirectory(
            at: Self.cacheDirectory,
            includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        return urls.filter { $0.pathExtension == "elc" }
    }

    private func fileSize(of url: URL) -> Int {
        (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
    }

    /// Reads and decodes one entry file. Any failure — unreadable file,
    /// broken compression frame, undecodable JSON — deletes the file and
    /// reports a miss, so corruption costs one refetch of one track and
    /// can never wedge the cache.
    private func readEntry(at url: URL) -> Entry? {
        guard let frame = try? Data(contentsOf: url) else { return nil }

        guard let json = Self.decompress(frame),
              let entry = try? JSONDecoder().decode(Entry.self, from: json),
              entry.version == 1 else {
            try? fileManager.removeItem(at: url)
            return nil
        }

        return entry
    }

    /// Deletes least-recently-used files until both caps hold. The file
    /// that was just written is only removed if it alone breaks the byte
    /// cap (storing it would make the cache permanently over budget).
    private func evictIfNeeded(protecting protectedURL: URL) {
        var files: [(url: URL, size: Int, modified: Date)] = cacheFileURLs().map { url in
            let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            return (url, values?.fileSize ?? 0, values?.contentModificationDate ?? .distantPast)
        }.sorted { $0.modified < $1.modified }

        var totalBytes = files.reduce(0) { $0 + $1.size }

        while files.count > Self.maxEntries || totalBytes > Self.maxTotalBytes {
            guard let victimIndex = files.firstIndex(where: { $0.url != protectedURL }) ?? files.indices.first else {
                break
            }

            let victim = files.remove(at: victimIndex)
            try? fileManager.removeItem(at: victim.url)
            totalBytes -= victim.size
        }
    }

    // MARK: - Compression framing
    //
    // Layout: 4-byte magic "ELC1", UInt32 little-endian original size,
    // then the zlib payload (Compression framework, COMPRESSION_ZLIB).
    // Storing the original size lets decode allocate once and verify the
    // output length, which is what makes corruption detection reliable.

    private static func compress(_ data: Data) -> Data? {
        // Deflate's worst case is a slight expansion; leave generous room.
        let dstCapacity = data.count + (data.count >> 4) + 65536
        var dst = Data(count: dstCapacity)

        let written = dst.withUnsafeMutableBytes { dstRaw -> Int in
            data.withUnsafeBytes { srcRaw -> Int in
                guard let dstPtr = dstRaw.baseAddress, let srcPtr = srcRaw.baseAddress else {
                    return 0
                }
                return compression_encode_buffer(
                    dstPtr.assumingMemoryBound(to: UInt8.self), dstCapacity,
                    srcPtr.assumingMemoryBound(to: UInt8.self), data.count,
                    nil, COMPRESSION_ZLIB
                )
            }
        }

        guard written > 0 else { return nil }

        var frame = Data()
        frame.append(contentsOf: frameMagic)
        var size = UInt32(data.count).littleEndian
        withUnsafeBytes(of: &size) { frame.append(contentsOf: $0) }
        frame.append(dst.prefix(written))
        return frame
    }

    private static func decompress(_ frame: Data) -> Data? {
        guard frame.count > 8, Array(frame.prefix(4)) == frameMagic else { return nil }

        let header = [UInt8](frame.prefix(8))
        let originalSize = Int(
            UInt32(header[4])
                | UInt32(header[5]) << 8
                | UInt32(header[6]) << 16
                | UInt32(header[7]) << 24
        )

        guard originalSize > 0, originalSize <= maxPayloadBytes else { return nil }

        let payload = frame.dropFirst(8)
        var dst = Data(count: originalSize)

        let written = dst.withUnsafeMutableBytes { dstRaw -> Int in
            payload.withUnsafeBytes { srcRaw -> Int in
                guard let dstPtr = dstRaw.baseAddress, let srcPtr = srcRaw.baseAddress else {
                    return 0
                }
                return compression_decode_buffer(
                    dstPtr.assumingMemoryBound(to: UInt8.self), originalSize,
                    srcPtr.assumingMemoryBound(to: UInt8.self), payload.count,
                    nil, COMPRESSION_ZLIB
                )
            }
        }

        guard written == originalSize else { return nil }

        return dst
    }
}

// MARK: - Codable conformances for the DTOs
//
// The struct conformances live in each DTO's own file: Swift only
// synthesizes Codable for an extension in the same file as the type
// declaration. The enum below is manual (raw-value based), so it can
// stay here.

extension LyricsRomanizationStatus: Codable {
    private var cacheRawValue: Int {
        switch self {
        case .romanized: return 0
        case .canBeRomanized: return 1
        case .original: return 2
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()

        switch try container.decode(Int.self) {
        case 0: self = .romanized
        case 1: self = .canBeRomanized
        default: self = .original
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(cacheRawValue)
    }
}
