using Chili.Core;
using Chili.ViewModels;
using Microsoft.UI.Xaml.Controls;

namespace Chili.Views;

/// <summary>New VM: "Recommended for Chili" (essentials + Chili's preset) or "Custom" (every
/// option, as in the Proxmox wizard). Port of VMWizardView.</summary>
public sealed class VMWizardWindow : WizardWindow
{
    private readonly VMWizardModel model;
    private readonly MainWindow main;
    private bool recommended = true;
    private readonly RadioButtons mode = new() { MaxColumns = 2 };

    public VMWizardWindow(ServerSession session, MainWindow main) : base(L.T("New Virtual Machine"), "vm-wizard")
    {
        model = new VMWizardModel(session);
        this.main = main;
        mode.Items.Add(L.T("Recommended for Chili"));
        mode.Items.Add(L.T("Custom"));
        mode.SelectedIndex = 0;
        mode.SelectionChanged += (_, _) => { recommended = mode.SelectedIndex == 0; Rebuild(); };
        Header.Children.Add(mode);
        Header.Children.Add(Description);
        Start();
    }

    /// <summary>Debug actions: open in the Custom mode.</summary>
    public void SetCustom(bool custom) => mode.SelectedIndex = custom ? 1 : 0;

    /// <summary>Debug actions: Windows 11 with the drivers ISO, once the lists are loaded.</summary>
    public async void DebugSelectWindows()
    {
        while (model.Isos.Count == 0) await Task.Delay(200);
        var old = D.Os;
        D.Os = VMDraft.OS.Win11;
        model.OsChanged(old);
        D.Name = "win11-office";
        D.Iso = model.Isos.FirstOrDefault(i => i.FileName.StartsWith("Win", StringComparison.OrdinalIgnoreCase))?.VolId;
        Rebuild();
    }

    private VMDraft D => model.Draft;
    protected override List<string> Problems => D.Problems;

    protected override async Task LoadAsync()
    {
        await model.LoadAsync();
        Error = model.Error;
    }

    protected override void Build(Form f)
    {
        Description.Text = recommended
            ? L.T("Pick the essentials; Chili sets up SPICE display and audio, the guest agent, VirtIO devices and, for Windows 11, UEFI with TPM 2.0.")
            : L.T("Every option, as in the Proxmox wizard.");
        if (recommended) BuildRecommended(f); else BuildCustom(f);
    }

    private Task NodeChanged(string node)
    {
        D.Node = node;
        return model.LoadNodeAsync();
    }

    private void IsoPicker(Form f, string label, string? selected, Action<string?> set, Panel? target = null) =>
        f.Choice(label, new[] { (L.T("None"), "") }.Concat(model.Isos.Select(i => (i.FileName, i.VolId))), selected ?? "",
                 v => { set(v.Length == 0 ? null : v); Validate(); }, 400, target);

    private void OsPicker(Form f, string label, Panel? target = null) =>
        f.Choice(label, Enum.GetValues<VMDraft.OS>().Select(o => (VMDraft.OsLabel(o), o)), D.Os, os =>
        {
            var old = D.Os;
            D.Os = os;
            model.OsChanged(old);
            Rebuild();
        }, 320, target);

    private void BuildRecommended(Form f)
    {
        NodePicker(f, model.Nodes, D.Node, NodeChanged);
        f.Text(L.T("Name"), D.Name, v => { D.Name = v; Validate(); }, "win11-office");
        OsPicker(f, L.T("Operating system"));
        IsoPicker(f, L.T("Installation ISO"), D.Iso, v => D.Iso = v);
        if (VMDraft.IsWindows(D.Os))
        {
            IsoPicker(f, L.T("VirtIO drivers ISO"), D.VirtioIso, v => { D.VirtioIso = v; Rebuild(); });
            f.Row(null, Form.Caption(D.VirtioIso is null
                ? L.T("Without the drivers ISO, Chili uses SATA and Intel network devices that Windows recognises by itself.")
                : L.T("During setup, load the disk driver from the VirtIO CD (vioscsi\\w11\\amd64), then install virtio-win-guest-tools for networking, clipboard and resizing.")));
        }
        f.Divider();
        f.Number(L.T("CPU cores"), D.Cores, 1, model.MaxCores, v => D.Cores = v);
        f.Number(L.T("Memory"), Math.Max(1, D.MemoryMiB / 1024), 1, Math.Max(1, model.MaxMemoryMiB / 1024), v => D.MemoryMiB = v * 1024, unit: "GB");
        f.Number(L.T("Disk size"), D.DiskSizeGB, 1, 65536, v => D.DiskSizeGB = v, unit: "GB");
        StoragePicker(f, L.T("Disk storage"), model.DiskStorages, D.DiskStorage, v => D.DiskStorage = v);
        BridgePicker(f, model.Bridges, D.Bridge, v => D.Bridge = v);
        f.Number(L.T("VLAN tag (0 = none)"), D.VlanTag, 0, 4094, v => D.VlanTag = v);
        f.Divider();
        f.Check(L.T("Start the VM and open its console"), D.StartAfterCreate, v => D.StartAfterCreate = v);
        f.Row(null, Form.Caption($"ID {D.VmId} · CPU {D.RecommendedCpuType}"));
    }

    private void BuildCustom(Form f)
    {
        var general = f.Section(L.T("General"));
        NodePicker(f, model.Nodes, D.Node, NodeChanged, general);
        f.Number(L.T("VM ID"), D.VmId, 100, 999_999_999, v => { D.VmId = v; Validate(); }, target: general);
        f.Text(L.T("Name"), D.Name, v => { D.Name = v; Validate(); }, target: general);
        f.Check(L.T("Start at boot"), D.StartAtBoot, v => D.StartAtBoot = v, general);

        var os = f.Section(L.T("OS"));
        IsoPicker(f, L.T("Installation ISO"), D.Iso, v => D.Iso = v, os);
        OsPicker(f, L.T("Guest OS type"), os);
        if (VMDraft.IsWindows(D.Os)) IsoPicker(f, L.T("VirtIO drivers ISO"), D.VirtioIso, v => D.VirtioIso = v, os);

        var system = f.Section(L.T("System"));
        f.Choice(L.T("Machine"), Enum.GetValues<VMDraft.Machine>().Select(m => (m.ToString().ToLowerInvariant(), m)), D.MachineType,
                 v => D.MachineType = v, 160, system);
        f.Choice(L.T("BIOS"), new[] { ("SeaBIOS", VMDraft.BIOS.SeaBIOS), ("OVMF (UEFI)", VMDraft.BIOS.OVMF) }, D.Bios,
                 v => { D.Bios = v; Rebuild(); }, 200, system);
        if (D.Bios == VMDraft.BIOS.OVMF || D.AddTpm)
            StoragePicker(f, L.T("EFI/TPM storage"), model.DiskStorages, D.EfiStorage, v => D.EfiStorage = v, system);
        f.Check(L.T("Add TPM 2.0"), D.AddTpm, v => { D.AddTpm = v; Rebuild(); }, system);
        f.Choice(L.T("SCSI controller"), VMDraft.ScsiControllers.Select(s => (s, s)), D.ScsiController, v => D.ScsiController = v, 220, system);
        f.Check(L.T("QEMU guest agent"), D.GuestAgent, v => D.GuestAgent = v, system);

        var disk = f.Section(L.T("Disk"));
        f.Choice(L.T("Bus"), Enum.GetValues<VMDraft.Bus>().Select(b => (VMDraft.BusLabel(b), b)), D.DiskBus, v => D.DiskBus = v, 200, disk);
        StoragePicker(f, L.T("Storage"), model.DiskStorages, D.DiskStorage, v => D.DiskStorage = v, disk);
        f.Number(L.T("Size"), D.DiskSizeGB, 1, 65536, v => D.DiskSizeGB = v, unit: "GB", target: disk);
        f.Choice(L.T("Cache"), VMDraft.CacheModes.Select(c => (c.Length == 0 ? L.T("Default (no cache)") : c, c)), D.DiskCache,
                 v => D.DiskCache = v, 220, disk);
        f.Check(L.T("Discard"), D.Discard, v => D.Discard = v, disk);
        f.Check(L.T("IO thread"), D.IoThread, v => D.IoThread = v, disk);
        f.Check(L.T("SSD emulation"), D.SsdEmulation, v => D.SsdEmulation = v, disk);

        var cpu = f.Section(L.T("CPU"));
        f.Number(L.T("Sockets"), D.Sockets, 1, 4, v => D.Sockets = v, target: cpu);
        f.Number(L.T("Cores"), D.Cores, 1, model.MaxCores, v => D.Cores = v, target: cpu);
        f.Choice(L.T("Type"), VMDraft.CpuTypes.Select(t => (t, t)), D.CpuType, v => D.CpuType = v, 220, cpu);

        var memory = f.Section(L.T("Memory"));
        f.Number(L.T("Memory"), D.MemoryMiB, 256, model.MaxMemoryMiB, v => D.MemoryMiB = v, 512, "MiB", memory);
        f.Check(L.T("Ballooning device"), D.Ballooning, v => { D.Ballooning = v; Rebuild(); }, memory);
        if (D.Ballooning)
            f.Number(L.T("Minimum memory"), D.MinMemoryMiB, 0, D.MemoryMiB, v => D.MinMemoryMiB = v, 512, "MiB", memory);

        var network = f.Section(L.T("Network"));
        BridgePicker(f, model.Bridges, D.Bridge, v => D.Bridge = v, network);
        f.Choice(L.T("Model"), Enum.GetValues<VMDraft.NetModel>().Select(m => (VMDraft.NetModelLabel(m), m)), D.Net, v => D.Net = v, 260, network);
        f.Number(L.T("VLAN tag (0 = none)"), D.VlanTag, 0, 4094, v => D.VlanTag = v, target: network);
        f.Check(L.T("Firewall"), D.Firewall, v => D.Firewall = v, network);

        var display = f.Section(L.T("Display & audio"));
        f.Choice(L.T("Display"), Enum.GetValues<VMDraft.Display>().Select(d => (VMDraft.DisplayLabel(d), d)), D.DisplayType,
                 v => { D.DisplayType = v; Rebuild(); }, 260, display);
        if (D.DisplayType == VMDraft.Display.Spice)
        {
            f.Number(L.T("Monitors"), D.Monitors, 1, 4, v => D.Monitors = v, target: display);
            f.Check(L.T("SPICE audio"), D.Audio, v => D.Audio = v, display);
        }

        var after = f.Section(L.T("After creation"));
        f.Check(L.T("Start the VM and open its console"), D.StartAfterCreate, v => D.StartAfterCreate = v, after);
    }

    protected override async Task<Func<Task>?> CreateAsync(Action<string> progress)
    {
        var vm = await model.CreateAsync(recommended, progress);
        if (vm is null || !D.StartAfterCreate) return null;
        // The list may still say "VM 106": use the name from the form for the console title.
        var named = vm with { Name = vm.Name ?? (D.Name.Trim() is { Length: > 0 } n ? n : null) };
        return () => main.Consoles.ConnectAsync(model.Session, named);
    }
}
