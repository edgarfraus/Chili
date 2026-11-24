using System.Globalization;
using System.Text;
using Chili.Core;
using Chili.Core.Proxmox;

namespace Chili.Core.Tests;

public class DraftTests
{
    /// <summary>The parameter set verified on a real Proxmox server (docs/windows/PLAN.md §3).</summary>
    [Fact]
    public void Windows11RecommendedWithDrivers()
    {
        var d = new VMDraft
        {
            Node = "pve01", VmId = 106, Name = "chili-test-win11", Os = VMDraft.OS.Win11,
            Iso = "local:iso/Win11.iso", VirtioIso = "local:iso/virtio-win.iso",
            DiskStorage = "local-lvm", DiskSizeGB = 64, Cores = 4, MemoryMiB = 8192, Bridge = "vmbr0",
        };
        d.ApplyChiliPreset();
        var expected = new Dictionary<string, string>
        {
            ["vmid"] = "106", ["name"] = "chili-test-win11", ["ostype"] = "win11", ["machine"] = "q35", ["bios"] = "ovmf",
            ["efidisk0"] = "local-lvm:1,efitype=4m,pre-enrolled-keys=1", ["tpmstate0"] = "local-lvm:1,version=v2.0",
            ["scsihw"] = "virtio-scsi-single", ["scsi0"] = "local-lvm:64,discard=on,iothread=1,ssd=1",
            ["ide2"] = "local:iso/Win11.iso,media=cdrom", ["ide0"] = "local:iso/virtio-win.iso,media=cdrom",
            ["sockets"] = "1", ["cores"] = "4", ["cpu"] = "x86-64-v2", ["memory"] = "8192",
            ["net0"] = "virtio,bridge=vmbr0,firewall=1", ["vga"] = "qxl",
            ["audio0"] = "device=ich9-intel-hda,driver=spice", ["agent"] = "enabled=1",
            ["boot"] = "order=scsi0;ide2;net0",
        };
        Assert.Equal(expected.OrderBy(k => k.Key), d.Parameters.OrderBy(k => k.Key));
        Assert.Empty(d.Problems);
    }

    [Fact]
    public void WindowsWithoutDriversUsesSataAndE1000e()
    {
        var d = new VMDraft { Os = VMDraft.OS.Win10, DiskStorage = "local-lvm", Bridge = "vmbr0", VlanTag = 20 };
        d.ApplyChiliPreset();
        var p = d.Parameters;
        Assert.Equal("local-lvm:32,discard=on,ssd=1", p["sata0"]);
        Assert.Equal("e1000e,bridge=vmbr0,firewall=1,tag=20", p["net0"]);
        Assert.Equal("order=sata0;ide2;net0", p["boot"]);
        Assert.False(p.ContainsKey("tpmstate0"));
        Assert.False(p.ContainsKey("ide0"));
    }

    [Fact]
    public void LinuxPreset()
    {
        var d = new VMDraft { Os = VMDraft.OS.Linux, DiskStorage = "local-lvm", Bridge = "vmbr0", RecommendedCpuType = "host" };
        d.ApplyChiliPreset();
        var p = d.Parameters;
        Assert.Equal("seabios", p["bios"]);
        Assert.Equal("host", p["cpu"]);
        Assert.Equal("local-lvm:32,discard=on,iothread=1", p["scsi0"]);
        Assert.Equal("none,media=cdrom", p["ide2"]);
        Assert.False(p.ContainsKey("efidisk0"));
    }

    [Fact]
    public void CustomDisplayDropsAudio()
    {
        var d = new VMDraft { DiskStorage = "s", Bridge = "b", DisplayType = VMDraft.Display.Std, Audio = true };
        Assert.Equal("std", d.Parameters["vga"]);
        Assert.False(d.Parameters.ContainsKey("audio0"));
        d.DisplayType = VMDraft.Display.Spice;
        d.Monitors = 3;
        Assert.Equal("qxl3", d.Parameters["vga"]);
    }

    [Theory]
    [InlineData("fpu cx16 lahf_lm popcnt sse4_1 sse4_2 ssse3 aes", "x86-64-v2")]
    [InlineData("fpu cx16 lahf_lm popcnt sse4_1 ssse3", "host")]
    [InlineData(null, "x86-64-v2")]
    public void CpuTypeFromFlags(string? flags, string expected) =>
        Assert.Equal(expected, VMDraft.CpuTypeForHostFlags(flags));

    [Fact]
    public void ValidationMessages()
    {
        var d = new VMDraft { VmId = 99, Name = "bad_name" };
        Assert.Equal(5, d.Problems.Count);
    }

    [Fact]
    public void ContainerParameters()
    {
        var c = new ContainerDraft
        {
            VmId = 106, Hostname = "chili-test-ct", Template = "local:vztmpl/alpine.tar.xz", Password = "secret",
            PasswordConfirm = "secret", MemoryMiB = 256, RootStorage = "local-lvm", RootSizeGB = 2, Bridge = "vmbr0",
            VlanTag = 5, Node = "pve01",
        };
        var p = c.Parameters("local:vztmpl/alpine.tar.xz");
        Assert.Equal("name=eth0,bridge=vmbr0,tag=5,ip=dhcp,ip6=auto,firewall=1", p["net0"]);
        Assert.Equal("local-lvm:2", p["rootfs"]);
        Assert.Equal("nesting=1", p["features"]);
        Assert.Equal("1", p["unprivileged"]);
        Assert.Empty(c.Problems);

        c.Ipv4 = ContainerDraft.IPv4.Static;
        c.Address = "192.168.1.50";
        c.Password = "abc";
        Assert.Equal(3, c.Problems.Count); // no prefix, too short, mismatch
        c.Address = "192.168.1.50/24";
        c.Gateway = "192.168.1.1";
        c.Ipv6 = ContainerDraft.IPv6.None;
        Assert.Equal("name=eth0,bridge=vmbr0,tag=5,ip=192.168.1.50/24,gw=192.168.1.1,firewall=1",
                     c.Parameters("x")["net0"]);
    }
}

public class ClientTests
{
    [Theory]
    [InlineData("https://pve:8006/#v1:0:18:4:::::", "pve", 8006)]
    [InlineData("  pve.example.com  ", "pve.example.com", null)]
    [InlineData("192.168.1.10:8443", "192.168.1.10", 8443)]
    [InlineData("https://[fd00::1]:8006/", "[fd00::1]", 8006)]
    [InlineData("fd00::1", "[fd00::1]", null)]
    [InlineData("[fd00::1]", "[fd00::1]", null)]
    public void HostNormalisation(string input, string host, int? port)
    {
        Assert.Equal(host, ProxmoxClient.NormalizedHost(input));
        Assert.Equal(port, ProxmoxClient.PortIn(input));
    }

    [Fact]
    public void FormEncodingIsStrict()
    {
        var body = ProxmoxClient.FormEncode([new("boot", "order=scsi0;ide2;net0"), new("name", "a b&c~é")]);
        Assert.Equal("boot=order%3Dscsi0%3Bide2%3Bnet0&name=a%20b%26c~%C3%A9", body);
    }

    [Fact]
    public void ErrorMessageCombinesMessageAndErrors()
    {
        var body = Encoding.UTF8.GetBytes("""{"message":"Parameter verification failed.\n","errors":{"net0":"invalid format","boot":"bad"},"data":null}""");
        Assert.Equal("Parameter verification failed.\nboot: bad\nnet0: invalid format", ProxmoxClient.ErrorMessage("x", body));
        Assert.Equal("proxy not allowed", ProxmoxClient.ErrorMessage("proxy not allowed", []));
        Assert.Equal("proxy not allowed", ProxmoxClient.ErrorMessage("proxy not allowed", Encoding.UTF8.GetBytes("""{"data":null}""")));
    }

    [Fact]
    public void JournalMarkers()
    {
        Assert.True(ProxmoxClient.IsJournalMarker("s=abc;i=12;b=ff;m=1;t=2;x=3"));
        Assert.True(ProxmoxClient.IsJournalMarker("-- No entries --"));
        Assert.False(ProxmoxClient.IsJournalMarker("Nov 22 10:00:00 pve01 systemd[1]: Started x."));
    }

    [Fact]
    public void WebConsoleUris()
    {
        using var c = new ProxmoxClient("pve", 8006, new NoTrust());
        var vm = new ProxmoxVM { VmId = 101, Name = "web server", Node = "pve01", Type = "qemu" };
        Assert.Equal("https://pve:8006/?console=kvm&novnc=1&vmid=101&vmname=web%20server&node=pve01&resize=scale",
                     c.WebConsoleUri(new WebConsoleKind.Vm(vm)).AbsoluteUri);
        Assert.Equal("https://pve:8006/?console=shell&xtermjs=1&node=pve01",
                     c.WebConsoleUri(new WebConsoleKind.NodeShell("pve01")).AbsoluteUri);
    }

    private sealed class NoTrust : ITrustStore
    {
        public bool IsTrusted(string host, int port, string fingerprint) => false;
    }
}

public class ViewerConfigTests
{
    [Fact]
    public void ParsesProxmoxVvFile()
    {
        var text = "[virt-viewer]\r\nsecure-attention=ctrl+alt+ins\r\ntype=spice\r\nhost=pvespiceproxy:abc:101:pve01::xyz\r\n" +
                   "tls-port=61000\r\npassword=s3cr=t\r\nproxy=http://pve:3128\r\nca=-----BEGIN CERTIFICATE-----\\nMIIF\\n-----END CERTIFICATE-----\\n\r\n" +
                   "delete-this-file=1\r\n";
        var c = ViewerConfig.Parse(text);
        Assert.Equal("s3cr=t", c["password"]);
        Assert.Equal("http://pve:3128", c["proxy"]);
        Assert.StartsWith("-----BEGIN CERTIFICATE-----\\n", c["ca"]);
        c["title"] = "VM";
        c["password"] = null;
        Assert.Equal("[virt-viewer]\nsecure-attention=ctrl+alt+ins\ntype=spice\nhost=pvespiceproxy:abc:101:pve01::xyz\n" +
                     "tls-port=61000\nproxy=http://pve:3128\nca=-----BEGIN CERTIFICATE-----\\nMIIF\\n-----END CERTIFICATE-----\\n\n" +
                     "delete-this-file=1\ntitle=VM\n", c.VvText);
    }
}

[Collection("Localization")]   // L is global: don't switch languages in parallel
public class LocalizationTests
{
    [Fact]
    public void ParsesStringsFiles()
    {
        var pairs = L.ParseStrings("/* c */\n\"A \\\"b\\\"\" = \"x\\ny\";\n// line\n\"%@ of %d\" = \"%@ di %d\";").ToList();
        Assert.Equal([("A \"b\"", "x\ny"), ("%@ of %d", "%@ di %d")], pairs);
    }

    [Fact]
    public void FormatsPlaceholders() =>
        Assert.Equal("3 vCPU on pve, 100%", L.Format("%d vCPU on %@, 100%%", 3, "pve"));

    [Fact]
    public void ItalianTableLoads()
    {
        try
        {
            L.Use(new CultureInfo("it-IT"));
            Assert.Equal("Connessione rapida", L.T("Quick Connect"));
            Assert.Equal("Connessione a pve…", L.F("Connecting to %@…", "pve"));
            Assert.Equal("%@ non ha risposto in tempo.", L.T("%@ did not answer in time."));
        }
        finally { L.Use(CultureInfo.InvariantCulture); }
    }
}

[Collection("Localization")]
public class TranslationCoverageTests
{
    /// <summary>Every L.T / L.F literal in the Windows sources has an Italian entry
    /// (launcher/Resources/it.lproj or Strings/it.windows.strings).</summary>
    [Fact]
    public void AllAppStringsAreTranslated()
    {
        var src = Path.GetFullPath(Path.Combine(AppContext.BaseDirectory, "..", "..", "..", "..", "..", "src"));
        var literal = new System.Text.RegularExpressions.Regex("""L\.[TF]\("((?:[^"\\]|\\.)*)"[,)]""");
        var missing = new SortedSet<string>();
        try
        {
            L.Use(new CultureInfo("it-IT"));
            foreach (var file in Directory.EnumerateFiles(src, "*.cs", SearchOption.AllDirectories))
                foreach (System.Text.RegularExpressions.Match m in literal.Matches(File.ReadAllText(file)))
                {
                    var key = m.Groups[1].Value.Replace("\\n", "\n").Replace("\\\"", "\"").Replace("\\\\", "\\");
                    if (!L.IsTranslated(key)) missing.Add(key);
                }
        }
        finally { L.Use(CultureInfo.InvariantCulture); }
        Assert.True(missing.Count == 0, "Missing Italian strings:\n" + string.Join("\n", missing));
    }
}

public class LaunchArgumentTests
{
    [Fact]
    public void SpiceUris()
    {
        var c = LaunchArguments.ParseSpiceUri("spice://192.168.1.10:5901?password=s%20e")!;
        Assert.Equal("192.168.1.10", c["host"]);
        Assert.Equal("5901", c["port"]);
        Assert.Equal("s e", c["password"]);
        var t = LaunchArguments.ParseSpiceUri("spice+tls://pve:61000")!;
        Assert.Equal("61000", t["tls-port"]);
        Assert.Null(t["port"]);
        Assert.Equal("5900", LaunchArguments.ParseSpiceUri("spice://host")!["port"]);
        Assert.Null(LaunchArguments.ParseSpiceUri("https://pve:8006"));
    }

    [Fact]
    public void CommandLines()
    {
        var args = LaunchArguments.Split(@"""C:\Program Files\Chili\Chili.exe"" ""C:\Users\me\Downloads\pve-spice (1).vv""");
        Assert.Equal([@"C:\Program Files\Chili\Chili.exe", @"C:\Users\me\Downloads\pve-spice (1).vv"], args);
        Assert.Equal(@"C:\Users\me\Downloads\pve-spice (1).vv", LaunchArguments.Target(args.Skip(1)));
        Assert.Equal("spice://h:1", LaunchArguments.Target(LaunchArguments.Split("Chili.exe spice://h:1")));
    }
}

public class TcpOverWebSocketTests
{
    [Theory]
    [InlineData("spice.example.com", "wss://spice.example.com/")]
    [InlineData(" https://spice.example.com ", "wss://spice.example.com/")]
    [InlineData("ws://localhost:8080/x", "ws://localhost:8080/x")]
    public void Endpoints(string host, string expected) =>
        Assert.Equal(expected, TcpOverWebSocket.EndpointFor(host).AbsoluteUri);

    /// <summary>TCP bytes go out as binary WebSocket frames and come back, for several
    /// connections at once (SPICE opens one per channel).</summary>
    [Fact]
    public async Task PipesTcpThroughWebSocket()
    {
        int port = FreePort();
        using var http = new System.Net.HttpListener();
        http.Prefixes.Add($"http://localhost:{port}/");
        http.Start();
        _ = Task.Run(async () =>
        {
            while (http.IsListening)
            {
                System.Net.HttpListenerContext ctx;
                try { ctx = await http.GetContextAsync(); } catch { return; }
                _ = Task.Run(async () =>
                {
                    var ws = (await ctx.AcceptWebSocketAsync(null)).WebSocket;
                    var buf = new byte[4096];
                    while (true)
                    {
                        var r = await ws.ReceiveAsync(buf, default);
                        if (r.MessageType == System.Net.WebSockets.WebSocketMessageType.Close) break;
                        Assert.Equal(System.Net.WebSockets.WebSocketMessageType.Binary, r.MessageType);
                        await ws.SendAsync(buf.AsMemory(0, r.Count), System.Net.WebSockets.WebSocketMessageType.Binary, true, default);
                    }
                    await ws.CloseAsync(System.Net.WebSockets.WebSocketCloseStatus.NormalClosure, null, default);
                });
            }
        });

        using var tunnel = new TcpOverWebSocket($"ws://localhost:{port}/");
        async Task<string> RoundTrip(string text)
        {
            using var tcp = new System.Net.Sockets.TcpClient();
            await tcp.ConnectAsync(System.Net.IPAddress.Loopback, tunnel.Port);
            var s = tcp.GetStream();
            var data = Encoding.UTF8.GetBytes(text);
            await s.WriteAsync(data);
            var back = new byte[data.Length];
            int got = 0;
            using var cts = new CancellationTokenSource(TimeSpan.FromSeconds(10));
            while (got < back.Length) got += await s.ReadAsync(back.AsMemory(got), cts.Token);
            return Encoding.UTF8.GetString(back);
        }
        var results = await Task.WhenAll(Enumerable.Range(0, 4).Select(i => RoundTrip($"CONNECT channel {i}\r\n\r\n")));
        Assert.Equal(Enumerable.Range(0, 4).Select(i => $"CONNECT channel {i}\r\n\r\n"), results);
        Assert.Null(tunnel.LastError);
    }

    [Fact]
    public async Task ReportsUnreachableHost()
    {
        using var tunnel = new TcpOverWebSocket($"ws://localhost:{FreePort()}/");
        using var tcp = new System.Net.Sockets.TcpClient();
        await tcp.ConnectAsync(System.Net.IPAddress.Loopback, tunnel.Port);
        var n = await tcp.GetStream().ReadAsync(new byte[1]);   // closed once the WebSocket fails
        Assert.Equal(0, n);
        Assert.NotNull(tunnel.LastError);
    }

    private static int FreePort()
    {
        var l = new System.Net.Sockets.TcpListener(System.Net.IPAddress.Loopback, 0);
        l.Start();
        int p = ((System.Net.IPEndPoint)l.LocalEndpoint).Port;
        l.Stop();
        return p;
    }
}

public class UpdateTests
{
    private static System.Text.Json.Nodes.JsonArray Releases() => System.Text.Json.Nodes.JsonNode.Parse("""
        [
          {"tag_name":"v1.1.0","draft":false,"prerelease":false,"html_url":"https://x/1.1.0","body":"new",
           "assets":[{"name":"Chili-1.1.0-x64-setup.exe","browser_download_url":"https://x/s110.exe"},
                     {"name":"Chili-1.1.0-x64-setup.exe.sha256","browser_download_url":"https://x/s110.sha"}]},
          {"tag_name":"v1.2.0","draft":false,"prerelease":true,
           "assets":[{"name":"Chili-1.2.0-x64-setup.exe","browser_download_url":"https://x/s120.exe"}]},
          {"tag_name":"v1.3.0","draft":true,"prerelease":false,
           "assets":[{"name":"Chili-1.3.0-x64-setup.exe","browser_download_url":"https://x/s130.exe"}]},
          {"tag_name":"v2.0.0","draft":false,"prerelease":false,
           "assets":[{"name":"Chili-2.0.0-arm64.dmg","browser_download_url":"https://x/mac.dmg"}]},
          {"tag_name":"v1.0.1","draft":false,"prerelease":false,
           "assets":[{"name":"Chili-1.0.1-x64-setup.exe","browser_download_url":"https://x/s101.exe"}]},
          {"tag_name":"windows-v9.0.0","draft":false,"prerelease":false,
           "assets":[{"name":"Chili-9.0.0-x64-setup.exe","browser_download_url":"https://x/old.exe"}]}
        ]
        """)!.AsArray();

    [Fact]
    public void PicksNewestReleaseWithAWindowsSetup()
    {
        var r = Updates.Newest(Releases(), new Version(1, 0, 0), "x64")!;
        Assert.Equal(new Version(1, 1, 0, 0), r.Version);
        Assert.Equal("https://x/s110.exe", r.SetupUrl);
        Assert.Equal("https://x/s110.sha", r.Sha256Url);
        Assert.Null(Updates.Newest(Releases(), new Version(1, 1, 0, 0), "x64"));
        Assert.Null(Updates.Newest(Releases(), new Version(1, 0, 0), "arm64"));   // no arm64 setup
    }

    [Theory]
    [InlineData("v1.0.1", "1.0.1.0")]
    [InlineData("v2.1", "2.1.0.0")]
    [InlineData("v1.0.0-beta", null)]
    [InlineData("windows-v1.0.4", null)]   // the Windows-only releases before 1.1.0
    public void Tags(string tag, string? version) =>
        Assert.Equal(version, Updates.ParseTag(tag)?.ToString());

    [Fact]
    public void Sha256Files() =>
        Assert.Equal("abc123", Updates.ParseSha256("abc123  Chili-1.0.1-x64-setup.exe"));
}

public class CloudflareAccessTests
{
    /// <summary>A local stand-in for a hostname behind Cloudflare Access.</summary>
    private static async Task<(T Result, List<System.Collections.Specialized.NameValueCollection> Requests)> WithServer<T>(
        Action<System.Net.HttpListenerContext> respond, Func<ProxmoxClient, Task<T>> run)
    {
        var l = new System.Net.Sockets.TcpListener(System.Net.IPAddress.Loopback, 0);
        l.Start();
        int port = ((System.Net.IPEndPoint)l.LocalEndpoint).Port;
        l.Stop();
        using var http = new System.Net.HttpListener();
        http.Prefixes.Add($"http://localhost:{port}/");
        http.Start();
        var requests = new List<System.Collections.Specialized.NameValueCollection>();
        _ = Task.Run(async () =>
        {
            while (http.IsListening)
            {
                System.Net.HttpListenerContext ctx;
                try { ctx = await http.GetContextAsync(); } catch { return; }
                lock (requests) requests.Add(ctx.Request.Headers);
                respond(ctx);
                ctx.Response.Close();
            }
        });
        using var client = new ProxmoxClient("localhost", port, new NoTrust()) { Scheme = "http" };
        client.ExtraHeaders["CF-Access-Client-Id"] = "id.access";
        client.ExtraHeaders["CF-Access-Client-Secret"] = "s3cret";
        return (await run(client), requests);
    }

    private static void Html(System.Net.HttpListenerContext ctx, int status, string body)
    {
        ctx.Response.StatusCode = status;
        ctx.Response.ContentType = "text/html; charset=utf-8";
        var b = Encoding.UTF8.GetBytes(body);
        ctx.Response.OutputStream.Write(b);
    }

    [Fact]
    public async Task AccessPageBecomesAClearError()
    {
        var (error, requests) = await WithServer(
            ctx => Html(ctx, 403, "<!doctype html><style>.base_AccessLogo .logo-light{display:none}</style>"),
            async c => await Record.ExceptionAsync(() => c.RealmsAsync()));
        Assert.IsType<CloudflareAccessException>(error);
        Assert.True(((CloudflareAccessException)error!).TokenSent);
        Assert.Equal("id.access", requests[0]["CF-Access-Client-Id"]);
        Assert.Equal("s3cret", requests[0]["CF-Access-Client-Secret"]);
    }

    [Fact]
    public async Task RedirectToAccessLoginIsRecognised()
    {
        var (error, _) = await WithServer(ctx =>
        {
            ctx.Response.StatusCode = 302;
            ctx.Response.RedirectLocation = "https://team.cloudflareaccess.com/cdn-cgi/access/login/pve.example.com";
        }, async c => await Record.ExceptionAsync(() => c.RealmsAsync()));
        Assert.IsType<CloudflareAccessException>(error);
    }

    [Fact]
    public async Task OtherWebPagesAreReportedAsSuch()
    {
        var (error, _) = await WithServer(ctx => Html(ctx, 200, "<html><body>Router login</body></html>"),
                                          async c => await Record.ExceptionAsync(() => c.RealmsAsync()));
        var e = Assert.IsType<HttpProxmoxException>(error);
        Assert.Contains("web page", e.Message);
    }

    [Fact]
    public async Task JsonStillWorks()
    {
        var (realms, _) = await WithServer(ctx =>
        {
            ctx.Response.ContentType = "application/json;charset=UTF-8";
            ctx.Response.OutputStream.Write(Encoding.UTF8.GetBytes("""{"data":[{"realm":"pam","comment":"Linux PAM"}]}"""));
        }, c => c.RealmsAsync());
        Assert.Equal("pam", Assert.Single(realms).Realm);
    }

    private sealed class NoTrust : ITrustStore
    {
        public bool IsTrusted(string host, int port, string fingerprint) => false;
    }
}
