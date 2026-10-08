import Foundation
import Compression

/// MKV 內嵌的文字字幕軌（SRT / ASS / SSA / WebVTT）
struct EmbeddedSubtitleTrack: Equatable, Sendable {
    let number: UInt64
    let codec: String
    /// 語言代碼：LanguageBCP47（例如 "zh-Hant"）優先，其次 ISO 639-2（例如 "chi"）
    let language: String
    let name: String?
    /// 0 = zlib、3 = 去標頭（header stripping）；nil = 沒有壓縮
    fileprivate let compressionAlgo: UInt64?
    fileprivate let compressionSettings: Data?
}

enum MatroskaError: Error {
    case notMatroska
    case unsupportedTrack
}

/// 直接讀 MKV 檔，取出文字字幕軌（給第二字幕用；libvlc 3 一次只能顯示一條字幕）。
/// 只讀元素標頭，影片／音訊的資料區塊直接跳過，所以掃整部片也只會讀到檔案的一小部分。
enum MatroskaSubtitles {
    static func isMatroska(_ url: URL) -> Bool {
        ["mkv", "webm", "mks"].contains(url.pathExtension.lowercased())
    }

    private static let textCodecs: Set<String> = [
        "S_TEXT/UTF8", "S_TEXT/ASS", "S_TEXT/SSA", "S_TEXT/WEBVTT", "S_ASS", "S_SSA",
    ]

    // MARK: - 字幕軌清單（只讀到 Tracks 為止，很快）

    static func textTracks(in url: URL) throws -> [EmbeddedSubtitleTrack] {
        let r = try EBMLReader(url: url)
        let segment = try r.openSegment()
        let segmentEnd = segment.end ?? r.fileSize
        while r.position < segmentEnd {
            guard let el = try r.readElementHeader() else { break }
            switch el.id {
            case ID.tracks:
                return try parseTracks(r, el).filter { textCodecs.contains($0.codec) }
            case ID.cluster:
                return []   // Tracks 應該在第一個 Cluster 之前；不是的話就不支援
            default:
                guard let end = el.end else { return [] }
                r.seek(to: end)
            }
        }
        return []
    }

    // MARK: - 取出某一軌的所有字幕（掃描整個檔案，可取消）

    static func cues(in url: URL, track: EmbeddedSubtitleTrack) throws -> [SubtitleCue] {
        let r = try EBMLReader(url: url)
        let segment = try r.openSegment()
        let segmentEnd = segment.end ?? r.fileSize
        var timecodeScale: UInt64 = 1_000_000   // 預設 1ms
        var raw: [(startMs: Int, durationMs: Int?, text: String)] = []

        while r.position < segmentEnd {
            try Task.checkCancellation()
            guard let el = try r.readElementHeader() else { break }
            switch el.id {
            case ID.info:
                guard let end = el.end else { return [] }
                while r.position < end {
                    guard let child = try r.readElementHeader(), let childEnd = child.end else { break }
                    if child.id == ID.timecodeScale, let size = child.size {
                        timecodeScale = try r.readUInt(size) ?? timecodeScale
                    }
                    r.seek(to: childEnd)
                }
                r.seek(to: end)
            case ID.cluster:
                try readCluster(r, el, track: track, scale: timecodeScale, segmentEnd: segmentEnd) { raw.append($0) }
            default:
                guard let end = el.end else { break }
                r.seek(to: end)
            }
        }

        // SimpleBlock 沒有長度：顯示到下一句開始（最多 5 秒）
        raw.sort { $0.startMs < $1.startMs }
        var cues: [SubtitleCue] = []
        for (i, item) in raw.enumerated() {
            let end: Int
            if let d = item.durationMs, d > 0 {
                end = item.startMs + d
            } else {
                let next = raw[(i + 1)...].first(where: { $0.startMs > item.startMs })?.startMs
                end = min(next ?? item.startMs + 5000, item.startMs + 5000)
            }
            cues.append(SubtitleCue(startMs: item.startMs, endMs: end, text: item.text))
        }
        return cues
    }

    // MARK: - 內部

    private enum ID {
        static let ebml: UInt32 = 0x1A45DFA3
        static let segment: UInt32 = 0x18538067
        static let seekHead: UInt32 = 0x114D9B74
        static let info: UInt32 = 0x1549A966
        static let timecodeScale: UInt32 = 0x2AD7B1
        static let tracks: UInt32 = 0x1654AE6B
        static let trackEntry: UInt32 = 0xAE
        static let trackNumber: UInt32 = 0xD7
        static let trackType: UInt32 = 0x83
        static let codecID: UInt32 = 0x86
        static let language: UInt32 = 0x22B59C
        static let languageBCP47: UInt32 = 0x22B59D
        static let name: UInt32 = 0x536E
        static let contentEncodings: UInt32 = 0x6D80
        static let contentEncoding: UInt32 = 0x6240
        static let contentEncodingType: UInt32 = 0x5033
        static let contentCompression: UInt32 = 0x5034
        static let contentCompAlgo: UInt32 = 0x4254
        static let contentCompSettings: UInt32 = 0x4255
        static let cluster: UInt32 = 0x1F43B675
        static let clusterTimecode: UInt32 = 0xE7
        static let simpleBlock: UInt32 = 0xA3
        static let blockGroup: UInt32 = 0xA0
        static let block: UInt32 = 0xA1
        static let blockDuration: UInt32 = 0x9B
        static let cues: UInt32 = 0x1C53BB6B
        static let chapters: UInt32 = 0x1043A770
        static let tags: UInt32 = 0x1254C367
        static let attachments: UInt32 = 0x1941A469
        /// Segment 的直接子元素：未知長度的 Cluster 讀到這些就代表 Cluster 結束了
        static let topLevel: Set<UInt32> = [seekHead, info, tracks, cluster, cues, chapters, tags, attachments]
    }

    private static let subtitleTrackType: UInt64 = 0x11

    private static func parseTracks(_ r: EBMLReader, _ tracksEl: EBMLElement) throws -> [EmbeddedSubtitleTrack] {
        guard let tracksEnd = tracksEl.end else { return [] }
        var result: [EmbeddedSubtitleTrack] = []
        while r.position < tracksEnd {
            guard let entry = try r.readElementHeader(), let entryEnd = entry.end else { break }
            guard entry.id == ID.trackEntry else { r.seek(to: entryEnd); continue }

            var number: UInt64 = 0, type: UInt64 = 0
            var codec = "", language = "eng", languageBCP47: String?, name: String?
            var encodingType: UInt64 = 0, compAlgo: UInt64?, compSettings: Data?
            var hasEncoding = false
            while r.position < entryEnd {
                guard let child = try r.readElementHeader(), let childEnd = child.end, let size = child.size else { break }
                switch child.id {
                case ID.trackNumber: number = try r.readUInt(size) ?? 0
                case ID.trackType: type = try r.readUInt(size) ?? 0
                case ID.codecID: codec = try r.readString(size)
                case ID.language: language = try r.readString(size)
                case ID.languageBCP47: languageBCP47 = try r.readString(size)
                case ID.name: name = try r.readString(size)
                case ID.contentEncodings:
                    // ContentEncodings → ContentEncoding → (ContentEncodingType, ContentCompression → Algo / Settings)
                    while r.position < childEnd {
                        guard let enc = try r.readElementHeader(), let encEnd = enc.end else { break }
                        if enc.id == ID.contentEncoding {
                            hasEncoding = true
                            compAlgo = 0   // ContentCompAlgo 的預設值是 zlib
                            while r.position < encEnd {
                                guard let e = try r.readElementHeader(), let eEnd = e.end, let eSize = e.size else { break }
                                if e.id == ID.contentEncodingType {
                                    encodingType = try r.readUInt(eSize) ?? 0
                                } else if e.id == ID.contentCompression {
                                    while r.position < eEnd {
                                        guard let c = try r.readElementHeader(), let cEnd = c.end, let cSize = c.size else { break }
                                        if c.id == ID.contentCompAlgo { compAlgo = try r.readUInt(cSize) ?? 0 }
                                        if c.id == ID.contentCompSettings { compSettings = try r.readBytes(Int(cSize)) }
                                        r.seek(to: cEnd)
                                    }
                                }
                                r.seek(to: eEnd)
                            }
                        }
                        r.seek(to: encEnd)
                    }
                default:
                    break
                }
                r.seek(to: childEnd)
            }
            r.seek(to: entryEnd)

            // 加密的軌道（ContentEncodingType 1）讀不了
            guard type == subtitleTrackType, number > 0, !(hasEncoding && encodingType != 0) else { continue }
            // 只支援 zlib (0) 與去標頭 (3) 兩種壓縮
            if hasEncoding, let algo = compAlgo, algo != 0 && algo != 3 { continue }
            let trimmedBCP47 = languageBCP47?.trimmingCharacters(in: .whitespaces)
            result.append(EmbeddedSubtitleTrack(
                number: number,
                codec: codec,
                language: (trimmedBCP47?.isEmpty == false ? trimmedBCP47! : language),
                name: name?.isEmpty == false ? name : nil,
                compressionAlgo: hasEncoding ? compAlgo : nil,
                compressionSettings: compSettings))
        }
        return result
    }

    private static func readCluster(_ r: EBMLReader, _ cluster: EBMLElement, track: EmbeddedSubtitleTrack,
                                    scale: UInt64, segmentEnd: UInt64,
                                    emit: ((startMs: Int, durationMs: Int?, text: String)) -> Void) throws {
        let end = cluster.end ?? segmentEnd
        var clusterTime: UInt64 = 0

        func emitBlock(_ block: (relTime: Int16, text: String), durationTicks: UInt64?) {
            let ticks = Int64(clusterTime) + Int64(block.relTime)
            let startMs = Int(ticks * Int64(scale) / 1_000_000)
            let durationMs = durationTicks.map { Int(Int64($0) * Int64(scale) / 1_000_000) }
            emit((startMs: startMs, durationMs: durationMs, text: block.text))
        }

        while r.position < end {
            let headerStart = r.position
            guard let el = try r.readElementHeader() else { return }
            // 未知長度的 Cluster：讀到下一個頂層元素就結束，退回讓外層處理
            if cluster.end == nil && ID.topLevel.contains(el.id) {
                r.seek(to: headerStart)
                return
            }
            guard let elEnd = el.end, let size = el.size else { return }
            switch el.id {
            case ID.clusterTimecode:
                clusterTime = try r.readUInt(size) ?? 0
            case ID.simpleBlock:
                if let block = try readBlock(r, end: elEnd, track: track) {
                    emitBlock(block, durationTicks: nil)
                }
            case ID.blockGroup:
                var found: (relTime: Int16, text: String)?
                var durationTicks: UInt64?
                while r.position < elEnd {
                    guard let child = try r.readElementHeader(), let childEnd = child.end, let childSize = child.size else { break }
                    if child.id == ID.block {
                        found = try readBlock(r, end: childEnd, track: track)
                    } else if child.id == ID.blockDuration {
                        durationTicks = try r.readUInt(childSize)
                    }
                    r.seek(to: childEnd)
                }
                if let found { emitBlock(found, durationTicks: durationTicks) }
            default:
                break
            }
            r.seek(to: elEnd)
        }

    }

    /// 讀一個 Block / SimpleBlock：不是要的軌道就回傳 nil（呼叫端會跳到元素結尾）
    private static func readBlock(_ r: EBMLReader, end: UInt64, track: EmbeddedSubtitleTrack) throws -> (relTime: Int16, text: String)? {
        guard let trackNumber = try r.readVint(), trackNumber == track.number,
              let header = try r.readBytes(3) else { return nil }
        let relTime = Int16(bitPattern: UInt16(header[header.startIndex]) << 8 | UInt16(header[header.startIndex + 1]))
        let flags = header[header.startIndex + 2]
        guard flags & 0x06 == 0 else { return nil }   // 有 lacing 的字幕極少見，略過
        guard end > r.position, let payload = try r.readBytes(Int(end - r.position)) else { return nil }

        var data = payload
        switch track.compressionAlgo {
        case 0?:
            guard let inflated = inflateZlib(payload) else { return nil }
            data = inflated
        case 3?:
            data = (track.compressionSettings ?? Data()) + payload
        default:
            break
        }
        let text = String(decoding: data, as: UTF8.self)
        let cleaned: String
        switch track.codec {
        case "S_TEXT/ASS", "S_TEXT/SSA", "S_ASS", "S_SSA":
            // MKV 裡的 ASS 區塊：ReadOrder, Layer, Style, Name, MarginL, MarginR, MarginV, Effect, Text
            let fields = text.split(separator: ",", maxSplits: 8, omittingEmptySubsequences: false)
            cleaned = fields.count == 9 ? SubtitleText.cleanASS(String(fields[8])) : ""
        default:
            cleaned = SubtitleText.cleanMarkup(text)
        }
        return cleaned.isEmpty ? nil : (relTime, cleaned)
    }

    /// Matroska 的 zlib 是帶 2 bytes 標頭的 zlib 格式；Compression 框架的 ZLIB 是不含標頭的 raw deflate
    private static func inflateZlib(_ data: Data) -> Data? {
        guard data.count > 2 else { return nil }
        let src = Data(data.dropFirst(2))
        for capacity in [64 * 1024, 1024 * 1024] {
            var out = Data(count: capacity)
            let written = out.withUnsafeMutableBytes { (dst: UnsafeMutableRawBufferPointer) -> Int in
                src.withUnsafeBytes { (s: UnsafeRawBufferPointer) -> Int in
                    guard let d = dst.bindMemory(to: UInt8.self).baseAddress,
                          let p = s.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                    return compression_decode_buffer(d, capacity, p, src.count, nil, COMPRESSION_ZLIB)
                }
            }
            if written > 0 && written < capacity { return out.prefix(written) }
        }
        return nil
    }
}

// MARK: - EBML 讀取器

struct EBMLElement {
    let id: UInt32
    let dataStart: UInt64
    /// nil = 未知長度
    let size: UInt64?
    var end: UInt64? { size.map { dataStart + $0 } }
}

/// 帶小緩衝的循序讀取器：跳過大區塊時直接移動位置，下次讀取才重新定位
final class EBMLReader {
    let fileSize: UInt64
    private(set) var position: UInt64 = 0
    private let handle: FileHandle
    private var buffer = Data()
    private var bufferStart: UInt64 = 0
    /// 跳過影片區塊後通常只需要下一個元素的標頭，緩衝不必大
    private let chunkSize = 4096

    init(url: URL) throws {
        handle = try FileHandle(forReadingFrom: url)
        fileSize = try handle.seekToEnd()
    }

    deinit { try? handle.close() }

    func seek(to offset: UInt64) { position = offset }

    /// 確保緩衝裡有從 position 開始的 n bytes
    private func ensure(_ n: Int) throws -> Bool {
        let bufferEnd = bufferStart + UInt64(buffer.count)
        if position >= bufferStart && position + UInt64(n) <= bufferEnd { return true }
        guard position < fileSize else { return false }
        try handle.seek(toOffset: position)
        buffer = try handle.read(upToCount: max(n, chunkSize)) ?? Data()
        bufferStart = position
        return buffer.count >= n
    }

    private func byte(at offsetInBuffer: Int) -> UInt8 {
        buffer[buffer.startIndex + offsetInBuffer]
    }

    func readByte() throws -> UInt8? {
        guard try ensure(1) else { return nil }
        let b = byte(at: Int(position - bufferStart))
        position += 1
        return b
    }

    func readBytes(_ n: Int) throws -> Data? {
        if n <= 0 { return Data() }
        guard try ensure(n) else { return nil }
        let start = buffer.startIndex + Int(position - bufferStart)
        let d = buffer.subdata(in: start..<(start + n))
        position += UInt64(n)
        return d
    }

    /// Element ID：1–4 bytes，保留長度標記位元
    func readID() throws -> UInt32? {
        guard let first = try readByte() else { return nil }
        var extra = 0
        var mask: UInt8 = 0x80
        while extra < 4 && first & mask == 0 { mask >>= 1; extra += 1 }
        guard extra < 4 else { return nil }
        var value = UInt32(first)
        for _ in 0..<extra {
            guard let b = try readByte() else { return nil }
            value = value << 8 | UInt32(b)
        }
        return value
    }

    /// 可變長度整數（長度、軌道編號）：去掉長度標記位元；unknown = 數值位元全部為 1
    func readVintWithUnknown() throws -> (value: UInt64, unknown: Bool)? {
        guard let first = try readByte() else { return nil }
        var extra = 0
        var mask: UInt8 = 0x80
        while extra < 8 && first & mask == 0 { mask >>= 1; extra += 1 }
        guard extra < 8 else { return nil }
        let firstBits = UInt64(first & (mask &- 1))
        var value = firstBits
        var allOnes = firstBits == UInt64(mask &- 1)
        for _ in 0..<extra {
            guard let b = try readByte() else { return nil }
            value = value << 8 | UInt64(b)
            if b != 0xFF { allOnes = false }
        }
        return (value, allOnes)
    }

    func readVint() throws -> UInt64? {
        try readVintWithUnknown()?.value
    }

    func readElementHeader() throws -> EBMLElement? {
        guard let id = try readID(), let size = try readVintWithUnknown() else { return nil }
        return EBMLElement(id: id, dataStart: position, size: size.unknown ? nil : size.value)
    }

    func readUInt(_ size: UInt64) throws -> UInt64? {
        guard size <= 8, let data = try readBytes(Int(size)) else { return nil }
        return data.reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
    }

    func readString(_ size: UInt64) throws -> String {
        guard size < 4096, let data = try readBytes(Int(size)) else { return "" }
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: CharacterSet(charactersIn: "\0").union(.whitespaces))
    }

    /// 檢查 EBML 標頭，回傳 Segment 元素（之後的讀取位置在 Segment 資料開頭）
    func openSegment() throws -> EBMLElement {
        guard let header = try readElementHeader(), header.id == 0x1A45DFA3, let headerEnd = header.end else {
            throw MatroskaError.notMatroska
        }
        seek(to: headerEnd)
        // Segment 前面可能有 Void 元素
        while let el = try readElementHeader() {
            if el.id == 0x18538067 { return el }
            guard let end = el.end else { break }
            seek(to: end)
        }
        throw MatroskaError.notMatroska
    }
}
