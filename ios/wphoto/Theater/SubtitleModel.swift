import Foundation
import SwiftUI

/// App 自己顯示的字幕（主字幕與第二字幕）。
///
/// 為什麼不交給 VLC：libvlc 3 在 iPhone 上找不到可用的中文字型，中文會變成方格，而指定蘋方字型會讓
/// 整個文字渲染器載入失敗、字幕全部消失。所以文字字幕（外掛 SRT / WebVTT / ASS / SSA、MKV 內嵌文字軌）
/// 都由 App 讀取並用系統字型畫在畫面上；VLC 只負責它獨有的圖片字幕（PGS、VobSub…）。
/// 也因為兩條都由 App 畫，雙字幕可以整齊地上下排列。
@MainActor
final class SubtitleModel: ObservableObject {
    enum Source: Equatable {
        case file(URL)
        case embedded(EmbeddedSubtitleTrack)
    }

    struct Option: Identifiable, Equatable {
        let id: Int
        let source: Source
        let title: String
        /// 正規化後的語言（"en"、"zh-hant"…），用來記住偏好、下一集自動選同語言
        let languageKey: String?
        let isForced: Bool
        let isDefaultTrack: Bool
    }

    enum Slot { case main, second }

    enum Position: String {
        case top, bottom
    }

    @Published private(set) var options: [Option] = []
    @Published private(set) var mainID: Int?
    @Published private(set) var secondID: Int?
    @Published private(set) var mainCues: SubtitleCues?
    @Published private(set) var secondCues: SubtitleCues?
    @Published private(set) var mainLoading = false
    @Published private(set) var secondLoading = false
    @Published private(set) var showsFailure = false
    /// 不是 MKV、或 MKV 裡有圖片字幕：主字幕選單要另外列出 VLC 自己的字幕軌
    @Published private(set) var needsVLCTracks = false
    /// 第二字幕位置（下方 = 疊在主字幕上面）
    @Published var position: Position {
        didSet { UserDefaults.standard.set(position.rawValue, forKey: Self.positionDefaultsKey) }
    }

    private static let mainLanguageDefaultsKey = "mainSubtitleLanguage"
    private static let secondLanguageDefaultsKey = "secondarySubtitleLanguage"
    private static let positionDefaultsKey = "secondarySubtitlePosition"
    /// 使用者關掉主字幕時記下的值：下一集也不自動開
    private static let offMarker = "off"

    private var videoURL: URL?
    private var configured = false
    /// 已讀過的字幕（主字幕／第二字幕互換時不必重讀）
    private var cache: [Int: SubtitleCues] = [:]
    private var scanTasks: [Int: Task<[SubtitleCue]?, Never>] = [:]
    private var loadTasks: [Slot: Task<Void, Never>] = [:]

    init() {
        position = Position(rawValue: UserDefaults.standard.string(forKey: Self.positionDefaultsKey) ?? "") ?? .bottom
    }

    // MARK: - 準備

    /// 列出字幕來源並自動選主字幕／第二字幕
    func configure(videoURL: URL, subtitleFiles: [URL]) async {
        guard !configured else { return }
        configured = true
        self.videoURL = videoURL

        var result: [Option] = []
        for file in subtitleFiles where SubtitleFileParser.canParse(file) {
            result.append(Option(id: result.count, source: .file(file), title: file.lastPathComponent,
                                 languageKey: Self.languageKey(forFileName: file, video: videoURL),
                                 isForced: false, isDefaultTrack: false))
        }
        // 不是文字格式的外掛字幕（.sub）只有 VLC 能顯示
        var vlcOnly = subtitleFiles.contains { !SubtitleFileParser.canParse($0) }
        if MatroskaSubtitles.isMatroska(videoURL) {
            let tracks = await Task.detached(priority: .userInitiated) { () -> (text: [EmbeddedSubtitleTrack], otherCount: Int) in
                (try? MatroskaSubtitles.subtitleTracks(in: videoURL)) ?? (text: [], otherCount: 0)
            }.value
            for (index, track) in tracks.text.enumerated() {
                result.append(Option(id: result.count, source: .embedded(track),
                                     title: Self.title(for: track, number: index + 1),
                                     languageKey: Self.normalizedLanguage(track.language),
                                     isForced: track.isForced, isDefaultTrack: track.isDefault))
            }
            if tracks.otherCount > 0 { vlcOnly = true }
        } else {
            vlcOnly = true   // MP4 / AVI / TS 的內嵌字幕只能交給 VLC
        }
        options = result
        needsVLCTracks = vlcOnly

        if let main = defaultMainOption(video: videoURL) {
            load(main, into: .main)
        }
        if let saved = UserDefaults.standard.string(forKey: Self.secondLanguageDefaultsKey),
           let second = bestOption(language: saved, excluding: mainID) {
            load(second, into: .second)
        }
    }

    /// 自動選主字幕：上次選的語言 → 檔名對得上的外掛字幕 → 介面語言（中文）→ 標記為預設的字幕軌
    private func defaultMainOption(video: URL) -> Option? {
        let saved = UserDefaults.standard.string(forKey: Self.mainLanguageDefaultsKey)
        if saved == Self.offMarker { return nil }
        if let saved, let match = bestOption(language: saved, excluding: nil) { return match }
        if let own = options.first(where: {
            if case .file(let url) = $0.source { return SubtitleFinder.matches(url, video: video) }
            return false
        }) { return own }
        if let ui = Self.normalizedLanguage(Bundle.main.preferredLocalizations.first),
           ui.hasPrefix("zh"), let match = bestOption(language: ui, excluding: nil) {
            return match
        }
        return options.first { $0.isDefaultTrack && !$0.isForced && $0.source.isEmbedded }
    }

    /// 同語言的選項，非強制字幕優先
    private func bestOption(language: String, excluding: Int?) -> Option? {
        let candidates = options.filter { $0.languageKey == language && $0.id != excluding }
        return candidates.first(where: { !$0.isForced }) ?? candidates.first
    }

    // MARK: - 選擇

    /// 選主字幕；nil = 關閉
    func selectMain(_ id: Int?) {
        if let id, let option = options.first(where: { $0.id == id }) {
            UserDefaults.standard.set(option.languageKey ?? Self.offMarker, forKey: Self.mainLanguageDefaultsKey)
            load(option, into: .main)
        } else {
            clear(.main)
            UserDefaults.standard.set(Self.offMarker, forKey: Self.mainLanguageDefaultsKey)
        }
    }

    /// 主字幕改用 VLC 的字幕軌（圖片字幕）：App 這邊不顯示主字幕，也不記成「關閉」
    func handMainToVLC() {
        clear(.main)
    }

    /// 選第二字幕；nil = 關閉
    func selectSecond(_ id: Int?) {
        if let id, let option = options.first(where: { $0.id == id }) {
            if let key = option.languageKey {
                UserDefaults.standard.set(key, forKey: Self.secondLanguageDefaultsKey)
            }
            load(option, into: .second)
        } else {
            clear(.second)
            UserDefaults.standard.removeObject(forKey: Self.secondLanguageDefaultsKey)
        }
    }

    /// 關閉播放畫面時呼叫：停止還在進行的讀檔
    func stop() {
        loadTasks.values.forEach { $0.cancel() }
        scanTasks.values.forEach { $0.cancel() }
        loadTasks = [:]
        scanTasks = [:]
    }

    private func clear(_ slot: Slot) {
        loadTasks[slot]?.cancel()
        loadTasks[slot] = nil
        switch slot {
        case .main: mainID = nil; mainCues = nil; mainLoading = false
        case .second: secondID = nil; secondCues = nil; secondLoading = false
        }
    }

    private func load(_ option: Option, into slot: Slot) {
        loadTasks[slot]?.cancel()
        showsFailure = false
        switch slot {
        case .main: mainID = option.id; mainCues = nil
        case .second: secondID = option.id; secondCues = nil
        }
        if let cached = cache[option.id] {
            setCues(cached, slot: slot)
            return
        }
        setLoading(true, slot: slot)
        let scan = scanTask(for: option)
        loadTasks[slot] = Task { [weak self] in
            let parsed = await scan.value
            guard let self, !Task.isCancelled else { return }
            self.scanTasks[option.id] = nil
            guard self.currentID(slot) == option.id else { return }
            self.setLoading(false, slot: slot)
            if let parsed, !parsed.isEmpty {
                let cues = SubtitleCues(parsed)
                self.cache[option.id] = cues
                self.setCues(cues, slot: slot)
            } else {
                self.clear(slot)
                self.showsFailure = true
                try? await Task.sleep(for: .seconds(3))
                if !Task.isCancelled { self.showsFailure = false }
            }
        }
    }

    /// 同一個來源只讀一次（主字幕與第二字幕同時要同一軌時共用）
    private func scanTask(for option: Option) -> Task<[SubtitleCue]?, Never> {
        if let running = scanTasks[option.id] { return running }
        let source = option.source
        let video = videoURL
        // userInitiated：低優先權的磁碟讀取會被 iOS 排在影片播放之後，邊播 4K 邊讀會慢到像卡住
        let task = Task.detached(priority: .userInitiated) { () -> [SubtitleCue]? in
            switch source {
            case .file(let url):
                return try? SubtitleFileParser.parse(url)
            case .embedded(let track):
                guard let video else { return nil }
                return try? MatroskaSubtitles.cues(in: video, track: track)
            }
        }
        scanTasks[option.id] = task
        return task
    }

    private func currentID(_ slot: Slot) -> Int? {
        slot == .main ? mainID : secondID
    }

    private func setLoading(_ loading: Bool, slot: Slot) {
        if slot == .main { mainLoading = loading } else { secondLoading = loading }
    }

    private func setCues(_ cues: SubtitleCues, slot: Slot) {
        if slot == .main { mainCues = cues } else { secondCues = cues }
    }

    // MARK: - 名稱與語言

    private static func title(for track: EmbeddedSubtitleTrack, number: Int) -> String {
        let language = track.language == "und" ? nil : VLCTrackLabel.localizedLanguage(track.language)
        switch (track.name, language) {
        case let (name?, lang?):
            return String(format: String(localized: "TrackLanguage"), name, lang)
        case let (name?, nil):
            return name
        case let (nil, lang?):
            return lang
        case (nil, nil):
            return String(format: String(localized: "SubtitleTrack"), number)
        }
    }

    /// "chi" / "zho" / "zh-TW" / "zh-Hant" / "en-US" / "eng" → "zh-hant" / "en" …（只用來比對同語言）
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

    /// 外掛字幕的語言：取檔名去掉影片檔名後剩下的語言標記（"Show.E01.zh-TW.srt" → "zh-hant"）
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

private extension SubtitleModel.Source {
    var isEmbedded: Bool {
        if case .embedded = self { return true }
        return false
    }
}
