import Foundation
import Combine

/// 透過「檔案」App 選取的資料夾：iCloud Drive、本機、或在「檔案」中連接的 NAS (SMB) 都適用。
/// 不記住上次的資料夾：每次開啟 App 都由使用者重新選擇。
/// （以前會在啟動時自動重開上次的資料夾，NAS 沒連線時就卡在掃描畫面。）
@MainActor
final class FolderSession: ObservableObject {
    enum Kind: String { case photo, video }

    @Published private(set) var folderURL: URL?
    @Published private(set) var files: [MediaFile] = []
    @Published private(set) var isScanning = false
    @Published var errorMessage: String?

    private let kind: Kind
    private var accessing = false
    /// 每次開啟資料夾 +1：較早開始、較晚回來的掃描結果直接丟棄
    private var scanGeneration = 0

    init(kind: Kind) {
        self.kind = kind
        // 清掉舊版存的資料夾書籤（舊版會在啟動時自動重開）
        UserDefaults.standard.removeObject(forKey: "folderBookmark.\(kind.rawValue)")
    }

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
        Task { await scan() }
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
