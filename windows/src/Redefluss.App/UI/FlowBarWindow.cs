using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Media.Animation;
using System.Windows.Media.Effects;
using System.Windows.Threading;
using Redefluss.Core.FlowBar;
using Redefluss.Core.Storage;
using static Redefluss.App.Native.NativeMethods;
using Shapes = System.Windows.Shapes;
using Forms = System.Windows.Forms;

namespace Redefluss.App.UI;

/// <summary>
/// Die schwebende Leiste unten am Bildschirm: durchsichtiges, nie aktivierendes Fenster (360 × 64),
/// die sichtbare Kapsel sitzt unten mittig darin. Durchsichtige Pixel lassen Klicks durch; in den
/// Zuständen ohne Bedienung (Halten, Schreiben) ist das ganze Fenster durchklickbar.
/// Bewusst ohne WPF-Button: Klicks und Ziehen laufen über eigene Mausbehandlung.
/// </summary>
public sealed class FlowBarWindow : Window
{
    public enum Mode { Hidden, Idle, Recording, HandsFree, Transcribing, Message, Meeting, MeetingFinishing }

    public event Action? StartHandsFreeRequested;
    public event Action? StopRequested;
    public event Action? CancelRequested;
    public event Action<FlowBarPosition?>? PositionChanged;
    public event Action? StopMeetingRequested;

    public const int BarCount = 14;

    private static readonly Color Red = Color.FromRgb(0xF2, 0x45, 0x45);
    private static readonly Color Orange = Color.FromRgb(0xFF, 0x9E, 0x4D);

    private readonly Grid _root = new();
    private readonly Border _pill = new();
    private readonly float[] _levels = new float[BarCount];
    private readonly List<Shapes.Rectangle> _bars = [];
    private readonly List<Shapes.Ellipse> _dots = [];
    private readonly DispatcherTimer _messageTimer = new() ;
    private Action? _messageTap;
    private IntPtr _hwnd;
    private bool _placedOnce;
    private string? _currentDisplay;
    private bool _clickThrough;

    public Mode CurrentMode { get; private set; } = Mode.Hidden;
    public string HotkeyLabel { get; set; } = "F5";

    private TextBlock? _clockText;

    /// <summary>Ruhezustand: Ruht die Leiste, zeigt sie stattdessen das laufende Meeting.</summary>
    private bool IsResting => CurrentMode is Mode.Idle or Mode.Hidden or Mode.Meeting or Mode.MeetingFinishing;

    private string? _meetingLabel;
    /// <summary>Name der Meeting-App, solange mitgeschrieben wird – ersetzt im Ruhezustand den Punkt.</summary>
    public string? MeetingLabel
    {
        get => _meetingLabel;
        set { _meetingLabel = value; if (IsResting) SetIdle(); }
    }

    private bool _meetingFinishing;
    public bool MeetingFinishing
    {
        get => _meetingFinishing;
        set { _meetingFinishing = value; if (IsResting) SetIdle(); }
    }

    private string _meetingClock = "00:00";
    /// <summary>Laufzeit („12:34") – nur der Text wird aktualisiert, ohne die Kapsel neu aufzubauen.</summary>
    public string MeetingClock
    {
        get => _meetingClock;
        set { _meetingClock = value; if (_clockText is not null) _clockText.Text = value; }
    }

    private bool _showIdlePill = true;
    public bool ShowIdlePill
    {
        get => _showIdlePill;
        set { _showIdlePill = value; if (IsResting) SetIdle(); }
    }

    private FlowBarPosition? _position;
    public FlowBarPosition? Position
    {
        get => _position;
        set { if (_position != value) { _position = value; Reposition(); } }
    }

    public FlowBarWindow()
    {
        Title = "Redefluss";
        WindowStyle = WindowStyle.None;
        AllowsTransparency = true;
        Background = Brushes.Transparent;
        ResizeMode = ResizeMode.NoResize;
        ShowInTaskbar = false;
        ShowActivated = false;
        Topmost = true;
        Focusable = false;
        Width = FlowBarGeometry.Width;
        Height = FlowBarGeometry.Height;

        _pill.HorizontalAlignment = HorizontalAlignment.Center;
        _pill.VerticalAlignment = VerticalAlignment.Bottom;
        _pill.Margin = new Thickness(0, 0, 0, FlowBarGeometry.PillBottomPadding);
        _pill.RenderTransformOrigin = new Point(0.5, 0.5);
        _pill.RenderTransform = new ScaleTransform(1, 1);
        _root.Children.Add(_pill);
        Content = _root;

        _messageTimer.Tick += (_, _) => SetIdle();
        MouseLeftButtonDown += OnMouseDown;
        MouseMove += OnMouseMove;
        MouseLeftButtonUp += OnMouseUp;
        LostMouseCapture += (_, _) => _press = null;
        DpiChanged += (_, _) => Dispatcher.BeginInvoke(Reposition, DispatcherPriority.Background);
    }

    protected override void OnSourceInitialized(EventArgs e)
    {
        base.OnSourceInitialized(e);
        _hwnd = new WindowInteropHelper(this).Handle;
        var style = (long)GetWindowLongPtr(_hwnd, GWL_EXSTYLE);
        SetWindowLongPtr(_hwnd, GWL_EXSTYLE, new IntPtr(style | WS_EX_NOACTIVATE | WS_EX_TOOLWINDOW | WS_EX_TOPMOST));
        HwndSource.FromHwnd(_hwnd)?.AddHook((IntPtr hwnd, int msg, IntPtr w, IntPtr l, ref bool handled) =>
        {
            // Klick auf die Leiste darf der App, in die gerade geschrieben wird, nie den Fokus nehmen.
            if (msg == WM_MOUSEACTIVATE)
            {
                handled = true;
                return new IntPtr(MA_NOACTIVATE);
            }
            return IntPtr.Zero;
        });
        Reposition();
    }

    // MARK: Zustände

    public void SetIdle()
    {
        _messageTimer.Stop();
        _messageTap = null;
        ResetLevels();
        if (MeetingFinishing)
        {
            var panel = new StackPanel { Orientation = Orientation.Horizontal, VerticalAlignment = VerticalAlignment.Center, Tag = "drag" };
            panel.Children.Add(ThinkingDots());
            var label = Label("Meeting wird gespeichert …", 12);
            label.Margin = new Thickness(8, 0, 0, 0);
            panel.Children.Add(label);
            Apply(Mode.MeetingFinishing, Capsule(panel), clickThrough: false);
            return;
        }
        if (MeetingLabel is { } app)
        {
            Apply(Mode.Meeting, BuildMeeting(app), clickThrough: false);
            return;
        }
        if (!ShowIdlePill)
        {
            Apply(Mode.Hidden, null, clickThrough: true);
            return;
        }
        Apply(Mode.Idle, BuildIdle(), clickThrough: false);
    }

    public void SetRecording(bool handsFree)
    {
        _messageTimer.Stop();
        Reposition();
        if (handsFree) Apply(Mode.HandsFree, BuildHandsFree(), clickThrough: false, width: 150);
        else Apply(Mode.Recording, Capsule(Waveform(BarCount)), clickThrough: true, width: 104);
    }

    public void SetTranscribing() => Apply(Mode.Transcribing, Capsule(ThinkingDots()), clickThrough: true, width: 64);

    /// <param name="onTap">Klick auf den Hinweis (z. B. Einstellungen öffnen).</param>
    public void ShowMessage(string text, bool isError = false, double seconds = 2.4, Action? onTap = null)
    {
        _messageTimer.Stop();
        _messageTap = onTap;
        Reposition();
        var panel = new StackPanel { Orientation = Orientation.Horizontal, VerticalAlignment = VerticalAlignment.Center, Tag = "message" };
        if (isError)
        {
            panel.Children.Add(new Border
            {
                Width = 14, Height = 14, CornerRadius = new CornerRadius(7), Background = new SolidColorBrush(Orange),
                Margin = new Thickness(0, 0, 6, 0),
                Child = new TextBlock { Text = "!", FontSize = 10, FontWeight = FontWeights.Bold, Foreground = Brushes.Black,
                    HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center },
            });
        }
        panel.Children.Add(Label(text, 12));
        var capsule = Capsule(panel);
        capsule.Tag = "message";
        capsule.Cursor = onTap is null ? null : Cursors.Hand;
        Apply(Mode.Message, capsule, clickThrough: false);
        _messageTimer.Interval = TimeSpan.FromSeconds(seconds);
        _messageTimer.Start();
    }

    public void PushLevel(float level)
    {
        Array.Copy(_levels, 1, _levels, 0, BarCount - 1);
        _levels[^1] = level;
        UpdateBars();
    }

    public void ResetLevels()
    {
        Array.Clear(_levels);
        UpdateBars();
    }

    private void Apply(Mode mode, FrameworkElement? content, bool clickThrough, double width = double.NaN)
    {
        var changed = mode != CurrentMode;
        CurrentMode = mode;
        CompositionTarget.Rendering -= AnimateDots;
        if (mode is Mode.Transcribing or Mode.MeetingFinishing) CompositionTarget.Rendering += AnimateDots;
        if (mode != Mode.Meeting) _clockText = null;

        _pill.Child = content;
        _pill.Width = width;
        _pill.Visibility = content is null ? Visibility.Hidden : Visibility.Visible;
        SetClickThrough(clickThrough);

        // Federndes Erscheinen beim Zustandswechsel – wie auf dem Mac.
        if (changed && content is not null)
        {
            var spring = new ElasticEase { Oscillations = 1, Springiness = 6, EasingMode = EasingMode.EaseOut };
            var grow = new DoubleAnimation(0.6, 1, TimeSpan.FromMilliseconds(320)) { EasingFunction = spring };
            _pill.RenderTransform.BeginAnimation(ScaleTransform.ScaleXProperty, grow);
            _pill.RenderTransform.BeginAnimation(ScaleTransform.ScaleYProperty, grow);
            _pill.BeginAnimation(OpacityProperty, new DoubleAnimation(0, 1, TimeSpan.FromMilliseconds(160)));
        }
    }

    private void SetClickThrough(bool on)
    {
        if (_hwnd == IntPtr.Zero || _clickThrough == on) { _clickThrough = on; return; }
        _clickThrough = on;
        const long transparent = 0x20; // WS_EX_TRANSPARENT
        var style = (long)GetWindowLongPtr(_hwnd, GWL_EXSTYLE);
        SetWindowLongPtr(_hwnd, GWL_EXSTYLE, new IntPtr(on ? style | transparent : style & ~transparent));
    }

    // MARK: Bausteine

    private FrameworkElement BuildIdle()
    {
        var dot = new Border
        {
            Width = 38, Height = 8, CornerRadius = new CornerRadius(4),
            Background = new SolidColorBrush(Color.FromArgb(140, 0, 0, 0)),
            BorderBrush = new SolidColorBrush(Color.FromArgb(46, 255, 255, 255)),
            BorderThickness = new Thickness(1),
            HorizontalAlignment = HorizontalAlignment.Center,
            VerticalAlignment = VerticalAlignment.Center,
        };
        var hint = Label($"{HotkeyLabel} halten oder klicken", 11);
        hint.Opacity = 0;
        hint.HorizontalAlignment = HorizontalAlignment.Center;
        hint.VerticalAlignment = VerticalAlignment.Center;
        dot.Child = hint;

        // Fast unsichtbarer Rand: vergrößert die Fläche, auf der die Maus den Punkt „findet".
        var hover = new Border
        {
            Background = new SolidColorBrush(Color.FromArgb(1, 0, 0, 0)),
            Padding = new Thickness(8),
            Child = dot,
            Tag = "start",
            Cursor = Cursors.Hand,
            ToolTip = "Diktat starten – ziehen verschiebt die Leiste",
        };
        void Animate(bool on)
        {
            var d = TimeSpan.FromMilliseconds(150);
            dot.BeginAnimation(WidthProperty, new DoubleAnimation(on ? 170 : 38, d));
            dot.BeginAnimation(HeightProperty, new DoubleAnimation(on ? 24 : 8, d));
            dot.CornerRadius = new CornerRadius(on ? 12 : 4);
            dot.Background = new SolidColorBrush(Color.FromArgb(on ? (byte)209 : (byte)140, 0, 0, 0));
            hint.BeginAnimation(OpacityProperty, new DoubleAnimation(on ? 0.85 : 0, d));
        }
        hover.MouseEnter += (_, _) => Animate(true);
        hover.MouseLeave += (_, _) => Animate(false);
        // Die Idle-Kapsel trägt keinen eigenen Hintergrund – das macht der Punkt selbst.
        return hover;
    }

    private FrameworkElement BuildHandsFree()
    {
        var grid = new Grid { Margin = new Thickness(-8, 0, -8, 0) };
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });

        var cancel = CircleButton(XMark(), Color.FromArgb(46, 255, 255, 255), "cancel", "Verwerfen (Esc)");
        var wave = Waveform(BarCount);
        wave.Tag = "drag";
        wave.Background = new SolidColorBrush(Color.FromArgb(1, 0, 0, 0));
        var stop = CircleButton(new Shapes.Rectangle { Width = 8, Height = 8, RadiusX = 1.5, RadiusY = 1.5, Fill = Brushes.White },
            Red, "stop", $"Fertig ({HotkeyLabel})");

        Grid.SetColumn(cancel, 0);
        Grid.SetColumn(wave, 1);
        Grid.SetColumn(stop, 2);
        grid.Children.Add(cancel);
        grid.Children.Add(wave);
        grid.Children.Add(stop);
        return Capsule(grid);
    }

    private FrameworkElement BuildMeeting(string app)
    {
        var dot = new Shapes.Ellipse { Width = 8, Height = 8, Fill = new SolidColorBrush(Red), VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(2, 0, 8, 0) };
        // Pulsierender roter Punkt – „es wird aufgenommen".
        dot.BeginAnimation(OpacityProperty, new DoubleAnimation(1, 0.35, TimeSpan.FromSeconds(1.3)) { AutoReverse = true, RepeatBehavior = RepeatBehavior.Forever });

        var name = Label(app, 11);
        name.FontWeight = FontWeights.SemiBold;
        name.MaxWidth = 110;
        _clockText = Label(MeetingClock, 11);
        _clockText.Opacity = 0.75;
        _clockText.Margin = new Thickness(8, 0, 8, 0);
        _clockText.FontFamily = new FontFamily("Segoe UI Variable Text, Segoe UI");
        _clockText.SetValue(System.Windows.Documents.Typography.NumeralAlignmentProperty, FontNumeralAlignment.Tabular);

        var info = new StackPanel
        {
            Orientation = Orientation.Horizontal, VerticalAlignment = VerticalAlignment.Center, Tag = "drag",
            Background = new SolidColorBrush(Color.FromArgb(1, 0, 0, 0)),
            ToolTip = "Meeting wird mitgeschrieben – ziehen verschiebt die Leiste",
        };
        info.Children.Add(dot);
        info.Children.Add(name);
        info.Children.Add(_clockText);
        info.Children.Add(Waveform(8));

        var stop = CircleButton(new Shapes.Rectangle { Width = 8, Height = 8, RadiusX = 1.5, RadiusY = 1.5, Fill = Brushes.White },
            Red, "stopMeeting", "Meeting-Mitschrift beenden");
        stop.Margin = new Thickness(8, 0, 0, 0);

        var row = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(-8, 0, -8, 0) };
        row.Children.Add(info);
        row.Children.Add(stop);
        return Capsule(row);
    }

    private static Border Capsule(UIElement content) => new()
    {
        Height = 32,
        MinWidth = 32,
        CornerRadius = new CornerRadius(16),
        Background = new SolidColorBrush(Color.FromArgb(224, 0, 0, 0)),
        BorderBrush = new SolidColorBrush(Color.FromArgb(41, 255, 255, 255)),
        BorderThickness = new Thickness(1),
        Padding = new Thickness(14, 0, 14, 0),
        Effect = new DropShadowEffect { BlurRadius = 16, ShadowDepth = 2, Direction = 270, Opacity = 0.25 },
        Child = content,
    };

    private static TextBlock Label(string text, double size) => new()
    {
        Text = text,
        FontSize = size,
        FontWeight = FontWeights.Medium,
        Foreground = new SolidColorBrush(Color.FromArgb(235, 255, 255, 255)),
        VerticalAlignment = VerticalAlignment.Center,
        TextTrimming = TextTrimming.CharacterEllipsis,
        MaxWidth = 320,
    };

    private Panel Waveform(int count)
    {
        _bars.Clear();
        var panel = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center, Height = 20 };
        for (var i = 0; i < count; i++)
        {
            var bar = new Shapes.Rectangle
            {
                Width = 2.5, Height = 3, RadiusX = 1.25, RadiusY = 1.25,
                Fill = new SolidColorBrush(Color.FromArgb(242, 255, 255, 255)),
                Margin = new Thickness(i == 0 ? 0 : 1.25, 0, i == count - 1 ? 0 : 1.25, 0),
                VerticalAlignment = VerticalAlignment.Center,
            };
            _bars.Add(bar);
            panel.Children.Add(bar);
        }
        UpdateBars();
        return panel;
    }

    private void UpdateBars()
    {
        if (_bars.Count == 0) return;
        var shown = _levels.AsSpan(_levels.Length - _bars.Count).ToArray();
        for (var i = 0; i < _bars.Count; i++) _bars[i].Height = FlowBarGeometry.BarHeight(shown, i);
    }

    private FrameworkElement ThinkingDots()
    {
        _dots.Clear();
        var panel = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center };
        for (var i = 0; i < 3; i++)
        {
            var dot = new Shapes.Ellipse { Width = 5, Height = 5, Fill = Brushes.White, Margin = new Thickness(2.5, 0, 2.5, 0), RenderTransform = new TranslateTransform() };
            _dots.Add(dot);
            panel.Children.Add(dot);
        }
        return panel;
    }

    private void AnimateDots(object? sender, EventArgs e)
    {
        var t = DateTime.Now.TimeOfDay.TotalSeconds;
        for (var i = 0; i < _dots.Count; i++)
        {
            var phase = Math.Max(0, Math.Sin(t * 5 - i * 0.7));
            _dots[i].Opacity = 0.35 + 0.65 * phase;
            ((TranslateTransform)_dots[i].RenderTransform).Y = -2.5 * phase;
        }
    }

    private static Border CircleButton(UIElement symbol, Color tint, string tag, string help)
    {
        var circle = new Border
        {
            Width = 22, Height = 22, CornerRadius = new CornerRadius(11),
            Background = new SolidColorBrush(tint),
            Child = symbol, Tag = tag, ToolTip = help, Cursor = Cursors.Hand,
            VerticalAlignment = VerticalAlignment.Center,
        };
        var normal = circle.Background;
        circle.MouseEnter += (_, _) => circle.Background = new SolidColorBrush(Lighten(tint));
        circle.MouseLeave += (_, _) => circle.Background = normal;
        return circle;
    }

    private static Color Lighten(Color c) =>
        Color.FromArgb((byte)Math.Min(255, c.A + 40), (byte)Math.Min(255, c.R + 30), (byte)Math.Min(255, c.G + 30), (byte)Math.Min(255, c.B + 30));

    private static Shapes.Path XMark() => new()
    {
        Data = Geometry.Parse("M0,0 L7,7 M7,0 L0,7"),
        Stroke = Brushes.White,
        StrokeThickness = 1.8,
        StrokeStartLineCap = PenLineCap.Round,
        StrokeEndLineCap = PenLineCap.Round,
        HorizontalAlignment = HorizontalAlignment.Center,
        VerticalAlignment = VerticalAlignment.Center,
    };

    // MARK: Lage

    /// <summary>
    /// Unten mittig über der Taskleiste oder an die gespeicherte Stelle – auf dem gespeicherten Bildschirm,
    /// sonst auf dem, wo die Leiste gerade ist. Nur beim allerersten Mal zählt die Maus.
    /// </summary>
    public void Reposition()
    {
        if (_hwnd == IntPtr.Zero || _press?.Dragging == true) return;
        var screen = Forms.Screen.AllScreens.FirstOrDefault(s => s.DeviceName == Position?.Display)
                     ?? (_placedOnce ? Forms.Screen.FromHandle(_hwnd) : null)
                     ?? Forms.Screen.FromPoint(Forms.Cursor.Position);
        _placedOnce = true;
        _currentDisplay = screen.DeviceName;
        var (work, geometry) = Measure(screen);
        var (x, y) = geometry.Origin(Position, work);
        SetWindowPos(_hwnd, HWND_TOPMOST, (int)Math.Round(x), (int)Math.Round(y),
            (int)Math.Round(geometry.W), (int)Math.Round(geometry.H), SWP_NOACTIVATE | SWP_SHOWWINDOW);
    }

    private static (Box Work, FlowBarGeometry Geometry) Measure(Forms.Screen screen)
    {
        var a = screen.WorkingArea;
        var center = new POINT { X = a.Left + a.Width / 2, Y = a.Top + a.Height / 2 };
        var scale = 1.0;
        var monitor = MonitorFromPoint(center, 2 /* MONITOR_DEFAULTTONEAREST */);
        if (GetDpiForMonitor(monitor, 0 /* MDT_EFFECTIVE_DPI */, out var dpi, out _) == 0 && dpi > 0) scale = dpi / 96.0;
        return (new Box(a.Left, a.Top, a.Width, a.Height), new FlowBarGeometry(scale));
    }

    // MARK: Klicken und Ziehen

    private sealed class Press
    {
        public required string? Tag;
        public required POINT Mouse;
        public required RECT Window;
        public bool Dragging;
    }

    private Press? _press;

    private void OnMouseDown(object sender, MouseButtonEventArgs e)
    {
        GetCursorPos(out var mouse);
        GetWindowRect(_hwnd, out var rect);
        _press = new Press { Tag = TagUnder(e.OriginalSource as DependencyObject), Mouse = mouse, Window = rect };
        CaptureMouse();
        e.Handled = true;
    }

    private void OnMouseMove(object sender, MouseEventArgs e)
    {
        if (_press is null || e.LeftButton != MouseButtonState.Pressed) return;
        // Knöpfe verschieben nicht – sonst fühlt sich ein leicht verwackelter Klick wie Ziehen an.
        if (_press.Tag is "cancel" or "stop" or "stopMeeting") return;
        GetCursorPos(out var mouse);
        var dx = mouse.X - _press.Mouse.X;
        var dy = mouse.Y - _press.Mouse.Y;
        var threshold = 4 * VisualTreeHelper.GetDpi(this).DpiScaleX;
        if (!_press.Dragging && Math.Abs(dx) < threshold && Math.Abs(dy) < threshold) return;
        _press.Dragging = true;
        SetWindowPos(_hwnd, HWND_TOPMOST, _press.Window.Left + dx, _press.Window.Top + dy, 0, 0, SWP_NOACTIVATE | SWP_NOSIZE);
    }

    private void OnMouseUp(object sender, MouseButtonEventArgs e)
    {
        var press = _press;
        _press = null;
        ReleaseMouseCapture();
        if (press is null) return;
        if (press.Dragging)
        {
            StorePosition();
            return;
        }
        // Knöpfe lösen nur aus, wenn auch über ihnen losgelassen wurde.
        var releasedOver = TagUnder(InputHitTest(e.GetPosition(this)) as DependencyObject);
        if (press.Tag is "cancel" or "stop" or "stopMeeting" && releasedOver != press.Tag) return;
        switch (press.Tag)
        {
            case "start": StartHandsFreeRequested?.Invoke(); break;
            case "cancel": CancelRequested?.Invoke(); break;
            case "stop": StopRequested?.Invoke(); break;
            case "stopMeeting": StopMeetingRequested?.Invoke(); break;
            case "message":
                var tap = _messageTap;
                if (tap is null) break;
                SetIdle();
                tap();
                break;
        }
    }

    private void StorePosition()
    {
        GetWindowRect(_hwnd, out var rect);
        var screen = Forms.Screen.FromHandle(_hwnd);
        var (work, geometry) = Measure(screen);
        var position = geometry.Position((rect.Left, rect.Top), work, screen.DeviceName);
        _position = position;
        _currentDisplay = screen.DeviceName;
        Reposition();   // einrasten bzw. an den Rand klemmen
        PositionChanged?.Invoke(position);
    }

    private static string? TagUnder(DependencyObject? element)
    {
        while (element is not null)
        {
            if (element is FrameworkElement { Tag: string tag }) return tag;
            element = element is Visual or System.Windows.Media.Media3D.Visual3D ? VisualTreeHelper.GetParent(element) : LogicalTreeHelper.GetParent(element);
        }
        return null;
    }
}
