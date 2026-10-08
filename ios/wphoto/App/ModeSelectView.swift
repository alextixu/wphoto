import SwiftUI

/// 啟動畫面：選擇照片模式或看劇模式（與 Windows 版一致）
struct ModeSelectView: View {
    /// iPad（全螢幕或較寬的分割畫面）為 .regular：卡片放大、整體限制寬度並置中
    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        let large = sizeClass == .regular
        return NavigationStack {
            ZStack {
                Color.wpBackground.ignoresSafeArea()
                VStack(spacing: 28) {
                    VStack(spacing: 6) {
                        Text("wphoto")
                            .font(.system(size: 38, weight: .bold))
                        Text("ChooseMode")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    HStack(spacing: 16) {
                        NavigationLink {
                            PhotoModeView()
                        } label: {
                            ModeCard(icon: "photo.on.rectangle.angled", title: "PhotoMode", subtitle: "PhotoModeDesc", large: large)
                        }
                        NavigationLink {
                            TheaterModeView()
                        } label: {
                            ModeCard(icon: "film.stack", title: "VideoMode", subtitle: "VideoModeDesc", large: large)
                        }
                    }
                    .frame(maxWidth: large ? 680 : .infinity)
                    .padding(.horizontal, 20)
                    Text("FilesHint")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                }
            }
            .toolbar(.hidden, for: .navigationBar)
        }
        .tint(.wpAccent)
    }
}

struct ModeCard: View {
    let icon: String
    let title: LocalizedStringKey
    let subtitle: LocalizedStringKey
    var large = false

    var body: some View {
        VStack(spacing: large ? 16 : 12) {
            Image(systemName: icon)
                .font(.system(size: large ? 60 : 44, weight: .regular))
                .foregroundStyle(Color.wpAccent)
            Text(title)
                .font(large ? .title3.weight(.semibold) : .headline)
                .foregroundStyle(.white)
            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .frame(height: large ? 240 : 180)
        .background(Color.wpCard)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

extension Color {
    /// 與 Windows 版相同的純黑底配色
    static let wpBackground = Color(red: 10 / 255, green: 10 / 255, blue: 10 / 255)
    static let wpCard = Color(red: 28 / 255, green: 28 / 255, blue: 30 / 255)
    static let wpAccent = Color(red: 10 / 255, green: 132 / 255, blue: 255 / 255)
}
