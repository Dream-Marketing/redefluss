using System.Collections.ObjectModel;
using System.Reflection;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Data;
using System.Windows.Media;
using Redefluss.App.Audio;
using Redefluss.Core.Models;
using Redefluss.Core.Storage;
using Redefluss.Core.Text;

namespace Redefluss.App.UI;

/// <summary>Einstellungen mit den Reitern Allgemein, Modell, Wörterbuch, Verlauf und Info.</summary>
public sealed class SettingsWindow : Window
{
    private readonly DictationController _controller;
    private readonly Action _showOnboarding;
    private readonly TabControl _tabs = new() { Padding = new Thickness(0) };
    private readonly StackPanel _modelPane = new();
    private readonly StackPanel _historyList = new();
    private readonly TextBlock _hookWarning = Ui.Text("", 13, Ui.Danger);
    private readonly TextBlock _meetingStatus = Ui.Text("", 13);

    private AppSettings Settings => _controller.Settings;

    public SettingsWindow(DictationController controller, Action showOnboarding)
    {
        _controller = controller;
        _showOnboarding = showOnboarding;
        Title = "Redefluss – Einstellungen";
        Width = 660;
        Height = 640;
        MinWidth = 520;
        MinHeight = 420;
        WindowStartupLocation = WindowStartupLocation.CenterScreen;
        Background = Brushes.White;
        FontFamily = new FontFamily("Segoe UI Variable Text, Segoe UI");
        Icon = App.IconImage;

        _tabs.Items.Add(Tab("Allgemein", General()));
        _tabs.Items.Add(Tab("Modell", Ui.Scroll(_modelPane)));
        _tabs.Items.Add(Tab("Wörterbuch", DictionaryPane()));
        _tabs.Items.Add(Tab("Verlauf", HistoryPane()));
        _tabs.Items.Add(Tab("Info", About()));
        Content = _tabs;

        RenderModels();
        RenderHistory();
        UpdateHookWarning();
        controller.Models.Changed += RenderModels;
        controller.StateChanged += OnControllerChanged;
        controller.History.Changed += RenderHistory;
        Closed += (_, _) =>
        {
            controller.Models.Changed -= RenderModels;
            controller.StateChanged -= OnControllerChanged;
            controller.History.Changed -= RenderHistory;
        };
    }

    public void Show(SettingsTab tab)
    {
        _tabs.SelectedIndex = (int)tab;
        Show();
        if (WindowState == WindowState.Minimized) WindowState = WindowState.Normal;
        Activate();
    }

    private void OnControllerChanged()
    {
        UpdateHookWarning();
        RenderModelStatus();
        UpdateMeetingStatus();
    }

    private static TabItem Tab(string title, UIElement content) => new() { Header = title, Content = content, Padding = new Thickness(12, 4, 12, 4) };

    // MARK: Allgemein

    private UIElement General()
    {
        var panel = new StackPanel();
        panel.Children.Add(_hookWarning);

        panel.Children.Add(Ui.Section("Tastenkürzel",
            new HotkeyChooser(Settings, _controller.Hook),
            Ui.Toggle("Dauer-Modus (Taste + Leertaste oder Doppeltipp)", Settings, nameof(AppSettings.HandsFreeEnabled)),
            Ui.Row("Letztes Diktat einfügen", Ui.Text("Strg + Alt + V", 13, Ui.Secondary)),
            Ui.Row("Diktat verwerfen", Ui.Text("Esc", 13, Ui.Secondary))));

        var language = new ComboBox { MinWidth = 220, HorizontalAlignment = HorizontalAlignment.Left, DisplayMemberPath = "Name", SelectedValuePath = "Code" };
        language.ItemsSource = SupportedLanguage.All.Select(l => new { l.Code, l.Name }).ToList();
        language.SetBinding(System.Windows.Controls.Primitives.Selector.SelectedValueProperty,
            new Binding(nameof(AppSettings.Language)) { Source = Settings, Mode = BindingMode.TwoWay });

        var microphone = new ComboBox { MinWidth = 220, HorizontalAlignment = HorizontalAlignment.Left, DisplayMemberPath = "Name", SelectedValuePath = "Id" };
        void FillMicrophones()
        {
            var devices = new List<AudioInputDevice> { new("", "Windows-Standard") };
            devices.AddRange(AudioRecorder.Devices());
            microphone.ItemsSource = devices;
            microphone.SelectedValue = Settings.InputDeviceId ?? "";
        }
        FillMicrophones();
        microphone.DropDownOpened += (_, _) => { var keep = Settings.InputDeviceId; FillMicrophones(); microphone.SelectedValue = keep ?? ""; };
        microphone.SelectionChanged += (_, _) =>
        {
            if (microphone.SelectedValue is string id) Settings.InputDeviceId = id.Length == 0 ? null : id;
        };

        panel.Children.Add(Ui.Section("Sprache & Mikrofon",
            Ui.Row("Sprache", language),
            Ui.Row("Mikrofon", microphone),
            Ui.Button("Mikrofon-Datenschutz in Windows öffnen", () => Shell.Open("ms-settings:privacy-microphone"))));

        panel.Children.Add(Ui.Section("Text",
            Ui.Toggle("Füllwörter entfernen (äh, ähm, uh …)", Settings, nameof(AppSettings.RemoveFillers)),
            Ui.Toggle("Leerzeichen nach dem Diktat anhängen", Settings, nameof(AppSettings.AppendTrailingSpace)),
            Ui.Toggle("Zwischenablage nach dem Einfügen wiederherstellen", Settings, nameof(AppSettings.RestoreClipboard))));

        panel.Children.Add(Ui.Section("Meetings",
            Ui.Toggle("Meetings automatisch mitschreiben", Settings, nameof(AppSettings.MeetingAutoRecord)),
            Ui.Toggle("Andere Teilnehmer mitschreiben (Systemaudio)", Settings, nameof(AppSettings.MeetingSystemAudio)),
            Ui.Caption("Sobald Zoom, Teams, Meet im Browser & Co. das Mikrofon benutzen, schreibt Redefluss mit und legt den Text " +
                       "im Verlauf ab. Es wird nie Ton gespeichert. Bitte die anderen Teilnehmer vorher informieren."),
            _meetingStatus));
        UpdateMeetingStatus();

        var autostart = new CheckBox { Content = "Beim Anmelden starten", Margin = new Thickness(0, 4, 0, 4), FontSize = 13, IsChecked = LaunchAtLogin.IsEnabled };
        autostart.Click += (_, _) =>
        {
            try { LaunchAtLogin.IsEnabled = autostart.IsChecked == true; }
            catch (Exception e) { Log.Error("Autostart", e); autostart.IsChecked = LaunchAtLogin.IsEnabled; }
        };

        panel.Children.Add(Ui.Section("Darstellung & System",
            Ui.Toggle("Töne bei Start und Ende", Settings, nameof(AppSettings.PlaySounds)),
            Ui.Toggle("Leiste auch im Ruhezustand zeigen", Settings, nameof(AppSettings.ShowIdlePill)),
            Ui.Toggle("Diktate im Verlauf speichern", Settings, nameof(AppSettings.SaveHistory)),
            autostart,
            Ui.Horizontal(
                Ui.Button("Einführung erneut zeigen", _showOnboarding),
                Ui.Button("Leiste zurück nach unten", () => Settings.FlowBarPosition = null))));
        return Ui.Scroll(panel);
    }

    private void UpdateMeetingStatus()
    {
        var meeting = _controller.Meeting;
        (_meetingStatus.Text, _meetingStatus.Foreground) = meeting.CurrentState switch
        {
            Meeting.MeetingRecorder.State.Recording => ($"● Mitschrift läuft: {meeting.AppName}" +
                (meeting.SystemAudioProblem is { } p ? $"\n{p}" : ""), Ui.Danger),
            Meeting.MeetingRecorder.State.Finishing => ("Mitschrift wird gespeichert …", Ui.Secondary),
            _ when !Settings.MeetingAutoRecord => ("Aus – im Infobereich-Symbol lässt sich eine Mitschrift auch von Hand starten.", Ui.Secondary),
            _ when _controller.MicrophoneUsers.Count == 0 => ("Gerade nutzt keine andere App das Mikrofon.", Ui.Secondary),
            _ => ($"Mikrofon in Benutzung: {string.Join(", ", _controller.MicrophoneUsers.Select(u => u.Name).Distinct())} – Mitschrift startet gleich", Ui.Accent),
        };
    }

    private void UpdateHookWarning()
    {
        _hookWarning.Text = _controller.HotkeyActive ? "" : "Die Diktiertaste ist gerade nicht aktiv. Bitte Redefluss neu starten.";
        _hookWarning.Visibility = _controller.HotkeyActive ? Visibility.Collapsed : Visibility.Visible;
    }

    // MARK: Modell

    private TextBlock? _modelStatus;

    private void RenderModelStatus()
    {
        if (_modelStatus is null) return;
        (_modelStatus.Text, _modelStatus.Foreground) = _controller.ModelState switch
        {
            ModelState.Ready r => ($"✓ {r.Name} ist bereit" + (_controller.Transcriber.Runtime is { } rt ? $" · rechnet mit {RuntimeName(rt)}" : ""), Ui.Success),
            ModelState.Loading l => ($"{l.Name} wird geladen …", Ui.Secondary),
            ModelState.Failed f => (f.Message, Ui.Danger),
            _ => ("Kein Modell ausgewählt", Ui.Secondary),
        };
    }

    private static string RuntimeName(string runtime) => runtime switch
    {
        "Vulkan" => "der Grafikkarte (Vulkan)",
        "Cuda" => "der NVIDIA-Grafikkarte (CUDA)",
        "Cpu" or "CpuNoAvx" => "dem Prozessor",
        _ => runtime,
    };

    private void RenderModels()
    {
        var models = _controller.Models;
        _modelPane.Children.Clear();

        _modelStatus = Ui.Text("", 14, weight: FontWeights.SemiBold);
        RenderModelStatus();
        _modelPane.Children.Add(Ui.Section("Aktives Modell", _modelStatus,
            Ui.Caption("Die Transkription läuft komplett auf diesem PC – kein Ton verlässt das Gerät.")));

        var installed = new List<UIElement>();
        if (models.Installed.Count == 0)
            installed.Add(Ui.Caption("Noch kein Modell vorhanden – lade unten eins herunter."));
        foreach (var model in models.Installed)
        {
            var active = string.Equals(model.Path, Settings.ModelPath, StringComparison.OrdinalIgnoreCase);
            var info = new StackPanel();
            info.Children.Add(Ui.Text(model.DisplayName, 13, weight: FontWeights.Medium));
            info.Children.Add(Ui.Caption($"{model.FileName} · {ByteFormat.Format(model.SizeBytes)}" +
                (model.IsExternal ? $" · gefunden in {Path.GetDirectoryName(model.Path)}" : "") +
                (model.IsEnglishOnly ? " · nur Englisch" : "")));
            var actions = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Right, VerticalAlignment = VerticalAlignment.Center };
            if (active) actions.Children.Add(Ui.Text("Aktiv", 13, Ui.Success, FontWeights.Medium));
            else actions.Children.Add(Ui.Button("Verwenden", () => Settings.ModelPath = model.Path));
            if (!model.IsExternal && !active)
                actions.Children.Add(Ui.Button("Löschen", () =>
                {
                    if (MessageBox.Show(this, $"{model.FileName} löschen?", "Redefluss", MessageBoxButton.YesNo, MessageBoxImage.Question) == MessageBoxResult.Yes)
                        models.Delete(model);
                }));
            installed.Add(RowWithActions(info, actions));
        }
        _modelPane.Children.Add(Ui.Section("Auf diesem PC", installed.ToArray()));

        var catalog = new List<UIElement>();
        foreach (var model in CatalogModel.Catalog)
        {
            var info = new StackPanel();
            info.Children.Add(Ui.Text(model.Name, 13, weight: FontWeights.Medium));
            info.Children.Add(Ui.Caption($"{model.Note} · {ByteFormat.Format(model.SizeBytes)}"));
            var actions = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Right, VerticalAlignment = VerticalAlignment.Center };
            if (models.Downloads.TryGetValue(model.Id, out var progress))
            {
                actions.Children.Add(new ProgressBar { Width = 120, Height = 6, Maximum = 1, Value = progress, VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(0, 0, 8, 0) });
                actions.Children.Add(Ui.Text($"{progress * 100:0} %", 12, Ui.Secondary));
                actions.Children.Add(Ui.Button("Abbrechen", () => models.CancelDownload(model)));
            }
            else if (models.InstalledVersion(model) is not null)
            {
                actions.Children.Add(Ui.Text("Vorhanden", 13, Ui.Secondary));
            }
            else
            {
                actions.Children.Add(Ui.Button("Laden", () => _ = DownloadAsync(model), primary: model == CatalogModel.Recommended));
            }
            catalog.Add(RowWithActions(info, actions));
        }
        if (models.LastError is { } error) catalog.Add(Ui.Text(error, 12, Ui.Danger));
        _modelPane.Children.Add(Ui.Section("Herunterladen", catalog.ToArray()));
        _modelPane.Children.Add(Ui.Caption($"Modelle liegen in {models.ModelsDirectory}. Gefunden werden auch Modelle in %USERPROFILE%\\.cache\\whisper-cpp."));
    }

    private async Task DownloadAsync(CatalogModel model)
    {
        var file = await _controller.Models.DownloadAsync(model);
        if (file is not null && (Settings.ModelPath.Length == 0 || !File.Exists(Settings.ModelPath))) Settings.ModelPath = file.Path;
        RenderModels();
    }

    private static Grid RowWithActions(UIElement info, UIElement actions)
    {
        var grid = new Grid { Margin = new Thickness(0, 4, 0, 4) };
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        grid.Children.Add(info);
        Grid.SetColumn((FrameworkElement)actions, 1);
        grid.Children.Add(actions);
        return grid;
    }

    // MARK: Wörterbuch

    public sealed class ReplacementRow
    {
        public string From { get; set; } = "";
        public string To { get; set; } = "";
    }

    private UIElement DictionaryPane()
    {
        var words = new TextBox
        {
            AcceptsReturn = true,
            TextWrapping = TextWrapping.Wrap,
            VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
            Height = 130,
            Text = string.Join(Environment.NewLine, Settings.Dictionary),
            FontSize = 13,
        };
        void SaveWords() => Settings.Dictionary = words.Text
            .Split(['\r', '\n'], StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries)
            .Distinct().ToList();
        words.LostFocus += (_, _) => SaveWords();
        // Schließen ohne vorheriges Verlassen des Feldes darf nichts verlieren.
        Closing += (_, _) => SaveWords();

        var rows = new ObservableCollection<ReplacementRow>(Settings.Replacements.Select(r => new ReplacementRow { From = r.From, To = r.To }));
        var grid = new DataGrid
        {
            ItemsSource = rows,
            AutoGenerateColumns = false,
            CanUserAddRows = true,
            CanUserDeleteRows = true,
            HeadersVisibility = DataGridHeadersVisibility.Column,
            Height = 200,
            FontSize = 13,
        };
        grid.Columns.Add(new DataGridTextColumn { Header = "Gesagt", Binding = new Binding(nameof(ReplacementRow.From)), Width = new DataGridLength(1, DataGridLengthUnitType.Star) });
        grid.Columns.Add(new DataGridTextColumn { Header = "Geschrieben", Binding = new Binding(nameof(ReplacementRow.To)), Width = new DataGridLength(1.4, DataGridLengthUnitType.Star) });
        void Save() => Settings.Replacements = rows
            .Where(r => !string.IsNullOrWhiteSpace(r.From))
            .Select(r => new Replacement(r.From.Trim(), r.To ?? ""))
            .ToList();
        grid.RowEditEnding += (_, _) => Dispatcher.BeginInvoke(Save);
        rows.CollectionChanged += (_, _) => Save();
        grid.LostFocus += (_, _) => Save();

        var panel = new StackPanel();
        panel.Children.Add(Ui.Section("Eigene Wörter",
            Ui.Caption("Namen und Fachbegriffe, eins pro Zeile – Whisper schreibt sie dann richtig."),
            words));
        panel.Children.Add(Ui.Section("Ersetzungen",
            Ui.Caption("Wird nach der Erkennung ersetzt, ganze Wörter, Groß-/Kleinschreibung egal. Zeile markieren und Entf löscht."),
            grid));
        return Ui.Scroll(panel);
    }

    // MARK: Verlauf

    private UIElement HistoryPane()
    {
        var panel = new DockPanel { LastChildFill = true };
        var top = Ui.Horizontal(
            Ui.Button("Alles löschen", () =>
            {
                if (MessageBox.Show(this, "Den ganzen Verlauf löschen?", "Redefluss", MessageBoxButton.YesNo, MessageBoxImage.Warning) == MessageBoxResult.Yes)
                    _controller.History.Clear();
            }));
        top.Margin = new Thickness(18, 10, 18, 0);
        DockPanel.SetDock(top, Dock.Top);
        panel.Children.Add(top);
        panel.Children.Add(Ui.Scroll(_historyList));
        return panel;
    }

    private void RenderHistory()
    {
        _historyList.Children.Clear();
        var items = _controller.History.Items;
        if (items.Count == 0)
        {
            _historyList.Children.Add(Ui.Text("Noch keine Diktate", 15, weight: FontWeights.SemiBold));
            _historyList.Children.Add(Ui.Caption("Halte die Diktiertaste und sprich – hier erscheint alles, was du diktiert hast."));
            return;
        }
        foreach (var item in items.Take(200))
        {
            var meta = $"{item.Date.LocalDateTime:dd.MM.yyyy HH:mm} · {item.AudioSeconds:0} s"
                       + (item.AppName is { } app ? $" · {app}" : "")
                       + (item.Language is { } lang ? $" · {lang.ToUpperInvariant()}" : "")
                       + (item.IsMeeting ? " · Meeting" : "");
            var text = new TextBox
            {
                Text = item.Text, IsReadOnly = true, TextWrapping = TextWrapping.Wrap, BorderThickness = new Thickness(0),
                Background = Brushes.Transparent, FontSize = 13, MaxHeight = 160,
                VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
            };
            var id = item.Id;
            var copy = item.Text;
            _historyList.Children.Add(Ui.Section(null,
                Ui.Caption(meta),
                text,
                Ui.Horizontal(
                    Ui.Button("Kopieren", () => Clipboard.SetText(copy)),
                    Ui.Button("Löschen", () => _controller.History.Delete(id)))));
        }
    }

    // MARK: Info

    private UIElement About()
    {
        var version = Assembly.GetExecutingAssembly().GetName().Version;
        var words = _controller.History.TotalWords;
        var panel = new StackPanel { HorizontalAlignment = HorizontalAlignment.Center, Margin = new Thickness(0, 30, 0, 0) };
        panel.Children.Add(new Image { Source = App.IconImage, Width = 96, Height = 96, Margin = new Thickness(0, 0, 0, 10) });
        var title = Ui.Text("Redefluss", 26, weight: FontWeights.SemiBold);
        title.HorizontalAlignment = HorizontalAlignment.Center;
        panel.Children.Add(title);
        foreach (var line in new[]
                 {
                     $"Version {version?.ToString(3) ?? "dev"} für Windows",
                     "Lokales Diktieren – Taste halten, sprechen, loslassen.",
                     "Transkription mit whisper.cpp direkt auf deinem PC.",
                     $"{_controller.History.Items.Count} Diktate · {words} Wörter bisher",
                 })
        {
            var t = Ui.Text(line, 13, Ui.Secondary);
            t.HorizontalAlignment = HorizontalAlignment.Center;
            t.TextAlignment = TextAlignment.Center;
            panel.Children.Add(t);
        }
        var logs = Ui.Button("Protokolle öffnen", () => { Directory.CreateDirectory(Log.Directory); Shell.Open(Log.Directory); });
        logs.HorizontalAlignment = HorizontalAlignment.Center;
        logs.Margin = new Thickness(0, 16, 0, 0);
        panel.Children.Add(logs);
        return panel;
    }
}
