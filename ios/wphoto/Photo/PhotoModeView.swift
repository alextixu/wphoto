import SwiftUI
import UniformTypeIdentifiers

/// 照片模式：從「檔案」選資料夾 → 縮圖牆 → 點開檢視
struct PhotoModeView: View {
    @StateObject private var session = FolderSession(kind: .photo)
    @State private var showPicker = false
    @State private var typeFilter: String? = nil
    @State private var selected: MediaFile?

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
            Color.wpBackground.ignoresSafeArea()
            if session.folderURL == nil {
                EmptyFolderView(hint: "PlaceholderPhoto") { showPicker = true }
            } else if session.isScanning {
                ProgressView("Scanning")
            } else if visibleFiles.isEmpty {
                Text("NoPhotos").foregroundStyle(.secondary)
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: Self.gridSpacing) {
                        ForEach(visibleFiles) { file in
                            ThumbnailCell(file: file)
                                .onTapGesture { selected = file }
                        }
                    }
                    .padding(Self.gridSpacing)
                }
            }
        }
        .navigationTitle(session.folderURL == nil ? String(localized: "PhotoMode") : session.folderDisplayName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                if !availableTypes.isEmpty {
                    Menu {
                        Picker("Type", selection: $typeFilter) {
                            Text("AllTypes").tag(String?.none)
                            ForEach(availableTypes, id: \.self) { t in
                                Text(t).tag(String?.some(t))
                            }
                        }
                    } label: {
                        Label(typeFilter ?? String(localized: "AllTypes"), systemImage: "line.3.horizontal.decrease.circle")
                    }
                }
                Button { showPicker = true } label: {
                    Image(systemName: "folder")
                }
            }
            ToolbarItem(placement: .bottomBar) {
                if !session.files.isEmpty {
                    Text(String(format: String(localized: "PhotoCount"), visibleFiles.count, visibleFiles.filter(\.isRaw).count))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .fileImporter(isPresented: $showPicker, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result {
                typeFilter = nil
                session.open(url)
            }
        }
        .fullScreenCover(item: $selected) { file in
            PhotoDetailView(files: visibleFiles, current: file)
        }
        .alert("Error", isPresented: Binding(get: { session.errorMessage != nil },
                                             set: { if !$0 { session.errorMessage = nil } })) {
            Button("OK") {}
        } message: {
            Text(session.errorMessage ?? "")
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
                } else {
                    // 載入中／無法產生縮圖：置中的圖示
                    Image(systemName: file.isVideo ? "film" : "photo")
                        .foregroundStyle(.secondary)
                }
            }
            .overlay(alignment: .topLeading) {
                if file.isRaw {
                    Text("RAW")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5).padding(.vertical, 2)
                        .background(Color(red: 0.56, green: 0.35, blue: 0.17))
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                        .padding(5)
                }
            }
            .clipped()
            // clipped() 只裁畫面、不影響點擊範圍；contentShape 讓可點範圍 = 看得到的方塊，不會搶到隔壁格的點擊
            .contentShape(Rectangle())
            .task(id: file.url) {
                image = ThumbnailCache.shared.cached(file.url)
                if image == nil {
                    image = await ThumbnailCache.shared.thumbnail(for: file)
                }
            }
    }
}

struct EmptyFolderView: View {
    let hint: LocalizedStringKey
    let action: () -> Void

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "folder.badge.plus")
                .font(.system(size: 52))
                .foregroundStyle(Color.wpAccent)
            Text(hint)
                .foregroundStyle(.secondary)
            Button(action: action) {
                Text("ChooseFolder")
                    .fontWeight(.semibold)
                    .padding(.horizontal, 22).padding(.vertical, 10)
            }
            .buttonStyle(.borderedProminent)
            Text("FilesHint")
                .font(.footnote)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
        }
    }
}
