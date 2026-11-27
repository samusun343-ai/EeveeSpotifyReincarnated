import Foundation

// MARK: - Original lyrics response shape dump (diagnostics)
//
// Eevee's Lyrics proto model (Lyrics.pb.swift) is a partial mapping of
// Spotify's /color-lyrics/v2 response: LyricsData models only fields
// 1, 2, 5, 9, 14 and LyricsLine only 1, 2, so anything the real response
// carries beyond those is invisible to the tweak — and silently dropped
// from the substituted payload it builds. To pin the real schema down
// from ground truth instead of guessing, this walks the *original*
// response bytes as schema-less protobuf and logs the field numbers,
// wire types and (for varints) values it finds, once per track per
// process. It never reads through the Lyrics model, so unmodeled fields
// show up too. Output goes through writeDebugLog, i.e. it only lands in
// the exported debug log when debug logging is enabled, and it never
// alters the payload that is handed to Spotify.

private var shapeDumpedPaths = Set<String>()
private let shapeDumpLock = NSLock()

private struct ProtoField {
    let number: Int
    let wireType: Int
    let varintValue: UInt64?
    let bytes: [UInt8]?
}

private func parseProtoFields(_ bytes: [UInt8]) -> [ProtoField]? {
    var fields: [ProtoField] = []
    var i = 0

    func readVarint() -> UInt64? {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        while i < bytes.count && shift < 64 {
            let b = bytes[i]
            i += 1
            result |= UInt64(b & 0x7f) << shift
            if b & 0x80 == 0 { return result }
            shift += 7
        }
        return nil
    }

    while i < bytes.count {
        guard let tag = readVarint(), tag > 0 else { return nil }
        let number = Int(tag >> 3)
        let wire = Int(tag & 7)
        guard number > 0 else { return nil }
        switch wire {
        case 0:
            guard let v = readVarint() else { return nil }
            fields.append(ProtoField(number: number, wireType: wire, varintValue: v, bytes: nil))
        case 1:
            guard i + 8 <= bytes.count else { return nil }
            fields.append(ProtoField(number: number, wireType: wire, varintValue: nil, bytes: Array(bytes[i..<i + 8])))
            i += 8
        case 2:
            guard let len = readVarint(), len <= UInt64(bytes.count - i) else { return nil }
            let n = Int(len)
            fields.append(ProtoField(number: number, wireType: wire, varintValue: nil, bytes: Array(bytes[i..<i + n])))
            i += n
        case 5:
            guard i + 4 <= bytes.count else { return nil }
            fields.append(ProtoField(number: number, wireType: wire, varintValue: nil, bytes: Array(bytes[i..<i + 4])))
            i += 4
        default:
            return nil
        }
    }
    return fields
}

private func describeField(_ field: ProtoField, depth: Int) -> String {
    switch field.wireType {
    case 0:
        return "\(field.number):v=\(field.varintValue ?? 0)"
    case 1:
        return "\(field.number):i64"
    case 5:
        return "\(field.number):i32"
    case 2:
        let bytes = field.bytes ?? []
        // Every nested message in this response (wrapper, data, line,
        // colors) starts at field 1; requiring that keeps lyric text
        // strings from being misread as messages.
        if depth < 3, let nested = parseProtoFields(bytes),
           nested.first?.number == 1 {
            return "\(field.number):msg{\(summarizeFields(nested, depth: depth + 1))}"
        }
        let looksLikeText = bytes.allSatisfy { $0 >= 0x20 || $0 == 0x09 || $0 == 0x0a || $0 == 0x0d || $0 >= 0x80 }
        if looksLikeText, let s = String(bytes: bytes, encoding: .utf8) {
            let preview = s.count > 24 ? String(s.prefix(24)) + "…" : s
            return "\(field.number):str(\"\(preview)\")"
        }
        return "\(field.number):bytes(\(bytes.count))"
    default:
        return "\(field.number):w\(field.wireType)"
    }
}

private func summarizeFields(_ fields: [ProtoField], depth: Int) -> String {
    // Group repeated fields: describe the first occurrence, count the rest.
    var order: [Int] = []
    var firstByNumber: [Int: ProtoField] = [:]
    var countByNumber: [Int: Int] = [:]
    for f in fields {
        if firstByNumber[f.number] == nil {
            firstByNumber[f.number] = f
            order.append(f.number)
        }
        countByNumber[f.number, default: 0] += 1
    }
    return order.map { n in
        let d = describeField(firstByNumber[n]!, depth: depth)
        let c = countByNumber[n] ?? 1
        return c > 1 ? "\(d)×\(c)" : d
    }.joined(separator: " ")
}

func logLyricsResponseShape(_ buffer: Data, context: String) {
    guard !buffer.isEmpty else { return }

    shapeDumpLock.lock()
    let already = shapeDumpedPaths.contains(context)
    if !already { shapeDumpedPaths.insert(context) }
    shapeDumpLock.unlock()
    guard !already else { return }

    let bytes = [UInt8](buffer)
    guard let fields = parseProtoFields(bytes) else {
        writeDebugLog("[LyricsShape] \(context): unparsable (\(bytes.count) bytes)")
        return
    }
    writeDebugLog("[LyricsShape] \(context): \(summarizeFields(fields, depth: 0))")
}

// MARK: - Delivered lyrics payload shape dump (diagnosis markers, §5)
//
// [LyricsShape] above dumps the ORIGINAL response buffer, before any
// substitution — it cannot show what Spotify actually received. This
// companion dumps the payload a hook is about to DELIVER (substituted or
// original), under the [LyricsShapeSub] prefix, deduped separately so an
// original and a delivered dump for the same path can both appear.

private var deliveredShapeDumpedPaths = Set<String>()

func logLyricsDeliveredShape(_ buffer: Data, context: String) {
    guard !buffer.isEmpty else { return }

    shapeDumpLock.lock()
    let key = "sub:" + context
    let already = deliveredShapeDumpedPaths.contains(key)
    if !already { deliveredShapeDumpedPaths.insert(key) }
    shapeDumpLock.unlock()
    guard !already else { return }

    let bytes = [UInt8](buffer)
    guard let fields = parseProtoFields(bytes) else {
        writeDebugLog("[LyricsShapeSub] \(context): unparsable (\(bytes.count) bytes)")
        return
    }
    writeDebugLog("[LyricsShapeSub] \(context): \(summarizeFields(fields, depth: 0))")
}
