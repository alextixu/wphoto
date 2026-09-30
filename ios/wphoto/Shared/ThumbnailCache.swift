import Foundation
import UIKit
import AVFoundation

/// 縮圖與影片時長快取：NSCache 在記憶體吃緊時會自動釋放
final class ThumbnailCache {
    static let shared = ThumbnailCache()

    private let cache: NSCache<NSURL, UIImage> = {
        let c = NSCache<NSURL, UIImage>()
        c.countLimit = 400
        return c
    }()
    /// 影片時長（秒）
    private let durations = NSCache<NSURL, NSNumber>()
    /// VLC 解不出畫面的影片：捲回來時不再重試（每次失敗最多要等 20 秒）
    private let vlcFailures = NSCache<NSURL, NSNumber>()

    func cached(_ url: URL) -> UIImage? {
        cache.object(forKey: url as NSURL)
    }

    func cachedDuration(_ url: URL) -> Double? {
        durations.object(forKey: url as NSURL)?.doubleValue
    }

    /// 取得縮圖（照片：內嵌預覽優先；影片：MP4/MOV 擷取第 1 秒畫面，其他容器由 VLCKit 擷取）
    func thumbnail(for file: MediaFile, maxPixel: Int = 320) async -> UIImage? {
        if let c = cached(file.url) { return c }
        let key = file.url as NSURL
        let image: UIImage?
        if file.isVideo {
            // 未下載的影片（iCloud / NAS 占位）不產生縮圖，避免為了封面把整部影片下載下來
            guard await FileAvailability.isLikelyLocal(file.url) else { return nil }
            if file.isAVFoundationNative {
                image = await VideoThumbnailer.frame(url: file.url, maxPixel: maxPixel)
            } else {
                guard vlcFailures.object(forKey: key) == nil else { return nil }
                let result = await VLCMediaInfo.thumbnail(url: file.url, maxPixel: maxPixel)
                if let ms = result.durationMs, ms > 0 {
                    durations.setObject(NSNumber(value: Double(ms) / 1000), forKey: key)
                }
                if result.finished && result.image == nil {
                    vlcFailures.setObject(NSNumber(value: true), forKey: key)
                }
                image = result.image
            }
        } else {
            let url = file.url
            image = await Task.detached(priority: .utility) {
                ImageLoading.thumbnail(url: url, maxPixel: maxPixel)
            }.value
        }
        if let image {
            cache.setObject(image, forKey: key)
        }
        return image
    }

    /// 影片時長（秒）；未下載的影片回傳 nil
    func duration(for file: MediaFile) async -> Double? {
        if let d = cachedDuration(file.url) { return d }
        guard await FileAvailability.isLikelyLocal(file.url) else { return nil }
        let seconds: Double?
        if file.isAVFoundationNative {
            seconds = await VideoThumbnailer.duration(url: file.url)
        } else {
            seconds = await VLCMediaInfo.durationMs(url: file.url).map { Double($0) / 1000 }
        }
        if let seconds, seconds > 0 {
            durations.setObject(NSNumber(value: seconds), forKey: file.url as NSURL)
        }
        return seconds
    }
}

/// AVFoundation 原生容器（MP4 / MOV / M4V）的封面與時長
enum VideoThumbnailer {
    static func frame(url: URL, maxPixel: Int) async -> UIImage? {
        let asset = AVURLAsset(url: url)
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: maxPixel, height: maxPixel)
        do {
            let (cg, _) = try await gen.image(at: CMTime(seconds: 1, preferredTimescale: 600))
            return UIImage(cgImage: cg)
        } catch {
            return nil
        }
    }

    /// 時長（秒）
    static func duration(url: URL) async -> Double? {
        let asset = AVURLAsset(url: url)
        guard let d = try? await asset.load(.duration) else { return nil }
        let s = CMTimeGetSeconds(d)
        return s.isFinite ? s : nil
    }

    /// AVPlayer 能否播放（例如 MP4 裡是 AVFoundation 不支援的編碼時為 false，改用 VLC）
    static func isPlayable(url: URL) async -> Bool {
        let asset = AVURLAsset(url: url)
        return (try? await asset.load(.isPlayable)) ?? false
    }
}
