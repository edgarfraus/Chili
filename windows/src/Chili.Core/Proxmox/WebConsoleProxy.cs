using System.Net;
using System.Net.Security;
using System.Net.Sockets;
using System.Security.Authentication;
using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;
using System.Text;

namespace Chili.Core.Proxmox;

/// <summary>
/// Puts Proxmox' web consoles (noVNC, xterm.js) behind Cloudflare Access with a service token.
/// WebView2 can add headers to the page's requests but not to its WebSocket, and Access doesn't
/// answer a service token with a cookie, so the console's WebSocket got a 403 ("Failed to connect
/// to server"). This HTTPS proxy on 127.0.0.1 forwards every request, WebSocket upgrades included,
/// to the Proxmox host with the extra headers. One request per connection (it asks for
/// <c>Connection: close</c>), so it never has to parse a body. Its certificate is a throwaway
/// self-signed one: the browser accepts it by <see cref="Fingerprint"/>.
/// </summary>
public sealed class WebConsoleProxy : IDisposable
{
    private readonly Uri upstream;
    private readonly IReadOnlyDictionary<string, string> headers;
    private readonly RemoteCertificateValidationCallback validate;
    private readonly TcpListener listener = new(IPAddress.Loopback, 0);
    private readonly CancellationTokenSource stop = new();
    private readonly X509Certificate2 certificate;

    public int Port { get; }
    /// <summary>SHA-256 fingerprint (AA:BB:…) of the proxy's own certificate.</summary>
    public string Fingerprint { get; }
    /// <summary>The last failure to reach the Proxmox host, for diagnostics.</summary>
    public string? LastError { get; private set; }

    /// <param name="upstream">The Proxmox web UI, e.g. https://pve.example.com/ (http:// in tests).</param>
    /// <param name="headers">Added to every request, e.g. CF-Access-Client-Id / CF-Access-Client-Secret.</param>
    /// <param name="validate">Checks the Proxmox host's certificate (the API's rule: valid or pinned).</param>
    public WebConsoleProxy(Uri upstream, IReadOnlyDictionary<string, string> headers, RemoteCertificateValidationCallback validate)
    {
        this.upstream = upstream;
        this.headers = headers;
        this.validate = validate;
        certificate = MakeCertificate();
        Fingerprint = ProxmoxClient.Fingerprint(certificate);
        listener.Start();
        Port = ((IPEndPoint)listener.LocalEndpoint).Port;
        _ = AcceptLoopAsync();
    }

    /// <summary>The same page, through the proxy.</summary>
    public Uri Local(Uri remote) => new UriBuilder(remote) { Scheme = "https", Host = "127.0.0.1", Port = Port }.Uri;

    private string Authority => upstream.IsDefaultPort ? upstream.Host : $"{upstream.Host}:{upstream.Port}";
    private string Origin => $"{upstream.Scheme}://{Authority}";

    private static X509Certificate2 MakeCertificate()
    {
        using var key = ECDsa.Create(ECCurve.NamedCurves.nistP256);
        var request = new CertificateRequest("CN=Chili console proxy", key, HashAlgorithmName.SHA256);
        var san = new SubjectAlternativeNameBuilder();
        san.AddIpAddress(IPAddress.Loopback);
        san.AddDnsName("localhost");
        request.CertificateExtensions.Add(san.Build());
        request.CertificateExtensions.Add(new X509EnhancedKeyUsageExtension([new Oid("1.3.6.1.5.5.7.3.1")], false));
        using var cert = request.CreateSelfSigned(DateTimeOffset.UtcNow.AddDays(-1), DateTimeOffset.UtcNow.AddDays(30));
        // Through PKCS#12: SChannel can't use the ephemeral key of a freshly made certificate.
        return X509CertificateLoader.LoadPkcs12(cert.Export(X509ContentType.Pkcs12), null);
    }

    private async Task AcceptLoopAsync()
    {
        while (!stop.IsCancellationRequested)
        {
            TcpClient client;
            try { client = await listener.AcceptTcpClientAsync(stop.Token); }
            catch { return; }
            _ = HandleAsync(client);
        }
    }

    private async Task HandleAsync(TcpClient client)
    {
        using var owned = client;
        using var connection = CancellationTokenSource.CreateLinkedTokenSource(stop.Token);
        try
        {
            await using var local = new SslStream(client.GetStream());
            using (var handshake = CancellationTokenSource.CreateLinkedTokenSource(stop.Token))
            {
                handshake.CancelAfter(TimeSpan.FromSeconds(15));
                await local.AuthenticateAsServerAsync(new SslServerAuthenticationOptions { ServerCertificate = certificate }, handshake.Token);
            }
            if (await ReadHeadAsync(local, connection.Token) is not var (head, rest)) return;
            var (request, upgrade) = RewriteRequest(head);

            using var tcp = new TcpClient();
            Stream remote;
            try
            {
                await tcp.ConnectAsync(upstream.Host, upstream.Port, connection.Token);
                remote = tcp.GetStream();
                if (upstream.Scheme == Uri.UriSchemeHttps)
                {
                    var ssl = new SslStream(remote);
                    await ssl.AuthenticateAsClientAsync(new SslClientAuthenticationOptions
                    {
                        TargetHost = upstream.IdnHost, RemoteCertificateValidationCallback = validate,
                    }, connection.Token);
                    remote = ssl;
                }
            }
            catch (Exception e)
            {
                LastError = e.Message;
                await local.WriteAsync(Encoding.ASCII.GetBytes("HTTP/1.1 502 Bad Gateway\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"), connection.Token);
                return;
            }
            await using var remoteOwned = remote;
            await remote.WriteAsync(request, connection.Token);
            await remote.WriteAsync(rest, connection.Token);

            // Request body (or WebSocket frames) up; the response head, then the rest, down.
            var up = local.CopyToAsync(remote, connection.Token);
            var down = Task.Run(async () =>
            {
                if (await ReadHeadAsync(remote, connection.Token) is not var (responseHead, more)) return;
                await local.WriteAsync(RewriteResponse(responseHead, upgrade), connection.Token);
                await local.WriteAsync(more, connection.Token);
                await remote.CopyToAsync(local, connection.Token);
            });
            await Task.WhenAny(up, down);
        }
        catch (Exception e) when (e is IOException or SocketException or OperationCanceledException or AuthenticationException or ObjectDisposedException) { }
        finally { connection.Cancel(); }
    }

    /// <summary>Reads up to the blank line that ends an HTTP head; returns the head's text and any
    /// bytes read past it, or null if the stream ended (or the head is absurdly long).</summary>
    private static async Task<(string Head, byte[] Tail)?> ReadHeadAsync(Stream stream, CancellationToken token)
    {
        var buffer = new byte[16384];
        var data = new MemoryStream();
        while (data.Length < 65536)
        {
            int n = await stream.ReadAsync(buffer, token);
            if (n == 0) return null;
            data.Write(buffer, 0, n);
            var bytes = data.GetBuffer().AsSpan(0, (int)data.Length);
            int end = bytes.IndexOf("\r\n\r\n"u8);
            if (end >= 0)
                return (Encoding.Latin1.GetString(bytes[..end]), bytes[(end + 4)..].ToArray());
        }
        return null;
    }

    /// <summary>Host, Origin and Referer point at the Proxmox host; the extra headers are added;
    /// keep-alive is turned off (upgrades keep their Connection: Upgrade).</summary>
    internal (byte[] Head, bool Upgrade) RewriteRequest(string head)
    {
        var lines = head.Split("\r\n");
        var fields = lines.Skip(1).Select(Split).Where(f => f.Name.Length > 0).ToList();
        bool upgrade = fields.Any(f => f.Name.Equals("Upgrade", StringComparison.OrdinalIgnoreCase))
                       && fields.Any(f => f.Name.Equals("Connection", StringComparison.OrdinalIgnoreCase)
                                          && f.Value.Contains("upgrade", StringComparison.OrdinalIgnoreCase));
        var dropped = new HashSet<string>(["Host", "Connection", "Keep-Alive", "Proxy-Connection", .. headers.Keys], StringComparer.OrdinalIgnoreCase);
        var output = new StringBuilder(lines[0]).Append("\r\n");
        output.Append("Host: ").Append(Authority).Append("\r\n");
        foreach (var (name, value) in fields)
        {
            if (dropped.Contains(name)) continue;
            var v = value;
            if (name.Equals("Origin", StringComparison.OrdinalIgnoreCase)) v = Origin;
            else if (name.Equals("Referer", StringComparison.OrdinalIgnoreCase) && Uri.TryCreate(value, UriKind.Absolute, out var r))
                v = Origin + r.PathAndQuery;
            output.Append(name).Append(": ").Append(v).Append("\r\n");
        }
        output.Append("Connection: ").Append(upgrade ? "Upgrade" : "close").Append("\r\n");
        foreach (var (name, value) in headers) output.Append(name).Append(": ").Append(value).Append("\r\n");
        output.Append("\r\n");
        return (Encoding.Latin1.GetBytes(output.ToString()), upgrade);
    }

    /// <summary>Tells the browser not to reuse the connection (one request each), except for a
    /// switch to WebSocket.</summary>
    internal static byte[] RewriteResponse(string head, bool upgrade)
    {
        var lines = head.Split("\r\n");
        bool switching = upgrade && lines[0].Split(' ') is [_, "101", ..];
        var output = new StringBuilder(lines[0]).Append("\r\n");
        foreach (var line in lines.Skip(1))
        {
            var (name, _) = Split(line);
            if (!switching && (name.Equals("Connection", StringComparison.OrdinalIgnoreCase) || name.Equals("Keep-Alive", StringComparison.OrdinalIgnoreCase)))
                continue;
            output.Append(line).Append("\r\n");
        }
        if (!switching) output.Append("Connection: close\r\n");
        output.Append("\r\n");
        return Encoding.Latin1.GetBytes(output.ToString());
    }

    private static (string Name, string Value) Split(string line)
    {
        int colon = line.IndexOf(':');
        return colon <= 0 ? ("", "") : (line[..colon].Trim(), line[(colon + 1)..].Trim());
    }

    public void Dispose()
    {
        stop.Cancel();
        listener.Stop();
        certificate.Dispose();
    }
}
