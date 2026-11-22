using Chili.Core;
using Chili.Core.Proxmox;
using Chili.ViewModels;
using Windows.System;

namespace Chili.Services;

/// <summary>Opens consoles: SPICE through remote-viewer, otherwise Proxmox' web consoles.</summary>
public sealed class Consoles(AppModel model)
{
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
            try { config = await session.Api.SpiceConfigAsync(vm); }
            catch (NoSpiceException)
            {
                // No SPICE display: fall back to Proxmox' noVNC console.
                await OpenWebConsoleAsync(session, new WebConsoleKind.Vm(vm));
                return;
            }
            await ViewerLauncher.LaunchAsync(config, $"{vm.DisplayName} ({vm.VmId})", model.Settings.Preferences.Fullscreen);
        }
        catch (Exception e) { await model.PresentAsync(e); }
        finally { if (item is not null) item.Busy = false; }
    }

    /// <summary>noVNC for VMs, xterm.js for containers and node shells, served by Proxmox.
    /// For now in the default browser; an embedded WebView2 tab comes next.</summary>
    public async Task OpenWebConsoleAsync(ServerSession session, WebConsoleKind kind)
    {
        try { await Launcher.LaunchUriAsync(session.Api.WebConsoleUri(kind)); }
        catch (Exception e) { await model.PresentAsync(e); }
    }
}
