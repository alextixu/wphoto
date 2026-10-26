# wphoto 交接文件

換電腦或開新的 Claude 對話時，先讀這份文件。最後更新：2026-10-27。

## 專案概況

| 部分 | 位置 | 狀態 |
|---|---|---|
| Windows 版（.NET 9 WPF） | `main` 分支，repo 根目錄 | v1.1 已發布；之後的啟動加速、縮圖總覽、`publish.ps1` 已 commit，**尚未發新 Release** |
| iPhone / iPad 版（SwiftUI） | `ios` 分支的 `ios/` 資料夾 | 可用 GitHub Actions 編出未簽名 IPA，用 Sideloadly 安裝；**還沒合併回 `main`**（`main` 的 README 連到 `ios/`，合併前那個連結會失效） |

- Repo：<https://github.com/alextixu/wphoto>（公開）
- GitHub 帳號：`alextixu`（原 `lintaixu`，2026-09 改名）

## 維護規則（一定要遵守）

1. **先給使用者看改了什麼，核准後才 commit。**
2. **push 只有使用者明確說「可以推」才做**，任何分支都一樣；要跑 CI 也要先問。
3. **commit 作者只能是 `lintaixu`**，commit 訊息**不加** Claude 的 Co-Authored-By 署名。
4. 每次功能變更都要同步：README（中英雙語，含截圖）、GitHub Release 的 zip、repo 的 topics/description。
5. README 截圖只用 `demo` 資料夾的 CC0 素材，**不用使用者的個人照片**。
6. UI 文字三語同步：Windows 版在 `Localization.cs`；iOS 版在 `ios/wphoto/Resources/*.lproj/Localizable.strings`（en / zh-Hant / zh-Hans 三份的 key 要一致）。
7. **NAS（Z: 槽）上的任何動作都要先問過使用者**，包括列目錄和讀檔；同意只適用那一次。

## 新電腦設定

1. 安裝 Git、[GitHub CLI](https://cli.github.com/)、Claude 桌面版；Windows 版開發還要裝 .NET 9 SDK。
2. 登入 GitHub CLI（帳號 `alextixu`，要有 `workflow` 權限）：

   ```bash
   gh auth login
   ```

3. 下載程式碼，並另外開一個資料夾放 `ios` 分支（git worktree）：

   ```bash
   git clone https://github.com/alextixu/wphoto.git PhotoViewer
   cd PhotoViewer
   git config user.name lintaixu
   git worktree add ../wphoto-ios ios
   ```

   `user.email` 請自行設成 lintaixu 的 GitHub 信箱。
4. 要把 IPA 裝到 iPhone 的話，再裝 Sideloadly。**不需要 Mac**，iOS 版在 GitHub Actions 上編譯。
5. 舊電腦的 Claude 記憶在 `C:\Users\<使用者>\.claude\projects\<專案路徑>\memory\`，可以整個資料夾複製到新電腦對應的位置。這份文件已經整理了其中跟專案有關的內容，不複製也可以。

## 建置與發行

### Windows 版

```powershell
.\publish.ps1                      # 產生 dist\wphoto_v<版本>_win-x64.zip
.\publish.ps1 -Install E:\wphoto   # 另外複製到指定資料夾
```

以資料夾形式發行，不用單一 exe：單一 exe 有 438 MB，在機械硬碟冷啟動要 20 秒，資料夾形式約 3 秒。

### iOS 版

1. 推送 `ios` 分支。如果 Git Credential Manager 卡住，改用 gh 當認證：

   ```bash
   git -c credential.helper= -c "credential.helper=!gh auth git-credential" push origin ios
   ```

2. 手動觸發建置（推送本身也會觸發一次）：

   ```bash
   gh workflow run ios.yml --repo alextixu/wphoto --ref ios
   ```

3. 編好後下載 artifact，把 `.ipa` 放到固定的資料夾（舊電腦是 `E:\test_think\ios-build\wphoto-unsigned.ipa`）：

   ```bash
   gh run download <run-id> --repo alextixu/wphoto --dir <下載資料夾>
   ```

4. 用 Sideloadly 搭配免費 Apple ID 安裝。7 天到期後，拿同一個 IPA 重裝即可，資料會保留。

上架 App Store 的準備在 `ios/AppStore/`（說明、三語商店文字、隱私權政策）和 `.github/workflows/ios-appstore.yml`。需要 Apple 開發者帳號，目前還沒申請。Mac 版的方向是讓 iPad 版直接在 Apple 晶片的 Mac 上執行。

## iOS 版技術重點

- **資料夾**：
  - 從「檔案」App 開啟，iCloud、本機、在「檔案」裡連接的 NAS 都可以。
  - 開過的資料夾記在「常用位置」，用 security-scoped bookmark；啟動時不會自動開任何資料夾，NAS 沒連線也不會卡住。
  - 資料夾一層一層進去，每次只讀目前這一層，讀過的層有快取。實作在 `Shared/FolderSession.swift`。
- **播放**：MP4 / MOV / M4V 用 AVPlayer，其他格式（MKV 等）用 MobileVLCKit 3.7.3。VLCKit 不進 git，由 CI 下載。
- **字幕**：
  - 文字字幕全部由 App 自己畫，因為 VLC 的 freetype 字型沒有中文字，會變方格。VLC 只負責圖形字幕（PGS 等）。
  - 支援雙字幕。
  - MKV 內嵌字幕用自己寫的 EBML 解析器讀取（`Theater/MatroskaSubtitles.swift`）：先讀 Cues 索引、從目前播放位置附近開始讀、8 條平行讀取、邊讀邊顯示，從 NAS 讀也快。
- **專案設定**：`ios/project.yml`（XcodeGen）。

## 待辦

### 已核准、還沒開始寫的四個功能（iOS）

使用者 2026-10-21 已經說好要做。做完先給使用者看，核准後才 commit／推送／編 IPA。

1. **手機相簿滑動整理**（從另一個專案 PhotoSweep 搬過來）
   - 入口：照片模式的位置清單最上面加一列「手機相簿」。只用在手機相簿，「檔案」和 NAS 資料夾維持原本的瀏覽方式。
   - 第一次使用先說明玩法，再要相簿權限（PhotoKit）。只允許部分照片時，可以再多選。
   - 相簿首頁：統計（已檢視／垃圾桶／已釋放空間）、快速開始（隨機、截圖、影片、最愛、全部）、按月份分組，都從最新的照片開始。
   - 滑動畫面：**右滑保留、左滑進 App 內的垃圾桶、點兩下跳出大愛心並加入最愛**（和 Apple「照片」同步；點兩下只加入，取消要按 ♥）、點一下看大圖；下方有復原／垃圾桶／保留／♥ 四個按鈕。
   - 垃圾桶可以還原；清空時由 iOS 跳確認框，刪掉的照片進「最近刪除」保留 30 天。
   - 預設：包含影片（和 PhotoSweep 一樣）；進度和 PhotoSweep 分開記。
   - 要加 `NSPhotoLibraryUsageDescription`（三語），並更新隱私權政策與 README。
   - 搬移注意事項：
     - PhotoSweep 的 `HomeView` 自己有一層 `NavigationStack`，wphoto 外層已經有，搬過來要拿掉，改用 `.navigationDestination(item:)`。
     - 類型名稱沒有衝突，但建議改名：`HomeView`→`LibraryHomeView`、`Layout`→`SwipeLayout`、`Route`→`LibraryRoute`、`PermissionView`→`LibraryPermissionView`。
     - PhotoSweep 的字串在 `Localizable.xcstrings`，要轉成 wphoto 的 `.strings` 三語。
2. **電影海報牆**（看劇模式）
   - 資料夾方塊改成直式海報（2:3），下面顯示片名。
   - 封面依序找資料夾裡的 `poster` / `folder` / `cover` / `fanart` 圖片，再來是其他圖片，最後用影片截一格。
   - 只讀畫面上看得到的資料夾；讀封面時順便把那一層的內容存進 `FolderSession` 的快取，點進去就不用再等 NAS。
   - 照片模式的資料夾維持原樣。
3. **續看進度**
   - AVPlayer（`Theater/PlayerScreen.swift`）和 VLC（`Theater/VLCPlayerScreen.swift`、`VLCPlayerController` 的 `currentMs` / `durationMs` / `seek(toMs:)`）都要記住看到哪裡。
   - 重新打開時從上次的位置繼續並提示；看不到 30 秒或看到最後 5% 的就從頭播。
   - 影片卡片（`EpisodeCard`）底部加進度條，看完的打勾。
4. **首頁的「繼續觀看」和「最近位置」**（`App/ModeSelectView.swift`）
   - 模式卡片下方列出：
     - 繼續觀看：附進度條，點一下會開啟所在的常用位置、進到那一層並開始播放。
     - 最近位置：照片和影片模式最近開過的位置，點一下直接進去。
   - 都是點了才開，啟動時不自動連 NAS。

### 其他

- Windows 版：發新版 Release（啟動加速、縮圖總覽），並同步 README 截圖。
- `ios` 分支合併回 `main` 的時機由使用者決定。
- 可以考慮：讓 CI 裡「在 Mac 上啟動」那一步只在有簽名憑證時才跑（目前用 ad-hoc 簽名一定會失敗，已設為 continue-on-error）。
