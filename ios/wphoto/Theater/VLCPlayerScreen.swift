import SwiftUI
import UIKit

/// VLC 全螢幕播放畫面：點一下顯示／隱藏控制列，播放中 3 秒後自動隱藏
/// （選單開著或拖曳進度條時不隱藏）。
struct VLCPlayerScreen: View {
    let title: String
    let url: URL
    let subtitles: [URL]

    @StateObject private var controller = VLCPlayerController()
    @StateObject private var secondary = SecondarySubtitleModel()
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var controlsVisible = true
    @State private var menuOpen = false
    @State private var isScrubbing = false
    /// 拖曳中的位置（0…1）；放開才真正跳轉，拖曳時不被播放進度蓋掉
    @State private var scrubFraction: Double?
    /// 每次操作 +1，重新起算自動隱藏
    @State private var interaction = 0

    private struct AutoHideKey: Equatable {
        var interaction: Int
        var visible: Bool
        var playing: Bool
        var menuOpen: Bool
        var scrubbing: Bool
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VLCVideoSurface(controller: controller, url: url, subtitles: subtitles)
                .ignoresSafeArea()

            // 第二字幕（App 自己畫；不攔截點擊）
            SecondarySubtitleOverlay(model: secondary, controller: controller, controlsVisible: controlsVisible)

            // 點畫面空白處：顯示／隱藏控制列
            Color.clear
                .contentShape(Rectangle())
                .ignoresSafeArea()
                .onTapGesture { toggleControls() }

            if controller.isOpening && !controller.hasError {
                ProgressView()
                    .controlSize(.large)
                    .tint(.white)
            }

            if controlsVisible {
                controls
                    .transition(.opacity)
            }

            if controller.hasError {
                errorOverlay
            }
        }
        .statusBarHidden(!controlsVisible)
        .persistentSystemOverlays(controlsVisible ? .automatic : .hidden)
        .task(id: AutoHideKey(interaction: interaction, visible: controlsVisible, playing: controller.isPlaying,
                              menuOpen: menuOpen, scrubbing: isScrubbing)) {
            await autoHide()
        }
        .onChange(of: controller.hasEnded) { _, ended in
            if ended { showControls() }
        }
        // 播放中不讓螢幕自動變暗、鎖定（AVPlayer 會自己處理，VLC 不會）；暫停或關閉時還原
        .onChange(of: controller.isPlaying) { _, playing in
            UIApplication.shared.isIdleTimerDisabled = playing
        }
        // 鎖定畫面或切到其他 App：暫停（VLC 沒有子母畫面與鎖定畫面控制）；
        // .inactive（控制中心、來電橫幅）不暫停
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .background:
                controller.setInBackground(true)
            case .active:
                if controller.isInBackground {
                    controller.setInBackground(false)
                    showControls()   // 回來時影片是暫停的，把控制列叫出來方便按播放
                }
            default:
                break
            }
        }
        .task {
            await secondary.configure(videoURL: url, subtitleFiles: subtitles)
        }
        .onDisappear {
            secondary.stop()
            controller.teardown()
            UIApplication.shared.isIdleTimerDisabled = false
        }
    }

    // MARK: - 控制列

    private var controls: some View {
        VStack(spacing: 0) {
            topBar
            Spacer(minLength: 0)
            bottomBar
        }
        .background {
            VStack(spacing: 0) {
                LinearGradient(colors: [.black.opacity(0.7), .clear], startPoint: .top, endPoint: .bottom)
                    .frame(height: 140)
                Spacer(minLength: 0)
                LinearGradient(colors: [.clear, .black.opacity(0.75)], startPoint: .top, endPoint: .bottom)
                    .frame(height: 200)
            }
            .ignoresSafeArea()
            .allowsHitTesting(false)
        }
        // 控制列本身不掛點擊手勢：按鈕以外的空白處會穿透到下層，由下層的點擊切換顯示／隱藏
    }

    private var topBar: some View {
        HStack(spacing: 12) {
            Button { dismiss() } label: {
                Image(systemName: "chevron.down")
                    .font(.headline)
                    .foregroundStyle(.white)
                    .frame(width: 40, height: 40)
                    .background(.ultraThinMaterial, in: Circle())
            }
            .accessibilityLabel(Text("Close"))

            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }

    private var bottomBar: some View {
        VStack(spacing: 6) {
            HStack(spacing: 10) {
                Text(PlaybackTime.string(ms: shownMs))
                    .frame(minWidth: 44, alignment: .leading)
                Slider(value: sliderValue, in: 0...1, onEditingChanged: { editing in
                    if editing {
                        isScrubbing = true
                    } else {
                        if let fraction = scrubFraction {
                            controller.seek(toMs: Int(fraction * Double(controller.durationMs)))
                        }
                        scrubFraction = nil
                        isScrubbing = false
                        interaction += 1
                    }
                })
                .tint(Color.wpAccent)
                .disabled(controller.durationMs <= 0)
                Text(controller.durationMs > 0 ? PlaybackTime.string(ms: controller.durationMs) : "--:--")
                    .frame(minWidth: 44, alignment: .trailing)
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.white)

            // 寬度以 iPhone SE（375pt）直式放得下為準
            HStack(spacing: 4) {
                iconButton("gobackward.10", label: "Back10") { controller.jump(seconds: -10) }
                iconButton(controller.isPlaying ? "pause.fill" : "play.fill",
                           label: controller.isPlaying ? "Pause" : "Play", size: 26) { controller.togglePlay() }
                iconButton("goforward.10", label: "Forward10") { controller.jump(seconds: 10) }

                Spacer(minLength: 8)

                PlayerMenuButton(text: rateLabel(controller.rate),
                                 menuTitle: String(localized: "Speed"),
                                 items: speedItems,
                                 onSelect: { index in
                                     controller.setRate(VLCPlayerController.rates[index])
                                     interaction += 1
                                 },
                                 onMenuVisibilityChange: { menuOpen = $0 })
                    .frame(width: 48, height: 44)

                PlayerMenuButton(systemImage: "captions.bubble",
                                 menuTitle: String(localized: "Subtitles"),
                                 items: subtitleItems,
                                 sectionTitles: subtitleSectionTitles,
                                 onSelect: { id in
                                     handleSubtitleMenu(id)
                                     interaction += 1
                                 },
                                 onMenuVisibilityChange: { menuOpen = $0 })
                    .frame(width: 40, height: 44)

                if realAudioTracks.count > 1 {
                    PlayerMenuButton(systemImage: "waveform",
                                     menuTitle: String(localized: "Audio"),
                                     items: audioItems,
                                     onSelect: { id in
                                         controller.selectAudio(Int32(id))
                                         interaction += 1
                                     },
                                     onMenuVisibilityChange: { menuOpen = $0 })
                        .frame(width: 40, height: 44)
                }

                iconButton(controller.isFill ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
                           label: controller.isFill ? "FitScreen" : "FillScreen") {
                    controller.setFill(!controller.isFill)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
    }

    private func iconButton(_ systemImage: String, label: LocalizedStringKey, size: CGFloat = 20,
                            action: @escaping () -> Void) -> some View {
        Button {
            action()
            interaction += 1
        } label: {
            Image(systemName: systemImage)
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 40, height: 44)
                .contentShape(Rectangle())
        }
        .accessibilityLabel(Text(label))
    }

    private var errorOverlay: some View {
        VStack(spacing: 14) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 40))
                .foregroundStyle(.yellow)
            Text("CantPlayVideo")
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
            Button("Close") { dismiss() }
                .buttonStyle(.borderedProminent)
        }
        .padding(24)
        .background(Color.wpCard, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    // MARK: - 進度條

    private var progress: Double {
        guard controller.durationMs > 0 else { return 0 }
        return min(1, max(0, Double(controller.currentMs) / Double(controller.durationMs)))
    }

    private var sliderValue: Binding<Double> {
        Binding(
            get: { scrubFraction ?? progress },
            set: { newValue in
                if isScrubbing {
                    scrubFraction = newValue
                } else {
                    // 非拖曳的調整（例如 VoiceOver）直接跳轉
                    controller.seek(toMs: Int(newValue * Double(controller.durationMs)))
                }
            }
        )
    }

    private var shownMs: Int {
        if let fraction = scrubFraction { return Int(fraction * Double(controller.durationMs)) }
        return controller.currentMs
    }

    // MARK: - 選單內容

    private var speedItems: [PlayerMenuItem] {
        VLCPlayerController.rates.enumerated().map { index, rate in
            PlayerMenuItem(id: index, title: rateLabel(rate), isSelected: abs(rate - controller.rate) < 0.01)
        }
    }

    /// 0.5x、0.75x、1.0x、1.25x、1.5x、2.0x
    private func rateLabel(_ rate: Float) -> String {
        rate == rate.rounded() ? String(format: "%.1fx", rate) : String(format: "%gx", rate)
    }

    /// 字幕選單的項目 id：主字幕用 libvlc 的軌道 id（-1 到數十），其他功能用不會重疊的大數字
    private enum MenuID {
        static let secondaryOff = 1_000_000
        static let secondaryBase = 1_000_001      // + 第二字幕選項 id
        static let positionTop = 2_000_000
        static let positionBottom = 2_000_001
        static let nothing = 3_000_000            // 停用的說明項目
    }

    private var subtitleSectionTitles: [String] {
        [String(localized: "PrimarySubtitles"), String(localized: "SecondarySubtitles"), String(localized: "SubtitlePosition")]
    }

    private var subtitleItems: [PlayerMenuItem] {
        // 第 0 區：主字幕（VLC 顯示）
        let off = PlayerMenuItem(id: -1, title: String(localized: "SubtitlesOff"),
                                 isSelected: controller.currentSubtitle == -1)
        let tracks = controller.subtitleTracks.filter { $0.id != -1 }.enumerated().map { index, track in
            PlayerMenuItem(id: Int(track.id),
                           title: trackTitle(track, index: index, format: "SubtitleTrack"),
                           isSelected: track.id == controller.currentSubtitle)
        }

        // 第 1 區：第二字幕（App 顯示）
        var second: [PlayerMenuItem] = [
            PlayerMenuItem(id: MenuID.secondaryOff, title: String(localized: "SubtitlesOff"),
                           isSelected: secondary.selectedID == nil, section: 1)
        ]
        if secondary.options.isEmpty {
            second.append(PlayerMenuItem(id: MenuID.nothing, title: String(localized: "NoTextSubtitles"),
                                         isSelected: false, section: 1, isEnabled: false))
        } else {
            second += secondary.options.map { option in
                PlayerMenuItem(id: MenuID.secondaryBase + option.id, title: option.title,
                               isSelected: secondary.selectedID == option.id, section: 1)
            }
        }

        // 第 2 區：第二字幕位置（開啟第二字幕時才顯示）
        var position: [PlayerMenuItem] = []
        if secondary.selectedID != nil {
            position = [
                PlayerMenuItem(id: MenuID.positionBottom, title: String(localized: "PositionBottom"),
                               isSelected: secondary.position == .bottom, section: 2),
                PlayerMenuItem(id: MenuID.positionTop, title: String(localized: "PositionTop"),
                               isSelected: secondary.position == .top, section: 2),
            ]
        }
        return [off] + tracks + second + position
    }

    private func handleSubtitleMenu(_ id: Int) {
        switch id {
        case MenuID.secondaryOff:
            secondary.select(nil)
        case MenuID.positionTop:
            secondary.position = .top
        case MenuID.positionBottom:
            secondary.position = .bottom
        case MenuID.nothing:
            break
        case MenuID.secondaryBase..<MenuID.positionTop:
            secondary.select(id - MenuID.secondaryBase)
        default:
            controller.selectSubtitle(Int32(id))
        }
    }

    /// 「關閉」軌 (-1) 會讓整部片靜音，不放進音軌選單
    private var realAudioTracks: [VLCPlayerController.Track] {
        controller.audioTracks.filter { $0.id != -1 }
    }

    private var audioItems: [PlayerMenuItem] {
        realAudioTracks.enumerated().map { index, track in
            PlayerMenuItem(id: Int(track.id),
                           title: trackTitle(track, index: index, format: "AudioTrack"),
                           isSelected: track.id == controller.currentAudio)
        }
    }

    /// 外掛字幕顯示檔名（才分得出是哪個檔案）；其他軌道把 libvlc 的英文名稱換成介面語言
    private func trackTitle(_ track: VLCPlayerController.Track, index: Int, format: String.LocalizationValue) -> String {
        if let fileName = track.fileName { return fileName }
        return VLCTrackLabel.title(libvlcName: track.name, number: index + 1, format: format)
    }

    // MARK: - 自動隱藏

    private func toggleControls() {
        withAnimation(.easeInOut(duration: 0.2)) { controlsVisible.toggle() }
        interaction += 1
    }

    private func showControls() {
        withAnimation(.easeInOut(duration: 0.2)) { controlsVisible = true }
        interaction += 1
    }

    private func autoHide() async {
        guard controlsVisible, controller.isPlaying, !menuOpen, !isScrubbing else { return }
        try? await Task.sleep(for: .seconds(3))
        guard !Task.isCancelled else { return }
        withAnimation(.easeInOut(duration: 0.3)) { controlsVisible = false }
    }
}

/// 第二字幕：依播放時間（每 0.1 秒讀一次 libvlc 的時間）畫在影片上，不攔截點擊。
/// 用系統字型畫，中文不會變方格。位置以影片實際顯示範圍計算（完整顯示時扣掉上下黑邊）。
struct SecondarySubtitleOverlay: View {
    @ObservedObject var model: SecondarySubtitleModel
    /// 不觀察：時間與畫面尺寸在 TimelineView 每次更新時直接讀取
    let controller: VLCPlayerController
    let controlsVisible: Bool

    var body: some View {
        GeometryReader { geo in
            if let cues = model.cues {
                TimelineView(.periodic(from: .now, by: 0.1)) { _ in
                    let text = cues.text(at: controller.liveTimeMs)
                    placed(geo: geo) {
                        if !text.isEmpty {
                            subtitleText(text, rect: videoRect(in: geo.size))
                        }
                    }
                }
            } else if model.isLoading || model.showsFailure {
                placed(geo: geo) {
                    HStack(spacing: 8) {
                        if model.isLoading {
                            ProgressView().tint(.white).controlSize(.small)
                        }
                        Text(model.isLoading ? "LoadingSecondary" : "SecondaryFailed")
                    }
                    .font(.footnote)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(.black.opacity(0.6), in: Capsule())
                }
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }

    private func subtitleText(_ text: String, rect: CGRect) -> some View {
        Text(text)
            .font(.system(size: max(15, min(30, rect.height * 0.05)), weight: .semibold))
            .foregroundStyle(.white)
            .multilineTextAlignment(.center)
            // 四個方向的黑色描邊加一點陰影，亮的畫面上也看得清楚
            .shadow(color: .black, radius: 0, x: 1, y: 1)
            .shadow(color: .black, radius: 0, x: -1, y: -1)
            .shadow(color: .black, radius: 0, x: 1, y: -1)
            .shadow(color: .black, radius: 0, x: -1, y: 1)
            .shadow(color: .black.opacity(0.7), radius: 3)
    }

    /// 放在影片範圍的上方或下方。下方位置預留主字幕（VLC 畫在影片底部）的高度，第二字幕疊在主字幕上面。
    private func placed<Content: View>(geo: GeometryProxy, @ViewBuilder content: () -> Content) -> some View {
        let rect = videoRect(in: geo.size)
        let top = model.position == .top
        let topPadding = max(rect.minY + rect.height * 0.04, max(geo.safeAreaInsets.top, 20) + (controlsVisible ? 60 : 8))
        let bottomPadding = max(geo.size.height - rect.maxY + rect.height * 0.17, controlsVisible ? 130 : 12)
        return VStack(spacing: 0) {
            if !top { Spacer(minLength: 0) }
            content()
            if top { Spacer(minLength: 0) }
        }
        .padding(.horizontal, 24)
        .padding(.top, top ? topPadding : 0)
        .padding(.bottom, top ? 0 : bottomPadding)
        .frame(width: geo.size.width, height: geo.size.height)
    }

    /// 影片實際顯示的範圍：填滿模式就是整個畫面；完整顯示時依影片比例置中
    private func videoRect(in size: CGSize) -> CGRect {
        let video = controller.videoSize
        guard !controller.isFill, video.width > 0, video.height > 0, size.width > 0, size.height > 0 else {
            return CGRect(origin: .zero, size: size)
        }
        let scale = min(size.width / video.width, size.height / video.height)
        let w = video.width * scale, h = video.height * scale
        return CGRect(x: (size.width - w) / 2, y: (size.height - h) / 2, width: w, height: h)
    }
}

/// 播放時間文字：m:ss 或 h:mm:ss
enum PlaybackTime {
    static func string(seconds: Double) -> String {
        guard seconds.isFinite else { return "--:--" }
        return string(totalSeconds: Int(seconds.rounded()))
    }

    static func string(ms: Int) -> String {
        string(totalSeconds: ms / 1000)
    }

    private static func string(totalSeconds: Int) -> String {
        let total = max(0, totalSeconds)
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}

/// 軌道名稱改成介面語言。libvlc 3 的名稱一律是英文（es_out.c）：
/// "Track 2"、"Track 2 - [Chinese]"，或容器裡的軌道標題（可能帶 " - [語言]"）。
/// 語言是 VLC 語言表的英文名稱；不認得的語言則是原始代碼（例如字幕檔名裡的 zh-TW）。
/// 例："Track 2 - [Chinese]" → 「字幕 2（中文）」
enum VLCTrackLabel {
    static func title(libvlcName: String, number: Int, format: String.LocalizationValue) -> String {
        var base = libvlcName.trimmingCharacters(in: .whitespaces)
        var language: String?
        if base.hasSuffix("]"), let open = base.range(of: " - [", options: .backwards) {
            language = String(base[open.upperBound..<base.index(before: base.endIndex)])
            base = String(base[..<open.lowerBound])
        }
        let title = (base.isEmpty || isGenericName(base)) ? String(format: String(localized: format), number) : base
        guard let language, !language.isEmpty else { return title }
        return String(format: String(localized: "TrackLanguage"), title, localizedLanguage(language))
    }

    static func localizedLanguage(_ language: String) -> String {
        let key = language.lowercased()
        // VLC 語言表有些名稱帶修飾，例如 "Greek, Modern"
        let shortKey = key.split(separator: ",").first.map { String($0) } ?? key
        if let code = codeByEnglishName[key] ?? codeByEnglishName[shortKey],
           let name = uiLocale.localizedString(forLanguageCode: code) {
            return name
        }
        if isLanguageTag(language), let name = uiLocale.localizedString(forIdentifier: language), !name.isEmpty {
            return name
        }
        return language
    }

    /// 介面實際採用的語系（en / zh-Hant / zh-Hans），語言名稱跟著介面走
    private static let uiLocale = Locale(identifier: Bundle.main.preferredLocalizations.first ?? "en")

    /// iOS 的英文語言名稱 → 語言代碼，用來反查 VLC 的英文名稱（"chinese" → "zh"）
    private static let codeByEnglishName: [String: String] = {
        let english = Locale(identifier: "en")
        var map: [String: String] = [:]
        for code in Locale.LanguageCode.isoLanguageCodes {
            let id = code.identifier
            guard let name = english.localizedString(forLanguageCode: id)?.lowercased() else { continue }
            // 同一個名稱有 2 碼與 3 碼代碼時用 2 碼
            if let existing = map[name], existing.count <= id.count { continue }
            map[name] = id
        }
        return map
    }()

    /// libvlc 沒有標題時的名稱："Track <數字>"（VLCKit 沒有翻譯）
    private static func isGenericName(_ name: String) -> Bool {
        guard name.hasPrefix("Track ") else { return false }
        return Int(name.dropFirst("Track ".count)) != nil
    }

    /// 看起來像語言代碼（zh、chi、zh-TW、pt_BR）才交給 Locale 翻譯
    private static func isLanguageTag(_ text: String) -> Bool {
        let parts = text.split(whereSeparator: { $0 == "-" || $0 == "_" })
        guard let first = parts.first, (2...3).contains(first.count),
              first.allSatisfy({ $0.isASCII && $0.isLetter }) else { return false }
        return parts.dropFirst().allSatisfy { part in
            (2...8).contains(part.count) && part.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) }
        }
    }
}

// MARK: - 影片 view（VLC 的 drawable）

/// 容器 view 裡放一個專用的 drawable：VLC 會在 drawable 裡加自己的 OpenGL 子 view，
/// 並在 drawable 的上層（這個容器）掛點擊手勢；容器關閉互動，點擊一律交給 SwiftUI。
struct VLCVideoSurface: UIViewRepresentable {
    let controller: VLCPlayerController
    let url: URL
    let subtitles: [URL]

    func makeUIView(context: Context) -> VLCVideoContainerView {
        let container = VLCVideoContainerView()
        let controller = self.controller
        container.onSizeChange = { [weak controller] size in
            controller?.updateViewSize(size)
        }
        controller.start(url: url, subtitles: subtitles, drawable: container.drawable)
        return container
    }

    func updateUIView(_ uiView: VLCVideoContainerView, context: Context) {}

    static func dismantleUIView(_ uiView: VLCVideoContainerView, coordinator: ()) {
        uiView.onSizeChange = nil
    }
}

final class VLCVideoContainerView: UIView {
    let drawable = UIView()
    var onSizeChange: ((CGSize) -> Void)?
    private var lastSize: CGSize = .zero

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        clipsToBounds = true
        isUserInteractionEnabled = false
        drawable.backgroundColor = .black
        drawable.frame = bounds
        drawable.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        addSubview(drawable)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if bounds.size != lastSize {
            lastSize = bounds.size
            onSizeChange?(bounds.size)
        }
    }
}

// MARK: - 選單按鈕（UIKit）

/// 選單的一個項目
struct PlayerMenuItem: Equatable {
    let id: Int
    let title: String
    let isSelected: Bool
    /// 屬於 sectionTitles 的第幾區（沒有分區時忽略）
    var section: Int = 0
    var isEnabled: Bool = true
}

/// 以 UIButton + UIMenu 做的選單按鈕：SwiftUI 的 Menu 無法得知選單是否開著，
/// 這裡用 UIControl 的選單回呼通知，讓控制列在選單開著時不自動隱藏。
struct PlayerMenuButton: UIViewRepresentable {
    var systemImage: String? = nil
    var text: String? = nil
    let menuTitle: String
    let items: [PlayerMenuItem]
    /// 有值時依 PlayerMenuItem.section 分區顯示（每區一個標題）
    var sectionTitles: [String] = []
    let onSelect: (Int) -> Void
    let onMenuVisibilityChange: (Bool) -> Void

    final class Coordinator {
        var onSelect: ((Int) -> Void)?
        var shownItems: [PlayerMenuItem]?
        var shownTitle: String?
        var shownSections: [String]?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> MenuTrackingButton {
        let button = MenuTrackingButton(frame: .zero)
        button.showsMenuAsPrimaryAction = true
        button.setTitleColor(.white, for: .normal)
        button.titleLabel?.font = .monospacedDigitSystemFont(ofSize: 15, weight: .semibold)
        if let systemImage {
            let config = UIImage.SymbolConfiguration(pointSize: 20, weight: .semibold)
            let image = UIImage(systemName: systemImage, withConfiguration: config)?
                .withTintColor(.white, renderingMode: .alwaysOriginal)
            button.setImage(image, for: .normal)
        }
        update(button, context: context)
        return button
    }

    func updateUIView(_ button: MenuTrackingButton, context: Context) {
        update(button, context: context)
    }

    private func update(_ button: MenuTrackingButton, context: Context) {
        let coordinator = context.coordinator
        coordinator.onSelect = onSelect
        button.onMenuVisibilityChange = onMenuVisibilityChange
        button.accessibilityLabel = menuTitle
        if let text, button.title(for: .normal) != text {
            button.setTitle(text, for: .normal)
        }
        // 內容沒變就不重建選單（播放進度每秒更新多次）
        guard items != coordinator.shownItems || menuTitle != coordinator.shownTitle
                || sectionTitles != coordinator.shownSections else { return }
        coordinator.shownItems = items
        coordinator.shownTitle = menuTitle
        coordinator.shownSections = sectionTitles
        let makeAction = { [weak coordinator] (item: PlayerMenuItem) -> UIAction in
            UIAction(title: item.title,
                     attributes: item.isEnabled ? [] : .disabled,
                     state: item.isSelected ? .on : .off) { _ in
                coordinator?.onSelect?(item.id)
            }
        }
        let children: [UIMenuElement]
        if sectionTitles.isEmpty {
            children = items.map(makeAction)
        } else {
            children = sectionTitles.indices.compactMap { section -> UIMenuElement? in
                let actions = items.filter { $0.section == section }.map(makeAction)
                guard !actions.isEmpty else { return nil }
                return UIMenu(title: sectionTitles[section], options: .displayInline, children: actions)
            }
        }
        button.menu = UIMenu(title: menuTitle, children: children)
    }
}

final class MenuTrackingButton: UIButton {
    var onMenuVisibilityChange: ((Bool) -> Void)?

    override func contextMenuInteraction(_ interaction: UIContextMenuInteraction,
                                         willDisplayMenuFor configuration: UIContextMenuConfiguration,
                                         animator: UIContextMenuInteractionAnimating?) {
        super.contextMenuInteraction(interaction, willDisplayMenuFor: configuration, animator: animator)
        onMenuVisibilityChange?(true)
    }

    override func contextMenuInteraction(_ interaction: UIContextMenuInteraction,
                                         willEndFor configuration: UIContextMenuConfiguration,
                                         animator: UIContextMenuInteractionAnimating?) {
        super.contextMenuInteraction(interaction, willEndFor: configuration, animator: animator)
        onMenuVisibilityChange?(false)
    }
}
