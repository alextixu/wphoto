using System;
using System.Collections.Generic;
using System.Collections.ObjectModel;
using System.IO;
using System.Linq;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
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
    public string Glyph => IsVideo ? "🎬" : "🖼️";
    public Visibility RawBadgeVisibility => IsRaw ? Visibility.Visible : Visibility.Collapsed;

    System.Windows.Media.Imaging.BitmapSource? _thumb;
    public System.Windows.Media.Imaging.BitmapSource? Thumb
    {
        get => _thumb;
        set { _thumb = value; PropertyChanged?.Invoke(this, new(nameof(Thumb))); }
    }

    public event System.ComponentModel.PropertyChangedEventHandler? PropertyChanged;
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

    public MainWindow()
    {
        InitializeComponent();
        FileList.ItemsSource = _files;
        EpisodeList.ItemsSource = _episodes;
        PhotoGridList.ItemsSource = _episodes;

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
        }
        if (_allPaths.Count == 0)
            FolderLabel.Text = Loc.T("NoFolderHint");

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
        StopVideo();
        _episodes.Clear();
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
        ModeOverlay.Visibility = Visibility.Visible;
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
            long len = _player.Length;
            if (len <= 0) return;
            _updatingSliderFromTimer = true;
            PositionSlider.Maximum = len;
            if (!PositionSlider.IsMouseCaptureWithin)
                PositionSlider.Value = _player.Time;
            _updatingSliderFromTimer = false;
            TimeCurrent.Text = FmtTime(_player.Time);
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
            if (VideoActive)
                VideoControls.Visibility = Visibility.Visible; // 視窗模式恆顯示
            VideoOverlay.Cursor = null;
        }
    }

    void Window_PreviewKeyDown(object sender, KeyEventArgs e)
    {
        if (SubtitleSelect.IsDropDownOpen || SpeedSelect.IsDropDownOpen)
            return;

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
        StopVideo();
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

        int scanToken = ++_scanToken;
        AppMode mode = _mode;
        FolderLabel.Text = folder;
        StatusLabel.Text = Loc.T("Scanning");
        _files.Clear();

        var paths = await Task.Run(() =>
        {
            var result = new List<string>();
            ScanFolder(folder, result, mode);
            result.Sort(StringComparer.OrdinalIgnoreCase);
            return result;
        });

        if (scanToken != _scanToken) return; // 已改開別的資料夾

        _allPaths = paths;
        _rootFolder = folder;

        // 類型下拉選單：只列出資料夾裡實際存在的類型
        var types = paths.Select(TypeLabel).Distinct().OrderBy(t => t, StringComparer.Ordinal).ToList();
        _suppressFilterEvent = true;
        TypeFilter.ItemsSource = types.Count > 0 ? new[] { FilterAll }.Concat(types).ToList() : new List<string>();
        TypeFilter.SelectedIndex = types.Count > 0 ? 0 : -1;
        _suppressFilterEvent = false;

        ApplyFilter(selectFile);
    }

    List<string> _allPaths = new();
    string _rootFolder = "";
    bool _suppressFilterEvent;

    static string FilterAll => Loc.T("AllTypes");

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

        StatusLabel.Text = _mode == AppMode.Photo
            ? string.Format(Loc.T("PhotoCount"), _files.Count, _files.Count(f => f.IsRaw))
            : string.Format(Loc.T("VideoCount"), _files.Count);

        if (_files.Count > 0)
        {
            EpisodesBtn.Visibility = Visibility.Visible;

            if (selectFile == null)
            {
                // 先顯示縮圖牆（照片）／封面選集（影片），讓使用者挑
                PopulateEpisodes();
                ShowEpisodePicker();
                return;
            }

            var target = selectFile != null
                ? _files.FirstOrDefault(f => string.Equals(f.Path, selectFile, StringComparison.OrdinalIgnoreCase)) ?? _files[0]
                : _files[0];
            FileList.SelectedItem = target;
            FileList.ScrollIntoView(target);
            FileList.Focus();
        }
        else
        {
            EpisodesBtn.Visibility = Visibility.Collapsed;
            HideGallery();
            StopVideo();
            MainImage.Source = null;
            MainImage.Visibility = Visibility.Visible;
            PlaceholderText.Visibility = Visibility.Visible;
            PlaceholderText.Text = Loc.T(_mode == AppMode.Photo ? "NoPhotos" : "NoVideos");
            ClearInfo();
        }
    }

    // ---------- 看劇模式：封面選集 ----------
    void PopulateEpisodes()
    {
        _episodes.Clear();
        foreach (var f in _files)
            _episodes.Add(new EpisodeItem { Path = f.Path, Name = f.Name });
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
        }
        GalleryHost.Visibility = Visibility.Visible;
        ClearInfo();
        StatusLabel.Text = string.Format(Loc.T(_mode == AppMode.Photo ? "PickPhoto" : "PickEpisode"), _files.Count);
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
        if (!await EnsurePlayerAsync() || token != _loadToken)
            return;
        if (_libVLC == null || _player == null)
        {
            StatusLabel.Text = Loc.T("PlayerNotInit");
            return;
        }

        _thumbToken++; // 取消封面縮圖產生，磁碟頻寬讓給播放
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
        StartProgressTimer();
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
