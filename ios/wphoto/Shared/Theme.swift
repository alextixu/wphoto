import SwiftUI

// 設計 token：顏色、圓角、間距、動畫與共用的外觀 modifier，照片／看劇兩個模式共用。
//
// 配色概念是「熄燈後的放映廳」：畫面裡唯一的彩色是座椅與布幕的絨布紅，其餘都是暖黑與象牙白，
// 讓海報、照片本身成為最亮的東西。紅色對深色底的對比只有 3.3:1，夠當圖示與填色、不夠當小字，
// 所以文字一律用象牙白系列；紅色只留給「播放、進度、主要動作」，用得少才顯得貴。

// MARK: - 顏色

private extension Color {
    init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255)
    }
}

extension Color {
    /// 全頁底色：帶一點暖意的黑，不用死黑
    static let wpBackground = Color(hex: 0x0E0B0A)
    /// 卡片表面
    static let wpCard = Color(hex: 0x1C1716)
    /// 比 wpCard 再亮一階的表面（surface2）：疊在卡片上的控制項、圖示底塊
    static let wpSurfaceElevated = Color(hex: 0x2A2322)
    /// 絨布紅：全 App 唯一的彩色，白字壓在上面的對比是 5.3:1
    static let wpAccent = Color(hex: 0xC8313A)
    /// 深絨布紅：大面積用（首頁看劇卡），比 wpAccent 暗才不會刺眼
    static let wpVelvet = Color(hex: 0x5C121C)
    static let wpVelvetDeep = Color(hex: 0x2E0A10)
    /// 次要動作的底色（清單滑動的重新命名）：白字對比夠、又不搶紅色的焦點
    static let wpMuted = Color(hex: 0x5A504A)
    /// 文字三階層：App 固定深色外觀，不用 .secondary（放在 NavigationLink 裡會被染成強調色）
    static let wpLabel = Color(hex: 0xF2ECE4)
    static let wpSecondaryLabel = Color(hex: 0xA89F97)
    static let wpTertiaryLabel = Color(hex: 0x8A8079)
    /// 列與列之間的分隔線
    static let wpSeparator = Color.wpLabel.opacity(0.08)
    /// 卡片邊框：比分隔線略明顯一點，讓霧面卡片在暗底上有邊界
    static let wpStroke = Color.wpLabel.opacity(0.10)
}

// MARK: - 尺寸與動畫

enum WPTheme {
    /// 圓角偏小：大圓角顯得活潑，端莊的畫面要收斂
    enum Radius {
        static let badge: CGFloat = 4
        /// 海報、影片畫面：像真的片框，幾乎是直角
        static let poster: CGFloat = 4
        /// 按鈕、圖示底塊
        static let control: CGFloat = 8
        static let card: CGFloat = 10
        static let hero: CGFloat = 14
    }

    /// 間距階梯（4 的倍數）
    enum Spacing {
        static let xs: CGFloat = 4
        static let s: CGFloat = 8
        static let m: CGFloat = 12
        static let l: CGFloat = 16
        static let xl: CGFloat = 24
    }

    /// 全頁背景：上淺下深的微漸層，讓卡片不會貼在死黑上
    static let backdrop = LinearGradient(
        colors: [Color(hex: 0x171211), Color(hex: 0x0A0807)],
        startPoint: .top, endPoint: .bottom
    )

    /// 深紅絨布的表面（首頁看劇卡）
    static let velvet = LinearGradient(
        colors: [Color.wpVelvet, Color.wpVelvetDeep],
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

/// 卡片的霧面表面：實色底 + 細邊框 + 陰影。
/// 不用材質或 Liquid Glass：玻璃會反映背後的內容、邊緣帶高光，放映廳要的是絨布般吸光的質感
struct CardSurface<Fill: ShapeStyle>: ViewModifier {
    var radius: CGFloat
    var fill: Fill
    var elevated: Bool

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        content
            .background(fill, in: shape)
            .overlay(shape.strokeBorder(Color.wpStroke, lineWidth: 1))
            .clipShape(shape)
            .shadow(color: .black.opacity(elevated ? 0.5 : 0.35),
                    radius: elevated ? 16 : 8,
                    y: elevated ? 8 : 4)
    }
}

/// 全頁背景。glow：畫面上方一抹很淡的紅光，像布幕映出來的；照片模式不開，避免影響看照片的色偏判斷
struct CinemaBackdrop: View {
    var glow = true

    var body: some View {
        ZStack {
            Rectangle().fill(WPTheme.backdrop)
            if glow {
                RadialGradient(colors: [Color.wpVelvet.opacity(0.32), .clear],
                               center: .top, startRadius: 0, endRadius: 560)
            }
        }
        .ignoresSafeArea()
    }
}

/// 清單列左側的圖示底塊：不分模式都是同一個安靜的深色塊，不靠顏色區分，靠圖形
struct IconTile: View {
    let systemName: String

    var body: some View {
        RoundedRectangle(cornerRadius: WPTheme.Radius.control, style: .continuous)
            .fill(Color.wpSurfaceElevated)
            .frame(width: 36, height: 36)
            .overlay {
                Image(systemName: systemName)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Color.wpLabel)
            }
            .accessibilityHidden(true)
    }
}

// MARK: - View 便利方法

extension View {
    /// 套上卡片表面（見 CardSurface）
    func wpCard(radius: CGFloat = WPTheme.Radius.card, elevated: Bool = false) -> some View {
        modifier(CardSurface(radius: radius, fill: Color.wpCard, elevated: elevated))
    }

    /// 同上，但底色自訂（漸層也可以）
    func wpCard(radius: CGFloat = WPTheme.Radius.card, fill: some ShapeStyle, elevated: Bool = false) -> some View {
        modifier(CardSurface(radius: radius, fill: fill, elevated: elevated))
    }

    /// 分區標題：小字、寬字距，像片尾字幕，比粗體大字沉穩
    func wpSectionTitle() -> some View {
        font(.footnote.weight(.semibold))
            .tracking(2)
            .textCase(.uppercase)
            .foregroundStyle(Color.wpSecondaryLabel)
    }

    /// 主要動作按鈕：全 App 唯一的紅色按鈕
    func wpPrimaryButton() -> some View {
        buttonStyle(.borderedProminent)
            .buttonBorderShape(.roundedRectangle(radius: WPTheme.Radius.control))
            .tint(Color.wpAccent)
    }

    /// 次要按鈕：壓在深色底上的象牙白
    func wpSecondaryButton() -> some View {
        buttonStyle(.bordered)
            .buttonBorderShape(.roundedRectangle(radius: WPTheme.Radius.control))
            .tint(Color.wpLabel)
    }

    /// iPad 游標：卡片浮起
    func wpHoverLift() -> some View {
        hoverEffect(.lift)
    }

    /// iPad 游標：控制項反白
    func wpHoverHighlight() -> some View {
        hoverEffect(.highlight)
    }

    /// 全頁背景（延伸到安全區外）
    func wpBackdrop(glow: Bool = true) -> some View {
        background { CinemaBackdrop(glow: glow) }
    }

    /// 縮圖角落的小徽章（時長、張數…）：等寬數字、材質底。
    /// 固定深色外觀，疊在亮色照片上材質也不會變白
    func wpBadge() -> some View {
        font(.caption2.weight(.semibold))
            .monospacedDigit()
            .foregroundStyle(.white)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: WPTheme.Radius.badge, style: .continuous))
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
