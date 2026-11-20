import SwiftUI
import AVFoundation

@main
struct WphotoApp: App {
    @Environment(\.scenePhase) private var scenePhase

    init() {
        // 靜音開關打開時影片仍有聲音（看劇模式）
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        Self.styleNavigationTitles()
        Self.tintWindows()
    }

    /// 整個視窗的 tintColor 設成象牙白（和全域 AccentColor 同色），檔案挑選器才不會變成系統藍。
    /// 挑選器（.fileImporter）是「檔案」行程畫的遠端畫面，UIKit 只在它的宿主 view（_UISceneHostingView）
    /// trait 改變時把 tint 送過去，主要是進入視窗的那一刻；之後 tint 再變也不會補送。
    /// 以前用 appearance(whenContainedInInstancesOf: [UIDocumentPickerViewController.self]) 設紅色，
    /// 但 appearance 比那一刻晚才套上：挑選器和遠端畫面一起加進視窗時（服務已經熱身）送出去的是
    /// 預設的 systemBlue，遠端畫面晚一點才接上時才是紅色，所以同一個版本有時紅有時藍。
    /// 視窗的 tint 從一開始就在，任何 view 一進視窗就繼承得到，每次送過去的都是象牙白。
    /// UIWindow.appearance() 套不到 SwiftUI 建的視窗，所以在視窗出現時直接設；
    /// 只設一般層級的視窗（iPad 可以開多個），鍵盤等系統視窗不碰
    private static func tintWindows() {
        let ivory = UIColor(Color.wpLabel)
        NotificationCenter.default.addObserver(forName: UIWindow.didBecomeVisibleNotification,
                                               object: nil, queue: .main) { note in
            MainActor.assumeIsolated {
                guard let window = note.object as? UIWindow, window.windowLevel == .normal else { return }
                window.tintColor = ivory
            }
        }
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
