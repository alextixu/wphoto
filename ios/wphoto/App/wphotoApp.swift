import SwiftUI
import AVFoundation

@main
struct WphotoApp: App {
    @Environment(\.scenePhase) private var scenePhase

    init() {
        // 靜音開關打開時影片仍有聲音（看劇模式）
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
    }

    var body: some Scene {
        WindowGroup {
            ModeSelectView()
                .preferredColorScheme(.dark)
        }
        .onChange(of: scenePhase) { _, phase in
            // 進背景前把看劇進度立刻寫入（平常是延遲 1 秒批次寫入）
            if phase == .background || phase == .inactive {
                WatchProgressStore.shared.flush()
            }
        }
    }
}
