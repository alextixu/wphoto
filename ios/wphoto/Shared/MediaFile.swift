import Foundation

/// 資料夾裡的一個媒體檔案
struct MediaFile: Identifiable, Hashable {
    let url: URL
    /// 相對於所選資料夾的路徑（子資料夾的檔案顯示「子資料夾/檔名」）
    let relativeName: String

    var id: URL { url }
    var ext: String { url.pathExtension.lowercased() }
    var isRaw: Bool { MediaTypes.rawExts.contains(ext) }
    var isVideo: Bool { MediaTypes.isVideo(url) }
    /// MP4 / M4V / MOV：可交給 AVPlayer（保留 HDR、杜比視界、子母畫面）
    var isAVFoundationNative: Bool { MediaTypes.isAVFoundationNative(url) }
    var typeLabel: String { MediaTypes.typeLabel(ext) }
}

enum MediaTypes {
    static let rawExts: Set<String> = [
        "cr2", "cr3", "nef", "nrw", "arw", "srf", "sr2", "dng",
        "raf", "orf", "rw2", "pef", "srw", "raw", "rwl", "3fr",
        "fff", "iiq", "x3f", "erf", "mrw", "kdc", "dcr",
    ]
    static let imageExts: Set<String> = [
        "jpg", "jpeg", "png", "tif", "tiff", "bmp", "gif", "heic", "heif", "hif", "webp",
    ]
    /// AVFoundation 原生可播放的容器
    static let avFoundationVideoExts: Set<String> = ["mp4", "m4v", "mov"]
    /// 其他容器（MKV、MTS、AVI…）AVPlayer 不支援，交給 VLCKit 播放
    static let vlcVideoExts: Set<String> = [
        "mkv", "webm", "avi", "mts", "m2ts", "ts", "wmv", "flv", "3gp",
    ]
    static let videoExts: Set<String> = avFoundationVideoExts.union(vlcVideoExts)
    /// 外掛字幕（與 Windows 版相同）
    static let subtitleExts: Set<String> = ["srt", "ass", "ssa", "sub", "vtt"]

    static func isPhoto(_ url: URL) -> Bool {
        let e = url.pathExtension.lowercased()
        return rawExts.contains(e) || imageExts.contains(e)
    }

    static func isVideo(_ url: URL) -> Bool {
        videoExts.contains(url.pathExtension.lowercased())
    }

    static func isAVFoundationNative(_ url: URL) -> Bool {
        avFoundationVideoExts.contains(url.pathExtension.lowercased())
    }

    static func isSubtitle(_ url: URL) -> Bool {
        subtitleExts.contains(url.pathExtension.lowercased())
    }

    /// 副檔名 → 類型名稱（同義副檔名合併，與 Windows 版一致）
    static func typeLabel(_ ext: String) -> String {
        switch ext {
        case "jpg", "jpeg": return "JPEG"
        case "tif", "tiff": return "TIFF"
        case "heif", "hif", "heic": return "HEIF"
        default: return ext.uppercased()
        }
    }
}
