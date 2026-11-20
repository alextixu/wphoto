using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Runtime.InteropServices;
using System.Text.RegularExpressions;
using System.Windows;
using System.Windows.Media.Imaging;

namespace PhotoViewer;

/// <summary>看劇模式讀到的一層資料夾：子資料夾＋影片；圖片不列出，只留給海報牆找封面</summary>
public sealed class FolderListing
{
    public List<string> Folders { get; } = new();
    public List<string> Videos { get; } = new();
    public List<string> Images { get; } = new();
}

/// <summary>
/// 看劇模式一層一層瀏覽資料夾（與 iOS 版 FolderSession 相同）：每次只讀目前這一層，
/// NAS 上有幾百部電影的資料夾也能很快打開；子資料夾顯示成海報牆。
/// </summary>
public static class TheaterLibrary
{
    /// <summary>不列出的資料夾：字幕資料夾（播放時會自動去裡面找字幕）、NAS 與 Windows 的系統資料夾</summary>
    static readonly HashSet<string> SkippedFolders = new(StringComparer.OrdinalIgnoreCase)
    {
        "subs", "subtitles", "@eaDir", "#recycle", "#snapshot", "$RECYCLE.BIN", "System Volume Information",
    };

    static readonly HashSet<string> CoverExts = new(StringComparer.OrdinalIgnoreCase)
    {
        ".jpg", ".jpeg", ".png", ".bmp", ".webp",
    };

    /// <summary>封面檔名的優先順序</summary>
    static readonly string[] CoverNames = { "poster", "folder", "cover", "fanart" };

    /// <summary>只讀這一層（讀不到時回傳 null，例如 NAS 斷線、資料夾被刪掉）</summary>
    public static FolderListing? List(string dir)
    {
        try
        {
            var result = new FolderListing();
            // EnumerateFileSystemInfos 一次就拿到名稱與屬性，NAS 上不必每個項目再問一次
            foreach (var info in new DirectoryInfo(dir).EnumerateFileSystemInfos())
            {
                if ((info.Attributes & (FileAttributes.Hidden | FileAttributes.System)) != 0 || info.Name.StartsWith('.'))
                    continue;
                if (info is DirectoryInfo)
                {
                    if (!SkippedFolders.Contains(info.Name))
                        result.Folders.Add(info.FullName);
                }
                else if (ImageLoader.IsVideo(info.FullName))
                    result.Videos.Add(info.FullName);
                else if (CoverExts.Contains(info.Extension))
                    result.Images.Add(info.FullName);
            }
            // 與檔案總管相同的自然排序：第 2 集排在第 10 集前面
            result.Folders.Sort(NaturalComparer.Instance);
            result.Videos.Sort(NaturalComparer.Instance);
            return result;
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException or System.Security.SecurityException or ArgumentException)
        {
            return null;
        }
    }

    /// <summary>封面：poster → folder → cover → fanart；也認 Kodi 的「片名-poster.jpg」。都沒有回傳 null（用佔位圖）</summary>
    public static string? FindCover(FolderListing listing)
    {
        static string Base(string p) => Path.GetFileNameWithoutExtension(p);
        foreach (var name in CoverNames)
            if (listing.Images.FirstOrDefault(p => Base(p).Equals(name, StringComparison.OrdinalIgnoreCase)) is { } hit)
                return hit;
        foreach (var name in CoverNames)
            if (listing.Images.FirstOrDefault(p => Base(p).EndsWith("-" + name, StringComparison.OrdinalIgnoreCase)) is { } hit)
                return hit;
        return null;
    }

    /// <summary>「片名 (年份)」：片名後接四位數年份（19xx／20xx）括號收尾</summary>
    static readonly Regex YearPattern = new(@"^(.*?)\s*\(((?:19|20)\d{2})\)\s*$", RegexOptions.CultureInvariant);

    /// <summary>「Alpha (2024)」→ 片名「Alpha」＋年份「2024」；沒有年份就整個當片名</summary>
    public static (string Title, string? Year) SplitTitle(string name)
    {
        var m = YearPattern.Match(name);
        // 整個名字只有「(2024)」：沒片名可拆，照原樣顯示
        if (!m.Success || m.Groups[1].Value.Length == 0)
            return (name, null);
        return (m.Groups[1].Value, m.Groups[2].Value);
    }

    /// <summary>資料夾顯示名稱：磁碟根目錄（Z:\）沒有名稱，直接顯示路徑</summary>
    public static string DisplayName(string dir)
    {
        string name = Path.GetFileName(Path.TrimEndingDirectorySeparator(dir));
        return string.IsNullOrEmpty(name) ? dir : name;
    }
}

/// <summary>檔案總管的排序方式（數字依大小比，不依字元比）</summary>
public sealed class NaturalComparer : IComparer<string>
{
    public static readonly NaturalComparer Instance = new();

    [DllImport("shlwapi.dll", CharSet = CharSet.Unicode, ExactSpelling = true)]
    static extern int StrCmpLogicalW(string x, string y);

    public int Compare(string? x, string? y) => StrCmpLogicalW(x ?? "", y ?? "");
}

/// <summary>海報牆的一格：子資料夾的 2:3 海報＋片名＋年份</summary>
public sealed class PosterItem : INotifyPropertyChanged
{
    public string Path { get; }
    public string Name { get; }
    public string Title { get; }
    public string? Year { get; }
    /// <summary>沒封面時佔位圖上的襯線首字</summary>
    public string Initial { get; }

    public PosterItem(string path)
    {
        Path = path;
        Name = TheaterLibrary.DisplayName(path);
        (Title, Year) = TheaterLibrary.SplitTitle(Name);
        // 以「字」為單位取第一個（emoji、罕用字可能佔兩個 char）
        var first = StringInfo.GetNextTextElement(Title);
        Initial = first.ToUpper(CultureInfo.CurrentCulture);
    }

    public Visibility YearVisibility => Year != null ? Visibility.Visible : Visibility.Collapsed;

    BitmapSource? _image;
    public BitmapSource? Image
    {
        get => _image;
        set { _image = value; Raise(nameof(Image)); Raise(nameof(PlaceholderVisibility)); }
    }

    bool _finished;
    /// <summary>封面找完了（不論有沒有）：還沒找完先留空，才不會先閃一下佔位再換成封面</summary>
    public bool Finished
    {
        get => _finished;
        set { _finished = value; Raise(nameof(PlaceholderVisibility)); }
    }

    public Visibility PlaceholderVisibility => _finished && _image == null ? Visibility.Visible : Visibility.Collapsed;

    public event PropertyChangedEventHandler? PropertyChanged;
    void Raise(string name) => PropertyChanged?.Invoke(this, new(name));
}
