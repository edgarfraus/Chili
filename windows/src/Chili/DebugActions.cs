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
