import Foundation
import Combine

/// 透過「檔案」App 選取的資料夾：iCloud Drive、本機、或在「檔案」中連接的 NAS (SMB) 都適用。
/// 開過的資料夾會記在「常用位置」，下次點一下就能開；但 App 啟動時不會自動開啟任何資料夾
/// （以前會自動重開上次的資料夾，NAS 沒連線時就卡在掃描畫面）。
/// 開啟常用位置時，解析書籤與掃描都在背景執行，隨時可以取消。
/// 資料夾一層一層進去：每次只讀目前這一層（子資料夾＋媒體檔），NAS 上的大資料夾也能很快打開。
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

    /// 目前這一層的子資料夾
    struct SubFolder: Identifiable, Hashable {
        let url: URL
        let name: String
        var id: URL { url }
    }

    /// 開啟的位置本身（從「檔案」選的或常用位置）
    @Published private(set) var folderURL: URL?
    /// 從開啟的位置一路點進去的資料夾：第一個是位置本身，最後一個是目前這一層
    @Published private(set) var stack: [URL] = []
    /// 目前這一層的子資料夾與媒體檔
    @Published private(set) var folders: [SubFolder] = []
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
    /// 每次開啟或關閉位置 +1：較早開始、較晚回來的掃描結果直接丟棄
    private var scanGeneration = 0
    /// 讀過的每一層都記著：回上一層不必再讀 NAS
    private var listings: [URL: Listing] = [:]

    private struct Listing {
        var folders: [SubFolder] = []
        var files: [MediaFile] = []
    }

    /// 看劇模式不列出字幕資料夾（播放時會自動去裡面找字幕）
    private static let subtitleFolderNames: Set<String> = ["subs", "subtitles"]

    init(kind: Kind) {
        self.kind = kind
        // 清掉舊版存的資料夾書籤（舊版會在啟動時自動重開）
        UserDefaults.standard.removeObject(forKey: "folderBookmark.\(kind.rawValue)")
        loadSaved()
    }

    private var savedKey: String { "savedFolders.\(kind.rawValue)" }

    /// 目前這一層的名稱
    var folderDisplayName: String {
        stack.last?.lastPathComponent ?? ""
    }

    /// 是否在點進去的子資料夾裡（可以回上一層）
    var canGoUp: Bool { stack.count > 1 }

    /// 上一層的名稱（返回按鈕用）
    var parentDisplayName: String {
        stack.count > 1 ? stack[stack.count - 2].lastPathComponent : ""
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
        scanGeneration += 1
        folderURL = url
        stack = [url]
        openingName = nil
        remember(url)
        Task { await load(url) }
    }

    /// 點進子資料夾
    func enter(_ folder: SubFolder) {
        guard folderURL != nil, stack.last != folder.url else { return }   // 連點兩下只進去一次
        stack.append(folder.url)
        Task { await load(folder.url) }
    }

    /// 回上一層（讀過的層直接顯示）
    func goUp() {
        guard stack.count > 1 else { return }
        stack.removeLast()
        if let url = stack.last { Task { await load(url) } }
    }

    /// 掃描中按取消：在子資料夾就回上一層，在最上層就回到常用位置清單
    func cancelScan() {
        if canGoUp { goUp() } else { closeFolder() }
    }

    /// 重新讀取目前這一層（下拉更新）
    func reload() async {
        guard let url = stack.last else { return }
        listings[url] = nil
        await load(url, showProgress: false)
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
        stack = []
        listings = [:]
        folders = []
        files = []
    }

    // MARK: - 讀取一層資料夾

    private func load(_ url: URL, showProgress: Bool = true) async {
        if let cached = listings[url] {
            folders = cached.folders
            files = cached.files
            isScanning = false
            return
        }
        let generation = scanGeneration
        if showProgress {
            isScanning = true
            folders = []
            files = []
        }
        errorMessage = nil
        let wantVideo = kind == .video
        let result: Listing? = await Task.detached(priority: .userInitiated) {
            Self.list(url, video: wantVideo)
        }.value
        // 期間使用者已關閉或改開別的位置：這份結果不要了
        guard generation == scanGeneration else { return }
        if let result { listings[url] = result }
        // 已經離開這一層（例如按了取消回上一層）：結果留著，下次點進來直接顯示
        guard stack.last == url else { return }
        folders = result?.folders ?? []
        files = result?.files ?? []
        isScanning = false
        if result == nil { errorMessage = String(localized: "CannotOpenLocation") }
    }

    /// 只讀這一層：子資料夾＋媒體檔（讀不到時回傳 nil，例如 NAS 斷線）
    nonisolated private static func list(_ dir: URL, video: Bool) -> Listing? {
        let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey, .isPackageKey]
        // 不略過隱藏檔：未下載的 iCloud 影片在磁碟上可能只是隱藏的 ".<檔名>.icloud" 占位檔，
        // 要換回真正檔名列出來（播放前再下載）；其他隱藏項目自行略過
        guard let items = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: keys, options: []
        ) else { return nil }

        var out = Listing()
        var seen = Set<String>()
        for url in items {
            var fileURL = url
            let name = url.lastPathComponent
            if name.hasPrefix(".") {
                // 占位檔只在看劇模式列出（照片模式目前無法先下載再檢視，維持原本略過）
                guard video, let real = FileAvailability.documentURL(forPlaceholderStub: url) else { continue }
                fileURL = real
            } else {
                guard let v = try? url.resourceValues(forKeys: Set(keys)) else { continue }
                if v.isDirectory == true {
                    guard v.isPackage != true else { continue }
                    if video && subtitleFolderNames.contains(name.lowercased()) { continue }
                    out.folders.append(SubFolder(url: url, name: name))
                    continue
                }
                guard v.isRegularFile == true else { continue }
            }
            let ok = video ? MediaTypes.isVideo(fileURL) : MediaTypes.isPhoto(fileURL)
            guard ok else { continue }
            guard seen.insert(fileURL.standardizedFileURL.path).inserted else { continue }   // 本體與占位同時存在時只列一次
            out.files.append(MediaFile(url: fileURL, relativeName: fileURL.lastPathComponent))
        }
        out.folders.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        out.files.sort { $0.relativeName.localizedStandardCompare($1.relativeName) == .orderedAscending }
        return out
    }
}
