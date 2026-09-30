import Foundation
import Darwin
import UIKit
import QuickLookThumbnailing

/// 檔案內容是否已在本機。
/// 透過「檔案」App 取得的 iCloud Drive / NAS (SMB) / 第三方雲端項目，可能只是占位（內容還在遠端）。
enum FileLocality: Sendable, Equatable {
    case local     // 內容在本機：可直接交給 AVFoundation / ImageIO / VLCKit
    case remote    // 未下載：iCloud notDownloaded、占位檔 (.<檔名>.icloud)、APFS dataless
    case unknown   // 檔案不存在或無權限
}

/// prepareForReading 的結果：播放期間持有，關閉播放器時呼叫 close()。
/// 持有已開啟的 FileHandle，讓系統視為「仍在使用」，避免 File Provider 在播放中把本機副本清掉。
final class PreparedFile: @unchecked Sendable {
    let url: URL
    private let lock = NSLock()
    private var handle: FileHandle?

    init(url: URL, handle: FileHandle?) {
        self.url = url
        self.handle = handle
    }

    func close() {
        lock.lock()
        let h = handle
        handle = nil
        lock.unlock()
        try? h?.close()
    }

    deinit { try? handle?.close() }
}

enum FileAvailability {
    /// <sys/stat.h>：#define SF_DATALESS 0x40000000 /* file is dataless object */
    private static let sfDataless: UInt32 = 0x4000_0000
    private static let stubSuffix = ".icloud"

    // MARK: - 判斷（只讀 metadata，不會下載檔案）

    /// 同步版。會呼叫 stat()（TN3150：可能展開 dataless 的「上層資料夾」），請在背景執行緒呼叫。
    static func locality(of url: URL) -> FileLocality {
        var u = url
        u.removeAllCachedResourceValues()   // URL 會快取 resource values，重複查詢前要清掉

        // 1) iCloud Drive：官方下載狀態
        if let v = try? u.resourceValues(forKeys: [.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey]),
           v.isUbiquitousItem == true,
           let status = v.ubiquitousItemDownloadingStatus {
            // .current = 本機且最新；.downloaded = 本機有副本（可能較舊）→ 都可讀
            return status == .notDownloaded ? .remote : .local
        }

        // 2) POSIX stat
        var st = stat()
        let rc: Int32 = u.withUnsafeFileSystemRepresentation { path in
            guard let path else { return -1 }
            return stat(path, &st)
        }
        if rc != 0 {
            // 本體不存在：舊式 File Provider / iCloud 的占位是同資料夾的隱藏檔 ".<檔名>.icloud"
            return FileManager.default.fileExists(atPath: placeholderStubURL(for: u).path) ? .remote : .unknown
        }

        // 3) APFS dataless（TN3150 的官方判斷法）
        if (st.st_flags & sfDataless) != 0 { return .remote }
        return .local
    }

    /// 非同步版（背景執行緒）
    static func currentLocality(of url: URL) async -> FileLocality {
        await Task.detached(priority: .utility) {
            FileAvailability.locality(of: url)
        }.value
    }

    /// 給縮圖格 / 播放前判斷用
    static func isLikelyLocal(_ url: URL) async -> Bool {
        await currentLocality(of: url) == .local
    }

    // MARK: - 占位檔名稱對應

    /// "<資料夾>/<檔名>" → "<資料夾>/.<檔名>.icloud"
    static func placeholderStubURL(for url: URL) -> URL {
        url.deletingLastPathComponent()
            .appendingPathComponent("." + url.lastPathComponent + stubSuffix)
    }

    /// "<資料夾>/.<檔名>.icloud" → "<資料夾>/<檔名>"；不是占位檔則回傳 nil
    static func documentURL(forPlaceholderStub url: URL) -> URL? {
        let name = url.lastPathComponent
        guard name.hasPrefix("."), name.hasSuffix(stubSuffix),
              name.count > stubSuffix.count + 1 else { return nil }
        let real = String(name.dropFirst().dropLast(stubSuffix.count))
        return url.deletingLastPathComponent().appendingPathComponent(real)
    }

    // MARK: - 讓內容可讀（未下載時會下載「整個檔案」）

    /// - 已在本機：立即回傳。
    /// - 否則：iCloud 項目先 startDownloadingUbiquitousItem（不阻塞），再做「協調讀取」。
    ///   協調讀取會阻塞到整個檔案下載完成（iOS 沒有部分下載），因此放在 GCD 執行緒。
    /// - 呼叫端 Task 被取消 → NSFileCoordinator.cancel()，等待中的讀取以 NSUserCancelledError 結束。
    static func prepareForReading(_ url: URL) async throws -> PreparedFile {
        try Task.checkCancellation()
        if await isLikelyLocal(url) {
            return PreparedFile(url: url, handle: nil)
        }
        // iCloud：開始下載（非 iCloud 項目會丟錯，忽略即可）
        try? FileManager.default.startDownloadingUbiquitousItem(at: url)

        let op = CancellableCoordination()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<PreparedFile, Error>) in
                DispatchQueue.global(qos: .userInitiated).async {
                    cont.resume(with: op.run(url))
                }
            }
        } onCancel: {
            op.cancel()
        }
    }

    // MARK: - 未下載 iCloud 項目的縮圖（不下載整個檔案）

    /// iCloud 會替 ≥1 MB 的常見檔案上傳縮圖，QuickLook 直接取用；非 iCloud（NAS / 其他 File Provider）回傳 nil。
    static func remoteThumbnail(for url: URL, side: CGFloat, scale: CGFloat) async -> UIImage? {
        let keys: Set<URLResourceKey> = [.isUbiquitousItemKey]
        let values = (try? url.resourceValues(forKeys: keys)) ?? (try? url.promisedItemResourceValues(forKeys: keys))
        guard values?.isUbiquitousItem == true else { return nil }
        let request = QLThumbnailGenerator.Request(fileAt: url,
                                                   size: CGSize(width: side, height: side),
                                                   scale: scale,
                                                   representationTypes: .thumbnail)
        return try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request).uiImage
    }
}

/// 可取消的協調讀取（同步執行，會阻塞到檔案可讀或被取消）
private final class CancellableCoordination: @unchecked Sendable {
    private let coordinator = NSFileCoordinator(filePresenter: nil)
    private let lock = NSLock()
    private var cancelled = false

    private var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        lock.lock(); cancelled = true; lock.unlock()
        coordinator.cancel()
    }

    func run(_ url: URL) -> Result<PreparedFile, Error> {
        if isCancelled { return .failure(CancellationError()) }
        var coordError: NSError?
        var prepared: PreparedFile?
        coordinator.coordinate(readingItemAt: url, options: [], error: &coordError) { readableURL in
            // 一律使用 accessor 給的 URL；在協調期間先打開檔案，播放期間持有
            prepared = PreparedFile(url: readableURL, handle: try? FileHandle(forReadingFrom: readableURL))
        }
        if isCancelled {
            prepared?.close()
            return .failure(CancellationError())
        }
        if let prepared { return .success(prepared) }
        if let coordError { return .failure(coordError) }
        return .failure(CocoaError(.fileReadUnknown))
    }
}
