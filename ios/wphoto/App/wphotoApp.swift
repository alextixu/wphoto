import SwiftUI
import AVFoundation

@main
struct WphotoApp: App {
    @Environment(\.scenePhase) private var scenePhase

    init() {
        // 靜音開關打開時影片仍有聲音（看劇模式）
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        Self.styleNavigationTitles()
        // 系統的檔案挑選器在另一個行程裡跑，不吃 App 的強調色，只能設它自己 view 的 tintColor。
        // 實測不穩定：同一個版本有時紅有時藍，原因不明，所以只算盡力而為
        UIView.appearance(whenContainedInInstancesOf: [UIDocumentPickerViewController.self]).tintColor = UIColor(Color.wpAccent)
    }

    /// 導覽列標題用襯線字（New York）：標題是整個畫面的門面，像片頭字卡一樣比無襯線體端莊。
    /// SwiftUI 的 navigationTitle 改不了字型，只能走 UIKit appearance
    private static func styleNavigationTitles() {
        let ivory = UIColor(Color.wpLabel)
        func serif(_ style: UIFont.TextStyle) -> UIFont {
            let base = UIFontDescriptor.preferredFontDescriptor(withTextStyle: style)
            let bold = base.withSymbolicTraits(.traitBold) ?? base
            return UIFont(descriptor: bold.withDesign(.serif) ?? bold, size: 0)
        }
        UINavigationBar.appearance().largeTitleTextAttributes = [.font: serif(.largeTitle), .foregroundColor: ivory]
        UINavigationBar.appearance().titleTextAttributes = [.font: serif(.headline), .foregroundColor: ivory]
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
