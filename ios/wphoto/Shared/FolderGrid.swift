import SwiftUI

/// 目前這一層的子資料夾：點一下進去（照片模式、看劇模式共用）
struct FolderGrid: View {
    let folders: [FolderSession.SubFolder]
    var large = false
    let onOpen: (FolderSession.SubFolder) -> Void

    var body: some View {
        let spacing: CGFloat = large ? 14 : 10
        LazyVGrid(columns: [GridItem(.adaptive(minimum: large ? 240 : 160), spacing: spacing)], spacing: spacing) {
            ForEach(folders) { folder in
                Button { onOpen(folder) } label: {
                    FolderTile(name: folder.name, large: large)
                }
                .buttonStyle(.plain)
            }
        }
    }
}

struct FolderTile: View {
    let name: String
    var large = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "folder.fill")
                .font(large ? .title2 : .title3)
                .foregroundStyle(Color.wpAccent)
            Text(name)
                .font(large ? .body.weight(.medium) : .subheadline.weight(.medium))
                .foregroundStyle(.white)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color(white: 0.45))
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, minHeight: large ? 64 : 56, alignment: .leading)
        .background(Color.wpCard)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .contentShape(Rectangle())
    }
}

/// 在子資料夾裡時，左上角的返回鍵改成「回上一層」（顯示上一層的名稱）；
/// 回到開啟的位置本身時，才恢復系統返回鍵（回模式選擇）
struct FolderBackButton: ViewModifier {
    @ObservedObject var session: FolderSession

    func body(content: Content) -> some View {
        content
            .navigationBarBackButtonHidden(session.canGoUp)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if session.canGoUp {
                        Button { session.goUp() } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "chevron.left")
                                    .fontWeight(.semibold)
                                Text(session.parentDisplayName)
                                    .lineLimit(1)
                                    .frame(maxWidth: 160, alignment: .leading)
                            }
                        }
                        .accessibilityLabel(Text("UpOneLevel"))
                        // 鍵盤（iPad／Mac）：⌘↑ 回上一層，與 Finder 相同
                        .keyboardShortcut(.upArrow, modifiers: .command)
                    }
                }
            }
    }
}
