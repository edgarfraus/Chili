using Chili.Core.Proxmox;

namespace Chili.Services;

/// <summary>CHILI_DEMO=1: a made-up server with sample VMs, for screenshots and UI work.
/// No network, no Credential Manager, and the saved settings are left untouched.</summary>
public static class Demo
{
    public static readonly bool IsOn = Environment.GetEnvironmentVariable("CHILI_DEMO") is { Length: > 0 };

    public static readonly ServerProfile Profile = new()
    {
        Id = new Guid("00000000-0000-0000-0000-00000000c411"), Name = "Homelab", Host = "pve.example.lan",
    };

    public static readonly List<ProxmoxVM> VMs =
    [
        Vm(100, "win11-desktop", "qemu", true, 4, 8, 0.27, 0.62),
        Vm(101, "ubuntu-server", "qemu", true, 2, 4, 0.06, 0.38),
        Vm(102, "debian-web", "lxc", true, 1, 1, 0.02, 0.21),
        Vm(103, "pihole", "lxc", true, 1, 0.5, 0.01, 0.44),
        Vm(104, "truenas", "qemu", true, 2, 16, 0.81, 0.93),
        Vm(105, "win-server-2022", "qemu", false, 4, 8, 0, 0),
        Vm(106, "fedora-test", "qemu", false, 2, 4, 0, 0),
    ];

    private static ProxmoxVM Vm(int id, string name, string type, bool running, double cpus, double memGB,
                                double cpu, double mem)
    {
        long maxmem = (long)(memGB * 1_073_741_824);
        return new ProxmoxVM
        {
            VmId = id, Name = name, Node = "pve1", Status = running ? "running" : "stopped", Type = type,
            MaxMem = maxmem, MaxCpu = cpus, Uptime = running ? 86_400 : null,
            Cpu = running ? cpu : null, Mem = running ? (long)(maxmem * mem) : null,
            NetIn = running ? id * 1_000_000L : null, NetOut = running ? id * 400_000L : null,
        };
    }
}
