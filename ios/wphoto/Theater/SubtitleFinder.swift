import Foundation

/// 外掛字幕搜尋（與 Windows 版相同規則，另外也找 VLC 預設會找的「Subtitles」資料夾）：
/// 影片同資料夾與「Subs」/「Subtitles」子資料夾裡的 .srt / .ass / .ssa / .sub / .vtt，
/// 檔名與影片相同的排最前，再來是以影片檔名開頭的（例如「影片.zh-TW.srt」），最多 15 個。
enum SubtitleFinder {
    static let maxCount = 15

    /// 在背景執行緒搜尋（NAS 上列資料夾可能要花一點時間）
    static func find(for videoURL: URL) async -> [URL] {
        await Task.detached(priority: .userInitiated) {
            SubtitleFinder.search(for: videoURL)
        }.value
    }

    static func search(for videoURL: URL) -> [URL] {
        let baseName = videoBaseName(videoURL)
        let top = scan(videoURL.deletingLastPathComponent())
        var candidates = top.subtitles
        for folder in top.subFolders {
            candidates += scan(folder).subtitles
        }

        let sorted = candidates.sorted { a, b in
            let ra = matchRank(a, videoBaseName: baseName), rb = matchRank(b, videoBaseName: baseName)
            if ra != rb { return ra < rb }
            return a.lastPathComponent.localizedStandardCompare(b.lastPathComponent) == .orderedAscending
        }
        return Array(sorted.prefix(maxCount))
    }

    /// 是不是這部影片自己的字幕：檔名以影片檔名開頭（不分大小寫）。
    /// 只有這種字幕會自動開啟；其他（例如別集的字幕）只列在選單裡。
    static func matches(_ subtitle: URL, video: URL) -> Bool {
        matchRank(subtitle, videoBaseName: videoBaseName(video)) < 2
    }

    /// 0 = 檔名與影片相同、1 = 以影片檔名開頭、2 = 其他
    private static func matchRank(_ subtitle: URL, videoBaseName: String) -> Int {
        let name = subtitle.deletingPathExtension().lastPathComponent.lowercased()
        if name == videoBaseName { return 0 }
        return name.hasPrefix(videoBaseName) ? 1 : 2
    }

    private static func videoBaseName(_ videoURL: URL) -> String {
        videoURL.deletingPathExtension().lastPathComponent.lowercased()
    }

    /// 列一次資料夾：字幕檔 + 「Subs」/「Subtitles」子資料夾（名稱不分大小寫，NAS 可能分大小寫）。
    /// 未下載的 iCloud 占位 ".<檔名>.icloud" 換回真正檔名（播放前再下載）。
    private static func scan(_ dir: URL) -> (subtitles: [URL], subFolders: [URL]) {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isDirectoryKey]
        let items = (try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: Array(keys), options: [])) ?? []
        var subtitles: [URL] = []
        var subFolders: [URL] = []
        var seen = Set<String>()
        for item in items {
            var url = item
            if item.lastPathComponent.hasPrefix(".") {
                guard let real = FileAvailability.documentURL(forPlaceholderStub: item) else { continue }
                url = real
            } else {
                let values = try? item.resourceValues(forKeys: keys)
                if values?.isDirectory == true {
                    let name = item.lastPathComponent.lowercased()
                    if name == "subs" || name == "subtitles" { subFolders.append(item) }
                    continue
                }
                guard values?.isRegularFile == true else { continue }
            }
            guard MediaTypes.isSubtitle(url), seen.insert(url.lastPathComponent).inserted else { continue }
            subtitles.append(url)
        }
        return (subtitles, subFolders)
    }
}
