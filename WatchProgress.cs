using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text.Json;
using System.Text.Json.Serialization;
using System.Threading.Tasks;
using System.Windows.Threading;

namespace PhotoViewer;

/// <summary>一部影片看到哪裡（watch-progress.json 裡的一筆）</summary>
public sealed class WatchEntry
{
    /// <summary>影片檔完整路徑，也是 key（不分大小寫）</summary>
    public string Path { get; set; } = "";
    public string FileName { get; set; } = "";
    public long PositionMs { get; set; }
    public long DurationMs { get; set; }
    public DateTime UpdatedAt { get; set; }
    /// <summary>曾經看到最後 5%：卡片打勾（之後重看一小段也不會不見）</summary>
    public bool Watched { get; set; }
    /// <summary>影片是從哪個位置開的，以及從那裡點進去的子資料夾（首頁「繼續觀看」開回同一層用）</summary>
    public string? LocationPath { get; set; }
    public List<string>? Subfolders { get; set; }

    [JsonIgnore]
    public double Fraction => DurationMs > 0 ? Math.Clamp((double)PositionMs / DurationMs, 0, 1) : 0;

    /// <summary>停在最後 5%：算看完，下次從頭播</summary>
    [JsonIgnore]
    public bool IsAtEnd => DurationMs > 0 && PositionMs >= DurationMs * (1 - WatchProgress.EndFraction);

    /// <summary>看了 30 秒以上、還沒看到最後 5%：下次從這裡繼續</summary>
    [JsonIgnore]
    public bool IsResumable => PositionMs >= WatchProgress.MinResumeMs && !IsAtEnd;
}

/// <summary>
/// 看劇模式記住每部影片看到哪裡（規則與 iOS 版 WatchProgressStore 相同）。
/// 續播、影片卡片的進度條與打勾、首頁的「繼續觀看」都讀這裡。
/// 存在 %LOCALAPPDATA%\wphoto\watch-progress.json，只記路徑與時間，不碰影片檔。
/// </summary>
public static class WatchProgress
{
    /// <summary>看不到 30 秒的就從頭播（也不記錄）</summary>
    public const long MinResumeMs = 30_000;
    /// <summary>看到最後 5% 的就從頭播（並且打勾）</summary>
    public const double EndFraction = 0.05;
    /// <summary>最多記住幾部影片（最近看的優先保留）</summary>
    const int MaxEntries = 500;

    static string FilePath =>
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "wphoto", "watch-progress.json");

    static Dictionary<string, WatchEntry>? _entries;
    static Dictionary<string, WatchEntry> Entries => _entries ??= Load();

    static DispatcherTimer? _saveTimer;
    static readonly object WriteLock = new();
    static int _writeSeq, _writtenSeq;

    static Dictionary<string, WatchEntry> Load()
    {
        var map = new Dictionary<string, WatchEntry>(StringComparer.OrdinalIgnoreCase);
        try
        {
            if (File.Exists(FilePath))
            {
                var list = JsonSerializer.Deserialize<List<WatchEntry>>(File.ReadAllText(FilePath));
                foreach (var e in list ?? new())
                    if (!string.IsNullOrEmpty(e.Path) &&
                        (!map.TryGetValue(e.Path, out var old) || e.UpdatedAt > old.UpdatedAt))
                        map[e.Path] = e;
            }
        }
        catch { } // 檔案壞了就當作沒有紀錄，不影響播放
        return map;
    }

    /// <summary>路徑正規化（純字串運算，不會碰磁碟或網路）</summary>
    public static string Key(string path)
    {
        try { return Path.GetFullPath(path); }
        catch { return path; }
    }

    public static WatchEntry? Get(string path) => Entries.TryGetValue(Key(path), out var e) ? e : null;

    /// <summary>續播位置（毫秒）；看不到 30 秒或已看到最後 5% 回傳 null（從頭播）</summary>
    public static long? ResumePositionMs(string path) => Get(path) is { IsResumable: true } e ? e.PositionMs : null;

    /// <summary>首頁「繼續觀看」：還沒看完的，最近看的在前</summary>
    public static List<WatchEntry> ContinueWatching =>
        Entries.Values.Where(e => e.IsResumable).OrderByDescending(e => e.UpdatedAt).ToList();

    /// <summary>播放中定時回報、停止或換片時再回報一次</summary>
    public static void Record(string path, long positionMs, long durationMs, string? locationPath, List<string>? subfolders)
    {
        string key = Key(path);
        Entries.TryGetValue(key, out var entry);
        // 沒有紀錄、又看不到 30 秒：只是點開看一下，不記（不會出現在「繼續觀看」）
        if (entry == null && positionMs < MinResumeMs)
            return;
        positionMs = Math.Max(0, positionMs);
        // 暫停中：位置沒變就不必重寫
        if (entry != null && entry.PositionMs == positionMs && (durationMs <= 0 || entry.DurationMs == durationMs))
            return;

        entry ??= new WatchEntry { Path = key, FileName = Path.GetFileName(key) };
        entry.PositionMs = positionMs;
        if (durationMs > 0)
            entry.DurationMs = durationMs;
        entry.UpdatedAt = DateTime.UtcNow;
        if (entry.IsAtEnd)
            entry.Watched = true;
        if (locationPath != null)
        {
            entry.LocationPath = locationPath;
            entry.Subfolders = subfolders;
        }
        Entries[key] = entry;
        ScheduleSave();
    }

    /// <summary>從「繼續觀看」移除（影片的看完標記保留）</summary>
    public static void RemoveFromContinueWatching(string path)
    {
        if (!Entries.TryGetValue(Key(path), out var entry))
            return;
        entry.PositionMs = 0;
        ScheduleSave();
    }

    /// <summary>延遲 1 秒再寫入：播放中每 5 秒回報一次，不必每次都寫</summary>
    static void ScheduleSave()
    {
        if (_saveTimer == null)
        {
            _saveTimer = new DispatcherTimer { Interval = TimeSpan.FromSeconds(1) };
            _saveTimer.Tick += (_, _) => Save(sync: false);
        }
        _saveTimer.Stop();
        _saveTimer.Start();
    }

    /// <summary>立刻寫入（關閉視窗時）：還沒寫、或背景還在寫的內容，都在這裡同步寫完</summary>
    public static void Flush()
    {
        if (_saveTimer?.IsEnabled == true || _writtenSeq < _writeSeq)
            Save(sync: true);
    }

    static void Save(bool sync)
    {
        _saveTimer?.Stop();
        if (_entries == null)
            return;
        var list = _entries.Values.OrderByDescending(e => e.UpdatedAt).ToList();
        if (list.Count > MaxEntries)
        {
            list.RemoveRange(MaxEntries, list.Count - MaxEntries);
            _entries = list.ToDictionary(e => e.Path, StringComparer.OrdinalIgnoreCase);
        }
        string json = JsonSerializer.Serialize(list);
        int seq = ++_writeSeq;
        if (sync)
            Write(json, seq);
        else
            Task.Run(() => Write(json, seq)); // 寫檔放背景，播放中不卡畫面
    }

    /// <summary>先寫暫存檔再換名，寫到一半當機也不會留下壞檔；較舊的內容不會蓋過較新的</summary>
    static void Write(string json, int seq)
    {
        lock (WriteLock)
        {
            if (seq <= _writtenSeq)
                return;
            try
            {
                Directory.CreateDirectory(Path.GetDirectoryName(FilePath)!);
                string tmp = FilePath + ".tmp";
                File.WriteAllText(tmp, json);
                File.Move(tmp, FilePath, overwrite: true);
                _writtenSeq = seq;
            }
            catch { }
        }
    }
}
