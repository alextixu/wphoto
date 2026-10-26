import SwiftUI

/// 單張檢視：左右滑動換張、捏合縮放、底部工具列顯示拍攝資訊
struct PhotoDetailView: View {
    let files: [MediaFile]
    @State private var index: Int
    @State private var showInfo = false
    @State private var chromeHidden = false
    @Environment(\.dismiss) private var dismiss

    init(files: [MediaFile], current: MediaFile) {
        self.files = files
        _index = State(initialValue: files.firstIndex(of: current) ?? 0)
    }

    private var file: MediaFile { files[index] }

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.ignoresSafeArea()
            TabView(selection: $index) {
                ForEach(Array(files.enumerated()), id: \.element.id) { i, f in
                    PhotoPage(file: f)
                        .tag(i)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .ignoresSafeArea()
            .onTapGesture { withAnimation(.easeInOut(duration: 0.2)) { chromeHidden.toggle() } }

            // 鍵盤快捷鍵（Mac、iPad 外接鍵盤）：左右方向鍵換張、Esc 關閉
            ZStack {
                Button("Back") { withAnimation { index = max(0, index - 1) } }
                    .keyboardShortcut(.leftArrow, modifiers: [])
                Button("Next") { withAnimation { index = min(files.count - 1, index + 1) } }
                    .keyboardShortcut(.rightArrow, modifiers: [])
                Button("Close") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .frame(width: 0, height: 0)
            .opacity(0)
            .allowsHitTesting(false)
            .accessibilityHidden(true)

            if !chromeHidden {
                HStack {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark").font(.headline)
                    }
                    Spacer()
                    VStack(spacing: 2) {
                        Text(file.url.lastPathComponent)
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                        Text("\(index + 1) / \(files.count)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button { showInfo = true } label: {
                        Image(systemName: "info.circle").font(.headline)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(.ultraThinMaterial)
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .statusBarHidden(chromeHidden)
        .sheet(isPresented: $showInfo) {
            InfoSheet(file: file)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
    }
}

struct PhotoPage: View {
    let file: MediaFile
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
                    ZoomableImageView(image: image, url: file.url)
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

/// 拍攝資訊（與 Windows 版右側面板相同欄位）
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
            .navigationTitle("ShootingInfo")
            .navigationBarTitleDisplayMode(.inline)
        }
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
