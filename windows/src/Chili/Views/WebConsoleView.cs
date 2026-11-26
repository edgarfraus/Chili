using System.Security.Cryptography.X509Certificates;
using Chili.Core;
using Chili.Core.Proxmox;
using Chili.ViewModels;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.Web.WebView2.Core;

namespace Chili.Views;

/// <summary>Proxmox' noVNC / xterm.js console inside Chili (WebView2). Logged in with the session's
/// ticket cookie; Proxmox' self-signed certificate is accepted only when its fingerprint is the one
/// the user trusted for the API. With a Cloudflare Access service token the page goes through a
/// <see cref="WebConsoleProxy"/> on 127.0.0.1 that adds the token to every request, WebSocket included.</summary>
public sealed class WebConsoleView : UserControl
{
    private readonly WebConsoleSession session;
    private readonly MainWindow window;
    private WebView2? web;
    private readonly Grid stage = new();
    private readonly StackPanel failed = new() { Spacing = 12, HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center, MaxWidth = 480 };
    private readonly TextBlock reason = new() { TextWrapping = TextWrapping.Wrap, TextAlignment = TextAlignment.Center, IsTextSelectionEnabled = true };
    private readonly ProgressRing loading = new() { IsActive = true, HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center };
    private Uri? url;
    private WebConsoleProxy? proxy;
    /// <summary>The browser being set up: Loaded can fire again before that finishes.</summary>
    private Task<CoreWebView2>? creating;
    private bool started;

    public WebConsoleSession Session => session;
    /// <summary>For debug snapshots: the WebView2 renders outside the XAML tree.</summary>
    public WebView2? Web => web;

    public WebConsoleView(WebConsoleSession session, MainWindow window)
    {
        this.session = session;
        this.window = window;

        var grid = new Grid();
        grid.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        grid.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });

        var bar = new Grid { Padding = new Thickness(16, 8, 12, 8), ColumnSpacing = 8 };
        bar.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        bar.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        bar.Children.Add(new TextBlock
        {
            Text = session.Title, Style = (Style)Application.Current.Resources["BodyStrongTextBlockStyle"],
            VerticalAlignment = VerticalAlignment.Center, TextTrimming = TextTrimming.CharacterEllipsis,
        });
        var buttons = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
        var reload = new Button { Content = L.T("Reload") };
        var browser = new Button { Content = L.T("Open in Browser") };
        var disconnect = new Button { Content = L.T("Disconnect") };
        buttons.Children.Add(reload);
        buttons.Children.Add(browser);
        buttons.Children.Add(disconnect);
        Grid.SetColumn(buttons, 1);
        bar.Children.Add(buttons);
        grid.Children.Add(bar);

        var light = new SolidColorBrush(Microsoft.UI.Colors.White);
        reason.Foreground = light;
        failed.Children.Add(new TextBlock
        {
            Text = L.T("The console could not be opened"), Foreground = light, HorizontalAlignment = HorizontalAlignment.Center,
            Style = (Style)Application.Current.Resources["SubtitleTextBlockStyle"],
        });
        failed.Children.Add(reason);
        var retry = new Button { Content = L.T("Reload"), HorizontalAlignment = HorizontalAlignment.Center, Style = (Style)Application.Current.Resources["AccentButtonStyle"] };
        failed.Children.Add(retry);
        failed.Visibility = Visibility.Collapsed;
        stage.Background = new SolidColorBrush(Microsoft.UI.Colors.Black);
        stage.Children.Add(loading);
        stage.Children.Add(failed);
        Grid.SetRow(stage, 1);
        grid.Children.Add(stage);
        Content = grid;

        reload.Click += async (_, _) => await LoadAsync();
        retry.Click += async (_, _) => await LoadAsync();
        browser.Click += async (_, _) => { if (url is not null) await Windows.System.Launcher.LaunchUriAsync(url); };
        disconnect.Click += (_, _) => window.CloseConsole(session);
        session.Closed += Teardown;
        // Loaded fires again when the tab moves or is shown again: load once.
        Loaded += async (_, _) => { if (started) return; started = true; await LoadAsync(); };
    }

    private async Task LoadAsync()
    {
        failed.Visibility = Visibility.Collapsed;
        loading.Visibility = Visibility.Visible;
        session.SetState(ConsoleState.Connecting);
        try
        {
            var (target, cookie) = await session.PrepareAsync();
            url = target;
            var core = await EnsureWebViewAsync();
            var headers = ServerSession.AccessHeaders(session.Server.Profile);
            if (headers.Count > 0)
                proxy ??= new WebConsoleProxy(new Uri(target.GetLeftPart(UriPartial.Authority)), headers, session.Server.Api.AcceptsCertificate);
            var page = proxy?.Local(target) ?? target;
            var c = core.CookieManager.CreateCookie("PVEAuthCookie", cookie, page.Host.Trim('[', ']'), "/");
            c.IsSecure = true;
            core.CookieManager.AddOrUpdateCookie(c);
            core.Navigate(page.AbsoluteUri);
        }
        catch (Exception e)
        {
            if (creating is { IsFaulted: true }) creating = null;   // try again on Reload
            Fail(e.Message);
        }
    }

    private Task<CoreWebView2> EnsureWebViewAsync() => creating ??= CreateWebViewAsync();

    private async Task<CoreWebView2> CreateWebViewAsync()
    {
        // One profile folder per server keeps cookies (and an Access login) separate.
        var folder = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                                  "Chili", "WebView2", session.Server.Profile.Id.ToString("N"));
        var env = await CoreWebView2Environment.CreateWithOptionsAsync(null, folder, new CoreWebView2EnvironmentOptions());
        web = new WebView2 { Visibility = Visibility.Collapsed };
        stage.Children.Insert(0, web);
        await web.EnsureCoreWebView2Async(env);
        var core = web.CoreWebView2;
        core.Settings.AreDevToolsEnabled = false;
        core.Settings.IsStatusBarEnabled = false;

        var api = session.Server.Api;
        core.ServerCertificateErrorDetected += (_, e) =>
        {
            // Accept Proxmox' self-signed certificate only if it's the one pinned for the API
            // (or our own console proxy's).
            try
            {
                using var cert = X509Certificate2.CreateFromPem(e.ServerCertificate.ToPemEncoding());
                var fp = ProxmoxClient.Fingerprint(cert);
                e.Action = App.Model.Settings.IsTrusted(api.Host, api.Port, fp) || fp == proxy?.Fingerprint
                    ? CoreWebView2ServerCertificateErrorAction.AlwaysAllow
                    : CoreWebView2ServerCertificateErrorAction.Cancel;
            }
            catch { e.Action = CoreWebView2ServerCertificateErrorAction.Cancel; }
        };
        // Links that want a new window (help, Proxmox' own UI) open in the default browser.
        core.NewWindowRequested += async (_, e) =>
        {
            e.Handled = true;
            if (Uri.TryCreate(e.Uri, UriKind.Absolute, out var u)) await Windows.System.Launcher.LaunchUriAsync(u);
        };
        if (Services.Debug.Action is not null) await LogWebSocketsAsync(core);
        core.NavigationCompleted += (_, e) =>
        {
            if (e.IsSuccess)
            {
                loading.Visibility = Visibility.Collapsed;
                failed.Visibility = Visibility.Collapsed;
                web.Visibility = Visibility.Visible;
                session.SetState(ConsoleState.Connected);
            }
            else
            {
                Fail(L.F("The page could not be loaded (%@).", e.WebErrorStatus.ToString()));
            }
        };
        return core;
    }

    /// <summary>Debug only: logs the page's WebSockets (URL, handshake status, errors) through the
    /// DevTools protocol, to see what reaches Proxmox or Cloudflare.</summary>
    private static async Task LogWebSocketsAsync(CoreWebView2 core)
    {
        await core.CallDevToolsProtocolMethodAsync("Network.enable", "{}");
        void On(string name, Func<System.Text.Json.Nodes.JsonNode, string?> describe) =>
            core.GetDevToolsProtocolEventReceiver(name).DevToolsProtocolEventReceived += (_, e) =>
                Services.Debug.Log($"web: {name[8..]} {describe(System.Text.Json.Nodes.JsonNode.Parse(e.ParameterObjectAsJson)!)}");
        On("Network.webSocketCreated", j => (string?)j["url"] is { } u ? u.Split('?')[0] : null);
        On("Network.webSocketHandshakeResponseReceived", j => j["response"]?["status"]?.ToString());
        On("Network.webSocketFrameError", j => (string?)j["errorMessage"]);
    }

    private void Fail(string message)
    {
        loading.Visibility = Visibility.Collapsed;
        if (web is not null) web.Visibility = Visibility.Collapsed;
        reason.Text = message;
        failed.Visibility = Visibility.Visible;
        session.SetState(ConsoleState.Disconnected, message);
    }

    /// <summary>The console was closed: release the browser (and its WebSocket to Proxmox) now.</summary>
    private void Teardown()
    {
        session.Closed -= Teardown;
        proxy?.Dispose();
        proxy = null;
        creating = null;
        if (web is null) return;
        stage.Children.Remove(web);
        web.Close();
        web = null;
    }
}
