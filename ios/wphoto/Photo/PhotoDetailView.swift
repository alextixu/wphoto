import SwiftUI

/// 單張檢視：左右滑動換張、捏合縮放、未縮放時下拉關閉；
/// 拍攝資訊在 iPad 是右側欄（把照片擠到左邊）、iPhone 是底部 sheet
struct PhotoDetailView: View {
    let files: [MediaFile]
    @State private var index: Int
    @State private var showInfo = false
    @State private var chromeHidden = false
    /// 下拉關閉的進度（0…1）：由 ZoomScrollView 的 pan 手勢回報，黑底跟著變淡、頂列跟著收起
    @State private var dismissProgress: CGFloat = 0
    @Environment(\.dismiss) private var dismiss
    /// regular 寬度（iPad／Mac）時資訊面板是右側欄，圖示跟著換成 sidebar.trailing
    @Environment(\.horizontalSizeClass) private var sizeClass
    /// 使用者開了「減少動態效果」：換張、控制列顯示／隱藏、側欄滑入都不做位移動畫
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(files: [MediaFile], current: MediaFile) {
        self.files = files
        _index = State(initialValue: files.firstIndex(of: current) ?? 0)
    }

    private var file: MediaFile { files[index] }

    /// 側欄只在 regular 寬度出現；compact 寬度走 sheet（兩者不會同時成立）
    private var showSidebar: Bool { showInfo && sizeClass == .regular }

    /// 頂列收起的條件：使用者點一下藏起來，或正在下拉關閉（拖一點點就先收，手指放開彈回時再出現）
    private var topBarHidden: Bool { chromeHidden || dismissProgress > 0.05 }

    var body: some View {
        // 側欄用 HStack 真的把照片區擠到左邊（.inspector 在 fullScreenCover 裡會疊在照片上，而不是擠開）
        HStack(spacing: 0) {
            viewerStack
            if showSidebar {
                Divider().overlay(Color.wpSeparator)
                InfoSheet(file: file)
                    .frame(width: 320)
                    // 底色延伸到狀態列／Home 指示列，側欄才不會上下露出黑邊
                    .background(Color.wpCard.ignoresSafeArea())
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .animation(reduceMotion ? nil : .spring(duration: 0.35, bounce: 0.1), value: showInfo)
        .statusBarHidden(chromeHidden)
        // 換張時輕微觸覺回饋（滑動、方向鍵都會觸發）
        .sensoryFeedback(.selection, trigger: index)
        // compact 寬度：拍攝資訊是底部 sheet；轉成 regular 時 binding 變 false，sheet 自動收掉
        .sheet(isPresented: Binding(get: { showInfo && sizeClass != .regular }, set: { showInfo = $0 })) {
            InfoSheet(file: file)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
    }

    /// 照片區：黑底 + 分頁 + 鍵盤快捷鍵 + 頂列
    private var viewerStack: some View {
        ZStack(alignment: .top) {
            // 下拉關閉時黑底跟著變淡（ZoomScrollView 本身是透明的，底色只有這一層）
            Color.black.opacity(Double(1 - dismissProgress * 0.9)).ignoresSafeArea()
            TabView(selection: $index) {
                ForEach(Array(files.enumerated()), id: \.element.id) { i, f in
                    PhotoPage(file: f,
                              onDismissProgress: { dismissProgress = $0 },
                              onDismiss: { dismiss() })
                        .tag(i)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .ignoresSafeArea()
            .onTapGesture { withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) { chromeHidden.toggle() } }

            // 鍵盤快捷鍵（Mac、iPad 外接鍵盤）：左右方向鍵換張、⌘I 拍攝資訊、Esc 關閉
            ZStack {
                Button("Back") { withAnimation(reduceMotion ? nil : .default) { index = max(0, index - 1) } }
                    .keyboardShortcut(.leftArrow, modifiers: [])
                Button("Next") { withAnimation(reduceMotion ? nil : .default) { index = min(files.count - 1, index + 1) } }
                    .keyboardShortcut(.rightArrow, modifiers: [])
                Button("ShootingInfo") { showInfo.toggle() }
                    .keyboardShortcut("i")
                Button("Close") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .frame(width: 0, height: 0)
            .opacity(0)
            .allowsHitTesting(false)
            .accessibilityHidden(true)

            // 頂列另外包一層並綁 topBarHidden：下拉時收起／彈回時出現也走同一個動畫，不會硬切
            ZStack(alignment: .top) {
                if !topBarHidden {
                    HStack {
                        ChromeButton(systemImage: "xmark", label: "Close") { dismiss() }
                        Spacer()
                        VStack(spacing: 2) {
                            Text(file.url.lastPathComponent)
                                .font(.subheadline.weight(.semibold))
                                .lineLimit(1)
                            Text("\(index + 1) / \(files.count)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        ChromeButton(systemImage: sizeClass == .regular ? "sidebar.trailing" : "info.circle", label: "ShootingInfo") { showInfo.toggle() }
                    }
                    .padding(.horizontal, WPTheme.Spacing.l)
                    .padding(.vertical, 6)
                    .background(.ultraThinMaterial)
                    .transition(reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity))
                }
            }
            .animation(reduceMotion ? nil : WPTheme.chrome, value: topBarHidden)
        }
    }
}

struct PhotoPage: View {
    let file: MediaFile
    /// 下拉關閉的進度與完成：原樣轉給 ZoomableImageView（手勢在 UIKit 那層）
    var onDismissProgress: ((CGFloat) -> Void)? = nil
    var onDismiss: (() -> Void)? = nil
    @State private var image: UIImage?
    /// 原檔比畫面小、已經是原始解析度：畫面再變大也不用重讀
    @State private var isOriginalSize = false
    @State private var failed = false
    @Environment(\.displayScale) private var displayScale

    private struct LoadKey: Equatable {
        let url: URL
        let pixels: Int
    }

    var body: some View {
        GeometryReader { geo in
            let pixels = Self.screenPixels(geo.size, displayScale)
            ZStack {
                if let image {
                    ZoomableImageView(image: image, url: file.url,
                                      onDismissProgress: onDismissProgress,
                                      onDismiss: onDismiss)
                        .transition(.opacity)
                } else if failed {
                    VStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle").font(.largeTitle)
                        Text("CantReadPhoto")
                    }
                    .foregroundStyle(.secondary)
                } else {
                    // 先顯示縮圖當佔位，避免黑一片
                    if let thumb = ThumbnailCache.shared.cached(file.url) {
                        Image(uiImage: thumb).resizable().scaledToFit()
                    }
                    ProgressView().tint(.white)
                }
            }
            // 縮圖佔位換成大圖時 crossfade，而不是硬切
            .animation(WPTheme.imageFade, value: image)
            .frame(width: geo.size.width, height: geo.size.height)
            .task(id: LoadKey(url: file.url, pixels: pixels)) {
                await load(pixels: pixels)
            }
        }
        .ignoresSafeArea()
    }

    /// 依畫面實際像素解碼（4K 外接螢幕、全螢幕都清楚）；畫面變大時重讀，變小則沿用
    private func load(pixels: Int) async {
        guard pixels > 0 else { return }
        if let image {
            if isOriginalSize || Self.longEdge(image) >= pixels { return }
            // 拖曳調整視窗大小時會連續觸發，等停下來再讀
            try? await Task.sleep(for: .milliseconds(300))
            if Task.isCancelled { return }
        }
        let url = file.url
        let loaded = await Task.detached(priority: .userInitiated) {
            ImageLoading.fullImage(url: url, maxPixel: pixels)
        }.value
        if Task.isCancelled { return }
        if let loaded {
            image = loaded
            isOriginalSize = Self.longEdge(loaded) < pixels
        } else if image == nil {
            failed = true
        }
    }

    /// 畫面長邊的實際像素，進位到 512 的倍數，視窗稍微調整大小時不會一直重讀
    private static func screenPixels(_ size: CGSize, _ scale: CGFloat) -> Int {
        let px = Int((max(size.width, size.height) * scale).rounded(.up))
        return (px + 511) / 512 * 512
    }

    private static func longEdge(_ image: UIImage) -> Int {
        Int(max(image.size.width, image.size.height) * image.scale)
    }
}

/// 拍攝資訊（與 Windows 版右側面板相同欄位）；當側欄時保留 NavigationStack 的標題列，看起來像 Finder 的檢閱器
struct InfoSheet: View {
    let file: MediaFile
    @State private var rows: [InfoRow] = []
    @State private var fileSize: String = ""

    var body: some View {
        NavigationStack {
            List {
                Section("ShootingInfo") {
                    LabeledContent(String(localized: "FileName"), value: file.url.lastPathComponent)
                    if !fileSize.isEmpty {
                        LabeledContent(String(localized: "FileSize"), value: fileSize)
                    }
                }
                if !rows.isEmpty {
                    Section("KeyParams") {
                        ForEach(rows) { row in
                            LabeledContent(NSLocalizedString(row.label, comment: ""), value: row.value)
                        }
                    }
                }
            }
            // 當右側欄時與黑底照片區要有分界，sheet 時也一致
            .scrollContentBackground(.hidden)
            .background(Color.wpCard)
            .navigationTitle("ShootingInfo")
            .navigationBarTitleDisplayMode(.inline)
        }
        // ←/→ 換張時 file.url 變了就重讀，側欄內容跟著換
        .task(id: file.url) {
            let url = file.url
            if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                fileSize = ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
            }
            rows = await Task.detached(priority: .userInitiated) {
                ImageLoading.metadata(url: url)
            }.value
        }
    }
}
