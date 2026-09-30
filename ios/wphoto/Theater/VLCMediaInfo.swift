import UIKit
import MobileVLCKit

/// VLCKit 縮圖結果：finished = 縮圖器有跑完（逾時或成功）；false 表示被取消、沒有真的嘗試
struct VLCThumbnailResult {
    var image: UIImage?
    var durationMs: Int?
    var finished: Bool
}

/// AVFoundation 不支援的容器（MKV / AVI / TS…）：用 VLCKit 擷取封面、讀取時長。
/// VLCMediaThumbnailer 必須在主執行緒啟動，回呼也在主執行緒，所以整個型別綁在 MainActor。
@MainActor
enum VLCMediaInfo {
    /// 每個縮圖工作都會開一個軟體解碼的 libvlc 播放器，同時最多跑 2 個
    private static let maxThumbnailJobs = 2
    private static var runningJobs = 0
    private static var waitingJobs: [CheckedContinuation<Void, Never>] = []

    /// 擷取封面（約影片 30% 處；VLCKit 預設位置），順便帶回解析到的時長
    static func thumbnail(url: URL, maxPixel: Int) async -> VLCThumbnailResult {
        await acquireSlot()
        defer { releaseSlot() }
        // 排隊期間卡片已捲出畫面：不做了，讓出名額
        if Task.isCancelled { return VLCThumbnailResult(image: nil, durationMs: nil, finished: false) }

        return await withCheckedContinuation { continuation in
            // 要求 16:9 的框；VLCKit 會依影片比例放大到「填滿」這個框（封面卡片是 16:9）
            let width = CGFloat(maxPixel)
            let height = (width * 9 / 16).rounded()
            VLCThumbnailJob().start(url: url, width: width, height: height) { image, durationMs in
                continuation.resume(returning: VLCThumbnailResult(
                    image: image.map { UIImage(cgImage: $0) },
                    durationMs: durationMs,
                    finished: true))
            }
        }
    }

    /// 只讀時長（毫秒）：解析檔頭，不解碼畫面
    static func durationMs(url: URL) async -> Int? {
        await withCheckedContinuation { continuation in
            VLCDurationProbe().start(url: url) { ms in
                continuation.resume(returning: ms)
            }
        }
    }

    // MARK: - 並行上限（狀態都在 MainActor 上）

    private static func acquireSlot() async {
        if runningJobs < maxThumbnailJobs {
            runningJobs += 1
            return
        }
        await withCheckedContinuation { waitingJobs.append($0) }
    }

    private static func releaseSlot() {
        if waitingJobs.isEmpty {
            runningJobs -= 1
        } else {
            waitingJobs.removeFirst().resume()   // 名額直接交給下一個排隊者
        }
    }
}

/// 一次縮圖工作。縮圖器的 delegate 是 weak，所以工作期間自己保留自己（keepAlive）。
private final class VLCThumbnailJob: NSObject, VLCMediaThumbnailerDelegate {
    private var thumbnailer: VLCMediaThumbnailer?
    private var completion: ((CGImage?, Int?) -> Void)?
    private var keepAlive: VLCThumbnailJob?

    func start(url: URL, width: CGFloat, height: CGFloat, completion: @escaping (CGImage?, Int?) -> Void) {
        self.completion = completion
        keepAlive = self
        // 每張縮圖用獨立的 VLCMedia：縮圖器會改寫 media 的選項（no-audio、start-time…）
        let t = VLCMediaThumbnailer(media: VLCMedia(url: url), andDelegate: self)
        t.thumbnailWidth = width
        t.thumbnailHeight = height
        thumbnailer = t
        t.fetchThumbnail()
        // 保險：VLCKit 自己的逾時是解析 10 秒 + 擷取 10 秒，超過 30 秒仍沒回呼就放棄
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in
            self?.finish(nil)
        }
    }

    func mediaThumbnailer(_ mediaThumbnailer: VLCMediaThumbnailer, didFinishThumbnail thumbnail: CGImage) {
        finish(thumbnail)
    }

    func mediaThumbnailerDidTimeOut(_ mediaThumbnailer: VLCMediaThumbnailer) {
        finish(nil)
    }

    private func finish(_ image: CGImage?) {
        guard let completion else { return }
        self.completion = nil
        var durationMs: Int?
        if let length = thumbnailer?.media.length, length.value != nil, length.intValue > 0 {
            durationMs = Int(length.intValue)
        }
        thumbnailer?.delegate = nil
        thumbnailer = nil
        completion(image, durationMs)
        keepAlive = nil
    }
}

/// 解析檔頭取得時長。VLCMedia 與 delegate 都是 weak 參照，工作期間自己保留自己。
private final class VLCDurationProbe: NSObject, VLCMediaDelegate {
    private var media: VLCMedia?
    private var completion: ((Int?) -> Void)?
    private var keepAlive: VLCDurationProbe?

    func start(url: URL, completion: @escaping (Int?) -> Void) {
        self.completion = completion
        keepAlive = self
        let m = VLCMedia(url: url)
        m.delegate = self
        media = m
        // options [] = 只解析本機檔案；回傳 0 表示已排入解析佇列
        guard m.parse(options: [], timeout: 5000) == 0 else {
            finish()
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
            self?.media?.parseStop()
            self?.finish()
        }
    }

    func mediaDidFinishParsing(_ aMedia: VLCMedia) {
        finish()
    }

    private func finish() {
        guard let completion else { return }
        self.completion = nil
        var durationMs: Int?
        if let m = media, m.parsedStatus == .done, m.length.value != nil, m.length.intValue > 0 {
            durationMs = Int(m.length.intValue)
        }
        media?.delegate = nil
        media = nil
        completion(durationMs)
        keepAlive = nil
    }
}
