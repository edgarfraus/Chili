using System.Text.Json.Serialization;

namespace Chili.Core.Proxmox;

/// <summary>A VM or container from /cluster/resources, with its live usage.</summary>
public sealed record ProxmoxVM
{
    [JsonPropertyName("vmid")] public int VmId { get; init; }
    [JsonPropertyName("name")] public string? Name { get; init; }
    [JsonPropertyName("node")] public string Node { get; init; } = "";
    [JsonPropertyName("status")] public string Status { get; init; } = "";
    [JsonPropertyName("type")] public string Type { get; init; } = "";
    [JsonPropertyName("template")] public int? Template { get; init; }
    [JsonPropertyName("maxmem")] public long? MaxMem { get; init; }
    [JsonPropertyName("maxcpu")] public double? MaxCpu { get; init; }
    [JsonPropertyName("uptime")] public long? Uptime { get; init; }
    // Live usage, refreshed by Proxmox (pvestatd) roughly every 10 seconds.
    [JsonPropertyName("cpu")] public double? Cpu { get; init; }       // fraction of maxcpu, 0…1
    [JsonPropertyName("mem")] public long? Mem { get; init; }
    [JsonPropertyName("maxdisk")] public long? MaxDisk { get; init; }
    [JsonPropertyName("netin")] public long? NetIn { get; init; }     // cumulative bytes
    [JsonPropertyName("netout")] public long? NetOut { get; init; }

    public string Id => $"{Node}/{VmId}";
    public string DisplayName => Name ?? $"VM {VmId}";
    public bool IsRunning => Status == "running";
    public bool IsTemplate => (Template ?? 0) == 1;
    public bool IsContainer => Type == "lxc";
}

public sealed record ProxmoxRealm
{
    [JsonPropertyName("realm")] public string Realm { get; init; } = "";
    [JsonPropertyName("comment")] public string? Comment { get; init; }
}

public sealed record Storage
{
    [JsonPropertyName("storage")] public string Name { get; init; } = "";
    [JsonPropertyName("type")] public string? Type { get; init; }
    [JsonPropertyName("content")] public string? Content { get; init; }
    [JsonPropertyName("avail")] public long? Avail { get; init; }
    [JsonPropertyName("total")] public long? Total { get; init; }
    [JsonPropertyName("active")] public int? Active { get; init; }
}

public sealed record StorageItem
{
    [JsonPropertyName("volid")] public string VolId { get; init; } = "";
    [JsonPropertyName("size")] public long? Size { get; init; }
    public string FileName => VolId.Split('/').Last();
}

public sealed record NetworkInterface
{
    [JsonPropertyName("iface")] public string Iface { get; init; } = "";
    [JsonPropertyName("type")] public string? Type { get; init; }
    [JsonPropertyName("active")] public int? Active { get; init; }
    [JsonPropertyName("comments")] public string? Comments { get; init; }
}

public sealed record NodeStatus
{
    public sealed record CpuInfo
    {
        [JsonPropertyName("cpus")] public int? Cpus { get; init; }
        [JsonPropertyName("model")] public string? Model { get; init; }
        [JsonPropertyName("flags")] public string? Flags { get; init; }
    }
    public sealed record MemoryInfo
    {
        [JsonPropertyName("total")] public long? Total { get; init; }
        [JsonPropertyName("free")] public long? Free { get; init; }
    }
    [JsonPropertyName("cpuinfo")] public CpuInfo? Cpu { get; init; }
    [JsonPropertyName("memory")] public MemoryInfo? Memory { get; init; }
}

public sealed record TaskEntry
{
    [JsonPropertyName("upid")] public string Upid { get; init; } = "";
    [JsonPropertyName("type")] public string Type { get; init; } = "";
    [JsonPropertyName("status")] public string? Status { get; init; }   // "OK", an error, or null while running
    [JsonPropertyName("starttime")] public long StartTime { get; init; }
    [JsonPropertyName("endtime")] public long? EndTime { get; init; }
    [JsonPropertyName("user")] public string? User { get; init; }
    [JsonPropertyName("node")] public string Node { get; init; } = "";

    public bool IsRunning => EndTime is null;
    public bool Succeeded => Status == "OK";
    public DateTimeOffset StartDate => DateTimeOffset.FromUnixTimeSeconds(StartTime);
    public TimeSpan? Duration => EndTime is long end ? TimeSpan.FromSeconds(end - StartTime) : null;
}

public sealed record Appliance
{
    [JsonPropertyName("template")] public string Template { get; init; } = "";
    [JsonPropertyName("headline")] public string? Headline { get; init; }
    [JsonPropertyName("os")] public string? Os { get; init; }
    [JsonPropertyName("section")] public string? Section { get; init; }
    [JsonPropertyName("version")] public string? Version { get; init; }
}

public enum PowerAction { Start, Shutdown, Reboot, Stop, Reset, Suspend, Resume }

public abstract record WebConsoleKind
{
    public sealed record Vm(ProxmoxVM Machine) : WebConsoleKind;
    public sealed record NodeShell(string Node) : WebConsoleKind;
}
