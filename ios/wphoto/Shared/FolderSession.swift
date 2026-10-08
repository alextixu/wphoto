import Foundation
import Combine

/// 透過「檔案」App 選取的資料夾：iCloud Drive、本機、或在「檔案」中連接的 NAS (SMB) 都適用。
/// 開過的資料夾會記在「常用位置」，下次點一下就能開；但 App 啟動時不會自動開啟任何資料夾
/// （以前會自動重開上次的資料夾，NAS 沒連線時就卡在掃描畫面）。
/// 開啟常用位置時，解析書籤與掃描都在背景執行，隨時可以取消。
@MainActor
final class FolderSession: ObservableObject {
    enum Kind: String { case photo, video }

    /// 常用位置：存資料夾的書籤（含存取權限），之後不必再從「檔案」選一次
    struct SavedFolder: Codable, Identifiable, Equatable {
        var id = UUID()
        var name: String
        /// 用來比對是不是同一個資料夾，以及顯示上一層資料夾名稱
        var path: String
        var bookmark: Data
        var lastOpened: Date

        var parentName: String {
            URL(fileURLWithPath: path).deletingLastPathComponent().lastPathComponent
        }
    }

    @Published private(set) var folderURL: URL?
    @Published private(set) var files: [MediaFile] = []
    @Published private(set) var isScanning = false
    @Published var errorMessage: String?
    /// 常用位置（最近開啟的在前）
    @Published private(set) var saved: [SavedFolder] = []
    /// 正在開啟的常用位置名稱（解析書籤中，可取消）
    @Published private(set) var openingName: String?

    /// 最多記住幾個位置
    private static let maxSaved = 30

    private let kind: Kind
    private var accessing = false
    /// 每次開啟資料夾 +1：較早開始、較晚回來的掃描結果直接丟棄
    private var scanGeneration = 0

    init(kind: Kind) {
        self.kind = kind
        // 清掉舊版存的資料夾書籤（舊版會在啟動時自動重開）
        UserDefaults.standard.removeObject(forKey: "folderBookmark.\(kind.rawValue)")
        loadSaved()
    }

    private var savedKey: String { "savedFolders.\(kind.rawValue)" }

    var folderDisplayName: String {
        folderURL?.lastPathComponent ?? ""
    }

    // MARK: - 開啟資料夾

    /// 使用者剛從檔案選取器選到的資料夾
    func open(_ url: URL) {
        stopAccess()
        guard url.startAccessingSecurityScopedResource() else {
            errorMessage = String(localized: "AccessDenied")
            return
        }
        accessing = true
        folderURL = url
        openingName = nil
        remember(url)
        Task { await scan() }
    }

    /// 開啟常用位置：書籤在背景解析（NAS 沒連線時可能要等），期間可以取消
    func openSaved(_ item: SavedFolder) {
        errorMessage = nil
        scanGeneration += 1
        let generation = scanGeneration
        openingName = item.name
        let bookmark = item.bookmark
        Task {
            let url = await Task.detached(priority: .userInitiated) { () -> URL? in
                var stale = false
                return try? URL(resolvingBookmarkData: bookmark, options: [], relativeTo: nil,
                                bookmarkDataIsStale: &stale)
            }.value
            guard generation == scanGeneration else { return }   // 使用者已取消或改開別的
            openingName = nil
            guard let url else {
                errorMessage = String(localized: "CannotOpenLocation")
                return
            }
            open(url)   // 會重新存書籤（書籤過期時也一併更新）
        }
    }

    /// 回到常用位置清單：取消正在進行的開啟或掃描
    func closeFolder() {
        scanGeneration += 1
        stopAccess()
        folderURL = nil
        files = []
        isScanning = false
        openingName = nil
    }

    func removeSaved(_ id: SavedFolder.ID) {
        saved.removeAll { $0.id == id }
        persistSaved()
    }

    func renameSaved(_ id: SavedFolder.ID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let i = saved.firstIndex(where: { $0.id == id }) else { return }
        saved[i].name = trimmed
        persistSaved()
    }

    // MARK: - 常用位置的儲存

    /// 開過的資料夾記到常用位置（同一個資料夾只留一筆，保留使用者改過的名稱）
    private func remember(_ url: URL) {
        guard let data = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
        else { return }
        let path = url.standardizedFileURL.path
        if let i = saved.firstIndex(where: { $0.path == path }) {
            var item = saved.remove(at: i)
            item.bookmark = data
            item.lastOpened = Date()
            saved.insert(item, at: 0)
        } else {
            saved.insert(SavedFolder(name: url.lastPathComponent, path: path, bookmark: data, lastOpened: Date()), at: 0)
            if saved.count > Self.maxSaved { saved.removeLast(saved.count - Self.maxSaved) }
        }
        persistSaved()
    }

    private func loadSaved() {
        guard let data = UserDefaults.standard.data(forKey: savedKey),
              let items = try? JSONDecoder().decode([SavedFolder].self, from: data) else { return }
        saved = items
    }

    private func persistSaved() {
        if let data = try? JSONEncoder().encode(saved) {
            UserDefaults.standard.set(data, forKey: savedKey)
        }
    }

    private func stopAccess() {
        if accessing, let url = folderURL {
            url.stopAccessingSecurityScopedResource()
        }
        accessing = false
        files = []
    }

    // MARK: - 掃描（遞迴子資料夾）

    private func scan() async {
        guard let root = folderURL else { return }
        scanGeneration += 1
        let generation = scanGeneration
        isScanning = true
        errorMessage = nil
        let wantVideo = kind == .video
        let result: [MediaFile] = await Task.detached(priority: .userInitiated) {
            Self.enumerate(root: root, video: wantVideo)
        }.value
        // 掃描期間使用者已改選別的資料夾（例如 NAS 沒回應時改選本機）：這份結果不要了
        guard generation == scanGeneration else { return }
        files = result
        isScanning = false
    }

    nonisolated private static func enumerate(root: URL, video: Bool) -> [MediaFile] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey, .nameKey]
        // 不用 .skipsHiddenFiles：未下載的 iCloud 影片在磁碟上可能只是隱藏的 ".<檔名>.icloud" 占位檔，
        // 要換回真正檔名列出來（播放前再下載）；其他隱藏項目自行略過
        guard let en = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: keys, options: [.skipsPackageDescendants]
        ) else { return [] }

        let rootPath = root.standardizedFileURL.path
        var out: [MediaFile] = []
        var seen = Set<String>()
        for case let url as URL in en {
            var fileURL = url
            if url.lastPathComponent.hasPrefix(".") {
                // 占位檔只在看劇模式列出（照片模式目前無法先下載再檢視，維持原本略過）
                guard video, let real = FileAvailability.documentURL(forPlaceholderStub: url) else {
                    if (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                        en.skipDescendants()   // 隱藏資料夾不往下走
                    }
                    continue
                }
                fileURL = real
            } else {
                guard let v = try? url.resourceValues(forKeys: Set(keys)), v.isRegularFile == true else { continue }
            }
            let ok = video ? MediaTypes.isVideo(fileURL) : MediaTypes.isPhoto(fileURL)
            guard ok else { continue }
            let full = fileURL.standardizedFileURL.path
            guard seen.insert(full).inserted else { continue }   // 本體與占位同時存在時只列一次
            var rel = full.hasPrefix(rootPath) ? String(full.dropFirst(rootPath.count)) : fileURL.lastPathComponent
            if rel.hasPrefix("/") { rel.removeFirst() }
            out.append(MediaFile(url: fileURL, relativeName: rel))
        }
        return out.sorted { $0.relativeName.localizedStandardCompare($1.relativeName) == .orderedAscending }
    }
}
