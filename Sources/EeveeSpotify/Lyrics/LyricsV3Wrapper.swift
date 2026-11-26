import Foundation

// Synthesis of Com_Spotify_Colorlyrics_V3_LyricsWrapperResponse bodies for
// /color-lyrics/v3/track/ requests — the route the NPV lyrics card consumes
// on current Spotify whenever its dynamic-colors predicate holds. Spotify
// answers 404 there for tracks without official lyrics, and the card path
// never sees the /color-lyrics/v2 response the rest of Eevee replaces.
//
// The wire layout below was read from the 9.2.2 binary (generated decode
// traversal + nominal descriptors; eevee-work/lyrics-card-v3route.md):
//
//   LyricsWrapperResponse { 2: LyricsResponse lyrics }
//   LyricsResponse        { 1: syncType, 2: lines, 6: provider }
//   LyricsLine            { 1: startTimeMs, 2: endTimeMs, 3: words }
//   Provider              { 1: name, 2: lyricsID }
//
// Hand-encoded on purpose: the wrapper is a thin envelope, and explicit
// encoding keeps the layout auditable against the binary's schema. Fields
// left out (colors, preview lines, translations) take proto defaults on
// the client — its V3 conversion (0x1052674bc) is a mechanical mapper with
// no presence validation, so an absent field cannot reject the body.

private func protoVarint(_ value: UInt64) -> Data {
    var v = value
    var out = Data()
    repeat {
        var byte = UInt8(v & 0x7f)
        v >>= 7
        if v != 0 { byte |= 0x80 }
        out.append(byte)
    } while v != 0
    return out
}

private func protoFieldVarint(_ field: Int, _ value: UInt64) -> Data {
    protoVarint(UInt64(field) << 3) + protoVarint(value)
}

private func protoFieldBytes(_ field: Int, _ payload: Data) -> Data {
    protoVarint((UInt64(field) << 3) | 2) + protoVarint(UInt64(payload.count)) + payload
}

private func protoFieldString(_ field: Int, _ string: String) -> Data {
    protoFieldBytes(field, Data(string.utf8))
}

/// Re-encodes Eevee's V1 lyrics payload as a V3 LyricsWrapperResponse.
/// Line timing maps 1:1; only the field numbering differs (V1 LyricsLine
/// carries words at field 2 and endTimeMs at field 4, V3 carries endTimeMs
/// at field 2 and words at field 3).
func lyricsWrapperData(from lyrics: Lyrics) -> Data {
    let data = lyrics.data

    var lines = Data()
    for line in data.lines {
        var message = Data()
        message += protoFieldVarint(1, UInt64(bitPattern: Int64(line.offsetMs)))
        message += protoFieldVarint(2, UInt64(bitPattern: line.endTimeMs))
        message += protoFieldString(3, line.content)
        lines += protoFieldBytes(2, message)
    }

    var provider = Data()
    let providerName = data.providedBy.isEmpty ? data.provider : data.providedBy
    if !providerName.isEmpty {
        provider += protoFieldString(1, providerName)
    }
    if !data.providerLyricsID.isEmpty {
        provider += protoFieldString(2, data.providerLyricsID)
    }

    var response = Data()
    let syncType: Int
    switch data.syncType {
    case .unsynced: syncType = 0
    case .lineSynced: syncType = 1
    case .syllableSynced: syncType = 2
    case .UNRECOGNIZED(let value): syncType = value
    }
    if syncType != 0 {
        response += protoFieldVarint(1, UInt64(syncType))
    }
    response += lines
    if !provider.isEmpty {
        response += protoFieldBytes(6, provider)
    }

    return protoFieldBytes(2, response)
}

/// Lyrics hook entry point for v3 requests: the same per-task answer the
/// v2 flow produces (eeveeLyricsData), re-encoded as a wrapper.
func eeveeLyricsWrapperData(_ path: String, task: URLSessionTask) throws -> Data {
    let v1Data = try eeveeLyricsData(path, task: task)
    let lyrics = try Lyrics(serializedBytes: v1Data)
    return lyricsWrapperData(from: lyrics)
}
