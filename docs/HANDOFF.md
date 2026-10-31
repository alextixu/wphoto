# wphoto 交接文件

換電腦或開新的 Claude 對話時，先讀這份文件。最後更新：2026-10-31。

## 專案概況

| 部分 | 位置 | 狀態 |
|---|---|---|
| Windows 版（.NET 9 WPF） | `main`，repo 根目錄 | v1.1 已發布；之後的啟動加速、縮圖總覽、`publish.ps1` 已 commit，**尚未發新 Release** |
| iPhone / iPad / Mac 版（SwiftUI） | `main` 的 `ios/` 資料夾 | 可用 GitHub Actions 編出未簽名 IPA，用 Sideloadly 安裝；Mac 上以「Designed for iPad」執行 |

- Repo：<https://github.com/alextixu/wphoto>（公開）
- GitHub 帳號：`alextixu`（原 `lintaixu`，2026-09 改名）

## 維護規則（一定要遵守）

1. **先給使用者看改了什麼，核准後才 commit。**
2. **push 只有使用者明確說「可以推」才做**，任何分支都一樣；要跑 CI 也要先問。
3. **commit 作者只能是 `alextixu`**（原 `lintaixu`，2026-10-31 起一律用新名字），commit 訊息**不加** Claude 的 Co-Authored-By 署名。
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

3. 下載程式碼：

   ```bash
   git clone https://github.com/alextixu/wphoto.git PhotoViewer
   cd PhotoViewer
   git config user.name alextixu
   ```

   `user.email` 請自行設成 alextixu 的 GitHub 信箱。
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

1. 推送 `main`。如果 Git Credential Manager 卡住，改用 gh 當認證：

   ```bash
   git -c credential.helper= -c "credential.helper=!gh auth git-credential" push origin main
   ```

2. 手動觸發建置（推送本身也會觸發一次）：

   ```bash
   gh workflow run ios.yml --repo alextixu/wphoto --ref main
   ```

3. 編好後下載 artifact，把 `.ipa` 放到固定的資料夾（舊電腦是 `E:\test_think\ios-build\wphoto-unsigned.ipa`）：

   ```bash
   gh run download <run-id> --repo alextixu/wphoto --dir <下載資料夾>
   ```

4. 用 Sideloadly 搭配免費 Apple ID 安裝。7 天到期後，拿同一個 IPA 重裝即可，資料會保留。

有 Mac（Apple 晶片）時也可以直接在本機編譯：`xcodegen generate` 後用 Xcode 開 `ios/wphoto.xcodeproj`，執行目標選「My Mac (Designed for iPad)」就能在 Mac 上用 iPad 版。免費 Apple ID 簽的版本 7 天後要再從 Xcode 執行一次。

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

### iOS 四個功能的狀態（2026-10-27）

- **手機相簿滑動整理（PhotoSweep）：使用者決定取消。** 照片模式維持只讀「檔案」裡的照片與相機 RAW，不要求照片圖庫權限。
- **電影海報牆、續看進度、首頁的「繼續觀看」與「最近位置」：已寫好**，並在 Mac 的 iPad 模擬器上測過。三語字串、README、隱私權政策都已同步。
  - 海報牆：`Theater/PosterGrid.swift`；封面查找與預先讀取的快取在 `Shared/FolderSession.swift` 的 `posterSource(for:)`（同時最多讀 4 個資料夾）。
  - 續看進度：`Theater/WatchProgressStore.swift`（存在 UserDefaults，以影片路徑為 key），AVPlayer 在 `Theater/PlayerScreen.swift`，VLC 用 `:start-time` 從續播位置開檔。
  - 首頁：`App/ModeSelectView.swift`；從首頁開回某一層用 `FolderSession.openSaved(_:subfolders:)`。
  - 等使用者說「可以推」才 commit、push、編 IPA。

### iOS UI 翻新（2026-10-28，已 commit）

- 做了 9 個「快速見效」項目：`Shared/Theme.swift` 設計 token、首頁 large title 與材質模式卡、常用位置空狀態與「…」選單、縮圖牆 Button 化與空狀態、檢視器 44pt 圓鈕與 iPad 右側拍攝資訊欄、海報牆陰影與漸層佔位、集數卡片去副檔名與材質徽章、VLC 控制列（中央播放群、材質面板、自製進度條、滑鼠支援、觸覺）、AVPlayer 續播提示與片名。
- 完整計畫、備註與下一輪的 B／C 級清單在桌面 `wphoto-ui-shots/UI翻新總結.md`（含截圖）。使用者看過核准後才 commit。
- 第二輪再做了 VLC 手勢（雙擊兩側 ±10 秒、捏合填滿、下滑關閉；手勢只編譯過、沒在模擬器實際操作）與檢視器的側欄（`HStack`，照片會縮到左邊）、下拉關閉、iOS 18 zoom 轉場。

### iOS 電影院配色與字幕大小（2026-10-31）

- 配色概念是「熄燈後的放映廳」：唯一的彩色是絨布紅，其餘都是暖黑與象牙白。token 都在 `Shared/Theme.swift`，檔案開頭有規則。不要再加第二個強調色，也不要用藍色。
- 紅色對深色底只有 3.3:1，只能當填色與圖示，不能當小字。紅色只留給播放、進度、主要按鈕；文字與導覽列用象牙白。
- 卡片是霧面實色（拿掉 Liquid Glass），圓角縮小，標題用襯線字（`App/wphotoApp.swift` 的 UINavigationBar appearance），分區標題是寬字距小字。
- 系統控制項的藍色用 `project.yml` 的全域 AccentColor 換掉。**檔案挑選器是例外**：它是系統畫面，`wphotoApp.swift` 雖然設了 tintColor，實測同一個版本有時紅有時藍，原因不明。要徹底解決得換掉 `.fileImporter`，但那條路徑關係到 NAS 的存取權限，目前不值得冒險。
- 照片模式不開紅光（`CinemaBackdrop(glow: false)`），避免影響看照片的色偏判斷。
- 字幕字級在 `VLCPlayerScreen.swift` 的 `subtitleFontSize`：影片高度 6.5%、同時看寬度，上限是一行放得下 16 字，下限 20pt。**不要再加固定點數上限**：舊版 56pt 上限在 4K 視窗只剩畫面的 2.6%。
- 參考值：YouTube 預設字幕實測是播放器高度的 4.44%（360p 到 4K 都一樣，沒有上限）；Netflix 規範沒有百分比，只要求相對影片解析度、繁中一行 16 字、英文 42 字。
- AVPlayer 的內嵌字幕由系統繪製，跟隨 iOS 的字幕設定，大小沒有實測。

### 分支與合併（2026-10-31）

- 只留 `main`。Windows 版在根目錄、iOS 版在 `ios/`，兩邊沒有共用程式碼，不需要平台分支。之後新功能開短期分支，用 PR 併回 `main`。
- `main` 的 PR **不要用 GitHub 的合併按鈕或 `gh pr merge --merge`**：GitHub 產生的 merge commit 作者會是個人頁顯示名稱，不是 `alextixu`。先確認 PR 是快轉，再把同一個 commit 直接 push 到 `main`，GitHub 會判定為 merged，編號與作者都不變。
- README 截圖的海報與影片畫面是程式生成的，照片裁自舊截圖裡的 CC0 範例；`demo` 資料夾不在 Mac 上。

### 其他

- Windows 版：發新版 Release（啟動加速、縮圖總覽），並同步 README 截圖。
- 可以考慮：讓 CI 裡「在 Mac 上啟動」那一步只在有簽名憑證時才跑（目前用 ad-hoc 簽名一定會失敗，已設為 continue-on-error）。
