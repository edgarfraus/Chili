using Chili.Core;
using Chili.Services;
using Chili.ViewModels;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;

namespace Chili.Views;

/// <summary>Direct SPICE connection (host, port, TLS, password) or a .vv file.</summary>
public sealed class QuickConnectView : UserControl
{
    private readonly AppModel model;
    private readonly MainWindow window;
    private readonly TextBox host = new() { PlaceholderText = "192.168.1.10" };
    private readonly NumberBox port = new() { Minimum = 1, Maximum = 65535, Width = 110, HorizontalAlignment = HorizontalAlignment.Left };
    private readonly CheckBox tls = new() { Content = L.T("Use TLS (port is the TLS port)") };
    private readonly PasswordBox password = new() { PlaceholderText = L.T("optional") };
    private readonly Button connect = new() { Content = L.T("Connect"), Style = (Style)Application.Current.Resources["AccentButtonStyle"] };

    public QuickConnectView(AppModel model, MainWindow window)
    {
        this.model = model;
        this.window = window;
        var prefs = model.Settings.Preferences;
        host.Text = prefs.QuickHost;
        port.Value = prefs.QuickPort;
        tls.IsChecked = prefs.QuickTls;

        var secondary = (Brush)Application.Current.Resources["TextFillColorSecondaryBrush"];
        var page = new StackPanel { Spacing = 18, Padding = new Thickness(32, 24, 32, 24), MaxWidth = 640, HorizontalAlignment = HorizontalAlignment.Left };
        page.Children.Add(new TextBlock { Text = L.T("Quick Connect"), Style = (Style)Application.Current.Resources["SubtitleTextBlockStyle"] });
        page.Children.Add(new TextBlock
        {
            Text = L.T("Connect directly to a SPICE server, for example a QEMU or libvirt VM started with -spice port=5900."),
            TextWrapping = TextWrapping.Wrap, Foreground = secondary,
        });

        var grid = new Grid { ColumnSpacing = 12, RowSpacing = 10, MaxWidth = 460, HorizontalAlignment = HorizontalAlignment.Left };
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(80) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(360) });
        int row = 0;
        void Row(string? label, FrameworkElement control)
        {
            grid.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
            var text = new TextBlock { Text = label ?? "", VerticalAlignment = VerticalAlignment.Center, HorizontalAlignment = HorizontalAlignment.Right };
            Grid.SetRow(text, row); Grid.SetRow(control, row); Grid.SetColumn(control, 1);
            grid.Children.Add(text); grid.Children.Add(control);
            row++;
        }
        Row(L.T("Host"), host);
        Row(L.T("Port"), port);
        Row(null, tls);
        Row(L.T("Password"), password);
        page.Children.Add(grid);

        var buttons = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
        var open = new Button { Content = L.T("Open Connection File…") };
        buttons.Children.Add(connect);
        buttons.Children.Add(open);
        page.Children.Add(buttons);

        page.Children.Add(new Border { Height = 1, Background = (Brush)Application.Current.Resources["DividerStrokeColorDefaultBrush"] });
        page.Children.Add(new TextBlock { Text = L.T("Using Proxmox?"), Style = (Style)Application.Current.Resources["BodyStrongTextBlockStyle"] });
        page.Children.Add(new TextBlock
        {
            Text = L.T("Add your server in the sidebar to list its VMs and connect with one click. You can also open the .vv files that Proxmox downloads when you choose Console → SPICE."),
            TextWrapping = TextWrapping.Wrap, Foreground = secondary,
        });
        var add = new Button { Content = L.T("Add Proxmox Server…") };
        page.Children.Add(add);
        Content = new ScrollViewer { Content = page };

        host.TextChanged += (_, _) => connect.IsEnabled = host.Text.Trim().Length > 0;
        connect.IsEnabled = host.Text.Trim().Length > 0;
        connect.Click += async (_, _) => await ConnectAsync();
        open.Click += async (_, _) => await OpenFileAsync();
        add.Click += async (_, _) => await window.EditServerAsync(null);
    }

    private async Task ConnectAsync()
    {
        var prefs = model.Settings.Preferences;
        prefs.QuickHost = host.Text.Trim();
        prefs.QuickPort = double.IsNaN(port.Value) ? 5900 : (int)port.Value;
        prefs.QuickTls = tls.IsChecked == true;
        model.Settings.Save();

        var config = new ViewerConfig();
        config["host"] = prefs.QuickHost;
        config[prefs.QuickTls ? "tls-port" : "port"] = prefs.QuickPort.ToString();
        if (password.Password.Length > 0) config["password"] = password.Password;
        try { await ViewerLauncher.LaunchAsync(config, $"{prefs.QuickHost}:{prefs.QuickPort}", prefs.Fullscreen); }
        catch (Exception e) { await model.PresentAsync(e); }
    }

    private async Task OpenFileAsync()
    {
        var picker = new Windows.Storage.Pickers.FileOpenPicker();
        picker.FileTypeFilter.Add(".vv");
        WinRT.Interop.InitializeWithWindow.Initialize(picker, WinRT.Interop.WindowNative.GetWindowHandle(window));
        if (await picker.PickSingleFileAsync() is not { } file) return;
        try { await ViewerLauncher.LaunchAsync([file.Path]); }
        catch (Exception e) { await model.PresentAsync(e); }
    }
}
