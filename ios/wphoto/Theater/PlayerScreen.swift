import SwiftUI
import AVKit

/// 播放畫面回報看到哪裡（毫秒）：定時一次、關閉時一次
typealias ProgressReporter = @MainActor (_ positionMs: Int, _ durationMs: Int) -> Void

/// 全螢幕播放（MP4 / M4V / MOV）：AVPlayerViewController 內建進度條、倍速（0.5x–2x）、
/// 字幕／音軌選單、子母畫面與 AirPlay；HDR / Dolby Vision / Atmos 由 iOS 原生處理。
/// AVPlayer 開不了檔（例如不支援的編碼）時呼叫 onFailure，由上層改用 VLC。
/// 有續播位置時從那裡開始，並提示「從頭播放」。
struct PlayerScreen: View {
    let url: URL
    var resumeMs: Int? = nil
    var onProgress: ProgressReporter = { _, _ in }
    var onFailure: () -> Void = {}
    @Environment(\.dismiss) private var dismiss
    @State private var startOverRequest = 0
    @State private var showResume = false

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.black.ignoresSafeArea()
            PlayerView(url: url, resumeMs: resumeMs, startOverRequest: startOverRequest,
                       onProgress: onProgress, onFailure: onFailure)
                .ignoresSafeArea()
            Button { dismiss() } label: {
                Image(systemName: "chevron.down")
                    .font(.headline)
                    .padding(10)
                    .background(.ultraThinMaterial, in: Circle())
            }
            .accessibilityLabel(Text("Close"))
            .padding(.leading, 16)
            .padding(.top, 8)
        }
        .overlay(alignment: .top) {
            if showResume, let resumeMs {
                ResumeBanner(positionMs: resumeMs) {
                    startOverRequest += 1
                    withAnimation { showResume = false }
                }
                .padding(.top, 60)
                .transition(.opacity)
            }
        }
        .task {
            guard resumeMs != nil else { return }
            showResume = true
            try? await Task.sleep(for: .seconds(6))
            withAnimation { showResume = false }
        }
    }
}

struct PlayerView: UIViewControllerRepresentable {
    let url: URL
    let resumeMs: Int?
    let startOverRequest: Int
    let onProgress: ProgressReporter
    let onFailure: () -> Void

    final class Coordinator {
        var url: URL?
        var onFailure: (() -> Void)?
        var onProgress: ProgressReporter?
        var statusObservation: NSKeyValueObservation?
        var startOverRequest = 0
        private var player: AVPlayer?
        private var timeObserver: Any?
        /// 等播放項目可以播了才跳到續播位置，跳完再開始播
        private var pendingResumeMs: Int?

        func load(_ url: URL, resumeMs: Int?, into vc: AVPlayerViewController) {
            removeTimeObserver()
            self.url = url
            if let resumeMs, resumeMs > 0 { pendingResumeMs = resumeMs } else { pendingResumeMs = nil }
            let item = AVPlayerItem(url: url)
            let player = AVPlayer(playerItem: item)
            statusObservation = item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
                DispatchQueue.main.async { self?.statusChanged(item) }
            }
            vc.player = player
            self.player = player
            timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 5, preferredTimescale: 1),
                                                          queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.reportProgress() }
            }
            if pendingResumeMs == nil { player.play() }
        }

        private func statusChanged(_ item: AVPlayerItem) {
            switch item.status {
            case .failed:
                onFailure?()
            case .readyToPlay:
                guard let ms = pendingResumeMs, let player else { return }
                pendingResumeMs = nil
                player.seek(to: CMTime(value: CMTimeValue(ms), timescale: 1000),
                            toleranceBefore: .zero, toleranceAfter: .zero) { [weak player] _ in
                    DispatchQueue.main.async { player?.play() }
                }
            default:
                break
            }
        }

        /// 續播提示的「從頭播放」
        func startOver() {
            pendingResumeMs = nil
            player?.seek(to: .zero)
            player?.play()
        }

        @MainActor func reportProgress() {
            guard let player, let item = player.currentItem, item.status == .readyToPlay else { return }
            let position = player.currentTime().seconds
            guard position.isFinite else { return }
            let duration = item.duration.seconds
            onProgress?(Int(position * 1000), duration.isFinite ? Int(duration * 1000) : 0)
        }

        private func removeTimeObserver() {
            if let timeObserver { player?.removeTimeObserver(timeObserver) }
            timeObserver = nil
        }

        /// 關閉畫面時：先記下最後的位置，再放掉播放器
        @MainActor func tearDown() {
            reportProgress()
            removeTimeObserver()
            statusObservation = nil
            onFailure = nil
            onProgress = nil
            player?.pause()
            player = nil
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let vc = AVPlayerViewController()
        vc.allowsPictureInPicturePlayback = true
        vc.canStartPictureInPictureAutomaticallyFromInline = true
        context.coordinator.onFailure = onFailure
        context.coordinator.onProgress = onProgress
        context.coordinator.startOverRequest = startOverRequest
        context.coordinator.load(url, resumeMs: resumeMs, into: vc)
        return vc
    }

    func updateUIViewController(_ vc: AVPlayerViewController, context: Context) {
        let coordinator = context.coordinator
        coordinator.onFailure = onFailure
        coordinator.onProgress = onProgress
        if coordinator.url != url {
            coordinator.load(url, resumeMs: resumeMs, into: vc)
        }
        if coordinator.startOverRequest != startOverRequest {
            coordinator.startOverRequest = startOverRequest
            coordinator.startOver()
        }
    }

    static func dismantleUIViewController(_ vc: AVPlayerViewController, coordinator: Coordinator) {
        coordinator.tearDown()
        vc.player = nil
    }
}

/// 續播提示：「從 12:34 繼續播放」＋「從頭播放」，幾秒後自動消失（AVPlayer、VLC 共用）
struct ResumeBanner: View {
    let positionMs: Int
    let onStartOver: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "clock.arrow.circlepath")
            Text(String(format: String(localized: "ResumedFrom"), PlaybackTime.string(ms: positionMs)))
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
            Button("StartOver", action: onStartOver)
                .font(.subheadline.weight(.semibold))
                .buttonStyle(.bordered)
                .tint(.white)
        }
        .foregroundStyle(.white)
        .padding(.leading, 14)
        .padding(.trailing, 8)
        .padding(.vertical, 8)
        .background(.black.opacity(0.75), in: Capsule())
    }
}
