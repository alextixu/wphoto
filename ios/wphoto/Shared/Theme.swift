import SwiftUI

// 設計 token：顏色、圓角、間距、動畫與共用的外觀 modifier，照片／看劇兩個模式共用。
// 基底三色 wpBackground / wpCard / wpAccent 留在 App/ModeSelectView.swift（同一個 module，
// 這裡直接引用），此檔只宣告「新的」token，避免重複定義。

// MARK: - 顏色

extension Color {
    /// 比 wpCard 再亮一階的表面（surface2）：疊在卡片上的控制項、彈出層
    static let wpSurfaceElevated = Color(red: 44 / 255, green: 44 / 255, blue: 46 / 255)
    /// 列與列之間的分隔線：黑底上用半透明白，深淺卡片都看得到
    static let wpSeparator = Color.white.opacity(0.08)
    /// 卡片邊框：比分隔線略明顯一點，讓材質卡片在純黑底上有邊界
    static let wpStroke = Color.white.opacity(0.10)
    /// 照片模式的主題色 #FF9F0A（系統橘）
    static let wpPhotoTint = Color(red: 255 / 255, green: 159 / 255, blue: 10 / 255)
    /// 看劇模式的主題色 #5E5CE6（系統靛藍）
    static let wpTheaterTint = Color(red: 94 / 255, green: 92 / 255, blue: 230 / 255)
    /// 文字三階層：App 固定深色外觀，不用 .secondary（放在 NavigationLink 裡會被染成強調色）
    static let wpLabel = Color.white
    static let wpSecondaryLabel = Color(white: 0.6)
    static let wpTertiaryLabel = Color(white: 0.45)
}

// MARK: - 尺寸與動畫

enum WPTheme {
    /// 圓角：徽章 < 卡片 < 首頁大卡
    enum Radius {
        static let badge: CGFloat = 6
        static let card: CGFloat = 12
        static let hero: CGFloat = 20
    }

    /// 間距階梯（4 的倍數）
    enum Spacing {
        static let xs: CGFloat = 4
        static let s: CGFloat = 8
        static let m: CGFloat = 12
        static let l: CGFloat = 16
        static let xl: CGFloat = 24
    }

    /// 全頁背景：上淺下深的微漸層，讓材質卡片不會貼在死黑上
    static let backdrop = LinearGradient(
        colors: [Color(white: 0.10), Color(white: 0.02)],
        startPoint: .top, endPoint: .bottom
    )

    /// 按下卡片的回彈
    static let pressSpring = Animation.spring(duration: 0.25, bounce: 0.35)
    /// 縮圖載入完成的淡入
    static let imageFade = Animation.easeOut(duration: 0.25)
    /// 播放器等畫面的控制列顯示／隱藏
    static let chrome = Animation.easeOut(duration: 0.25)
}

// MARK: - 按鈕樣式

/// 卡片類按鈕：按下時略縮、略暗，放開回彈
struct CardPressStyle: ButtonStyle {
    var scale: CGFloat = 0.96

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? scale : 1)
            .brightness(configuration.isPressed ? -0.06 : 0)
            .animation(WPTheme.pressSpring, value: configuration.isPressed)
    }
}

// MARK: - 卡片表面

/// 卡片的材質表面：iOS 26 用系統 Liquid Glass，更早的系統用材質 + 漸層 + 邊框 + 陰影模擬。
/// CI 是 Xcode 16.4（Swift 6.1），glassEffect 只在 Xcode 26+ 的 SDK 才有，
/// 所以用 `#if compiler(>=6.2)` 讓那段只在新 Xcode 編譯；執行期再用 #available 分流。
struct CardSurface: ViewModifier {
    var radius: CGFloat
    var tint: Color?
    var elevated: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        #if compiler(>=6.2)
        if #available(iOS 26, *) {
            content.glassEffect(tint.map { Glass.regular.tint($0.opacity(0.35)) } ?? .regular, in: shape)
        } else {
            classic(content, shape)
        }
        #else
        classic(content, shape)
        #endif
    }

    /// iOS 17–18 的外觀：regularMaterial 底 + 主題色斜向漸層 + 細邊框 + 陰影
    private func classic(_ content: Content, _ shape: RoundedRectangle) -> some View {
        content
            .background {
                ZStack {
                    shape.fill(.regularMaterial)
                    if let tint {
                        shape.fill(LinearGradient(
                            colors: [tint.opacity(0.35), tint.opacity(0.06)],
                            startPoint: .topLeading, endPoint: .bottomTrailing
                        ))
                    }
                }
            }
            .overlay(shape.strokeBorder(Color.wpStroke, lineWidth: 1))
            .clipShape(shape)
            .shadow(color: .black.opacity(elevated ? 0.45 : 0.35),
                    radius: elevated ? 16 : 8,
                    y: elevated ? 8 : 4)
    }
}

// MARK: - View 便利方法

extension View {
    /// 套上卡片表面（見 CardSurface）
    func wpCard(radius: CGFloat = WPTheme.Radius.card, tint: Color? = nil, elevated: Bool = false) -> some View {
        modifier(CardSurface(radius: radius, tint: tint, elevated: elevated))
    }

    /// iPad 游標：卡片浮起
    func wpHoverLift() -> some View {
        hoverEffect(.lift)
    }

    /// iPad 游標：控制項反白
    func wpHoverHighlight() -> some View {
        hoverEffect(.highlight)
    }

    /// 全頁背景漸層（延伸到安全區外）
    func wpBackdrop() -> some View {
        background {
            Rectangle()
                .fill(WPTheme.backdrop)
                .ignoresSafeArea()
        }
    }

    /// 縮圖角落的小徽章（時長、張數…）：等寬數字、膠囊材質底。
    /// 固定深色外觀，疊在亮色照片上材質也不會變白
    func wpBadge() -> some View {
        font(.caption2.weight(.semibold))
            .monospacedDigit()
            .foregroundStyle(.white)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(.ultraThinMaterial, in: Capsule())
            .environment(\.colorScheme, .dark)
    }
}

// MARK: - 控制列按鈕

/// 播放器／檢視器疊在內容上的圓形按鈕（關閉、設定…）：44pt 點擊區、材質底
struct ChromeButton: View {
    let systemImage: String
    let label: LocalizedStringKey
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.headline.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .background(.ultraThinMaterial, in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .hoverEffect(.highlight)
        .accessibilityLabel(Text(label))
    }
}
