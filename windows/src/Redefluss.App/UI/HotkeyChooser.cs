using System.Windows;
using System.Windows.Controls;
using Redefluss.App.Native;
using Redefluss.Core.Hotkey;
using Redefluss.Core.Storage;

namespace Redefluss.App.UI;

/// <summary>Auswahl der Diktiertaste: Voreinstellungen oder eine selbst aufgenommene Taste.</summary>
internal sealed class HotkeyChooser : StackPanel
{
    private readonly AppSettings _settings;
    private readonly KeyboardHook _hook;
    private readonly ComboBox _combo = new() { MinWidth = 220, HorizontalAlignment = HorizontalAlignment.Left };
    private readonly TextBlock _status = Ui.Caption("");
    private readonly TextBlock _hint = Ui.Caption("");
    private bool _recording;
    private bool _updating;

    private const string RecordItem = "Andere Taste aufnehmen …";

    public HotkeyChooser(AppSettings settings, KeyboardHook hook)
    {
        _settings = settings;
        _hook = hook;
        Children.Add(Ui.Row("Diktiertaste", _combo));
        Children.Add(_status);
        Children.Add(_hint);
        _combo.SelectionChanged += OnSelection;
        Rebuild();
        Unloaded += (_, _) => StopRecording();
    }

    private void Rebuild()
    {
        _updating = true;
        _combo.Items.Clear();
        foreach (var preset in HotkeyOption.Presets) _combo.Items.Add(new ComboBoxItem { Content = preset.Label, Tag = preset });
        if (!_settings.Hotkey.IsPreset)
            _combo.Items.Add(new ComboBoxItem { Content = _settings.Hotkey.Label, Tag = _settings.Hotkey });
        _combo.Items.Add(new ComboBoxItem { Content = RecordItem, Tag = null });
        _combo.SelectedItem = _combo.Items.Cast<ComboBoxItem>().First(i => Equals(i.Tag, _settings.Hotkey));
        _updating = false;
        UpdateHint();
    }

    private void OnSelection(object sender, SelectionChangedEventArgs e)
    {
        if (_updating || _combo.SelectedItem is not ComboBoxItem item) return;
        if (item.Tag is HotkeyOption option)
        {
            StopRecording();
            _settings.Hotkey = option;
            UpdateHint();
            return;
        }
        StartRecording();
    }

    private void StartRecording()
    {
        _recording = true;
        _status.Text = "Drück jetzt die gewünschte Taste … (Esc bricht ab)";
        _status.Foreground = Ui.Accent;
        _hook.RecordNextKey(vk =>
        {
            _recording = false;
            if (vk < 0)
            {
                _status.Text = "";
            }
            else if (HotkeyOption.Unsuitable(vk) is { } reason)
            {
                _status.Text = $"{KeyNames.Name(vk)}: {reason}";
                _status.Foreground = Ui.Warning;
            }
            else
            {
                _settings.Hotkey = HotkeyOption.FromRecordedKey(vk);
                _status.Text = $"Diktiertaste ist jetzt {_settings.Hotkey.Label}.";
                _status.Foreground = Ui.Success;
            }
            Rebuild();
        });
    }

    private void StopRecording()
    {
        if (!_recording) return;
        _recording = false;
        _hook.CancelRecording();
        _status.Text = "";
    }

    private void UpdateHint()
    {
        var key = _settings.Hotkey;
        _hint.Text = key.Equals(HotkeyOption.F5)
            ? "Halten = diktieren, zweimal tippen = Dauer-Modus. F5 lädt im Browser dann nicht mehr neu – Strg+R geht weiter. " +
              "Logitech MX Keys: In Logi Options+ der Diktat-Taste ein „Tastenkürzel“ F5 zuweisen (dann ist sie haltbar)."
            : key.Kind == HotkeyKind.Modifier
                ? $"{key.Label} allein halten = diktieren. Zusammen mit anderen Tasten funktioniert sie weiter wie gewohnt."
                : $"{key.Label} wird von Redefluss abgefangen und tippt in anderen Programmen nichts mehr.";
    }
}
