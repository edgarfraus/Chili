using Chili.Core;
using Chili.Core.Proxmox;
using Chili.Services;
using Chili.ViewModels;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace Chili.Views;

/// <summary>Add / edit a Proxmox server. Explicit grid rows with a fixed label column
/// (a flexible form layout inflated the window on macOS).</summary>
public sealed class ServerEditorDialog : ContentDialog
{
    private readonly AppModel model;
    private readonly ServerProfile original;
    private readonly bool isNew;

    private readonly TextBox name = new() { PlaceholderText = L.T("My homelab") };
    private readonly TextBox host = new() { PlaceholderText = L.T("pve.example.com or 192.168.1.10") };
    private readonly NumberBox port = new() { Minimum = 1, Maximum = 65535, Width = 110, HorizontalAlignment = HorizontalAlignment.Left };
    private readonly RadioButtons method = new() { MaxColumns = 2 };
    private readonly TextBox user = new() { PlaceholderText = "root" };
    private readonly ComboBox realm = new() { HorizontalAlignment = HorizontalAlignment.Stretch };
    private readonly TextBox tokenId = new() { PlaceholderText = "user@pam!spice" };
    private readonly PasswordBox secret = new();
    private readonly CheckBox remember = new() { Content = L.T("Remember in Credential Manager") };
    private readonly TextBox tunnel = new() { PlaceholderText = "spice.example.com" };
    private readonly TextBox accessId = new() { PlaceholderText = "0123abcd….access" };
    private readonly PasswordBox accessSecret = new();
    private readonly CheckBox tunnelUsesAccess = new() { Content = L.T("Use the Cloudflare Access token for the tunnel too") };
    private readonly TextBlock tunnelHint = new()
    {
        Text = L.T("Only if the spiceproxy (port 3128) can't be reached directly: a WebSocket that leads to it, such as a Cloudflare Tunnel TCP service (spice.example.com) or websockify (ws://pve.example.com:8443/). Leave empty otherwise."),
        TextWrapping = TextWrapping.Wrap, Style = (Style)Application.Current.Resources["CaptionTextBlockStyle"],
        Foreground = (Microsoft.UI.Xaml.Media.Brush)Application.Current.Resources["TextFillColorSecondaryBrush"],
    };
    private readonly TextBlock tokenHint = new()
    {
        Text = L.T("The token needs the VM.Console and VM.Audit privileges (and VM.PowerMgmt to start VMs)."),
        TextWrapping = TextWrapping.Wrap, Style = (Style)Application.Current.Resources["CaptionTextBlockStyle"],
        Foreground = (Microsoft.UI.Xaml.Media.Brush)Application.Current.Resources["TextFillColorSecondaryBrush"],
    };
    private readonly FrameworkElement[] passwordRows, tokenRows;
    private List<ProxmoxRealm> realms = [];
    private CancellationTokenSource? realmLookup;

    public ServerProfile Result { get; private set; }
    public string? Secret => secret.Password.Length > 0 ? secret.Password : null;
    public string? AccessSecret => accessSecret.Password.Length > 0 ? accessSecret.Password : null;
    public bool Removed { get; private set; }
    private readonly Expander expander, accessExpander;


    /// <summary>Debug actions: open the Cloudflare sections and scroll to the end.</summary>
    public void ExpandRemoteAccess()
    {
        foreach (var e in new[] { expander, accessExpander }) e.IsExpanded = true;
        Opened += async (_, _) =>
        {
            await Task.Delay(400);
            scroller.UpdateLayout();
            scroller.ChangeView(null, scroller.ScrollableHeight, null, disableAnimation: true);
        };
    }

    private readonly ScrollViewer scroller;

    /// <summary>The dialog's title and buttons take ~200 px; the form gets the rest of the window.</summary>
    private void FitToWindow()
    {
        if (XamlRoot is null) return;
        scroller.MaxHeight = Math.Max(240, XamlRoot.Size.Height - 220);
    }

    public ServerEditorDialog(AppModel model, ServerProfile? profile)
    {
        this.model = model;
        isNew = profile is null || !model.Settings.Servers.Any(s => s.Id == profile.Id);
        original = profile ?? new ServerProfile();
        Result = original;

        Title = isNew ? L.T("Add Proxmox Server") : L.T("Edit Proxmox Server");
        PrimaryButtonText = isNew ? L.T("Add") : L.T("Save");
        CloseButtonText = L.T("Cancel");
        DefaultButton = ContentDialogButton.Primary;
        if (!isNew) SecondaryButtonText = L.T("Remove Server");

        name.Text = original.Name;
        host.Text = original.Host;
        port.Value = original.Port;
        method.Items.Add(L.T("Password"));
        method.Items.Add(L.T("API token"));
        method.SelectedIndex = original.Auth == ServerProfile.AuthMethod.Token ? 1 : 0;
        user.Text = original.Username;
        tokenId.Text = original.TokenId;
        remember.IsChecked = original.RememberSecret;
        tunnel.Text = original.SpiceTunnelHost;
        accessId.Text = original.AccessClientId;
        if (original.AccessClientId.Length > 0) accessSecret.PlaceholderText = L.T("unchanged");
        tunnelUsesAccess.IsChecked = original.SpiceTunnelUsesAccess;
        if (!isNew) secret.PlaceholderText = L.T("unchanged");

        var grid = new Grid { ColumnSpacing = 12, RowSpacing = 10 };
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(110) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        int row = 0;
        FrameworkElement[] Row(string? label, FrameworkElement control)
        {
            grid.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
            var text = new TextBlock { Text = label ?? "", VerticalAlignment = VerticalAlignment.Center, HorizontalAlignment = HorizontalAlignment.Right };
            Grid.SetRow(text, row); Grid.SetRow(control, row); Grid.SetColumn(control, 1);
            grid.Children.Add(text); grid.Children.Add(control);
            row++;
            return [text, control];
        }
        Row(L.T("Name"), name);
        Row(L.T("Host"), host);
        Row(L.T("Port"), port);
        Row(L.T("Log in with"), method);
        var userRow = Row(L.T("User"), user);
        var realmRow = Row(L.T("Realm"), realm);
        var tokenRow = Row(L.T("Token ID"), tokenId);
        var secretRow = Row(L.T("Password"), secret);
        Row(null, remember);
        var hintRow = Row(null, tokenHint);
        passwordRows = [.. userRow, .. realmRow];
        tokenRows = [.. tokenRow, .. hintRow];
        secretLabel = (TextBlock)secretRow[0];

        // Two independent Cloudflare sections, collapsed unless configured: Access in front of the
        // Proxmox hostname, and the SPICE tunnel (with its own, optional Access token).
        static (Expander Expander, Action<string?, FrameworkElement> Row) Section(string title, bool open)
        {
            var g = new Grid { ColumnSpacing = 12, RowSpacing = 10 };
            g.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(110) });
            g.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            int n = 0;
            void Add(string? label, FrameworkElement control)
            {
                g.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
                var text = new TextBlock
                {
                    Text = label ?? "", VerticalAlignment = VerticalAlignment.Center, HorizontalAlignment = HorizontalAlignment.Right,
                    TextWrapping = TextWrapping.Wrap, TextAlignment = TextAlignment.Right,
                };
                Grid.SetRow(text, n); Grid.SetRow(control, n); Grid.SetColumn(control, 1);
                g.Children.Add(text); g.Children.Add(control);
                n++;
            }
            var e = new Expander
            {
                Header = title, Content = g, IsExpanded = open,
                HorizontalAlignment = HorizontalAlignment.Stretch, HorizontalContentAlignment = HorizontalAlignment.Stretch,
            };
            return (e, Add);
        }
        var (accessSection, accessRow) = Section(L.T("Cloudflare Access"), original.AccessClientId.Length > 0);
        accessRow(L.T("Client ID"), accessId);
        accessRow(L.T("Client Secret"), accessSecret);
        accessRow(null, Form.Caption(L.T("Only if Cloudflare Access protects the Proxmox hostname: a service token (Zero Trust → Access → Service credentials) allowed by a Service Auth policy. Used for the API and the web consoles, and for the SPICE tunnel if ticked there.")));
        var (tunnelSection, tunnelRow) = Section(L.T("SPICE tunnel (WebSocket)"), original.SpiceTunnelHost.Length > 0);
        tunnelRow(L.T("Address"), tunnel);
        tunnelRow(null, tunnelHint);
        tunnelRow(null, tunnelUsesAccess);
        expander = tunnelSection;
        accessExpander = accessSection;
        var page = new StackPanel { Spacing = 10, Width = 440 };
        page.Children.Add(grid);
        page.Children.Add(new Border { Height = 4 });
        page.Children.Add(accessSection);
        page.Children.Add(tunnelSection);
        // Our own scroller: ContentDialog doesn't re-measure when the expander grows after it opened,
        // which left the Access fields below the bottom edge, unreachable.
        scroller = new ScrollViewer
        {
            Content = page, VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
            Padding = new Thickness(0, 0, 16, 0),   // room for the scroll bar
        };
        Content = scroller;
        Opened += (_, _) => { FitToWindow(); XamlRoot.Changed += (_, _) => FitToWindow(); };
        foreach (var section in new[] { accessSection, tunnelSection })
            section.Expanding += (_, _) => DispatcherQueue.TryEnqueue(
                Microsoft.UI.Dispatching.DispatcherQueuePriority.Low, () => section.StartBringIntoView());

        FillRealms();
        method.SelectionChanged += (_, _) => UpdateMode();
        host.TextChanged += (_, _) => { LookupRealms(); Validate(); };
        user.TextChanged += (_, _) => Validate();
        tokenId.TextChanged += (_, _) => Validate();
        PrimaryButtonClick += OnSave;
        SecondaryButtonClick += (_, _) => Removed = true;
        UpdateMode();
        LookupRealms();
    }

    private readonly TextBlock secretLabel;
    private bool UsesToken => method.SelectedIndex == 1;

    private void UpdateMode()
    {
        foreach (var e in passwordRows) e.Visibility = UsesToken ? Visibility.Collapsed : Visibility.Visible;
        foreach (var e in tokenRows) e.Visibility = UsesToken ? Visibility.Visible : Visibility.Collapsed;
        secretLabel.Text = UsesToken ? L.T("Secret") : L.T("Password");
        Validate();
    }

    private void Validate() =>
        IsPrimaryButtonEnabled = ProxmoxClient.NormalizedHost(host.Text).Length > 0
            && (UsesToken ? tokenId.Text.Contains('!') : user.Text.Trim().Length > 0);

    private string SelectedRealm => (realm.SelectedItem as ComboBoxItem)?.Tag as string ?? original.Realm;

    private void FillRealms()
    {
        var current = realm.Items.Count > 0 ? SelectedRealm : original.Realm;
        var names = realms.Select(r => r.Realm).ToList();
        foreach (var r in new[] { "pam", "pve", current }) if (!names.Contains(r)) names.Add(r);
        realm.Items.Clear();
        foreach (var r in names)
        {
            var label = r switch
            {
                "pam" => L.T("Linux PAM (pam)"),
                "pve" => L.T("Proxmox VE (pve)"),
                _ => realms.FirstOrDefault(x => x.Realm == r)?.Comment is { Length: > 0 } c ? $"{c} ({r})" : r,
            };
            var item = new ComboBoxItem { Content = label, Tag = r };
            realm.Items.Add(item);
            if (r == current) realm.SelectedItem = item;
        }
    }

    /// <summary>Asks the server for its realms (no login needed; fails quietly until the
    /// certificate is trusted). Debounced while typing.</summary>
    private async void LookupRealms()
    {
        realmLookup?.Cancel();
        var cts = realmLookup = new CancellationTokenSource();
        var h = ProxmoxClient.NormalizedHost(host.Text);
        if (h.Length <= 3 || Demo.IsOn) return;
        try
        {
            await Task.Delay(600, cts.Token);
            using var client = new ProxmoxClient(h, ProxmoxClient.PortIn(host.Text) ?? (int)port.Value, model.Settings);
            var list = await client.RealmsAsync(cts.Token);
            if (cts.IsCancellationRequested) return;
            realms = list;
            FillRealms();
        }
        catch (Exception) { /* not reachable yet, untrusted certificate…: keep the defaults */ }
    }

    private void OnSave(ContentDialog sender, ContentDialogButtonClickEventArgs args)
    {
        Result = original with
        {
            Name = name.Text.Trim(),
            Host = ProxmoxClient.NormalizedHost(host.Text),
            Port = ProxmoxClient.PortIn(host.Text) ?? (double.IsNaN(port.Value) ? 8006 : (int)port.Value),
            Auth = UsesToken ? ServerProfile.AuthMethod.Token : ServerProfile.AuthMethod.Password,
            Username = user.Text.Trim(),
            Realm = SelectedRealm,
            TokenId = tokenId.Text.Trim(),
            RememberSecret = remember.IsChecked == true,
            SpiceTunnelHost = tunnel.Text.Trim(),
            AccessClientId = accessId.Text.Trim(),
            SpiceTunnelUsesAccess = tunnelUsesAccess.IsChecked == true,
        };
    }
}
