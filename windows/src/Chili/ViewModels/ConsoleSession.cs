using Chili.Core;
using Chili.Spice;
using Microsoft.UI.Dispatching;

namespace Chili.ViewModels;

/// <summary>An open console in the sidebar: a built-in SPICE display. Reconnecting asks for a
/// fresh ticket when the console came from Proxmox (tickets are single-use and expire after
/// ~30 s); plain SPICE connections reuse their settings.</summary>
public sealed class ConsoleSession
{
    public Guid Id { get; } = Guid.NewGuid();
    public string Title { get; }
    public SpiceConnection Connection { get; private set; }
    private ViewerConfig config;
    private readonly Func<Task<ViewerConfig>>? freshConfig;
    private readonly DispatcherQueue ui;

    /// <summary>State or connection object changed (sidebar dot, console view).</summary>
    public event Action? Changed;

    public ConsoleSession(ViewerConfig config, string title, Func<Task<ViewerConfig>>? freshConfig, DispatcherQueue ui)
    {
        Title = config["title"] is { Length: > 0 } t ? t : title;
        this.config = config;
        this.freshConfig = freshConfig;
        this.ui = ui;
        Connection = Attach(config);
    }

    private SpiceConnection Attach(ViewerConfig c)
    {
        var connection = new SpiceConnection(c.Entries, ui);
        connection.Changed += () => Changed?.Invoke();
        ClipboardSync.Attach(connection);
        return connection;
    }

    public void Connect() => Connection.Connect(audio: true);

    public async Task ReconnectAsync()
    {
        if (freshConfig is not null) config = await freshConfig();
        Connection.Dispose();
        Connection = Attach(config);
        Changed?.Invoke();
        Connect();
    }

    public void Close()
    {
        Connection.Disconnect();
        Connection.Dispose();
    }
}
