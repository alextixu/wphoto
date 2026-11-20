import SwiftUI
import UIKit
import UniformTypeIdentifiers

// Mac（Designed for iPad）專屬：選單列命令、開資料夾、視窗最小尺寸。
// iPhone／iPad 不會建立任何選單項目，原本畫面裡的快捷鍵照舊。
//
// 畫面裡用隱形按鈕掛的 .keyboardShortcut 不會出現在 Mac 選單列，所以 Mac 上改由這裡的選單項目負責：
// 各畫面出現時把「自己能做的事」登記到 MacMenu，選單依目前登記的內容啟用或停用。
// 同一個按鍵（←／→）在照片與播放器各有意思，只把快捷鍵掛在目前有效的那一組，選單列裡不會重複。

enum MacSupport {
    /// iPad App 跑在 Apple 晶片 Mac 上
    static let isMac = ProcessInfo.processInfo.isiOSAppOnMac

    /// 視窗最小尺寸（iPad 座標，Mac 上顯示為 77%，約 693×493 點）：
    /// 照片檢視開著 320pt 拍攝資訊欄時照片區仍有一半以上，海報牆維持兩欄，播放器控制列不擠
    static let minimumWindowSize = CGSize(width: 900, height: 640)
}

/// 目前畫面登記的命令。每個畫面用自己的 owner 登記，消失時只清掉自己那一筆，
/// 換畫面時新畫面先登記、舊畫面後消失也不會把新的蓋掉
@MainActor
final class MacMenu: ObservableObject {
    static let shared = MacMenu()

    /// 資料夾瀏覽（照片模式、看劇模式的位置清單與資料夾內）
    struct Folder {
        var canGoUp: Bool
        var open: () -> Void
        var goUp: () -> Void
    }

    /// 照片檢視
    struct Photo {
        var showsInfo: Bool
        var previous: () -> Void
        var next: () -> Void
        var toggleInfo: () -> Void
    }

    /// VLC 播放器（AVPlayer 的鍵盤由 AVKit 自己處理）
    struct Player {
        var isPlaying: Bool
        var isFill: Bool
        var togglePlay: () -> Void
        var back: () -> Void
        var forward: () -> Void
        var toggleFill: () -> Void
    }

    @Published private(set) var folder: Folder?
    @Published private(set) var photo: Photo?
    @Published private(set) var player: Player?
    private var folderOwner: UUID?
    private var photoOwner: UUID?
    private var playerOwner: UUID?

    func setFolder(_ value: Folder?, owner: UUID) {
        if value == nil, folderOwner != owner { return }
        folder = value
        folderOwner = value == nil ? nil : owner
    }

    func setPhoto(_ value: Photo?, owner: UUID) {
        if value == nil, photoOwner != owner { return }
        photo = value
        photoOwner = value == nil ? nil : owner
    }

    func setPlayer(_ value: Player?, owner: UUID) {
        if value == nil, playerOwner != owner { return }
        player = value
        playerOwner = value == nil ? nil : owner
    }

    /// 照片檢視或播放器蓋在資料夾畫面上時，開資料夾、上一層要停用
    var folderCovered: Bool { photo != nil || player != nil }
}

// MARK: - 選單列

struct MacMenuCommands: Commands {
    @ObservedObject private var menu = MacMenu.shared

    var body: some Commands {
        // 檔案：開資料夾、上一層（與 Finder 相同的 ⌘↑）
        CommandGroup(after: .newItem) {
            Section {
                // AVPlayer 的播放畫面不會登記（PlayerScreen 由 AVKit 處理鍵盤），選單沒辦法事先停用，按下時再擋
                Button("MenuOpenFolder") { if !MacFolderPicker.isCovered { menu.folder?.open() } }
                    .keyboardShortcut("o")
                    .disabled(menu.folder == nil || menu.folderCovered)
                Button("UpOneLevel") { if !MacFolderPicker.isCovered { menu.folder?.goUp() } }
                    .keyboardShortcut(.upArrow, modifiers: .command)
                    .disabled(menu.folder?.canGoUp != true || menu.folderCovered)
            }
        }

        // 顯示方式：照片上一張／下一張、拍攝資訊（系統的「進入全螢幕」也在這個選單）。
        // 包成 Section：直接放的話系統會一項一項插在「工具列」前面，順序整個倒過來
        CommandGroup(before: .toolbar) {
            let photo = menu.photo
            Section {
                Button("Back") { photo?.previous() }
                    .keyboardShortcut(photo == nil ? nil : KeyboardShortcut(.leftArrow, modifiers: []))
                    .disabled(photo == nil)
                Button("Next") { photo?.next() }
                    .keyboardShortcut(photo == nil ? nil : KeyboardShortcut(.rightArrow, modifiers: []))
                    .disabled(photo == nil)
                Button(LocalizedStringKey(photo?.showsInfo == true ? "MenuHideInfo" : "MenuShowInfo")) { photo?.toggleInfo() }
                    .keyboardShortcut("i")
                    .disabled(photo == nil)
            }
        }

        // 播放：空白鍵播放／暫停、←／→ 倒退／快轉 10 秒
        CommandMenu("MenuPlayback") {
            let player = menu.player
            Button(LocalizedStringKey(player?.isPlaying == true ? "Pause" : "Play")) { player?.togglePlay() }
                .keyboardShortcut(player == nil ? nil : KeyboardShortcut(.space, modifiers: []))
                .disabled(player == nil)
            Button("Back10") { player?.back() }
                .keyboardShortcut(player == nil ? nil : KeyboardShortcut(.leftArrow, modifiers: []))
                .disabled(player == nil)
            Button("Forward10") { player?.forward() }
                .keyboardShortcut(player == nil ? nil : KeyboardShortcut(.rightArrow, modifiers: []))
                .disabled(player == nil)
            Divider()
            Button(LocalizedStringKey(player?.isFill == true ? "FitScreen" : "FillScreen")) { player?.toggleFill() }
                .disabled(player == nil)
        }
    }
}

// MARK: - 畫面登記

private struct MacMenuRegistration<Value>: ViewModifier {
    let value: Value
    /// 狀態變了（播放／暫停、能不能上一層）才重新登記，選單標題與啟用狀態跟著更新
    let key: [Bool]
    let set: @MainActor (Value?, UUID) -> Void
    @State private var owner = UUID()

    func body(content: Content) -> some View {
        content
            .onAppear { set(value, owner) }
            .onChange(of: key) { _, _ in set(value, owner) }
            .onDisappear { set(nil, owner) }
    }
}

extension View {
    /// 只在 Mac 上登記；iPhone／iPad 不加任何東西
    @ViewBuilder
    func macMenuFolder(_ folder: @autoclosure () -> MacMenu.Folder) -> some View {
        if MacSupport.isMac {
            let value = folder()
            modifier(MacMenuRegistration(value: value, key: [value.canGoUp]) { MacMenu.shared.setFolder($0, owner: $1) })
        } else {
            self
        }
    }

    @ViewBuilder
    func macMenuPhoto(_ photo: @autoclosure () -> MacMenu.Photo) -> some View {
        if MacSupport.isMac {
            let value = photo()
            modifier(MacMenuRegistration(value: value, key: [value.showsInfo]) { MacMenu.shared.setPhoto($0, owner: $1) })
        } else {
            self
        }
    }

    @ViewBuilder
    func macMenuPlayer(_ player: @autoclosure () -> MacMenu.Player) -> some View {
        if MacSupport.isMac {
            let value = player()
            modifier(MacMenuRegistration(value: value, key: [value.isPlaying, value.isFill]) { MacMenu.shared.setPlayer($0, owner: $1) })
        } else {
            self
        }
    }

    /// Mac 視窗設定（最小尺寸）：掛在 WindowGroup 的根畫面上
    @ViewBuilder
    func macWindowSetup() -> some View {
        if MacSupport.isMac {
            background(MacWindowSetup().frame(width: 0, height: 0))
        } else {
            self
        }
    }
}

// MARK: - 開資料夾（⌘O）

/// 選單的「開啟資料夾…」：畫面自己的 .fileImporter 綁在各模式的 @State 上，選單碰不到，
/// 這裡直接用 UIKit 的資料夾挑選器（和 .fileImporter 底層相同，拿到的一樣是有存取權限的 URL）
@MainActor
enum MacFolderPicker {
    private final class Delegate: NSObject, UIDocumentPickerDelegate {
        let onPick: (URL) -> Void
        init(onPick: @escaping (URL) -> Void) { self.onPick = onPick }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            if let url = urls.first { onPick(url) }
            MacFolderPicker.delegate = nil
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            MacFolderPicker.delegate = nil
        }
    }

    /// 挑選器開著時保留 delegate（UIDocumentPickerViewController 只弱參照它）
    private static var delegate: Delegate?

    /// 視窗上蓋著別的畫面（播放器、提示框、系統的檔案挑選器）
    static var isCovered: Bool { topViewController()?.presentingViewController != nil }

    static func present(onPick: @escaping (URL) -> Void) {
        guard delegate == nil, !isCovered, let top = topViewController() else { return }
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.folder])
        picker.view.tintColor = UIColor(Color.wpAccent)
        let delegate = Delegate(onPick: onPick)
        picker.delegate = delegate
        self.delegate = delegate
        top.present(picker, animated: true)
    }

    private static func topViewController() -> UIViewController? {
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive } ??
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        var vc = (scene?.windows.first { $0.isKeyWindow } ?? scene?.windows.first)?.rootViewController
        while let presented = vc?.presentedViewController { vc = presented }
        return vc
    }
}

// MARK: - 視窗最小尺寸

/// 預設可以把視窗縮到約 514×319 點，首頁、照片側欄、海報牆都會被切掉；進到視窗時設一次下限
private struct MacWindowSetup: UIViewRepresentable {
    final class SetupView: UIView {
        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard let restrictions = window?.windowScene?.sizeRestrictions else { return }
            let minimum = MacSupport.minimumWindowSize
            if restrictions.minimumSize.width < minimum.width || restrictions.minimumSize.height < minimum.height {
                restrictions.minimumSize = minimum
            }
        }
    }

    func makeUIView(context: Context) -> SetupView {
        let view = SetupView()
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ uiView: SetupView, context: Context) {}
}
