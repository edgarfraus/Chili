using System.Text.RegularExpressions;

namespace Chili.Core;

/// <summary>Everything needed to create a QEMU VM, turned into Proxmox API parameters by
/// <see cref="Parameters"/>. The quick wizard fills it with <see cref="ApplyChiliPreset"/>; the
/// custom wizard exposes every field. Port of launcher/Sources/VMDraft.swift.</summary>
public sealed class VMDraft
{
    public enum OS { Win11, Win10, Linux, Other }
    public enum Machine { I440fx, Q35 }
    public enum BIOS { SeaBIOS, OVMF }
    public enum Bus { Scsi, Sata, Virtio, Ide }
    public enum NetModel { Virtio, E1000e, E1000, Rtl8139, Vmxnet3 }
    public enum Display { Spice, Std, Virtio, None }

    public static readonly string[] ScsiControllers = ["virtio-scsi-single", "virtio-scsi-pci", "lsi", "megasas", "pvscsi"];
    public static readonly string[] CpuTypes = ["x86-64-v2", "host", "x86-64-v2-AES", "x86-64-v3", "kvm64", "qemu64"];
    public static readonly string[] CacheModes = ["", "writeback", "writethrough", "directsync", "unsafe"];

    public static string OsType(OS os) => os switch
    {
        OS.Win11 => "win11", OS.Win10 => "win10", OS.Linux => "l26", _ => "other",
    };
    public static bool IsWindows(OS os) => os is OS.Win11 or OS.Win10;
    public static string OsLabel(OS os) => os switch
    {
        OS.Win11 => "Windows 11 / Server 2022+",
        OS.Win10 => "Windows 10 / Server 2016–2019",
        OS.Linux => "Linux",
        _ => L.T("Other"),
    };
    public static string BusName(Bus b) => b.ToString().ToLowerInvariant();
    public static string BusLabel(Bus b) => b switch
    {
        Bus.Scsi => "SCSI", Bus.Sata => "SATA", Bus.Virtio => "VirtIO Block", _ => "IDE",
    };
    public static string NetModelName(NetModel m) => m.ToString().ToLowerInvariant();
    public static string NetModelLabel(NetModel m) => m switch
    {
        NetModel.Virtio => "VirtIO (paravirtualized)",
        NetModel.E1000e => "Intel E1000E",
        NetModel.E1000 => "Intel E1000",
        NetModel.Rtl8139 => "Realtek RTL8139",
        _ => "VMware vmxnet3",
    };
    public static string DisplayLabel(Display d) => d switch
    {
        Display.Spice => L.T("SPICE (best with Chili)"),
        Display.Std => L.T("Standard VGA (noVNC)"),
        Display.Virtio => "VirtIO-GPU (noVNC)",
        _ => L.T("None"),
    };

    // General
    public string Node { get; set; } = "";
    public int VmId { get; set; } = 100;
    public string Name { get; set; } = "";
    public bool StartAtBoot { get; set; }
    // OS
    public OS Os { get; set; } = OS.Linux;
    public string? Iso { get; set; }            // volid, e.g. "local:iso/debian.iso"
    public string? VirtioIso { get; set; }      // Windows drivers
    // System
    public Machine MachineType { get; set; } = Machine.Q35;
    public BIOS Bios { get; set; } = BIOS.SeaBIOS;
    public string EfiStorage { get; set; } = "";
    public bool AddTpm { get; set; }
    public string ScsiController { get; set; } = "virtio-scsi-single";
    public bool GuestAgent { get; set; } = true;
    // Disk
    public Bus DiskBus { get; set; } = Bus.Scsi;
    public string DiskStorage { get; set; } = "";
    public int DiskSizeGB { get; set; } = 32;
    public string DiskCache { get; set; } = "";
    public bool Discard { get; set; } = true;
    public bool IoThread { get; set; } = true;
    public bool SsdEmulation { get; set; }
    // CPU
    public int Sockets { get; set; } = 1;
    public int Cores { get; set; } = 2;
    public string CpuType { get; set; } = "x86-64-v2";
    // Memory
    public int MemoryMiB { get; set; } = 4096;
    public bool Ballooning { get; set; } = true;
    public int MinMemoryMiB { get; set; }       // 0 = same as memory
    // Network
    public string Bridge { get; set; } = "";
    public NetModel Net { get; set; } = NetModel.Virtio;
    public int VlanTag { get; set; }            // 0 = none
    public bool Firewall { get; set; } = true;
    // Display & audio
    public Display DisplayType { get; set; } = Display.Spice;
    public int Monitors { get; set; } = 1;
    public bool Audio { get; set; } = true;
    // After creation
    public bool StartAfterCreate { get; set; } = true;

    /// <summary>Set from the node's CPU flags when the wizard loads.</summary>
    public string RecommendedCpuType { get; set; } = "x86-64-v2";

    /// <summary>Default CPU model: x86-64-v2 (live-migratable, starts on any recent CPU — the
    /// "-AES" variant fails on hosts without AES-NI), or "host" on CPUs too old for v2.</summary>
    public static string CpuTypeForHostFlags(string? flags)
    {
        if (flags is null) return "x86-64-v2";
        var set = flags.Split(' ', StringSplitOptions.RemoveEmptyEntries).ToHashSet();
        string[] v2 = ["cx16", "lahf_lm", "popcnt", "sse4_1", "sse4_2", "ssse3"];
        return v2.All(set.Contains) ? "x86-64-v2" : "host";
    }

    /// <summary>The settings Chili recommends: SPICE display and audio, guest agent, VirtIO where
    /// drivers are available, UEFI + TPM for Windows 11.</summary>
    public void ApplyChiliPreset()
    {
        MachineType = Machine.Q35;
        ScsiController = "virtio-scsi-single";
        GuestAgent = true;
        DisplayType = Display.Spice;
        Monitors = 1;
        Audio = true;
        CpuType = RecommendedCpuType;
        Sockets = 1;
        DiskCache = "";
        Discard = true;
        Ballooning = true;
        MinMemoryMiB = 0;
        Firewall = true;
        (Bios, AddTpm) = Os switch
        {
            OS.Win11 => (BIOS.OVMF, true),
            OS.Win10 => (BIOS.OVMF, false),
            _ => (BIOS.SeaBIOS, false),
        };
        if (IsWindows(Os))
        {
            // Without the VirtIO drivers ISO, Windows setup can't see VirtIO disks
            // or NICs: fall back to devices it supports out of the box.
            bool drivers = VirtioIso is not null;
            DiskBus = drivers ? Bus.Scsi : Bus.Sata;
            Net = drivers ? NetModel.Virtio : NetModel.E1000e;
            SsdEmulation = true;
        }
        else
        {
            DiskBus = Bus.Scsi;
            Net = NetModel.Virtio;
            SsdEmulation = false;
        }
        IoThread = DiskBus is Bus.Scsi or Bus.Virtio;
        if (EfiStorage.Length == 0) EfiStorage = DiskStorage;
    }

    public Dictionary<string, string> Parameters
    {
        get
        {
            var p = new Dictionary<string, string>
            {
                ["vmid"] = VmId.ToString(),
                ["ostype"] = OsType(Os),
                ["sockets"] = Sockets.ToString(),
                ["cores"] = Cores.ToString(),
                ["cpu"] = CpuType,
                ["memory"] = MemoryMiB.ToString(),
                ["scsihw"] = ScsiController,
                ["agent"] = GuestAgent ? "enabled=1" : "enabled=0",
            };
            var trimmed = Name.Trim();
            if (trimmed.Length > 0) p["name"] = trimmed;
            if (StartAtBoot) p["onboot"] = "1";
            if (MachineType == Machine.Q35) p["machine"] = "q35";
            p["bios"] = Bios == BIOS.OVMF ? "ovmf" : "seabios";
            var efi = EfiStorage.Length == 0 ? DiskStorage : EfiStorage;
            if (Bios == BIOS.OVMF)
                p["efidisk0"] = $"{efi}:1,efitype=4m" + (IsWindows(Os) ? ",pre-enrolled-keys=1" : "");
            if (AddTpm) p["tpmstate0"] = $"{efi}:1,version=v2.0";

            var disk = $"{DiskStorage}:{DiskSizeGB}";
            if (Discard) disk += ",discard=on";
            if (IoThread && (DiskBus == Bus.Virtio || (DiskBus == Bus.Scsi && ScsiController == "virtio-scsi-single")))
                disk += ",iothread=1";
            if (SsdEmulation && DiskBus != Bus.Virtio) disk += ",ssd=1";
            if (DiskCache.Length > 0) disk += $",cache={DiskCache}";
            var diskKey = $"{BusName(DiskBus)}0";
            p[diskKey] = disk;

            p["ide2"] = (Iso ?? "none") + ",media=cdrom";
            if (VirtioIso is not null && IsWindows(Os))
                p[DiskBus == Bus.Ide ? "ide1" : "ide0"] = VirtioIso + ",media=cdrom";

            var net = $"{NetModelName(Net)},bridge={Bridge}";
            if (Firewall) net += ",firewall=1";
            if (VlanTag > 0) net += $",tag={VlanTag}";
            p["net0"] = net;

            if (!Ballooning) p["balloon"] = "0";
            else if (MinMemoryMiB > 0 && MinMemoryMiB < MemoryMiB) p["balloon"] = MinMemoryMiB.ToString();

            p["vga"] = DisplayType switch
            {
                Display.Spice => Monitors > 1 ? $"qxl{Monitors}" : "qxl",
                Display.Std => "std",
                Display.Virtio => "virtio",
                _ => "none",
            };
            // Audio goes through SPICE; with other displays there would be no way to hear it.
            if (Audio && DisplayType == Display.Spice) p["audio0"] = "device=ich9-intel-hda,driver=spice";

            p["boot"] = $"order={diskKey};ide2;net0";
            return p;
        }
    }

    /// <summary>Problems that would make Proxmox reject the request, for the UI.</summary>
    public List<string> Problems
    {
        get
        {
            var list = new List<string>();
            if (Node.Length == 0) list.Add(L.T("Choose a node."));
            if (DiskStorage.Length == 0) list.Add(L.T("Choose a storage for the disk."));
            if (Bridge.Length == 0) list.Add(L.T("Choose a network bridge."));
            if (VmId < 100) list.Add(L.T("The VM ID must be 100 or higher."));
            if (!Names.IsValid(Name)) list.Add(L.T("The name may only contain letters, digits, dots and dashes."));
            return list;
        }
    }
}

/// <summary>An LXC container to create. Port of ContainerDraft (ContainerWizard.swift).</summary>
public sealed class ContainerDraft
{
    public enum IPv4 { Dhcp, Static }
    public enum IPv6 { Auto, Dhcp, None }

    public string Node { get; set; } = "";
    public int VmId { get; set; } = 100;
    public string Hostname { get; set; } = "";
    /// <summary>A template volid, or "download:&lt;template&gt;" for one from Proxmox' catalogue.</summary>
    public string Template { get; set; } = "";
    public string DownloadStorage { get; set; } = "";
    public string Password { get; set; } = "";
    public string PasswordConfirm { get; set; } = "";
    public string SshKey { get; set; } = "";
    public bool Unprivileged { get; set; } = true;
    public bool Nesting { get; set; } = true;
    public int Cores { get; set; } = 1;
    public int MemoryMiB { get; set; } = 1024;
    public int SwapMiB { get; set; } = 512;
    public string RootStorage { get; set; } = "";
    public int RootSizeGB { get; set; } = 8;
    public string Bridge { get; set; } = "";
    public int VlanTag { get; set; }        // 0 = untagged
    public IPv4 Ipv4 { get; set; } = IPv4.Dhcp;
    public string Address { get; set; } = "";   // CIDR, e.g. 192.168.1.50/24
    public string Gateway { get; set; } = "";
    public IPv6 Ipv6 { get; set; } = IPv6.Auto;
    public bool Firewall { get; set; } = true;
    public bool StartAtBoot { get; set; }
    public bool StartAfterCreate { get; set; } = true;

    public const string DownloadPrefix = "download:";
    public bool WantsDownload => Template.StartsWith(DownloadPrefix, StringComparison.Ordinal);
    public string DownloadName => Template[DownloadPrefix.Length..];

    public Dictionary<string, string> Parameters(string ostemplate)
    {
        var p = new Dictionary<string, string>
        {
            ["vmid"] = VmId.ToString(),
            ["ostemplate"] = ostemplate,
            ["unprivileged"] = Unprivileged ? "1" : "0",
            ["cores"] = Cores.ToString(),
            ["memory"] = MemoryMiB.ToString(),
            ["swap"] = SwapMiB.ToString(),
            ["rootfs"] = $"{RootStorage}:{RootSizeGB}",
        };
        var name = Hostname.Trim();
        if (name.Length > 0) p["hostname"] = name;
        if (Password.Length > 0) p["password"] = Password;
        var key = SshKey.Trim();
        if (key.Length > 0) p["ssh-public-keys"] = key;
        // Nesting keeps systemd-based distributions happy inside unprivileged containers.
        if (Nesting) p["features"] = "nesting=1";
        if (StartAtBoot) p["onboot"] = "1";

        var net = $"name=eth0,bridge={Bridge}";
        if (VlanTag > 0) net += $",tag={VlanTag}";
        if (Ipv4 == IPv4.Dhcp) net += ",ip=dhcp";
        else
        {
            net += $",ip={Address.Trim()}";
            var gw = Gateway.Trim();
            if (gw.Length > 0) net += $",gw={gw}";
        }
        net += Ipv6 switch { IPv6.Auto => ",ip6=auto", IPv6.Dhcp => ",ip6=dhcp", _ => "" };
        if (Firewall) net += ",firewall=1";
        p["net0"] = net;
        return p;
    }

    public List<string> Problems
    {
        get
        {
            var list = new List<string>();
            if (Node.Length == 0) list.Add(L.T("Choose a node."));
            if (Template.Length == 0) list.Add(L.T("Choose a template."));
            if (RootStorage.Length == 0) list.Add(L.T("Choose a storage for the disk."));
            if (Bridge.Length == 0) list.Add(L.T("Choose a network bridge."));
            if (Password.Length == 0 && SshKey.Trim().Length == 0) list.Add(L.T("Set a root password or an SSH key."));
            if (Password.Length > 0 && Password.Length < 5) list.Add(L.T("The password must be at least 5 characters."));
            if (Password != PasswordConfirm) list.Add(L.T("The passwords don't match."));
            if (Ipv4 == IPv4.Static && !Address.Contains('/'))
                list.Add(L.T("Write the IPv4 address with its prefix, e.g. 192.168.1.50/24."));
            if (!Names.IsValid(Hostname)) list.Add(L.T("The name may only contain letters, digits, dots and dashes."));
            return list;
        }
    }
}

public static partial class Names
{
    /// <summary>Empty, or a DNS-style name (letters, digits, dots, dashes).</summary>
    public static bool IsValid(string name)
    {
        var n = name.Trim();
        return n.Length == 0 || Pattern().IsMatch(n);
    }

    [GeneratedRegex("^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$")]
    private static partial Regex Pattern();
}
