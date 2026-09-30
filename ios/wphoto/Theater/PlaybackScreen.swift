import SwiftUI

/// 播放入口（fullScreenCover）：先確認檔案可讀（NAS / iCloud 未下載的先下載），
/// 再決定用哪個引擎：
///  - MP4 / M4V / MOV、沒有同名外掛字幕、AVPlayer 可播 → AVPlayer（保留 HDR、杜比視界、子母畫面、AirPlay）
///  - 其他容器（MKV、AVI、TS…）或有同名外掛字幕 → VLC
///  - AVPlayer 播放失敗 → 自動改用 VLC
struct PlaybackScreen: View {
    let file: MediaFile

    @StateObject private var preparer = PlaybackPreparer()
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            switch preparer.phase {
            case .checking:
                preparing(downloading: false)
            case .downloading:
                preparing(downloading: true)
            case .failed(let message):
                failure(message)
            case .ready(let plan):
                switch plan.engine {
                case .avPlayer:
                    PlayerScreen(url: plan.videoURL) {
                        preparer.fallBackToVLC()
                    }
                case .vlc:
                    VLCPlayerScreen(title: file.url.lastPathComponent,
                                    url: plan.videoURL,
                                    subtitles: plan.subtitleURLs)
                }
            }
        }
        .task { await preparer.prepare(file) }
        .onDisappear { preparer.release() }
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
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .multilineTextAlignment(.center)
            if downloading {
                Text("DownloadNote")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            Button("Cancel") { dismiss() }
                .buttonStyle(.bordered)
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
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .multilineTextAlignment(.center)
            Button("Close") { dismiss() }
                .buttonStyle(.borderedProminent)
                .padding(.top, 6)
        }
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
            phase = .ready(Plan(videoURL: video.url, subtitleURLs: subtitleURLs, engine: engine))
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
        phase = .ready(Plan(videoURL: plan.videoURL, subtitleURLs: plan.subtitleURLs, engine: .vlc))
    }

    func release() {
        held.forEach { $0.close() }
        held = []
    }
}
