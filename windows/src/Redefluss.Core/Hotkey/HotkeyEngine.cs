using System.Diagnostics;

namespace Redefluss.Core.Hotkey;

/// <summary>Was der Nutzer mit der Diktiertaste gerade getan hat.</summary>
public enum HotkeyEvent
{
    /// <summary>Taste gedrückt → Aufnahme starten.</summary>
    Start,
    /// <summary>Taste losgelassen (Halten) bzw. erneut gedrückt (Dauer-Modus) → transkribieren.</summary>
    Stop,
    /// <summary>Esc, zu kurzer Tipper oder Tastenkombination → verwerfen.</summary>
    Cancel,
    /// <summary>Taste + Leertaste oder Doppeltipp → Aufnahme läuft ohne Halten weiter.</summary>
    LockHandsFree,
    /// <summary>Strg+Alt+V → letztes Diktat erneut einfügen.</summary>
    PasteLast,
}

/// <summary>Ein Tastenereignis aus dem globalen Tastatur-Hook.</summary>
public readonly record struct KeyInput(int VirtualKey, bool IsDown);

/// <summary>
/// Zustandsmaschine der Diktiertaste – dasselbe Verhalten wie der HotkeyMonitor der Mac-Version,
/// nur mit Windows-Tastencodes und ohne Systemabhängigkeit (die App füttert sie aus einem
/// WH_KEYBOARD_LL-Hook).
///
/// Halten: Taste halten, sprechen, loslassen.
/// Dauer-Modus: Taste + Leertaste oder Doppeltipp; beenden mit erneutem Druck, Esc verwirft.
/// Software-Tipp: Kommen Drücken und Loslassen im selben Augenblick (Logi Options+ & Co.), kann
/// niemand halten – dann schaltet jeder Tipp den Dauer-Modus um.
///
/// Windows kennt kein Autorepeat-Flag: Ein erneutes Drücken einer Taste, die schon unten ist, gilt als
/// Wiederholung – es sei denn, das letzte Drücken liegt lange zurück (dann ging ein Loslassen verloren,
/// z. B. am Sperrbildschirm), dann zählt es als neuer Druck.
/// </summary>
public sealed class HotkeyEngine
{
    public event Action<HotkeyEvent>? Event;

    public HotkeyOption Hotkey { get; set; } = HotkeyOption.Default;
    public bool HandsFreeEnabled { get; set; } = true;

    /// <summary>Solange eine neue Diktiertaste aufgenommen wird, geht alles unverändert durch.</summary>
    public bool IsSuspended { get; set; }

    /// <summary>Uhr in Sekunden – in Tests austauschbar.</summary>
    public Func<double> Now { get; set; } = () => Stopwatch.GetTimestamp() / (double)Stopwatch.Frequency;

    private enum State { Idle, Holding, HandsFree, AwaitingRelease }

    private State _state = State.Idle;
    private double _holdingSince;
    private double _lastShortTap = double.NegativeInfinity;
    private readonly HashSet<int> _down = [];
    private readonly Dictionary<int, double> _lastDownAt = [];
    private readonly HashSet<int> _swallowedKeyDowns = [];

    /// <summary>Kürzere Tipper gelten als Versehen (oder als erster Teil eines Doppeltipps).</summary>
    internal const double MinimumHold = 0.25;
    internal const double DoubleTapWindow = 0.4;
    /// <summary>Noch kürzer schafft kein Finger: Drücken und Loslassen kamen aus Software.</summary>
    internal const double InstantTap = 0.02;
    /// <summary>Autorepeat kommt spätestens nach der längsten Verzögerung (1 s) und dann ~30× pro Sekunde.</summary>
    internal const double RepeatGap = 1.2;

    /// <summary>Von außen zurücksetzen, z. B. wenn die Aufnahme nicht starten konnte oder per Klick beendet wurde.</summary>
    public void Reset()
    {
        _state = _state switch
        {
            State.Holding => State.AwaitingRelease,
            State.HandsFree => State.Idle,
            _ => _state,
        };
    }

    /// <summary>Dauer-Modus von außen starten (Klick auf die Leiste).</summary>
    public void EnterHandsFree() => _state = State.HandsFree;

    /// <summary>Alle gemerkten Tasten vergessen (z. B. nach Sperrbildschirm oder Benutzerwechsel).</summary>
    public void ForgetPressedKeys()
    {
        _down.Clear();
        _lastDownAt.Clear();
        _swallowedKeyDowns.Clear();
        if (_state == State.AwaitingRelease) _state = State.Idle;
    }

    /// <summary>Gibt <c>true</c> zurück, wenn das Ereignis geschluckt werden soll.</summary>
    public bool Handle(KeyInput input)
    {
        var vk = input.VirtualKey;
        var isRepeat = false;
        if (input.IsDown)
        {
            var now = Now();
            isRepeat = _down.Contains(vk) && _lastDownAt.TryGetValue(vk, out var last) && now - last < RepeatGap;
            _down.Add(vk);
            _lastDownAt[vk] = now;
        }
        else
        {
            _down.Remove(vk);
            _lastDownAt.Remove(vk);
        }

        if (IsSuspended) return false;

        if (Hotkey.Matches(vk))
        {
            if (input.IsDown)
            {
                // Autorepeat beim Halten ist kein neuer Druck.
                if (!isRepeat) HotkeyChanged(isDown: true);
            }
            else
            {
                _swallowedKeyDowns.Remove(vk);
                HotkeyChanged(isDown: false);
            }
            // Eine normale Diktiertaste landet nie in der App; Modifier gehen immer durch.
            return Hotkey.Kind == HotkeyKind.Key;
        }

        return input.IsDown ? HandleKeyDown(vk, isRepeat) : _swallowedKeyDowns.Remove(vk);
    }

    /// <summary>Die Diktiertaste wurde gedrückt oder losgelassen.</summary>
    private void HotkeyChanged(bool isDown)
    {
        var now = Now();
        // Ein frischer Druck, während noch auf das Loslassen gewartet wird: Das Loslassen ging verloren
        // (Sperrbildschirm, UAC-Dialog, Hook kurz aus) – also wie aus dem Ruhezustand behandeln.
        if (_state == State.AwaitingRelease && isDown) _state = State.Idle;
        switch (_state)
        {
            case State.Idle:
                if (!isDown) return;
                if (HandsFreeEnabled && now - _lastShortTap < DoubleTapWindow)
                {
                    _lastShortTap = double.NegativeInfinity;
                    _state = State.HandsFree;
                    Emit(HotkeyEvent.Start);
                    Emit(HotkeyEvent.LockHandsFree);
                }
                else
                {
                    _state = State.Holding;
                    _holdingSince = now;
                    Emit(HotkeyEvent.Start);
                }
                break;

            case State.Holding:
                if (isDown) return;
                var held = now - _holdingSince;
                if (held < InstantTap && HandsFreeEnabled)
                {
                    _state = State.HandsFree;
                    Emit(HotkeyEvent.LockHandsFree);
                }
                else if (held < MinimumHold)
                {
                    _state = State.Idle;
                    _lastShortTap = now;
                    Emit(HotkeyEvent.Cancel);
                }
                else
                {
                    _state = State.Idle;
                    Emit(HotkeyEvent.Stop);
                }
                break;

            case State.HandsFree:
                if (isDown)
                {
                    _state = State.AwaitingRelease;
                    Emit(HotkeyEvent.Stop);
                }
                break;

            case State.AwaitingRelease:
                if (!isDown) _state = State.Idle;
                break;
        }
    }

    private bool HandleKeyDown(int vk, bool isRepeat)
    {
        switch (_state)
        {
            case State.Idle:
                if (vk == Vk.V && IsPasteLastChord())
                {
                    if (!isRepeat) Emit(HotkeyEvent.PasteLast);
                    return Swallow(vk);
                }
                return false;

            case State.Holding:
                if (vk == Vk.Escape)
                {
                    _state = State.AwaitingRelease;
                    Emit(HotkeyEvent.Cancel);
                    return Swallow(vk);
                }
                // Eine Taste, die schon vor der Diktiertaste unten war, wiederholt sich nur.
                if (isRepeat) return false;
                if (vk == Vk.Space && HandsFreeEnabled)
                {
                    _state = State.HandsFree;
                    Emit(HotkeyEvent.LockHandsFree);
                    return Swallow(vk);
                }
                // Normale Kombination wie Strg+C oder F5+A: durchlassen, Diktat verwerfen.
                _state = State.AwaitingRelease;
                Emit(HotkeyEvent.Cancel);
                return false;

            case State.HandsFree:
                if (vk == Vk.Escape)
                {
                    _state = State.Idle;
                    Emit(HotkeyEvent.Cancel);
                    return Swallow(vk);
                }
                // Leertaste, die nach dem Sperren noch gehalten wird, wiederholt sich.
                if (vk == Vk.Space && isRepeat) return Swallow(vk);
                return false;

            case State.AwaitingRelease:
                // Taste+Leertaste zum Beenden des Dauer-Modus darf kein Leerzeichen tippen.
                if (vk is Vk.Space or Vk.Escape) return Swallow(vk);
                return false;
        }
        return false;
    }

    /// <summary>Strg + linke Alt (nicht AltGr), ohne Umschalt und Windows-Taste.</summary>
    private bool IsPasteLastChord() =>
        _down.Any(Vk.IsControl) && (_down.Contains(Vk.LMenu) || _down.Contains(Vk.Menu))
        && !_down.Any(Vk.IsShift) && !_down.Any(Vk.IsWin);

    private bool Swallow(int vk)
    {
        _swallowedKeyDowns.Add(vk);
        return true;
    }

    private void Emit(HotkeyEvent e) => Event?.Invoke(e);
}
