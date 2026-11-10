using System.Diagnostics;
using Microsoft.Win32;

namespace Redefluss.App;

/// <summary>Einfaches Log in %LOCALAPPDATA%\Redefluss\logs\redefluss.log – nie Diktat-Text, nie Audio.</summary>
public static class Log
{
    public static string Directory { get; } =
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Redefluss", "logs");

    private static readonly object Gate = new();
    private static string FilePath => Path.Combine(Directory, "redefluss.log");

    public static void Info(string message) => Write("INFO", message);
    public static void Error(string context, Exception e) => Write("FEHLER", $"{context}: {e}");

    private static void Write(string level, string message)
    {
        try
        {
            lock (Gate)
            {
                System.IO.Directory.CreateDirectory(Directory);
                var info = new FileInfo(FilePath);
                // Klein halten: bei 2 MB einmal umbenennen.
                if (info.Exists && info.Length > 2_000_000) File.Move(FilePath, FilePath + ".1", overwrite: true);
                File.AppendAllText(FilePath, $"{DateTime.Now:yyyy-MM-dd HH:mm:ss.fff} {level} {message}{Environment.NewLine}");
            }
        }
        catch (IOException) { }
        catch (UnauthorizedAccessException) { }
        Debug.WriteLine($"{level} {message}");
    }
}

public static class Shell
{
    public static void Open(string target)
    {
        try { Process.Start(new ProcessStartInfo(target) { UseShellExecute = true }); }
        catch (Exception e) { Log.Error($"Öffnen {target}", e); }
    }
}

/// <summary>„Beim Anmelden starten" über HKCU\…\Run – braucht keine Adminrechte.</summary>
public static class LaunchAtLogin
{
    private const string Key = @"Software\Microsoft\Windows\CurrentVersion\Run";
    private const string Name = "Redefluss";

    public static bool IsEnabled
    {
        get
        {
            using var key = Registry.CurrentUser.OpenSubKey(Key);
            return key?.GetValue(Name) is string;
        }
        set
        {
            using var key = Registry.CurrentUser.CreateSubKey(Key);
            if (value) key.SetValue(Name, $"\"{Environment.ProcessPath}\" --autostart");
            else key.DeleteValue(Name, throwOnMissingValue: false);
        }
    }

    /// <summary>Nach einem Update an anderem Ort den Pfad im Autostart nachziehen.</summary>
    public static void Refresh()
    {
        if (IsEnabled) IsEnabled = true;
    }
}
