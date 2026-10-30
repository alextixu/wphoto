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

    /// 大標題顯示的 App 名稱：跟 Info.plist 的顯示名稱一致，改名時不用再改這裡
    private static let appName = Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? "wphoto"

    var body: some View {
        let large = sizeClass == .regular
        return NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: WPTheme.Spacing.xl) {
                    modeSection(large: large)

                    // 已經有清單就不必再教怎麼開資料夾：使用者早就會了
                    if recents.isEmpty && continueWatching.isEmpty {
                        Text("FilesHint")
                            .font(.footnote)
                            .foregroundStyle(Color.wpSecondaryLabel)
                            .multilineTextAlignment(.leading)
                    }

                    if !continueWatching.isEmpty {
                        continueSection
                    }
                    if !recents.isEmpty {
                        recentSection
                    }
                }
                .frame(maxWidth: large ? 760 : .infinity)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 20)
                .padding(.top, 8)
                .padding(.bottom, 24)
            }
            .wpBackdrop()
            // 一定用 verbatim：純字串會被當成 LocalizedStringKey 去查表
            .navigationTitle(Text(verbatim: Self.appName))
            .navigationBarTitleDisplayMode(.large)
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
        // 導覽列、選單用象牙白：紅字在深色底上對比不足，紅色只留給播放與主要按鈕
        .tint(.wpLabel)
    }

    // MARK: - 模式卡片

    private func modeSection(large: Bool) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("ChooseMode")
            HStack(spacing: 16) {
                NavigationLink {
                    PhotoModeView()
                } label: {
                    ModeCard(icon: "photo.on.rectangle.angled.fill", title: "PhotoMode", subtitle: "PhotoModeDesc", large: large)
                }
                .buttonStyle(CardPressStyle())
                .wpHoverLift()
                .contentShape(.hoverEffect, RoundedRectangle(cornerRadius: WPTheme.Radius.hero, style: .continuous))
                NavigationLink {
                    TheaterModeView()
                } label: {
                    ModeCard(icon: "film.stack.fill", title: "VideoMode", subtitle: "VideoModeDesc", velvet: true, large: large)
                }
                .buttonStyle(CardPressStyle())
                .wpHoverLift()
                .contentShape(.hoverEffect, RoundedRectangle(cornerRadius: WPTheme.Radius.hero, style: .continuous))
            }
            // 兩張卡並排，字體放到最大會擠不下：上限停在 accessibility2
            .dynamicTypeSize(...DynamicTypeSize.accessibility2)
        }
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
                .buttonStyle(CardPressStyle(scale: 0.98))
                .wpHoverHighlight()
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
                    .buttonStyle(CardPressStyle(scale: 0.98))
                    .wpHoverHighlight()
                    if recent.id != recents.last?.id {
                        // 從文字欄位開始畫：12 邊距 + 36 色塊 + 12 間距
                        Divider()
                            .overlay(Color.wpSeparator)
                            .padding(.leading, 60)
                    }
                }
            }
            .wpCard(radius: WPTheme.Radius.card)
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
            .wpSectionTitle()
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
                .font(.title)
                .foregroundStyle(Color.wpAccent)
            VStack(alignment: .leading, spacing: 4) {
                Text(entry.fileName)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.wpLabel)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(Color.wpSecondaryLabel)
                    .lineLimit(1)
                    .truncationMode(.middle)
                ProgressView(value: entry.fraction)
                    .tint(Color.wpAccent)
            }
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color.wpTertiaryLabel)
                .accessibilityHidden(true)
        }
        .padding(WPTheme.Spacing.m)
        .wpCard(radius: WPTheme.Radius.card)
        .contentShape(Rectangle())
    }

    /// 「位置 › 子資料夾 · 12:34 / 45:00」
    private var detail: String {
        var time = PlaybackTime.string(ms: entry.positionMs)
        if entry.durationMs > 0 { time += " / " + PlaybackTime.string(ms: entry.durationMs) }
        return locationName.isEmpty ? time : "\(locationName) · \(time)"
    }
}

/// 「最近位置」的一列：模式圖示、位置名稱、上一層資料夾與上次開啟時間
private struct RecentRow: View {
    let kind: FolderSession.Kind
    let folder: FolderSession.SavedFolder

    var body: some View {
        HStack(spacing: 12) {
            IconTile(systemName: kind == .photo ? "photo.on.rectangle.angled" : "film.stack")
            VStack(alignment: .leading, spacing: 2) {
                Text(folder.name)
                    .foregroundStyle(Color.wpLabel)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(Color.wpSecondaryLabel)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color.wpTertiaryLabel)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
    }

    /// 「上一層資料夾 · 3 天前」：兩個同名的 Documents 靠上一層分辨；
    /// 位置就在根目錄（沒有上一層）時退回「看劇模式 · 3 天前」
    private var detail: String {
        let parent = folder.parentName
        let when = folder.lastOpened.formatted(.relative(presentation: .named))
        if parent.isEmpty || parent == "/" {
            let mode = String(localized: kind == .photo ? "PhotoMode" : "VideoMode")
            return "\(mode) · \(when)"
        }
        return "\(parent) · \(when)"
    }
}

struct ModeCard: View {
    let icon: String
    let title: LocalizedStringKey
    let subtitle: LocalizedStringKey
    /// 看劇卡用深紅絨布底，是首頁最重的一塊；照片卡維持深色，兩張才有主次
    var velvet = false
    var large = false
    /// 圖示跟著動態字體縮放（以大標題為基準）；iPad 卡片大，再放大 15%
    @ScaledMetric(relativeTo: .largeTitle) private var iconSize: CGFloat = 36

    @ViewBuilder
    var body: some View {
        let content = VStack(alignment: .leading, spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: large ? iconSize * 1.15 : iconSize, weight: .regular))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(Color.wpLabel)
            Spacer(minLength: 12)
            Text(title)
                .font(.title3.weight(.semibold))
                .fontDesign(.serif)
                .foregroundStyle(Color.wpLabel)
            Text(subtitle)
                .font(.footnote)
                // 灰字壓在深紅上對比不足，改用半透明象牙白
                .foregroundStyle(velvet ? Color.wpLabel.opacity(0.75) : Color.wpSecondaryLabel)
                .multilineTextAlignment(.leading)
        }
        .padding(20)
        .frame(maxWidth: .infinity, minHeight: large ? 176 : 140, alignment: .leading)
        if velvet {
            content.wpCard(radius: WPTheme.Radius.hero, fill: WPTheme.velvet, elevated: true)
        } else {
            content.wpCard(radius: WPTheme.Radius.hero, elevated: true)
        }
    }
}
