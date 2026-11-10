using Redefluss.Core.Hotkey;

namespace Redefluss.Core.Tests;

/// <summary>
/// Gleiches Tastenverhalten wie die Mac-Version (HotkeyMonitorTests), mit Windows-Tastencodes:
/// halten = aufnehmen, loslassen = einfügen, Doppeltipp = Dauer-Modus bis zum nächsten Druck.
/// </summary>
public sealed class HotkeyEngineTests
{
    private readonly HotkeyEngine _engine = new();
    private readonly List<HotkeyEvent> _events = [];
    private double _clock = 1000;

    private const int A = 0x41, LeftArrow = 0x25, F13 = 0x7C, F18 = 0x81;
    private static readonly HotkeyOption F18Key = new(HotkeyKind.Key, F18, "F18");

    public HotkeyEngineTests()
    {
        _engine.Hotkey = HotkeyOption.F5;
        _engine.Now = () => _clock;
        _engine.Event += _events.Add;
    }

    // MARK: Halten

    [Fact]
    public void HoldAndReleaseRecordsAndStops()
    {
        Assert.True(Key(Vk.F5, down: true), "F5 darf nie in der App landen (kein Neuladen im Browser)");
        Assert.Equal([HotkeyEvent.Start], _events);
        Advance(1.5);
        Assert.True(Key(Vk.F5, down: false));
        Assert.Equal([HotkeyEvent.Start, HotkeyEvent.Stop], _events);
    }

    [Fact]
    public void AutorepeatWhileHoldingIsSwallowedAndStartsNothing()
    {
        Key(Vk.F5, down: true);
        for (var i = 0; i < 20; i++) { Advance(0.033); Assert.True(Key(Vk.F5, down: true)); }
        Advance(1);
        Key(Vk.F5, down: false);
        Assert.Equal([HotkeyEvent.Start, HotkeyEvent.Stop], _events);
    }

    [Fact]
    public void AccidentalShortTapIsDiscarded()
    {
        Key(Vk.F5, down: true); Advance(0.1); Key(Vk.F5, down: false);
        Assert.Equal([HotkeyEvent.Start, HotkeyEvent.Cancel], _events);
    }

    // MARK: Doppeltipp → Dauer-Modus

    [Fact]
    public void DoubleTapStartsHandsFreeUntilNextPress()
    {
        DoubleTap();
        Assert.Equal([HotkeyEvent.Start, HotkeyEvent.Cancel, HotkeyEvent.Start, HotkeyEvent.LockHandsFree], _events);

        Advance(20);
        Assert.Equal(4, _events.Count);

        Key(Vk.F5, down: true);
        Assert.Equal(HotkeyEvent.Stop, _events[^1]);
        Advance(0.1);
        Key(Vk.F5, down: false);
        Assert.Equal(5, _events.Count);

        Advance(1);
        Key(Vk.F5, down: true); Advance(1); Key(Vk.F5, down: false);
        Assert.Equal([HotkeyEvent.Start, HotkeyEvent.Stop], _events[^2..]);
    }

    [Fact]
    public void TwoTapsTooFarApartAreNotADoubleTap()
    {
        Key(Vk.F5, down: true); Advance(0.08); Key(Vk.F5, down: false);
        Advance(0.8);
        Key(Vk.F5, down: true);
        Assert.Equal([HotkeyEvent.Start, HotkeyEvent.Cancel, HotkeyEvent.Start], _events);
        Advance(1); Key(Vk.F5, down: false);
        Assert.Equal(HotkeyEvent.Stop, _events[^1]);
    }

    [Fact]
    public void DoubleTapDisabledWhenHandsFreeOff()
    {
        _engine.HandsFreeEnabled = false;
        Key(Vk.F5, down: true); Advance(0.08); Key(Vk.F5, down: false);
        Advance(0.15);
        Key(Vk.F5, down: true); Advance(1); Key(Vk.F5, down: false);
        Assert.Equal([HotkeyEvent.Start, HotkeyEvent.Cancel, HotkeyEvent.Start, HotkeyEvent.Stop], _events);
    }

    // MARK: Taste + Leertaste, Esc, Kombinationen

    [Fact]
    public void HotkeySpaceLocksHandsFreeAndSwallowsSpace()
    {
        Key(Vk.F5, down: true);
        Assert.True(Key(Vk.Space, down: true), "Leertaste darf nicht in der App landen");
        Assert.True(Key(Vk.Space, down: false));
        Key(Vk.F5, down: false);
        Assert.Equal([HotkeyEvent.Start, HotkeyEvent.LockHandsFree], _events);
    }

    [Fact]
    public void HeldSpaceRepeatsAreSwallowedInHandsFree()
    {
        Key(Vk.F5, down: true);
        Key(Vk.Space, down: true);
        Advance(0.5);
        Assert.True(Key(Vk.Space, down: true), "Autorepeat der Leertaste tippt keine Leerzeichen");
        Assert.True(Key(Vk.Space, down: false));
    }

    [Fact]
    public void EscapeCancelsWhileHolding()
    {
        Key(Vk.F5, down: true);
        Assert.True(Key(Vk.Escape, down: true));
        Assert.True(Key(Vk.Escape, down: false));
        Advance(1);
        Key(Vk.F5, down: false);
        Assert.Equal([HotkeyEvent.Start, HotkeyEvent.Cancel], _events);
    }

    [Fact]
    public void EscapeCancelsHandsFree()
    {
        DoubleTap();
        Advance(3);
        Assert.True(Key(Vk.Escape, down: true));
        Assert.Equal(HotkeyEvent.Cancel, _events[^1]);
    }

    [Fact]
    public void HotkeyPlusOtherKeyIsPassedThroughAndCancels()
    {
        Key(Vk.F5, down: true);
        Assert.False(Key(LeftArrow, down: true), "F5+Pfeil muss als Pfeil bei der App ankommen");
        Assert.Equal([HotkeyEvent.Start, HotkeyEvent.Cancel], _events);
        Assert.True(Key(Vk.F5, down: false), "Loslassen der Diktiertaste bleibt geschluckt");
        Assert.Equal(2, _events.Count);
    }

    [Fact]
    public void NormalTypingIsNeverSwallowed()
    {
        Assert.False(Key(A, down: true));
        Assert.False(Key(A, down: false));
        Assert.False(Key(Vk.Space, down: true));
        Assert.False(Key(Vk.Escape, down: true));
        Assert.Empty(_events);
    }

    [Fact]
    public void PasteLastShortcutIsCtrlLeftAltV()
    {
        Key(Vk.LControl, down: true); Key(Vk.LMenu, down: true);
        Assert.True(Key(Vk.V, down: true));
        Assert.True(Key(Vk.V, down: false));
        Key(Vk.LMenu, down: false); Key(Vk.LControl, down: false);
        Assert.Equal([HotkeyEvent.PasteLast], _events);

        Key(Vk.LControl, down: true);
        Assert.False(Key(Vk.V, down: true), "Normales Strg+V bleibt unberührt");
        Key(Vk.V, down: false); Key(Vk.LControl, down: false);

        // AltGr (rechte Alt) + V ist keine Tastenkombination für Redefluss.
        Key(Vk.RMenu, down: true);
        Assert.False(Key(Vk.V, down: true));
        Assert.Single(_events);
    }

    [Fact]
    public void PasteLastIgnoresShiftAndWin()
    {
        Key(Vk.LControl, down: true); Key(Vk.LMenu, down: true); Key(Vk.LShift, down: true);
        Assert.False(Key(Vk.V, down: true));
        Assert.Empty(_events);
    }

    // MARK: Modifier als Diktiertaste

    [Fact]
    public void RightControlAsHotkeyIsNeverSwallowed()
    {
        _engine.Hotkey = HotkeyOption.RightControl;
        Assert.False(Key(Vk.RControl, down: true), "Strg selbst muss weiter bei der App ankommen");
        Advance(0.6); Assert.False(Key(Vk.RControl, down: true));   // Autorepeat
        Advance(0.4);
        Assert.False(Key(Vk.RControl, down: false));
        Assert.Equal([HotkeyEvent.Start, HotkeyEvent.Stop], _events);

        // Linke Strg löst nichts aus.
        Key(Vk.LControl, down: true); Advance(1); Key(Vk.LControl, down: false);
        Assert.Equal(2, _events.Count);
    }

    [Fact]
    public void ModifierHotkeyPlusLetterCancelsAndPasses()
    {
        _engine.Hotkey = HotkeyOption.RightControl;
        Key(Vk.RControl, down: true);
        Assert.False(Key(0x43, down: true), "Strg+C muss kopieren");
        Assert.Equal([HotkeyEvent.Start, HotkeyEvent.Cancel], _events);
    }

    [Fact]
    public void KeyHeldBeforeHotkeyOnlyRepeatsAndDoesNotCancel()
    {
        // Wer Umschalt schon hält und dann die Diktiertaste drückt, bekommt Autorepeat von Umschalt.
        Key(Vk.LShift, down: true);
        Key(Vk.F5, down: true);
        Advance(0.5); Assert.False(Key(Vk.LShift, down: true));
        Advance(0.5);
        Key(Vk.F5, down: false);
        Assert.Equal([HotkeyEvent.Start, HotkeyEvent.Stop], _events);
    }

    // MARK: Eigene Taste

    [Fact]
    public void CustomKeyHoldAndShortTapAndDoubleTap()
    {
        _engine.Hotkey = F18Key;
        Key(F18, down: true); Advance(0.08); Key(F18, down: false);
        Advance(0.15);
        Key(F18, down: true); Advance(0.08); Key(F18, down: false);
        Assert.Equal([HotkeyEvent.Start, HotkeyEvent.Cancel, HotkeyEvent.Start, HotkeyEvent.LockHandsFree], _events);
        Advance(5);
        Assert.True(Key(F18, down: true));
        Assert.Equal(HotkeyEvent.Stop, _events[^1]);
    }

    [Fact]
    public void OtherKeysDoNotTriggerTheHotkey()
    {
        Assert.False(Key(F13, down: true));
        Assert.False(Key(F13, down: false));
        Assert.Empty(_events);
    }

    // MARK: Software-Tipps (Logi Options+ & Co.)

    [Fact]
    public void InstantTapsToggleHandsFree()
    {
        Assert.True(Key(Vk.F5, down: true)); Assert.True(Key(Vk.F5, down: false));
        Assert.Equal([HotkeyEvent.Start, HotkeyEvent.LockHandsFree], _events);
        Advance(5);
        Key(Vk.F5, down: true); Key(Vk.F5, down: false);
        Assert.Equal([HotkeyEvent.Start, HotkeyEvent.LockHandsFree, HotkeyEvent.Stop], _events);
        Advance(1);
        Key(Vk.F5, down: true); Advance(1); Key(Vk.F5, down: false);
        Assert.Equal([HotkeyEvent.Start, HotkeyEvent.Stop], _events[^2..]);
    }

    [Fact]
    public void InstantTapWithoutHandsFreeIsDiscarded()
    {
        _engine.HandsFreeEnabled = false;
        Key(Vk.F5, down: true); Key(Vk.F5, down: false);
        Assert.Equal([HotkeyEvent.Start, HotkeyEvent.Cancel], _events);
    }

    [Fact]
    public void HumanShortTapStillCancels()
    {
        Key(Vk.F5, down: true); Advance(0.04); Key(Vk.F5, down: false);
        Assert.Equal([HotkeyEvent.Start, HotkeyEvent.Cancel], _events);
    }

    // MARK: Verlorenes Loslassen, Aussetzen

    [Fact]
    public void LostKeyUpDoesNotLockTheHotkeyForever()
    {
        Key(Vk.F5, down: true); Advance(1); Key(Vk.F5, down: false);
        // Drücken, dann geht das Loslassen verloren (z. B. Sperrbildschirm) …
        Key(Vk.F5, down: true);
        _engine.Reset();
        Advance(60);
        // … der nächste echte Druck muss trotzdem wieder ein Diktat starten.
        _events.Clear();
        _engine.ForgetPressedKeys();
        Key(Vk.F5, down: true); Advance(1); Key(Vk.F5, down: false);
        Assert.Equal([HotkeyEvent.Start, HotkeyEvent.Stop], _events);
    }

    [Fact]
    public void StaleDownLongAgoCountsAsNewPress()
    {
        Key(Vk.F5, down: true); Advance(1); Key(Vk.F5, down: false);
        _events.Clear();
        Key(Vk.F5, down: true);              // Loslassen geht verloren …
        _engine.Reset();                     // (Controller hat die Aufnahme beendet)
        Advance(60);
        Key(Vk.F5, down: true);              // … der nächste echte Druck zählt trotzdem.
        Advance(1);
        Key(Vk.F5, down: false);
        Assert.Equal([HotkeyEvent.Start, HotkeyEvent.Start, HotkeyEvent.Stop], _events);
    }

    [Fact]
    public void SuspendedEnginePassesEverythingThrough()
    {
        _engine.IsSuspended = true;
        Assert.False(Key(Vk.F5, down: true)); Advance(1); Assert.False(Key(Vk.F5, down: false));
        Key(Vk.LControl, down: true); Key(Vk.LMenu, down: true);
        Assert.False(Key(Vk.V, down: true), "Auch Strg+Alt+V bleibt unberührt");
        Key(Vk.V, down: false); Key(Vk.LMenu, down: false); Key(Vk.LControl, down: false);
        Assert.Empty(_events);

        _engine.IsSuspended = false;
        Key(Vk.F5, down: true); Advance(1); Key(Vk.F5, down: false);
        Assert.Equal([HotkeyEvent.Start, HotkeyEvent.Stop], _events);
    }

    [Fact]
    public void ResetAfterClickStopReturnsToIdle()
    {
        _engine.EnterHandsFree();
        _engine.Reset();
        Key(Vk.F5, down: true); Advance(1); Key(Vk.F5, down: false);
        Assert.Equal([HotkeyEvent.Start, HotkeyEvent.Stop], _events);
    }

    // MARK: Helfer

    private void DoubleTap()
    {
        Key(Vk.F5, down: true); Advance(0.08); Key(Vk.F5, down: false);
        Advance(0.15);
        Key(Vk.F5, down: true); Advance(0.08); Key(Vk.F5, down: false);
    }

    private void Advance(double seconds) => _clock += seconds;

    private bool Key(int vk, bool down) => _engine.Handle(new KeyInput(vk, down));
}
