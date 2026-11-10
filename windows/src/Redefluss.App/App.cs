using System.Windows;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Threading;
using Redefluss.App.Transcription;
using Redefluss.App.UI;
using Redefluss.Core.Hotkey;
using Redefluss.Core.Models;
using Redefluss.Core.Storage;

namespace Redefluss.App;

public sealed class App : Application
{
    private static Mutex? _singleInstance;
    private DictationController? _controller;
    private TrayIcon? _tray;
    private SettingsWindow? _settingsWindow;
    private OnboardingWindow? _onboarding;
    private IDisposable? _whisperLog;

    public static ImageSource IconImage { get; } =
        BitmapFrame.Create(new Uri("pack://application:,,,/Assets/Redefluss.ico"));

    [STAThread]
    public static int Main(string[] args)
    {
        // Nur eine Redefluss-Instanz – zwei Tastatur-Hooks würden sich gegenseitig die Taste wegnehmen.
        _singleInstance = new Mutex(initiallyOwned: true, @"Local\Redefluss.SingleInstance", out var isFirst);
        if (!isFirst) return 0;

        var app = new App { ShutdownMode = ShutdownMode.OnExplicitShutdown };
        app.DispatcherUnhandledException += (_, e) =>
        {
            // Lieber eine Meldung in der Leiste als ein Absturz mitten im Schreiben.
            Log.Error("Unbehandelt (UI)", e.Exception);
            e.Handled = true;
            app._controller?.FlowBar.ShowMessage("Unerwarteter Fehler – Details im Protokoll", isError: true, seconds: 4);
        };
        AppDomain.CurrentDomain.UnhandledException += (_, e) => Log.Error("Unbehandelt", (Exception)e.ExceptionObject);
        TaskScheduler.UnobservedTaskException += (_, e) =>
        {
            Log.Error("Unbeobachtete Aufgabe", e.Exception);
            e.SetObserved();
        };
        return app.Run();
    }

    protected override void OnStartup(StartupEventArgs e)
    {
        base.OnStartup(e);
        Log.Info($"Start {typeof(App).Assembly.GetName().Version} · {Environment.OSVersion}");
        KeyNames.SystemName = Native.NativeMethods.SystemKeyName;
        _whisperLog = WhisperTranscriber.RouteLogs(m => Log.Info($"whisper: {m}"));

        var settings = AppSettings.Load();
        var models = new ModelManager();
        var history = new HistoryStore();
        _controller = new DictationController(settings, models, history, Dispatcher);
        _controller.NeedsAttention += ShowSettings;
        _controller.Start();
        LaunchAtLogin.Refresh();

        _tray = new TrayIcon(_controller);
        _tray.OpenSettings += ShowSettings;
        _tray.Quit += Quit;

        var autostart = e.Args.Contains("--autostart");
        if (!settings.OnboardingDone) ShowOnboarding();
        else if (!autostart && _controller.ModelState is ModelState.None) ShowSettings(SettingsTab.Model);
    }

    private void ShowSettings(SettingsTab tab)
    {
        if (_controller is null) return;
        if (_settingsWindow is null)
        {
            _settingsWindow = new SettingsWindow(_controller, ShowOnboarding);
            _settingsWindow.Closed += (_, _) => _settingsWindow = null;
        }
        _settingsWindow.Show(tab);
    }

    private void ShowOnboarding()
    {
        if (_controller is null) return;
        if (_onboarding is not null)
        {
            _onboarding.Activate();
            return;
        }
        _onboarding = new OnboardingWindow(_controller);
        _onboarding.Closed += (_, _) => _onboarding = null;
        _onboarding.Show();
        _onboarding.Activate();
    }

    private void Quit()
    {
        _tray?.Dispose();
        _controller?.Dispose();
        _whisperLog?.Dispose();
        Shutdown();
    }

    protected override void OnExit(ExitEventArgs e)
    {
        _tray?.Dispose();
        _singleInstance?.ReleaseMutex();
        base.OnExit(e);
    }
}
