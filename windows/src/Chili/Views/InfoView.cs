using System.Runtime.InteropServices;
using Chili.Core;
using Chili.Services;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Imaging;
using Windows.System;

namespace Chili.Views;

/// <summary>About Chili: version, updates (check now, automatic checks), links, the bundled
/// components and their versions, and the folders where Chili keeps its settings and logs.</summary>
public sealed class InfoView : UserControl
{
    private const string Project = $"https://github.com/{Updates.Repository}";
    private readonly MainWindow window;
    private readonly TextBlock updateStatus = new() { TextWrapping = TextWrapping.Wrap, VerticalAlignment = VerticalAlignment.Center };
    private readonly Button checkButton = new() { Content = L.T("Check for Updates") };
    private readonly Button updateButton = new() { Content = L.T("Update Now"), Visibility = Visibility.Collapsed };
    private readonly ProgressRing checking = new() { Width = 18, Height = 18, IsActive = false };

    public InfoView(MainWindow window)
    {
        this.window = window;
        updateButton.Style = (Style)Application.Current.Resources["AccentButtonStyle"];
        var page = new StackPanel { Spacing = 18, Padding = new Thickness(32, 24, 32, 32), MaxWidth = 720, HorizontalAlignment = HorizontalAlignment.Left };

        // Header: icon, name, version
        var header = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 18 };
        header.Children.Add(new Image { Source = new BitmapImage(new Uri("ms-appx:///Assets/Chili.png")), Width = 72, Height = 72 });
        var titles = new StackPanel { VerticalAlignment = VerticalAlignment.Center, Spacing = 2 };
        titles.Children.Add(new TextBlock { Text = "Chili", Style = Form.Res("TitleTextBlockStyle") });
        titles.Children.Add(new TextBlock
        {
            Text = L.F("Version %@ (%@)", Updater.Current.ToString(3), RuntimeInformation.ProcessArchitecture.ToString().ToLowerInvariant()),
            Foreground = Form.Secondary, IsTextSelectionEnabled = true,
        });
        titles.Children.Add(new TextBlock { Text = L.T("An unofficial SPICE client and Proxmox VE companion"), Foreground = Form.Secondary });
        header.Children.Add(titles);
        page.Children.Add(header);

        // Updates
        var updates = Card(page, L.T("Updates"));
        var row = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 10 };
        row.Children.Add(checkButton);
        row.Children.Add(updateButton);
        row.Children.Add(checking);
        updates.Children.Add(updateStatus);
        updates.Children.Add(row);
        var auto = new CheckBox
        {
            Content = L.T("Check for updates automatically"), IsChecked = App.Model.Settings.Preferences.CheckForUpdates,
        };
        auto.Click += (_, _) =>
        {
            App.Model.Settings.Preferences.CheckForUpdates = auto.IsChecked == true;
            App.Model.Settings.Save();
        };
        updates.Children.Add(auto);
        if (!Updater.IsInstalled)
            updates.Children.Add(Form.Caption(L.T("This copy wasn't installed with the setup: updates are only checked, not installed.")));
        checkButton.Click += async (_, _) => await CheckAsync();
        updateButton.Click += (_, _) => window.StartUpdate();
        ShowUpdateState();

        // Links
        var links = Card(page, L.T("Links"));
        AddLink(links, L.T("Project page"), Project);
        AddLink(links, L.T("What's new in this version"), $"{Project}/releases/tag/v{Updater.Current.ToString(3)}");
        AddLink(links, L.T("All releases"), $"{Project}/releases");
        AddLink(links, L.T("Report a problem"), $"{Project}/issues");
        AddLink(links, L.T("Source code"), Project);

        // Components
        var parts = Card(page, L.T("Components"));
        var grid = new Grid { ColumnSpacing = 24, RowSpacing = 4 };
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        int r = 0;
        foreach (var (name, version) in Components())
        {
            grid.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
            var n = new TextBlock { Text = name };
            var v = new TextBlock { Text = version, Foreground = Form.Secondary, IsTextSelectionEnabled = true };
            Grid.SetRow(n, r); Grid.SetRow(v, r); Grid.SetColumn(v, 1);
            grid.Children.Add(n); grid.Children.Add(v);
            r++;
        }
        parts.Children.Add(grid);
        parts.Children.Add(Form.Caption(L.T("Chili is free software under the GNU GPL, version 2 or later. Each release ships the source of every bundled component.")));

        // Folders
        var folders = Card(page, L.T("Folders"));
        var buttons = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
        buttons.Children.Add(FolderButton(L.T("Settings"), SettingsStore.Directory));
        buttons.Children.Add(FolderButton(L.T("Logs"), ViewerLauncher.LogDirectory));
        buttons.Children.Add(FolderButton(L.T("Program"), AppContext.BaseDirectory));
        folders.Children.Add(buttons);
        folders.Children.Add(Form.Caption(L.T("Passwords and tokens are kept in Windows Credential Manager, not in these folders.")));

        Content = new ScrollViewer { Content = page };
        window.UpdateAvailable += _ => ShowUpdateState();
    }

    private static StackPanel Card(Panel page, string title)
    {
        var inner = new StackPanel { Spacing = 10 };
        var outer = new StackPanel { Spacing = 8 };
        outer.Children.Add(new TextBlock { Text = title, Style = Form.Res("BodyStrongTextBlockStyle") });
        outer.Children.Add(new Border
        {
            Child = inner, Padding = new Thickness(16), CornerRadius = new CornerRadius(8),
            Background = (Brush)Application.Current.Resources["CardBackgroundFillColorDefaultBrush"],
            BorderBrush = (Brush)Application.Current.Resources["CardStrokeColorDefaultBrush"], BorderThickness = new Thickness(1),
        });
        page.Children.Add(outer);
        return inner;
    }

    private static void AddLink(Panel panel, string text, string url) =>
        panel.Children.Add(new HyperlinkButton { Content = text, NavigateUri = new Uri(url), Padding = new Thickness(0) });

    private static Button FolderButton(string text, string path)
    {
        var b = new Button { Content = text };
        ToolTipService.SetToolTip(b, path);
        b.Click += async (_, _) =>
        {
            Directory.CreateDirectory(path);
            await Launcher.LaunchFolderPathAsync(path);
        };
        return b;
    }

    private async Task CheckAsync()
    {
        if (window.Updater is not { } updater) { ShowUpdateState(); return; }
        checkButton.IsEnabled = false;
        checking.IsActive = true;
        updateStatus.Text = L.T("Checking…");
        await updater.CheckNowAsync();
        checking.IsActive = false;
        checkButton.IsEnabled = true;
        ShowUpdateState();
    }

    private void ShowUpdateState()
    {
        var updater = window.Updater;
        updateButton.Visibility = Visibility.Collapsed;
        if (updater is null)
        {
            updateStatus.Text = L.T("Updates are not checked in this mode.");
            checkButton.IsEnabled = false;
        }
        else if (updater.Pending is { } release)
        {
            updateStatus.Text = L.F("Chili %@ is available", release.Version.ToString(3));
            if (Updater.IsInstalled) updateButton.Visibility = Visibility.Visible;
        }
        else if (updater.LastError is { } error)
        {
            updateStatus.Text = L.F("Couldn't check for updates: %@", error);
        }
        else if (updater.LastChecked is { } when)
        {
            updateStatus.Text = L.F("Chili is up to date (checked at %@).", when.ToString("t"));
        }
        else
        {
            updateStatus.Text = L.T("Not checked yet.");
        }
    }

    /// <summary>Versions of what Chili is made of: the SPICE stack from the bundle's PACKAGES.txt
    /// (MSYS2 packages), plus .NET and the WebView2 runtime.</summary>
    private static IEnumerable<(string Name, string Version)> Components()
    {
        var wanted = new (string Package, string Label)[]
        {
            ("spice-gtk", "spice-gtk (SPICE)"), ("virt-viewer", "virt-viewer (remote-viewer)"),
            ("gstreamer", "GStreamer"), ("gtk3", "GTK"), ("openssl", "OpenSSL"),
        };
        var packages = new Dictionary<string, string>();
        var list = Path.Combine(AppContext.BaseDirectory, "viewer", "PACKAGES.txt");
        if (File.Exists(list))
            foreach (var line in File.ReadLines(list))
            {
                var p = line.Split(' ', 2);
                if (p.Length == 2 && p[0].StartsWith("mingw-w64-", StringComparison.Ordinal))
                    packages[p[0][(p[0].IndexOf("-x86_64-", StringComparison.Ordinal) is var i and >= 0 ? i + 8 : 0)..]] = p[1].Split('-')[0];
            }
        foreach (var (package, label) in wanted)
            if (packages.TryGetValue(package, out var v)) yield return (label, v);
        yield return (".NET", Environment.Version.ToString(3));
        string webview;
        try { webview = Microsoft.Web.WebView2.Core.CoreWebView2Environment.GetAvailableBrowserVersionString() ?? "—"; }
        catch { webview = L.T("not installed"); }
        yield return ("WebView2", webview);
    }
}
