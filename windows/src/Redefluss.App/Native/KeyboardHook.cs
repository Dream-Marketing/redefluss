using System.Runtime.InteropServices;
using System.Windows.Threading;
using Redefluss.Core.Hotkey;
using static Redefluss.App.Native.NativeMethods;

namespace Redefluss.App.Native;

/// <summary>
/// Globaler Tastatur-Hook (WH_KEYBOARD_LL) auf einem eigenen Thread mit Nachrichtenschleife.
/// Eigener Thread, weil Windows einen Hook, der länger als ~300 ms nicht antwortet, stillschweigend
/// entfernt – der UI-Thread ist beim Modell-Laden oder Fenster-Aufbau aber auch mal beschäftigt.
///
/// Der Hook entscheidet sofort (schlucken oder durchlassen) über <see cref="HotkeyEngine"/>;
/// deren Ereignisse gehen per Dispatcher an den UI-Thread. Unter Windows braucht das keine
/// Berechtigung – aber Fenster von Programmen mit Adminrechten sieht ein normaler Hook nicht.
/// </summary>
public sealed class KeyboardHook : IDisposable
{
    private readonly HotkeyEngine _engine;
    private readonly Dispatcher _ui;
    private readonly object _lock = new();
    private readonly LowLevelKeyboardProc _proc;
    private Thread? _thread;
    private uint _threadId;
    private IntPtr _hook;
    private Action<int>? _recordCallback;
    private int? _awaitingRecordedRelease;

    public event Action<HotkeyEvent>? Event;

    public KeyboardHook(HotkeyEngine engine, Dispatcher ui)
    {
        _engine = engine;
        _ui = ui;
        _proc = Callback;   // Delegat festhalten, sonst sammelt ihn der GC ein.
        _engine.Event += e => _ui.BeginInvoke(() => Event?.Invoke(e));
    }

    public bool IsRunning => _hook != IntPtr.Zero;

    /// <summary>Alle Zugriffe auf die Engine laufen unter dieser Sperre (Hook-Thread und UI-Thread).</summary>
    public void WithEngine(Action<HotkeyEngine> action)
    {
        lock (_lock) action(_engine);
    }

    public bool Start()
    {
        if (_thread is not null) return IsRunning;
        using var ready = new ManualResetEventSlim();
        _thread = new Thread(() =>
        {
            _threadId = GetCurrentThreadId();
            _hook = SetWindowsHookExW(WH_KEYBOARD_LL, _proc, GetModuleHandleW(null), 0);
            ready.Set();
            if (_hook == IntPtr.Zero) return;
            while (GetMessageW(out var msg, IntPtr.Zero, 0, 0) > 0) { /* Hook-Aufrufe kommen über die Schleife */ }
            UnhookWindowsHookEx(_hook);
            _hook = IntPtr.Zero;
        })
        {
            IsBackground = true,
            Name = "Redefluss Tastatur-Hook",
            Priority = ThreadPriority.Highest,
        };
        _thread.Start();
        ready.Wait(TimeSpan.FromSeconds(2));
        return IsRunning;
    }

    /// <summary>Nimmt die nächste gedrückte Taste auf (Esc bricht ab → -1) und schluckt sie. Die Engine ruht derweil.</summary>
    public void RecordNextKey(Action<int> onKey)
    {
        lock (_lock)
        {
            _recordCallback = onKey;
            _engine.IsSuspended = true;
        }
    }

    public void CancelRecording()
    {
        lock (_lock)
        {
            _recordCallback = null;
            _awaitingRecordedRelease = null;
            _engine.IsSuspended = false;
        }
    }

    private IntPtr Callback(int nCode, IntPtr wParam, IntPtr lParam)
    {
        if (nCode < 0) return CallNextHookEx(IntPtr.Zero, nCode, wParam, lParam);
        var info = Marshal.PtrToStructure<KBDLLHOOKSTRUCT>(lParam);

        // Eigene Strg+V-Tastendrücke und die unechte Strg vor AltGr nicht auswerten.
        if (info.dwExtraInfo == InjectedMarker || info.scanCode == FakeAltGrControlScanCode)
            return CallNextHookEx(IntPtr.Zero, nCode, wParam, lParam);

        var message = (int)wParam;
        var isDown = message is WM_KEYDOWN or WM_SYSKEYDOWN;
        var vk = (int)info.vkCode;
        bool swallow;

        lock (_lock)
        {
            if (_recordCallback is { } record)
            {
                // Engine ist ausgesetzt, merkt sich aber, welche Tasten unten sind.
                _engine.Handle(new KeyInput(vk, isDown));
                if (isDown)
                {
                    _recordCallback = null;
                    _awaitingRecordedRelease = vk;
                    var recorded = vk == Vk.Escape ? -1 : vk;
                    _ui.BeginInvoke(() => record(recorded));
                }
                return 1;
            }
            if (_awaitingRecordedRelease == vk)
            {
                // Erst nach dem Loslassen der aufgenommenen Taste wieder auswerten – sonst startet sie sofort ein Diktat.
                _engine.Handle(new KeyInput(vk, isDown));
                if (!isDown)
                {
                    _awaitingRecordedRelease = null;
                    _engine.IsSuspended = false;
                }
                return 1;
            }
            try
            {
                swallow = _engine.Handle(new KeyInput(vk, isDown));
            }
            catch
            {
                // Ein Fehler im Hook darf nie die Tastatur blockieren.
                swallow = false;
            }
        }
        return swallow ? 1 : CallNextHookEx(IntPtr.Zero, nCode, wParam, lParam);
    }

    public void Dispose()
    {
        if (_threadId != 0) PostThreadMessageW(_threadId, WM_QUIT, IntPtr.Zero, IntPtr.Zero);
        _thread?.Join(TimeSpan.FromSeconds(1));
        _thread = null;
    }
}
