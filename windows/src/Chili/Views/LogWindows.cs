using Chili.Core;
using Chili.Core.Proxmox;
using Chili.Services;
using Chili.ViewModels;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Documents;
using Microsoft.UI.Xaml.Media;

namespace Chili.Views;

/// <summary>Readable names for Proxmox task types.</summary>
public static class TaskNames
{
    private static readonly Dictionary<string, string> Names = new()
    {
        ["qmstart"] = "Start", ["vzstart"] = "Start", ["qmstop"] = "Stop", ["vzstop"] = "Stop",
        ["qmshutdown"] = "Shut down", ["vzshutdown"] = "Shut down", ["qmreboot"] = "Reboot", ["vzreboot"] = "Reboot",
        ["qmreset"] = "Reset", ["qmsuspend"] = "Suspend", ["qmresume"] = "Resume", ["vzsuspend"] = "Suspend", ["vzresume"] = "Resume",
        ["qmcreate"] = "Create", ["vzcreate"] = "Create", ["qmdestroy"] = "Delete", ["vzdestroy"] = "Delete",
        ["qmclone"] = "Clone", ["vzclone"] = "Clone", ["qmigrate"] = "Migrate", ["vzmigrate"] = "Migrate",
        ["vzdump"] = "Backup", ["qmrestore"] = "Restore", ["vzrestore"] = "Restore",
        ["qmsnapshot"] = "Snapshot", ["vzsnapshot"] = "Snapshot", ["qmdelsnapshot"] = "Delete snapshot", ["vzdelsnapshot"] = "Delete snapshot",
        ["qmrollback"] = "Rollback", ["vzrollback"] = "Rollback", ["qmmove"] = "Move disk", ["move_volume"] = "Move volume",
        ["qmresize"] = "Resize disk", ["resize"] = "Resize disk", ["qmtemplate"] = "Convert to template", ["vztemplate"] = "Convert to template",
        ["qmconfig"] = "Change configuration", ["vzconfig"] = "Change configuration",
        ["vncproxy"] = "Console (noVNC)", ["vncshell"] = "Shell", ["termproxy"] = "Console (xterm.js)",
        ["spiceproxy"] = "Console (SPICE)", ["spiceshell"] = "Shell (SPICE)", ["imgcopy"] = "Copy image", ["download"] = "Download",
    };

    public static string Label(string type) => Names.TryGetValue(type, out var n) ? L.T(n) : type;
}

/// <summary>Monospaced, selectable log text that keeps to the end while you're at the end.
/// Errors in red, warnings in orange.</summary>
public sealed class LogText : UserControl
{
    private readonly ScrollViewer scroller = new() { HorizontalScrollBarVisibility = ScrollBarVisibility.Auto, Padding = new Thickness(12) };
    private readonly RichTextBlock text = new()
    {
        IsTextSelectionEnabled = true, FontFamily = new FontFamily("Cascadia Mono, Consolas"), FontSize = 12, TextWrapping = TextWrapping.NoWrap,
    };
    private List<string> shown = [];

    public LogText()
    {
        scroller.Content = text;
        Content = new Border { Child = scroller, Background = (Brush)Application.Current.Resources["LayerFillColorDefaultBrush"] };
    }

    public void SetLines(IReadOnlyList<string> lines)
    {
        if (lines.SequenceEqual(shown)) return;
        bool atEnd = shown.Count == 0 || scroller.VerticalOffset >= scroller.ScrollableHeight - 24;
        shown = lines.ToList();
        var paragraph = new Paragraph();
        var red = (Brush)Application.Current.Resources["DangerBrush"];
        var orange = (Brush)Application.Current.Resources["WarningBrush"];
        for (int i = 0; i < lines.Count; i++)
        {
            var line = lines[i];
            var l = line.ToLowerInvariant();
            var run = new Run { Text = line };
            if (l.Contains("error") || l.Contains("failed")) run.Foreground = red;
            else if (l.Contains("warn")) run.Foreground = orange;
            paragraph.Inlines.Add(run);
            if (i < lines.Count - 1) paragraph.Inlines.Add(new LineBreak());
        }
        text.Blocks.Clear();
        text.Blocks.Add(paragraph);
        if (atEnd)
            DispatcherQueue.TryEnqueue(Microsoft.UI.Dispatching.DispatcherQueuePriority.Low, () =>
            {
                scroller.UpdateLayout();
                scroller.ChangeView(null, scroller.ScrollableHeight, null, disableAnimation: true);
            });
    }
}

/// <summary>History of a VM's or container's Proxmox tasks, with the log of the selected one.</summary>
public sealed class VMLogsWindow : ToolWindow
{
    private readonly ServerSession session;
    private readonly ProxmoxVM vm;
    private readonly ListView list = new() { SelectionMode = ListViewSelectionMode.Single };
    private readonly LogText log = new();
    private readonly TextBlock placeholder = new()
    {
        HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center,
        TextWrapping = TextWrapping.Wrap, TextAlignment = TextAlignment.Center, Margin = new Thickness(16), Foreground = Form.Secondary,
    };
    private List<TaskEntry> tasks = [];
    private string? selected;
    private bool loading;

    public VMLogsWindow(ServerSession session, ProxmoxVM vm) : base(L.T("History & Logs"), 980, 620, "vm-logs")
    {
        this.session = session;
        this.vm = vm;
        var grid = new Grid();
        grid.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        grid.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
        grid.Children.Add(LogHeader(L.T("History & Logs"), $"{vm.DisplayName} ({vm.VmId}) · {vm.Node}", null,
                                    async () => await ReloadAsync(), Close));

        var body = new Grid
        {
            BorderBrush = (Brush)Application.Current.Resources["DividerStrokeColorDefaultBrush"], BorderThickness = new Thickness(0, 1, 0, 0),
        };
        body.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(340) });
        body.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        var left = new Grid
        {
            BorderBrush = (Brush)Application.Current.Resources["DividerStrokeColorDefaultBrush"], BorderThickness = new Thickness(0, 0, 1, 0),
        };
        left.Children.Add(list);
        left.Children.Add(placeholder);
        body.Children.Add(left);
        Grid.SetColumn(log, 1);
        body.Children.Add(log);
        Grid.SetRow(body, 1);
        grid.Children.Add(body);
        Content = grid;

        list.SelectionChanged += async (_, _) =>
        {
            if (list.SelectedItem is ListViewItem { Tag: string upid } && upid != selected) { selected = upid; await LoadLogAsync(); }
        };
        var timer = DispatcherQueue.CreateTimer();
        timer.Interval = TimeSpan.FromSeconds(4);
        // Keep following tasks that are still running.
        timer.Tick += async (_, _) => { if (tasks.Any(t => t.IsRunning)) await ReloadAsync(); };
        timer.Start();
        Closed += (_, _) => timer.Stop();
        _ = ReloadAsync();
    }

    private async Task ReloadAsync()
    {
        if (loading) return;
        loading = true;
        try
        {
            if (tasks.Count == 0) placeholder.Text = L.T("Loading…");
            tasks = Demo.IsOn ? DemoTasks() : await session.Api.TasksAsync(vm);
            placeholder.Text = tasks.Count == 0 ? L.T("No tasks recorded for this machine yet.") : "";
        }
        catch (Exception e) { placeholder.Text = e.Message; }
        finally { loading = false; }
        placeholder.Visibility = placeholder.Text.Length == 0 ? Visibility.Collapsed : Visibility.Visible;

        list.Items.Clear();
        foreach (var t in tasks)
        {
            var item = new ListViewItem { Tag = t.Upid, Content = TaskRow(t) };
            list.Items.Add(item);
            if (t.Upid == selected) list.SelectedItem = item;
        }
        if (selected is null && list.Items.Count > 0) list.SelectedIndex = 0;
        else await LoadLogAsync();
    }

    private async Task LoadLogAsync()
    {
        if (tasks.FirstOrDefault(t => t.Upid == selected) is not { } task) { log.SetLines([L.T("Select a task to see its log.")]); return; }
        try { log.SetLines(Demo.IsOn ? DemoLog(task) : await session.Api.TaskLogAsync(task.Node, task.Upid)); }
        catch (Exception e) { log.SetLines([e.Message]); }
    }

    private static FrameworkElement TaskRow(TaskEntry t)
    {
        var row = new Grid { ColumnSpacing = 10, Padding = new Thickness(0, 4, 0, 4) };
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(18) });
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        FrameworkElement icon = t.IsRunning
            ? new ProgressRing { IsActive = true, Width = 14, Height = 14 }
            : new FontIcon
            {
                Glyph = t.Succeeded ? "" : "", FontSize = 14,
                Foreground = (Brush)Application.Current.Resources[t.Succeeded ? "RunningBrush" : "WarningBrush"],
            };
        icon.VerticalAlignment = VerticalAlignment.Top;
        icon.Margin = new Thickness(0, 3, 0, 0);
        row.Children.Add(icon);
        var text = new StackPanel { Spacing = 1 };
        text.Children.Add(new TextBlock { Text = TaskNames.Label(t.Type), FontWeight = Microsoft.UI.Text.FontWeights.SemiBold });
        text.Children.Add(new TextBlock { Text = Subtitle(t), Style = Form.Res("CaptionTextBlockStyle"), Foreground = Form.Secondary });
        if (t.Status is { } status && !t.Succeeded && !t.IsRunning)
            text.Children.Add(new TextBlock
            {
                Text = status, Style = Form.Res("CaptionTextBlockStyle"), TextWrapping = TextWrapping.Wrap, MaxLines = 2,
                Foreground = (Brush)Application.Current.Resources["DangerBrush"],
            });
        Grid.SetColumn(text, 1);
        row.Children.Add(text);
        return row;
    }

    private static string Subtitle(TaskEntry t)
    {
        var parts = new List<string> { t.StartDate.ToLocalTime().ToString("g") };
        if (t.Duration is { TotalSeconds: >= 1 } d)
            parts.Add(d.TotalHours >= 1 ? $"{(int)d.TotalHours} h {d.Minutes} min"
                      : d.TotalMinutes >= 1 ? $"{(int)d.TotalMinutes} min {d.Seconds} s" : $"{d.Seconds} s");
        if (t.User is { } u) parts.Add(u);
        return string.Join(" · ", parts);
    }

    /// <summary>Header shared by the log windows: title, subtitle, extra controls, refresh, close.</summary>
    internal static Grid LogHeader(string title, string subtitle, FrameworkElement? extra, Action refresh, Action close)
    {
        var header = new Grid { Padding = new Thickness(20, 14, 16, 14), ColumnSpacing = 12 };
        header.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        header.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        var titles = new StackPanel { Spacing = 2 };
        titles.Children.Add(new TextBlock { Text = title, Style = Form.Res("SubtitleTextBlockStyle") });
        titles.Children.Add(new TextBlock { Text = subtitle, Foreground = Form.Secondary });
        header.Children.Add(titles);
        var buttons = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8, VerticalAlignment = VerticalAlignment.Center };
        if (extra is not null) buttons.Children.Add(extra);
        var refreshButton = new Button { Content = new SymbolIcon(Symbol.Refresh) };
        ToolTipService.SetToolTip(refreshButton, L.T("Refresh"));
        refreshButton.Click += (_, _) => refresh();
        var closeButton = new Button { Content = L.T("Close") };
        closeButton.Click += (_, _) => close();
        buttons.Children.Add(refreshButton);
        buttons.Children.Add(closeButton);
        Grid.SetColumn(buttons, 1);
        header.Children.Add(buttons);
        return header;
    }

    // MARK: Demo data (screenshots)

    private List<TaskEntry> DemoTasks()
    {
        long now = DateTimeOffset.UtcNow.ToUnixTimeSeconds();
        TaskEntry T(string type, long ago, long? took, string? status) => new()
        {
            Upid = $"UPID:pve1:0000{ago:X4}:{type}:{vm.VmId}", Type = type, StartTime = now - ago,
            EndTime = took is long d ? now - ago + d : null, Status = status, User = "root@pam", Node = vm.Node,
        };
        return
        [
            T("spiceproxy", 120, 1, "OK"), T("qmstart", 180, 3, "OK"), T("qmshutdown", 4000, 22, "OK"),
            T("qmstart", 86_400, 2, "start failed: QEMU exited with code 1"), T("qmconfig", 90_000, 1, "OK"),
            T("qmcreate", 172_800, 7, "OK"),
        ];
    }

    private static List<string> DemoLog(TaskEntry t) => t.Succeeded
        ? ["generating cloud-init ISO", "TASK OK"]
        : ["kvm: -device vfio-pci,host=0000:01:00.0: vfio 0000:01:00.0: failed to open /dev/vfio/1: No such file or directory",
           "start failed: QEMU exited with code 1", "TASK ERROR: start failed: QEMU exited with code 1"];
}

/// <summary>A node's system journal (latest entries), with a filter and live follow.</summary>
public sealed class NodeLogWindow : ToolWindow
{
    private readonly ServerSession session;
    private readonly string node;
    private readonly LogText log = new();
    private readonly TextBox filter = new() { Width = 220 };
    private readonly CheckBox follow = new() { Content = L.T("Follow"), IsChecked = true, MinWidth = 0 };
    private readonly InfoBar error = new() { Severity = InfoBarSeverity.Error, IsClosable = false };
    private List<string> lines = [];

    public NodeLogWindow(ServerSession session, string node) : base(L.T("System Log"), 980, 640, "node-log")
    {
        this.session = session;
        this.node = node;
        filter.PlaceholderText = L.T("Filter");
        var extra = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 12 };
        extra.Children.Add(filter);
        extra.Children.Add(follow);

        var grid = new Grid();
        grid.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        grid.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        grid.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
        grid.Children.Add(VMLogsWindow.LogHeader(L.T("System Log"), node, extra, async () => await ReloadAsync(), Close));
        Grid.SetRow(error, 1);
        grid.Children.Add(error);
        Grid.SetRow(log, 2);
        grid.Children.Add(log);
        Content = grid;

        filter.TextChanged += (_, _) => Show();
        var timer = DispatcherQueue.CreateTimer();
        timer.Interval = TimeSpan.FromSeconds(5);
        timer.Tick += async (_, _) => { if (follow.IsChecked == true) await ReloadAsync(); };
        timer.Start();
        Closed += (_, _) => timer.Stop();
        _ = ReloadAsync();
    }

    private async Task ReloadAsync()
    {
        try
        {
            lines = Demo.IsOn ? DemoJournal() : await session.Api.JournalAsync(node);
            error.IsOpen = false;
        }
        catch (Exception e)
        {
            error.Message = e.Message;
            error.IsOpen = true;
        }
        Show();
    }

    private void Show() =>
        log.SetLines(filter.Text.Length == 0 ? lines : lines.Where(l => l.Contains(filter.Text, StringComparison.CurrentCultureIgnoreCase)).ToList());

    private List<string> DemoJournal()
    {
        var t = DateTime.Now.AddMinutes(-30);
        string At(int min) => t.AddMinutes(min).ToString("MMM dd HH:mm:ss", System.Globalization.CultureInfo.InvariantCulture);
        return
        [
            $"{At(0)} {node} systemd[1]: Started pvestatd.service - PVE Status Daemon.",
            $"{At(2)} {node} pvedaemon[1432]: <root@pam> starting task UPID:{node}:00002A1F:qmstart:100:root@pam:",
            $"{At(2)} {node} kernel: tap100i0: entered promiscuous mode",
            $"{At(3)} {node} pvedaemon[1432]: <root@pam> end task UPID:{node}:00002A1F:qmstart:100:root@pam: OK",
            $"{At(9)} {node} pveproxy[2210]: proxy detected vanished client connection",
            $"{At(14)} {node} smartd[812]: Device: /dev/sda [SAT], SMART Usage Attribute: 194 Temperature_Celsius changed from 61 to 62",
            $"{At(21)} {node} pvestatd[1201]: storage 'nas' is not online",
            $"{At(22)} {node} pvescheduler[3310]: replication: error - job 104-0 failed: no route to host",
            $"{At(29)} {node} pmxcfs[1011]: [status] notice: received log",
        ];
    }
}
