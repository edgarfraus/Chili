namespace Chili.ViewModels;

public enum ConsoleState { Connecting, Connected, Disconnected }

/// <summary>An open console in the sidebar: a built-in SPICE display or a Proxmox web console
/// (noVNC, xterm.js) in WebView2.</summary>
public interface IConsole
{
    Guid Id { get; }
    string Title { get; }
    ConsoleState State { get; }
    /// <summary>State changed (sidebar dot, console view).</summary>
    event Action? Changed;
    void Close();
}
