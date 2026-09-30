import SwiftUI
import AVKit

/// 全螢幕播放（MP4 / M4V / MOV）：AVPlayerViewController 內建進度條、倍速（0.5x–2x）、
/// 字幕／音軌選單、子母畫面與 AirPlay；HDR / Dolby Vision / Atmos 由 iOS 原生處理。
/// AVPlayer 開不了檔（例如不支援的編碼）時呼叫 onFailure，由上層改用 VLC。
struct PlayerScreen: View {
    let url: URL
    var onFailure: () -> Void = {}
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.black.ignoresSafeArea()
            PlayerView(url: url, onFailure: onFailure)
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
    }
}

struct PlayerView: UIViewControllerRepresentable {
    let url: URL
    let onFailure: () -> Void

    final class Coordinator {
        var url: URL?
        var onFailure: (() -> Void)?
        var statusObservation: NSKeyValueObservation?

        func load(_ url: URL, into vc: AVPlayerViewController) {
            self.url = url
            let item = AVPlayerItem(url: url)
            statusObservation = item.observe(\.status, options: [.new]) { [weak self] item, _ in
                guard item.status == .failed else { return }
                DispatchQueue.main.async { self?.onFailure?() }
            }
            vc.player = AVPlayer(playerItem: item)
            vc.player?.play()
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let vc = AVPlayerViewController()
        vc.allowsPictureInPicturePlayback = true
        vc.canStartPictureInPictureAutomaticallyFromInline = true
        context.coordinator.onFailure = onFailure
        context.coordinator.load(url, into: vc)
        return vc
    }

    func updateUIViewController(_ vc: AVPlayerViewController, context: Context) {
        context.coordinator.onFailure = onFailure
        if context.coordinator.url != url {
            context.coordinator.load(url, into: vc)
        }
    }

    static func dismantleUIViewController(_ vc: AVPlayerViewController, coordinator: Coordinator) {
        coordinator.statusObservation = nil
        coordinator.onFailure = nil
        vc.player?.pause()
        vc.player = nil
    }
}
