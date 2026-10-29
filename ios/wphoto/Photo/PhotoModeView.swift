import SwiftUI
import UniformTypeIdentifiers

/// 照片模式：從「檔案」選資料夾 → 縮圖牆 → 點開檢視
struct PhotoModeView: View {
    /// 從首頁「最近位置」點進來時，直接開這個常用位置
    var initialLocation: FolderSession.SavedFolder? = nil

    @StateObject private var session = FolderSession(kind: .photo)
    @State private var didOpenInitial = false
    @State private var showPicker = false
    @State private var typeFilter: String? = nil
    @State private var selected: MediaFile?
    /// iOS 18+ 的 zoom 轉場：點開照片時從那格縮圖放大進來、關閉時縮回去（縮圖是 source、檢視器是目的地）
    @Namespace private var zoomNS

    /// 格線間距：欄距、列距、外距都用同一個值，縮圖才會形成整齊的棋盤格
    private static let gridSpacing: CGFloat = 3
    /// iPad（.regular）每格放大，避免 13 吋橫向一排塞十幾格小縮圖
    @Environment(\.horizontalSizeClass) private var sizeClass

    /// 自動依寬度決定欄數：iPhone 每格至少 110pt（直向約 3 欄），iPad 至少 170pt
    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: sizeClass == .regular ? 170 : 110), spacing: Self.gridSpacing)]
    }

    private var availableTypes: [String] {
        Array(Set(session.files.map(\.typeLabel))).sorted()
    }

    private var visibleFiles: [MediaFile] {
        guard let t = typeFilter else { return session.files }
        return session.files.filter { $0.typeLabel == t }
    }

    var body: some View {
        ZStack {
            Rectangle().fill(WPTheme.backdrop).ignoresSafeArea()
            if let name = session.openingName {
                FolderProgressView(title: String(format: String(localized: "OpeningLocation"), name)) {
                    session.closeFolder()
                }
            } else if session.folderURL == nil {
                LocationsView(session: session) { showPicker = true }
            } else if session.isScanning {
                FolderProgressView(title: String(localized: "Scanning")) { session.cancelScan() }
            } else if visibleFiles.isEmpty && session.folders.isEmpty {
                // 空資料夾不只說「沒有照片」，順便給出路：上一層／回位置清單／另選資料夾
                ContentUnavailableView {
                    Label { Text("NoPhotos") } icon: { Image(systemName: "photo.on.rectangle").foregroundStyle(Color.wpAccent) }
                } actions: {
                    if session.canGoUp { Button("UpOneLevel") { session.goUp() } }
                    Button("Locations") { session.closeFolder() }
                    Button("ChooseFolder") { showPicker = true }.buttonStyle(.borderedProminent).buttonBorderShape(.capsule)
                }
            } else {
                ScrollView {
                    if !session.folders.isEmpty {
                        FolderGrid(folders: session.folders, large: sizeClass == .regular) { session.enter($0) }
                            .padding([.horizontal, .top], 12)
                            .padding(.bottom, 9)
                    }
                    LazyVGrid(columns: columns, spacing: Self.gridSpacing) {
                        ForEach(visibleFiles) { file in
                            thumbnailButton(file)
                        }
                    }
                    .padding(Self.gridSpacing)
                    if !session.files.isEmpty {
                        Text(String(format: String(localized: "PhotoCount"), visibleFiles.count, visibleFiles.filter(\.isRaw).count))
                            .font(.footnote)
                            .foregroundStyle(Color.wpSecondaryLabel)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, WPTheme.Spacing.l)
                    }
                }
                .refreshable { await session.reload() }
            }
        }
        .navigationTitle(session.folderURL == nil ? String(localized: "PhotoMode") : session.folderDisplayName)
        .navigationBarTitleDisplayMode(session.folderURL == nil ? .large : .inline)
        .modifier(FolderBackButton(session: session))
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                if availableTypes.count > 1 {
                    Menu {
                        Picker("Type", selection: $typeFilter) {
                            Text("AllTypes").tag(String?.none)
                            ForEach(availableTypes, id: \.self) { t in
                                Text(t).tag(String?.some(t))
                            }
                        }
                    } label: {
                        Label(typeFilter ?? String(localized: "AllTypes"),
                              systemImage: typeFilter == nil ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
                            .labelStyle(.titleAndIcon)
                            .foregroundStyle(Color.wpAccent)
                    }
                }
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
        // 換資料夾（含點進子資料夾、回上一層、開常用位置）時清掉類型篩選
        .onChange(of: session.stack) { _, _ in typeFilter = nil }
        .fullScreenCover(item: $selected) { file in
            detailView(for: file)
        }
        .task {
            // 只在第一次出現時開（從檢視畫面回來不會再開一次）
            guard !didOpenInitial, let item = initialLocation else { return }
            didOpenInitial = true
            session.openSaved(session.saved.first { $0.id == item.id } ?? item)
        }
        .alert("Error", isPresented: Binding(get: { session.errorMessage != nil },
                                             set: { if !$0 { session.errorMessage = nil } })) {
            Button("OK") {}
        } message: {
            Text(session.errorMessage ?? "")
        }
    }

    /// 縮圖格的按鈕。iOS 18+ 標記成 zoom 轉場的來源；用 helper 包起來，
    /// 避免在 ForEach 裡直接寫 if #available 分支讓型別檢查爆炸
    @ViewBuilder
    private func thumbnailButton(_ file: MediaFile) -> some View {
        let button = Button { selected = file } label: {
            ThumbnailCell(file: file)
        }
        .buttonStyle(CardPressStyle(scale: 0.97))
        .wpHoverHighlight()
        .accessibilityLabel(Text(file.relativeName))
        if #available(iOS 18, *) {
            button.matchedTransitionSource(id: file.id, in: zoomNS)
        } else {
            button
        }
    }

    /// fullScreenCover 的內容。iOS 18+ 從被點的那格縮圖 zoom 進來／縮回去
    /// （在檢視器裡滑到別張時轉場來源仍是原本那格，可接受）；iOS 17 沒有對應 API，維持系統的推入動畫
    @ViewBuilder
    private func detailView(for file: MediaFile) -> some View {
        let detail = PhotoDetailView(files: visibleFiles, current: file)
        if #available(iOS 18, *) {
            detail.navigationTransition(.zoom(sourceID: file.id, in: zoomNS))
        } else {
            detail
        }
    }
}

/// 縮圖格（LazyVGrid 只會載入看得到的格子）
///
/// 格子大小只由底色方塊決定：`Color.wpCard.aspectRatio(1, contentMode: .fit)` = 欄寬 × 欄寬。
/// 照片放在 overlay 裡 scaledToFill：overlay 不會改變底層尺寸，超出方塊的部分由 clipped() 裁掉。
/// （舊寫法把照片放進 ZStack，ZStack 會回報「照片填滿後」的尺寸，非正方形照片因此把格子撐寬／撐高，
///  蓋到隔壁格，看起來就是縮圖黏在一起、排不整齊。）
struct ThumbnailCell: View {
    let file: MediaFile
    @State private var image: UIImage?

    var body: some View {
        Color.wpCard
            // .fit：永遠不超過格線給的寬度（.fill 在某些父視圖下會再次超出）
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .transition(.opacity)
                } else {
                    // 載入中／無法產生縮圖：置中的圖示
                    Image(systemName: file.isVideo ? "film" : "photo")
                        .foregroundStyle(.secondary)
                }
            }
            .overlay(alignment: .topLeading) {
                if file.isRaw {
                    // 固定亮色外觀：霧面材質疊在深色照片上也維持白色小方塊、黑字
                    Text("RAW")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.black)
                        .padding(.horizontal, 5).padding(.vertical, 2)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                        .environment(\.colorScheme, .light)
                        .padding(5)
                }
            }
            .clipped()
            // clipped() 只裁畫面、不影響點擊範圍；contentShape 讓可點範圍 = 看得到的方塊，不會搶到隔壁格的點擊
            .contentShape(Rectangle())
            // 縮圖從佔位圖示換成照片時淡入（已在快取裡的會直接出現，不會閃）
            .animation(WPTheme.imageFade, value: image)
            .task(id: file.url) {
                image = ThumbnailCache.shared.cached(file.url)
                if image == nil {
                    image = await ThumbnailCache.shared.thumbnail(for: file)
                }
            }
    }
}
