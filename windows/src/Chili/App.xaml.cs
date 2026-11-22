using System.Globalization;
using Chili.Core;
using Chili.ViewModels;
using Microsoft.UI.Xaml;

namespace Chili;

public partial class App : Application
{
    public static AppModel Model { get; private set; } = null!;
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

    protected override void OnLaunched(LaunchActivatedEventArgs args)
    {
        Model = new AppModel();
        window = new MainWindow(Model);
        window.Activate();
    }
}
