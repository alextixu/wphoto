import Foundation
import SwiftUI

/// 第二字幕（雙字幕）。libvlc 3 一次只能顯示一條字幕，所以第二條由 App 自己讀檔、依播放時間畫在畫面上。
/// 來源：外掛字幕檔（SRT / WebVTT / ASS / SSA）與 MKV 內嵌的文字字幕軌。
/// 選過的語言會記住，下一集有同語言的字幕時自動開啟。
@MainActor
final class SecondarySubtitleModel: ObservableObject {
    enum Source: Equatable {
        case file(URL)
        case embedded(EmbeddedSubtitleTrack)
    }

    struct Option: Identifiable, Equatable {
        let id: Int
        let source: Source
        let title: String
        /// 正規化後的語言（"en"、"zh-Hant"…），用來在下一集自動選同語言
        let languageKey: String?
    }

    enum Position: String {
        case top, bottom
    }

    @Published private(set) var options: [Option] = []
    @Published private(set) var selectedID: Int?
    @Published private(set) var cues: SubtitleCues?
    @Published private(set) var isLoading = false
    @Published private(set) var showsFailure = false
    @Published var position: Position {
        didSet { UserDefaults.standard.set(position.rawValue, forKey: Self.positionKey) }
    }

    private static let languageDefaultsKey = "secondarySubtitleLanguage"
    private static let positionKey = "secondarySubtitlePosition"
    private var videoURL: URL?
    private var configured = false
    private var loadTask: Task<Void, Never>?
    /// 讀檔／掃描 MKV 的背景工作（分離的 Task 不會跟著 loadTask 取消，要另外取消）
    private var scanTask: Task<[SubtitleCue]?, Never>?

    init() {
        position = Position(rawValue: UserDefaults.standard.string(forKey: Self.positionKey) ?? "") ?? .bottom
    }

    /// 關閉播放畫面時呼叫：停止還在進行的讀檔／掃描
    func stop() {
        cancelLoading()
    }

    private func cancelLoading() {
        scanTask?.cancel()
        loadTask?.cancel()
        scanTask = nil
        loadTask = nil
    }

    // MARK: - 準備選項

    /// 列出可用的第二字幕；上次選過的語言如果有，就自動載入
    func configure(videoURL: URL, subtitleFiles: [URL]) async {
        guard !configured else { return }
        configured = true
        self.videoURL = videoURL

        var result: [Option] = []
        for file in subtitleFiles where SubtitleFileParser.canParse(file) {
            result.append(Option(id: result.count, source: .file(file), title: file.lastPathComponent,
                                 languageKey: Self.languageKey(forFileName: file, video: videoURL)))
        }
        if MatroskaSubtitles.isMatroska(videoURL) {
            let tracks = await Task.detached(priority: .utility) {
                (try? MatroskaSubtitles.textTracks(in: videoURL)) ?? []
            }.value
            for (index, track) in tracks.enumerated() {
                result.append(Option(id: result.count, source: .embedded(track),
                                     title: Self.title(for: track, number: index + 1),
                                     languageKey: Self.normalizedLanguage(track.language)))
            }
        }
        options = result

        // 下一集自動開啟同語言的第二字幕
        if let saved = UserDefaults.standard.string(forKey: Self.languageDefaultsKey),
           let match = result.first(where: { $0.languageKey == saved }) {
            load(match)
        }
    }

    // MARK: - 選擇

    /// nil = 關閉第二字幕
    func select(_ id: Int?) {
        guard let id, let option = options.first(where: { $0.id == id }) else {
            cancelLoading()
            selectedID = nil
            cues = nil
            isLoading = false
            UserDefaults.standard.removeObject(forKey: Self.languageDefaultsKey)
            return
        }
        if let key = option.languageKey {
            UserDefaults.standard.set(key, forKey: Self.languageDefaultsKey)
        }
        load(option)
    }

    private func load(_ option: Option) {
        cancelLoading()
        selectedID = option.id
        cues = nil
        isLoading = true
        showsFailure = false
        let source = option.source
        let video = videoURL
        // 讀檔與掃描 MKV 都在背景執行緒；掃描整部 MKV 只讀元素標頭，但大檔仍要幾秒
        let scan = Task.detached(priority: .utility) { () -> [SubtitleCue]? in
            switch source {
            case .file(let url):
                return try? SubtitleFileParser.parse(url)
            case .embedded(let track):
                guard let video else { return nil }
                return try? MatroskaSubtitles.cues(in: video, track: track)
            }
        }
        scanTask = scan
        loadTask = Task { [weak self] in
            let parsed = await scan.value
            guard let self, !Task.isCancelled, self.selectedID == option.id else { return }
            self.isLoading = false
            if let parsed, !parsed.isEmpty {
                self.cues = SubtitleCues(parsed)
            } else {
                self.selectedID = nil
                self.showsFailure = true
                try? await Task.sleep(for: .seconds(3))
                if !Task.isCancelled { self.showsFailure = false }
            }
        }
    }

    // MARK: - 名稱與語言

    private static func title(for track: EmbeddedSubtitleTrack, number: Int) -> String {
        let language = track.language == "und" ? nil : VLCTrackLabel.localizedLanguage(track.language)
        switch (track.name, language) {
        case let (name?, language?):
            return String(format: String(localized: "TrackLanguage"), name, language)
        case let (name?, nil):
            return name
        case let (nil, language?):
            return language
        case (nil, nil):
            return String(format: String(localized: "SubtitleTrack"), number)
        }
    }

    /// "chi" / "zho" / "zh-TW" / "zh-Hant" / "en-US" / "eng" → "zh-Hant" / "en" …（只為了比對下一集的同語言字幕）
    static func normalizedLanguage(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        let lower = raw.lowercased().replacingOccurrences(of: "_", with: "-")
        let parts = lower.split(separator: "-").map(String.init)
        guard let first = parts.first else { return nil }
        let threeToTwo = ["chi": "zh", "zho": "zh", "eng": "en", "jpn": "ja", "kor": "ko", "fre": "fr", "fra": "fr",
                          "ger": "de", "deu": "de", "spa": "es", "ita": "it", "por": "pt", "rus": "ru", "tha": "th",
                          "vie": "vi", "ind": "id", "may": "ms", "msa": "ms", "dut": "nl", "nld": "nl"]
        var base = threeToTwo[first] ?? first
        // 中文：常見的檔名寫法
        if ["chs", "sc", "gb"].contains(first) { base = "zh-hans" }
        if ["cht", "tc", "big5"].contains(first) { base = "zh-hant" }
        if base == "zh" {
            let rest = Set(parts.dropFirst())
            if !rest.isDisjoint(with: ["hant", "tw", "hk", "mo"]) { base = "zh-hant" }
            if !rest.isDisjoint(with: ["hans", "cn", "sg"]) { base = "zh-hans" }
        }
        // 只接受 2～3 個字母的語言代碼與中文繁簡標記，避免把檔名裡的一般英文字當成語言
        let isCode = (2...3).contains(base.count) && base.allSatisfy { $0.isASCII && $0.isLetter }
        guard isCode || base == "zh-hant" || base == "zh-hans" else { return nil }
        return base
    }

    /// 外掛字幕的語言：取檔名去掉影片檔名後剩下的語言標記（"Show.E01.zh-TW.srt" → "zh-Hant"）
    private static func languageKey(forFileName file: URL, video: URL) -> String? {
        let base = video.deletingPathExtension().lastPathComponent.lowercased()
        var name = file.deletingPathExtension().lastPathComponent.lowercased()
        if name.hasPrefix(base) { name = String(name.dropFirst(base.count)) }
        let tokens = name.split(whereSeparator: { $0 == "." || $0 == " " || $0 == "[" || $0 == "]" || $0 == "(" || $0 == ")" })
        for token in tokens.reversed() {
            let t = String(token)
            if ["sdh", "forced", "cc", "hi", "default"].contains(t) { continue }
            if let key = normalizedLanguage(t) { return key }
        }
        return nil
    }
}
