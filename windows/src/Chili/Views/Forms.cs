using System.Runtime.InteropServices;
using Chili.Core;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;

namespace Chili.Views;

/// <summary>Form building blocks for the wizards: explicit rows with a fixed, right-aligned
/// label column (flexible form layouts inflated the window on macOS).</summary>
public sealed class Form
{
    public StackPanel Panel { get; } = new() { Spacing = 10 };
    private readonly double labelWidth;

    public Form(double labelWidth = 170) => this.labelWidth = labelWidth;

    public static Brush Secondary => (Brush)Application.Current.Resources["TextFillColorSecondaryBrush"];
    public static Style Res(string key) => (Style)Application.Current.Resources[key];

    /// <summary>A label + control row, added to <paramref name="target"/> (default: the form).</summary>
    public Grid Row(string? label, FrameworkElement control, Panel? target = null)
    {
        var grid = new Grid { ColumnSpacing = 12 };
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(labelWidth) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        var text = new TextBlock
        {
            Text = label ?? "", HorizontalAlignment = HorizontalAlignment.Right, VerticalAlignment = VerticalAlignment.Center,
            TextAlignment = TextAlignment.Right, TextWrapping = TextWrapping.Wrap,
        };
        FrameworkElement placed = control;
        if (control is not TextBlock && double.IsNaN(control.Width) && !double.IsPositiveInfinity(control.MaxWidth))
        {
            // Drop-downs and text fields: as wide as the column allows, up to MaxWidth, flush left.
            // (A stretched element with a MaxWidth would be centred.)
            var host = new Grid();
            host.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star), MaxWidth = control.MaxWidth });
            host.Children.Add(control);
            placed = host;
        }
        else if (control is not TextBlock)
        {
            control.HorizontalAlignment = HorizontalAlignment.Left;
        }
        Grid.SetColumn(placed, 1);
        grid.Children.Add(text);
        grid.Children.Add(placed);
        (target ?? Panel).Children.Add(grid);
        return grid;
    }

    /// <summary>A titled group with a subtle background, like the macOS SectionBox.</summary>
    public StackPanel Section(string title)
    {
        var outer = new StackPanel { Spacing = 8 };
        outer.Children.Add(new TextBlock { Text = title, Style = Res("BodyStrongTextBlockStyle") });
        var inner = new StackPanel { Spacing = 10 };
        outer.Children.Add(new Border
        {
            Child = inner, Padding = new Thickness(14), CornerRadius = new CornerRadius(8),
            Background = (Brush)Application.Current.Resources["CardBackgroundFillColorDefaultBrush"],
            BorderBrush = (Brush)Application.Current.Resources["CardStrokeColorDefaultBrush"], BorderThickness = new Thickness(1),
        });
        Panel.Children.Add(outer);
        return inner;
    }

    public void Divider() => Panel.Children.Add(new Border
    {
        Height = 1, Margin = new Thickness(0, 4, 0, 4),
        Background = (Brush)Application.Current.Resources["DividerStrokeColorDefaultBrush"],
    });

    public static TextBlock Caption(string text) => new()
    {
        Text = text, TextWrapping = TextWrapping.Wrap, Foreground = Secondary, Style = Res("CaptionTextBlockStyle"),
    };

    public TextBox Text(string label, string value, Action<string> set, string? placeholder = null, double width = 260, Panel? target = null)
    {
        var box = new TextBox { Text = value, PlaceholderText = placeholder ?? "", MaxWidth = width, HorizontalAlignment = HorizontalAlignment.Stretch };
        box.TextChanged += (_, _) => set(box.Text);
        Row(label, box, target);
        return box;
    }

    public PasswordBox Password(string label, string value, Action<string> set, double width = 260, Panel? target = null)
    {
        var box = new PasswordBox { MaxWidth = width, Password = value, HorizontalAlignment = HorizontalAlignment.Stretch };
        box.PasswordChanged += (_, _) => set(box.Password);
        Row(label, box, target);
        return box;
    }

    public NumberBox Number(string label, int value, int min, int max, Action<int> set, int step = 1, string unit = "", Panel? target = null)
    {
        var box = new NumberBox
        {
            Value = value, Minimum = min, Maximum = max, SmallChange = step, LargeChange = step * 10, Width = 150,
            SpinButtonPlacementMode = NumberBoxSpinButtonPlacementMode.Inline,
            ValidationMode = NumberBoxValidationMode.InvalidInputOverwritten,
        };
        box.ValueChanged += (_, e) => { if (!double.IsNaN(e.NewValue)) set((int)e.NewValue); };
        if (unit.Length == 0) { Row(label, box, target); return box; }
        var line = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
        line.Children.Add(box);
        line.Children.Add(new TextBlock { Text = unit, Foreground = Secondary, VerticalAlignment = VerticalAlignment.Center });
        Row(label, line, target);
        return box;
    }

    public CheckBox Check(string text, bool value, Action<bool> set, Panel? target = null)
    {
        var box = new CheckBox { Content = text, IsChecked = value };
        box.Click += (_, _) => set(box.IsChecked == true);
        Row(null, box, target);
        return box;
    }

    /// <summary>A drop-down of (label, value) pairs. Items with a null value are group headers.</summary>
    public ComboBox Choice<T>(string label, IEnumerable<(string Label, T Value)> items, T selected, Action<T> set,
                              double width = 320, Panel? target = null)
    {
        var box = new ComboBox { MaxWidth = width, HorizontalAlignment = HorizontalAlignment.Stretch };
        foreach (var (text, value) in items)
        {
            var item = new ComboBoxItem { Content = text, Tag = value };
            if (value is null)
            {
                item.IsEnabled = false;
                item.FontWeight = Microsoft.UI.Text.FontWeights.SemiBold;
            }
            box.Items.Add(item);
            if (value is not null && EqualityComparer<T>.Default.Equals(value, selected)) box.SelectedItem = item;
        }
        // Only real changes: callers often rebuild the form, which must not loop.
        box.SelectionChanged += (_, _) =>
        {
            if (box.SelectedItem is not ComboBoxItem { Tag: T v } || EqualityComparer<T>.Default.Equals(v, selected)) return;
            selected = v;
            set(v);
        };
        Row(label, box, target);
        return box;
    }

    public RadioButtons Segments<T>(string label, IEnumerable<(string Label, T Value)> items, T selected, Action<T> set, Panel? target = null)
    {
        var list = items.ToList();
        var radios = new RadioButtons { MaxColumns = list.Count };
        foreach (var (text, _) in list) radios.Items.Add(text);
        var current = Math.Max(0, list.FindIndex(i => EqualityComparer<T>.Default.Equals(i.Value, selected)));
        radios.SelectedIndex = current;
        // RadioButtons raises SelectionChanged again once it's loaded; callers that rebuild the form
        // on a change would then rebuild forever (the container wizard flickered and ignored clicks).
        radios.SelectionChanged += (_, _) =>
        {
            if (radios.SelectedIndex < 0 || radios.SelectedIndex == current) return;
            current = radios.SelectedIndex;
            set(list[current].Value);
        };
        Row(label, radios, target);
        return radios;
    }

    public static string StorageLabel(Core.Proxmox.Storage s) =>
        s.Avail is long free ? $"{s.Name} — " + L.F("%@ free", Services.Format.Bytes(free)) : s.Name;

    public static string BridgeLabel(Core.Proxmox.NetworkInterface b) =>
        b.Comments is { Length: > 0 } c && c.Trim().Length > 0 ? $"{b.Iface} — {c.Trim()}" : b.Iface;
}

/// <summary>A secondary window (wizards, logs) that stays above the main window.</summary>
public class ToolWindow : Window
{
    public ToolWindow(string title, int width, int height, string snapshotName)
    {
        Title = title;
        SystemBackdrop = new MicaBackdrop();
        var scale = App.Windows.FirstOrDefault()?.Content?.XamlRoot?.RasterizationScale ?? 1;
        AppWindow.Resize(new Windows.Graphics.SizeInt32((int)(width * scale), (int)(height * scale)));
        if (App.Windows.FirstOrDefault() is { } owner)
        {
            // Owned window: stays on top of Chili's main window and closes with it.
            SetWindowLongPtrW(WinRT.Interop.WindowNative.GetWindowHandle(this), -8 /* GWLP_HWNDPARENT */,
                              WinRT.Interop.WindowNative.GetWindowHandle(owner));
            var o = owner.AppWindow.Position;
            var os = owner.AppWindow.Size;
            AppWindow.Move(new Windows.Graphics.PointInt32(o.X + (os.Width - AppWindow.Size.Width) / 2,
                                                           o.Y + Math.Max(0, (os.Height - AppWindow.Size.Height) / 2)));
        }
        if (AppWindow.Presenter is OverlappedPresenter p) { p.IsMinimizable = false; }
        App.Windows.Add(this);
        Closed += (_, _) => App.Windows.Remove(this);
        Activated += (_, _) => { if (!snapshotsStarted) { snapshotsStarted = true; Services.Debug.StartSnapshots(this, snapshotName); } };
    }

    private bool snapshotsStarted;

    [DllImport("user32.dll")] private static extern IntPtr SetWindowLongPtrW(IntPtr hwnd, int index, IntPtr value);

    public Task ShowAlertAsync(string title, string message) => new ContentDialog
    {
        Title = title, XamlRoot = Content.XamlRoot,
        Content = new TextBlock { Text = message, TextWrapping = TextWrapping.Wrap, IsTextSelectionEnabled = true },
        CloseButtonText = L.T("OK"),
    }.ShowAsync().AsTask();
}
