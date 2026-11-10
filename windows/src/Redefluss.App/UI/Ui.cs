using System.Windows;
using System.Windows.Controls;
using System.Windows.Data;
using System.Windows.Media;

namespace Redefluss.App.UI;

/// <summary>Kleine Bausteine für die Fenster – im Code statt XAML, damit alles an einer Stelle steht.</summary>
internal static class Ui
{
    public static readonly Brush Secondary = new SolidColorBrush(Color.FromRgb(0x6B, 0x6B, 0x70));
    public static readonly Brush Accent = new SolidColorBrush(Color.FromRgb(0x2F, 0x6F, 0xEB));
    public static readonly Brush Warning = new SolidColorBrush(Color.FromRgb(0xC2, 0x6A, 0x00));
    public static readonly Brush Success = new SolidColorBrush(Color.FromRgb(0x1E, 0x8E, 0x3E));
    public static readonly Brush Danger = new SolidColorBrush(Color.FromRgb(0xC6, 0x28, 0x28));
    public static readonly Brush Card = new SolidColorBrush(Color.FromRgb(0xF6, 0xF6, 0xF8));

    public static TextBlock Text(string text, double size = 13, Brush? color = null, FontWeight? weight = null) => new()
    {
        Text = text,
        FontSize = size,
        Foreground = color ?? Brushes.Black,
        FontWeight = weight ?? FontWeights.Normal,
        TextWrapping = TextWrapping.Wrap,
        Margin = new Thickness(0, 2, 0, 2),
    };

    public static TextBlock Caption(string text) => Text(text, 12, Secondary);

    public static TextBlock Heading(string text) => Text(text, 13, Brushes.Black, FontWeights.SemiBold);

    /// <summary>Abschnitt mit Überschrift und grauer Karte.</summary>
    public static StackPanel Section(string? title, params UIElement[] children)
    {
        var outer = new StackPanel { Margin = new Thickness(0, 0, 0, 14) };
        if (title is not null)
        {
            var heading = Heading(title);
            heading.Margin = new Thickness(2, 0, 0, 4);
            outer.Children.Add(heading);
        }
        var inner = new StackPanel();
        foreach (var child in children) inner.Children.Add(child);
        outer.Children.Add(new Border { Background = Card, CornerRadius = new CornerRadius(8), Padding = new Thickness(12, 8, 12, 8), Child = inner });
        return outer;
    }

    public static CheckBox Toggle(string label, object source, string property)
    {
        var box = new CheckBox { Content = label, Margin = new Thickness(0, 4, 0, 4), FontSize = 13 };
        box.SetBinding(System.Windows.Controls.Primitives.ToggleButton.IsCheckedProperty,
            new Binding(property) { Source = source, Mode = BindingMode.TwoWay });
        return box;
    }

    public static Button Button(string label, Action onClick, bool primary = false)
    {
        var button = new Button
        {
            Content = label,
            Padding = new Thickness(12, 4, 12, 4),
            Margin = new Thickness(0, 4, 8, 4),
            HorizontalAlignment = HorizontalAlignment.Left,
            MinWidth = 80,
        };
        if (primary)
        {
            button.Background = Accent;
            button.Foreground = Brushes.White;
            button.BorderBrush = Accent;
        }
        button.Click += (_, _) => onClick();
        return button;
    }

    public static Grid Row(string label, UIElement control)
    {
        var grid = new Grid { Margin = new Thickness(0, 4, 0, 4) };
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(190) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        var text = Text(label);
        text.VerticalAlignment = VerticalAlignment.Center;
        grid.Children.Add(text);
        Grid.SetColumn((FrameworkElement)control, 1);
        grid.Children.Add(control);
        return grid;
    }

    public static StackPanel Horizontal(params UIElement[] children)
    {
        var panel = new StackPanel { Orientation = Orientation.Horizontal };
        foreach (var child in children) panel.Children.Add(child);
        return panel;
    }

    public static ScrollViewer Scroll(UIElement content) => new()
    {
        Content = content,
        VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
        Padding = new Thickness(18, 14, 18, 14),
    };
}
