using System.ComponentModel;
using Chili.Core;
using Chili.Core.Proxmox;
using Chili.ViewModels;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Windows.System;

namespace Chili.Views;

/// <summary>A Proxmox server: login (password, TOTP, token) and the VM list.</summary>
public sealed partial class ServerView : UserControl
{
    public ServerSession Session { get; }
    private readonly MainWindow window;

    public ServerView(ServerSession session, MainWindow window)
    {
        Session = session;
        this.window = window;
        InitializeComponent();

        TitleText.Text = session.Profile.Title;
        RefreshButton.Label = L.T("Refresh");
        ToolTipService.SetToolTip(RefreshButton, L.T("Refresh the VM list"));
        LogoutButton.Label = L.T("Log Out");
        ToolTipService.SetToolTip(LogoutButton, L.T("Log out"));
        EditButton.Label = L.T("Edit");
        ToolTipService.SetToolTip(EditButton, L.T("Edit server"));

        LoginTitle.Text = session.Profile.Title;
        LoginUser.Text = session.Profile.Auth == Services.ServerProfile.AuthMethod.Token
            ? session.Profile.TokenId : session.Profile.FullUsername;
        SecretBox.PlaceholderText = session.Profile.Auth == Services.ServerProfile.AuthMethod.Token
            ? L.T("Token secret") : L.T("Password");
        OtpBox.PlaceholderText = L.T("Two-factor code");
        OtpHint.Text = L.T("Enter the 6-digit code from your authenticator app, or a recovery key.");
        LoginButton.Content = L.T("Log In");
        ConnectingText.Text = L.F("Connecting to %@…", session.Profile.Host);

        FilterBox.PlaceholderText = L.T("Filter");
        FilterBox.Text = session.Filter;
        ShowStoppedBox.Content = L.T("Show stopped VMs");
        ShowStoppedBox.IsChecked = session.ShowStopped;
        VmList.ItemsSource = session.Items;

        Loaded += OnLoaded;
        Unloaded += (_, _) => session.PropertyChanged -= OnSessionChanged;
    }

    private void OnLoaded(object sender, RoutedEventArgs e)
    {
        Session.PropertyChanged -= OnSessionChanged;
        Session.PropertyChanged += OnSessionChanged;
        UpdateState();
        Session.ConnectWithStoredSecret();
        if (Session.State is ServerSession.SessionState.LoggedOut or ServerSession.SessionState.NeedsOtp)
            (Session.State == ServerSession.SessionState.NeedsOtp ? (Control)OtpBox : SecretBox).Focus(FocusState.Programmatic);
    }

    private async void OnSessionChanged(object? sender, PropertyChangedEventArgs e)
    {
        UpdateState();
        if (e.PropertyName == nameof(ServerSession.PendingCertificate) && Session.PendingCertificate is { } fp)
        {
            if (await ShowCertificatePromptAsync(window, Session.Profile.Host, fp)) Session.TrustPendingCertificate();
            else Session.PendingCertificate = null;
        }
    }

    private void UpdateState()
    {
        var state = Session.State;
        bool ready = state == ServerSession.SessionState.Ready;
        bool connecting = state == ServerSession.SessionState.Working && Session.IsEmpty && !LoginPanelWasUsed;
        ListPanel.Visibility = ready ? Visibility.Visible : Visibility.Collapsed;
        ConnectingPanel.Visibility = connecting ? Visibility.Visible : Visibility.Collapsed;
        LoginPanel.Visibility = !ready && !connecting ? Visibility.Visible : Visibility.Collapsed;
        RefreshButton.Visibility = LogoutButton.Visibility = ready ? Visibility.Visible : Visibility.Collapsed;

        bool otp = state == ServerSession.SessionState.NeedsOtp;
        SecretBox.Visibility = otp ? Visibility.Collapsed : Visibility.Visible;
        OtpBox.Visibility = OtpHint.Visibility = otp ? Visibility.Visible : Visibility.Collapsed;
        bool working = state == ServerSession.SessionState.Working;
        LoginButton.IsEnabled = !working;
        LoginButton.Opacity = working ? 0 : 1;
        LoginProgress.IsActive = working;
        LoginError.Text = Session.LastError ?? "";
        LoginError.Visibility = Session.LastError is null || ready ? Visibility.Collapsed : Visibility.Visible;

        ErrorText.Text = Session.LastError ?? "";
        ErrorBanner.Visibility = ready && Session.LastError is not null ? Visibility.Visible : Visibility.Collapsed;
        EmptyText.Text = Session.EmptyText ?? "";
        EmptyText.Visibility = Session.EmptyText is null ? Visibility.Collapsed : Visibility.Visible;
    }

    /// <summary>True once the user pressed Log In here: show the form's spinner, not the full-page one.</summary>
    private bool LoginPanelWasUsed;

    private void SubmitLogin()
    {
        LoginPanelWasUsed = true;
        if (Session.State == ServerSession.SessionState.NeedsOtp)
        {
            Session.Login("", OtpBox.Text);
            OtpBox.Text = "";
        }
        else
        {
            Session.Login(SecretBox.Password.Length > 0 ? SecretBox.Password : Session.StoredSecret ?? "");
        }
    }

    private void OnLogin(object sender, RoutedEventArgs e) => SubmitLogin();

    private void OnLoginKeyDown(object sender, KeyRoutedEventArgs e)
    {
        if (e.Key == VirtualKey.Enter) { e.Handled = true; SubmitLogin(); }
    }

    public static async Task<bool> ShowCertificatePromptAsync(MainWindow window, string host, string fingerprint)
    {
        var body = new StackPanel { Spacing = 12, MaxWidth = 460 };
        body.Children.Add(new TextBlock
        {
            TextWrapping = TextWrapping.Wrap,
            Text = L.F("%@ uses a certificate that Windows doesn't trust. This is normal for Proxmox, which generates a self-signed certificate on install.\n\nCompare this SHA-256 fingerprint with the one shown in Proxmox under Node → System → Certificates:", host),
        });
        body.Children.Add(new TextBlock
        {
            // Two lines of 16 bytes, easier to compare than a wrapped one.
            Text = fingerprint.Length > 48 ? fingerprint[..47] + "\n" + fingerprint[48..] : fingerprint,
            TextWrapping = TextWrapping.Wrap, IsTextSelectionEnabled = true,
            FontFamily = new Microsoft.UI.Xaml.Media.FontFamily("Cascadia Mono, Consolas"), FontSize = 12,
        });
        var result = await window.ShowDialogAsync(new ContentDialog
        {
            Title = L.T("Untrusted certificate"),
            Content = body,
            PrimaryButtonText = L.T("Trust and Continue"),
            CloseButtonText = L.T("Cancel"),
            DefaultButton = ContentDialogButton.Close,
        });
        return result == ContentDialogResult.Primary;
    }

    // MARK: Toolbar

    private void OnRefresh(object sender, RoutedEventArgs e) => Session.Refresh();

    private void OnLogout(object sender, RoutedEventArgs e)
    {
        LoginPanelWasUsed = true;
        Session.Logout();
    }

    private async void OnEdit(object sender, RoutedEventArgs e) => await window.EditServerAsync(Session.Profile);

    private void OnFilterChanged(object sender, TextChangedEventArgs e) => Session.Filter = FilterBox.Text;

    private void OnShowStopped(object sender, RoutedEventArgs e) => Session.ShowStopped = ShowStoppedBox.IsChecked == true;

    // MARK: Rows

    private static VmItem? ItemOf(object sender) => (sender as FrameworkElement)?.DataContext as VmItem;

    private async void OnConnect(object sender, RoutedEventArgs e)
    {
        if (ItemOf(sender) is { } item) await window.Consoles.ConnectAsync(Session, item.Vm);
    }

    private async void OnStart(object sender, RoutedEventArgs e)
    {
        if (ItemOf(sender) is { } item) await Session.StartAsync(item.Vm);
    }

    private async void OnRowDoubleTapped(object sender, DoubleTappedRoutedEventArgs e)
    {
        if ((e.OriginalSource as FrameworkElement)?.DataContext is VmItem { Busy: false } item)
            await window.Consoles.ConnectAsync(Session, item.Vm);
    }

    private void OnMore(object sender, RoutedEventArgs e)
    {
        if (ItemOf(sender) is not { } item) return;
        var vm = item.Vm;
        var menu = new MenuFlyout { Placement = Microsoft.UI.Xaml.Controls.Primitives.FlyoutPlacementMode.BottomEdgeAlignedRight };
        void Add(string text, Func<Task> action, bool destructive = false)
        {
            var mi = new MenuFlyoutItem { Text = text };
            if (destructive) mi.Foreground = (Microsoft.UI.Xaml.Media.Brush)Application.Current.Resources["SystemFillColorCriticalBrush"];
            mi.Click += async (_, _) => await action();
            menu.Items.Add(mi);
        }
        if (!vm.IsContainer)
            Add(L.T("noVNC Console"), () => window.Consoles.OpenWebConsoleAsync(Session, new WebConsoleKind.Vm(vm)));
        menu.Items.Add(new MenuFlyoutSeparator());
        if (vm.IsRunning)
        {
            Add(L.T("Shut Down"), () => Session.PowerAsync(vm, PowerAction.Shutdown));
            Add(L.T("Reboot"), () => Session.PowerAsync(vm, PowerAction.Reboot));
            Add(L.T("Stop (power off)"), async () =>
            {
                if (await window.ConfirmAsync(L.F("Stop %@?", vm.DisplayName),
                        L.T("This powers the VM off immediately, like pulling the plug. Unsaved data in the VM is lost."),
                        L.T("Stop")))
                    await Session.PowerAsync(vm, PowerAction.Stop);
            });
        }
        else
        {
            Add(L.T("Start"), () => Session.StartAsync(vm));
        }
        menu.Items.Add(new MenuFlyoutSeparator());
        Add(L.T("Delete…"), async () =>
        {
            if (await window.ConfirmAsync(L.F("Delete %@ (%@)?", vm.DisplayName, vm.VmId.ToString()),
                    L.T("The VM and all its disks are permanently deleted from Proxmox. This can't be undone."),
                    L.T("Delete")))
                await Session.DeleteAsync(vm);
        }, destructive: true);
        menu.ShowAt((FrameworkElement)sender);
    }
}
