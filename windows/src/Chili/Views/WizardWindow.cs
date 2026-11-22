using Chili.Core;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;

namespace Chili.Views;

/// <summary>Shell shared by the VM and container wizards: header, scrolling form, footer with
/// the first problem (or the error), progress, Cancel and Create.</summary>
public abstract class WizardWindow : ToolWindow
{
    protected readonly StackPanel Header = new() { Spacing = 10, Padding = new Thickness(20, 16, 20, 14) };
    protected readonly TextBlock Description = Form.Caption("");
    private readonly ScrollViewer scroller = new() { Padding = new Thickness(20, 16, 28, 16) };
    private readonly TextBlock problem = new() { TextWrapping = TextWrapping.Wrap, MaxLines = 6 };
    private readonly ProgressRing progressRing = new() { Width = 18, Height = 18, IsActive = false };
    private readonly TextBlock progressText = new() { Foreground = Form.Secondary, VerticalAlignment = VerticalAlignment.Center };
    private readonly Button create = new() { Content = L.T("Create"), Style = Form.Res("AccentButtonStyle"), MinWidth = 100 };
    private readonly Button cancel = new() { Content = L.T("Cancel"), MinWidth = 100 };
    private bool loading = true, creating, closed;

    protected string? Error { get; set; }

    protected WizardWindow(string title, string snapshotName) : base(title, 640, 720, snapshotName)
    {
        var grid = new Grid();
        grid.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        grid.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
        grid.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });

        Header.Children.Add(new TextBlock { Text = title, Style = Form.Res("SubtitleTextBlockStyle") });
        grid.Children.Add(Header);

        Grid.SetRow(scroller, 1);
        scroller.BorderBrush = (Brush)Application.Current.Resources["DividerStrokeColorDefaultBrush"];
        scroller.BorderThickness = new Thickness(0, 1, 0, 1);
        grid.Children.Add(scroller);

        var footer = new Grid { Padding = new Thickness(20, 12, 20, 16), RowSpacing = 8, ColumnSpacing = 8 };
        footer.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        footer.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        footer.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        footer.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        Grid.SetColumnSpan(problem, 2);
        footer.Children.Add(problem);
        var progress = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
        progress.Children.Add(progressRing);
        progress.Children.Add(progressText);
        Grid.SetRow(progress, 1);
        footer.Children.Add(progress);
        var buttons = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
        buttons.Children.Add(cancel);
        buttons.Children.Add(create);
        Grid.SetRow(buttons, 1);
        Grid.SetColumn(buttons, 1);
        footer.Children.Add(buttons);
        Grid.SetRow(footer, 2);
        grid.Children.Add(footer);
        Content = grid;

        Closed += (_, _) => closed = true;
        cancel.Click += (_, _) => Close();
        create.Click += async (_, _) => await RunCreateAsync();
    }

    /// <summary>Call at the end of the subclass constructor.</summary>
    protected async void Start()
    {
        Rebuild();
        await LoadAsync();
        loading = false;
        Rebuild();
    }

    protected abstract Task LoadAsync();
    protected abstract void Build(Form form);
    protected abstract List<string> Problems { get; }
    /// <summary>Creates the machine; returns what to do afterwards (run after the window closes).</summary>
    protected abstract Task<Func<Task>?> CreateAsync(Action<string> progress);

    /// <summary>Rebuilds the form from the draft (on structural changes: mode, node, OS…).</summary>
    protected void Rebuild()
    {
        if (closed) return;
        if (loading)
        {
            var wait = new StackPanel { Spacing = 12, HorizontalAlignment = HorizontalAlignment.Center, Margin = new Thickness(40) };
            wait.Children.Add(new ProgressRing { IsActive = true });
            wait.Children.Add(new TextBlock { Text = L.T("Loading the server's storages and networks…"), Foreground = Form.Secondary });
            scroller.Content = wait;
        }
        else
        {
            var offset = scroller.VerticalOffset;
            var form = new Form();
            Build(form);
            scroller.Content = form.Panel;
            DispatcherQueue.TryEnqueue(() => scroller.ChangeView(null, offset, null, disableAnimation: true));
        }
        Validate();
    }

    protected void Validate()
    {
        if (closed) return;
        if (Error is { } e)
        {
            problem.Text = e;
            problem.Foreground = (Brush)Application.Current.Resources["SystemFillColorCriticalBrush"];
        }
        else
        {
            problem.Text = loading ? "" : Problems.FirstOrDefault() ?? "";
            problem.Foreground = Form.Secondary;
        }
        problem.Visibility = problem.Text.Length == 0 ? Visibility.Collapsed : Visibility.Visible;
        create.IsEnabled = !loading && !creating && Problems.Count == 0;
        cancel.IsEnabled = !creating;
    }

    private async Task RunCreateAsync()
    {
        creating = true;
        Error = null;
        Validate();
        progressRing.IsActive = true;
        try
        {
            var then = await CreateAsync(p => { if (!closed) progressText.Text = p; });
            Close();
            if (then is not null) await then();
        }
        catch (Exception e)
        {
            Error = e.Message;
        }
        finally
        {
            creating = false;
            if (!closed)
            {
                progressRing.IsActive = false;
                progressText.Text = "";
                Validate();
            }
        }
    }

    // MARK: Pickers shared by both wizards

    protected void NodePicker(Form f, List<string> nodes, string selected, Func<string, Task> changed, Panel? target = null)
    {
        if (nodes.Count <= 1) return;
        f.Choice(L.T("Node"), nodes.Select(n => (n, n)), selected, async n => { await changed(n); Rebuild(); }, 260, target);
    }

    protected void StoragePicker(Form f, string label, IEnumerable<Core.Proxmox.Storage> storages, string selected,
                                 Action<string> set, Panel? target = null) =>
        f.Choice(label, storages.Select(s => (Form.StorageLabel(s), s.Name)), selected, v => { set(v); Validate(); }, 320, target);

    protected void BridgePicker(Form f, IEnumerable<Core.Proxmox.NetworkInterface> bridges, string selected,
                                Action<string> set, Panel? target = null) =>
        f.Choice(L.T("Network"), bridges.Select(b => (Form.BridgeLabel(b), b.Iface)), selected, v => { set(v); Validate(); }, 320, target);
}
