using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Threading;
using Redefluss.Core.Hotkey;
using static Redefluss.App.Native.NativeMethods;

namespace Redefluss.App.Native;

/// <summary>
/// Fügt Text in die fokussierte App ein: Zwischenablage setzen, Strg+V schicken,
/// danach den vorherigen Inhalt der Zwischenablage zurückholen.
/// </summary>
public sealed class TextInserter
{
    public enum Outcome
    {
        Pasted,
        /// <summary>Ziel-App läuft mit Adminrechten (oder Einfügen ging nicht): Text liegt nur in der Zwischenablage.</summary>
        CopiedOnly,
    }

    /// <summary>Windows-Zwischenablageverlauf und Cloud-Zwischenablage sollen Diktate nicht speichern.</summary>
    private const string ExcludeFormat = "ExcludeClipboardContentFromMonitorProcessing";
    private const string HistoryFormat = "CanIncludeInClipboardHistory";
    private const string CloudFormat = "CanUploadToCloudClipboard";

    private int _generation;

    public async Task<Outcome> InsertAsync(string text, bool restoreClipboard)
    {
        var target = GetForegroundWindow();
        if (target != IntPtr.Zero && IsElevated(target) && !Environment.IsPrivilegedProcess)
        {
            SetClipboard(text, conceal: false);
            return Outcome.CopiedOnly;
        }

        var saved = restoreClipboard ? Snapshot() : null;
        if (!SetClipboard(text, conceal: true)) return Outcome.CopiedOnly;
        var generation = ++_generation;
        var sequence = GetClipboardSequenceNumber();

        // Alt/Umschalt/Win, die noch gehalten werden (z. B. Strg+Alt+V), würden aus Strg+V etwas anderes machen.
        await WaitForModifierRelease();
        if (!SendPaste()) return Outcome.CopiedOnly;

        if (saved is not null)
        {
            // Manche Apps (Electron, Browser) lesen die Zwischenablage verzögert.
            await Task.Delay(600);
            // Hat der Nutzer inzwischen selbst etwas kopiert oder läuft schon ein neues Einfügen: nichts überschreiben.
            if (generation == _generation && GetClipboardSequenceNumber() == sequence)
                Restore(saved);
        }
        return Outcome.Pasted;
    }

    public void CopyToClipboard(string text) => SetClipboard(text, conceal: false);

    private static bool SetClipboard(string text, bool conceal)
    {
        var data = new DataObject();
        data.SetText(text, TextDataFormat.UnicodeText);
        if (conceal)
        {
            data.SetData(ExcludeFormat, new MemoryStream([0, 0, 0, 0]));
            data.SetData(HistoryFormat, new MemoryStream([0, 0, 0, 0]));
            data.SetData(CloudFormat, new MemoryStream([0, 0, 0, 0]));
        }
        return Retry(() => Clipboard.SetDataObject(data, copy: true));
    }

    /// <summary>Eine echte Kopie aller lesbaren Formate – das Original-Objekt lebt nur so lange wie die Zwischenablage.</summary>
    private static DataObject? Snapshot()
    {
        IDataObject? current = null;
        if (!Retry(() => current = Clipboard.GetDataObject()) || current is null) return null;
        var copy = new DataObject();
        var any = false;
        foreach (var format in current.GetFormats(autoConvert: false))
        {
            try
            {
                var value = current.GetData(format, autoConvert: false);
                if (value is null) continue;
                copy.SetData(format, value);
                any = true;
            }
            catch (COMException) { /* Format lässt sich nicht lesen (z. B. verzögert gerendert) */ }
            catch (OutOfMemoryException) { }
        }
        return any ? copy : new DataObject();
    }

    private static void Restore(DataObject saved)
    {
        if (saved.GetFormats().Length == 0) Retry(Clipboard.Clear);
        else Retry(() => Clipboard.SetDataObject(saved, copy: true));
    }

    /// <summary>Die Zwischenablage ist manchmal kurz von einer anderen App geöffnet.</summary>
    private static bool Retry(Action action)
    {
        for (var attempt = 0; attempt < 10; attempt++)
        {
            try { action(); return true; }
            catch (COMException) { Thread.Sleep(30); }
            catch (ExternalException) { Thread.Sleep(30); }
        }
        return false;
    }

    private static async Task WaitForModifierRelease()
    {
        int[] keys = [Vk.LMenu, Vk.RMenu, Vk.LShift, Vk.RShift, Vk.LWin, Vk.RWin];
        for (var i = 0; i < 75 && keys.Any(k => (GetAsyncKeyState(k) & 0x8000) != 0); i++)
            await Task.Delay(20);
    }

    /// <summary>Strg drücken, V drücken/loslassen, Strg loslassen – wie eine echte Tastatur.</summary>
    private static bool SendPaste()
    {
        // Eine noch gehaltene Strg (z. B. rechte Strg als Diktiertaste) stört nicht: Strg+V bleibt Strg+V.
        INPUT Key(int vk, bool up) => new()
        {
            type = INPUT_KEYBOARD,
            U = new InputUnion { ki = new KEYBDINPUT { wVk = (ushort)vk, dwFlags = up ? KEYEVENTF_KEYUP : 0, dwExtraInfo = InjectedMarker } },
        };
        INPUT[] inputs = [Key(Vk.LControl, false), Key(Vk.V, false), Key(Vk.V, true), Key(Vk.LControl, true)];
        return SendInput((uint)inputs.Length, inputs, Marshal.SizeOf<INPUT>()) == inputs.Length;
    }

    [DllImport("user32.dll")]
    private static extern uint GetClipboardSequenceNumber();
}
