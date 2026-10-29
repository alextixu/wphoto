import SwiftUI

/// 播放入口（fullScreenCover）：先確認檔案可讀（NAS / iCloud 未下載的先下載），
/// 再決定用哪個引擎：
///  - MP4 / M4V / MOV、沒有同名外掛字幕、AVPlayer 可播 → AVPlayer（保留 HDR、杜比視界、子母畫面、AirPlay）
///  - 其他容器（MKV、AVI、TS…）或有同名外掛字幕 → VLC
///  - AVPlayer 播放失敗 → 自動改用 VLC
/// 看到哪裡記在 WatchProgressStore：下次從那裡繼續（看不到 30 秒或已看到最後 5% 的從頭播）。
struct PlaybackScreen: View {
    let file: MediaFile
    /// 從哪個常用位置、哪一層開的（首頁「繼續觀看」用）
    var origin: PlaybackOrigin? = nil

    @StateObject private var preparer = PlaybackPreparer()
    @Environment(\.dismiss) private var dismiss

    /// 階段代號：只拿來驅動「準備中 → 播放 / 失敗」的淡入淡出。
    /// Phase 帶 associated value，不便直接當 animation 的 value，用整數代替
    private var phaseKey: Int {
        switch preparer.phase {
        case .checking: 0
        case .downloading: 1
        case .ready: 2
        case .failed: 3
        }
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            switch preparer.phase {
            case .checking:
                preparing(downloading: false)
                    .transition(.opacity)
            case .downloading:
                preparing(downloading: true)
                    .transition(.opacity)
            case .failed(let message):
                failure(message)
                    .transition(.opacity)
            case .ready(let plan):
                switch plan.engine {
                case .avPlayer:
                    PlayerScreen(url: plan.videoURL, resumeMs: plan.resumeMs, onProgress: recordProgress,
                                 onFailure: { preparer.fallBackToVLC() })
                        .transition(.opacity)
                case .vlc:
                    VLCPlayerScreen(title: file.url.lastPathComponent,
                                    url: plan.videoURL,
                                    subtitles: plan.subtitleURLs,
                                    resumeMs: plan.resumeMs,
                                    onProgress: recordProgress)
                        .transition(.opacity)
                }
            }
        }
        // 階段切換用淡入淡出，不要硬切（AVPlayer → VLC 的備援不換階段，維持直接換，不多閃一次黑畫面）
        .animation(.easeInOut(duration: 0.25), value: phaseKey)
        .task { await preparer.prepare(file) }
        .onDisappear { preparer.release() }
    }

    /// 進度以原本的檔案為準（不是下載後的暫存位置）
    private func recordProgress(positionMs: Int, durationMs: Int) {
        WatchProgressStore.shared.record(url: file.url, positionMs: positionMs, durationMs: durationMs, origin: origin)
    }

    private func preparing(downloading: Bool) -> some View {
        VStack(spacing: 16) {
            ProgressView()
                .controlSize(.large)
                .tint(.white)
            Text(downloading ? "Downloading" : "Preparing")
                .font(.headline)
                .foregroundStyle(.white)
            Text(file.url.lastPathComponent)
                .font(.footnote)
                .foregroundStyle(Color.wpSecondaryLabel)
                .lineLimit(2)
                .multilineTextAlignment(.center)
            if downloading {
                Text("DownloadNote")
                    .font(.footnote)
                    .foregroundStyle(Color.wpSecondaryLabel)
                    .multilineTextAlignment(.center)
            }
            Button("Cancel") { dismiss() }
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
                .tint(.white)
                .padding(.top, 8)
        }
        .padding(.horizontal, 40)
    }

    private func failure(_ message: LocalizedStringKey) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 40))
                .foregroundStyle(.yellow)
            Text(message)
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
            Text(file.url.lastPathComponent)
                .font(.footnote)
                .foregroundStyle(Color.wpSecondaryLabel)
                .lineLimit(2)
                .multilineTextAlignment(.center)
            Button("Close") { dismiss() }
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.capsule)
                .padding(.top, 6)
        }
        // 失敗訊息裝進浮起的材質卡：跟純黑底分開，一眼看出這是一則要處理的訊息
        .padding(24)
        .wpCard(radius: WPTheme.Radius.hero, elevated: true)
        .padding(.horizontal, 40)
    }
}

/// 播放前準備：下載（需要時）、找外掛字幕、選引擎。播放期間持有 PreparedFile，關閉時釋放。
@MainActor
final class PlaybackPreparer: ObservableObject {
    enum Engine { case avPlayer, vlc }

    struct Plan {
        let videoURL: URL
        let subtitleURLs: [URL]
        let engine: Engine
        /// 續播位置（毫秒）；nil = 從頭播
        let resumeMs: Int?
    }

    enum Phase {
        case checking
        case downloading
        case ready(Plan)
        case failed(LocalizedStringKey)
    }

    @Published private(set) var phase: Phase = .checking
    private var held: [PreparedFile] = []
    private var started = false

    func prepare(_ file: MediaFile) async {
        guard !started else { return }
        started = true
        var locality = FileLocality.unknown
        do {
            // 外掛字幕（同資料夾 + Subs 子資料夾）
            let subtitles = await SubtitleFinder.find(for: file.url)

            // 影片本體：未下載的要先完整下載（iOS 無法邊下載邊播）
            locality = await FileAvailability.currentLocality(of: file.url)
            if locality == .remote { phase = .downloading }
            let video = try await FileAvailability.prepareForReading(file.url)
            held.append(video)

            // 只有「這部影片自己的字幕」（檔名以影片檔名開頭）才需要改用 VLC；
            // 資料夾裡別集的字幕不算，否則 MP4 會白白失去 HDR、子母畫面與 AirPlay
            let hasOwnSubtitle = subtitles.contains { SubtitleFinder.matches($0, video: file.url) }
            var engine = Engine.vlc
            if file.isAVFoundationNative && !hasOwnSubtitle {
                let playable = await VideoThumbnailer.isPlayable(url: video.url)
                if playable { engine = .avPlayer }
            }

            // 字幕檔也要可讀（很小，下載失敗就略過那一個）
            var subtitleURLs: [URL] = []
            if engine == .vlc {
                for sub in subtitles {
                    guard let prepared = try? await FileAvailability.prepareForReading(sub) else { continue }
                    held.append(prepared)
                    subtitleURLs.append(prepared.url)
                }
            }
            try Task.checkCancellation()
            let resumeMs = WatchProgressStore.shared.resumePositionMs(for: file.url)
            phase = .ready(Plan(videoURL: video.url, subtitleURLs: subtitleURLs, engine: engine, resumeMs: resumeMs))
        } catch is CancellationError {
            // 使用者按了取消、畫面已關閉
        } catch {
            if !Task.isCancelled {
                phase = .failed(locality == .remote ? "DownloadFailed" : "CantPlayVideo")
            }
        }
    }

    /// AVPlayer 無法播放（例如 MP4 裡是不支援的編碼）→ 改用 VLC
    func fallBackToVLC() {
        guard case .ready(let plan) = phase, plan.engine == .avPlayer else { return }
        phase = .ready(Plan(videoURL: plan.videoURL, subtitleURLs: plan.subtitleURLs, engine: .vlc, resumeMs: plan.resumeMs))
    }

    func release() {
        held.forEach { $0.close() }
        held = []
    }
}
