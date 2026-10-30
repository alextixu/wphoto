import SwiftUI

/// 常用位置清單：選過的資料夾都記在這裡，點一下就開；列右側的「…」、向左滑或長按可以重新命名、移除。
/// 還沒有任何位置時顯示大的空狀態（圖示＋說明＋「選擇資料夾」按鈕），不再是一列藍字加整片黑。
/// App 啟動時不會自動開啟任何位置，NAS 沒連線也不會卡住。
struct LocationsView: View {
    @ObservedObject var session: FolderSession
    let onChooseFolder: () -> Void

    @State private var renaming: FolderSession.SavedFolder?
    @State private var newName = ""
    /// 每次改名成功 +1，觸發一次成功的觸覺回饋
    @State private var renameCount = 0

    var body: some View {
        Group {
            if session.saved.isEmpty {
                emptyState
            } else {
                list
            }
        }
        .wpBackdrop(glow: session.kind == .video)
        .alert("Rename", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } }),
               presenting: renaming) { item in
            TextField("Rename", text: $newName)
                .submitLabel(.done)
            Button("OK") {
                session.renameSaved(item.id, to: newName)
                renameCount += 1
                renaming = nil
            }
            Button("Cancel", role: .cancel) { renaming = nil }
        } message: { item in
            // 顯示完整路徑：同名資料夾（例如多台 NAS 都有「電影」）才分得出是哪一個
            Text(item.path)
        }
        .sensoryFeedback(.success, trigger: renameCount)
    }

    // MARK: - 空狀態

    /// 還沒有常用位置：畫面中央放大圖示、模式說明與「選擇資料夾」大按鈕
    private var emptyState: some View {
        ContentUnavailableView {
            Label {
                Text(session.kind == .photo ? "PlaceholderPhoto" : "PlaceholderVideo")
            } icon: {
                Image(systemName: "folder.badge.plus")
                    .foregroundStyle(Color.wpSecondaryLabel)
            }
        } description: {
            Text("FilesHint")
        } actions: {
            Button("ChooseFolder", action: onChooseFolder)
                .wpPrimaryButton()
                .controlSize(.large)
        }
    }

    // MARK: - 清單

    private var list: some View {
        List {
            Section {
                Button(action: onChooseFolder) {
                    Label("ChooseFolder", systemImage: "folder.badge.plus")
                        .foregroundStyle(Color.wpLabel)
                }
                .listRowBackground(Color.wpCard)
            }

            Section {
                ForEach(session.saved) { item in
                    // 開啟與「…」是兩個獨立的按鈕：一定要 .plain / .borderless，
                    // 否則 List 會把整列的點擊同時轉給所有 Button
                    HStack(spacing: WPTheme.Spacing.s) {
                        Button { session.openSaved(item) } label: {
                            row(item)
                        }
                        .buttonStyle(.plain)
                        LocationActionsMenu(onRename: { startRename(item) },
                                            onRemove: { session.removeSaved(item.id) })
                    }
                    .wpHoverHighlight()
                    .listRowBackground(Color.wpCard)
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) { session.removeSaved(item.id) } label: {
                            Label("RemoveLocation", systemImage: "trash")
                        }
                        Button { startRename(item) } label: {
                            Label("Rename", systemImage: "pencil")
                        }
                        .tint(Color.wpMuted)
                    }
                    .contextMenu {
                        Button { startRename(item) } label: {
                            Label("Rename", systemImage: "pencil")
                        }
                        Button(role: .destructive) { session.removeSaved(item.id) } label: {
                            Label("RemoveLocation", systemImage: "trash")
                        }
                    }
                }
            } header: {
                Text("SavedLocations").wpSectionTitle()
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
    }

    private func row(_ item: FolderSession.SavedFolder) -> some View {
        HStack(spacing: WPTheme.Spacing.m) {
            IconTile(systemName: "folder.fill")
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name)
                    .font(.body)
                    .foregroundStyle(Color.wpLabel)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(detail(item))
                    .font(.caption)
                    .foregroundStyle(Color.wpSecondaryLabel)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
    }

    /// 「上一層資料夾 · 上次開啟時間」
    private func detail(_ item: FolderSession.SavedFolder) -> String {
        let when = item.lastOpened.formatted(.relative(presentation: .named))
        let parent = item.parentName
        return parent.isEmpty || parent == "/" ? when : "\(parent) · \(when)"
    }

    private func startRename(_ item: FolderSession.SavedFolder) {
        newName = item.name
        renaming = item
    }
}

/// 位置列右側的「…」選單：重新命名、移除。
/// 用 Mac 滑鼠或 iPad 游標點它會開選單，而不是把整列當成「開啟」
private struct LocationActionsMenu: View {
    let onRename: () -> Void
    let onRemove: () -> Void

    var body: some View {
        Menu {
            Button(action: onRename) { Label("Rename", systemImage: "pencil") }
            Button(role: .destructive, action: onRemove) { Label("RemoveLocation", systemImage: "trash") }
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.title3)
                .foregroundStyle(Color.wpSecondaryLabel)
                .frame(width: 44, height: 44)   // 44pt 點擊區
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .accessibilityLabel(Text("Actions"))
    }
}

/// 開啟常用位置或掃描資料夾時的等待畫面：可以取消（例如 NAS 沒有回應）
struct FolderProgressView: View {
    let title: String
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            ProgressView()
                .controlSize(.large)
            Text(title)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Button("Cancel", action: onCancel)
                .buttonStyle(.bordered)
        }
    }
}
