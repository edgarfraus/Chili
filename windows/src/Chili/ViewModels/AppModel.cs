using Chili.Core;
using Chili.Services;

namespace Chili.ViewModels;

/// <summary>App-wide state: saved servers, their sessions, error reporting.</summary>
public sealed class AppModel
{
    public SettingsStore Settings { get; } = new(Demo.IsOn);
    private readonly Dictionary<Guid, ServerSession> sessions = [];

    /// <summary>Raised when the server list changes (sidebar rebuild).</summary>
    public event Action? ServersChanged;
    /// <summary>Shows a message to the user (set by the main window).</summary>
    public Func<string, string, Task>? ShowAlert { get; set; }

    /// <summary>Open built-in consoles, in sidebar order.</summary>
    public List<ConsoleSession> Consoles { get; } = [];

    public ServerSession Session(ServerProfile profile)
    {
        if (sessions.TryGetValue(profile.Id, out var s) && s.Profile == profile) return s;
        s?.Stop();
        s = new ServerSession(profile, this);
        sessions[profile.Id] = s;
        return s;
    }

    public void Save(ServerProfile profile, string? secret)
    {
        Settings.Upsert(profile);
        if (!profile.RememberSecret) Credentials.Delete(profile.Id);
        else if (!string.IsNullOrEmpty(secret)) Credentials.Save(profile.Id, secret);
        if (sessions.Remove(profile.Id, out var old)) old.Stop();
        ServersChanged?.Invoke();
    }

    public void Delete(ServerProfile profile)
    {
        Settings.Remove(profile);
        Credentials.Delete(profile.Id);
        if (sessions.Remove(profile.Id, out var old)) old.Stop();
        ServersChanged?.Invoke();
    }

    public async Task PresentAsync(Exception error)
    {
        Debug.Log($"alert: {error.Message}");
        if (ShowAlert is { } show) await show(L.T("Something went wrong"), error.Message);
    }
}
