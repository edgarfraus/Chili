using System.Collections.ObjectModel;
using Chili.Core;
using Chili.Core.Proxmox;
using Chili.Services;
using CommunityToolkit.Mvvm.ComponentModel;
using Microsoft.UI.Dispatching;

namespace Chili.ViewModels;

/// <summary>Login state and VM list of one Proxmox server. Lives on the UI thread.</summary>
public sealed partial class ServerSession : ObservableObject
{
    public enum SessionState { LoggedOut, NeedsOtp, Working, Ready }

    public ServerProfile Profile { get; }
    private readonly AppModel app;
    private readonly ProxmoxClient client;

    [ObservableProperty] public partial SessionState State { get; set; } = SessionState.LoggedOut;
    [ObservableProperty] public partial string? LastError { get; set; }
    /// <summary>SHA-256 fingerprint of a certificate waiting for the user's decision.</summary>
    [ObservableProperty] public partial string? PendingCertificate { get; set; }
    [ObservableProperty] public partial string Filter { get; set; } = "";
    [ObservableProperty] public partial bool ShowStopped { get; set; }

    public List<ProxmoxVM> VMs { get; private set; } = [];
    /// <summary>The rows shown, after the filter.</summary>
    public ObservableCollection<VmItem> Items { get; } = [];
    private readonly Dictionary<string, VmItem> items = [];
    private readonly Dictionary<string, UsageSample> lastSample = [];
    private readonly Dictionary<string, (DateTime Date, long In, long Out)> lastNetCounters = [];

    public static readonly TimeSpan RefreshInterval = TimeSpan.FromSeconds(5);
    private DispatcherQueueTimer? refreshTimer;
    private string password = "";

    public ServerSession(ServerProfile profile, AppModel app)
    {
        Profile = profile;
        this.app = app;
        client = new ProxmoxClient(profile.Host, profile.Port, app.Settings);
        ShowStopped = app.Settings.Preferences.ShowStoppedVMs;
        if (Demo.IsOn)
        {
            VMs = Demo.VMs;
            foreach (var vm in VMs.Where(v => v.IsRunning))
            {
                double rate = (vm.VmId % 7 + 1) * 37_000;
                lastSample[vm.Id] = new UsageSample(DateTime.Now, vm.Cpu ?? 0, (double)(vm.Mem ?? 0) / (vm.MaxMem ?? 1),
                                                    rate * 3.1, rate);
            }
            State = SessionState.Ready;
            ApplyFilter();
        }
    }

    public ProxmoxClient Api => client;
    public string? StoredSecret => Credentials.Load(Profile.Id);
    public bool IsEmpty => VMs.Count == 0;

    partial void OnFilterChanged(string value) => ApplyFilter();

    partial void OnShowStoppedChanged(bool value)
    {
        app.Settings.Preferences.ShowStoppedVMs = value;
        app.Settings.Save();
        ApplyFilter();
    }

    public void ConnectWithStoredSecret()
    {
        if (Demo.IsOn) return;
        // Dev aid: UI work without touching Credential Manager or the server.
        if (Environment.GetEnvironmentVariable("CHILI_DEBUG_NO_LOGIN") is { Length: > 0 }) return;
        if (State != SessionState.LoggedOut || StoredSecret is not { } secret) return;
        Login(secret);
    }

    public async void Login(string secret, string? otp = null)
    {
        if (secret.Length > 0) password = secret;
        State = SessionState.Working;
        LastError = null;
        try
        {
            if (Profile.Auth == ServerProfile.AuthMethod.Password)
                await client.LoginAsync(Profile.FullUsername, password, otp);
            else
                await client.UseTokenAsync(Profile.TokenId, password);
            if (Profile.RememberSecret) Credentials.Save(Profile.Id, password);
            await ReloadAsync();
            State = SessionState.Ready;
            StartAutoRefresh();
        }
        catch (NeedsTotpException)
        {
            State = SessionState.NeedsOtp;
        }
        catch (UntrustedCertificateException e)
        {
            State = SessionState.LoggedOut;
            PendingCertificate = e.Fingerprint;
        }
        catch (Exception e)
        {
            LastError = e.Message;
            State = otp is null ? SessionState.LoggedOut : SessionState.NeedsOtp;
        }
    }

    public void TrustPendingCertificate()
    {
        if (PendingCertificate is not { } fp) return;
        app.Settings.Trust(client.Host, Profile.Port, fp);
        PendingCertificate = null;
        Login(password.Length > 0 ? password : StoredSecret ?? "");
    }

    public void Logout()
    {
        refreshTimer?.Stop();
        State = SessionState.LoggedOut;
        VMs = [];
        password = "";
        ApplyFilter();
    }

    public void Stop() => refreshTimer?.Stop();

    public async Task ReloadAsync()
    {
        if (Demo.IsOn) return;
        VMs = await client.VirtualMachinesAsync();
        RecordUsage();
        ApplyFilter();
    }

    public async void Refresh()
    {
        try
        {
            await ReloadAsync();
            LastError = null;
        }
        catch (Exception e) { LastError = e.Message; }
    }

    private void StartAutoRefresh()
    {
        refreshTimer ??= DispatcherQueue.GetForCurrentThread().CreateTimer();
        refreshTimer.Interval = RefreshInterval;
        refreshTimer.IsRepeating = true;
        refreshTimer.Tick -= OnRefreshTick;
        refreshTimer.Tick += OnRefreshTick;
        refreshTimer.Start();
    }

    private bool refreshing;
    private async void OnRefreshTick(DispatcherQueueTimer sender, object args)
    {
        if (refreshing || State != SessionState.Ready) return;
        refreshing = true;
        try { await ReloadAsync(); LastError = null; }
        catch (Exception e) { LastError = e.Message; }
        finally { refreshing = false; }
    }

    /// <summary>Network rate = delta of the cumulative counters ÷ elapsed time.</summary>
    private void RecordUsage()
    {
        var now = DateTime.Now;
        foreach (var vm in VMs)
        {
            if (!vm.IsRunning)
            {
                lastSample.Remove(vm.Id);
                lastNetCounters.Remove(vm.Id);
                continue;
            }
            double netIn = 0, netOut = 0;
            if (vm.NetIn is long inBytes && vm.NetOut is long outBytes)
            {
                if (lastNetCounters.TryGetValue(vm.Id, out var last) && (now - last.Date).TotalSeconds > 0.5
                    && inBytes >= last.In && outBytes >= last.Out)
                {
                    double dt = (now - last.Date).TotalSeconds;
                    netIn = (inBytes - last.In) / dt;
                    netOut = (outBytes - last.Out) / dt;
                }
                else if (lastSample.TryGetValue(vm.Id, out var previous))
                {
                    // Proxmox updates the counters about every 10 s: keep the last rate meanwhile.
                    (netIn, netOut) = (previous.NetIn, previous.NetOut);
                }
                if (!lastNetCounters.TryGetValue(vm.Id, out var l) || l.In != inBytes || l.Out != outBytes)
                    lastNetCounters[vm.Id] = (now, inBytes, outBytes);
            }
            double memory = (vm.MaxMem ?? 0) > 0 ? (double)(vm.Mem ?? 0) / vm.MaxMem!.Value : 0;
            lastSample[vm.Id] = new UsageSample(now, Math.Clamp(vm.Cpu ?? 0, 0, 1), Math.Min(memory, 1), netIn, netOut);
        }
    }

    /// <summary>Syncs <see cref="Items"/> with the VM list and the filter, reusing rows.</summary>
    private void ApplyFilter()
    {
        var shown = VMs.Where(vm => (ShowStopped || vm.IsRunning) &&
            (Filter.Length == 0 || vm.DisplayName.Contains(Filter, StringComparison.CurrentCultureIgnoreCase)
                                || vm.VmId.ToString().Contains(Filter))).ToList();
        foreach (var vm in VMs)
        {
            lastSample.TryGetValue(vm.Id, out var sample);
            if (!items.TryGetValue(vm.Id, out var item)) items[vm.Id] = item = new VmItem(vm);
            item.Update(vm, sample);
        }
        foreach (var gone in items.Keys.Except(VMs.Select(v => v.Id)).ToList()) items.Remove(gone);

        var wanted = shown.Select(vm => items[vm.Id]).ToList();
        for (int i = Items.Count - 1; i >= 0; i--)
            if (!wanted.Contains(Items[i])) Items.RemoveAt(i);
        for (int i = 0; i < wanted.Count; i++)
        {
            int at = Items.IndexOf(wanted[i]);
            if (at == i) continue;
            if (at >= 0) Items.Move(at, i); else Items.Insert(i, wanted[i]);
        }
        OnPropertyChanged(nameof(IsEmpty));
        OnPropertyChanged(nameof(EmptyText));
    }

    public string? EmptyText =>
        Items.Count > 0 ? null : VMs.Count == 0 ? L.T("No virtual machines on this server.") : L.T("No VMs match the filter.");

    public async Task<List<string>> LoadNodesAsync()
    {
        if (Demo.IsOn) return ["pve1"];
        try { return await client.NodesAsync(); }
        catch { return VMs.Select(v => v.Node).Distinct().Order().ToList(); }
    }

    // MARK: Actions

    private async Task RunBusy(ProxmoxVM vm, Func<Task> work)
    {
        items.TryGetValue(vm.Id, out var item);
        if (item is not null) item.Busy = true;
        try { await work(); }
        catch (Exception e) { await app.PresentAsync(e); }
        finally { if (item is not null) item.Busy = false; }
    }

    /// <summary>Shutdown, reboot, stop… then refresh the list.</summary>
    public Task PowerAsync(ProxmoxVM vm, PowerAction action) => RunBusy(vm, async () =>
    {
        var upid = await client.PowerAsync(vm, action);
        await client.WaitForTaskAsync(vm.Node, upid, TimeSpan.FromMinutes(3));
        await ReloadAsync();
    });

    public Task StartAsync(ProxmoxVM vm) => RunBusy(vm, () => StartAndWaitAsync(vm));

    /// <summary>Deletes a VM or container with its disks (stopping it first).</summary>
    public Task DeleteAsync(ProxmoxVM vm) => RunBusy(vm, async () =>
    {
        if (vm.IsRunning)
        {
            var stop = await client.PowerAsync(vm, PowerAction.Stop);
            await client.WaitForTaskAsync(vm.Node, stop, TimeSpan.FromMinutes(2));
        }
        var upid = await client.DeleteAsync(vm);
        await client.WaitForTaskAsync(vm.Node, upid);
        await ReloadAsync();
    });

    /// <summary>Starts the VM and waits for Proxmox' start task, so its real error (if any) is
    /// shown, then until the VM is listed as running.</summary>
    public async Task StartAndWaitAsync(ProxmoxVM vm)
    {
        var upid = await client.PowerAsync(vm, PowerAction.Start);
        await client.WaitForTaskAsync(vm.Node, upid, TimeSpan.FromMinutes(2));
        for (int i = 0; i < 30; i++)
        {
            await Task.Delay(1000);
            await ReloadAsync();
            if (VMs.FirstOrDefault(v => v.Id == vm.Id)?.IsRunning == true)
            {
                await Task.Delay(1500);   // give QEMU a moment to open the SPICE port
                return;
            }
        }
        throw new HttpProxmoxException(0, L.T("The VM did not start within 30 seconds."));
    }

    public VmItem? ItemFor(ProxmoxVM vm) => items.GetValueOrDefault(vm.Id);
}
