# wphoto 上架 App Store 教學（不需要 Mac）

整個流程：加入 Apple Developer Program → 產生憑證與描述檔 → 設定 GitHub Secrets → 執行 **iOS App Store upload** workflow → 在 App Store Connect 填資料、TestFlight 測試 → 送審。
同一個上架流程也會讓 M 系列晶片的 Mac 可以從 Mac App Store 安裝（見第 11 節）。

> 付款、登入 Apple 帳號、上傳憑證到 GitHub Secrets 都要你本人操作。下面的指令在 Windows 的 **Git Bash** 執行（Git Bash 內建 `openssl` 與 `base64`）。

## 1. 加入 Apple Developer Program

1. Apple ID 先開啟雙重認證。
2. 到 <https://developer.apple.com/programs/enroll/> 以「個人」身分報名，年費 US$99。App Store 上的開發者名稱會是你的本名。
3. 通過後（通常 1～2 天）就能使用 <https://developer.apple.com/account> 與 <https://appstoreconnect.apple.com>。

## 2. 註冊 Bundle ID

Developer 網站 → **Certificates, Identifiers & Profiles** → **Identifiers** → ＋ → **App IDs** → **App**：

- Description：`wphoto`
- Bundle ID（Explicit）：`com.lintaixu.wphoto`
- Capabilities：不需要勾任何項目

> Bundle ID 上架後就不能改。若想改成別的（例如 `com.alextixu.wphoto`），要先改 `ios/project.yml` 的 `PRODUCT_BUNDLE_IDENTIFIER` 與 `.github/workflows/ios-appstore.yml` 的 `BUNDLE_ID`。

## 3. 產生 Apple Distribution 憑證（.p12）

在 Git Bash：

```bash
mkdir -p ~/wphoto-signing && cd ~/wphoto-signing
openssl genrsa -out dist.key 2048
openssl req -new -key dist.key -out dist.csr -subj "/emailAddress=你的Apple ID信箱/CN=你的名字/C=TW"
```

Developer 網站 → **Certificates** → ＋ → **Apple Distribution** → 上傳 `dist.csr` → 下載 `distribution.cer`，放到 `~/wphoto-signing`，然後：

```bash
openssl x509 -inform DER -in distribution.cer -out dist.pem
openssl pkcs12 -export -legacy -inkey dist.key -in dist.pem -out dist.p12
```

最後一行會要你設定 .p12 密碼（之後填到 `DIST_CERT_PASSWORD`）。

> `dist.key` 與 `dist.p12` 等於你的簽名身分，**不要**放進 git、不要傳給別人。

## 4. 產生 App Store 描述檔

Developer 網站 → **Profiles** → ＋ → **App Store Connect** → App ID 選 `com.lintaixu.wphoto` → 憑證選剛建立的 Apple Distribution → 名稱 `wphoto App Store` → 下載 `.mobileprovision` 放到 `~/wphoto-signing`。

## 5. 建立 App Store Connect API 金鑰

App Store Connect → **使用者與存取權限** → **整合** → **App Store Connect API** → ＋ → 名稱 `GitHub Actions`、權限 **App 管理**（App Manager）→ 下載 `AuthKey_XXXXXXXXXX.p8`（只能下載一次），並記下頁面上的 **Key ID** 與 **Issuer ID**。

## 6. 設定 GitHub Secrets

用已登入的 GitHub CLI 在 Git Bash 執行（`gh secret set` 會直接加密上傳，不會留在畫面或檔案裡）：

```bash
cd ~/wphoto-signing
R=alextixu/wphoto
base64 -w0 dist.p12 | gh secret set DIST_CERT_P12_BASE64 -R $R
gh secret set DIST_CERT_PASSWORD -R $R                      # 會提示輸入 .p12 密碼
base64 -w0 *.mobileprovision | gh secret set PROVISIONING_PROFILE_BASE64 -R $R
gh secret set APPSTORE_API_KEY_ID -R $R                     # 輸入 Key ID
gh secret set APPSTORE_API_ISSUER_ID -R $R                  # 輸入 Issuer ID
gh secret set APPSTORE_API_PRIVATE_KEY -R $R < AuthKey_*.p8
```

## 7. 在 App Store Connect 建立 App

**我的 App** → ＋ → **新增 App**：

- 平台：iOS
- 名稱：見 [listing.md](listing.md)（名稱被別人用掉時改用備案）
- 主要語言：繁體中文
- 套件識別碼：`com.lintaixu.wphoto`
- SKU：`wphoto`

## 8. 上傳建置版本

GitHub → **Actions** → **iOS App Store upload** → **Run workflow**（分支選 `ios`）。成功後約 10～30 分鐘，App Store Connect 的 **TestFlight** 會出現這個建置版本。

- 建置號自動遞增（每次執行 +1）；版本號在 `ios/project.yml` 的 `MARKETING_VERSION`，新版本上架前記得改。
- 加密出口合規已在 Info.plist 宣告（`ITSAppUsesNonExemptEncryption = NO`），上傳後不必再回答。

## 9. TestFlight 測試

TestFlight → **內部測試** → 把自己加入測試員 → iPhone / iPad 安裝 TestFlight App 後即可安裝（有效 90 天，不像 Sideloadly 7 天就過期）。

## 10. 填寫商店資料並送審

App Store Connect → App → **App 資訊** 與 **iOS App 1.0**：

| 欄位 | 內容 |
|---|---|
| 名稱、副標題、宣傳文字、描述、關鍵字 | [listing.md](listing.md)（繁中、簡中、英文三份） |
| 截圖 | iPhone 6.9 吋（1320×2868）、iPad 13 吋（2064×2752）各至少 1 張 |
| 支援網址 | `https://github.com/alextixu/wphoto/issues` |
| 隱私權政策網址 | `https://github.com/alextixu/wphoto/blob/ios/ios/AppStore/privacy-policy.md` |
| App 隱私權 | 「不收集資料」 |
| 年齡分級 | 問卷全部選「無」→ 4+ |
| 類別 | 主要：攝影與錄影；次要：娛樂 |
| 版權 | `2026 你的名字` |
| 審查備註 | 見 listing.md 的「給審查人員的說明」 |

最後選擇建置版本 → **提交審查**（通常 1～3 天）。

## 11. Mac 版（Apple 晶片的 Mac 直接執行 iPad 版）

wphoto 不另外做 Mac 版：M 系列晶片的 Mac 可以直接執行 iPad 版，從 Mac App Store 安裝。

1. App Store Connect → App → **定價與供應狀況** → **iPhone 與 iPad App 在 Apple 晶片 Mac 上的供應狀況**：確認是「**提供**」（預設就是提供；不要選「不提供」）。
2. 送審前用 Mac 測試：在 M 系列 Mac 的 App Store 安裝 **TestFlight**，用同一個 Apple ID 登入，就能安裝 TestFlight 版的 wphoto。
3. 要測的項目：從「檔案」選資料夾（Mac 上會出現 Finder 的選取視窗）、照片縮圖與放大、MKV 播放（VLC 播放器）、字幕與雙字幕、視窗縮放時的版面。
4. 如果某項在 Mac 上不能用（例如 VLC 播放），可以先在這裡改成「不提供」，iPhone / iPad 版照常上架。

> Intel Mac 無法執行 iPad App；要支援 Intel Mac 或要有完整的 Mac 選單與視窗體驗，就要另外做原生 Mac 版。

## 可能的審查問題

- **LGPL（VLCKit）**：VLCKit 以 LGPL-2.1 授權、獨立的動態框架形式內嵌；App 本身原始碼以 MIT 公開在 GitHub，使用者可自行替換 VLCKit 重新建置。README 與 App 內都已標示第三方授權。
- **杜比音訊**：E-AC-3（DD+）由 VLCKit 以軟體解碼；若審查提出疑慮，可考慮在 App 內提示或改由系統解碼。
- **背景音訊（UIBackgroundModes: audio）**：用於 MP4/MOV 的子母畫面與背景播放；VLC 播放器進背景時會暫停。
