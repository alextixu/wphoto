import SwiftUI

/// 啟動畫面：選擇照片模式或看劇模式（與 Windows 版一致）。
/// 模式卡片下方列出「繼續觀看」與「最近位置」：都是點了才開，啟動時不會自動連 NAS。
struct ModeSelectView: View {
    /// iPad（全螢幕或較寬的分割畫面）為 .regular：卡片放大、整體限制寬度並置中
    @Environment(\.horizontalSizeClass) private var sizeClass
    @ObservedObject private var progress = WatchProgressStore.shared
    /// 照片、看劇兩個模式最近開過的位置（每次回到首頁重新讀）
    @State private var recents: [RecentLocation] = []
    @State private var destination: HomeDestination?

    /// 首頁點進去的畫面
    private enum HomeDestination: Hashable {
        case photo(FolderSession.SavedFolder)
        case video(TheaterLaunch)
    }

    private struct RecentLocation: Identifiable {
        let kind: FolderSession.Kind
        let folder: FolderSession.SavedFolder
        var id: String { "\(kind.rawValue)-\(folder.id)" }
    }

    /// 首頁最多列幾筆
    private static let maxContinue = 5
    private static let maxRecents = 6

    var body: some View {
        let large = sizeClass == .regular
        return NavigationStack {
            GeometryReader { geo in
                ScrollView {
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
                        Text("FilesHint")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 12)

                        if !continueWatching.isEmpty {
                            continueSection
                        }
                        if !recents.isEmpty {
                            recentSection
                        }
                    }
                    .frame(maxWidth: large ? 680 : .infinity)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 24)
                    // 沒有清單時維持原本的置中版面
                    .frame(maxWidth: .infinity, minHeight: geo.size.height)
                }
            }
            .background(Color.wpBackground.ignoresSafeArea())
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(item: $destination) { destination in
                switch destination {
                case .photo(let folder):
                    PhotoModeView(initialLocation: folder)
                case .video(let launch):
                    TheaterModeView(launch: launch)
                }
            }
            .onAppear { loadRecents() }
        }
        .tint(.wpAccent)
    }

    // MARK: - 繼續觀看

    /// 還沒看完、而且知道是從哪個位置開的影片
    private var continueWatching: [WatchProgressStore.Entry] {
        Array(progress.continueWatching.filter { $0.origin != nil }.prefix(Self.maxContinue))
    }

    private var continueSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("ContinueWatching")
            ForEach(continueWatching) { entry in
                Button {
                    destination = .video(.resume(entry))
                } label: {
                    ContinueRow(entry: entry, locationName: locationName(for: entry))
                }
                .buttonStyle(.plain)
                .contextMenu {
                    Button(role: .destructive) {
                        progress.removeFromContinueWatching(entry.path)
                    } label: {
                        Label("RemoveFromContinueWatching", systemImage: "xmark.circle")
                    }
                }
            }
        }
    }

    /// 影片所在常用位置的名稱（使用者改過名就用改過的）
    private func locationName(for entry: WatchProgressStore.Entry) -> String {
        guard let path = entry.origin?.locationPath else { return "" }
        let saved = FolderSession.savedFolders(kind: .video).first { $0.path == path }
        let name = saved?.name ?? URL(fileURLWithPath: path).lastPathComponent
        let subfolders = entry.origin?.subfolders ?? []
        return ([name] + subfolders).joined(separator: " › ")
    }

    // MARK: - 最近位置

    private var recentSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("RecentLocations")
            VStack(spacing: 0) {
                ForEach(recents) { recent in
                    Button {
                        switch recent.kind {
                        case .photo: destination = .photo(recent.folder)
                        case .video: destination = .video(.location(recent.folder))
                        }
                    } label: {
                        RecentRow(kind: recent.kind, folder: recent.folder)
                    }
                    .buttonStyle(.plain)
                    if recent.id != recents.last?.id {
                        Divider().padding(.leading, 52)
                    }
                }
            }
            .background(Color.wpCard)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
    }

    /// 只讀常用位置清單（UserDefaults），不開任何資料夾
    private func loadRecents() {
        let photo = FolderSession.savedFolders(kind: .photo).map { RecentLocation(kind: .photo, folder: $0) }
        let video = FolderSession.savedFolders(kind: .video).map { RecentLocation(kind: .video, folder: $0) }
        recents = Array((photo + video).sorted { $0.folder.lastOpened > $1.folder.lastOpened }.prefix(Self.maxRecents))
    }

    private func sectionTitle(_ key: LocalizedStringKey) -> some View {
        Text(key)
            .font(.headline)
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// 「繼續觀看」的一列：片名、所在位置、看到哪裡、進度條
private struct ContinueRow: View {
    let entry: WatchProgressStore.Entry
    let locationName: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "play.circle.fill")
                .font(.system(size: 30))
                .foregroundStyle(Color.wpAccent)
            VStack(alignment: .leading, spacing: 4) {
                Text(entry.fileName)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(Color(white: 0.6))
                    .lineLimit(1)
                    .truncationMode(.middle)
                ProgressView(value: entry.fraction)
                    .tint(Color.wpAccent)
            }
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color(white: 0.45))
        }
        .padding(12)
        .background(Color.wpCard)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .contentShape(Rectangle())
    }

    /// 「位置 › 子資料夾 · 12:34 / 45:00」
    private var detail: String {
        var time = PlaybackTime.string(ms: entry.positionMs)
        if entry.durationMs > 0 { time += " / " + PlaybackTime.string(ms: entry.durationMs) }
        return locationName.isEmpty ? time : "\(locationName) · \(time)"
    }
}

/// 「最近位置」的一列：模式圖示、位置名稱、模式與上次開啟時間
private struct RecentRow: View {
    let kind: FolderSession.Kind
    let folder: FolderSession.SavedFolder

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: kind == .photo ? "photo.on.rectangle.angled" : "film.stack")
                .font(.title3)
                .foregroundStyle(Color.wpAccent)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(folder.name)
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(Color(white: 0.6))
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color(white: 0.45))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
    }

    /// 「看劇模式 · 3 天前」
    private var detail: String {
        let mode = String(localized: kind == .photo ? "PhotoMode" : "VideoMode")
        return "\(mode) · \(folder.lastOpened.formatted(.relative(presentation: .named)))"
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
                // 不用 .secondary：放在 NavigationLink 裡會被染成強調色（藍色）
                .foregroundStyle(Color(white: 0.6))
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
