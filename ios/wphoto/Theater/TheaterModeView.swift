import SwiftUI
import UniformTypeIdentifiers

/// 從首頁點進看劇模式時要直接做的事
enum TheaterLaunch: Hashable {
    /// 「最近位置」：直接開這個常用位置
    case location(FolderSession.SavedFolder)
    /// 「繼續觀看」：開回影片所在的常用位置、進到那一層並開始播放
    case resume(WatchProgressStore.Entry)
}

/// 看劇模式：從「檔案」選資料夾（含 NAS）→ 封面選集 → 播放
struct TheaterModeView: View {
    var launch: TheaterLaunch? = nil

    @StateObject private var session = FolderSession(kind: .video)
    @State private var showPicker = false
    @State private var playing: MediaFile?
    @State private var didLaunch = false
    /// 「繼續觀看」：那一層讀好後要自動播放的檔名
    @State private var pendingPlayName: String?
    /// 播放畫面關閉後 +1：剛下載完的影片重新檢查、補上封面與時長
    @State private var refreshToken = 0

    /// iPad（.regular）卡片放大、間距加寬
    @Environment(\.horizontalSizeClass) private var sizeClass

    private var isLarge: Bool { sizeClass == .regular }

    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: isLarge ? 260 : 160), spacing: isLarge ? 20 : 12)]
    }

    var body: some View {
        ZStack {
            // 上淺下深的微漸層：材質卡片不會貼在死黑上
            CinemaBackdrop()
            if let name = session.openingName {
                FolderProgressView(title: String(format: String(localized: "OpeningLocation"), name)) {
                    session.closeFolder()
                }
            } else if session.folderURL == nil {
                LocationsView(session: session) { showPicker = true }
            } else if session.isScanning {
                FolderProgressView(title: String(localized: "Scanning")) { session.cancelScan() }
            } else if session.files.isEmpty && session.folders.isEmpty {
                // 空資料夾：說明支援的格式，並給「上一層／常用位置／選資料夾」三條路離開
                ContentUnavailableView {
                    Label { Text("NoVideos") } icon: { Image(systemName: "film.stack").foregroundStyle(Color.wpSecondaryLabel) }
                } description: {
                    Text("VideoFormatNote")
                } actions: {
                    if session.canGoUp { Button("UpOneLevel") { session.goUp() } }
                    Button("Locations") { session.closeFolder() }
                    Button("ChooseFolder") { showPicker = true }
                        .wpPrimaryButton()
                }
            } else {
                ScrollView {
                    VStack(spacing: isLarge ? 24 : 16) {
                        if !session.folders.isEmpty {
                            PosterGrid(folders: session.folders, session: session, large: isLarge) { session.enter($0) }
                        }
                        LazyVGrid(columns: columns, spacing: isLarge ? 24 : 16) {
                            ForEach(session.files) { file in
                                Button { playing = file } label: {
                                    EpisodeCard(file: file, refreshToken: refreshToken)
                                }
                                .buttonStyle(CardPressStyle())
                                .wpHoverLift()
                                .contentShape(.hoverEffect, RoundedRectangle(cornerRadius: WPTheme.Radius.poster, style: .continuous))
                            }
                        }
                        if !session.files.isEmpty {
                            // 影片數量放在卡片下方，不再佔一條底部工具列
                            Text(String(format: String(localized: "VideoCount"), session.files.count))
                                .font(.footnote)
                                .foregroundStyle(Color.wpSecondaryLabel)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 8)
                        }
                    }
                    .padding(isLarge ? 20 : 12)
                }
                .refreshable { await session.reload() }
            }
        }
        .navigationTitle(session.folderURL == nil ? String(localized: "VideoMode") : session.folderDisplayName)
        // 常用位置清單用大標題；開進資料夾後改小標題，把空間留給海報與卡片
        .navigationBarTitleDisplayMode(session.folderURL == nil ? .large : .inline)
        .modifier(FolderBackButton(session: session))
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                // 開著資料夾時：回到常用位置清單（可改開別的位置）
                if session.folderURL != nil {
                    Button { session.closeFolder() } label: {
                        Image(systemName: "folder")
                    }
                    .accessibilityLabel(Text("Locations"))
                }
            }
        }
        .fileImporter(isPresented: $showPicker, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result {
                session.open(url)
            }
        }
        .fullScreenCover(item: $playing, onDismiss: { refreshToken += 1 }) { file in
            PlaybackScreen(file: file, origin: session.playbackOrigin)
        }
        .task {
            // 只在第一次出現時執行（從播放畫面回來不會再跑一次）
            guard !didLaunch, let launch else { return }
            didLaunch = true
            start(launch)
        }
        .onChange(of: session.loadedURL) { _, _ in playPendingIfReady() }
        // 使用者取消或回到常用位置清單：不再自動播放
        .onChange(of: session.folderURL) { _, url in
            if url == nil { pendingPlayName = nil }
        }
        .alert("Error", isPresented: Binding(get: { session.errorMessage != nil },
                                             set: { if !$0 { session.errorMessage = nil } })) {
            Button("OK") {}
        } message: {
            Text(session.errorMessage ?? "")
        }
    }

    private func start(_ launch: TheaterLaunch) {
        switch launch {
        case .location(let item):
            session.openSaved(session.saved.first { $0.id == item.id } ?? item)
        case .resume(let entry):
            guard let origin = entry.origin,
                  let item = session.saved.first(where: { $0.path == origin.locationPath }) else {
                session.errorMessage = String(localized: "ContinueLocationMissing")
                return
            }
            pendingPlayName = entry.fileName
            session.openSaved(item, subfolders: origin.subfolders)
        }
    }

    /// 「繼續觀看」的那一層讀好了：找到影片就播（從上次的位置繼續）
    private func playPendingIfReady() {
        guard let name = pendingPlayName, let loaded = session.loadedURL, loaded == session.stack.last else { return }
        pendingPlayName = nil
        if let file = session.files.first(where: { $0.url.lastPathComponent == name }) {
            playing = file
        } else if session.errorMessage == nil {
            // 這一層讀好了，但影片已經不在（改名、搬走）
            session.errorMessage = String(localized: "ContinueVideoMissing")
        }
    }
}

/// 封面卡片：縮圖＋時長＋檔名。
/// 縮圖區尺寸只由 16:9 底色決定（寬 = 欄寬）；畫面放 overlay 裡 scaledToFill 再裁切，
/// 所以非 16:9 的畫面不會把卡片撐大、蓋到隔壁卡片。
struct EpisodeCard: View {
    let file: MediaFile
    var refreshToken = 0

    /// 看到哪裡：底部進度條、看完打勾
    @ObservedObject private var progress = WatchProgressStore.shared
    @State private var image: UIImage?
    @State private var duration = ""
    @State private var isRemote = false

    private struct LoadKey: Equatable {
        let url: URL
        let refreshToken: Int
    }

    private static let shape = RoundedRectangle(cornerRadius: WPTheme.Radius.poster, style: .continuous)

    /// 標題不帶副檔名；格式改放到第二行
    private var displayTitle: String { (file.relativeName as NSString).deletingPathExtension }

    /// 第二行「MP4 · 1:30」：時長還沒讀到（或未下載）就只剩格式
    private var subtitleLine: String {
        [file.url.pathExtension.uppercased(), duration].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    var body: some View {
        let watch = progress.entry(for: file.url)
        let resumable = watch?.isResumable == true
        VStack(alignment: .leading, spacing: 6) {
            Color.wpCard
                .aspectRatio(16 / 9, contentMode: .fit)
                .overlay {
                    if let image {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFill()
                            .transition(.opacity)
                    } else {
                        Image(systemName: "film")
                            .font(.title)
                            .foregroundStyle(.secondary)
                    }
                }
                .overlay {
                    // 底部壓暗：時長徽章與進度條疊在亮畫面上也看得清。
                    // 另開一層 overlay 而不是跟圖片放同一個 ZStack：scaledToFill 的圖片會比 16:9 框大，
                    // 同一個 ZStack 會跟著被撐大，漸層就對不準看得到的範圍
                    if image != nil {
                        LinearGradient(colors: [.clear, .black.opacity(0.6)], startPoint: .center, endPoint: .bottom)
                            .transition(.opacity)
                    }
                }
                .overlay(alignment: .topLeading) {
                    if watch?.watched == true {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.callout.weight(.semibold))
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(Color.wpBackground, Color.wpLabel)
                            .padding(4)
                            .background(.ultraThinMaterial, in: Circle())
                            .padding(8)
                            .accessibilityLabel(Text("Watched"))
                    }
                }
                .overlay(alignment: .bottom) {
                    if resumable, let watch {
                        // 看到一半：底部進度條（圓角、左右內縮，不貼邊）
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                Capsule().fill(.white.opacity(0.3))
                                Capsule().fill(Color.wpAccent)
                                    .frame(width: geo.size.width * watch.fraction)
                            }
                        }
                        .frame(height: 3)
                        .padding(.horizontal, 8)
                        .padding(.bottom, 8)
                    }
                }
                .overlay(alignment: .topTrailing) {
                    if isRemote {
                        // 還在 iCloud / NAS 上：播放前會先下載
                        Image(systemName: "icloud.and.arrow.down")
                            .font(.caption.weight(.semibold))
                            .padding(5)
                            .background(.ultraThinMaterial, in: Circle())
                            .padding(8)
                            .accessibilityLabel(Text("NotDownloaded"))
                    }
                }
                .overlay(alignment: .bottomTrailing) {
                    if !duration.isEmpty {
                        // 有進度條時再往上讓一點，不壓到進度條
                        Text(duration)
                            .wpBadge()
                            .padding(8)
                            .padding(.bottom, resumable ? 10 : 0)
                    }
                }
                .clipShape(Self.shape)
                .overlay(Self.shape.strokeBorder(Color.wpStroke, lineWidth: 1))

            Text(displayTitle)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(Color.wpLabel)
                .multilineTextAlignment(.leading)
                .lineLimit(2, reservesSpace: true)   // 標題區固定兩行高，整排卡片對齊
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(subtitleLine)
                .font(.caption2)
                .foregroundStyle(Color.wpSecondaryLabel)
                .lineLimit(1)
        }
        // 點擊範圍 = 整張卡片（被裁掉的畫面不會攔截隔壁卡片的點擊）
        .contentShape(Rectangle())
        // VoiceOver：整張卡片一個元素，唸集數名＋看到哪裡
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(displayTitle))
        .accessibilityValue(Text(watchValue(watch)))
        .animation(WPTheme.imageFade, value: image)
        .task(id: LoadKey(url: file.url, refreshToken: refreshToken)) {
            await load()
        }
    }

    /// VoiceOver 的值：看完唸「已看」、看到一半唸百分比；沒看過給空字串（不會唸出來）。
    /// 不用 if／else 切換 modifier：那會換掉 view 身分，縮圖與時長的 @State 會被清掉重讀
    private func watchValue(_ watch: WatchProgressStore.Entry?) -> String {
        guard let watch else { return "" }
        return watch.watched ? String(localized: "Watched") : "\(Int(watch.fraction * 100))%"
    }

    private func load() async {
        if image == nil { image = ThumbnailCache.shared.cached(file.url) }
        if duration.isEmpty, let seconds = ThumbnailCache.shared.cachedDuration(file.url) {
            duration = PlaybackTime.string(seconds: seconds)
        }
        if image != nil && !duration.isEmpty {
            isRemote = false
            return
        }
        // 未下載的影片不讀縮圖與時長，避免瀏覽 NAS / iCloud 資料夾時把整部影片下載下來
        guard await FileAvailability.isLikelyLocal(file.url) else {
            isRemote = true
            return
        }
        isRemote = false
        if image == nil {
            image = await ThumbnailCache.shared.thumbnail(for: file, maxPixel: 640)
        }
        if duration.isEmpty, let seconds = await ThumbnailCache.shared.duration(for: file) {
            duration = PlaybackTime.string(seconds: seconds)
        }
    }
}
