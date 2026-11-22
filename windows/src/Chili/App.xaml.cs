using System.Globalization;
using Chili.Core;
using Chili.ViewModels;
using Microsoft.UI.Xaml;

namespace Chili;

public partial class App : Application
{
    public static AppModel Model { get; private set; } = null!;
    /// <summary>Open windows (for finding a control's HWND).</summary>
    public static List<Window> Windows { get; } = [];
    private MainWindow? window;

    public App()
    {
        // Dev aid: CHILI_LANG=it / en for screenshots in either language.
        if (Environment.GetEnvironmentVariable("CHILI_LANG") is { Length: > 0 } lang)
        {
            var culture = new CultureInfo(lang);
            CultureInfo.CurrentUICulture = culture;
            CultureInfo.CurrentCulture = culture;
            L.Use(culture);
        }
        InitializeComponent();
        UnhandledException += (_, e) => Services.Debug.Log($"unhandled: {e.Exception}");
    }

    public static new App? Current => Application.Current as App;

    protected override void OnLaunched(LaunchActivatedEventArgs args)
    {
        Model = new AppModel();
        window = new MainWindow(Model);
        Windows.Add(window);
        window.Activate();
        HandleLaunch(Program.Arguments);
    }

    /// <summary>Opens a .vv file or spice:// link from the command line (this launch or a
    /// redirected one). May be called from any thread.</summary>
    public void HandleLaunch(IReadOnlyList<string> args)
    {
        var target = LaunchArguments.Target(args);
        window?.DispatcherQueue.TryEnqueue(async () =>
        {
            if (window is null) return;
            window.BringToFront();
            if (target is not null) await window.OpenTargetAsync(target);
        });
    }
}
