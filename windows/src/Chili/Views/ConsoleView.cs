using Chili.Core;
using Chili.Spice;
using Chili.ViewModels;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;

namespace Chili.Views;

/// <summary>A built-in console: toolbar (Ctrl+Alt+Del, full screen, disconnect), the display,
/// and overlays for connecting / disconnected (with Reconnect) / mouse capture hints.</summary>
public sealed class ConsoleView : UserControl
{
    private readonly ConsoleSession session;
    private readonly MainWindow window;
    private readonly SpiceDisplay display = new();
    private readonly StackPanel connecting = new() { Spacing = 12, HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center };
    private readonly StackPanel disconnected = new() { Spacing = 12, HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center, MaxWidth = 480 };
    private readonly TextBlock reason = new() { TextWrapping = TextWrapping.Wrap, TextAlignment = TextAlignment.Center, IsTextSelectionEnabled = true };
    private readonly Border hint = new()
    {
        CornerRadius = new CornerRadius(6), Padding = new Thickness(12, 6, 12, 6), Margin = new Thickness(0, 12, 0, 0),
        HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Top, IsHitTestVisible = false,
        Background = new SolidColorBrush(Windows.UI.Color.FromArgb(0xCC, 0x20, 0x20, 0x20)),
    };
    private readonly TextBlock hintText = new() { Foreground = new SolidColorBrush(Microsoft.UI.Colors.White) };
    private readonly Button ctrlAltDel = new() { Content = L.T("Ctrl+Alt+Del") };
    private readonly Button fullScreen = new();
    private readonly DispatcherTimerLite hideHint;

    public ConsoleSession Session => session;

    public ConsoleView(ConsoleSession session, MainWindow window)
    {
        this.session = session;
        this.window = window;
        var secondary = (Brush)Application.Current.Resources["TextFillColorSecondaryBrush"];
        var light = new SolidColorBrush(Microsoft.UI.Colors.White);

        var grid = new Grid();
        grid.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        grid.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });

        // Toolbar
        var bar = new Grid { Padding = new Thickness(16, 8, 12, 8), ColumnSpacing = 8 };
        bar.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        bar.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        bar.Children.Add(new TextBlock
        {
            Text = session.Title, Style = (Style)Application.Current.Resources["BodyStrongTextBlockStyle"],
            VerticalAlignment = VerticalAlignment.Center, TextTrimming = TextTrimming.CharacterEllipsis,
        });
        var buttons = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
        ToolTipService.SetToolTip(ctrlAltDel, L.T("Send Ctrl+Alt+Del to the VM"));
        var disconnect = new Button { Content = L.T("Disconnect") };
        buttons.Children.Add(ctrlAltDel);
        buttons.Children.Add(fullScreen);
        buttons.Children.Add(disconnect);
        Grid.SetColumn(buttons, 1);
        bar.Children.Add(buttons);
        grid.Children.Add(bar);

        // Display + overlays
        var stage = new Grid { Background = new SolidColorBrush(Microsoft.UI.Colors.Black) };
        Grid.SetRow(stage, 1);
        stage.Children.Add(display);
        connecting.Children.Add(new ProgressRing { IsActive = true });
        connecting.Children.Add(new TextBlock { Text = L.T("Connecting…"), Foreground = light, HorizontalAlignment = HorizontalAlignment.Center });
        stage.Children.Add(connecting);
        reason.Foreground = light;
        disconnected.Children.Add(new TextBlock
        {
            Text = L.T("Disconnected"), Foreground = light, HorizontalAlignment = HorizontalAlignment.Center,
            Style = (Style)Application.Current.Resources["SubtitleTextBlockStyle"],
        });
        disconnected.Children.Add(reason);
        var reconnect = new Button
        {
            Content = L.T("Reconnect"), HorizontalAlignment = HorizontalAlignment.Center,
            Style = (Style)Application.Current.Resources["AccentButtonStyle"],
        };
        disconnected.Children.Add(reconnect);
        stage.Children.Add(disconnected);
        hint.Child = hintText;
        stage.Children.Add(hint);
        grid.Children.Add(stage);
        Content = grid;

        display.ResizeGuestToFit = App.Model.Settings.Preferences.ResizeGuest;
        display.CaptureChanged += captured => ShowHint(captured ? L.T("Press Ctrl+Alt to release the mouse.") : null);
        hideHint = new DispatcherTimerLite(DispatcherQueue, TimeSpan.FromSeconds(4), () => hint.Visibility = Visibility.Collapsed);

        ctrlAltDel.Click += (_, _) => { session.Connection.CtrlAltDel(); display.Focus(FocusState.Programmatic); };
        fullScreen.Click += (_, _) => { window.ToggleFullScreen(); UpdateFullScreenLabel(); display.Focus(FocusState.Programmatic); };
        disconnect.Click += (_, _) => window.CloseConsole(session);
        reconnect.Click += async (_, _) =>
        {
            try { await session.ReconnectAsync(); }
            catch (Exception e) { await App.Model.PresentAsync(e); }
        };
        session.Changed += OnChanged;
        Loaded += (_, _) => { display.Connection = session.Connection; UpdateFullScreenLabel(); OnChanged(); display.Focus(FocusState.Programmatic); };
        Unloaded += (_, _) => display.Connection = null;
        hint.Visibility = Visibility.Collapsed;
    }

    private void UpdateFullScreenLabel() =>
        fullScreen.Content = window.IsFullScreen ? L.T("Exit Full Screen") : L.T("Full Screen");

    private SpiceConnection.ConnectionState? lastState;
    private SpiceConnection.MouseModes? lastMode;

    private void OnChanged()
    {
        var c = session.Connection;
        if (display.Connection != c && IsLoaded) display.Connection = c;
        connecting.Visibility = c.State == SpiceConnection.ConnectionState.Connecting ? Visibility.Visible : Visibility.Collapsed;
        disconnected.Visibility = c.State == SpiceConnection.ConnectionState.Disconnected ? Visibility.Visible : Visibility.Collapsed;
        display.Visibility = c.State == SpiceConnection.ConnectionState.Connected ? Visibility.Visible : Visibility.Collapsed;
        reason.Text = c.ErrorMessage ?? "";
        reason.Visibility = c.ErrorMessage is null ? Visibility.Collapsed : Visibility.Visible;
        ctrlAltDel.IsEnabled = c.State == SpiceConnection.ConnectionState.Connected;
        if (c.State == SpiceConnection.ConnectionState.Connected && (lastState != c.State || lastMode != c.MouseMode)
            && c.MouseMode == SpiceConnection.MouseModes.Server)
            ShowHint(L.T("Click inside the console to control the mouse."));
        lastState = c.State;
        lastMode = c.MouseMode;
    }

    private void ShowHint(string? text)
    {
        if (text is null) { hint.Visibility = Visibility.Collapsed; return; }
        hintText.Text = text;
        hint.Visibility = Visibility.Visible;
        hideHint.Restart();
    }
}
