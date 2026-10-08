import SwiftUI

/// 常用位置清單：選過的資料夾都記在這裡，點一下就開；向左滑或長按可以重新命名、移除。
/// App 啟動時不會自動開啟任何位置，NAS 沒連線也不會卡住。
struct LocationsView: View {
    @ObservedObject var session: FolderSession
    let onChooseFolder: () -> Void

    @State private var renaming: FolderSession.SavedFolder?
    @State private var newName = ""

    var body: some View {
        List {
            Section {
                Button(action: onChooseFolder) {
                    Label("ChooseFolder", systemImage: "folder.badge.plus")
                        .foregroundStyle(Color.wpAccent)
                }
            } footer: {
                Text("FilesHint")
            }

            Section("SavedLocations") {
                if session.saved.isEmpty {
                    Text("NoSavedLocations")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(session.saved) { item in
                        Button { session.openSaved(item) } label: {
                            row(item)
                        }
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) { session.removeSaved(item.id) } label: {
                                Label("RemoveLocation", systemImage: "trash")
                            }
                            Button { startRename(item) } label: {
                                Label("Rename", systemImage: "pencil")
                            }
                            .tint(.orange)
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
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Color.wpBackground)
        .alert("Rename", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Rename", text: $newName)
            Button("OK") {
                if let item = renaming { session.renameSaved(item.id, to: newName) }
                renaming = nil
            }
            Button("Cancel", role: .cancel) { renaming = nil }
        }
    }

    private func row(_ item: FolderSession.SavedFolder) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "folder.fill")
                .font(.title3)
                .foregroundStyle(Color.wpAccent)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(detail(item))
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
