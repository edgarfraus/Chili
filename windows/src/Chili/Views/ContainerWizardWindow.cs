using Chili.Core;
using Chili.ViewModels;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace Chili.Views;

/// <summary>New LXC container: template (on the server or downloaded from Proxmox' catalogue),
/// root password / SSH key, resources, network; advanced options in an expander.
/// Port of ContainerWizardView.</summary>
public sealed class ContainerWizardWindow : WizardWindow
{
    private readonly ContainerWizardModel model;
    private readonly MainWindow main;
    private bool showAdvanced;

    public ContainerWizardWindow(ServerSession session, MainWindow main) : base(L.T("New Container"), "ct-wizard")
    {
        model = new ContainerWizardModel(session);
        this.main = main;
        Description.Text = L.T("An LXC container shares the node's Linux kernel: it starts in seconds and uses little memory. Chili creates it unprivileged, with nesting enabled, and opens its console when it's ready.");
        Header.Children.Add(Description);
        Start();
    }

    private ContainerDraft D => model.Draft;
    protected override List<string> Problems => D.Problems;

    protected override async Task LoadAsync()
    {
        await model.LoadAsync();
        Error = model.Error;
    }

    protected override void Build(Form f)
    {
        NodePicker(f, model.Nodes, D.Node, node => { D.Node = node; return model.LoadNodeAsync(); });
        f.Text(L.T("Hostname"), D.Hostname, v => { D.Hostname = v; Validate(); }, "web01");

        var templates = new List<(string, string?)>();
        if (model.Templates.Count > 0)
        {
            templates.Add((L.T("On the server"), null));
            templates.AddRange(model.Templates.Select(t => (t.FileName, (string?)t.VolId)));
        }
        var downloadable = model.Downloadable.ToList();
        if (downloadable.Count > 0)
        {
            templates.Add((L.T("Download from Proxmox"), null));
            templates.AddRange(downloadable.Select(a => (a.Template, (string?)(ContainerDraft.DownloadPrefix + a.Template))));
        }
        f.Choice(L.T("Template"), templates, D.Template, v => { D.Template = v ?? ""; Rebuild(); }, 400);
        if (D.WantsDownload && model.TemplateStorages.Count > 1)
            StoragePicker(f, L.T("Save template to"), model.TemplateStorages, D.DownloadStorage, v => D.DownloadStorage = v);

        f.Password(L.T("Root password"), D.Password, v => { D.Password = v; Validate(); });
        f.Password(L.T("Confirm password"), D.PasswordConfirm, v => { D.PasswordConfirm = v; Validate(); });
        f.Text(L.T("SSH public key"), D.SshKey, v => { D.SshKey = v; Validate(); }, L.T("optional"), 400);
        f.Divider();
        f.Number(L.T("CPU cores"), D.Cores, 1, model.MaxCores, v => D.Cores = v);
        f.Number(L.T("Memory"), D.MemoryMiB, 128, model.MaxMemoryMiB, v => D.MemoryMiB = v, 256, "MiB");
        f.Number(L.T("Disk size"), D.RootSizeGB, 1, 65536, v => D.RootSizeGB = v, unit: "GB");
        StoragePicker(f, L.T("Disk storage"), model.RootStorages, D.RootStorage, v => D.RootStorage = v);
        BridgePicker(f, model.Bridges, D.Bridge, v => D.Bridge = v);
        f.Number(L.T("VLAN tag (0 = none)"), D.VlanTag, 0, 4094, v => D.VlanTag = v);
        f.Segments(L.T("IPv4"), new[] { (L.T("DHCP"), ContainerDraft.IPv4.Dhcp), (L.T("Static"), ContainerDraft.IPv4.Static) },
                   D.Ipv4, v => { D.Ipv4 = v; Rebuild(); });
        if (D.Ipv4 == ContainerDraft.IPv4.Static)
        {
            f.Text(L.T("Address"), D.Address, v => { D.Address = v; Validate(); }, "192.168.1.50/24", 200);
            f.Text(L.T("Gateway"), D.Gateway, v => { D.Gateway = v; Validate(); }, "192.168.1.1", 200);
        }
        f.Divider();
        f.Check(L.T("Start the container and open its console"), D.StartAfterCreate, v => D.StartAfterCreate = v);

        var advanced = new StackPanel { Spacing = 10, Margin = new Thickness(0, 8, 0, 0) };
        var expander = new Expander
        {
            Header = L.T("Advanced"), Content = advanced, IsExpanded = showAdvanced,
            HorizontalAlignment = HorizontalAlignment.Stretch, HorizontalContentAlignment = HorizontalAlignment.Stretch,
        };
        expander.Expanding += (_, _) => showAdvanced = true;
        expander.Collapsed += (_, _) => showAdvanced = false;
        f.Panel.Children.Add(expander);
        var inner = new Form(150);
        inner.Number(L.T("Container ID"), D.VmId, 100, 999_999_999, v => { D.VmId = v; Validate(); }, target: advanced);
        inner.Number(L.T("Swap"), D.SwapMiB, 0, 65536, v => D.SwapMiB = v, 256, "MiB", advanced);
        inner.Segments(L.T("IPv6"), new[] { (L.T("SLAAC"), ContainerDraft.IPv6.Auto), (L.T("DHCP"), ContainerDraft.IPv6.Dhcp), (L.T("None"), ContainerDraft.IPv6.None) },
                       D.Ipv6, v => D.Ipv6 = v, advanced);
        inner.Check(L.T("Unprivileged container"), D.Unprivileged, v => D.Unprivileged = v, advanced);
        inner.Check(L.T("Nesting (needed by systemd and Docker)"), D.Nesting, v => D.Nesting = v, advanced);
        inner.Check(L.T("Firewall"), D.Firewall, v => D.Firewall = v, advanced);
        inner.Check(L.T("Start at boot"), D.StartAtBoot, v => D.StartAtBoot = v, advanced);
    }

    protected override async Task<Func<Task>?> CreateAsync(Action<string> progress)
    {
        var ct = await model.CreateAsync(progress);
        if (ct is null || !D.StartAfterCreate) return null;
        var named = ct with { Name = ct.Name ?? (D.Hostname.Trim() is { Length: > 0 } n ? n : null) };
        return () => main.Consoles.ConnectAsync(model.Session, named);
    }
}
