# wphoto for iOS

Native SwiftUI companion to the Windows app. Same two modes, same dark look. Photos and MP4/MOV use Apple's own decoders, so RAW (RAF/ARW/CR3/…), HEIF, HDR10 and Dolby Vision render natively; MKV, MTS, AVI, WebM and other containers Apple can't open play through [VLCKit](https://code.videolan.org/videolan/VLCKit).

原生 SwiftUI 版本。照片／看劇兩種模式與 Windows 版一致。照片與 MP4/MOV 走 Apple 原生解碼（RAW、HEIF、HDR、杜比視界）；MKV、MTS、AVI、WebM 等 Apple 不支援的格式改用 VLCKit 播放。

## Open folders from anywhere in Files · 從「檔案」開啟任何位置

Both modes pick a folder through the Files app — **iCloud Drive, On My iPhone, or a NAS you've connected in Files (SMB)**. The app does not reopen the last folder on launch — you pick one each time, so an unreachable NAS can never leave the app stuck at startup.

兩種模式都透過「檔案」App 選資料夾——**iCloud Drive、我的 iPhone、或在「檔案」裡連接的 NAS (SMB)** 都可以。App 不會在啟動時自動重開上次的資料夾，每次都由你選擇，所以 NAS 沒連線時不會卡在啟動畫面。

> **NAS / iCloud note.** iOS cannot stream a file from a Files provider: a video that isn't on the iPhone yet is **downloaded in full** before it plays (the player shows "Downloading…" with a Cancel button, and the phone needs enough free space). Episode covers and durations are only read for videos that are already local — browsing a NAS season never downloads whole episodes; not-yet-downloaded ones show a cloud badge. Photo thumbnails still load the file the first time a cell appears.
>
> **NAS／iCloud 說明**：iOS 無法從「檔案」的雲端項目邊下載邊播，還不在 iPhone 上的影片會**先完整下載**再播放（畫面顯示「下載中…」，可按取消；手機需要足夠空間）。封面與時長只讀取已在本機的影片，瀏覽 NAS 整季不會把每集都下載下來；尚未下載的集數會顯示雲朵圖示。照片縮圖則會在格子第一次出現時讀取檔案。

## Features · 功能

| Photo mode | Theater mode |
|---|---|
| RAW / JPEG / HEIF / TIFF via ImageIO (Apple RAW pipeline) | MP4 / MOV / M4V via AVPlayer; MKV / WebM / AVI / MTS / M2TS / TS / WMV / FLV / 3GP via VLCKit |
| Thumbnail grid, type filter (only types present in the folder) | Episode grid with cover frames and duration |
| Pinch-zoom, double-tap, swipe between photos | AVPlayer: native controls, 0.5×–2× speed, subtitle/audio tracks, PiP, AirPlay |
| Shooting info sheet: camera, lens, ISO, shutter, aperture, focal length, GPS… | VLC player: scrubber, ±10 s, 0.5×–2× speed, subtitle / audio track menus, fit / fill, auto-hiding controls |
| | External subtitles (`.srt` `.ass` `.ssa` `.sub` `.vtt`) next to the video or in a `Subs` / `Subtitles` folder |
| | **Dual subtitles** (VLC player): main + second subtitle drawn by the app (no Chinese box glyphs), from external files or embedded MKV text tracks |

### Which player is used · 播放引擎怎麼選

| Video | Player | Why |
|---|---|---|
| MP4 / M4V / MOV, no subtitle file named after the video | AVPlayer | Keeps HDR10 / Dolby Vision / Atmos, Picture in Picture and AirPlay |
| MP4 / M4V / MOV **with** its own subtitle file (name starts with the video's name, e.g. `Show.E02.srt`) | VLC | AVPlayer can't load `.srt` / `.ass` for a local file |
| MKV, WebM, AVI, MTS, M2TS, TS, WMV, FLV, 3GP | VLC | AVFoundation has no reader for these containers |
| An MP4 that AVPlayer can't open (unsupported codec) | VLC | Automatic fallback |

- 沒有同名外掛字幕的 MP4 / M4V / MOV 用 AVPlayer（保留 HDR、杜比視界、子母畫面、AirPlay）；資料夾裡別集的字幕不算。
- 有同名外掛字幕（檔名以影片檔名開頭）、或是 MKV / AVI / TS 等格式，用 VLC（字幕選單會列出內嵌字幕與外掛字幕）。
- AVPlayer 開不了的 MP4 自動改用 VLC。

External subtitles are searched in the video's folder and a `Subs` or `Subtitles` subfolder (up to 15). Only a subtitle whose name starts with the video's name (e.g. `Show.E02.srt`, `Show.E02.zh-TW.srt`) is turned on automatically; the others — such as other episodes' subtitles — are only listed in the Subtitles menu (by file name when the app can tell which track is which file). Track names are shown in the app's language, e.g. "Subtitle 2 (Chinese)". Non-UTF-8 Chinese subtitles are decoded as Big5 (CP950) when the iPhone language is Traditional Chinese and as GB18030 when it is Simplified Chinese; UTF-8 files are always detected automatically.

外掛字幕會在影片同資料夾與 `Subs`、`Subtitles` 子資料夾中尋找（最多 15 個）。只有檔名以影片檔名開頭的字幕（例如 `Show.E02.srt`、`Show.E02.zh-TW.srt`）會自動開啟；其他字幕（例如別集的）只列在字幕選單裡（能確定是哪個檔案時以檔名顯示）。軌道名稱以介面語言顯示，例如「字幕 2（中文）」。非 UTF-8 的中文字幕：系統語言為繁體中文時以 Big5（CP950）解碼、簡體中文時以 GB18030 解碼；UTF-8 字幕一律自動辨識。

### Subtitles in the VLC player · VLC 播放器的字幕

Text subtitles — external `.srt` / `.vtt` / `.ass` / `.ssa` files and text tracks embedded in MKV/WebM (SRT, ASS/SSA, WebVTT) — are read and drawn by the app itself with the iOS system font. libVLC 3 can't render Chinese on iOS: its default font (Helvetica Neue) has no Chinese glyphs, its automatic fallback fails (iOS hands it the hidden name ".PingFang SC", which doesn't match the name inside the font file), and forcing a Chinese font makes VLC's text renderer fail to load so no subtitles appear at all. VLC only draws what the app can't read: image subtitles (PGS, VobSub, DVB), subtitles embedded in MP4/TS/AVI, and `.sub` files — listed under "Other tracks (shown by VLC)".

The Subtitles menu: **Main Subtitle**, **Other tracks (shown by VLC)** (only when there are any), **Second Subtitle**, **Second Subtitle Position**.

- Dual subtitles: pick a second subtitle; it is stacked above the main one (or placed at the top).
- Main subtitle is chosen automatically: the language you picked last time → a subtitle file named after the video → the app's language when it is Chinese → a track flagged default. The second subtitle language is remembered too.
- Embedded tracks are read through the MKV's Cues index (mkvmerge indexes every subtitle block), so even an 18 GB 4K film loads its subtitles in about a second. Files without that index are scanned once (only element headers).
- Image subtitles can't be the second subtitle.

文字字幕——外掛 `.srt` / `.vtt` / `.ass` / `.ssa`，以及 MKV／WebM 內嵌的文字軌（SRT、ASS/SSA、WebVTT）——都由 App 自己讀取，並用 iOS 系統字型顯示。libVLC 3 在 iOS 上無法顯示中文：預設字型 Helvetica Neue 沒有中文字，自動替代字型會失敗（iOS 給的是隱藏名稱「.PingFang SC」，跟字型檔裡的名稱對不上），而強制指定中文字型會讓 VLC 的文字渲染器載入失敗、字幕全部消失。VLC 只負責 App 讀不了的字幕：圖片字幕（PGS、VobSub、DVB）、MP4／TS／AVI 內嵌字幕與 `.sub` 檔，列在「其他字幕軌（由 VLC 顯示）」。

字幕選單：**主字幕**、**其他字幕軌（由 VLC 顯示）**（有的時候才出現）、**第二字幕**、**第二字幕位置**。

- 雙字幕：選一條第二字幕，會疊在主字幕上面（或放在上方）。
- 主字幕自動選擇：上次選的語言 → 檔名對得上的外掛字幕 → 介面語言為中文時選同語言 → 標記為預設的字幕軌。第二字幕的語言也會記住。
- 內嵌字幕透過 MKV 的 Cues 索引直接讀取（mkvmerge 會替每個字幕區塊建索引），18 GB 的 4K 電影約一秒內載入；沒有索引的檔案才掃描一次（只讀元素標頭）。
- 圖片字幕無法當第二字幕。

Limits of the VLC player: no HDR / Dolby Vision tone mapping (VLCKit 3 renders SDR), no Picture in Picture or AirPlay video, and no lock-screen controls — playback pauses when you lock the phone or switch apps.

VLC 播放的限制：不支援 HDR／杜比視界（VLCKit 3 以 SDR 顯示），也沒有子母畫面、AirPlay 影像與鎖定畫面的播放控制——鎖定手機或切到其他 App 時會自動暫停。

## Build · 建置

iOS apps can only be compiled by Xcode 16 or newer on a Mac (or a macOS CI runner). The project is defined with [XcodeGen](https://github.com/yonaskolb/XcodeGen). VLCKit is **not** stored in git (the extracted framework is about 1.3 GB), so download VideoLAN's official MobileVLCKit 3.7.3 into `ios/Vendor/` first and check its SHA-256:

```bash
brew install xcodegen
cd ios

# MobileVLCKit 3.7.3 (official VideoLAN binary, same URL and checksum as the official podspec)
curl -fLO https://download.videolan.org/pub/cocoapods/prod/MobileVLCKit-3.7.3-319ed2c0-79128878.tar.xz
echo "0d04059906962ddc9a7bd1ebaa12e1f9ae85eb2466116a97a2f46886dd27a0a9  MobileVLCKit-3.7.3-319ed2c0-79128878.tar.xz" | shasum -a 256 -c -
mkdir -p Vendor /tmp/vlckit
tar -xf MobileVLCKit-3.7.3-319ed2c0-79128878.tar.xz -C /tmp/vlckit
mv /tmp/vlckit/MobileVLCKit-binary/MobileVLCKit.xcframework Vendor/

xcodegen generate        # → wphoto.xcodeproj (embeds Vendor/MobileVLCKit.xcframework)
open wphoto.xcodeproj    # Run on Simulator or your iPhone
```

Do not commit `ios/Vendor/` or the downloaded `.tar.xz`.

Every push touching `ios/` is compiled on GitHub Actions (`.github/workflows/ios.yml`, macOS runner) as a build check. The workflow downloads the same VLCKit archive, verifies the SHA-256 and caches it.

每次修改 `ios/` 都會在 GitHub Actions（macOS runner）編譯檢查；workflow 會下載同一個 VLCKit 壓縮檔、驗證 SHA-256 並快取。

### Install on your iPhone · 安裝到 iPhone

- **With a Mac:** open the project in Xcode, pick your Apple ID under Signing & Capabilities, and run.
- **Without a Mac (Sideloadly):** run the **iOS build** workflow manually (Actions → iOS build → Run workflow). It uploads an unsigned `wphoto-unsigned.ipa` (artifact `wphoto-unsigned-ipa`) with MobileVLCKit embedded; install it with [Sideloadly](https://sideloadly.io) and your own Apple ID, which signs the app and the framework.

A free Apple ID allows 7-day sideloading; TestFlight / App Store distribution needs the Apple Developer Program.

**App Store / TestFlight:** see [AppStore/README.md](AppStore/README.md) (no Mac needed — the **iOS App Store upload** workflow signs and uploads; store texts in three languages are in [AppStore/listing.md](AppStore/listing.md)). 上架教學見 [AppStore/README.md](AppStore/README.md)。

- **有 Mac：** 用 Xcode 開啟專案，在 Signing & Capabilities 選自己的 Apple ID 後執行。
- **沒有 Mac（Sideloadly）：** 在 GitHub 手動執行 **iOS build** workflow，下載 `wphoto-unsigned-ipa`（內含 MobileVLCKit），再用 Sideloadly 以自己的 Apple ID 簽名安裝。免費 Apple ID 每 7 天需重新安裝。

## Languages · 語言

Follows the iPhone system language: English, 繁體中文, 简体中文 (`Resources/*.lproj/Localizable.strings`).

## Third-party · 第三方元件

- [MobileVLCKit](https://code.videolan.org/videolan/VLCKit) 3.7.3 (libVLC) — playback of MKV, MTS, AVI, WebM and other non-Apple containers. LGPL-2.1; shipped unmodified as a separate dynamic framework (`wphoto.app/Frameworks/MobileVLCKit.framework`). Source code and license: <https://code.videolan.org/videolan/VLCKit> (tag `3.7.3`), license text in `COPYING.txt` inside the official archive.

## License · 授權

[MIT](../LICENSE). Video playback of non-Apple formats uses VLCKit / libVLC under LGPL-2.1, distributed as a separate dynamic framework.
