using Chili.Core;
using Chili.Core.Proxmox;
using Chili.ViewModels;
using Windows.System;

namespace Chili.Services;

/// <summary>Opens consoles: SPICE in the built-in console (or remote-viewer, if chosen in the
/// settings), otherwise Proxmox' web consoles.</summary>
public sealed class Consoles(AppModel model, MainWindow window)
{
    private bool UseBuiltIn => !model.Settings.Preferences.UseClassicViewer && Spice.Native.IsAvailable;

    /// <summary>Opens a SPICE connection. <paramref name="freshConfig"/> gets a new ticket for
    /// Reconnect (Proxmox tickets are single-use).</summary>
    public async Task OpenSpiceAsync(ViewerConfig config, string title, Func<Task<ViewerConfig>>? freshConfig = null,
                                     Func<string?>? diagnostics = null)
    {
        try
        {
            if (UseBuiltIn)
            {
                window.OpenConsole(config, title, freshConfig, diagnostics);
                if (model.Settings.Preferences.Fullscreen && !window.IsFullScreen) window.ToggleFullScreen();
            }
            else
            {
                await ViewerLauncher.LaunchAsync(config, title, model.Settings.Preferences.Fullscreen);
            }
        }
        catch (Exception e) { await model.PresentAsync(e); }
    }

    /// <summary>Opens the VM's console, starting the VM first if needed.</summary>
    public async Task ConnectAsync(ServerSession session, ProxmoxVM vm)
    {
        var item = session.ItemFor(vm);
        if (item is { Busy: true }) return;
        if (item is not null) item.Busy = true;
        try
        {
            if (Demo.IsOn) return;
            if (!vm.IsRunning) await session.StartAndWaitAsync(vm);
            if (vm.IsContainer)
            {
                await OpenWebConsoleAsync(session, new WebConsoleKind.Vm(vm));
                return;
            }
            ViewerConfig config;
            try { config = await session.SpiceConfigAsync(vm); }
            catch (NoSpiceException)
            {
                // No SPICE display: fall back to Proxmox' noVNC console.
                await OpenWebConsoleAsync(session, new WebConsoleKind.Vm(vm));
                return;
            }
            var tunnel = session.SpiceTunnel;
            await OpenSpiceAsync(config, $"{vm.DisplayName} ({vm.VmId})", () => session.SpiceConfigAsync(vm),
                                 tunnel is null ? null : () => tunnel.LastError is { } e ? L.F("SPICE tunnel (%@): %@", session.Profile.SpiceTunnelHost, e) : null);
        }
        catch (Exception e) { await model.PresentAsync(e); }
        finally { if (item is not null) item.Busy = false; }
    }

    /// <summary>Opens a .vv file (or a spice:// link in remote-viewer).</summary>
    public async Task OpenFileAsync(string path)
    {
        try
        {
            if (!UseBuiltIn) { await ViewerLauncher.LaunchAsync([path]); return; }
            var text = await File.ReadAllTextAsync(path);
            if (!text.Contains("[virt-viewer]"))
                throw new ViewerException(L.F("“%@” is not a valid SPICE connection file.", Path.GetFileName(path)));
            var config = ViewerConfig.Parse(text);
            // Proxmox' files carry a one-time password: honour delete-this-file like remote-viewer.
            if (config["delete-this-file"] == "1") try { File.Delete(path); } catch (IOException) { }
            await OpenSpiceAsync(config, config["title"] ?? Path.GetFileNameWithoutExtension(path));
        }
        catch (Exception e) { await model.PresentAsync(e); }
    }

    /// <summary>noVNC for VMs, xterm.js for containers and node shells, served by Proxmox, in a
    /// console tab (WebView2). Without the WebView2 runtime, in the default browser.</summary>
    public async Task OpenWebConsoleAsync(ServerSession session, WebConsoleKind kind)
    {
        try
        {
            if (!session.Api.UsesTicket)
                throw new ProxmoxException(L.T("The noVNC and shell consoles need a password login: Proxmox' web pages can't use API tokens."));
            var title = kind switch
            {
                WebConsoleKind.Vm { Machine: var vm } => $"{vm.DisplayName} ({vm.VmId})",
                WebConsoleKind.NodeShell { Node: var node } => L.F("Shell – %@", node),
                _ => "",
            };
            if (HasWebView2Runtime) window.OpenWebConsole(session, kind, title);
            else await Launcher.LaunchUriAsync(session.Api.WebConsoleUri(kind));
        }
        catch (Exception e) { await model.PresentAsync(e); }
    }

    /// <summary>Microsoft Edge WebView2 Runtime (part of Windows 11; usually present on Windows 10).</summary>
    private static bool HasWebView2Runtime
    {
        get
        {
            try { return Microsoft.Web.WebView2.Core.CoreWebView2Environment.GetAvailableBrowserVersionString() is { Length: > 0 }; }
            catch { return false; }
        }
    }
}
