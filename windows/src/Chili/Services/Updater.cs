using System.Diagnostics;
using System.Runtime.InteropServices;
using Chili.Core;

namespace Chili.Services;

/// <summary>Checks GitHub for a newer Windows release at launch and every 12 hours, and installs
/// it: downloads the setup, verifies its SHA-256 and runs it silently; the installer closes
/// Chili, updates it in place (same per-user / all-users mode) and starts it again.</summary>
public sealed class Updater
{
    private static readonly TimeSpan Interval = TimeSpan.FromHours(12);

    /// <summary>The running version (set by the build from VERSION).
    /// CHILI_DEBUG_UPDATE_CURRENT pretends another one, to test against real releases.</summary>
    public static Version Current { get; } = Updates.Normalize(
        Version.TryParse(Environment.GetEnvironmentVariable("CHILI_DEBUG_UPDATE_CURRENT"), out var fake) ? fake
        : typeof(Updater).Assembly.GetName().Version ?? new Version(0, 0));

    /// <summary>Installed with the setup (not a development build): updates can be applied.</summary>
    public static bool IsInstalled => File.Exists(Path.Combine(AppContext.BaseDirectory, "unins000.exe"));

    private static string Arch => RuntimeInformation.ProcessArchitecture == Architecture.Arm64 ? "arm64" : "x64";

    private readonly Func<bool> enabled;
    private readonly HttpClient http = Updates.CreateClient(Current);

    /// <summary>A newer release was found (raised on the UI thread).</summary>
    public event Action<ReleaseInfo>? Available;
    public ReleaseInfo? Pending { get; private set; }

    public Updater(Func<bool> enabled) => this.enabled = enabled;

    public void Start(Microsoft.UI.Dispatching.DispatcherQueue ui)
    {
        bool debug = Environment.GetEnvironmentVariable("CHILI_DEBUG_UPDATE_CURRENT") is { Length: > 0 };
        if (Demo.IsOn || (!IsInstalled && !debug)) return;
        var timer = ui.CreateTimer();
        timer.Interval = Interval;
        timer.Tick += async (_, _) => await CheckAsync();
        timer.Start();
        // First check a little after launch, so it doesn't compete with logging in.
        ui.TryEnqueue(async () => { await Task.Delay(TimeSpan.FromSeconds(debug ? 1 : 15)); await CheckAsync(); });
    }

    /// <summary>Scheduled check: only when automatic checks are on.</summary>
    public async Task CheckAsync()
    {
        if (!enabled()) return;
        await CheckNowAsync();
    }

    /// <summary>When the last check finished, and what it found (null: up to date).</summary>
    public DateTime? LastChecked { get; private set; }
    public string? LastError { get; private set; }

    /// <summary>Checks right away (also from the Info page, whatever the preference). Raises
    /// <see cref="Available"/> for a release not announced yet.</summary>
    public async Task<ReleaseInfo?> CheckNowAsync()
    {
        try
        {
            var release = await Updates.CheckAsync(http, Current, Arch);
            Debug.Log($"update check: current {Current}, latest {release?.Tag ?? "none newer"}");
            LastChecked = DateTime.Now;
            LastError = null;
            if (release is not null && release.Version != Pending?.Version)
            {
                Pending = release;
                Available?.Invoke(release);
            }
            return release;
        }
        catch (Exception e)
        {
            Debug.Log($"update check failed: {e.Message}");   // offline, rate-limited…: try again later
            LastError = e.Message;
            return null;
        }
    }

    /// <summary>Downloads and verifies the setup. Returns its path.</summary>
    public Task<string> DownloadAsync(ReleaseInfo release, IProgress<double> progress) =>
        Updates.DownloadAsync(http, release,
            Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Chili", "Updates"), progress);

    /// <summary>Runs the verified setup silently; it closes Chili and restarts it when done.</summary>
    public static void RunInstaller(string setup)
    {
        // Same mode as the current installation: all users when Chili lives under Program Files
        // (Windows asks for administrator rights), otherwise for this user only.
        var programFiles = Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles);
        bool allUsers = AppContext.BaseDirectory.StartsWith(programFiles, StringComparison.OrdinalIgnoreCase);
        var psi = new ProcessStartInfo(setup)
        {
            UseShellExecute = true,
            Arguments = $"/SILENT /SUPPRESSMSGBOXES /NORESTART /CLOSEAPPLICATIONS /CHILIRESTART=1 {(allUsers ? "/ALLUSERS" : "/CURRENTUSER")}",
        };
        Process.Start(psi);
    }
}
