using Chili.Core.Proxmox;

namespace Chili.ViewModels;

/// <summary>Proxmox' own web console (noVNC for VMs, xterm.js for containers and node shells)
/// shown in WebView2. The page is logged in with the PVEAuthCookie of the server's session.</summary>
public sealed class WebConsoleSession : IConsole
{
    public Guid Id { get; } = Guid.NewGuid();
    public string Title { get; }
    public ServerSession Server { get; }
    public WebConsoleKind Kind { get; }
    public ConsoleState State { get; private set; } = ConsoleState.Connecting;
    public string? ErrorMessage { get; private set; }
    public event Action? Changed;

    /// <summary>Raised by Close so the view can drop its WebView2 right away.</summary>
    public event Action? Closed;

    public WebConsoleSession(ServerSession server, WebConsoleKind kind, string title)
    {
        Server = server;
        Kind = kind;
        Title = title;
    }

    /// <summary>A fresh ticket (they expire after two hours), the page URL and the cookie value.</summary>
    public async Task<(Uri Url, string Cookie)> PrepareAsync()
    {
        var api = Server.Api;
        // A fresh ticket for the page (logging in again if the old one expired).
        await Server.WithLoginAsync(() => api.RenewTicketAsync(Server.Profile.FullUsername));
        return (api.WebConsoleUri(Kind), api.AuthCookieValue ?? throw new InvalidOperationException("no ticket"));
    }

    public void SetState(ConsoleState state, string? error = null)
    {
        State = state;
        ErrorMessage = error;
        Changed?.Invoke();
    }

    public void Close()
    {
        Closed?.Invoke();
        State = ConsoleState.Disconnected;
    }
}
