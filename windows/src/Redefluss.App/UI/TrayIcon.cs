using Redefluss.Core.Storage;
using Forms = System.Windows.Forms;

namespace Redefluss.App.UI;

/// <summary>Symbol im Infobereich der Taskleiste – entspricht dem Menüleisten-Symbol der Mac-Version.</summary>
public sealed class TrayIcon : IDisposable
{
    private readonly DictationController _controller;
    private readonly Forms.NotifyIcon _icon;
    private readonly Forms.ContextMenuStrip _menu = new();

    public event Action<SettingsTab>? OpenSettings;
    public event Action? Quit;

    public TrayIcon(DictationController controller)
    {
        _controller = controller;
        using var stream = System.Windows.Application.GetResourceStream(new Uri("pack://application:,,,/Assets/Redefluss.ico"))!.Stream;
        _icon = new Forms.NotifyIcon
        {
            Icon = new System.Drawing.Icon(stream, Forms.SystemInformation.SmallIconSize),
            Text = "Redefluss",
            Visible = true,
            ContextMenuStrip = _menu,
        };
        _menu.Opening += (_, _) => Build();
        _icon.MouseClick += (_, e) => { if (e.Button == Forms.MouseButtons.Left) OpenSettings?.Invoke(SettingsTab.General); };
        controller.StateChanged += UpdateTooltip;
        Build();
        UpdateTooltip();
    }

    private string Status => _controller.Meeting.CurrentState == Meeting.MeetingRecorder.State.Recording && _controller.Phase == Phase.Idle
        ? $"Meeting läuft ({_controller.Meeting.AppName}) · {Core.Meeting.MeetingClock.Format(_controller.Meeting.Elapsed)}"
        : _controller.Phase switch
    {
        Phase.Recording or Phase.RecordingHandsFree => "Hört zu …",
        Phase.Transcribing => "Schreibt …",
        _ => _controller.ModelState switch
        {
            ModelState.Loading l => $"Lädt {l.Name} …",
            ModelState.Failed => "Modell konnte nicht geladen werden",
            ModelState.None => "Kein Sprachmodell",
            _ => _controller.HotkeyActive
                ? $"Bereit – {_controller.Settings.Hotkey.ShortLabel} halten zum Diktieren"
                : "Diktiertaste inaktiv",
        },
    };

    private void UpdateTooltip()
    {
        // NotifyIcon.Text ist auf 127 Zeichen begrenzt.
        var text = $"Redefluss – {Status}";
        _icon.Text = text.Length > 127 ? text[..127] : text;
    }

    private void Build()
    {
        _menu.Items.Clear();
        _menu.Items.Add(new Forms.ToolStripMenuItem(Status) { Enabled = false });
        _menu.Items.Add(new Forms.ToolStripSeparator());

        var meeting = _controller.Meeting;
        switch (meeting.CurrentState)
        {
            case Meeting.MeetingRecorder.State.Recording:
                _menu.Items.Add(new Forms.ToolStripMenuItem($"Meeting-Mitschrift beenden ({meeting.AppName})", null, (_, _) => _controller.StopMeeting()));
                break;
            case Meeting.MeetingRecorder.State.Finishing:
                _menu.Items.Add(new Forms.ToolStripMenuItem("Meeting wird gespeichert …") { Enabled = false });
                break;
            default:
                _menu.Items.Add(new Forms.ToolStripMenuItem("Meeting jetzt mitschreiben", null, (_, _) => _controller.StartMeetingManually()));
                break;
        }
        _menu.Items.Add(new Forms.ToolStripMenuItem("Meetings automatisch mitschreiben", null,
            (_, _) => _controller.Settings.MeetingAutoRecord = !_controller.Settings.MeetingAutoRecord)
        {
            Checked = _controller.Settings.MeetingAutoRecord,
        });
        _menu.Items.Add(new Forms.ToolStripSeparator());

        var paste = new Forms.ToolStripMenuItem("Letztes Diktat einfügen", null, (_, _) => _controller.PasteLast())
        {
            ShortcutKeyDisplayString = "Strg+Alt+V",
            Enabled = _controller.LastTranscript is not null,
        };
        _menu.Items.Add(paste);
        _menu.Items.Add(new Forms.ToolStripMenuItem("Letztes Diktat kopieren", null, (_, _) => _controller.CopyLast())
        {
            Enabled = _controller.LastTranscript is not null,
        });
        _menu.Items.Add(new Forms.ToolStripSeparator());

        var language = new Forms.ToolStripMenuItem("Sprache");
        foreach (var (code, name) in SupportedLanguage.All)
        {
            var c = code;
            language.DropDownItems.Add(new Forms.ToolStripMenuItem(name, null, (_, _) => _controller.Settings.Language = c)
            {
                Checked = _controller.Settings.Language == code,
            });
        }
        _menu.Items.Add(language);
        _menu.Items.Add(new Forms.ToolStripMenuItem("Verlauf …", null, (_, _) => OpenSettings?.Invoke(SettingsTab.History)));
        _menu.Items.Add(new Forms.ToolStripMenuItem("Einstellungen …", null, (_, _) => OpenSettings?.Invoke(SettingsTab.General)));
        _menu.Items.Add(new Forms.ToolStripSeparator());
        _menu.Items.Add(new Forms.ToolStripMenuItem("Redefluss beenden", null, (_, _) => Quit?.Invoke()));
    }

    public void Dispose()
    {
        _controller.StateChanged -= UpdateTooltip;
        _icon.Visible = false;
        _icon.Dispose();
        _menu.Dispose();
    }
}
