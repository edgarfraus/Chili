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
        Consoles = new Consoles(model);
        InitializeComponent();
        AppWindow.Resize(new Windows.Graphics.SizeInt32(1180, 760));
        if (AppWindow.Presenter is OverlappedPresenter p)
        {
            p.PreferredMinimumWidth = 820;
            p.PreferredMinimumHeight = 480;
        }
        AddServerItem.Content = L.T("Add Server…");
        model.ShowAlert = ShowAlertAsync;
        model.ServersChanged += () => BuildMenu(Nav.SelectedItem is NavigationViewItem { Tag: string t } ? t : null);
        BuildMenu(model.Settings.Servers.FirstOrDefault() is { } first ? ServerTag(first) : QuickTag);
        Debug.StartSnapshots(this, "main");
        if (Debug.Action is { } action) DispatcherQueue.TryEnqueue(async () => await RunDebugAction(action));
    }

    private static string ServerTag(ServerProfile p) => $"server:{p.Id}";

    private void BuildMenu(string? select)
    {
        Nav.MenuItems.Clear();
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
        var target = Nav.MenuItems.OfType<NavigationViewItem>().FirstOrDefault(i => (string)i.Tag == select)
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
        else if (tag.StartsWith("server:") && Guid.TryParse(tag[7..], out var id)
                 && model.Settings.Servers.FirstOrDefault(s => s.Id == id) is { } profile)
        {
            Detail.Content = new ServerView(model.Session(profile), this);
        }
        else
        {
            Detail.Content = null;
        }
    }

    private async void OnAddServer(object sender, TappedRoutedEventArgs e) => await EditServerAsync(null);

    public async Task EditServerAsync(ServerProfile? profile)
    {
        var editor = new ServerEditorDialog(model, profile);
        var result = await ShowDialogAsync(editor);
        if (editor.Removed)
        {
            model.Delete(profile!);
        }
        else if (result == ContentDialogResult.Primary)
        {
            model.Save(editor.Result, editor.Secret);
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
            case "edit":
                if (model.Settings.Servers.FirstOrDefault() is { } p) await EditServerAsync(p);
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
            case "alert":
                await model.PresentAsync(new Core.Proxmox.HttpProxmoxException(0, "Parameter verification failed.\nnet0: invalid format"));
                break;
        }
    }
}
