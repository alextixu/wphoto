import Foundation
import Combine

/// 影片是從哪個常用位置、點進哪幾層開的（首頁「繼續觀看」用來開回同一個地方）
struct PlaybackOrigin: Codable, Hashable {
    /// 常用位置本身的路徑（= FolderSession.SavedFolder.path）
    let locationPath: String
    /// 從常用位置一路點進去的子資料夾名稱
    let subfolders: [String]
}

/// 看劇模式記住每部影片看到哪裡（AVPlayer、VLC 共用）。
/// 續播、影片卡片的進度條與打勾、首頁的「繼續觀看」都讀這裡；存在 UserDefaults，只記路徑與時間，不碰影片檔。
@MainActor
final class WatchProgressStore: ObservableObject {
    static let shared = WatchProgressStore()

    struct Entry: Codable, Identifiable, Hashable {
        /// 影片檔路徑（standardized），也是 id
        var path: String
        var fileName: String
        var positionMs: Int
        var durationMs: Int
        var updatedAt: Date
        /// 曾經看到最後 5%：卡片打勾（之後重看一小段也不會不見）
        var watched: Bool
        var origin: PlaybackOrigin?

        var id: String { path }

        var fraction: Double {
            guard durationMs > 0 else { return 0 }
            return min(1, max(0, Double(positionMs) / Double(durationMs)))
        }

        /// 停在最後 5%：算看完，下次從頭播
        var isAtEnd: Bool {
            durationMs > 0 && Double(positionMs) >= Double(durationMs) * (1 - WatchProgressStore.endFraction)
        }

        /// 看了 30 秒以上、還沒看到最後 5%：下次從這裡繼續
        var isResumable: Bool {
            positionMs >= WatchProgressStore.minResumeMs && !isAtEnd
        }
    }

    /// 看不到 30 秒的就從頭播
    nonisolated static let minResumeMs = 30_000
    /// 看到最後 5% 的就從頭播（並且打勾）
    nonisolated static let endFraction = 0.05
    private static let defaultsKey = "watchProgress"
    /// 最多記住幾部影片（最近看的優先保留）
    private static let maxEntries = 500

    @Published private(set) var entries: [String: Entry] = [:]
    private var saveTask: Task<Void, Never>?

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.defaultsKey),
           let list = try? JSONDecoder().decode([Entry].self, from: data) {
            entries = Dictionary(list.map { ($0.path, $0) }, uniquingKeysWith: { a, b in a.updatedAt > b.updatedAt ? a : b })
        }
    }

    static func key(for url: URL) -> String {
        url.standardizedFileURL.path
    }

    func entry(for url: URL) -> Entry? {
        entries[Self.key(for: url)]
    }

    /// 續播位置（毫秒）；看不到 30 秒或已看到最後 5% 回傳 nil（從頭播）
    func resumePositionMs(for url: URL) -> Int? {
        guard let entry = entry(for: url), entry.isResumable else { return nil }
        return entry.positionMs
    }

    /// 首頁「繼續觀看」：還沒看完的，最近看的在前
    var continueWatching: [Entry] {
        entries.values
            .filter(\.isResumable)
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    /// 播放畫面定時回報、關閉時再回報一次
    func record(url: URL, positionMs: Int, durationMs: Int, origin: PlaybackOrigin?) {
        let key = Self.key(for: url)
        let existing = entries[key]
        // 沒有紀錄、又看不到 30 秒：只是點開看一下，不記（不會出現在「繼續觀看」）
        if existing == nil && positionMs < Self.minResumeMs { return }
        var entry = existing ?? Entry(path: key, fileName: url.lastPathComponent, positionMs: 0, durationMs: 0,
                                      updatedAt: Date(), watched: false, origin: nil)
        entry.positionMs = max(0, positionMs)
        if durationMs > 0 { entry.durationMs = durationMs }
        entry.updatedAt = Date()
        if entry.isAtEnd { entry.watched = true }
        if let origin { entry.origin = origin }
        guard entry != existing else { return }
        entries[key] = entry
        scheduleSave()
    }

    /// 從「繼續觀看」移除（影片的看完標記保留）
    func removeFromContinueWatching(_ path: String) {
        guard var entry = entries[path] else { return }
        entry.positionMs = 0
        entries[path] = entry
        scheduleSave()
    }

    // MARK: - 存檔

    /// 延遲 1 秒再寫入：播放中每 5 秒回報一次，不必每次都寫
    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            self?.flush()
        }
    }

    /// 立刻寫入（進背景前）
    func flush() {
        saveTask?.cancel()
        saveTask = nil
        var list = Array(entries.values)
        if list.count > Self.maxEntries {
            list.sort { $0.updatedAt > $1.updatedAt }
            list.removeLast(list.count - Self.maxEntries)
            entries = Dictionary(list.map { ($0.path, $0) }, uniquingKeysWith: { a, _ in a })
        }
        if let data = try? JSONEncoder().encode(list) {
            UserDefaults.standard.set(data, forKey: Self.defaultsKey)
        }
    }
}
