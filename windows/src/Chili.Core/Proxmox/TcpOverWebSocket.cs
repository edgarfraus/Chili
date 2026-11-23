using System.Net;
using System.Net.Sockets;
using System.Net.WebSockets;

namespace Chili.Core.Proxmox;

/// <summary>
/// Reaches Proxmox' spiceproxy (TCP 3128) through a Cloudflare Tunnel without any client software:
/// the tunnel publishes it as <c>service: tcp://localhost:3128</c> on its own hostname, and Cloudflare
/// carries such services as WebSocket streams over HTTPS (what <c>cloudflared access tcp</c> does).
/// This listens on 127.0.0.1, and pipes every accepted connection through its own WebSocket to
/// <c>wss://&lt;host&gt;/</c> in binary frames. SPICE then uses <c>proxy=http://127.0.0.1:&lt;port&gt;</c>.
/// </summary>
public sealed class TcpOverWebSocket : IDisposable
{
    private readonly Uri endpoint;
    private readonly TcpListener listener = new(IPAddress.Loopback, 0);
    private readonly CancellationTokenSource stop = new();
    private readonly IReadOnlyDictionary<string, string> headers;

    /// <summary>The local port SPICE should use as its HTTP proxy.</summary>
    public int Port { get; }
    /// <summary>The last failure to open the WebSocket, for diagnostics.</summary>
    public string? LastError { get; private set; }

    /// <param name="host">Hostname of the tunnel's TCP service, e.g. "spice.example.com" (or a wss:// URL).</param>
    /// <param name="headers">Extra request headers, e.g. a Cloudflare Access service token.</param>
    public TcpOverWebSocket(string host, IReadOnlyDictionary<string, string>? headers = null)
    {
        endpoint = EndpointFor(host);
        this.headers = headers ?? new Dictionary<string, string>();
        listener.Start();
        Port = ((IPEndPoint)listener.LocalEndpoint).Port;
        _ = AcceptLoopAsync();
    }

    /// <summary>"spice.example.com" → wss://spice.example.com/ (ws:// and wss:// URLs are kept).</summary>
    public static Uri EndpointFor(string host)
    {
        var h = host.Trim();
        if (h.StartsWith("https://", StringComparison.OrdinalIgnoreCase)) h = "wss://" + h[8..];
        else if (h.StartsWith("http://", StringComparison.OrdinalIgnoreCase)) h = "ws://" + h[7..];
        else if (!h.StartsWith("ws://", StringComparison.OrdinalIgnoreCase) && !h.StartsWith("wss://", StringComparison.OrdinalIgnoreCase))
            h = "wss://" + h;
        return new Uri(h);
    }

    private async Task AcceptLoopAsync()
    {
        while (!stop.IsCancellationRequested)
        {
            TcpClient client;
            try { client = await listener.AcceptTcpClientAsync(stop.Token); }
            catch { return; }
            _ = PipeAsync(client);
        }
    }

    private async Task PipeAsync(TcpClient client)
    {
        using var _ = client;
        client.NoDelay = true;
        using var ws = new ClientWebSocket();
        foreach (var (k, v) in headers) ws.Options.SetRequestHeader(k, v);
        ws.Options.KeepAliveInterval = TimeSpan.FromSeconds(20);
        try
        {
            using var timeout = CancellationTokenSource.CreateLinkedTokenSource(stop.Token);
            timeout.CancelAfter(TimeSpan.FromSeconds(15));
            await ws.ConnectAsync(endpoint, timeout.Token);
        }
        catch (Exception e)
        {
            LastError = e is WebSocketException { InnerException: { } inner } ? inner.Message : e.Message;
            return;   // closing the TCP connection makes SPICE report the failure
        }
        using var both = CancellationTokenSource.CreateLinkedTokenSource(stop.Token);
        var stream = client.GetStream();
        var up = Task.Run(async () =>
        {
            var buffer = new byte[64 * 1024];
            try
            {
                int n;
                while ((n = await stream.ReadAsync(buffer, both.Token)) > 0)
                    await ws.SendAsync(buffer.AsMemory(0, n), WebSocketMessageType.Binary, true, both.Token);
                await ws.CloseOutputAsync(WebSocketCloseStatus.NormalClosure, null, CancellationToken.None);
            }
            catch { }
        });
        var down = Task.Run(async () =>
        {
            var buffer = new byte[64 * 1024];
            try
            {
                while (true)
                {
                    var r = await ws.ReceiveAsync(buffer.AsMemory(), both.Token);
                    if (r.MessageType == WebSocketMessageType.Close) break;
                    await stream.WriteAsync(buffer.AsMemory(0, r.Count), both.Token);
                }
            }
            catch { }
        });
        await Task.WhenAny(up, down);
        both.Cancel();   // one side ended: end the other too
        await Task.WhenAll(up, down);
    }

    public void Dispose()
    {
        stop.Cancel();
        listener.Stop();
    }
}
