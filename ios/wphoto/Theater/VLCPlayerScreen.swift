import SwiftUI
import UIKit

/// VLC 全螢幕播放畫面：點一下顯示／隱藏控制列，播放中 3 秒後自動隱藏
/// （選單開著或拖曳進度條時不隱藏）。雙擊兩側 ±10 秒、中央播放／暫停；
/// 捏合切換填滿／完整；下滑關閉。
struct VLCPlayerScreen: View {
    let title: String
    let url: URL
    let subtitles: [URL]
    /// 續播位置（毫秒）；nil = 從頭播
    var resumeMs: Int? = nil
    var onProgress: ProgressReporter = { _, _ in }

    @StateObject private var controller = VLCPlayerController()
    @StateObject private var subtitleModel = SubtitleModel()
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var controlsVisible = true
    @State private var menuOpen = false
    @State private var isScrubbing = false
    /// 拖曳中的位置（0…1）；放開才真正跳轉，拖曳時不被播放進度蓋掉
    @State private var scrubFraction: Double?
    /// 每次操作 +1，重新起算自動隱藏
    @State private var interaction = 0
    /// 游標停在上下控制列上（Mac、iPad 滑鼠）：不自動隱藏
    @State private var barHovered = false
    /// 每次 ±10 秒跳轉 +1，觸發觸覺回饋
    @State private var jumpCount = 0
    @State private var showResume = false
    /// 雙擊兩側跳轉的回饋圓；nil = 不顯示
    @State private var seekFlash: SeekFlash?
    /// 最近一次捏合的時間：兩指縮放時其中一指的位移也會被下滑手勢收到，放開時用它排除誤判關閉
    @State private var lastPinch: Date = .distantPast

    /// iPad／Mac 用大一點的按鈕與間距
    private var regular: Bool { sizeClass == .regular }

    private struct AutoHideKey: Equatable {
        var interaction: Int
        var visible: Bool
        var playing: Bool
        var menuOpen: Bool
        var scrubbing: Bool
        var hovered: Bool
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            // 文字字幕由 App 顯示；VLC 只拿到它自己才讀得了的外掛字幕（.sub）
            VLCVideoSurface(controller: controller, url: url,
                            subtitles: subtitles.filter { !SubtitleFileParser.canParse($0) },
                            startMs: resumeMs)
                .ignoresSafeArea()

            // 主字幕與第二字幕（App 用系統字型畫，中文不會變方格；不攔截點擊）
            SubtitleOverlay(model: subtitleModel, controller: controller, controlsVisible: controlsVisible)

            // 點畫面空白處：單擊顯示／隱藏控制列，雙擊兩側 ±10 秒、中央播放／暫停，
            // 捏合切換填滿／完整，下滑關閉。單擊要等雙擊判定失敗（約 0.3 秒）才生效是預期的；
            // 按鈕、滑鼠移動等其他叫出控制列的路徑不受影響。
            // 進度條的拖曳掛在 bottomBar 自己身上、層級在這層之上，不會互搶
            GeometryReader { geo in
                Color.clear
                    .contentShape(Rectangle())
                    .gesture(
                        SpatialTapGesture(count: 2)
                            .onEnded { value in handleDoubleTap(at: value.location, width: geo.size.width) }
                            .exclusively(before: TapGesture().onEnded {
                                guard !controller.hasError else { return }
                                toggleControls()
                            })
                    )
                    .simultaneousGesture(pinchGesture)
                    .simultaneousGesture(swipeDownGesture)
            }
            .ignoresSafeArea()

            if controller.isOpening && !controller.hasError {
                ProgressView()
                    .controlSize(.large)
                    .tint(.white)
            }

            // 控制列拆成四層各自進出場：漸層淡入、上下列分別從畫面邊緣滑入、中央播放群淡入
            if controlsVisible {
                controlsBackdrop
                    .transition(.opacity)
                topBar
                    .frame(maxHeight: .infinity, alignment: .top)
                    .transition(.move(edge: .top).combined(with: .opacity))
                if !controller.isOpening {
                    centerCluster
                        .transition(.opacity)
                }
                bottomBar
                    .frame(maxHeight: .infinity, alignment: .bottom)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            // 雙擊跳轉的回饋：三等分的隱形列一直掛著，圓形只在該側那一格進出場，
            // 縮放動畫才會以圓心為準（整列一起進出場的話會往畫面中央縮）。不攔截點擊
            HStack(spacing: 0) {
                seekFlashSlot(.leading)
                Color.clear
                seekFlashSlot(.trailing)
            }
            .ignoresSafeArea()
            .allowsHitTesting(false)
            .accessibilityHidden(true)

            if controller.hasError {
                errorOverlay
            }

            if showResume, let resumeMs {
                VStack {
                    ResumeBanner(positionMs: resumeMs) {
                        controller.seek(toMs: 0)
                        withAnimation { showResume = false }
                        showControls()
                    }
                    // 控制列顯示時讓開標題列；隱藏後貼近上緣
                    .padding(.top, controlsVisible ? 72 : 16)
                    .animation(WPTheme.chrome, value: controlsVisible)
                    Spacer()
                }
                .transition(.asymmetric(insertion: .move(edge: .top).combined(with: .opacity), removal: .opacity))
            }

            keyboardShortcuts
        }
        .statusBarHidden(!controlsVisible)
        .persistentSystemOverlays(controlsVisible ? .automatic : .hidden)
        // 滑鼠（Mac、iPad 觸控板）：游標一動就叫出控制列；觸控裝置不會觸發
        .onContinuousHover { phase in
            if case .active = phase, !controlsVisible { showControls() }
        }
        // 觸覺：播放／暫停切換、±10 秒跳轉、開始拖曳進度條（Mac 與沒有觸覺引擎的裝置會自動略過）
        .sensoryFeedback(.impact(flexibility: .soft, intensity: 0.7), trigger: controller.isPlaying)
        .sensoryFeedback(.impact(weight: .light), trigger: jumpCount)
        .sensoryFeedback(.selection, trigger: isScrubbing)
        .task(id: AutoHideKey(interaction: interaction, visible: controlsVisible, playing: controller.isPlaying,
                              menuOpen: menuOpen, scrubbing: isScrubbing, hovered: barHovered)) {
            await autoHide()
        }
        // 控制列已隱藏時 onHover 不一定會送出「離開」，保險起見一併重設，之後才會再自動隱藏
        .onChange(of: controlsVisible) { _, visible in
            if !visible { barHovered = false }
        }
        // 任何操作（按鈕、拖曳進度條、鍵盤）都收掉續播提示
        .onChange(of: interaction) { _, _ in
            if showResume { withAnimation { showResume = false } }
        }
        .onChange(of: controller.hasEnded) { _, ended in
            if ended {
                showControls()
                reportProgress()
            }
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
            let controller = self.controller
            subtitleModel.currentTimeMs = { [weak controller] in controller?.liveTimeMs ?? 0 }
            await subtitleModel.configure(videoURL: url, subtitleFiles: subtitles)
        }
        // 看到哪裡：每 5 秒記一次，關閉時再記一次
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                if Task.isCancelled { break }
                reportProgress()
            }
        }
        // 續播提示：等畫面出現後再從上方彈入，5 秒後自己收掉（有操作時提早收，見 onChange(of: interaction)）
        .task {
            guard resumeMs != nil else { return }
            try? await Task.sleep(for: .milliseconds(400))
            withAnimation(.spring(duration: 0.45, bounce: 0.25)) { showResume = true }
            try? await Task.sleep(for: .seconds(5))
            withAnimation { showResume = false }
        }
        .onDisappear {
            reportProgress()
            subtitleModel.stop()
            controller.teardown()
            UIApplication.shared.isIdleTimerDisabled = false
        }
    }

    // MARK: - 手勢（雙擊、捏合、下滑）

    /// 雙擊：左三分之一後退 10 秒、右三分之一前進 10 秒、中間播放／暫停。
    /// 中間沒有「側」可以顯示回饋圓，播放／暫停的觸覺由 isPlaying 的變化觸發，不再加一次 jumpCount
    private func handleDoubleTap(at location: CGPoint, width: CGFloat) {
        guard !controller.hasError else { return }
        interaction += 1
        let side: HorizontalEdge
        if location.x < width / 3 {
            side = .leading
        } else if location.x > width * 2 / 3 {
            side = .trailing
        } else {
            controller.togglePlay()
            return
        }
        let seconds = side == .leading ? -10 : 10
        controller.jump(seconds: seconds)
        jumpCount += 1
        let flash = SeekFlash(side: side, seconds: seconds)
        withAnimation(.spring(duration: 0.3, bounce: 0.3)) { seekFlash = flash }
        // 650 毫秒後淡出；期間又雙擊的話 token 已換新，這一次的收掉就作廢
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(650))
            if seekFlash?.token == flash.token {
                withAnimation(.easeOut(duration: 0.2)) { seekFlash = nil }
            }
        }
    }

    /// 捏合放大 → 填滿；縮小 → 完整顯示。放開時才判定，門檻 1.2 / 0.8 避免手指稍動就切換
    private var pinchGesture: some Gesture {
        MagnifyGesture()
            // 每 0.1 秒記一次就夠（每一格都寫 @State 會一直重繪整個畫面），
            // 下滑手勢只看「最近 0.3 秒內有沒有捏合」
            .onChanged { _ in
                if Date.now.timeIntervalSince(lastPinch) > 0.1 { lastPinch = .now }
            }
            .onEnded { value in
                lastPinch = .now
                guard !controller.hasError else { return }
                if value.magnification > 1.2, !controller.isFill {
                    controller.setFill(true)
                    interaction += 1
                } else if value.magnification < 0.8, controller.isFill {
                    controller.setFill(false)
                    interaction += 1
                }
            }
    }

    /// 下滑關閉：放開時往下超過 120pt、而且明顯是垂直（不是斜向滑）才關閉；拖曳中不做視覺回饋
    private var swipeDownGesture: some Gesture {
        DragGesture(minimumDistance: 30)
            .onEnded { value in
                guard !controller.hasError, !isScrubbing,
                      Date.now.timeIntervalSince(lastPinch) > 0.3 else { return }
                let dy = value.translation.height, dx = abs(value.translation.width)
                if dy > 120, dy > dx * 1.5 { dismiss() }
            }
    }

    /// 回饋圓所在的那一格（畫面三分之一寬）：只在該側有跳轉時出現
    @ViewBuilder
    private func seekFlashSlot(_ side: HorizontalEdge) -> some View {
        ZStack {
            if let flash = seekFlash, flash.side == side {
                SeekFlashView(flash: flash)
                    .transition(.scale(scale: 0.6).combined(with: .opacity))
            }
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - 鍵盤快捷鍵（Mac、iPad 外接鍵盤）

    /// 放在一直存在的隱形按鈕上：控制列自動隱藏後快捷鍵仍然有效
    private var keyboardShortcuts: some View {
        ZStack {
            Button("Play") { controller.togglePlay(); showControls() }
                .keyboardShortcut(.space, modifiers: [])
            Button("Back10") { controller.jump(seconds: -10); jumpCount += 1; showControls() }
                .keyboardShortcut(.leftArrow, modifiers: [])
            Button("Forward10") { controller.jump(seconds: 10); jumpCount += 1; showControls() }
                .keyboardShortcut(.rightArrow, modifiers: [])
            Button("Close") { dismiss() }
                .keyboardShortcut(.cancelAction)
        }
        .frame(width: 0, height: 0)
        .opacity(0)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    // MARK: - 控制列

    /// 上下兩道漸層：讓白色文字與按鈕在亮的畫面上也看得清楚（不攔截點擊）
    private var controlsBackdrop: some View {
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

    // 上下列本身不掛點擊手勢：按鈕以外的空白處會穿透到下層，由下層的點擊切換顯示／隱藏

    private var topBar: some View {
        HStack(spacing: 12) {
            // iPhone 是由下往上蓋出來的全螢幕，用 chevron.down；iPad／Mac 用 xmark
            ChromeButton(systemImage: regular ? "xmark" : "chevron.down", label: "Close") { dismiss() }

            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .onHover { barHovered = $0 }
    }

    /// 畫面正中央的播放群：±10 秒、播放／暫停（開檔中不顯示，避免和轉圈重疊）
    private var centerCluster: some View {
        HStack(spacing: regular ? 48 : 36) {
            circleButton("gobackward.10", label: "Back10",
                         diameter: regular ? 52 : 44, icon: regular ? 24 : 20) {
                controller.jump(seconds: -10)
                jumpCount += 1
            }
            circleButton(controller.isPlaying ? "pause.fill" : "play.fill",
                         label: controller.isPlaying ? "Pause" : "Play",
                         diameter: regular ? 72 : 60, icon: regular ? 34 : 28) {
                controller.togglePlay()
            }
            circleButton("goforward.10", label: "Forward10",
                         diameter: regular ? 52 : 44, icon: regular ? 24 : 20) {
                controller.jump(seconds: 10)
                jumpCount += 1
            }
        }
    }

    /// 底部霧面面板：時間列（進度條）＋ 選單列；最寬 760pt 置中，iPad 不會整排拉開
    private var bottomBar: some View {
        VStack(spacing: 8) {
            // 播放中每秒更新 30 次，進度條才會平順；暫停或拖曳時停下來，由狀態變化觸發重繪
            TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !controller.isPlaying || isScrubbing)) { _ in
                HStack(spacing: 10) {
                    Text(PlaybackTime.string(ms: shownMs))
                        .frame(minWidth: 44, alignment: .leading)
                    ScrubberBar(fraction: scrubFraction ?? progress,
                                durationMs: controller.durationMs,
                                isScrubbing: $isScrubbing,
                                scrubFraction: $scrubFraction) { fraction in
                        controller.seek(toMs: Int(fraction * Double(controller.durationMs)))
                        interaction += 1
                    }
                    .disabled(controller.durationMs <= 0)
                    .accessibilityElement()
                    .accessibilityLabel(Text("PlaybackPosition"))
                    .accessibilityValue(Text(PlaybackTime.string(ms: shownMs) + " / "
                                             + PlaybackTime.string(ms: controller.durationMs)))
                    .accessibilityAdjustableAction { direction in
                        controller.jump(seconds: direction == .increment ? 10 : -10)
                    }
                    // 右側顯示剩餘時間（-0:36），比總長更有用
                    Text(controller.durationMs > 0
                         ? "-" + PlaybackTime.string(ms: max(0, controller.durationMs - shownMs))
                         : "--:--")
                        .frame(minWidth: 52, alignment: .trailing)
                }
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.white)
            }

            // 寬度以 iPhone SE（375pt）直式放得下為準
            HStack(spacing: 4) {
                Spacer(minLength: 0)

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
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: WPTheme.Radius.hero, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: WPTheme.Radius.hero, style: .continuous)
            .strokeBorder(Color.wpStroke, lineWidth: 1))
        .frame(maxWidth: 760)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, regular ? 24 : 12)
        .padding(.bottom, 12)
        .onHover { barHovered = $0 }
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
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .hoverEffect(.highlight)
        .accessibilityLabel(Text(label))
    }

    /// 中央播放群的材質圓形按鈕
    private func circleButton(_ systemImage: String, label: LocalizedStringKey, diameter: CGFloat, icon: CGFloat,
                              action: @escaping () -> Void) -> some View {
        Button {
            action()
            interaction += 1
        } label: {
            Image(systemName: systemImage)
                .font(.system(size: icon, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: diameter, height: diameter)
                .background(.ultraThinMaterial, in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .hoverEffect(.highlight)
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
        .wpCard(radius: WPTheme.Radius.hero, elevated: true)
    }

    // MARK: - 進度條

    /// 進度條用的時間：直接向 libvlc 讀（不經過 @Published，TimelineView 每次更新都拿得到新值）。
    /// 開檔中 libvlc 還沒跳到續播位置，改用控制器記的 currentMs，提示的位置才不會先顯示 0:00
    private var liveMs: Int {
        controller.isOpening ? controller.currentMs : controller.liveTimeMs
    }

    private var progress: Double {
        guard controller.durationMs > 0 else { return 0 }
        return min(1, max(0, Double(liveMs) / Double(controller.durationMs)))
    }

    private var shownMs: Int {
        if let fraction = scrubFraction { return Int(fraction * Double(controller.durationMs)) }
        return liveMs
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

    /// 字幕選單的項目 id：VLC 字幕軌用 libvlc 的軌道 id（0 到數十），其他功能用不會重疊的大數字
    private enum MenuID {
        static let mainOff = 1_000_000
        static let mainBase = 1_100_000           // + 字幕選項 id
        static let secondOff = 2_000_000
        static let secondBase = 2_100_000         // + 字幕選項 id
        static let positionTop = 3_000_000
        static let positionBottom = 3_000_001
        static let nothing = 4_000_000            // 停用的說明項目
    }

    private enum MenuSection: Int {
        case main, vlc, second, position
    }

    private var subtitleSectionTitles: [String] {
        [String(localized: "PrimarySubtitles"), String(localized: "VLCSubtitleTracks"),
         String(localized: "SecondarySubtitles"), String(localized: "SubtitlePosition")]
    }

    private var subtitleItems: [PlayerMenuItem] {
        let model = subtitleModel
        var items: [PlayerMenuItem] = []

        // 主字幕（App 顯示）
        let vlcShowing = controller.currentSubtitle != -1
        items.append(PlayerMenuItem(id: MenuID.mainOff, title: String(localized: "SubtitlesOff"),
                                    isSelected: model.mainID == nil && !vlcShowing,
                                    section: MenuSection.main.rawValue))
        items += model.options.map { option in
            PlayerMenuItem(id: MenuID.mainBase + option.id, title: option.title,
                           isSelected: model.mainID == option.id, section: MenuSection.main.rawValue)
        }

        // VLC 自己的字幕軌（圖片字幕、MP4 / TS 內嵌字幕等 App 讀不了的）
        if model.needsVLCTracks {
            let vlcTracks = controller.subtitleTracks.filter { $0.id != -1 }
            items += vlcTracks.enumerated().map { index, track in
                PlayerMenuItem(id: Int(track.id),
                               title: trackTitle(track, index: index, format: "SubtitleTrack"),
                               isSelected: model.mainID == nil && track.id == controller.currentSubtitle,
                               section: MenuSection.vlc.rawValue)
            }
        }

        // 第二字幕（App 顯示）
        items.append(PlayerMenuItem(id: MenuID.secondOff, title: String(localized: "SubtitlesOff"),
                                    isSelected: model.secondID == nil, section: MenuSection.second.rawValue))
        if model.options.isEmpty {
            items.append(PlayerMenuItem(id: MenuID.nothing, title: String(localized: "NoTextSubtitles"),
                                        isSelected: false, section: MenuSection.second.rawValue, isEnabled: false))
        } else {
            items += model.options.map { option in
                PlayerMenuItem(id: MenuID.secondBase + option.id, title: option.title,
                               isSelected: model.secondID == option.id, section: MenuSection.second.rawValue)
            }
        }

        // 第二字幕位置（開啟第二字幕時才顯示）
        if model.secondID != nil {
            items.append(PlayerMenuItem(id: MenuID.positionBottom, title: String(localized: "PositionBottom"),
                                        isSelected: model.position == .bottom, section: MenuSection.position.rawValue))
            items.append(PlayerMenuItem(id: MenuID.positionTop, title: String(localized: "PositionTop"),
                                        isSelected: model.position == .top, section: MenuSection.position.rawValue))
        }
        return items
    }

    private func handleSubtitleMenu(_ id: Int) {
        switch id {
        case MenuID.mainOff:
            subtitleModel.selectMain(nil)
            controller.disableVLCSubtitles()
        case MenuID.mainBase..<MenuID.secondOff:
            subtitleModel.selectMain(id - MenuID.mainBase)
            controller.disableVLCSubtitles()
        case MenuID.secondOff:
            subtitleModel.selectSecond(nil)
        case MenuID.secondBase..<MenuID.positionTop:
            subtitleModel.selectSecond(id - MenuID.secondBase)
        case MenuID.positionTop:
            subtitleModel.position = .top
        case MenuID.positionBottom:
            subtitleModel.position = .bottom
        case MenuID.nothing:
            break
        default:
            // VLC 的字幕軌：主字幕改由 VLC 顯示
            subtitleModel.handMainToVLC()
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

    // MARK: - 續看進度

    private func reportProgress() {
        if controller.hasEnded, controller.durationMs > 0 {
            onProgress(controller.durationMs, controller.durationMs)
        } else if !controller.isOpening, !controller.hasError {
            onProgress(controller.currentMs, controller.durationMs)
        }
    }

    // MARK: - 自動隱藏

    private func toggleControls() {
        withAnimation(WPTheme.chrome) { controlsVisible.toggle() }
        interaction += 1
    }

    private func showControls() {
        withAnimation(WPTheme.chrome) { controlsVisible = true }
        interaction += 1
    }

    private func autoHide() async {
        guard controlsVisible, controller.isPlaying, !menuOpen, !isScrubbing, !barHovered else { return }
        try? await Task.sleep(for: .seconds(3))
        guard !Task.isCancelled else { return }
        withAnimation(WPTheme.chrome) { controlsVisible = false }
    }
}

/// 雙擊兩側跳轉的回饋狀態。token 每次換新：同側連點時圖示再彈一次，延遲收掉也只認最新那一次
private struct SeekFlash {
    let token = UUID()
    let side: HorizontalEdge
    let seconds: Int
}

/// 雙擊跳轉的回饋圓：材質圓形＋ ±10 秒圖示＋秒數，和中央播放群的圓形按鈕同一家族。
/// 第一次出現靠 scale 轉場彈入；同側連點時靠 symbolEffect 讓圖示再彈一次
private struct SeekFlashView: View {
    let flash: SeekFlash

    var body: some View {
        VStack(spacing: 2) {
            Image(systemName: flash.side == .leading ? "gobackward.10" : "goforward.10")
                .font(.system(size: 34, weight: .semibold))
                .symbolEffect(.bounce, value: flash.token)
            Text(verbatim: "\(flash.seconds > 0 ? "+" : "")\(flash.seconds)s")
                .font(.caption.weight(.semibold).monospacedDigit())
        }
        .foregroundStyle(.white)
        .frame(width: 110, height: 110)
        .background(.ultraThinMaterial, in: Circle())
        .overlay(Circle().strokeBorder(Color.wpStroke, lineWidth: 1))
    }
}

/// 自製進度條：細膠囊 + 圓形拇指；按住拖曳時變粗、拇指放大、上方浮出時間氣泡。
/// 拖曳中只更新 scrubFraction（畫面跟著動），放開才透過 onCommit 真正跳轉。
/// 點一下（不拖）也會跳到該位置。無障礙屬性由呼叫端加（需要播放器的時間）。
private struct ScrubberBar: View {
    /// 目前顯示的位置（0…1）：拖曳中是拖曳位置，否則是播放進度
    let fraction: Double
    let durationMs: Int
    @Binding var isScrubbing: Bool
    @Binding var scrubFraction: Double?
    let onCommit: (Double) -> Void

    var body: some View {
        GeometryReader { geo in
            // 寬度還沒量到時避免除以 0
            let width = max(geo.size.width, 1)
            let thumb: CGFloat = isScrubbing ? 20 : 14
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.3))
                Capsule().fill(Color.wpAccent)
                    .frame(width: width * fraction)
                Circle().fill(.white)
                    .frame(width: thumb, height: thumb)
                    .offset(x: width * fraction - thumb / 2)
            }
            .frame(height: isScrubbing ? 8 : 4)
            // 整個 44pt 高度都能按到，不用準確按在細線上
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        isScrubbing = true
                        scrubFraction = min(1, max(0, value.location.x / width))
                    }
                    .onEnded { _ in
                        if let fraction = scrubFraction { onCommit(fraction) }
                        scrubFraction = nil
                        isScrubbing = false
                    }
            )
            .overlay(alignment: .topLeading) {
                if isScrubbing {
                    Text(PlaybackTime.string(ms: Int(fraction * Double(durationMs))))
                        .font(.caption.bold().monospacedDigit())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(.black.opacity(0.8), in: RoundedRectangle(cornerRadius: WPTheme.Radius.badge))
                        // 氣泡跟著拇指走，但不超出進度條兩端
                        .offset(x: min(max(width * fraction - 24, 0), width - 48), y: -36)
                        .transition(.scale(scale: 0.8).combined(with: .opacity))
                }
            }
        }
        .frame(height: 44)
        .animation(.spring(duration: 0.25, bounce: 0.2), value: isScrubbing)
    }
}

/// App 顯示的字幕：依播放時間（每 0.1 秒讀一次 libvlc 的時間）畫在影片上，不攔截點擊。
/// 用系統字型畫，中文不會變方格。主字幕在影片底部；第二字幕疊在主字幕上面，或放在影片上方。
/// 位置以影片實際顯示範圍計算（完整顯示時扣掉上下黑邊）。
struct SubtitleOverlay: View {
    @ObservedObject var model: SubtitleModel
    /// 不觀察：時間與畫面尺寸在 TimelineView 每次更新時直接讀取
    let controller: VLCPlayerController
    let controlsVisible: Bool

    var body: some View {
        GeometryReader { geo in
            if model.mainCues != nil || model.secondCues != nil {
                TimelineView(.periodic(from: .now, by: 0.1)) { _ in
                    layout(geo: geo, timeMs: controller.liveTimeMs)
                }
            } else {
                layout(geo: geo, timeMs: nil)
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }

    @ViewBuilder
    private func layout(geo: GeometryProxy, timeMs: Int?) -> some View {
        let rect = videoRect(in: geo.size)
        let main = timeMs.flatMap { model.mainCues?.text(at: $0) } ?? ""
        let second = timeMs.flatMap { model.secondCues?.text(at: $0) } ?? ""
        let secondOnTop = model.position == .top
        let busy = model.mainLoading || model.secondLoading || model.showsFailure
        ZStack {
            // 上方：第二字幕（位置選「上方」時）
            VStack(spacing: 0) {
                if secondOnTop && !second.isEmpty {
                    subtitleText(second, rect: rect)
                }
                Spacer(minLength: 0)
            }
            .padding(.top, max(rect.minY + rect.height * 0.04,
                               max(geo.safeAreaInsets.top, 20) + (controlsVisible ? 60 : 8)))

            // 下方：（第二字幕）＋ 主字幕
            VStack(spacing: 6) {
                Spacer(minLength: 0)
                if busy { statusBadge }
                if !secondOnTop && !second.isEmpty {
                    subtitleText(second, rect: rect)
                }
                if !main.isEmpty {
                    subtitleText(main, rect: rect)
                }
            }
            .padding(.bottom, max(geo.size.height - rect.maxY + rect.height * 0.05, controlsVisible ? 130 : 16))
        }
        .padding(.horizontal, 24)
        .frame(width: geo.size.width, height: geo.size.height)
    }

    private var statusBadge: some View {
        let loading = model.mainLoading || model.secondLoading
        return HStack(spacing: 8) {
            if loading {
                ProgressView().tint(.white).controlSize(.small)
            }
            Text(loading ? "LoadingSubtitles" : "SubtitleFailed")
        }
        .font(.footnote)
        .foregroundStyle(.white)
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(.black.opacity(0.6), in: Capsule())
    }

    private func subtitleText(_ text: String, rect: CGRect) -> some View {
        Text(text)
            // 影片高度的 6.5%：iPhone 橫向約 26pt，13 吋 iPad 約 50pt
            .font(.system(size: max(18, min(56, rect.height * 0.065)), weight: .semibold))
            .foregroundStyle(.white)
            .multilineTextAlignment(.center)
            // 四個方向的黑色描邊加一點陰影，亮的畫面上也看得清楚
            .shadow(color: .black, radius: 0, x: 1, y: 1)
            .shadow(color: .black, radius: 0, x: -1, y: -1)
            .shadow(color: .black, radius: 0, x: 1, y: -1)
            .shadow(color: .black, radius: 0, x: -1, y: 1)
            .shadow(color: .black.opacity(0.7), radius: 3)
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
    var startMs: Int? = nil

    func makeUIView(context: Context) -> VLCVideoContainerView {
        let container = VLCVideoContainerView()
        let controller = self.controller
        container.onSizeChange = { [weak controller] size in
            controller?.updateViewSize(size)
        }
        controller.start(url: url, subtitles: subtitles, drawable: container.drawable, startMs: startMs)
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
        // 跟著動態字體縮放（等寬數字，速度 1.0x → 1.25x 時寬度不跳）
        button.titleLabel?.font = UIFontMetrics(forTextStyle: .subheadline)
            .scaledFont(for: .monospacedDigitSystemFont(ofSize: 15, weight: .semibold))
        button.titleLabel?.adjustsFontForContentSizeCategory = true
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
        // VoiceOver 唸「速度，1.0x」而不是只有「速度」
        button.accessibilityValue = text
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
