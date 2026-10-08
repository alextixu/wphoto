import Foundation

/// 一句字幕（毫秒）
struct SubtitleCue {
    let startMs: Int
    let endMs: Int
    let text: String
}

/// 依開始時間排序的字幕，用來查「某個時間點該顯示哪幾句」
struct SubtitleCues {
    private let cues: [SubtitleCue]

    init(_ cues: [SubtitleCue]) {
        self.cues = cues
            .filter { $0.endMs > $0.startMs && !$0.text.isEmpty }
            .sorted { $0.startMs < $1.startMs }
    }

    var isEmpty: Bool { cues.isEmpty }

    /// 時間點 ms 正在顯示的字幕（同時有多句時依開始時間由上而下排列）
    func text(at ms: Int) -> String {
        // 二分搜尋：最後一句 startMs <= ms
        var low = 0, high = cues.count
        while low < high {
            let mid = (low + high) / 2
            if cues[mid].startMs <= ms { low = mid + 1 } else { high = mid }
        }
        var active: [String] = []
        var i = low - 1
        // 往回看幾句就夠了：重疊的字幕很少超過兩三句
        while i >= 0 && i >= low - 8 {
            let cue = cues[i]
            if cue.endMs > ms { active.append(cue.text) }
            i -= 1
        }
        return active.reversed().joined(separator: "\n")
    }
}

/// 外掛字幕檔（SRT / WebVTT / ASS / SSA）→ 字幕清單。
/// 只取文字：ASS 的位置、特效、繪圖都略過（第二字幕由 App 自己用系統字型畫，中文不會變方格）。
enum SubtitleFileParser {
    /// 可以當第二字幕的外掛字幕格式（.sub 是依影格數計時的 MicroDVD，需要影格率，不支援）
    static let supportedExts: Set<String> = ["srt", "vtt", "ass", "ssa"]

    static func canParse(_ url: URL) -> Bool {
        supportedExts.contains(url.pathExtension.lowercased())
    }

    static func parse(_ url: URL) throws -> [SubtitleCue] {
        let data = try Data(contentsOf: url)
        let text = SubtitleText.decode(data)
        switch url.pathExtension.lowercased() {
        case "ass", "ssa": return parseASS(text)
        default: return parseSRTorVTT(text)   // WebVTT 與 SRT 的時間軸寫法幾乎一樣
        }
    }

    // MARK: SRT / WebVTT

    private static func parseSRTorVTT(_ text: String) -> [SubtitleCue] {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        var cues: [SubtitleCue] = []
        for block in normalized.components(separatedBy: "\n\n") {
            let lines = block.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            guard let arrowIndex = lines.firstIndex(where: { $0.contains("-->") }) else { continue }
            let parts = lines[arrowIndex].components(separatedBy: "-->")
            guard parts.count == 2,
                  let start = SubtitleText.parseTimestamp(parts[0]),
                  // WebVTT 的時間後面可能接位置設定（"00:01.000 --> 00:04.000 line:0"）
                  let end = SubtitleText.parseTimestamp(parts[1].split(separator: " ", omittingEmptySubsequences: true).first.map(String.init) ?? "")
            else { continue }
            let body = lines[(arrowIndex + 1)...].joined(separator: "\n")
            let cleaned = SubtitleText.cleanMarkup(body)
            if !cleaned.isEmpty {
                cues.append(SubtitleCue(startMs: start, endMs: end, text: cleaned))
            }
        }
        return cues
    }

    // MARK: ASS / SSA

    private static func parseASS(_ text: String) -> [SubtitleCue] {
        var cues: [SubtitleCue] = []
        var inEvents = false
        // 預設欄位順序；檔案裡的 Format 行會覆蓋
        var fields = ["layer", "start", "end", "style", "name", "marginl", "marginr", "marginv", "effect", "text"]
        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") {
                inEvents = line.lowercased() == "[events]"
                continue
            }
            guard inEvents else { continue }
            if line.lowercased().hasPrefix("format:") {
                fields = line.dropFirst("format:".count).split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
                continue
            }
            guard line.lowercased().hasPrefix("dialogue:"),
                  let startIndex = fields.firstIndex(of: "start"),
                  let endIndex = fields.firstIndex(of: "end"),
                  let textIndex = fields.firstIndex(of: "text") else { continue }
            // 文字是最後一欄，裡面可能有逗號：只切 fields.count - 1 刀
            let values = line.dropFirst("dialogue:".count)
                .split(separator: ",", maxSplits: fields.count - 1, omittingEmptySubsequences: false)
                .map(String.init)
            guard values.count == fields.count,
                  let start = SubtitleText.parseTimestamp(values[startIndex]),
                  let end = SubtitleText.parseTimestamp(values[endIndex]) else { continue }
            let cleaned = SubtitleText.cleanASS(values[textIndex])
            if !cleaned.isEmpty {
                cues.append(SubtitleCue(startMs: start, endMs: end, text: cleaned))
            }
        }
        return cues
    }
}

/// 字幕文字的共用處理：編碼、時間、標記
enum SubtitleText {
    /// 解碼字幕檔：BOM → UTF-8 → 依介面語言猜 Big5 或 GB18030（與 VLC 主字幕的規則一致）
    static func decode(_ data: Data) -> String {
        if data.starts(with: [0xEF, 0xBB, 0xBF]) {
            return String(decoding: data.dropFirst(3), as: UTF8.self)
        }
        if data.starts(with: [0xFF, 0xFE]), let s = String(data: data, encoding: .utf16LittleEndian) {
            return s.hasPrefix("\u{FEFF}") ? String(s.dropFirst()) : s
        }
        if data.starts(with: [0xFE, 0xFF]), let s = String(data: data, encoding: .utf16BigEndian) {
            return s.hasPrefix("\u{FEFF}") ? String(s.dropFirst()) : s
        }
        if let s = String(data: data, encoding: .utf8) { return s }

        let big5 = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(
            CFStringEncoding(CFStringEncodings.big5_HKSCS_1999.rawValue)))
        let gb18030 = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(
            CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))
        let simplified = (Bundle.main.preferredLocalizations.first ?? "") == "zh-Hans"
        for encoding in simplified ? [gb18030, big5] : [big5, gb18030] {
            if let s = String(data: data, encoding: encoding) { return s }
        }
        return String(decoding: data, as: UTF8.self)   // 最後手段：無法解的字元變成 �
    }

    /// "01:02:03,456"、"01:02:03.456"、"02:03.456"（WebVTT）、"1:02:03.45"（ASS 的百分之一秒）→ 毫秒
    static func parseTimestamp(_ raw: String) -> Int? {
        let s = raw.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        let parts = s.split(separator: ":").map(String.init)
        guard (2...3).contains(parts.count) else { return nil }
        let secondParts = parts[parts.count - 1].split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard let seconds = Int(secondParts[0]),
              let minutes = Int(parts[parts.count - 2]) else { return nil }
        let hours = parts.count == 3 ? (Int(parts[0]) ?? -1) : 0
        guard hours >= 0 else { return nil }
        var fraction = 0
        if secondParts.count > 1 {
            // 小數位數不固定：".5" = 500ms、".45" = 450ms、".456" = 456ms
            let digits = String(secondParts[1].prefix(3).filter(\.isNumber))
            if let value = Int(digits) {
                fraction = value * [1, 100, 10, 1][digits.count]
            }
        }
        return ((hours * 60 + minutes) * 60 + seconds) * 1000 + fraction
    }

    /// SRT / WebVTT：去掉 <i>、<font …> 等 HTML 標記與 {\an8} 這類 ASS 標記
    static func cleanMarkup(_ text: String) -> String {
        var s = text.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: "\\{[^}]*\\}", with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&amp;", with: "&")
        return s.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }.joined(separator: "\n")
    }

    /// ASS 對白：去掉 {…} 特效標記，\N、\n 換行，\h 空白；繪圖指令（\p1）整句略過
    static func cleanASS(_ text: String) -> String {
        if text.range(of: "\\{[^}]*\\\\p[1-9]", options: .regularExpression) != nil { return "" }
        var s = text.replacingOccurrences(of: "\\{[^}]*\\}", with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: "\\N", with: "\n")
            .replacingOccurrences(of: "\\n", with: "\n")
            .replacingOccurrences(of: "\\h", with: " ")
        return s.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }.joined(separator: "\n")
    }
}
