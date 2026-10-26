using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Windows;

namespace PhotoViewer;

/// <summary>
/// 三語系字串表（繁中／簡中／英文）。
/// Apply() 會把字串灌進 Application.Resources，XAML 用 DynamicResource 取用；
/// 程式碼用 Loc.T("Key")。語言選擇存在 %APPDATA%\wphoto\lang.txt。
/// </summary>
public static class Loc
{
    public const string ZhHant = "zh-Hant";
    public const string ZhHans = "zh-Hans";
    public const string En = "en";

    public static string Current { get; private set; } = En;

    static string SettingsPath =>
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "wphoto", "lang.txt");

    public static void Init()
    {
        string lang;
        try
        {
            lang = File.Exists(SettingsPath) ? File.ReadAllText(SettingsPath).Trim() : DetectSystemLang();
        }
        catch
        {
            lang = DetectSystemLang();
        }
        Apply(lang, save: false);
    }

    static string DetectSystemLang()
    {
        var c = CultureInfo.CurrentUICulture;
        if (c.Name.StartsWith("zh", StringComparison.OrdinalIgnoreCase))
        {
            // zh-TW / zh-HK / zh-MO → 繁體；zh-CN / zh-SG / zh-Hans → 簡體
            return c.Name.Contains("TW") || c.Name.Contains("HK") || c.Name.Contains("MO") || c.Name.Contains("Hant")
                ? ZhHant : ZhHans;
        }
        return En;
    }

    public static void Apply(string lang, bool save = true)
    {
        if (!Tables.ContainsKey(lang))
            lang = En;
        Current = lang;

        var table = Tables[lang];
        foreach (var kv in table)
            Application.Current.Resources["L." + kv.Key] = kv.Value;

        if (save)
        {
            try
            {
                Directory.CreateDirectory(Path.GetDirectoryName(SettingsPath)!);
                File.WriteAllText(SettingsPath, lang);
            }
            catch { }
        }
    }

    public static string T(string key) =>
        Tables[Current].TryGetValue(key, out var v) ? v : key;

    static readonly Dictionary<string, Dictionary<string, string>> Tables = new()
    {
        [ZhHant] = new()
        {
            ["ChooseFolder"] = "選擇資料夾",
            ["NoFolderHint"] = "尚未選擇資料夾（也可以直接把資料夾拖進視窗）",
            ["Subtitle"] = "字幕",
            ["Episodes"] = "選集",
            ["Gallery"] = "縮圖總覽",
            ["PickPhoto"] = "點選縮圖檢視照片（共 {0} 張）",
            ["SwitchMode"] = "切換模式",
            ["ShootingInfo"] = "拍攝資訊",
            ["KeyParams"] = "主要參數",
            ["PlaceholderPhoto"] = "選擇資料夾開始瀏覽照片",
            ["PlaceholderVideo"] = "選擇資料夾開始看劇",
            ["ChooseMode"] = "選擇使用模式",
            ["PhotoMode"] = "照片模式",
            ["PhotoModeDesc"] = "RAW · JPEG · HEIF · 拍攝資訊",
            ["VideoMode"] = "看劇模式",
            ["VideoModeDesc"] = "MP4 · MKV · MTS · 字幕切換",
            ["AppTitlePhoto"] = "wphoto — 照片模式",
            ["AppTitleVideo"] = "wphoto — 看劇模式",
            ["FullscreenTip"] = "全螢幕 (F11)",
            ["Scanning"] = "掃描資料夾中…",
            ["PhotoCount"] = "共 {0} 張照片（RAW {1} 張）",
            ["VideoCount"] = "共 {0} 部影片",
            ["NoPhotos"] = "這個資料夾裡沒有支援的照片格式",
            ["NoVideos"] = "這個資料夾裡沒有支援的影片格式",
            ["Loading"] = "讀取中… {0}",
            ["Playing"] = "{0} — 播放中（空白鍵：播放/暫停）",
            ["ZoomPct"] = "縮放 {0}%（雙擊還原）",
            ["Zoom100"] = "縮放 100%",
            ["PickEpisode"] = "選擇要播放的影片（共 {0} 部）",
            ["CantReadPhoto"] = "⚠ 無法讀取這張照片",
            ["ReadFail"] = "⚠ 讀取失敗：{0}",
            ["PlayerNotInit"] = "⚠ 影片播放引擎未初始化，無法播放",
            ["PlayerInitFail"] = "⚠ 影片播放引擎初始化失敗：{0}（照片瀏覽不受影響）",
            ["SubOff"] = "關閉字幕",
            ["SubTrack"] = "字幕軌 {0}",
            ["ExtSubs"] = "外掛字幕",
            ["ExtSubsCount"] = "{0} 個檔案",
            ["AllTypes"] = "全部類型",
            ["FolderDialogTitle"] = "選擇照片資料夾",
            ["VideoBadge"] = "影片",
            ["FileName"] = "檔名",
            ["FileSize"] = "檔案大小",
            ["DisplaySize"] = "顯示尺寸",
            ["Camera"] = "相機",
            ["Make"] = "廠牌",
            ["Lens"] = "鏡頭",
            ["DateTaken"] = "拍攝時間",
            ["ISO"] = "ISO",
            ["Shutter"] = "快門",
            ["Aperture"] = "光圈",
            ["FocalLength"] = "焦距",
            ["FocalLength35"] = "等效焦距(35mm)",
            ["ExposureComp"] = "曝光補償",
            ["ExposureMode"] = "曝光模式",
            ["Metering"] = "測光模式",
            ["WhiteBalance"] = "白平衡",
            ["Flash"] = "閃光燈",
            ["ColorSpace"] = "色彩空間",
            ["Software"] = "軟體",
            ["ImageSize"] = "影像尺寸",
            ["GPS"] = "GPS",
            ["Duration"] = "時長",
            ["Resolution"] = "解析度",
            ["FrameRate"] = "影格率",
            ["VideoCodec"] = "視訊編碼",
            ["AudioCodec"] = "音訊編碼",
            ["AudioInfo"] = "音訊",
            ["AudioFmt"] = "{0} 聲道 / {1} Hz",
        },
        [ZhHans] = new()
        {
            ["ChooseFolder"] = "选择文件夹",
            ["NoFolderHint"] = "尚未选择文件夹（也可以直接把文件夹拖进窗口）",
            ["Subtitle"] = "字幕",
            ["Episodes"] = "选集",
            ["Gallery"] = "缩略图总览",
            ["PickPhoto"] = "点选缩略图查看照片（共 {0} 张）",
            ["SwitchMode"] = "切换模式",
            ["ShootingInfo"] = "拍摄信息",
            ["KeyParams"] = "主要参数",
            ["PlaceholderPhoto"] = "选择文件夹开始浏览照片",
            ["PlaceholderVideo"] = "选择文件夹开始看剧",
            ["ChooseMode"] = "选择使用模式",
            ["PhotoMode"] = "照片模式",
            ["PhotoModeDesc"] = "RAW · JPEG · HEIF · 拍摄信息",
            ["VideoMode"] = "看剧模式",
            ["VideoModeDesc"] = "MP4 · MKV · MTS · 字幕切换",
            ["AppTitlePhoto"] = "wphoto — 照片模式",
            ["AppTitleVideo"] = "wphoto — 看剧模式",
            ["FullscreenTip"] = "全屏 (F11)",
            ["Scanning"] = "正在扫描文件夹…",
            ["PhotoCount"] = "共 {0} 张照片（RAW {1} 张）",
            ["VideoCount"] = "共 {0} 个视频",
            ["NoPhotos"] = "这个文件夹里没有支持的照片格式",
            ["NoVideos"] = "这个文件夹里没有支持的视频格式",
            ["Loading"] = "正在读取… {0}",
            ["Playing"] = "{0} — 播放中（空格键：播放/暂停）",
            ["ZoomPct"] = "缩放 {0}%（双击还原）",
            ["Zoom100"] = "缩放 100%",
            ["PickEpisode"] = "选择要播放的视频（共 {0} 个）",
            ["CantReadPhoto"] = "⚠ 无法读取这张照片",
            ["ReadFail"] = "⚠ 读取失败：{0}",
            ["PlayerNotInit"] = "⚠ 视频播放引擎未初始化，无法播放",
            ["PlayerInitFail"] = "⚠ 视频播放引擎初始化失败：{0}（照片浏览不受影响）",
            ["SubOff"] = "关闭字幕",
            ["SubTrack"] = "字幕轨 {0}",
            ["ExtSubs"] = "外挂字幕",
            ["ExtSubsCount"] = "{0} 个文件",
            ["AllTypes"] = "全部类型",
            ["FolderDialogTitle"] = "选择照片文件夹",
            ["VideoBadge"] = "视频",
            ["FileName"] = "文件名",
            ["FileSize"] = "文件大小",
            ["DisplaySize"] = "显示尺寸",
            ["Camera"] = "相机",
            ["Make"] = "品牌",
            ["Lens"] = "镜头",
            ["DateTaken"] = "拍摄时间",
            ["ISO"] = "ISO",
            ["Shutter"] = "快门",
            ["Aperture"] = "光圈",
            ["FocalLength"] = "焦距",
            ["FocalLength35"] = "等效焦距(35mm)",
            ["ExposureComp"] = "曝光补偿",
            ["ExposureMode"] = "曝光模式",
            ["Metering"] = "测光模式",
            ["WhiteBalance"] = "白平衡",
            ["Flash"] = "闪光灯",
            ["ColorSpace"] = "色彩空间",
            ["Software"] = "软件",
            ["ImageSize"] = "图像尺寸",
            ["GPS"] = "GPS",
            ["Duration"] = "时长",
            ["Resolution"] = "分辨率",
            ["FrameRate"] = "帧率",
            ["VideoCodec"] = "视频编码",
            ["AudioCodec"] = "音频编码",
            ["AudioInfo"] = "音频",
            ["AudioFmt"] = "{0} 声道 / {1} Hz",
        },
        [En] = new()
        {
            ["ChooseFolder"] = "Choose Folder",
            ["NoFolderHint"] = "No folder selected (you can also drag a folder onto the window)",
            ["Subtitle"] = "Subtitles",
            ["Episodes"] = "Episodes",
            ["Gallery"] = "Gallery",
            ["PickPhoto"] = "Click a thumbnail to view ({0} photos)",
            ["SwitchMode"] = "Switch Mode",
            ["ShootingInfo"] = "Shooting Info",
            ["KeyParams"] = "Key Parameters",
            ["PlaceholderPhoto"] = "Choose a folder to browse photos",
            ["PlaceholderVideo"] = "Choose a folder to start watching",
            ["ChooseMode"] = "Choose a mode",
            ["PhotoMode"] = "Photo Mode",
            ["PhotoModeDesc"] = "RAW · JPEG · HEIF · EXIF info",
            ["VideoMode"] = "Theater Mode",
            ["VideoModeDesc"] = "MP4 · MKV · MTS · Subtitles",
            ["AppTitlePhoto"] = "wphoto — Photo Mode",
            ["AppTitleVideo"] = "wphoto — Theater Mode",
            ["FullscreenTip"] = "Fullscreen (F11)",
            ["Scanning"] = "Scanning folder…",
            ["PhotoCount"] = "{0} photos ({1} RAW)",
            ["VideoCount"] = "{0} videos",
            ["NoPhotos"] = "No supported photos in this folder",
            ["NoVideos"] = "No supported videos in this folder",
            ["Loading"] = "Loading… {0}",
            ["Playing"] = "{0} — playing (Space: play/pause)",
            ["ZoomPct"] = "Zoom {0}% (double-click to reset)",
            ["Zoom100"] = "Zoom 100%",
            ["PickEpisode"] = "Pick a video to play ({0} total)",
            ["CantReadPhoto"] = "⚠ Cannot read this photo",
            ["ReadFail"] = "⚠ Read failed: {0}",
            ["PlayerNotInit"] = "⚠ Video engine not initialized",
            ["PlayerInitFail"] = "⚠ Video engine init failed: {0} (photo browsing unaffected)",
            ["SubOff"] = "Subtitles off",
            ["SubTrack"] = "Track {0}",
            ["ExtSubs"] = "External subs",
            ["ExtSubsCount"] = "{0} file(s)",
            ["AllTypes"] = "All types",
            ["FolderDialogTitle"] = "Choose a photo folder",
            ["VideoBadge"] = "VIDEO",
            ["FileName"] = "File name",
            ["FileSize"] = "File size",
            ["DisplaySize"] = "Display size",
            ["Camera"] = "Camera",
            ["Make"] = "Make",
            ["Lens"] = "Lens",
            ["DateTaken"] = "Date taken",
            ["ISO"] = "ISO",
            ["Shutter"] = "Shutter",
            ["Aperture"] = "Aperture",
            ["FocalLength"] = "Focal length",
            ["FocalLength35"] = "35mm equiv.",
            ["ExposureComp"] = "Exposure comp.",
            ["ExposureMode"] = "Exposure program",
            ["Metering"] = "Metering",
            ["WhiteBalance"] = "White balance",
            ["Flash"] = "Flash",
            ["ColorSpace"] = "Color space",
            ["Software"] = "Software",
            ["ImageSize"] = "Image size",
            ["GPS"] = "GPS",
            ["Duration"] = "Duration",
            ["Resolution"] = "Resolution",
            ["FrameRate"] = "Frame rate",
            ["VideoCodec"] = "Video codec",
            ["AudioCodec"] = "Audio codec",
            ["AudioInfo"] = "Audio",
            ["AudioFmt"] = "{0} ch / {1} Hz",
        },
    };
}
