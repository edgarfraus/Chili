using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;
using Microsoft.Windows.AppLifecycle;

namespace Chili;

/// <summary>Single instance: a second launch (double-clicking a .vv file, a spice:// link,
/// the Start menu) hands its command line to the running Chili and exits.</summary>
public static class Program
{
    [STAThread]
    private static int Main(string[] args)
    {
        WinRT.ComWrappersSupport.InitializeComWrappers();
        if (RedirectedToRunningInstance()) return 0;
        Application.Start(p =>
        {
            SynchronizationContext.SetSynchronizationContext(
                new DispatcherQueueSynchronizationContext(DispatcherQueue.GetForCurrentThread()));
            _ = new App();
        });
        return 0;
    }

    /// <summary>The command line of this launch (without the executable).</summary>
    public static IReadOnlyList<string> Arguments { get; private set; } = Environment.GetCommandLineArgs().Skip(1).ToList();

    private static bool RedirectedToRunningInstance()
    {
        // Demo and debug-action runs never join a real Chili (snapshot-only runs do, to test this).
        bool dev = Environment.GetEnvironmentVariable("CHILI_DEMO") is { Length: > 0 }
                   || Environment.GetEnvironmentVariable("CHILI_DEBUG_ACTION") is { Length: > 0 };
        var key = AppInstance.FindOrRegisterForKey(dev ? $"chili-dev-{Environment.ProcessId}" : "chili-main");
        if (key.IsCurrent)
        {
            key.Activated += (_, e) => OnActivated(e);
            return false;
        }
        var activation = AppInstance.GetCurrent().GetActivatedEventArgs();
        // Don't block the STA on the async call: run it on the thread pool and wait there.
        Task.Run(() => key.RedirectActivationToAsync(activation).AsTask()).Wait();
        return true;
    }

    /// <summary>Another launch was redirected here (on a background thread).</summary>
    private static void OnActivated(AppActivationArguments e)
    {
        var commandLine = e.Data is Windows.ApplicationModel.Activation.ILaunchActivatedEventArgs launch ? launch.Arguments : "";
        var args = Core.LaunchArguments.Split(commandLine);
        // Unpackaged apps get the whole command line, executable included.
        if (args.Count > 0 && args[0].EndsWith(".exe", StringComparison.OrdinalIgnoreCase)) args.RemoveAt(0);
        App.Current?.HandleLaunch(args);
    }
}
