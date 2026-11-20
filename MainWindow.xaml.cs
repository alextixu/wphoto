using System;
using System.Collections.Generic;
using System.Collections.ObjectModel;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media.Imaging;
using LibVLCSharp.Shared;
using Microsoft.Win32;

namespace PhotoViewer;

public class FileItem
{
    public required string Path { get; init; }
    public required string Root { get; init; }
    /// <summary>清單顯示用：相對於所選資料夾的路徑（子資料夾的檔案會顯示「子資料夾\檔名」）</summary>
    public string Name => System.IO.Path.GetRelativePath(Root, Path);
    public bool IsRaw => ImageLoader.IsRaw(Path);
    public bool IsVideo => ImageLoader.IsVideo(Path);
    public Visibility RawBadgeVisibility => IsRaw ? Visibility.Visible : Visibility.Collapsed;
    public Visibility VideoBadgeVisibility => IsVideo ? Visibility.Visible : Visibility.Collapsed;
}

public class EpisodeItem : System.ComponentModel.INotifyPropertyChanged
{
    public required string Path { get; init; }
    public required string Name { get; init; }
    public bool IsRaw => ImageLoader.IsRaw(Path);
    public bool IsVideo => ImageLoader.IsVideo(Path);
    public Visibility RawBadgeVisibility => IsRaw ? Visibility.Visible : Visibility.Collapsed;

    /// <summary>影片卡片的標題不帶副檔名；格式改放到第二行</summary>
    public string Title => System.IO.Path.GetFileNameWithoutExtension(Name);

    /// <summary>第二行「MKV · 1:30:00」：看過的影片才知道時長，沒看過只顯示格式</summary>
    public string Subtitle
    {
        get
        {
            string ext = System.IO.Path.GetExtension(Path).TrimStart('.').ToUpperInvariant();
            return _watch is { DurationMs: > 0 } w ? $"{ext} · {MainWindow.FmtShort(w.DurationMs)}" : ext;
        }
    }

    System.Windows.Media.Imaging.BitmapSource? _thumb;
    public System.Windows.Media.Imaging.BitmapSource? Thumb
    {
        get => _thumb;
        set { _thumb = value; Raise(nameof(Thumb)); Raise(nameof(ThumbVisibility)); }
    }

    /// <summary>有畫面才壓暗底部（進度條疊在亮畫面上也看得清）</summary>
    public Visibility ThumbVisibility => _thumb != null ? Visibility.Visible : Visibility.Collapsed;

    // ---------- 看到哪裡（看劇模式） ----------
    WatchEntry? _watch;

    /// <summary>重新讀播放進度（回到選集畫面時更新進度條與打勾）</summary>
    public void RefreshWatch()
    {
        _watch = WatchProgress.Get(Path);
        Raise(nameof(Subtitle));
        Raise(nameof(ProgressVisibility));
        Raise(nameof(ProgressDone));
        Raise(nameof(ProgressRest));
        Raise(nameof(WatchedVisibility));
    }

    public Visibility ProgressVisibility => _watch?.IsResumable == true ? Visibility.Visible : Visibility.Collapsed;
    public GridLength ProgressDone => new(_watch?.Fraction ?? 0, GridUnitType.Star);
    public GridLength ProgressRest => new(1 - (_watch?.Fraction ?? 0), GridUnitType.Star);
    public Visibility WatchedVisibility => _watch?.Watched == true ? Visibility.Visible : Visibility.Collapsed;

    public event System.ComponentModel.PropertyChangedEventHandler? PropertyChanged;
    void Raise(string name) => PropertyChanged?.Invoke(this, new(name));
}

/// <summary>首頁「繼續觀看」的一列</summary>
public class ContinueRowItem
{
    public required WatchEntry Entry { get; init; }
    public string Title => Entry.FileName;
    /// <summary>「位置 › 子資料夾 · 12:34 / 45:00」</summary>
    public string Detail
    {
        get
        {
            string time = MainWindow.FmtShort(Entry.PositionMs);
            if (Entry.DurationMs > 0)
                time += " / " + MainWindow.FmtShort(Entry.DurationMs);
            if (Entry.LocationPath == null)
                return time;
            var parts = new List<string> { TheaterLibrary.DisplayName(Entry.LocationPath) };
            if (Entry.Subfolders != null)
                parts.AddRange(Entry.Subfolders);
            return $"{string.Join(" › ", parts)} · {time}";
        }
    }
    public GridLength ProgressDone => new(Entry.Fraction, GridUnitType.Star);
    public GridLength ProgressRest => new(1 - Entry.Fraction, GridUnitType.Star);
}

/// <summary>首頁「最近位置」的一列</summary>
public class RecentRowItem
{
    public required RecentLocation Location { get; init; }
    public bool IsFirst { get; init; }
    public string Name => TheaterLibrary.DisplayName(Location.Path);
    public Wpf.Ui.Controls.SymbolRegular Symbol => Location.Mode == MainWindow.AppMode.Photo
        ? Wpf.Ui.Controls.SymbolRegular.ImageMultiple24
        : Wpf.Ui.Controls.SymbolRegular.Filmstrip24;
    public Visibility SeparatorVisibility => IsFirst ? Visibility.Collapsed : Visibility.Visible;

    /// <summary>「上一層資料夾 · 3 天前」：兩個同名的資料夾靠上一層分辨；在磁碟根目錄（沒有上一層）時退回「看劇模式 · 3 天前」。
    /// 只做字串運算，不會去讀資料夾（NAS 沒連線也不會卡）</summary>
    public string Detail
    {
        get
        {
            string when = Loc.RelativeTime(Location.LastOpened);
            string? parentDir = System.IO.Path.GetDirectoryName(Location.Path);
            string parent = parentDir == null ? "" : System.IO.Path.GetFileName(System.IO.Path.TrimEndingDirectorySeparator(parentDir));
            if (string.IsNullOrEmpty(parent))
                parent = Loc.T(Location.Mode == MainWindow.AppMode.Photo ? "PhotoMode" : "VideoMode");
            return $"{parent} · {when}";
        }
    }
}

public partial class MainWindow : Wpf.Ui.Controls.FluentWindow
{
    readonly ObservableCollection<FileItem> _files = new();
    int _loadToken;
    LibVLC? _libVLC;
    MediaPlayer? _player;
    Media? _currentMedia;

    public enum AppMode { Photo, Video }

    AppMode _mode = AppMode.Photo;
    string? _pendingFolder;

    readonly ObservableCollection<EpisodeItem> _episodes = new();
    int _thumbToken;

    bool _suppressLangEvent;

    /// <summary>首頁最多列幾筆</summary>
    const int MaxContinueRows = 5;
    const int MaxRecentRows = 6;

    public MainWindow()
    {
        InitializeComponent();
        FileList.ItemsSource = _files;
        EpisodeList.ItemsSource = _episodes;
        PhotoGridList.ItemsSource = _episodes;
        PosterList.ItemsSource = _posters;

        // 語言選單反映目前語言（Loc.Init 已在 App 啟動時執行）
        _suppressLangEvent = true;
        foreach (ComboBoxItem it in LangSelect.Items)
            if ((string)it.Tag == Loc.Current)
                LangSelect.SelectedItem = it;
        _suppressLangEvent = false;

        // LibVLC 不在啟動時初始化（載入 400+ 外掛在 HDD 上要數秒）；進看劇模式才在背景載入

        var args = Environment.GetCommandLineArgs();
        if (args.Length > 1 && System.IO.Directory.Exists(args[1]))
            _pendingFolder = args[1]; // 等使用者選完模式再開

        RefreshHome(); // 只讀本機的 JSON，不會去開任何資料夾
    }

    void LangSelect_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (_suppressLangEvent || LangSelect.SelectedItem is not ComboBoxItem it)
            return;
        Loc.Apply((string)it.Tag);

        // DynamicResource 綁定的文字會自動更新；由程式碼設定的文字手動刷新
        if (ModeOverlay.Visibility != Visibility.Visible)
        {
            AppTitleBar.Title = Loc.T(_mode == AppMode.Photo ? "AppTitlePhoto" : "AppTitleVideo");
            EpisodesBtn.Content = Loc.T(_mode == AppMode.Photo ? "Gallery" : "Episodes");
            if (MainImage.Source == null && !VideoActive)
                PlaceholderText.Text = Loc.T(_mode == AppMode.Photo ? "PlaceholderPhoto" : "PlaceholderVideo");
            if (GalleryHost.Visibility == Visibility.Visible)
                UpdatePickerStatus();
        }
        if (_allPaths.Count == 0 && _theaterStack.Count == 0)
            FolderLabel.Text = Loc.T("NoFolderHint");
        RefreshHome(); // 「3 天前」等相對時間由程式碼組字

        // 類型下拉選單的「全部」項目換語言重建（保留目前選擇位置）
        if (TypeFilter.ItemsSource is List<string> old && old.Count > 0)
        {
            int idx = TypeFilter.SelectedIndex;
            var rebuilt = new List<string>(old) { [0] = FilterAll };
            _suppressFilterEvent = true;
            TypeFilter.ItemsSource = rebuilt;
            TypeFilter.SelectedIndex = idx;
            _suppressFilterEvent = false;
        }
    }

    void OverlayLang_Click(object sender, RoutedEventArgs e)
    {
        if ((sender as FrameworkElement)?.Tag is not string lang)
            return;
        foreach (ComboBoxItem it in LangSelect.Items)
            if ((string)it.Tag == lang)
                LangSelect.SelectedItem = it; // 觸發 LangSelect_SelectionChanged → Loc.Apply
    }

    void PhotoMode_Click(object sender, RoutedEventArgs e) => StartMode(AppMode.Photo);
    void VideoMode_Click(object sender, RoutedEventArgs e) => StartMode(AppMode.Video);

    void StartMode(AppMode mode)
    {
        _mode = mode;
        AppTitleBar.Title = Loc.T(mode == AppMode.Photo ? "AppTitlePhoto" : "AppTitleVideo");
        PlaceholderText.Text = Loc.T(mode == AppMode.Photo ? "PlaceholderPhoto" : "PlaceholderVideo");
        EpisodesBtn.Content = Loc.T(mode == AppMode.Photo ? "Gallery" : "Episodes");
        ModeOverlay.Visibility = Visibility.Collapsed;
        if (mode == AppMode.Video)
            _ = EnsurePlayerAsync(); // 使用者選資料夾的同時在背景載入播放引擎

        if (_pendingFolder != null)
        {
            string f = _pendingFolder;
            _pendingFolder = null;
            OpenFolder(f);
        }
    }

    void SwitchMode_Click(object sender, RoutedEventArgs e)
    {
        _loadToken++;
        _scanToken++;
        _thumbToken++;
        _posterToken++;
        StopVideo();
        _episodes.Clear();
        _posters.Clear();
        _theaterStack.Clear();
        _listings.Clear();
        _posterCache.Clear();
        HideGallery();
        EpisodesBtn.Visibility = Visibility.Collapsed;
        _files.Clear();
        _allPaths.Clear();
        TypeFilter.ItemsSource = null;
        MainImage.Source = null;
        MainImage.Visibility = Visibility.Visible;
        PlaceholderText.Visibility = Visibility.Visible;
        ClearInfo();
        FolderLabel.Text = Loc.T("NoFolderHint");
        StatusLabel.Text = "";
        RefreshHome(); // 剛看過的影片出現在「繼續觀看」
        ModeOverlay.Visibility = Visibility.Visible;
    }

    // ---------- 首頁：繼續觀看、最近位置 ----------

    /// <summary>重建首頁的兩份清單。只讀本機的 JSON，不檢查路徑還在不在（避免啟動時連 NAS）</summary>
    void RefreshHome()
    {
        var cont = WatchProgress.ContinueWatching.Take(MaxContinueRows)
            .Select(entry => new ContinueRowItem { Entry = entry }).ToList();
        ContinueList.ItemsSource = cont;
        ContinueSection.Visibility = cont.Count > 0 ? Visibility.Visible : Visibility.Collapsed;

        var recents = RecentLocations.All.Take(MaxRecentRows)
            .Select((r, i) => new RecentRowItem { Location = r, IsFirst = i == 0 }).ToList();
        RecentList.ItemsSource = recents;
        RecentSection.Visibility = recents.Count > 0 ? Visibility.Visible : Visibility.Collapsed;

        HomeHint.Visibility = cont.Count == 0 && recents.Count == 0 ? Visibility.Visible : Visibility.Collapsed;
    }

    /// <summary>「繼續觀看」：開回影片所在的位置、進到那一層，從上次的位置繼續播</summary>
    void Continue_Click(object sender, RoutedEventArgs e)
    {
        if ((sender as FrameworkElement)?.Tag is not ContinueRowItem row)
            return;
        var entry = row.Entry;
        _pendingFolder = null; // 使用者點了這一筆：命令列帶進來的資料夾不再自動開
        StartMode(AppMode.Video);
        string root = entry.LocationPath ?? System.IO.Path.GetDirectoryName(entry.Path) ?? entry.Path;
        var subfolders = entry.LocationPath != null && entry.Subfolders != null ? entry.Subfolders : new List<string>();
        OpenTheaterLocation(root, subfolders, playPath: entry.Path);
    }

    /// <summary>「最近位置」：用當時的模式開那個資料夾</summary>
    void Recent_Click(object sender, RoutedEventArgs e)
    {
        if ((sender as FrameworkElement)?.Tag is not RecentRowItem row)
            return;
        _pendingFolder = null;
        StartMode(row.Location.Mode);
        OpenFolder(row.Location.Path);
    }

    void RemoveContinue_Click(object sender, RoutedEventArgs e)
    {
        if ((sender as FrameworkElement)?.Tag is not ContinueRowItem row)
            return;
        WatchProgress.RemoveFromContinueWatching(row.Entry.Path);
        RefreshHome();
    }

    void RemoveRecent_Click(object sender, RoutedEventArgs e)
    {
        if ((sender as FrameworkElement)?.Tag is not RecentRowItem row)
            return;
        RecentLocations.Remove(row.Location.Path, row.Location.Mode);
        RefreshHome();
    }

    Task<bool>? _vlcInitTask;

    /// <summary>確保播放引擎就緒；第一次呼叫時在背景載入 LibVLC（可重複 await）</summary>
    Task<bool> EnsurePlayerAsync() => _vlcInitTask ??= InitVideoPlayerAsync();

    async Task<bool> InitVideoPlayerAsync()
    {
        try
        {
            var libVLC = await Task.Run(() =>
            {
                // 發行時 libvlc 資料夾在 exe 旁邊，明確指定路徑最保險
                string exeDir = System.IO.Path.GetDirectoryName(Environment.ProcessPath!)!;
                string libvlcDir = System.IO.Path.Combine(exeDir, "libvlc", Environment.Is64BitProcess ? "win-x64" : "win-x86");
                if (System.IO.Directory.Exists(libvlcDir))
                    Core.Initialize(libvlcDir);
                else
                    Core.Initialize();
                return new LibVLC(); // 最重的一步（掃描/載入外掛），放背景執行緒
            });
            _libVLC = libVLC;
            _player = new MediaPlayer(_libVLC);
            VideoViewControl.MediaPlayer = _player;
            return true;
        }
        catch (Exception ex)
        {
            StatusLabel.Text = string.Format(Loc.T("PlayerInitFail"), ex.Message);
            return false;
        }
    }

    void StopVideo()
    {
        RecordProgress(); // 停止前記下看到哪裡
        _playingPath = null;
        HideResumeBanner();
        _spuTimer?.Stop();
        _progressTimer?.Stop();
        _hideControlsTimer?.Stop();
        VideoOverlay.Cursor = null;
        var player = _player;
        var media = _currentMedia;
        _currentMedia = null;
        if (player != null && (player.IsPlaying || player.Media != null))
            Task.Run(() =>
            {
                // Stop 在大檔/HDD 上可能耗時數百毫秒，放背景執行緒避免卡 UI
                try { player.Stop(); } catch { }
                media?.Dispose();
            });
        else
            media?.Dispose();
        VideoViewControl.Visibility = Visibility.Collapsed;
        VideoControls.Visibility = Visibility.Collapsed;
        SubtitleLabel.Visibility = Visibility.Collapsed;
        SubtitleSelect.Visibility = Visibility.Collapsed;
        SubtitleSelect.ItemsSource = null;
    }

    // ---------- 播放進度（繼續觀看） ----------
    /// <summary>正在播的影片與它是從哪個位置、哪幾層子資料夾開的</summary>
    string? _playingPath;
    string? _playingRoot;
    List<string>? _playingSubfolders;
    /// <summary>進度計時器最後一次讀到的有效位置（-1 = 還沒開始播）。停止時記這個值，不在停止的瞬間重讀</summary>
    long _lastTimeMs = -1;
    long _lastLengthMs;
    int _recordTicks;
    bool _endRecorded;

    /// <summary>把目前看到的位置交給 WatchProgress（看不到 30 秒的由它決定不記）</summary>
    void RecordProgress()
    {
        if (_playingPath == null || _lastTimeMs <= 0)
            return;
        WatchProgress.Record(_playingPath, _lastTimeMs, _lastLengthMs, _playingRoot, _playingSubfolders);
    }

    System.Windows.Threading.DispatcherTimer? _resumeBannerTimer;

    void ShowResumeBanner(long positionMs)
    {
        ResumeText.Text = string.Format(Loc.T("ResumedFrom"), FmtShort(positionMs));
        ResumeBanner.Visibility = Visibility.Visible;
        if (_resumeBannerTimer == null)
        {
            _resumeBannerTimer = new System.Windows.Threading.DispatcherTimer { Interval = TimeSpan.FromSeconds(6) };
            _resumeBannerTimer.Tick += (_, _) => HideResumeBanner();
        }
        _resumeBannerTimer.Stop();
        _resumeBannerTimer.Start();
    }

    void HideResumeBanner()
    {
        _resumeBannerTimer?.Stop();
        ResumeBanner.Visibility = Visibility.Collapsed;
    }

    void StartOver_Click(object sender, RoutedEventArgs e)
    {
        HideResumeBanner();
        if (!VideoActive) return;
        _player!.Time = 0;
        _lastTimeMs = -1; // 舊的續播位置不要再寫回去
        Keyboard.Focus(VideoOverlay);
    }

    // ---------- 字幕 ----------
    record SubtitleOption(string Name, int SpuId);

    System.Windows.Threading.DispatcherTimer? _spuTimer;
    bool _suppressSubEvent;

    /// <summary>找同資料夾（含 Subs 子資料夾）的外掛字幕檔，同名的排最前</summary>
    static List<string> FindSubtitleFiles(string videoPath)
    {
        var subExts = new[] { ".srt", ".ass", ".ssa", ".sub", ".vtt" };
        string dir = System.IO.Path.GetDirectoryName(videoPath)!;
        string baseName = System.IO.Path.GetFileNameWithoutExtension(videoPath);
        var result = new List<string>();
        try
        {
            IEnumerable<string> candidates = System.IO.Directory.EnumerateFiles(dir);
            string subsDir = System.IO.Path.Combine(dir, "Subs");
            if (System.IO.Directory.Exists(subsDir))
                candidates = candidates.Concat(System.IO.Directory.EnumerateFiles(subsDir));
            result = candidates
                .Where(f => subExts.Contains(System.IO.Path.GetExtension(f).ToLowerInvariant()))
                .OrderByDescending(f => System.IO.Path.GetFileNameWithoutExtension(f)
                    .StartsWith(baseName, StringComparison.OrdinalIgnoreCase))
                .Take(15)
                .ToList();
        }
        catch { }
        return result;
    }

    /// <summary>把目前的字幕軌清單（內嵌 + 外掛）填進下拉選單</summary>
    void RefreshSubtitleList(bool force = false)
    {
        if (_player == null || (!force && SubtitleSelect.IsDropDownOpen))
            return;
        var items = _player.SpuDescription
            .Select(t => new SubtitleOption(
                t.Id == -1 ? Loc.T("SubOff")
                           : (string.IsNullOrWhiteSpace(t.Name) ? string.Format(Loc.T("SubTrack"), t.Id) : t.Name!),
                t.Id))
            .ToList();
        _suppressSubEvent = true;
        int current = _player.Spu;
        SubtitleSelect.ItemsSource = items;
        SubtitleSelect.SelectedItem = items.FirstOrDefault(i => i.SpuId == current) ?? items.FirstOrDefault();
        _suppressSubEvent = false;
    }

    void SubtitleSelect_DropDownOpened(object? sender, EventArgs e)
    {
        RefreshSubtitleList(force: true);
    }

    void SubtitleSelect_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (!_suppressSubEvent && _player != null && SubtitleSelect.SelectedItem is SubtitleOption o)
            _player.SetSpu(o.SpuId);
    }

    // ---------- 縮放與平移 ----------
    double _zoom = 1.0;
    System.Windows.Point _dragStart;
    bool _dragging;

    void ResetZoom()
    {
        _zoom = 1.0;
        ImgScale.ScaleX = ImgScale.ScaleY = 1.0;
        ImgPan.X = ImgPan.Y = 0;
    }

    void ZoomHost_MouseWheel(object sender, MouseWheelEventArgs e)
    {
        if (MainImage.Source == null || VideoViewControl.Visibility == Visibility.Visible)
            return;

        double factor = e.Delta > 0 ? 1.25 : 0.8;
        double newZoom = Math.Clamp(_zoom * factor, 1.0, 10.0);
        if (Math.Abs(newZoom - _zoom) < 0.001)
            return;

        // 以游標位置為中心縮放
        var pos = e.GetPosition(ZoomHost);
        double ratio = newZoom / _zoom;
        ImgPan.X = pos.X - (pos.X - ImgPan.X) * ratio;
        ImgPan.Y = pos.Y - (pos.Y - ImgPan.Y) * ratio;
        _zoom = newZoom;
        ImgScale.ScaleX = ImgScale.ScaleY = newZoom;

        if (_zoom <= 1.001)
            ResetZoom();
        StatusLabel.Text = _zoom > 1
            ? string.Format(Loc.T("ZoomPct"), (_zoom * 100).ToString("F0"))
            : Loc.T("Zoom100");
        e.Handled = true;
    }

    void ZoomHost_MouseLeftButtonDown(object sender, MouseButtonEventArgs e)
    {
        if (e.ClickCount == 2)
        {
            ResetZoom();
            StatusLabel.Text = Loc.T("Zoom100");
            return;
        }
        if (_zoom > 1 && MainImage.Source != null)
        {
            _dragging = true;
            _dragStart = e.GetPosition(ZoomHost);
            ZoomHost.CaptureMouse();
            ZoomHost.Cursor = Cursors.SizeAll;
        }
    }

    void ZoomHost_MouseLeftButtonUp(object sender, MouseButtonEventArgs e)
    {
        _dragging = false;
        ZoomHost.ReleaseMouseCapture();
        ZoomHost.Cursor = Cursors.Arrow;
    }

    void ZoomHost_MouseMove(object sender, MouseEventArgs e)
    {
        if (!_dragging)
            return;
        var pos = e.GetPosition(ZoomHost);
        ImgPan.X += pos.X - _dragStart.X;
        ImgPan.Y += pos.Y - _dragStart.Y;
        _dragStart = pos;
    }

    // ---------- 影片控制：進度、倍速、全螢幕 ----------
    System.Windows.Threading.DispatcherTimer? _progressTimer;
    bool _updatingSliderFromTimer;
    bool _fullscreen;
    double _savedLeft, _savedTop, _savedWidth, _savedHeight;
    WindowState _savedState;
    GridLength _savedLeftColWidth, _savedRightColWidth;
    double _savedLeftColMin, _savedRightColMin;

    bool VideoActive => VideoViewControl.Visibility == Visibility.Visible && _player != null;

    static string FmtTime(long ms) => TimeSpan.FromMilliseconds(Math.Max(0, ms)).ToString(@"h\:mm\:ss");

    /// <summary>「12:34」或「1:02:03」（續播提示、首頁、影片卡片用；與 iOS 版相同）</summary>
    public static string FmtShort(long ms)
    {
        var t = TimeSpan.FromMilliseconds(Math.Max(0, ms));
        return t.TotalHours >= 1 ? t.ToString(@"h\:mm\:ss") : t.ToString(@"m\:ss");
    }

    void StartProgressTimer()
    {
        _progressTimer ??= CreateProgressTimer();
        _progressTimer.Start();
    }

    System.Windows.Threading.DispatcherTimer CreateProgressTimer()
    {
        var t = new System.Windows.Threading.DispatcherTimer { Interval = TimeSpan.FromMilliseconds(500) };
        t.Tick += (_, _) =>
        {
            if (!VideoActive) return;
            PlayPauseIcon.Symbol = _player!.IsPlaying
                ? Wpf.Ui.Controls.SymbolRegular.Pause24
                : Wpf.Ui.Controls.SymbolRegular.Play24;
            var state = _player.State;
            // 播到最後：記成看完（之後的停止不再覆寫）
            if (state == VLCState.Ended && _playingPath != null && !_endRecorded && _lastLengthMs > 0)
            {
                _endRecorded = true;
                _lastTimeMs = _lastLengthMs;
                RecordProgress();
                _lastTimeMs = -1;
            }
            long len = _player.Length;
            if (len <= 0) return;
            long time = _player.Time;
            if (_playingPath != null && time > 0 && (state == VLCState.Playing || state == VLCState.Paused))
            {
                _lastTimeMs = time;
                _lastLengthMs = len;
                // 看到哪裡：每 5 秒記一次，停止或換片時再記一次
                if (++_recordTicks % 10 == 0)
                    RecordProgress();
            }
            _updatingSliderFromTimer = true;
            PositionSlider.Maximum = len;
            if (!PositionSlider.IsMouseCaptureWithin)
                PositionSlider.Value = time;
            _updatingSliderFromTimer = false;
            TimeCurrent.Text = FmtTime(time);
            TimeTotal.Text = FmtTime(len);
        };
        return t;
    }

    void PositionSlider_ValueChanged(object sender, RoutedPropertyChangedEventArgs<double> e)
    {
        if (!_updatingSliderFromTimer && VideoActive && _player!.Length > 0)
        {
            _player.Time = (long)e.NewValue;
            TimeCurrent.Text = FmtTime((long)e.NewValue);
        }
    }

    void PlayPause_Click(object sender, RoutedEventArgs e)
    {
        if (VideoActive) _player!.Pause();
    }

    void SpeedSelect_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (_player != null && SpeedSelect.SelectedItem is ContentControl c &&
            float.TryParse(c.Content?.ToString()?.TrimEnd('x'), out float rate))
            _player.SetRate(rate);
    }

    void SeekBy(int seconds)
    {
        if (!VideoActive || _player!.Length <= 0) return;
        _player.Time = Math.Clamp(_player.Time + seconds * 1000L, 0, _player.Length - 500);
    }

    void Fullscreen_Click(object sender, RoutedEventArgs e) => ToggleFullscreen();

    // ---------- YouTube 式控制列自動隱藏（僅全螢幕） ----------
    System.Windows.Threading.DispatcherTimer? _hideControlsTimer;

    void VideoOverlay_MouseMove(object sender, MouseEventArgs e) => ShowVideoControls();

    void VideoOverlay_MouseDown(object sender, MouseButtonEventArgs e)
    {
        // 點影片區把鍵盤焦點收進疊層，Esc / 空白鍵 / 左右鍵才收得到
        Keyboard.Focus(VideoOverlay);
    }

    /// <summary>顯示控制列與滑鼠游標；全螢幕時重新起算自動隱藏</summary>
    void ShowVideoControls()
    {
        if (!VideoActive || EpisodePicker.Visibility == Visibility.Visible) return;
        VideoControls.Visibility = Visibility.Visible;
        VideoOverlay.Cursor = null;
        if (_fullscreen)
        {
            _hideControlsTimer ??= CreateHideControlsTimer();
            _hideControlsTimer.Stop();
            _hideControlsTimer.Start();
        }
    }

    System.Windows.Threading.DispatcherTimer CreateHideControlsTimer()
    {
        var t = new System.Windows.Threading.DispatcherTimer { Interval = TimeSpan.FromMilliseconds(2500) };
        t.Tick += (_, _) =>
        {
            t.Stop();
            // 滑鼠停在控制列上就不藏（跟 YouTube 一樣）
            if (_fullscreen && VideoActive && !VideoControls.IsMouseOver &&
                !SpeedSelect.IsDropDownOpen && !SubtitleSelect.IsDropDownOpen)
            {
                VideoControls.Visibility = Visibility.Collapsed;
                VideoOverlay.Cursor = Cursors.None;
                // 焦點拉回主視窗，Esc 才收得到
                Activate();
            }
        };
        return t;
    }

    void ToggleFullscreen()
    {
        if (!_fullscreen)
        {
            _savedState = WindowState;
            _savedLeft = Left; _savedTop = Top; _savedWidth = Width; _savedHeight = Height;
            _savedLeftColWidth = LeftCol.Width; _savedRightColWidth = RightCol.Width;
            _savedLeftColMin = LeftCol.MinWidth; _savedRightColMin = RightCol.MinWidth;

            AppTitleBar.Visibility = Visibility.Collapsed;
            ToolbarRow.Visibility = Visibility.Collapsed;
            StatusBar.Visibility = Visibility.Collapsed;
            LeftCol.MinWidth = 0; RightCol.MinWidth = 0;
            LeftCol.Width = new GridLength(0); LeftSplitCol.Width = new GridLength(0);
            RightCol.Width = new GridLength(0); RightSplitCol.Width = new GridLength(0);

            // 影片完全貼齊螢幕邊緣（去掉邊距與圓角）
            CenterBorder.Margin = new Thickness(0);
            CenterBorder.CornerRadius = new CornerRadius(0);
            VideoViewControl.Margin = new Thickness(0);

            WindowState = WindowState.Normal;
            Left = 0; Top = 0;
            Width = SystemParameters.PrimaryScreenWidth;
            Height = SystemParameters.PrimaryScreenHeight;
            Topmost = true;
            _fullscreen = true;
            ShowVideoControls(); // 起算自動隱藏
        }
        else
        {
            AppTitleBar.Visibility = Visibility.Visible;
            ToolbarRow.Visibility = Visibility.Visible;
            StatusBar.Visibility = Visibility.Visible;
            LeftCol.MinWidth = _savedLeftColMin; RightCol.MinWidth = _savedRightColMin;
            LeftCol.Width = _savedLeftColWidth; LeftSplitCol.Width = new GridLength(4);
            RightCol.Width = _savedRightColWidth; RightSplitCol.Width = new GridLength(4);

            CenterBorder.Margin = new Thickness(0, 0, 0, 8);
            CenterBorder.CornerRadius = new CornerRadius(10);
            VideoViewControl.Margin = new Thickness(10);

            Topmost = false;
            Left = _savedLeft; Top = _savedTop; Width = _savedWidth; Height = _savedHeight;
            WindowState = _savedState;
            _fullscreen = false;

            _hideControlsTimer?.Stop();
            if (VideoActive && EpisodePicker.Visibility != Visibility.Visible)
                VideoControls.Visibility = Visibility.Visible; // 視窗模式恆顯示
            VideoOverlay.Cursor = null;
        }
    }

    void Window_PreviewKeyDown(object sender, KeyEventArgs e)
    {
        if (SubtitleSelect.IsDropDownOpen || SpeedSelect.IsDropDownOpen)
            return;

        // 看劇模式的選集畫面：Backspace 或 Alt+↑ 回上一層（與檔案總管相同）
        if (_mode == AppMode.Video && EpisodePicker.Visibility == Visibility.Visible && _theaterStack.Count > 1 &&
            (e.Key == Key.Back || (e.Key == Key.System && e.SystemKey == Key.Up)))
        {
            GoUpLevel();
            e.Handled = true;
            return;
        }
        if (e.Key == Key.F11 && VideoActive)
        {
            ToggleFullscreen();
            e.Handled = true;
            return;
        }
        if (e.Key == Key.Escape && _fullscreen)
        {
            ToggleFullscreen();
            e.Handled = true;
            return;
        }
        if (!VideoActive)
            return;

        switch (e.Key)
        {
            case Key.Space:
                _player!.Pause(); // 呼叫一次即在播放/暫停間切換
                ShowVideoControls();
                e.Handled = true;
                break;
            case Key.Left:
                SeekBy(-10);
                ShowVideoControls();
                e.Handled = true;
                break;
            case Key.Right:
                SeekBy(10);
                ShowVideoControls();
                e.Handled = true;
                break;
        }
    }

    protected override void OnClosed(EventArgs e)
    {
        StopVideo(); // 會記下看到哪裡
        WatchProgress.Flush();
        _player?.Dispose();
        _libVLC?.Dispose();
        base.OnClosed(e);
    }

    void ChooseFolder_Click(object sender, RoutedEventArgs e)
    {
        var dlg = new OpenFolderDialog { Title = Loc.T("FolderDialogTitle") };
        if (dlg.ShowDialog() == true)
            OpenFolder(dlg.FolderName);
    }

    void Window_DragOver(object sender, DragEventArgs e)
    {
        e.Effects = e.Data.GetDataPresent(DataFormats.FileDrop)
            ? DragDropEffects.Copy : DragDropEffects.None;
        e.Handled = true;
    }

    void Window_Drop(object sender, DragEventArgs e)
    {
        if (e.Data.GetData(DataFormats.FileDrop) is string[] paths && paths.Length > 0)
        {
            string p = paths[0];
            if (System.IO.Directory.Exists(p))
                OpenFolder(p);
            else if (File.Exists(p))
                OpenFolder(System.IO.Path.GetDirectoryName(p)!, selectFile: p);
        }
    }

    int _scanToken;

    async void OpenFolder(string folder, string? selectFile = null)
    {
        if (ModeOverlay.Visibility == Visibility.Visible)
        {
            _pendingFolder = folder; // 還沒選模式：先記住，選完自動開
            return;
        }

        // 看劇模式一層一層瀏覽，子資料夾顯示成海報牆
        if (_mode == AppMode.Video)
        {
            OpenTheaterLocation(folder, new List<string>(), selectFile);
            return;
        }

        int scanToken = ++_scanToken;
        AppMode mode = _mode;
        FolderLabel.Text = folder;
        StatusLabel.Text = Loc.T("Scanning");
        _files.Clear();

        var paths = await Task.Run(() =>
        {
            // 資料夾不在了（NAS 沒連線、隨身碟拔掉）：回報無法開啟，不顯示成「沒有照片」
            if (!System.IO.Directory.Exists(folder))
                return null;
            var result = new List<string>();
            ScanFolder(folder, result, mode);
            result.Sort(StringComparer.OrdinalIgnoreCase);
            return result;
        });

        if (scanToken != _scanToken) return; // 已改開別的資料夾

        if (paths == null)
        {
            _allPaths = new List<string>();
            TypeFilter.ItemsSource = null;
            ShowEmpty(Loc.T("CannotOpenLocation"));
            StatusLabel.Text = Loc.T("CannotOpenLocation");
            return;
        }
        RecentLocations.Remember(folder, AppMode.Photo);

        _allPaths = paths;
        _rootFolder = folder;
        RebuildTypeFilter();
        ApplyFilter(selectFile);
    }

    List<string> _allPaths = new();
    string _rootFolder = "";
    bool _suppressFilterEvent;

    static string FilterAll => Loc.T("AllTypes");

    /// <summary>類型下拉選單：只列出資料夾裡實際存在的類型</summary>
    void RebuildTypeFilter()
    {
        var types = _allPaths.Select(TypeLabel).Distinct().OrderBy(t => t, StringComparer.Ordinal).ToList();
        _suppressFilterEvent = true;
        TypeFilter.ItemsSource = types.Count > 0 ? new[] { FilterAll }.Concat(types).ToList() : new List<string>();
        TypeFilter.SelectedIndex = types.Count > 0 ? 0 : -1;
        _suppressFilterEvent = false;
    }

    /// <summary>副檔名 → 類型名稱（JPG/JPEG 等同義副檔名合併顯示）</summary>
    static string TypeLabel(string path)
    {
        string ext = System.IO.Path.GetExtension(path).TrimStart('.').ToUpperInvariant();
        return ext switch
        {
            "JPG" or "JPEG" => "JPEG",
            "TIF" or "TIFF" => "TIFF",
            "HEIF" or "HIF" or "HEIC" => "HEIF",
            "M2TS" => "MTS",
            _ => ext,
        };
    }

    void TypeFilter_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (!_suppressFilterEvent)
            ApplyFilter(null);
    }

    void ApplyFilter(string? selectFile)
    {
        string? filter = TypeFilter.SelectedItem as string;
        if (filter == FilterAll)
            filter = null;

        _files.Clear();
        foreach (var p in _allPaths)
            if (filter == null || TypeLabel(p) == filter)
                _files.Add(new FileItem { Path = p, Root = _rootFolder });

        bool video = _mode == AppMode.Video;
        StatusLabel.Text = !video
            ? string.Format(Loc.T("PhotoCount"), _files.Count, _files.Count(f => f.IsRaw))
            : string.Format(Loc.T("VideoCount"), _files.Count);

        // 看劇模式：這一層沒有影片也顯示選集畫面（可能只有子資料夾；空的也要有「上一層」可以按）
        if (_files.Count > 0 || video)
        {
            EpisodesBtn.Visibility = Visibility.Visible;

            FileItem? target = null;
            if (selectFile != null)
            {
                target = _files.FirstOrDefault(f => string.Equals(f.Path, selectFile, StringComparison.OrdinalIgnoreCase));
                // 照片模式拖進來的檔案被篩選掉了：照舊從第一張開始；看劇模式（繼續觀看）找不到就不亂播別部
                if (target == null && !video)
                    target = _files[0];
            }

            if (target == null)
            {
                // 先顯示縮圖牆（照片）／封面選集（影片），讓使用者挑
                PopulateEpisodes();
                ShowEpisodePicker();
                // 「繼續觀看」要播的影片不在這一層了（改名、搬走）
                if (video && selectFile != null && ImageLoader.IsVideo(selectFile))
                    StatusLabel.Text = Loc.T("ContinueVideoMissing");
                return;
            }
            // 看劇模式直接播：選集先備好（按「選集」就是這一層），但縮圖等回到選集畫面才讀，磁碟讓給播放
            if (video)
                PopulateEpisodes(loadThumbs: false);

            FileList.SelectedItem = target;
            FileList.ScrollIntoView(target);
            FileList.Focus();
        }
        else
        {
            ShowEmpty(Loc.T("NoPhotos"));
        }
    }

    /// <summary>沒有可顯示的內容：中間顯示一行說明</summary>
    void ShowEmpty(string message)
    {
        EpisodesBtn.Visibility = Visibility.Collapsed;
        HideGallery();
        StopVideo();
        MainImage.Source = null;
        MainImage.Visibility = Visibility.Visible;
        PlaceholderText.Visibility = Visibility.Visible;
        PlaceholderText.Text = message;
        ClearInfo();
    }

    // ---------- 看劇模式：一層一層瀏覽、海報牆 ----------
    /// <summary>從開啟的位置一路點進去的資料夾：第一個是位置本身，最後一個是目前這一層</summary>
    readonly List<string> _theaterStack = new();
    /// <summary>讀過的每一層都記著：回上一層不必再讀 NAS（換位置時清空）</summary>
    readonly Dictionary<string, FolderListing> _listings = new(StringComparer.OrdinalIgnoreCase);
    /// <summary>找過的海報（null = 沒有封面），以資料夾為 key</summary>
    readonly Dictionary<string, BitmapSource?> _posterCache = new(StringComparer.OrdinalIgnoreCase);
    readonly ObservableCollection<PosterItem> _posters = new();
    int _posterToken;
    /// <summary>每次換位置 +1：較晚回來的舊位置結果不寫進快取</summary>
    int _locationGen;

    /// <summary>海報解碼尺寸：顯示 150×225，留給 200% 縮放的螢幕</summary>
    const int PosterDecodeWidth = 300, PosterDecodeHeight = 450;

    /// <summary>開啟一個位置；subfolders 不是空的時直接進到那一層（首頁「繼續觀看」）。playPath：那一層讀好後要播的影片</summary>
    void OpenTheaterLocation(string root, IReadOnlyList<string> subfolders, string? playPath = null)
    {
        _locationGen++;
        _listings.Clear();
        _posterCache.Clear();
        _theaterStack.Clear();
        _theaterStack.Add(root);
        foreach (var name in subfolders)
            _theaterStack.Add(System.IO.Path.Combine(_theaterStack[^1], name));
        LoadTheaterLevel(playPath, rememberRoot: true);
    }

    /// <summary>讀目前這一層（讀過的直接顯示）。rememberRoot：讀得到才記進「最近位置」</summary>
    async void LoadTheaterLevel(string? playPath = null, bool rememberRoot = false)
    {
        int scanToken = ++_scanToken;
        _posterToken++;
        _thumbToken++;
        string dir = _theaterStack[^1];
        FolderLabel.Text = dir;
        UpdatePickerHeader();

        if (!_listings.TryGetValue(dir, out var listing))
        {
            // 讀取中：先清空並顯示「掃描資料夾中…」，避免標題已經換了、畫面還是上一層
            _posters.Clear();
            _episodes.Clear();
            _files.Clear();
            StatusLabel.Text = Loc.T("Scanning");
            PickerFooter.Text = Loc.T("Scanning");
            int gen = _locationGen;
            listing = await Task.Run(() => TheaterLibrary.List(dir));
            if (scanToken != _scanToken) return; // 已改開別的資料夾或回上一層
            if (listing == null)
            {
                // 「繼續觀看」直接進到深層：上面幾層沒讀過，不一層層往上試（NAS 斷線時每層都要等逾時）
                if (_theaterStack.Count > 1 && playPath == null)
                {
                    // 子資料夾讀不到（NAS 斷線等）：留在上一層（上一層讀過，直接顯示）
                    _theaterStack.RemoveAt(_theaterStack.Count - 1);
                    LoadTheaterLevel();
                }
                else
                {
                    _allPaths = new List<string>();
                    TypeFilter.ItemsSource = null;
                    _posters.Clear();
                    ShowEmpty(Loc.T("CannotOpenLocation"));
                }
                StatusLabel.Text = Loc.T("CannotOpenLocation");
                return;
            }
            if (gen == _locationGen)
                _listings[dir] = listing;
        }

        if (rememberRoot)
            RecentLocations.Remember(_theaterStack[0], AppMode.Video);

        _rootFolder = dir;
        _allPaths = listing.Videos.ToList();
        _posters.Clear();
        foreach (var folder in listing.Folders)
            _posters.Add(new PosterItem(folder));
        PickerScroll.ScrollToTop();
        RebuildTypeFilter();
        ApplyFilter(playPath);
    }

    void UpdatePickerHeader()
    {
        if (_theaterStack.Count == 0)
            return;
        PickerTitle.Text = TheaterLibrary.DisplayName(_theaterStack[^1]);
        bool canGoUp = _theaterStack.Count > 1;
        UpLevelBtn.Visibility = canGoUp ? Visibility.Visible : Visibility.Collapsed;
        // 返回鍵顯示上一層的名稱（與 iOS 版相同）
        UpLevelBtn.Content = canGoUp ? TheaterLibrary.DisplayName(_theaterStack[^2]) : null;
    }

    /// <summary>選集畫面的狀態列與底部文字（影片數量）</summary>
    void UpdatePickerStatus()
    {
        if (_mode != AppMode.Video)
        {
            StatusLabel.Text = string.Format(Loc.T("PickPhoto"), _files.Count);
            return;
        }
        StatusLabel.Text = _posters.Count > 0
            ? string.Format(Loc.T("PickTitle"), _posters.Count, _files.Count)
            : string.Format(Loc.T(_files.Count > 0 ? "PickEpisode" : "NoVideos"), _files.Count);
        PickerFooter.Text = _files.Count > 0
            ? string.Format(Loc.T("VideoCount"), _files.Count)
            : (_posters.Count == 0 ? Loc.T("NoVideos") : "");
    }

    void Poster_Click(object sender, RoutedEventArgs e)
    {
        if ((sender as FrameworkElement)?.Tag is not PosterItem poster)
            return;
        _theaterStack.Add(poster.Path);
        LoadTheaterLevel();
    }

    void UpLevel_Click(object sender, RoutedEventArgs e) => GoUpLevel();

    void GoUpLevel()
    {
        if (_theaterStack.Count <= 1)
            return;
        _theaterStack.RemoveAt(_theaterStack.Count - 1);
        LoadTheaterLevel();
    }

    /// <summary>
    /// 背景找海報：讀子資料夾那一層找 poster／folder／cover／fanart，都沒有就用首字佔位。
    /// 同時最多讀 4 個資料夾（NAS 一次湧入太多請求反而更慢）；讀到的內容順便存進快取，點進去直接顯示
    /// </summary>
    void LoadPostersAsync()
    {
        int token = ++_posterToken;
        int gen = _locationGen;
        foreach (var p in _posters)
            if (!p.Finished && _posterCache.TryGetValue(p.Path, out var cached))
            {
                p.Image = cached;
                p.Finished = true;
            }
        // 在 UI 執行緒先抓好已讀過的那幾層（Dictionary 不能跨執行緒讀）
        var pending = _posters.Where(p => !p.Finished)
            .Select(p => (Item: p, Listing: _listings.TryGetValue(p.Path, out var l) ? l : null))
            .ToList();
        if (pending.Count == 0)
            return;

        Task.Run(async () =>
        {
            using var gate = new System.Threading.SemaphoreSlim(4);
            var tasks = pending.Select(async job =>
            {
                await gate.WaitAsync();
                try
                {
                    if (token != _posterToken) return; // 已離開這一層
                    var listing = job.Listing ?? TheaterLibrary.List(job.Item.Path);
                    string? cover = listing == null ? null : TheaterLibrary.FindCover(listing);
                    BitmapSource? bmp = null;
                    if (cover != null)
                    {
                        try { bmp = ImageLoader.LoadCover(cover, PosterDecodeWidth, PosterDecodeHeight); }
                        catch { } // 圖壞了就用佔位
                    }
                    await Dispatcher.BeginInvoke(() =>
                    {
                        if (gen != _locationGen) return;
                        if (listing != null && !_listings.ContainsKey(job.Item.Path))
                            _listings[job.Item.Path] = listing;
                        // 讀不到資料夾（null listing）不寫快取：下次回到這一層再試
                        if (listing != null)
                            _posterCache[job.Item.Path] = bmp;
                        job.Item.Image = bmp;
                        job.Item.Finished = true;
                    });
                }
                finally { gate.Release(); }
            }).ToList();
            await Task.WhenAll(tasks);
        });
    }

    // ---------- 看劇模式：封面選集 ----------
    void PopulateEpisodes(bool loadThumbs = true)
    {
        _episodes.Clear();
        foreach (var f in _files)
        {
            var ep = new EpisodeItem { Path = f.Path, Name = f.Name };
            if (_mode == AppMode.Video)
                ep.RefreshWatch();
            _episodes.Add(ep);
        }
        if (loadThumbs)
            LoadThumbsAsync();
    }

    /// <summary>背景載入缺少的封面縮圖。先撈系統快取（瞬間），沒有的才現場產生（吃磁碟、可取消）</summary>
    void LoadThumbsAsync()
    {
        int token = ++_thumbToken;
        var pending = _episodes.Where(ep => ep.Thumb == null).ToList();
        if (pending.Count == 0)
            return;

        Task.Run(async () =>
        {
            // 第一輪：只撈 Windows 快取（瞬間）
            foreach (var it in pending)
            {
                if (token != _thumbToken) return;
                if (it.Thumb != null) continue;
                var bmp = ShellThumb.Get(it.Path, 320, cacheOnly: true);
                if (bmp != null)
                    _ = Dispatcher.BeginInvoke(() => it.Thumb ??= bmp);
            }
            // 第二輪：沒快取的自己產生。照片用內建解碼器（RAW 取內嵌小預覽），3 個並行；
            // 影片交給 Shell 產生（開始播放時會取消，把磁碟讓給影片）
            using var gate = new System.Threading.SemaphoreSlim(3);
            var tasks = pending.Where(it => it.Thumb == null).Select(async it =>
            {
                await gate.WaitAsync();
                try
                {
                    if (token != _thumbToken || it.Thumb != null) return;
                    System.Windows.Media.Imaging.BitmapSource? bmp = null;
                    try
                    {
                        bmp = it.IsVideo ? ShellThumb.Get(it.Path, 320) : ImageLoader.LoadThumbnail(it.Path, 320);
                    }
                    catch { }
                    if (bmp != null && token == _thumbToken)
                        await Dispatcher.BeginInvoke(() => it.Thumb ??= bmp);
                }
                finally { gate.Release(); }
            }).ToList();
            await Task.WhenAll(tasks);
        });
    }

    /// <summary>目前模式對應的縮圖牆容器</summary>
    Border GalleryHost => _mode == AppMode.Photo ? PhotoGrid : EpisodePicker;

    void HideGallery()
    {
        PhotoGrid.Visibility = Visibility.Collapsed;
        EpisodePicker.Visibility = Visibility.Collapsed;
    }

    System.Windows.Threading.DispatcherTimer? _loadingTimer;

    /// <summary>載入指示：開始後 200ms 才顯示（快速載入不閃爍），完成即隱藏</summary>
    void ShowLoading(bool on)
    {
        if (_loadingTimer == null)
        {
            _loadingTimer = new System.Windows.Threading.DispatcherTimer { Interval = TimeSpan.FromMilliseconds(200) };
            _loadingTimer.Tick += (_, _) =>
            {
                _loadingTimer.Stop();
                LoadingRing.Visibility = Visibility.Visible;
            };
        }
        _loadingTimer.Stop();
        if (on)
            _loadingTimer.Start();
        else
            LoadingRing.Visibility = Visibility.Collapsed;
    }

    void ShowEpisodePicker()
    {
        _loadToken++; // 取消進行中的影像載入
        StopVideo();
        FileList.UnselectAll();
        MainImage.Source = null;
        MainImage.Visibility = Visibility.Collapsed;
        PlaceholderText.Visibility = Visibility.Collapsed;
        ShowLoading(false);
        if (_mode == AppMode.Video)
        {
            // 影片視窗保持存在（選集畫面疊在上面）——之後點封面播放不用重建視窗，才不會卡
            VideoViewControl.Visibility = Visibility.Visible;
            // 剛看完回來：進度條與打勾更新
            foreach (var ep in _episodes)
                ep.RefreshWatch();
            UpdatePickerHeader();
            LoadPostersAsync(); // 續找還沒找完的海報
        }
        GalleryHost.Visibility = Visibility.Visible;
        ClearInfo();
        UpdatePickerStatus();
        LoadThumbsAsync(); // 續載還沒好的縮圖
    }

    void EpisodesBtn_Click(object sender, RoutedEventArgs e) => ShowEpisodePicker();

    void Episode_Click(object sender, RoutedEventArgs e)
    {
        if ((sender as FrameworkElement)?.Tag is not EpisodeItem ep)
            return;
        HideGallery();
        var item = _files.FirstOrDefault(f => string.Equals(f.Path, ep.Path, StringComparison.OrdinalIgnoreCase));
        if (item != null)
        {
            FileList.SelectedItem = item;
            FileList.ScrollIntoView(item);
        }
    }

    /// <summary>遞迴掃描資料夾（依模式只收照片或影片），跳過沒有權限的目錄</summary>
    static void ScanFolder(string dir, List<string> result, AppMode mode)
    {
        try
        {
            foreach (var f in System.IO.Directory.EnumerateFiles(dir))
                if (mode == AppMode.Photo ? ImageLoader.IsImage(f) : ImageLoader.IsVideo(f))
                    result.Add(f);
            foreach (var d in System.IO.Directory.EnumerateDirectories(dir))
                ScanFolder(d, result, mode);
        }
        catch (UnauthorizedAccessException) { }
        catch (IOException) { }
    }

    async void FileList_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (FileList.SelectedItem is not FileItem item)
            return;

        HideGallery();
        int token = ++_loadToken;
        string path = item.Path;
        StatusLabel.Text = string.Format(Loc.T("Loading"), item.Name);

        if (item.IsVideo)
        {
            await ShowVideoAsync(item, token);
            return;
        }

        StopVideo();
        MainImage.Visibility = Visibility.Visible;
        ShowLoading(true);

        try
        {
            var result = await Task.Run(() =>
            {
                var img = ImageLoader.Load(path);
                var key = ExifService.Read(path);
                return (img, key);
            });

            if (token != _loadToken) return; // 使用者已切到別張
            ShowLoading(false);

            PlaceholderText.Visibility = Visibility.Collapsed;
            ResetZoom();
            MainImage.Source = result.img;
            FillInfo(path, result.img.PixelWidth, result.img.PixelHeight, result.key);
            StatusLabel.Text = $"{item.Name} — {result.img.PixelWidth} x {result.img.PixelHeight}";
        }
        catch (Exception ex)
        {
            if (token != _loadToken) return;
            ShowLoading(false);
            MainImage.Source = null;
            PlaceholderText.Visibility = Visibility.Visible;
            PlaceholderText.Text = Loc.T("CantReadPhoto");
            StatusLabel.Text = string.Format(Loc.T("ReadFail"), ex.Message);
            FillInfo(path, 0, 0, SafeReadExif(path));
        }
    }

    async Task ShowVideoAsync(FileItem item, int token)
    {
        // 換片：先記下上一部看到哪裡；新的一部真正開播前不記錄
        RecordProgress();
        _playingPath = null;
        HideResumeBanner();

        if (!await EnsurePlayerAsync() || token != _loadToken)
            return;
        if (_libVLC == null || _player == null)
        {
            StatusLabel.Text = Loc.T("PlayerNotInit");
            return;
        }

        _thumbToken++; // 取消封面縮圖產生，磁碟頻寬讓給播放
        _posterToken++;
        _spuTimer?.Stop();
        var oldMedia = _currentMedia;
        _currentMedia = null;

        // 停止舊影片與掃描字幕都是慢速 IO（尤其在 HDD 上），移到背景執行緒避免卡 UI
        var subFiles = await Task.Run(() =>
        {
            try { _player.Stop(); } catch { }
            oldMedia?.Dispose();
            return FindSubtitleFiles(item.Path);
        });

        if (token != _loadToken)
            return;

        var media = new Media(_libVLC, new Uri(item.Path));
        foreach (var sub in subFiles)
            media.AddSlave(MediaSlaveType.Subtitle, 4, new Uri(sub).AbsoluteUri);

        // 上次看到一半（30 秒以上、還沒到最後 5%）：從那裡開檔（與 iOS 版 VLC 相同，用 :start-time）
        long? resumeMs = WatchProgress.ResumePositionMs(item.Path);
        if (resumeMs is long ms)
            media.AddOption(":start-time=" + (ms / 1000.0).ToString("F1", CultureInfo.InvariantCulture));

        ResetZoom();
        MainImage.Source = null;
        MainImage.Visibility = Visibility.Collapsed;
        PlaceholderText.Visibility = Visibility.Collapsed;
        VideoViewControl.Visibility = Visibility.Visible;
        VideoControls.Visibility = Visibility.Visible;
        SubtitleLabel.Visibility = Visibility.Visible;
        SubtitleSelect.Visibility = Visibility.Visible;

        // 每部影片從 1.0x 開始
        SpeedSelect.SelectedIndex = 2;
        PositionSlider.Value = 0;
        TimeCurrent.Text = "0:00:00";
        TimeTotal.Text = "0:00:00";

        // 先開播（切集立即有反應），影片資訊在背景解析完再補進右側面板
        _currentMedia = media;
        _player.Play(media);
        _playingPath = item.Path;
        _playingRoot = _theaterStack.Count > 0 ? _theaterStack[0] : System.IO.Path.GetDirectoryName(item.Path);
        _playingSubfolders = _theaterStack.Skip(1).Select(d => System.IO.Path.GetFileName(d)).ToList();
        _lastTimeMs = -1;
        _lastLengthMs = 0;
        _recordTicks = 0;
        _endRecorded = false;
        StartProgressTimer();
        if (resumeMs is long shown)
            ShowResumeBanner(shown);
        FillInfo(item.Path, 0, 0, new List<InfoRow>());

        _ = Task.Run(async () =>
        {
            await media.Parse(MediaParseOptions.ParseLocal);
            if (token != _loadToken) return;

            var rows = new List<InfoRow>();
            if (media.Duration > 0)
                rows.Add(new InfoRow(Loc.T("Duration"), TimeSpan.FromMilliseconds(media.Duration).ToString(@"hh\:mm\:ss")));
            foreach (var t in media.Tracks)
            {
                if (t.TrackType == TrackType.Video)
                {
                    rows.Add(new InfoRow(Loc.T("Resolution"), $"{t.Data.Video.Width} x {t.Data.Video.Height}"));
                    if (t.Data.Video.FrameRateDen > 0)
                        rows.Add(new InfoRow(Loc.T("FrameRate"), $"{t.Data.Video.FrameRateNum / (double)t.Data.Video.FrameRateDen:F2} fps"));
                    rows.Add(new InfoRow(Loc.T("VideoCodec"), FourCC(t.Codec)));
                }
                else if (t.TrackType == TrackType.Audio)
                {
                    rows.Add(new InfoRow(Loc.T("AudioCodec"), FourCC(t.Codec)));
                    rows.Add(new InfoRow(Loc.T("AudioInfo"), string.Format(Loc.T("AudioFmt"), t.Data.Audio.Channels, t.Data.Audio.Rate)));
                }
            }
            if (subFiles.Count > 0)
                rows.Add(new InfoRow(Loc.T("ExtSubs"), string.Format(Loc.T("ExtSubsCount"), subFiles.Count)));
            rows.AddRange(SafeReadExif(item.Path)); // 拍攝時間等（MP4/MOV 可讀）

            Dispatcher.Invoke(() =>
            {
                if (token != _loadToken) return;
                FillInfo(item.Path, 0, 0, rows);
            });
        });

        // 字幕軌要等播放器啟動後才註冊完成，開播後刷新幾次清單
        int refreshes = 0;
        _spuTimer?.Stop();
        _spuTimer = new System.Windows.Threading.DispatcherTimer
        {
            Interval = TimeSpan.FromMilliseconds(800)
        };
        _spuTimer.Tick += (_, _) =>
        {
            RefreshSubtitleList();
            if (++refreshes >= 5)
                _spuTimer!.Stop();
        };
        _spuTimer.Start();

        StatusLabel.Text = string.Format(Loc.T("Playing"), item.Name);
    }

    static string FourCC(uint codec)
    {
        Span<char> c = stackalloc char[4];
        for (int i = 0; i < 4; i++)
        {
            char ch = (char)((codec >> (8 * i)) & 0xFF);
            c[i] = char.IsLetterOrDigit(ch) ? ch : ' ';
        }
        return new string(c).Trim().ToUpperInvariant();
    }

    static List<InfoRow> SafeReadExif(string path)
    {
        try { return ExifService.Read(path); }
        catch { return new List<InfoRow>(); }
    }

    void FillInfo(string path, int w, int h, List<InfoRow> key)
    {
        var fi = new FileInfo(path);
        var basic = new List<InfoRow>
        {
            new(Loc.T("FileName"), fi.Name),
            new(Loc.T("FileSize"), HumanSize(fi.Length)),
        };
        if (w > 0)
            basic.Add(new InfoRow(Loc.T("DisplaySize"), $"{w} x {h}"));

        FileInfoList.ItemsSource = basic;
        KeyInfoList.ItemsSource = key;
        var vis = key.Count > 0 ? Visibility.Visible : Visibility.Collapsed;
        KeyTitle.Visibility = vis;
        KeyCard.Visibility = vis;
    }

    void ClearInfo()
    {
        FileInfoList.ItemsSource = null;
        KeyInfoList.ItemsSource = null;
        KeyTitle.Visibility = Visibility.Collapsed;
        KeyCard.Visibility = Visibility.Collapsed;
    }

    static string HumanSize(long n) => n switch
    {
        < 1024 => $"{n} B",
        < 1024 * 1024 => $"{n / 1024.0:F1} KB",
        < 1024 * 1024 * 1024 => $"{n / 1024.0 / 1024:F1} MB",
        _ => $"{n / 1024.0 / 1024 / 1024:F2} GB",
    };
}
