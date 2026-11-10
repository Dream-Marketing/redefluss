using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using Redefluss.Core.Models;

namespace Redefluss.App.UI;

/// <summary>Einführung beim ersten Start: Willkommen → Mikrofon → Sprachmodell → Diktiertaste → Ausprobieren.</summary>
public sealed class OnboardingWindow : Window
{
    private readonly DictationController _controller;
    private readonly ContentControl _page = new();
    private readonly Button _back;
    private readonly Button _next;
    private readonly TextBlock _stepLabel = Ui.Caption("");
    private int _step;
    private const int Steps = 5;

    public OnboardingWindow(DictationController controller)
    {
        _controller = controller;
        Title = "Redefluss einrichten";
        Width = 560;
        Height = 520;
        ResizeMode = ResizeMode.NoResize;
        WindowStartupLocation = WindowStartupLocation.CenterScreen;
        Background = Brushes.White;
        FontFamily = new FontFamily("Segoe UI Variable Text, Segoe UI");
        Icon = App.IconImage;

        _back = Ui.Button("Zurück", () => Go(_step - 1));
        _next = Ui.Button("Weiter", () => Go(_step + 1), primary: true);
        _next.Margin = new Thickness(0, 4, 0, 4);

        var footer = new DockPanel { Margin = new Thickness(24, 0, 24, 18) };
        DockPanel.SetDock(_stepLabel, Dock.Left);
        _stepLabel.VerticalAlignment = VerticalAlignment.Center;
        footer.Children.Add(_stepLabel);
        var buttons = Ui.Horizontal(_back, _next);
        buttons.HorizontalAlignment = HorizontalAlignment.Right;
        footer.Children.Add(buttons);

        var root = new DockPanel();
        DockPanel.SetDock(footer, Dock.Bottom);
        root.Children.Add(footer);
        _page.Margin = new Thickness(28, 26, 28, 10);
        root.Children.Add(_page);
        Content = root;

        controller.Models.Changed += Refresh;
        controller.StateChanged += Refresh;
        Closed += (_, _) =>
        {
            controller.Models.Changed -= Refresh;
            controller.StateChanged -= Refresh;
        };
        Go(0);
    }

    private void Refresh()
    {
        // Nur die Modell-Seite zeigt Live-Fortschritt.
        if (_step == 2) Go(2);
    }

    private void Go(int step)
    {
        if (step >= Steps)
        {
            _controller.Settings.OnboardingDone = true;
            Close();
            return;
        }
        _step = Math.Max(0, step);
        _back.Visibility = _step == 0 ? Visibility.Hidden : Visibility.Visible;
        _next.Content = _step == Steps - 1 ? "Fertig" : "Weiter";
        _stepLabel.Text = $"Schritt {_step + 1} von {Steps}";
        _page.Content = _step switch
        {
            0 => Welcome(),
            1 => Microphone(),
            2 => Model(),
            3 => Hotkey(),
            _ => TryIt(),
        };
    }

    private static StackPanel Page(string title, params UIElement[] children)
    {
        var panel = new StackPanel();
        panel.Children.Add(Ui.Text(title, 22, weight: FontWeights.SemiBold));
        panel.Children.Add(new Border { Height = 8 });
        foreach (var child in children) panel.Children.Add(child);
        return panel;
    }

    private UIElement Welcome()
    {
        var image = new Image { Source = App.IconImage, Width = 80, Height = 80, HorizontalAlignment = HorizontalAlignment.Left, Margin = new Thickness(0, 0, 0, 12) };
        var page = Page("Willkommen bei Redefluss",
            Ui.Text("Taste halten, sprechen, loslassen – der Text steht dort, wo dein Cursor ist. In jedem Programm.", 14),
            Ui.Text("Alles läuft lokal auf diesem PC mit whisper.cpp. Kein Ton und kein Text verlässt das Gerät.", 14, Ui.Secondary),
            Ui.Text("Die Einrichtung dauert etwa zwei Minuten (plus Download des Sprachmodells).", 14, Ui.Secondary));
        page.Children.Insert(0, image);
        return page;
    }

    private UIElement Microphone() => Page("Mikrofon erlauben",
        Ui.Text("Windows muss Desktop-Apps den Zugriff auf das Mikrofon erlauben.", 14),
        Ui.Text("Einstellungen → Datenschutz und Sicherheit → Mikrofon:\n• „Mikrofonzugriff“ an\n• „Desktop-Apps Zugriff auf Ihr Mikrofon erlauben“ an", 14, Ui.Secondary),
        Ui.Button("Mikrofon-Einstellungen öffnen", () => Shell.Open("ms-settings:privacy-microphone")),
        Ui.Caption("Ist das schon eingeschaltet, einfach weiter. Das Mikrofon wird nur benutzt, solange du die Diktiertaste hältst."));

    private UIElement Model()
    {
        var models = _controller.Models;
        var recommended = CatalogModel.Recommended;
        var children = new List<UIElement>
        {
            Ui.Text("Redefluss braucht ein Sprachmodell. Empfohlen ist „Turbo“: schnell und genau für Deutsch und Englisch.", 14),
        };
        if (models.BestInstalled() is { } best)
        {
            children.Add(Ui.Text($"✓ {best.DisplayName} ist vorhanden ({ByteFormat.Format(best.SizeBytes)}).", 14, Ui.Success, FontWeights.Medium));
        }
        else if (models.Downloads.TryGetValue(recommended.Id, out var progress))
        {
            children.Add(new ProgressBar { Height = 8, Maximum = 1, Value = progress, Margin = new Thickness(0, 10, 0, 4) });
            children.Add(Ui.Caption($"{progress * 100:0} % von {ByteFormat.Format(recommended.SizeBytes)} – du kannst schon weitermachen."));
        }
        else
        {
            children.Add(Ui.Button($"Turbo laden ({ByteFormat.Format(recommended.SizeBytes)})", async () =>
            {
                var file = await models.DownloadAsync(recommended);
                if (file is not null) _controller.Settings.ModelPath = file.Path;
                Refresh();
            }, primary: true));
            if (models.LastError is { } error) children.Add(Ui.Text(error, 13, Ui.Danger));
            children.Add(Ui.Caption("Andere Größen gibt es später unter Einstellungen → Modell."));
        }
        return Page("Sprachmodell", children.ToArray());
    }

    private UIElement Hotkey() => Page("Diktiertaste",
        Ui.Text("Welche Taste startet das Diktat? Die Fn-Taste sieht Windows nicht – deshalb ist F5 voreingestellt.", 14),
        new HotkeyChooser(_controller.Settings, _controller.Hook),
        Ui.Caption("Halten = diktieren · zweimal tippen oder Taste + Leertaste = Dauer-Modus · Esc = verwerfen · Strg+Alt+V = letztes Diktat erneut einfügen."));

    private UIElement TryIt() => Page("Probier es aus",
        Ui.Text($"Klick in ein Textfeld, halte {_controller.Settings.Hotkey.Label} und sprich einen Satz. Beim Loslassen steht der Text da.", 14),
        Ui.Text("Die kleine Leiste unten am Bildschirm zeigt, dass Redefluss zuhört. Du kannst sie mit der Maus verschieben oder anklicken, um ohne Taste zu diktieren.", 14, Ui.Secondary),
        Ui.Text("Redefluss sitzt im Infobereich der Taskleiste (ggf. unter ˄). Dort findest du Einstellungen und Verlauf.", 14, Ui.Secondary),
        Ui.Text("Meetings (Zoom, Teams, Meet …) schreibt Redefluss automatisch mit, sobald sie das Mikrofon benutzen – abschaltbar unter Einstellungen → Allgemein.", 14, Ui.Secondary),
        Ui.Caption("Hinweis: In Programme, die als Administrator laufen, kann Redefluss nicht tippen – dort landet der Text in der Zwischenablage."));
}
