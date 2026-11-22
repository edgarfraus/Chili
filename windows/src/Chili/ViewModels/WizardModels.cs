using Chili.Core;
using Chili.Core.Proxmox;
using Chili.Services;

namespace Chili.ViewModels;

/// <summary>Loads what the VM wizard can choose from and runs the creation. Port of VMWizardModel.</summary>
public sealed class VMWizardModel(ServerSession session)
{
    public ServerSession Session { get; } = session;
    private ProxmoxClient Api => Session.Api;

    public VMDraft Draft { get; } = new();
    public List<string> Nodes { get; private set; } = [];
    public List<Storage> DiskStorages { get; private set; } = [];
    public List<StorageItem> Isos { get; private set; } = [];
    public List<NetworkInterface> Bridges { get; private set; } = [];
    public int MaxCores { get; private set; } = 16;
    public int MaxMemoryMiB { get; private set; } = 32768;
    public string? Error { get; set; }

    public IEnumerable<StorageItem> VirtioIsos => Isos.Where(i => i.FileName.Contains("virtio", StringComparison.OrdinalIgnoreCase));

    public async Task LoadAsync()
    {
        try
        {
            Nodes = Demo.IsOn ? ["pve1"] : await Api.NodesAsync();
            if (Draft.Node.Length == 0 || !Nodes.Contains(Draft.Node)) Draft.Node = Nodes.FirstOrDefault() ?? "";
            await LoadNodeAsync();
        }
        catch (Exception e) { Error = e.Message; }
    }

    public async Task LoadNodeAsync()
    {
        var node = Draft.Node;
        if (node.Length == 0) return;
        try
        {
            if (Demo.IsOn) FillDemo();
            else
            {
                var id = Api.NextVmIdAsync();
                var disks = Api.StoragesAsync(node, "images");
                var isoStores = Api.StoragesAsync(node, "iso");
                var nets = Api.BridgesAsync(node);
                var status = Api.NodeStatusAsync(node);
                Draft.VmId = await id;
                DiskStorages = await disks;
                Bridges = await nets;
                var found = new List<StorageItem>();
                foreach (var store in await isoStores)
                    try { found.AddRange(await Api.IsoImagesAsync(node, store.Name)); } catch (ProxmoxException) { }
                Isos = found;
                try
                {
                    var st = await status;
                    var recommended = VMDraft.CpuTypeForHostFlags(st.Cpu?.Flags);
                    if (Draft.CpuType == Draft.RecommendedCpuType) Draft.CpuType = recommended;
                    Draft.RecommendedCpuType = recommended;
                    MaxCores = Math.Max(1, st.Cpu?.Cpus ?? 16);
                    MaxMemoryMiB = Math.Max(1024, (int)((st.Memory?.Total ?? 32L << 30) >> 20));
                }
                catch (ProxmoxException) { }
            }
            if (!DiskStorages.Any(s => s.Name == Draft.DiskStorage))
            {
                // Prefer the usual VM storages, then the one with most free space.
                Draft.DiskStorage = (DiskStorages.FirstOrDefault(s => s.Name is "local-lvm" or "local-zfs")
                                     ?? DiskStorages.MaxBy(s => s.Avail ?? 0))?.Name ?? "";
            }
            if (!DiskStorages.Any(s => s.Name == Draft.EfiStorage)) Draft.EfiStorage = Draft.DiskStorage;
            if (!Bridges.Any(b => b.Iface == Draft.Bridge))
                Draft.Bridge = (Bridges.FirstOrDefault(b => b.Iface == "vmbr0") ?? Bridges.FirstOrDefault())?.Iface ?? "";
            Draft.VirtioIso ??= VirtioIsos.LastOrDefault()?.VolId;
        }
        catch (Exception e) { Error = e.Message; }
    }

    /// <summary>Sensible sizes when the OS changes (only if the user didn't pick their own).</summary>
    public void OsChanged(VMDraft.OS old)
    {
        (int Cores, int Mem, int Disk) Defaults(VMDraft.OS os) => VMDraft.IsWindows(os) ? (4, 8192, 64) : (2, 4096, 32);
        var now = Defaults(Draft.Os);
        var before = Defaults(old);
        if (Draft.Cores == before.Cores) Draft.Cores = Math.Min(now.Cores, MaxCores);
        if (Draft.MemoryMiB == before.Mem) Draft.MemoryMiB = Math.Min(now.Mem, MaxMemoryMiB);
        if (Draft.DiskSizeGB == before.Disk) Draft.DiskSizeGB = now.Disk;
    }

    /// <summary>Creates the VM and waits for the task. Returns the created VM (null in demo mode).</summary>
    public async Task<ProxmoxVM?> CreateAsync(bool recommended, Action<string> progress)
    {
        if (recommended) Draft.ApplyChiliPreset();
        progress(L.T("Creating the VM…"));
        if (Demo.IsOn) { await Task.Delay(1500); return null; }
        var upid = await Api.CreateVmAsync(Draft.Node, Draft.Parameters);
        await Api.WaitForTaskAsync(Draft.Node, upid);
        await Session.ReloadAsync();
        return Session.VMs.FirstOrDefault(v => v.VmId == Draft.VmId && v.Node == Draft.Node);
    }

    private void FillDemo()
    {
        Draft.VmId = 107;
        DiskStorages = [new() { Name = "local-lvm", Avail = 412L << 30 }, new() { Name = "tank", Avail = 3L << 40 }];
        Bridges = [new() { Iface = "vmbr0" }, new() { Iface = "vmbr1", Comments = "lab" }];
        Isos =
        [
            new() { VolId = "local:iso/debian-13.1.0-amd64-netinst.iso" },
            new() { VolId = "local:iso/ubuntu-24.04.3-live-server-amd64.iso" },
            new() { VolId = "local:iso/virtio-win-0.1.271.iso" },
            new() { VolId = "local:iso/Win11_24H2_Italian_x64.iso" },
        ];
    }
}

/// <summary>Loads what the container wizard can choose from and runs the creation
/// (downloading the template first when needed). Port of ContainerWizardModel.</summary>
public sealed class ContainerWizardModel(ServerSession session)
{
    public ServerSession Session { get; } = session;
    private ProxmoxClient Api => Session.Api;

    public ContainerDraft Draft { get; } = new();
    public List<string> Nodes { get; private set; } = [];
    public List<Storage> RootStorages { get; private set; } = [];
    public List<Storage> TemplateStorages { get; private set; } = [];
    public List<StorageItem> Templates { get; private set; } = [];
    public List<Appliance> Appliances { get; private set; } = [];
    public List<NetworkInterface> Bridges { get; private set; } = [];
    public int MaxCores { get; private set; } = 16;
    public int MaxMemoryMiB { get; private set; } = 32768;
    public string? Error { get; set; }

    /// <summary>Catalogue entries not already downloaded.</summary>
    public IEnumerable<Appliance> Downloadable
    {
        get
        {
            var present = Templates.Select(t => t.FileName).ToHashSet();
            return Appliances.Where(a => !present.Contains(a.Template));
        }
    }

    public async Task LoadAsync()
    {
        try
        {
            Nodes = Demo.IsOn ? ["pve1"] : await Api.NodesAsync();
            if (Draft.Node.Length == 0 || !Nodes.Contains(Draft.Node)) Draft.Node = Nodes.FirstOrDefault() ?? "";
            await LoadNodeAsync();
        }
        catch (Exception e) { Error = e.Message; }
    }

    public async Task LoadNodeAsync()
    {
        var node = Draft.Node;
        if (node.Length == 0) return;
        try
        {
            if (Demo.IsOn) FillDemo();
            else
            {
                var id = Api.NextVmIdAsync();
                var roots = Api.StoragesAsync(node, "rootdir");
                var tmplStores = Api.StoragesAsync(node, "vztmpl");
                var nets = Api.BridgesAsync(node);
                var status = Api.NodeStatusAsync(node);
                Draft.VmId = await id;
                RootStorages = await roots;
                TemplateStorages = await tmplStores;
                Bridges = await nets;
                var found = new List<StorageItem>();
                foreach (var store in TemplateStorages)
                    try { found.AddRange(await Api.ContainerTemplatesAsync(node, store.Name)); } catch (ProxmoxException) { }
                Templates = found;
                try { Appliances = await Api.AppliancesAsync(node); } catch (ProxmoxException) { Appliances = []; }
                try
                {
                    var st = await status;
                    MaxCores = Math.Max(1, st.Cpu?.Cpus ?? 16);
                    MaxMemoryMiB = Math.Max(512, (int)((st.Memory?.Total ?? 32L << 30) >> 20));
                }
                catch (ProxmoxException) { }
            }
            if (!RootStorages.Any(s => s.Name == Draft.RootStorage))
                Draft.RootStorage = (RootStorages.FirstOrDefault(s => s.Name is "local-lvm" or "local-zfs")
                                     ?? RootStorages.MaxBy(s => s.Avail ?? 0))?.Name ?? "";
            if (!TemplateStorages.Any(s => s.Name == Draft.DownloadStorage))
                Draft.DownloadStorage = (TemplateStorages.FirstOrDefault(s => s.Name == "local") ?? TemplateStorages.FirstOrDefault())?.Name ?? "";
            if (!Bridges.Any(b => b.Iface == Draft.Bridge))
                Draft.Bridge = (Bridges.FirstOrDefault(b => b.Iface == "vmbr0") ?? Bridges.FirstOrDefault())?.Iface ?? "";
            if (Draft.Template.Length == 0)
            {
                // Prefer a template that is already there, else the newest Debian from the catalogue.
                Draft.Template = Templates.LastOrDefault()?.VolId
                    ?? (Appliances.LastOrDefault(a => a.Template.StartsWith("debian-")) is { } d ? ContainerDraft.DownloadPrefix + d.Template : "");
            }
        }
        catch (Exception e) { Error = e.Message; }
    }

    public async Task<ProxmoxVM?> CreateAsync(Action<string> progress)
    {
        var d = Draft;
        var ostemplate = d.Template;
        if (d.WantsDownload)
        {
            progress(L.F("Downloading %@…", d.DownloadName));
            if (!Demo.IsOn)
            {
                var dl = await Api.DownloadTemplateAsync(d.Node, d.DownloadStorage, d.DownloadName);
                await Api.WaitForTaskAsync(d.Node, dl, TimeSpan.FromMinutes(30));
            }
            ostemplate = $"{d.DownloadStorage}:vztmpl/{d.DownloadName}";
        }
        progress(L.T("Creating the container…"));
        if (Demo.IsOn) { await Task.Delay(1500); return null; }
        var upid = await Api.CreateContainerAsync(d.Node, d.Parameters(ostemplate));
        await Api.WaitForTaskAsync(d.Node, upid, TimeSpan.FromMinutes(15));
        await Session.ReloadAsync();
        return Session.VMs.FirstOrDefault(v => v.VmId == d.VmId && v.Node == d.Node);
    }

    private void FillDemo()
    {
        Draft.VmId = 107;
        RootStorages = [new() { Name = "local-lvm", Avail = 412L << 30 }];
        TemplateStorages = [new() { Name = "local", Avail = 61L << 30 }];
        Bridges = [new() { Iface = "vmbr0" }];
        Templates = [new() { VolId = "local:vztmpl/debian-13-standard_13.1-2_amd64.tar.zst" }];
        Appliances =
        [
            new() { Template = "alpine-3.22-default_20250617_amd64.tar.xz", Section = "system" },
            new() { Template = "debian-13-standard_13.1-2_amd64.tar.zst", Section = "system" },
            new() { Template = "ubuntu-24.04-standard_24.04-2_amd64.tar.zst", Section = "system" },
        ];
    }
}
