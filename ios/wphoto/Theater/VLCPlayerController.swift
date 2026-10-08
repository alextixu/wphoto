import Foundation
import UIKit
import MobileVLCKit

/// 包住 VLCMediaPlayer 的播放控制（MKV / AVI / TS…，或需要外掛字幕的 MP4）。
/// VLCKit 3 預設把所有事件派送到主執行緒；這個類別只在主執行緒使用（由 SwiftUI 畫面呼叫）。
final class VLCPlayerController: NSObject, ObservableObject, VLCMediaPlayerDelegate {
    struct Track: Identifiable, Equatable {
        /// libvlc 的軌道 id（-1 = 關閉）
        let id: Int32
        /// libvlc 給的名稱（英文，例如 "Track 2 - [Chinese]"）；畫面上會改成介面語言
        let name: String
        /// 外掛字幕的檔名（能確定是哪個檔案時才有）
        let fileName: String?
    }

    /// 使用者手動選的字幕
    private struct SubtitleChoice {
        /// -1 = 關閉
        let id: Int32
        /// 外掛字幕的檔案：重播時依檔案找回（軌道 id 由 libvlc 依建立順序編號，重播時可能不同）
        let file: URL?
    }

    static let rates: [Float] = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0]

    @Published private(set) var isPlaying = false
    @Published private(set) var isOpening = true
    @Published private(set) var hasEnded = false
    @Published private(set) var hasError = false
    @Published private(set) var currentMs = 0
    @Published private(set) var durationMs = 0
    @Published private(set) var rate: Float = 1
    @Published private(set) var isFill = false
    @Published private(set) var subtitleTracks: [Track] = []
    @Published private(set) var currentSubtitle: Int32 = -1
    @Published private(set) var audioTracks: [Track] = []
    @Published private(set) var currentAudio: Int32 = -1
    /// App 在背景（鎖定畫面、切到其他 App）
    private(set) var isInBackground = false

    /// 指定中文字型，否則中文字幕會顯示成方格（原因見 SubtitleFont）。
    /// 帶選項建立時 VLCKit 會為這個播放器另開一個 libvlc（選項接在 VLCKit 預設選項之後）。
    private let player: VLCMediaPlayer = {
        if let family = SubtitleFont.vlcFamily {
            return VLCMediaPlayer(options: ["--freetype-font=\(family)"])
        }
        return VLCMediaPlayer()
    }()
    private var started = false
    private var tornDown = false
    /// 播完後重新開始時要跳到的位置（輸入串流建立後才能設定時間）
    private var pendingSeekMs: Int?
    private var viewSize: CGSize = .zero

    private var videoURL: URL?
    /// 外掛字幕（SubtitleFinder 的順序：與影片同名的在前）
    private var subtitleFiles: [URL] = []
    /// 預設開啟的外掛字幕：檔名以影片檔名開頭的第一個；沒有就不自動開啟任何外掛字幕（不會打開別集的字幕）
    private var defaultSubtitle: URL?
    /// 這次開播是否已送出外掛字幕
    private var subtitlesAdded = false
    /// 送出外掛字幕前就有的字幕軌 id（內嵌字幕）
    private var subtitleIDsBeforeAdding: Set<Int32> = []
    /// 實際送出的外掛字幕（依送出順序）
    private var addedSubtitles: [URL] = []
    /// 字幕軌 id → 外掛字幕檔
    private var subtitleFileByID: [Int32: URL] = [:]
    /// 使用者手動選的字幕；播完重播時要還原
    private var userSubtitle: SubtitleChoice?
    private var pendingSubtitleRestore: SubtitleChoice?

    override init() {
        super.init()
        player.delegate = self
    }

    deinit {
        if !tornDown {
            player.delegate = nil
            player.stop()
        }
    }

    // MARK: - 開始 / 結束

    /// drawable 必須是 UIView，而且要在 play() 之前設定
    func start(url: URL, subtitles: [URL], drawable: UIView) {
        guard !started, !tornDown else { return }
        started = true
        videoURL = url
        subtitleFiles = subtitles
        defaultSubtitle = subtitles.first { SubtitleFinder.matches($0, video: url) }
        player.drawable = drawable
        player.media = makeMedia(url: url)
        // 外掛字幕等開始播放後才加（見 addSubtitlesIfNeeded）
        player.play()
    }

    /// 關閉畫面時呼叫：先拿掉 delegate，再停止（非同步、不阻塞），最後放掉 drawable
    func teardown() {
        guard !tornDown else { return }
        tornDown = true
        player.delegate = nil
        player.stop()
        player.drawable = nil
        isPlaying = false
    }

    /// App 進入／離開背景。VLC 沒有子母畫面，也沒有鎖定畫面的播放控制，
    /// 進背景就暫停，避免聲音在背景一直播、只能回到 App 才停得掉。
    func setInBackground(_ background: Bool) {
        isInBackground = background
        if background, !tornDown, player.isPlaying {
            player.pause()
        }
    }

    // MARK: - 第二字幕用（由畫面直接讀取，不經過 @Published，避免每 0.1 秒重繪整個畫面）

    /// 目前播放位置（毫秒），直接向 libvlc 讀取
    var liveTimeMs: Int {
        guard !tornDown else { return currentMs }
        return Int(player.time.intValue)
    }

    /// 影片原始尺寸（還不知道時是 .zero）
    var videoSize: CGSize {
        tornDown ? .zero : player.videoSize
    }

    // MARK: - 播放控制

    func togglePlay() {
        if hasEnded {
            restart(fromMs: 0)
        } else if player.isPlaying {
            player.pause()
        } else {
            player.play()
        }
    }

    func jump(seconds: Int) {
        seek(toMs: currentMs + seconds * 1000)
    }

    func seek(toMs ms: Int) {
        var target = max(0, ms)
        if durationMs > 0 { target = min(target, max(0, durationMs - 500)) }
        currentMs = target   // 先更新畫面，避免進度條跳回舊位置
        if hasEnded {
            restart(fromMs: target)
        } else {
            player.time = VLCTime(int: Int32(clamping: target))
        }
    }

    func setRate(_ newRate: Float) {
        player.rate = newRate
        rate = newRate
    }

    func selectSubtitle(_ id: Int32) {
        player.currentVideoSubTitleIndex = id
        currentSubtitle = id
        userSubtitle = SubtitleChoice(id: id, file: subtitleFileByID[id])
        pendingSubtitleRestore = nil
    }

    func selectAudio(_ id: Int32) {
        player.currentAudioTrackIndex = id
        currentAudio = id
    }

    // MARK: - 畫面比例（完整顯示 / 填滿）

    func setFill(_ fill: Bool) {
        isFill = fill
        applyAspect()
    }

    /// 旋轉或版面改變時由影片 view 呼叫
    func updateViewSize(_ size: CGSize) {
        guard size != viewSize else { return }
        viewSize = size
        if isFill { applyAspect() }
    }

    /// 填滿 = 把影片裁成畫面的長寬比，再自動縮放；完整顯示 = 不裁切
    private func applyAspect() {
        player.scaleFactor = 0
        let w = Int(viewSize.width.rounded()), h = Int(viewSize.height.rounded())
        if isFill, w > 0, h > 0 {
            "\(w):\(h)".withCString { player.videoCropGeometry = UnsafeMutablePointer(mutating: $0) }
        } else {
            player.videoCropGeometry = nil
        }
    }

    // MARK: - VLCMediaPlayerDelegate（主執行緒）

    func mediaPlayerStateChanged(_ aNotification: Notification) {
        switch player.state {
        case .error:
            hasError = true
            isOpening = false
        case .ended:
            hasEnded = true
            isOpening = false
        case .playing, .paused, .esAdded:
            isOpening = false
            addSubtitlesIfNeeded()
            refreshTracks()
        case .opening, .buffering, .stopped:
            break
        @unknown default:
            break
        }
        // 切到背景時還在開檔、之後才開始播放：一樣停下來
        if isInBackground, player.isPlaying {
            player.pause()
        }
        isPlaying = player.isPlaying
    }

    func mediaPlayerTimeChanged(_ aNotification: Notification) {
        if let pending = pendingSeekMs {
            pendingSeekMs = nil
            player.time = VLCTime(int: Int32(clamping: pending))
            currentMs = pending
        } else {
            currentMs = Int(player.time.intValue)
        }
        let length = Int(player.media?.length.intValue ?? 0)
        if length > 0, length != durationMs { durationMs = length }
        if isOpening { isOpening = false }
        addSubtitlesIfNeeded()
        if subtitleTracks.isEmpty && audioTracks.isEmpty { refreshTracks() }
    }

    // MARK: - 內部

    /// 每次（重新）開播都用新的 VLCMedia：播放中加入的外掛字幕會被 libvlc 記在 media 上，
    /// 沿用舊的 media 重播時會全部以「使用者指定」的最高優先權載入，隨便選一個當預設。
    private func makeMedia(url: URL) -> VLCMedia {
        let media = VLCMedia(url: url)
        if let encoding = Self.subtitleEncoding {
            // 非 UTF-8 的中文字幕（台灣常見 Big5、中國常見 GBK）；UTF-8 字幕仍會自動辨識
            media.addOption(":subsdec-encoding=\(encoding)")
        }
        // 外掛字幕全部由 app 自己加（SubtitleFinder 已找過同資料夾與 Subs / Subtitles），
        // 關掉 VLC 自己的偵測：否則同一個檔案可能列兩次（網址編碼不同），也無法確定哪一軌是哪個檔案
        media.addOption(":no-sub-autodetect-file")
        return media
    }

    private func restart(fromMs ms: Int) {
        guard let url = videoURL else { return }
        hasEnded = false
        pendingSeekMs = ms > 0 ? ms : nil
        // 使用者選過字幕（含「關閉」）就不再自動選預設字幕，等軌道出現後還原
        pendingSubtitleRestore = userSubtitle
        subtitlesAdded = false
        subtitleIDsBeforeAdding = []
        addedSubtitles = []
        subtitleFileByID = [:]
        // 播完後輸入串流已結束，要先 stop 再 play 才會重新開啟；換新的 media（見 makeMedia）
        player.stop()
        player.media = makeMedia(url: url)
        player.play()
    }

    /// 開始播放（已有輸入串流）後才加入外掛字幕：
    /// - 開播前加入的字幕在 libvlc 一律是最高優先權，會強制選取排序後的第一個；
    ///   排序只比優先權而且不穩定，常常選到別集的字幕。
    /// - 播放中加入時 enforce 才有作用：只選取 defaultSubtitle，其他只列在選單裡。
    private func addSubtitlesIfNeeded() {
        guard !subtitlesAdded, !tornDown, player.isPlaying else { return }
        subtitlesAdded = true
        guard !subtitleFiles.isEmpty else { return }
        subtitleIDsBeforeAdding = Set(Self.trackIDs(player.videoSubTitlesIndexes))
        // 重播時要還原使用者的選擇，不自動選取
        let selected = pendingSubtitleRestore == nil ? defaultSubtitle : nil
        for sub in subtitleFiles {
            if player.addPlaybackSlave(sub, type: .subtitle, enforce: sub == selected) == 0 {
                addedSubtitles.append(sub)
            }
        }
    }

    private func refreshTracks() {
        let subIDs = Self.trackIDs(player.videoSubTitlesIndexes)
        mapAddedSubtitles(ids: subIDs)
        let subs = Self.tracks(ids: subIDs, names: player.videoSubTitlesNames, files: subtitleFileByID)
        if subs != subtitleTracks { subtitleTracks = subs }
        let sub = player.currentVideoSubTitleIndex
        if sub != currentSubtitle { currentSubtitle = sub }
        restoreSubtitleIfNeeded(ids: subIDs)

        let audioIDs = Self.trackIDs(player.audioTrackIndexes)
        let audio = Self.tracks(ids: audioIDs, names: player.audioTrackNames, files: [:])
        if audio != audioTracks { audioTracks = audio }
        let aud = player.currentAudioTrackIndex
        if aud != currentAudio { currentAudio = aud }
    }

    /// 把外掛字幕軌對應回檔案：libvlc 依建立順序列出字幕軌，送出後才出現的新軌道就是外掛字幕（依送出順序）。
    /// 數量剛好對上才標檔名；還沒載入完、有檔案開不了、或同時多出其他軌道時不標，避免標錯。
    private func mapAddedSubtitles(ids: [Int32]) {
        guard !addedSubtitles.isEmpty else { return }
        let newIDs = ids.filter { $0 != -1 && !subtitleIDsBeforeAdding.contains($0) }
        guard newIDs.count == addedSubtitles.count else {
            subtitleFileByID = [:]
            return
        }
        subtitleFileByID = Dictionary(zip(newIDs, addedSubtitles), uniquingKeysWith: { first, _ in first })
    }

    /// 重播後把使用者先前選的字幕套回去（軌道出現、外掛字幕對應到檔案後才設定得了）
    private func restoreSubtitleIfNeeded(ids: [Int32]) {
        guard subtitlesAdded, let choice = pendingSubtitleRestore else { return }
        let target: Int32?
        if let file = choice.file {
            target = subtitleFileByID.first(where: { $0.value == file })?.key
        } else {
            target = (choice.id == -1 || ids.contains(choice.id)) ? choice.id : nil
        }
        guard let target else { return }
        pendingSubtitleRestore = nil
        player.currentVideoSubTitleIndex = target
        currentSubtitle = target
    }

    /// VLCKit 回傳未標型別的 NSArray：id 是 NSNumber
    private static func trackIDs(_ ids: [Any]) -> [Int32] {
        ids.compactMap { ($0 as? NSNumber)?.int32Value }
    }

    /// 名稱陣列與 id 陣列位置一一對應
    private static func tracks(ids: [Int32], names: [Any], files: [Int32: URL]) -> [Track] {
        ids.enumerated().map { index, id in
            let name = index < names.count ? (names[index] as? String ?? "") : ""
            return Track(id: id, name: name, fileName: files[id]?.lastPathComponent)
        }
    }

    /// 依系統語言猜測非 UTF-8 中文字幕的編碼；其他語言維持 VLC 預設
    private static var subtitleEncoding: String? {
        for language in Locale.preferredLanguages {
            let l = language.lowercased()
            if l.hasPrefix("zh-hant") || l.hasPrefix("zh-tw") || l.hasPrefix("zh-hk") || l.hasPrefix("zh-mo") {
                return "CP950"     // Big5（Windows 繁中）
            }
            if l.hasPrefix("zh") {
                return "GB18030"   // 涵蓋 GBK / GB2312
            }
        }
        return nil
    }
}
