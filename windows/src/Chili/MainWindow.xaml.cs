using Chili.Core;
using Chili.Services;
using Chili.ViewModels;
using Chili.Views;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;

namespace Chili;

/// <summary>Sidebar (Quick Connect, Proxmox servers, Add Server…) and a detail pane that is
/// rebuilt on every selection change, like the macOS ContentView.</summary>
public sealed partial class MainWindow : Window
{
    private readonly AppModel model;
    public Consoles Consoles { get; }
    private readonly SemaphoreSlim dialogGate = new(1, 1);
    private const string QuickTag = "quick";

    public MainWindow(AppModel model)
    {
        this.model = model;
        Consoles = new Consoles(model, this);
        InitializeComponent();
        AppWindow.Resize(new Windows.Graphics.SizeInt32(1180, 760));
        // The icon embedded in Chili.exe (ApplicationIcon), so no loose file is needed.
        var icon = ExtractIconW(IntPtr.Zero, Environment.ProcessPath ?? "", 0);
        if (icon > 1) AppWindow.SetIcon(Microsoft.UI.Win32Interop.GetIconIdFromIcon(icon));
        if (AppWindow.Presenter is OverlappedPresenter p)
        {
            p.PreferredMinimumWidth = 820;
            p.PreferredMinimumHeight = 480;
        }
        AddServerItem.Content = L.T("Add Server…");
        InfoItem.Content = L.T("Info");
        model.ShowAlert = ShowAlertAsync;
        model.ServersChanged += () => BuildMenu(Nav.SelectedItem is NavigationViewItem { Tag: string t } ? t : null);
        BuildMenu(model.Settings.Servers.FirstOrDefault() is { } first ? ServerTag(first) : QuickTag);
        StartUpdater();
        Debug.StartSnapshots(this, "main");
        if (Debug.Action is { } action) DispatcherQueue.TryEnqueue(async () => await RunDebugAction(action));
    }

    private static string ServerTag(ServerProfile p) => $"server:{p.Id}";

    private void BuildMenu(string? select)
    {
        Nav.MenuItems.Clear();
        consoleIcons.Clear();
        if (model.Consoles.Count > 0)
        {
            Nav.MenuItems.Add(new NavigationViewItemHeader { Content = L.T("Consoles") });
            foreach (var console in model.Consoles)
            {
                var icon = new FontIcon { Glyph = "" };
                consoleIcons[console.Id] = icon;
                var item = new NavigationViewItem { Content = console.Title, Tag = ConsoleTag(console), Icon = icon };
                var menu = new MenuFlyout();
                var close = new MenuFlyoutItem { Text = L.T("Disconnect") };
                close.Click += (_, _) => CloseConsole(console);
                menu.Items.Add(close);
                item.ContextFlyout = menu;
                Nav.MenuItems.Add(item);
                UpdateConsoleIcon(console);
            }
        }
        Nav.MenuItems.Add(new NavigationViewItem
        {
            Content = L.T("Quick Connect"), Tag = QuickTag, Icon = new FontIcon { Glyph = "" },
        });
        Nav.MenuItems.Add(new NavigationViewItemHeader { Content = L.T("Proxmox Servers") });
        foreach (var profile in model.Settings.Servers)
        {
            var item = new NavigationViewItem
            {
                Content = profile.Title, Tag = ServerTag(profile), Icon = new FontIcon { Glyph = "" },
            };
            var menu = new MenuFlyout();
            var edit = new MenuFlyoutItem { Text = L.T("Edit…") };
            edit.Click += async (_, _) => await EditServerAsync(profile);
            var remove = new MenuFlyoutItem { Text = L.T("Remove") };
            remove.Click += (_, _) => model.Delete(profile);
            menu.Items.Add(edit);
            menu.Items.Add(remove);
            item.ContextFlyout = menu;
            Nav.MenuItems.Add(item);
        }
        var target = (select == InfoTag ? InfoItem : null)
                     ?? Nav.MenuItems.OfType<NavigationViewItem>().FirstOrDefault(i => (string)i.Tag == select)
                     ?? Nav.MenuItems.OfType<NavigationViewItem>().First();
        Nav.SelectedItem = target;
        ShowDetail((string)target.Tag);
    }

    private void OnSelectionChanged(NavigationView sender, NavigationViewSelectionChangedEventArgs args)
    {
        if (args.SelectedItem is NavigationViewItem { Tag: string tag }) ShowDetail(tag);
    }

    private string? shownTag;

    private void ShowDetail(string tag)
    {
        if (tag == shownTag && Detail.Content is not null) return;
        shownTag = tag;
        if (tag == QuickTag)
        {
            Detail.Content = new QuickConnectView(model, this);
        }
        else if (tag == InfoTag)
        {
            Detail.Content = new InfoView(this);
        }
        else if (tag.StartsWith("server:") && Guid.TryParse(tag[7..], out var id)
                 && model.Settings.Servers.FirstOrDefault(s => s.Id == id) is { } profile)
        {
            Detail.Content = new ServerView(model.Session(profile), this);
        }
        else if (tag.StartsWith("console:") && model.Consoles.FirstOrDefault(c => ConsoleTag(c) == tag) is { } console)
        {
            // Console views are kept while the console is open: a web console would otherwise
            // reload (and reconnect) every time it is selected again.
            if (!consoleViews.TryGetValue(console.Id, out var view))
            {
                view = console switch
                {
                    ConsoleSession spice => new ConsoleView(spice, this),
                    WebConsoleSession webConsole => new WebConsoleView(webConsole, this),
                    _ => throw new InvalidOperationException(),
                };
                consoleViews[console.Id] = view;
            }
            Detail.Content = view;
        }
        else
        {
            Detail.Content = null;
        }
    }

    // MARK: Consoles

    private readonly Dictionary<Guid, FontIcon> consoleIcons = [];
    private readonly Dictionary<Guid, UserControl> consoleViews = [];
    private static string ConsoleTag(IConsole c) => $"console:{c.Id}";

    /// <summary>Opens Proxmox' noVNC / xterm.js console in a sidebar tab (WebView2).</summary>
    public void OpenWebConsole(ServerSession server, Core.Proxmox.WebConsoleKind kind, string title)
    {
        var session = new WebConsoleSession(server, kind, title);
        session.Changed += () => UpdateConsoleIcon(session);
        model.Consoles.Add(session);
        BuildMenu(ConsoleTag(session));
        Activate();
    }

    /// <summary>Opens a built-in SPICE console in the main window and connects it.</summary>
    public void OpenConsole(Core.ViewerConfig config, string title, Func<Task<Core.ViewerConfig>>? freshConfig,
                            Func<string?>? diagnostics = null)
    {
        var session = new ConsoleSession(config, title, freshConfig, DispatcherQueue) { Diagnostics = diagnostics };
        session.Changed += () => UpdateConsoleIcon(session);
        model.Consoles.Add(session);
        session.Connect();
        BuildMenu(ConsoleTag(session));
        Activate();
    }

    public void CloseConsole(IConsole session)
    {
        if (IsFullScreen) ToggleFullScreen();
        model.Consoles.Remove(session);
        consoleViews.Remove(session.Id);
        // Move the selection away before dropping the console (an empty detail pane otherwise).
        string? next = shownTag == ConsoleTag(session)
            ? model.Consoles.LastOrDefault() is { } other ? ConsoleTag(other) : QuickTag
            : shownTag;
        shownTag = null;
        BuildMenu(next);
        session.Close();
    }

    private void UpdateConsoleIcon(IConsole session)
    {
        if (!consoleIcons.TryGetValue(session.Id, out var icon)) return;
        var key = session.State switch
        {
            ConsoleState.Connected => "RunningBrush",
            ConsoleState.Connecting => "WarningBrush",
            _ => "TextFillColorSecondaryBrush",
        };
        icon.Foreground = (Microsoft.UI.Xaml.Media.Brush)Application.Current.Resources[key];
    }

    // MARK: Updates

    private Updater? updater;
    private const string InfoTag = "info";

    /// <summary>Null in demo mode (no network).</summary>
    public Updater? Updater => updater;
    /// <summary>A newer release was found (the Info page listens too).</summary>
    public event Action<Core.ReleaseInfo>? UpdateAvailable;

    private void StartUpdater()
    {
        if (Demo.IsOn) return;
        updater = new Updater(() => model.Settings.Preferences.CheckForUpdates);
        updater.Available += ShowUpdate;
        updater.Start(DispatcherQueue);
    }

    /// <summary>Update Now from the Info page: same as the banner's button.</summary>
    public void StartUpdate() => OnUpdateNow(this, new RoutedEventArgs());

    private void ShowUpdate(Core.ReleaseInfo release)
    {
        UpdateAvailable?.Invoke(release);
        UpdateBar.Title = L.F("Chili %@ is available", release.Version.ToString(3));
        UpdateBar.Message = L.F("You have version %@.", Updater.Current.ToString(3));
        UpdateBar.Severity = InfoBarSeverity.Informational;
        UpdateButton.Content = L.T("Update Now");
        UpdateButton.IsEnabled = true;
        UpdateNotes.Content = L.T("What's New");
        UpdateProgress.Visibility = Visibility.Collapsed;
        UpdateBar.IsOpen = true;
    }

    private async void OnUpdateNotes(object sender, RoutedEventArgs e)
    {
        if (updater?.Pending is { } r) await Windows.System.Launcher.LaunchUriAsync(new Uri(r.PageUrl));
    }

    private async void OnUpdateNow(object sender, RoutedEventArgs e)
    {
        if (updater?.Pending is not { } release) return;
        if (model.Consoles.Count > 0 && !await ConfirmAsync(L.T("Update Chili now?"),
                L.T("Chili closes while the update installs, and reopens afterwards. Open consoles are disconnected."),
                L.T("Update Now")))
            return;
        UpdateButton.IsEnabled = false;
        UpdateProgress.Visibility = Visibility.Visible;
        UpdateProgress.Value = 0;
        UpdateBar.Message = L.T("Downloading the update…");
        try
        {
            var setup = await updater.DownloadAsync(release, new Progress<double>(p => UpdateProgress.Value = p * 100));
            if (!Updater.IsInstalled)
            {
                // Development build: never run the installer over it.
                UpdateBar.Message = L.F("Downloaded and verified: %@", setup);
                UpdateProgress.Visibility = Visibility.Collapsed;
                return;
            }
            UpdateBar.Message = L.T("Installing…");
            foreach (var c in model.Consoles.ToList()) c.Close();
            Updater.RunInstaller(setup);   // replaces the files and starts Chili again
            Application.Current.Exit();
        }
        catch (Exception ex)
        {
            UpdateBar.Severity = InfoBarSeverity.Error;
            UpdateBar.Message = ex.Message;
            UpdateButton.IsEnabled = true;
            UpdateProgress.Visibility = Visibility.Collapsed;
        }
    }

    /// <summary>A .vv file or spice:// link from the command line or a file association.</summary>
    public async Task OpenTargetAsync(string target)
    {
        if (target.EndsWith(".vv", StringComparison.OrdinalIgnoreCase))
        {
            await Consoles.OpenFileAsync(target);
        }
        else if (Core.LaunchArguments.ParseSpiceUri(target) is { } config)
        {
            await Consoles.OpenSpiceAsync(config, $"{config["host"]}:{config["port"] ?? config["tls-port"]}");
        }
        else
        {
            await ShowAlertAsync(L.T("Something went wrong"), L.F("“%@” is not a valid SPICE connection file.", target));
        }
    }

    /// <summary>Shows the window on top (also when a second launch was redirected here).</summary>
    public void BringToFront()
    {
        if (AppWindow.Presenter is OverlappedPresenter { State: OverlappedPresenterState.Minimized } p) p.Restore();
        var hwnd = WinRT.Interop.WindowNative.GetWindowHandle(this);
        SetForegroundWindow(hwnd);
        Activate();
    }

    [System.Runtime.InteropServices.DllImport("user32.dll")] private static extern bool SetForegroundWindow(IntPtr hwnd);
    [System.Runtime.InteropServices.DllImport("shell32.dll", CharSet = System.Runtime.InteropServices.CharSet.Unicode)]
    private static extern IntPtr ExtractIconW(IntPtr instance, string path, int index);

    public bool IsFullScreen => AppWindow.Presenter.Kind == AppWindowPresenterKind.FullScreen;

    /// <summary>Full screen for the console: no sidebar, the display fills the screen.</summary>
    public void ToggleFullScreen()
    {
        bool enter = !IsFullScreen;
        AppWindow.SetPresenter(enter ? AppWindowPresenterKind.FullScreen : AppWindowPresenterKind.Overlapped);
        Nav.IsPaneVisible = !enter;
    }

    private async void OnAddServer(object sender, TappedRoutedEventArgs e) => await EditServerAsync(null);

    public async Task EditServerAsync(ServerProfile? profile, bool expandRemote = false)
    {
        var editor = new ServerEditorDialog(model, profile);
        if (expandRemote) editor.ExpandRemoteAccess();
        var result = await ShowDialogAsync(editor);
        if (editor.Removed)
        {
            model.Delete(profile!);
        }
        else if (result == ContentDialogResult.Primary)
        {
            model.Save(editor.Result, editor.Secret, editor.AccessSecret);
            shownTag = null;
            BuildMenu(ServerTag(editor.Result));
        }
    }

    // MARK: Dialogs (WinUI shows one ContentDialog at a time)

    public async Task<ContentDialogResult> ShowDialogAsync(ContentDialog dialog)
    {
        await dialogGate.WaitAsync();
        try
        {
            dialog.XamlRoot = Content.XamlRoot;
            dialog.RequestedTheme = ((FrameworkElement)Content).ActualTheme;
            return await dialog.ShowAsync();
        }
        finally { dialogGate.Release(); }
    }

    public Task ShowAlertAsync(string title, string message) => ShowDialogAsync(new ContentDialog
    {
        Title = title,
        Content = new TextBlock { Text = message, TextWrapping = TextWrapping.Wrap, IsTextSelectionEnabled = true },
        CloseButtonText = L.T("OK"),
        DefaultButton = ContentDialogButton.Close,
    });

    /// <summary>Asks before something destructive; true when confirmed.</summary>
    public async Task<bool> ConfirmAsync(string title, string message, string action)
    {
        var result = await ShowDialogAsync(new ContentDialog
        {
            Title = title,
            Content = new TextBlock { Text = message, TextWrapping = TextWrapping.Wrap },
            PrimaryButtonText = action,
            CloseButtonText = L.T("Cancel"),
            DefaultButton = ContentDialogButton.Close,
        });
        return result == ContentDialogResult.Primary;
    }

    // MARK: Debug actions (CHILI_DEBUG_ACTION), for screenshots and UI checks

    private async Task RunDebugAction(string action)
    {
        await Task.Delay(800);
        Debug.Log($"debug action: {action}");
        switch (action)
        {
            case "editor":
                await EditServerAsync(null);
                break;
            case "edit-remote":
                if (model.Settings.Servers.FirstOrDefault() is { } pr) await EditServerAsync(pr, expandRemote: true);
                break;
            case "edit":
                if (model.Settings.Servers.FirstOrDefault() is { } p) await EditServerAsync(p);
                break;
            case "info":
                Nav.SelectedItem = InfoItem;
                break;
            case "quick":
                Nav.SelectedItem = Nav.MenuItems[0];
                break;
            case "login":
                if (Detail.Content is ServerView sv) sv.Session.Logout();
                break;
            case "cert":
                await ServerView.ShowCertificatePromptAsync(this, "pve.example.lan",
                    string.Join(":", Enumerable.Range(0, 32).Select(i => (i * 37 % 256).ToString("X2"))));
                break;
            case var a when a.StartsWith("spice:") && int.TryParse(a[6..], out var vmid):
                // Opens the console of a running VM on the first server (never starts one).
                if (Detail.Content is not ServerView view) break;
                for (int i = 0; i < 60 && view.Session.State != ServerSession.SessionState.Ready; i++) await Task.Delay(500);
                var target = view.Session.VMs.FirstOrDefault(v => v.VmId == vmid);
                Debug.Log($"spice: state={view.Session.State} vm={target?.DisplayName} status={target?.Status} running=[{string.Join(", ", view.Session.VMs.Where(v => v.IsRunning && !v.IsContainer).Select(v => $"{v.VmId} {v.DisplayName}"))}]");
                if (target is { IsRunning: true }) await Consoles.ConnectAsync(view.Session, target);
                Debug.Log("spice: launched");
                if (Environment.GetEnvironmentVariable("CHILI_DEBUG_CLOSE_AFTER") is { } secs && int.TryParse(secs, out var s))
                {
                    // Teardown check: close the console, then open and close it once more.
                    for (int round = 0; round < 2; round++)
                    {
                        await Task.Delay(s * 1000);
                        if (model.Consoles.LastOrDefault() is { } open)
                        {
                            Debug.Log($"spice: closing ({open.State})");
                            CloseConsole(open);
                        }
                        if (round == 0 && target is { IsRunning: true })
                        {
                            await Task.Delay(2000);
                            Nav.SelectedItem = Nav.MenuItems.OfType<NavigationViewItem>().First(i => i.Tag is string t && t.StartsWith("server:"));
                            await Task.Delay(500);
                            await Consoles.ConnectAsync(view.Session, target);
                        }
                    }
                    Debug.Log($"spice: closed, consoles={model.Consoles.Count}");
                }
                break;
            case "wizard" or "wizard-custom" or "wizard-win" when Detail.Content is ServerView wv:
            {
                var w = new VMWizardWindow(wv.Session, this);
                w.Activate();
                if (action == "wizard-custom") w.SetCustom(true);
                if (action == "wizard-win") w.DebugSelectWindows();
                break;
            }
            case "ctwizard" when Detail.Content is ServerView cv:
                new ContainerWizardWindow(cv.Session, this).Activate();
                break;
            case "logs" when Detail.Content is ServerView lv && lv.Session.VMs.FirstOrDefault() is { } first:
                new VMLogsWindow(lv.Session, first).Activate();
                break;
            case "syslog" when Detail.Content is ServerView sv2:
                new NodeLogWindow(sv2.Session, (await sv2.Session.LoadNodesAsync()).FirstOrDefault() ?? "pve1").Activate();
                break;
            case var c when c.StartsWith("create:"):
                foreach (var variant in c[7..].Split(',')) await DebugCreateVmAsync(variant);
                break;
            case "ctcreate":
                await DebugCreateContainerAsync();
                break;
            case var t when t.StartsWith("spicetunnel:") && int.TryParse(t[12..], out var tid):
                await DebugSpiceTunnelAsync(tid);
                break;
            case var n when n.StartsWith("novnc:") && int.TryParse(n[6..], out var nid):
                await DebugWebConsoleAsync(nid);
                break;
            case "shell":
                await DebugWebConsoleAsync(null);
                break;
            case var x when x.StartsWith("expire:"):
                await DebugExpireAsync(x[7..]);
                break;
            case "cleanup":
                await DebugCleanupAsync();
                break;
            case "update" when updater is not null:
                await updater.CheckAsync();
                if (updater.Pending is not null) OnUpdateNow(this, new RoutedEventArgs());
                break;
            case "alert":
                await model.PresentAsync(new Core.Proxmox.HttpProxmoxException(0, "Parameter verification failed.\nnet0: invalid format"));
                break;
        }
    }
}
