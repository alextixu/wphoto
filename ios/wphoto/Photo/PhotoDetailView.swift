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
    @State private var failed = false

    var body: some View {
        ZStack {
            if let image {
                ZoomableImageView(image: image)
                    .ignoresSafeArea()
            } else if failed {
                VStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle").font(.largeTitle)
                    Text("CantReadPhoto")
                }
                .foregroundStyle(.secondary)
            } else {
                // 先顯示縮圖當佔位，避免黑一片
                if let thumb = ThumbnailCache.shared.cached(file.url) {
                    Image(uiImage: thumb).resizable().scaledToFit().ignoresSafeArea()
                }
                ProgressView().tint(.white)
            }
        }
        .task(id: file.url) {
            let url = file.url
            let loaded = await Task.detached(priority: .userInitiated) {
                ImageLoading.fullImage(url: url)
            }.value
            if let loaded { image = loaded } else { failed = true }
        }
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
