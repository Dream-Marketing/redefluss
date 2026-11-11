using Redefluss.Core.Storage;

namespace Redefluss.Core.FlowBar;

/// <summary>Rechteck in Bildschirmkoordinaten (Ursprung oben links, y wächst nach unten).</summary>
public readonly record struct Box(double X, double Y, double Width, double Height)
{
    public double Right => X + Width;
    public double Bottom => Y + Height;
    public double CenterX => X + Width / 2;
}

/// <summary>
/// Lage der Leiste: ein durchsichtiges Fenster (360 × 64 Punkte), die sichtbare Kapsel sitzt unten mittig darin.
/// Alle Maße werden mit dem DPI-Faktor des Bildschirms skaliert; gerechnet wird in Pixeln.
/// </summary>
public sealed class FlowBarGeometry(double scale = 1)
{
    public const double Width = 360, Height = 64;
    /// <summary>Typische Kapselgröße – hält die Kapsel beim Verschieben auf dem Bildschirm.</summary>
    public const double PillWidth = 150, PillHeight = 32;
    public const double PillBottomPadding = 6;
    /// <summary>So nah an der Standardlage rastet die Leiste wieder ein.</summary>
    public const double SnapDistance = 24;

    public double Scale { get; } = scale;
    public double W => Width * Scale;
    public double H => Height * Scale;

    /// <summary>Fensterursprung für eine gespeicherte Position (null = unten mittig über der Taskleiste).</summary>
    public (double X, double Y) Origin(FlowBarPosition? position, Box work)
    {
        if (position is null) return (work.CenterX - W / 2, work.Bottom - H - PillBottomPadding * Scale);
        var cx = work.X + position.X * work.Width;
        var cy = work.Y + position.Y * work.Height;
        return Clamp((cx - W / 2, cy - H / 2), work);
    }

    /// <summary>Gespeicherte Position für einen Fensterursprung. Nahe der Standardlage rastet sie ein (null).</summary>
    public FlowBarPosition? Position((double X, double Y) origin, Box work, string? display = null)
    {
        if (work.Width <= 0 || work.Height <= 0) return null;
        var standard = Origin(null, work);
        if (Math.Abs(origin.X - standard.X) < SnapDistance * Scale && Math.Abs(origin.Y - standard.Y) < SnapDistance * Scale)
            return null;
        var (x, y) = Clamp(origin, work);
        return new FlowBarPosition((x + W / 2 - work.X) / work.Width, (y + H / 2 - work.Y) / work.Height, display);
    }

    /// <summary>Hält die Kapsel (nicht das unsichtbare Fenster) in der Arbeitsfläche – so kann sie bis an den Rand.</summary>
    public (double X, double Y) Clamp((double X, double Y) origin, Box work)
    {
        var pillW = PillWidth * Scale;
        var pillH = PillHeight * Scale;
        var pad = PillBottomPadding * Scale;
        var minX = work.X + pillW / 2 - W / 2;
        var maxX = work.Right - pillW / 2 - W / 2;
        // Oberkante der Kapsel = Fenster-Oberkante + H - pad - pillH.
        var minY = work.Y - (H - pad - pillH);
        var maxY = work.Bottom - H;
        return (Math.Min(Math.Max(origin.X, minX), Math.Max(minX, maxX)),
                Math.Min(Math.Max(origin.Y, minY), Math.Max(minY, maxY)));
    }

    /// <summary>Balkenhöhe der Wellenform: Mitte etwas höher gewichtet – wirkt wie eine Stimme.</summary>
    public static double BarHeight(IReadOnlyList<float> levels, int index, double maxHeight = 20)
    {
        var center = (levels.Count - 1) / 2.0;
        var distance = center > 0 ? Math.Abs(index - center) / center : 0;
        var weight = 1 - distance * 0.45;
        return Math.Max(3, levels[index] * maxHeight * weight);
    }
}
