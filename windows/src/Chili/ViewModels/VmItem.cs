using Chili.Core;
using Chili.Core.Proxmox;
using Chili.Services;
using CommunityToolkit.Mvvm.ComponentModel;
using Microsoft.UI.Xaml;

namespace Chili.ViewModels;

/// <summary>One row of the VM list. Updated in place on every refresh so the list doesn't flicker.</summary>
public sealed partial class VmItem : ObservableObject
{
    [ObservableProperty] public partial ProxmoxVM Vm { get; set; }
    [ObservableProperty] public partial double Cpu { get; set; }
    [ObservableProperty] public partial double Memory { get; set; }
    [ObservableProperty] public partial double NetIn { get; set; }
    [ObservableProperty] public partial double NetOut { get; set; }
    [ObservableProperty] public partial bool Busy { get; set; }

    public VmItem(ProxmoxVM vm) { Vm = vm; Update(vm, null); }

    public string Key => Vm.Id;
    public string IdText => Vm.VmId.ToString();
    public string Name => Vm.DisplayName;
    public bool IsRunning => Vm.IsRunning;

    public string Details
    {
        get
        {
            var parts = new List<string> { Vm.IsContainer ? L.T("Container") + " · " + Vm.Node : Vm.Node };
            if (Vm.MaxCpu is double cpu) parts.Add(L.F("%d vCPU", (int)cpu));
            if (Vm.MaxMem is long mem) parts.Add(Format.Bytes(mem));
            return string.Join(" · ", parts);
        }
    }

    public string NetInText => "↓ " + Format.Rate(NetIn);
    public string NetOutText => "↑ " + Format.Rate(NetOut);
    public string CpuTip => $"CPU {Format.Percent(Cpu)} · {(int)(Vm.MaxCpu ?? 0)} vCPU";
    public string MemoryTip => $"RAM {Format.Bytes(Vm.Mem)} / {Format.Bytes(Vm.MaxMem)}";

    public Visibility RunningVisibility => Vm.IsRunning ? Visibility.Visible : Visibility.Collapsed;
    public Visibility StoppedVisibility => Vm.IsRunning || Busy ? Visibility.Collapsed : Visibility.Visible;
    public Visibility ActionsVisibility => Busy ? Visibility.Collapsed : Visibility.Visible;
    public Visibility BusyVisibility => Busy ? Visibility.Visible : Visibility.Collapsed;
    public Visibility StoppedDotVisibility => Vm.IsRunning ? Visibility.Collapsed : Visibility.Visible;
    public string ConnectLabel => Vm.IsRunning ? L.T("Connect") : L.T("Start & Connect");
    public string StartLabel => L.T("Start");
    public string NetworkTip => L.T("Network traffic");
    public string MoreTip => L.T("More ways to open the console");

    public void Update(ProxmoxVM vm, UsageSample? sample)
    {
        Vm = vm;
        Cpu = sample?.Cpu ?? Math.Clamp(vm.Cpu ?? 0, 0, 1);
        Memory = sample?.Memory ?? ((vm.MaxMem ?? 0) > 0 ? Math.Min((double)(vm.Mem ?? 0) / vm.MaxMem!.Value, 1) : 0);
        NetIn = sample?.NetIn ?? 0;
        NetOut = sample?.NetOut ?? 0;
        OnPropertyChanged(string.Empty);   // derived texts
    }

    partial void OnBusyChanged(bool value)
    {
        OnPropertyChanged(nameof(StoppedVisibility));
        OnPropertyChanged(nameof(ActionsVisibility));
        OnPropertyChanged(nameof(BusyVisibility));
    }
}

/// <summary>One point of a VM's resource history.</summary>
public sealed record UsageSample(DateTime Date, double Cpu, double Memory, double NetIn, double NetOut);
