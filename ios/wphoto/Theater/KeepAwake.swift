import SwiftUI

/// 影片播放與準備期間不讓螢幕自動關閉、系統自動睡眠（蓋上筆電、手動鎖定仍會睡）
/// - iPhone／iPad：isIdleTimerDisabled
/// - Mac（Designed for iPad）：isIdleTimerDisabled 沒有作用（用 pmset 實測不會產生電源 assertion），
///   要改用 ProcessInfo 的 activity
/// AVPlayer 播放時系統會自己處理（含子母畫面、AirPlay），這裡只補它管不到的：VLC 播放、播放前的準備與下載。
@MainActor
private enum KeepAwake {
    /// 準備階段交棒給 VLC 畫面時兩邊會同時持有，數到 0 才真的放開
    private static var holders = 0
    private static var activity: NSObjectProtocol?

    static func hold() {
        holders += 1
        guard holders == 1 else { return }
        if ProcessInfo.processInfo.isiOSAppOnMac {
            activity = ProcessInfo.processInfo.beginActivity(
                options: [.idleDisplaySleepDisabled, .idleSystemSleepDisabled],
                reason: "wphoto playback")
        } else {
            UIApplication.shared.isIdleTimerDisabled = true
        }
    }

    static func release() {
        holders -= 1
        guard holders == 0 else { return }
        if let activity {
            ProcessInfo.processInfo.endActivity(activity)
            self.activity = nil
        }
        UIApplication.shared.isIdleTimerDisabled = false
    }
}

private struct KeepAwakeModifier: ViewModifier {
    let active: Bool
    /// 這個畫面目前有沒有持有，避免重複計數
    @State private var holding = false

    func body(content: Content) -> some View {
        content
            .task(id: active) {
                guard !Task.isCancelled else { return }
                if active {
                    setHolding(true)
                } else {
                    // 晚幾秒才放開：VLC 的 isPlaying 是即時讀 libvlc，緩衝時不保證維持 true，
                    // 階段交棒也有空檔；Mac 上閒置已超過時限時，一放開螢幕就會關掉
                    try? await Task.sleep(for: .seconds(3))
                    if !Task.isCancelled { setHolding(false) }
                }
            }
            .onDisappear { setHolding(false) }
    }

    private func setHolding(_ on: Bool) {
        guard on != holding else { return }
        holding = on
        if on { KeepAwake.hold() } else { KeepAwake.release() }
    }
}

extension View {
    /// active 為 true 時不讓螢幕自動關閉；變 false 或畫面關閉時還原
    func keepsScreenAwake(_ active: Bool) -> some View {
        modifier(KeepAwakeModifier(active: active))
    }
}
