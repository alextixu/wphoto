using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace PhotoViewer;

/// <summary>開過的資料夾（照片、看劇兩個模式各自記）</summary>
public sealed class RecentLocation
{
    public string Path { get; set; } = "";
    [JsonConverter(typeof(JsonStringEnumConverter))]
    public MainWindow.AppMode Mode { get; set; }
    public DateTime LastOpened { get; set; }
}

/// <summary>
/// 首頁的「最近位置」。存在 %LOCALAPPDATA%\wphoto\recent-locations.json。
/// 只記路徑字串：啟動時不檢查資料夾還在不在，NAS 沒連線也不會卡住；使用者點了才開。
/// </summary>
public static class RecentLocations
{
    /// <summary>最多記住幾個位置</summary>
    const int MaxSaved = 30;

    static string FilePath =>
        System.IO.Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "wphoto", "recent-locations.json");

    static List<RecentLocation>? _items;
    static List<RecentLocation> Items => _items ??= Load();

    /// <summary>最近開的在前</summary>
    public static IReadOnlyList<RecentLocation> All => Items;

    static List<RecentLocation> Load()
    {
        try
        {
            if (File.Exists(FilePath))
                return (JsonSerializer.Deserialize<List<RecentLocation>>(File.ReadAllText(FilePath)) ?? new())
                    .Where(r => !string.IsNullOrEmpty(r.Path))
                    .OrderByDescending(r => r.LastOpened)
                    .ToList();
        }
        catch { }
        return new();
    }

    /// <summary>路徑正規化：去掉結尾的斜線（磁碟根目錄 Z:\ 保留），純字串運算</summary>
    static string Normalize(string path)
    {
        try { return System.IO.Path.TrimEndingDirectorySeparator(System.IO.Path.GetFullPath(path)); }
        catch { return path; }
    }

    /// <summary>開過的資料夾記到最前面（同一個模式的同一個資料夾只留一筆）</summary>
    public static void Remember(string path, MainWindow.AppMode mode)
    {
        string p = Normalize(path);
        Items.RemoveAll(r => r.Mode == mode && string.Equals(r.Path, p, StringComparison.OrdinalIgnoreCase));
        Items.Insert(0, new RecentLocation { Path = p, Mode = mode, LastOpened = DateTime.UtcNow });
        if (Items.Count > MaxSaved)
            Items.RemoveRange(MaxSaved, Items.Count - MaxSaved);
        Save();
    }

    public static void Remove(string path, MainWindow.AppMode mode)
    {
        if (Items.RemoveAll(r => r.Mode == mode && string.Equals(r.Path, path, StringComparison.OrdinalIgnoreCase)) > 0)
            Save();
    }

    static void Save()
    {
        try
        {
            Directory.CreateDirectory(System.IO.Path.GetDirectoryName(FilePath)!);
            string tmp = FilePath + ".tmp";
            File.WriteAllText(tmp, JsonSerializer.Serialize(Items));
            File.Move(tmp, FilePath, overwrite: true);
        }
        catch { }
    }
}
