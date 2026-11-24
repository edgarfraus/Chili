using Chili.Core;
using Chili.Core.Proxmox;
using Chili.Services;
using Chili.ViewModels;
using Chili.Views;

namespace Chili;

/// <summary>Live tests on a real server (CHILI_DEBUG_ACTION), through the same models the
/// wizards use. Only ever creates or deletes machines named chili-test-*, checked against
/// their configuration (the cluster list can lag right after creation).</summary>
public sealed partial class MainWindow
{
    private const string TestPrefix = "chili-test-";

    private async Task<ServerSession?> ReadySessionAsync()
    {
        if (Detail.Content is not ServerView view) return null;
        for (int i = 0; i < 60 && view.Session.State != ServerSession.SessionState.Ready; i++) await Task.Delay(500);
        return view.Session.State == ServerSession.SessionState.Ready ? view.Session : null;
    }

    /// <summary>create:linux | create:win11 | create:win11-nodrivers | create:custom</summary>
    private async Task DebugCreateVmAsync(string variant)
    {
        if (await ReadySessionAsync() is not { } session) { Debug.Log("create: not logged in"); return; }
        var model = new VMWizardModel(session);
        await model.LoadAsync();
        var d = model.Draft;
        d.Name = TestPrefix + variant;
        d.StartAfterCreate = false;
        bool recommended = variant != "custom";
        switch (variant)
        {
            case "linux":
                d.Os = VMDraft.OS.Linux;
                d.Iso = model.Isos.FirstOrDefault(i => !i.FileName.Contains("virtio", StringComparison.OrdinalIgnoreCase)
                                                       && !i.FileName.StartsWith("win", StringComparison.OrdinalIgnoreCase))?.VolId;
                break;
            case "win11" or "win11-nodrivers":
                d.Os = VMDraft.OS.Win11;
                d.Iso = model.Isos.FirstOrDefault(i => i.FileName.StartsWith("win", StringComparison.OrdinalIgnoreCase))?.VolId;
                d.VirtioIso = variant == "win11" ? model.VirtioIsos.LastOrDefault()?.VolId : null;
                break;
            case "custom":
                d.Os = VMDraft.OS.Other;
                d.Bios = VMDraft.BIOS.OVMF;
                d.DiskBus = VMDraft.Bus.Virtio;
                d.DiskCache = "writeback";
                d.Net = VMDraft.NetModel.E1000;
                d.VlanTag = 42;
                d.DisplayType = VMDraft.Display.Spice;
                d.Monitors = 2;
                d.Ballooning = true;
                d.MinMemoryMiB = 512;
                break;
        }
        // Test machines stay small: 4 GB disk, 1 GB RAM, never started.
        d.Cores = 1;
        d.MemoryMiB = 1024;
        d.DiskSizeGB = 4;
        Debug.Log($"create {variant}: node={d.Node} id={d.VmId} storage={d.DiskStorage} bridge={d.Bridge} iso={d.Iso} virtio={d.VirtioIso} problems=[{string.Join("; ", d.Problems)}]");
        try
        {
            var vm = await model.CreateAsync(recommended, p => Debug.Log($"create {variant}: {p}"));
            if (vm is null) { Debug.Log($"create {variant}: created, not listed yet"); return; }
            var config = await session.Api.ConfigAsync(vm);
            Debug.Log($"create {variant}: OK {vm.VmId}\n  " +
                      string.Join("\n  ", config.Where(kv => kv.Key != "digest").OrderBy(kv => kv.Key).Select(kv => $"{kv.Key}={kv.Value}")));
        }
        catch (Exception e) { Debug.Log($"create {variant}: FAILED {e.Message}"); }
    }

    /// <summary>ctcreate: chili-test-ct from a template already on the server (no downloads).</summary>
    private async Task DebugCreateContainerAsync()
    {
        if (await ReadySessionAsync() is not { } session) { Debug.Log("ctcreate: not logged in"); return; }
        var model = new ContainerWizardModel(session);
        await model.LoadAsync();
        var d = model.Draft;
        var template = model.Templates.FirstOrDefault(t => t.FileName.StartsWith("alpine", StringComparison.OrdinalIgnoreCase))
                       ?? model.Templates.FirstOrDefault();
        Debug.Log($"ctcreate: templates=[{string.Join(", ", model.Templates.Select(t => t.VolId))}]");
        if (template is null) { Debug.Log("ctcreate: no template on the server; not downloading one"); return; }
        d.Template = template.VolId;
        d.Hostname = TestPrefix + "ct";
        d.Password = d.PasswordConfirm = "chili-" + Guid.NewGuid().ToString("N")[..10];
        d.MemoryMiB = 256;
        d.RootSizeGB = 2;
        d.StartAfterCreate = false;
        Debug.Log($"ctcreate: node={d.Node} id={d.VmId} storage={d.RootStorage} bridge={d.Bridge} problems=[{string.Join("; ", d.Problems)}]");
        try
        {
            var ct = await model.CreateAsync(p => Debug.Log($"ctcreate: {p}"));
            if (ct is null) { Debug.Log("ctcreate: created, not listed yet"); return; }
            var config = await session.Api.ConfigAsync(ct);
            Debug.Log($"ctcreate: OK {ct.VmId}\n  " +
                      string.Join("\n  ", config.Where(kv => kv.Key != "digest").OrderBy(kv => kv.Key).Select(kv => $"{kv.Key}={kv.Value}")));
        }
        catch (Exception e) { Debug.Log($"ctcreate: FAILED {e.Message}"); }
    }

    /// <summary>spicetunnel:&lt;vmid&gt; — the Cloudflare Tunnel path without Cloudflare: an in-process
    /// WebSocket↔TCP bridge to the server's spiceproxy plays cloudflared, and a copy of the profile
    /// (in memory only) points SpiceTunnelHost at it. Opens a running VM's console through it.</summary>
    private async Task DebugSpiceTunnelAsync(int vmid)
    {
        if (await ReadySessionAsync() is not { } real) { Debug.Log("spicetunnel: not logged in"); return; }
        int port = 47000 + Random.Shared.Next(1000);
        var http = new System.Net.HttpListener();
        http.Prefixes.Add($"http://localhost:{port}/");
        http.Start();
        int bridged = 0;
        _ = Task.Run(async () =>
        {
            while (http.IsListening)
            {
                System.Net.HttpListenerContext ctx;
                try { ctx = await http.GetContextAsync(); } catch { return; }
                _ = Task.Run(async () =>
                {
                    var ws = (await ctx.AcceptWebSocketAsync(null)).WebSocket;
                    using var tcp = new System.Net.Sockets.TcpClient();
                    await tcp.ConnectAsync(real.Api.Host, 3128);
                    Interlocked.Increment(ref bridged);
                    var s = tcp.GetStream();
                    var up = Task.Run(async () =>
                    {
                        var b = new byte[65536];
                        try
                        {
                            while (true)
                            {
                                var r = await ws.ReceiveAsync(b, default);
                                if (r.MessageType == System.Net.WebSockets.WebSocketMessageType.Close) break;
                                await s.WriteAsync(b.AsMemory(0, r.Count));
                            }
                        }
                        catch { }
                    });
                    var down = Task.Run(async () =>
                    {
                        var b = new byte[65536];
                        try
                        {
                            int n;
                            while ((n = await s.ReadAsync(b)) > 0)
                                await ws.SendAsync(b.AsMemory(0, n), System.Net.WebSockets.WebSocketMessageType.Binary, true, default);
                        }
                        catch { }
                    });
                    await Task.WhenAny(up, down);
                });
            }
        });
        var session = new ServerSession(real.Profile with { SpiceTunnelHost = $"ws://localhost:{port}/" }, model);
        session.Login(real.StoredSecret ?? "");
        for (int i = 0; i < 40 && session.State != ServerSession.SessionState.Ready; i++) await Task.Delay(500);
        var vm = session.VMs.FirstOrDefault(v => v.VmId == vmid);
        Debug.Log($"spicetunnel: state={session.State} vm={vm?.DisplayName} running={vm?.IsRunning} local port={session.SpiceTunnel?.Port}");
        if (vm is not { IsRunning: true }) return;
        await Consoles.ConnectAsync(session, vm);
        await Task.Delay(8000);
        Debug.Log($"spicetunnel: websockets bridged={bridged} tunnel error={session.SpiceTunnel?.LastError ?? "none"} " +
                  $"console={model.Consoles.LastOrDefault()?.State}");
    }

    /// <summary>novnc:&lt;vmid&gt; / shell — opens a running VM's noVNC console (or the first node's
    /// shell) in a WebView2 tab and saves a PNG of the page (CHILI_DEBUG_SNAPSHOT dir, webview.png).</summary>
    private async Task DebugWebConsoleAsync(int? vmid)
    {
        if (await ReadySessionAsync() is not { } session) { Debug.Log("web: not logged in"); return; }
        if (vmid is int id)
        {
            var vm = session.VMs.FirstOrDefault(v => v.VmId == id);
            if (vm is not { IsRunning: true }) { Debug.Log($"web: VM {id} not running"); return; }
            await Consoles.OpenWebConsoleAsync(session, new WebConsoleKind.Vm(vm));
        }
        else
        {
            var node = (await session.LoadNodesAsync()).First();
            await Consoles.OpenWebConsoleAsync(session, new WebConsoleKind.NodeShell(node));
        }
        for (int i = 0; i < 40 && model.Consoles.LastOrDefault() is { State: ConsoleState.Connecting }; i++) await Task.Delay(500);
        await Task.Delay(6000);   // let noVNC connect and draw
        var console = model.Consoles.LastOrDefault() as WebConsoleSession;
        Debug.Log($"web: state={console?.State} error={console?.ErrorMessage ?? "none"}");
        if (Debug.SnapshotDir is { } dir && Detail.Content is WebConsoleView { Web.CoreWebView2: { } core })
        {
            using var stream = new Windows.Storage.Streams.InMemoryRandomAccessStream();
            await core.CapturePreviewAsync(Microsoft.Web.WebView2.Core.CoreWebView2CapturePreviewImageFormat.Png, stream);
            var bytes = new byte[stream.Size];
            stream.Seek(0);
            await stream.ReadAsync(System.Runtime.InteropServices.WindowsRuntime.WindowsRuntimeBufferExtensions.AsBuffer(bytes),
                                   (uint)bytes.Length, Windows.Storage.Streams.InputStreamOptions.None);
            await File.WriteAllBytesAsync(Path.Combine(dir, "webview.png"), bytes);
            Debug.Log($"web: page title={core.DocumentTitle}");
        }
    }

    /// <summary>cleanup: deletes every machine whose configured name/hostname starts with chili-test-.</summary>
    private async Task DebugCleanupAsync()
    {
        if (await ReadySessionAsync() is not { } session) { Debug.Log("cleanup: not logged in"); return; }
        await session.ReloadAsync();
        foreach (var vm in session.VMs.ToList())
        {
            Dictionary<string, string> config;
            try { config = await session.Api.ConfigAsync(vm); }
            catch (Exception e) { Debug.Log($"cleanup: {vm.VmId} config unreadable ({e.Message}), skipped"); continue; }
            var name = config.GetValueOrDefault(vm.IsContainer ? "hostname" : "name") ?? "";
            if (!name.StartsWith(TestPrefix, StringComparison.Ordinal)) continue;
            Debug.Log($"cleanup: deleting {vm.VmId} {name}");
            try
            {
                if (vm.IsRunning)
                {
                    var stop = await session.Api.PowerAsync(vm, PowerAction.Stop);
                    await session.Api.WaitForTaskAsync(vm.Node, stop, TimeSpan.FromMinutes(2));
                }
                var upid = await session.Api.DeleteAsync(vm);
                await session.Api.WaitForTaskAsync(vm.Node, upid);
                Debug.Log($"cleanup: deleted {vm.VmId}");
            }
            catch (Exception e) { Debug.Log($"cleanup: {vm.VmId} FAILED {e.Message}"); }
        }
        await session.ReloadAsync();
        Debug.Log("cleanup: done");
    }
}
