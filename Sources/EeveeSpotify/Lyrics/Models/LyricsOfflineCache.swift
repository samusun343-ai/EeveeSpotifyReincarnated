import Compression
import Foundation

/// Persistent on-disk cache of fetched lyrics, one file per *recording
/// identity* (format v3; v1/v2 filed one file per Spotify track ID).
///
/// The in-memory pieces of the lyrics pipeline (the prefetch handoff in
/// CustomLyrics, KaraokeLyricsStore) die with the process, so every cold
/// start used to re-fetch every song — slow on replay, useless offline, and
/// hard on rate-limited providers (LiriQo allows only a handful of requests
/// per window). This store keeps the fetched `LyricsDto` (plus the
/// word-synced karaoke data the fetch published, when any) in Application
/// Support so a replay is served instantly with no network at all.
///
/// Identity keying (see LyricsIdentity): Spotify lists one recording
/// under several track IDs (album/single/deluxe variants), and filing
/// per track ID stored and re-fetched every duplicate separately. An
/// entry is now filed under the recording's ISRC when one is known —
/// from the producing stage's verified resolution
/// (`LyricsDto.resolvedIsrc`) or from the track's own metadata
/// (`LyricsSearchQuery.isrc`) — under a title/artist fingerprint for
/// plain lyrics only, and under the track ID otherwise. A small alias
/// map (track ID → ISRC key) is kept alongside the entries so a track
/// whose lyrics were filed under its ISRC is found again on later
/// plays, whose metadata resolution usually never reaches the step
/// that could supply the ISRC. The sharing rules are strict: synced
/// lyrics and karaoke data cross track IDs only under an ISRC
/// identity, never under a fingerprint (two different recordings can
/// share a normalized title/artist; their timings cannot be shared).
///
/// Entries record the source that produced them: a read only hits when
/// the entry's source is the currently selected one, which keeps the
/// semantics of `invalidateLyricsForSourceChange()` — after a provider
/// switch the next visit fetches from the new provider (the old entry
/// is simply never served, and is overwritten if that identity is
/// fetched again). One refinement of "the source that produced them": a
/// result produced by the Genius fallback is filed under the selected
/// source whose pipeline produced it (with the Genius credit pinned on
/// the DTO), because filing it under .genius made it unservable under
/// the very configuration that fetched it. Title/artist are stored too:
/// entries filed under a track ID are still cross-checked against the
/// query, so a track ID that resolves to different metadata can never
/// serve the wrong song's lyrics. Identity-keyed entries need no such
/// check — the identity *is* the check.
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
        /// The identity this entry is filed under (LyricsIdentity):
        /// "isrc:…", "meta:…" or "track:…". The file name is a hash of
        /// this key.
        var identityKey: String
        /// The title/artist fingerprint computed at store time, kept
        /// even on ISRC/track entries so a duplicate track ID whose own
        /// identity is not yet known can find the entry by scan (plain
        /// lyrics only — see `cachedLyrics`).
        var fingerprintKey: String?
        /// The track ID that first filed this entry (display/removal).
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

    /// Entry format version written by `store` and required by `readEntry`.
    /// v2 invalidated every entry written before the metadata-attribution
    /// fix in CustomLyrics (the NowPlaying resolution step could adopt
    /// the *playing* track's title/artist for a different requested track
    /// ID, and those pairings were stored here; the title/artist
    /// cross-check on read cannot catch them, both sides came from the
    /// same wrong resolution, so the whole pre-fix generation was dropped
    /// instead — a version mismatch deletes the file and the track is
    /// simply refetched once).
    /// v3 switches filing from track IDs to recording identities
    /// (LyricsIdentity), which changes both the entry shape and the file
    /// naming; the v2 generation is dropped by the same mechanism.
    private static let currentEntryVersion = 3

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

    private static let aliasesFileURL = cacheDirectory
        .appendingPathComponent("identity-aliases.json")

    private let lock = NSLock()
    private let fileManager = FileManager.default

    /// Track ID → ISRC identity key, loaded lazily from disk. Only ever
    /// written for identities a track's own fetch verified (see store),
    /// so an alias can never point one track at another song's entry.
    private var aliasesCache: [String: String]?

    private init() {}

    // MARK: - Identity

    /// The ISRC identity on file for a track, if its lyrics were ever
    /// filed under one. Used by the timing offsets, whose corrections
    /// are shared across duplicate track IDs of one recording under
    /// exactly this identity. Deliberately independent of the cache
    /// enabled toggle: the map records facts about tracks, and offset
    /// sharing should not silently change when the cache is toggled.
    func isrc(forTrackId trackId: String) -> String? {
        guard !trackId.isEmpty else { return nil }

        lock.lock()
        defer { lock.unlock() }

        guard let key = loadAliasesLocked()[trackId] else { return nil }
        return LyricsIdentity.isrc(fromKey: key)
    }

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

        let trackId = query.spotifyTrackId
        let aliases = loadAliasesLocked()
        let fingerprint = LyricsIdentity.fingerprintKey(title: query.title, artist: query.primaryArtist)

        // Candidate identity keys, most trusted first: the track's own
        // ISRC from this resolution, the ISRC an earlier fetch of this
        // track verified and filed under, the title/artist fingerprint,
        // and finally the track ID itself.
        var candidates: [String] = []
        if let isrc = query.isrc, !isrc.isEmpty {
            candidates.append(LyricsIdentity.isrcKey(isrc))
        }
        if let alias = aliases[trackId], !candidates.contains(alias) {
            candidates.append(alias)
        }
        if let fingerprint, !candidates.contains(fingerprint) {
            candidates.append(fingerprint)
        }
        let trackKey = LyricsIdentity.trackKey(trackId)
        if !candidates.contains(trackKey) {
            candidates.append(trackKey)
        }

        for key in candidates {
            let url = fileURL(forIdentityKey: key)
            let fileExists = fileManager.fileExists(atPath: url.path)

            guard let entry = readEntry(at: url) else {
                // A dangling alias (its entry was evicted or removed)
                // cleans itself up instead of shadowing later lookups.
                if key == aliases[trackId], !fileExists {
                    var aliases = aliases
                    aliases[trackId] = nil
                    aliasesCache = aliases
                    saveAliasesLocked()
                }
                continue
            }

            guard entry.identityKey == key else { continue }

            // Only serve what the currently selected provider produced.
            guard entry.sourceRawValue == source.rawValue else { continue }

            if LyricsIdentity.isFingerprintKey(key) {
                // A fingerprint is only ever trusted with plain lyrics:
                // a different recording can share the title/artist, and
                // its timings must not cross over. (Store never files a
                // synced DTO under a fingerprint; this is the read-side
                // half of the same rule.)
                guard !entry.lyrics.timeSynced else { continue }
            }

            if key == trackKey {
                // Per-track entries keep the legacy identity check: if
                // the metadata this entry was fetched under no longer
                // matches the query, the entry cannot be trusted.
                if !query.title.isEmpty, !entry.title.isEmpty,
                   query.title.caseInsensitiveCompare(entry.title) != .orderedSame {
                    try? fileManager.removeItem(at: url)
                    continue
                }
                if !query.primaryArtist.isEmpty, !entry.artist.isEmpty,
                   query.primaryArtist.caseInsensitiveCompare(entry.artist) != .orderedSame {
                    try? fileManager.removeItem(at: url)
                    continue
                }
            }

            // Refresh LRU position.
            try? fileManager.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)

            // A read that arrived carrying the track's own ISRC teaches
            // the alias map, so later plays — whose metadata resolution
            // usually never reaches the Web API step that supplies an
            // ISRC — go straight to this entry.
            if LyricsIdentity.isIsrcKey(key), aliases[trackId] != key {
                var aliases = aliases
                aliases[trackId] = key
                aliasesCache = aliases
                saveAliasesLocked()
            }

            // Karaoke data is word-synced (timed) data: under a
            // fingerprint identity it is served only to the track that
            // produced it, never across track IDs.
            let karaoke = (LyricsIdentity.isFingerprintKey(key) && entry.trackId != trackId)
                ? nil
                : entry.karaoke

            return CachedLyrics(dto: entry.lyrics, karaoke: karaoke)
        }

        // Scan fallback: an entry filed under an identity this query
        // could not recompute — typically the ISRC an earlier fetch of
        // a *duplicate* track ID resolved — recorded its fingerprint at
        // store time. A fingerprint match serves plain lyrics only
        // (same rule as the fingerprint candidate above), and never
        // teaches the alias map: this track's own ISRC is still
        // unverified, so its synced lyrics must wait for its own fetch.
        if let fingerprint {
            for url in cacheFileURLs() {
                guard let entry = readEntry(at: url) else { continue }

                guard entry.fingerprintKey == fingerprint,
                      entry.sourceRawValue == source.rawValue,
                      !entry.lyrics.timeSynced else { continue }

                try? fileManager.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)

                let karaoke = entry.trackId == trackId ? entry.karaoke : nil
                return CachedLyrics(dto: entry.lyrics, karaoke: karaoke)
            }
        }

        return nil
    }

    // MARK: - Store

    func store(dto: LyricsDto, karaoke: KaraokeLyricsDto?, query: LyricsSearchQuery, source: LyricsSource) {
        guard UserDefaults.lyricsOfflineCacheEnabled,
              !query.spotifyTrackId.isEmpty,
              !dto.lines.isEmpty else { return }

        // Identity resolution, most trusted first: the ISRC of the
        // recording the lyrics actually came from (the producing stage
        // sets it only on a verified match), then the track's own ISRC
        // from metadata resolution. Plain lyrics without any ISRC use
        // the title/artist fingerprint; synced lyrics without one keep
        // per-track filing, so timed data is never shared on a
        // fingerprint's say-so.
        let fingerprint = LyricsIdentity.fingerprintKey(title: query.title, artist: query.primaryArtist)

        let identityKey: String
        if let isrc = dto.resolvedIsrc ?? query.isrc, !isrc.isEmpty {
            identityKey = LyricsIdentity.isrcKey(isrc)
        } else if !dto.timeSynced, let fingerprint {
            identityKey = fingerprint
        } else {
            identityKey = LyricsIdentity.trackKey(query.spotifyTrackId)
        }

        let entry = Entry(
            version: Self.currentEntryVersion,
            identityKey: identityKey,
            fingerprintKey: fingerprint,
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

        let url = fileURL(forIdentityKey: identityKey)

        guard (try? frame.write(to: url, options: .atomic)) != nil else { return }

        // Remember which ISRC identity this track filed under, so its
        // later plays (and its timing-offset sharing) can find it
        // without re-deriving the ISRC.
        if LyricsIdentity.isIsrcKey(identityKey) {
            var aliases = loadAliasesLocked()
            if aliases[query.spotifyTrackId] != identityKey {
                aliases[query.spotifyTrackId] = identityKey
                aliasesCache = aliases
                saveAliasesLocked()
            }
        }

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

        try? fileManager.removeItem(at: fileURL(forIdentityKey: LyricsIdentity.trackKey(trackId)))

        var aliases = loadAliasesLocked()
        if let key = aliases[trackId] {
            try? fileManager.removeItem(at: fileURL(forIdentityKey: key))
            aliases[trackId] = nil
            aliasesCache = aliases
            saveAliasesLocked()
        }

        // An entry this track filed may live under a fingerprint key,
        // which cannot be recomputed here without the original
        // title/artist — find it by the track ID recorded in the entry.
        for url in cacheFileURLs() {
            if let entry = readEntry(at: url), entry.trackId == trackId {
                try? fileManager.removeItem(at: url)
            }
        }
    }

    func clearAll() {
        lock.lock()
        defer { lock.unlock() }

        for url in cacheFileURLs() {
            try? fileManager.removeItem(at: url)
        }

        aliasesCache = [:]
        try? fileManager.removeItem(at: Self.aliasesFileURL)
    }

    // MARK: - Files

    /// Entry files are named by a hash of the identity key: ISRCs and
    /// fingerprints contain characters that are awkward in file names,
    /// and the name itself carries no information the entry doesn't.
    private func fileURL(forIdentityKey key: String) -> URL {
        Self.cacheDirectory
            .appendingPathComponent(Self.fileName(forIdentityKey: key))
            .appendingPathExtension("elc")
    }

    /// FNV-1a (64-bit) over the key's UTF-8 bytes. Only stability and
    /// dispersion matter here — the entry re-verifies its own key on
    /// every read, so even a (practically impossible) collision would
    /// degrade to a miss, never to wrong lyrics.
    private static func fileName(forIdentityKey key: String) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in key.utf8 {
            hash ^= UInt64(byte)
            hash &*= 0x100000001b3
        }
        return String(format: "%016llx", hash)
    }

    private func loadAliasesLocked() -> [String: String] {
        if let aliasesCache {
            return aliasesCache
        }

        let aliases: [String: String]
        if let data = try? Data(contentsOf: Self.aliasesFileURL),
           let decoded = try? JSONDecoder().decode([String: String].self, from: data) {
            aliases = decoded
        } else {
            aliases = [:]
        }

        aliasesCache = aliases
        return aliases
    }

    private func saveAliasesLocked() {
        guard let aliasesCache,
              let data = try? JSONEncoder().encode(aliasesCache) else { return }
        try? data.write(to: Self.aliasesFileURL, options: .atomic)
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
    /// broken compression frame, undecodable JSON, or an entry written
    /// by an older format version — deletes the file and reports a miss,
    /// so corruption (or a format bump) costs one refetch of one track
    /// and can never wedge the cache.
    private func readEntry(at url: URL) -> Entry? {
        guard let frame = try? Data(contentsOf: url) else { return nil }

        guard let json = Self.decompress(frame),
              let entry = try? JSONDecoder().decode(Entry.self, from: json),
              entry.version == Self.currentEntryVersion else {
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
    // output length, which makes corruption detection reliable.

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
