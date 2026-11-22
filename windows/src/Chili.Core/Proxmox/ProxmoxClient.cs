using System.Net;
using System.Net.Http.Headers;
using System.Net.Security;
using System.Security.Authentication;
using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace Chili.Core.Proxmox;

/// <summary>Certificate fingerprints the user explicitly accepted, per host:port.</summary>
public interface ITrustStore
{
    bool IsTrusted(string host, int port, string fingerprint);
}

/// <summary>Proxmox VE API client: just what Chili needs (see docs/windows/PLAN.md §3).</summary>
public sealed class ProxmoxClient : IDisposable
{
    private abstract record Auth;
    private sealed record TicketAuth(string Ticket, string Csrf) : Auth;
    private sealed record TokenAuth(string Id, string Secret) : Auth;

    public string Host { get; }
    public int Port { get; }

    private Auth? auth;
    private readonly HttpClient http;
    private readonly ITrustStore trust;
    private string? lastRejectedFingerprint;

    public ProxmoxClient(string host, int port, ITrustStore trust)
    {
        Host = NormalizedHost(host);
        Port = port;
        this.trust = trust;
        var handler = new SocketsHttpHandler
        {
            UseCookies = false,
            AutomaticDecompression = DecompressionMethods.All,
            SslOptions = new SslClientAuthenticationOptions { RemoteCertificateValidationCallback = ValidateCertificate },
        };
        http = new HttpClient(handler) { Timeout = TimeSpan.FromSeconds(20) };
    }

    public void Dispose() => http.Dispose();

    private Uri BaseUri()
    {
        if (Host.Length == 0 || !Uri.TryCreate($"https://{Host}:{Port}/", UriKind.Absolute, out var uri))
            throw new InvalidHostException(Host);
        return uri;
    }

    // MARK: Host parsing

    /// <summary>Accepts what people paste from the browser: "https://pve:8006/#v1:0:…" → "pve".
    /// IPv6 literals keep their brackets.</summary>
    public static string NormalizedHost(string input)
    {
        var h = StripSchemeAndPath(input);
        if (h.StartsWith('['))
        {
            int close = h.IndexOf(']');
            if (close >= 0) h = h[..(close + 1)];
        }
        else if (h.Count(c => c == ':') == 1)
        {
            h = h[..h.IndexOf(':')];
        }
        else if (h.Contains(':'))
        {
            h = $"[{h}]";   // bare IPv6 address
        }
        return h;
    }

    /// <summary>The port in a pasted URL ("https://pve:8443"), if any.</summary>
    public static int? PortIn(string input)
    {
        var h = StripSchemeAndPath(input);
        if (h.StartsWith('['))
        {
            int close = h.IndexOf(']');
            if (close < 0) return null;
            var rest = h[(close + 1)..];
            return rest.StartsWith(':') && int.TryParse(rest[1..], out var p1) ? p1 : null;
        }
        var parts = h.Split(':');
        return parts.Length == 2 && int.TryParse(parts[1], out var p) ? p : null;
    }

    private static string StripSchemeAndPath(string input)
    {
        var h = input.Trim();
        int scheme = h.IndexOf("://", StringComparison.Ordinal);
        if (scheme >= 0) h = h[(scheme + 3)..];
        int end = h.IndexOfAny(['/', '?', '#']);
        if (end >= 0) h = h[..end];
        return h;
    }

    // MARK: Authentication

    public Task<List<ProxmoxRealm>> RealmsAsync(CancellationToken ct = default) =>
        RequestAsync<List<ProxmoxRealm>>("GET", "/api2/json/access/domains", authenticated: false, ct: ct);

    /// <summary>Logs in with a password. Throws <see cref="NeedsTotpException"/> when the account
    /// has 2FA; call again with <paramref name="otp"/> set to complete the login.</summary>
    public async Task LoginAsync(string username, string password, string? otp = null)
    {
        var first = await RequestAsync<JsonObject>("POST", "/api2/json/access/ticket",
            new() { ["username"] = username, ["password"] = password, ["new-format"] = "1" }, authenticated: false);
        var ticket = (string?)first["ticket"] ?? throw new BadResponseException();
        if (IntValue(first["NeedTFA"]) != 1)
        {
            auth = new TicketAuth(ticket, (string?)first["CSRFPreventionToken"] ?? throw new BadResponseException());
            return;
        }
        if (string.IsNullOrWhiteSpace(otp)) throw new NeedsTotpException();
        var code = otp.Trim();
        // Recovery keys contain dashes; TOTP codes are digits only.
        var answer = code.Contains('-') ? $"recovery:{code}" : $"totp:{code}";
        var second = await RequestAsync<JsonObject>("POST", "/api2/json/access/ticket",
            new() { ["username"] = username, ["tfa-challenge"] = ticket, ["password"] = answer, ["new-format"] = "1" },
            authenticated: false);
        auth = new TicketAuth((string?)second["ticket"] ?? throw new BadResponseException(),
                              (string?)second["CSRFPreventionToken"] ?? throw new BadResponseException());
    }

    /// <summary>Uses an API token ("user@realm!tokenname" + secret) instead of a password.</summary>
    public async Task UseTokenAsync(string id, string secret)
    {
        auth = new TokenAuth(id, secret);
        await RequestAsync<JsonObject>("GET", "/api2/json/version");
    }

    public bool UsesTicket => auth is TicketAuth;

    /// <summary>Tickets are valid for two hours; an existing ticket can be traded for a new one.</summary>
    public async Task RenewTicketAsync(string username)
    {
        if (auth is TicketAuth t) await LoginAsync(username, t.Ticket);
    }

    // MARK: VMs and nodes

    public async Task<List<ProxmoxVM>> VirtualMachinesAsync()
    {
        var all = await RequestAsync<List<ProxmoxVM>>("GET", "/api2/json/cluster/resources?type=vm");
        return all.Where(v => (v.Type == "qemu" || v.Type == "lxc") && !v.IsTemplate).OrderBy(v => v.VmId).ToList();
    }

    public async Task<List<string>> NodesAsync()
    {
        var list = await RequestAsync<List<JsonObject>>("GET", "/api2/json/nodes");
        return list.Where(n => (string?)n["status"] != "offline").Select(n => (string?)n["node"] ?? "")
                   .Where(n => n.Length > 0).Order(StringComparer.Ordinal).ToList();
    }

    public async Task<int> NextVmIdAsync()
    {
        // Returned as a string ("102") by most versions, as a number by some.
        var data = await RequestAsync<JsonNode>("GET", "/api2/json/cluster/nextid");
        return IntValue(data) ?? throw new BadResponseException();
    }

    /// <summary>Storages of a node that accept <paramref name="content"/> (images, iso, rootdir, vztmpl).</summary>
    public async Task<List<Storage>> StoragesAsync(string node, string content)
    {
        var list = await RequestAsync<List<Storage>>("GET", $"/api2/json/nodes/{Seg(node)}/storage?content={content}&enabled=1");
        return list.Where(s => (s.Active ?? 1) == 1).OrderBy(s => s.Name, StringComparer.Ordinal).ToList();
    }

    public async Task<List<StorageItem>> IsoImagesAsync(string node, string storage) =>
        SortByFileName(await RequestAsync<List<StorageItem>>("GET",
            $"/api2/json/nodes/{Seg(node)}/storage/{Seg(storage)}/content?content=iso"));

    public async Task<List<NetworkInterface>> BridgesAsync(string node)
    {
        var list = await RequestAsync<List<NetworkInterface>>("GET", $"/api2/json/nodes/{Seg(node)}/network?type=any_bridge");
        return list.OrderBy(i => i.Iface, StringComparer.Ordinal).ToList();
    }

    public Task<NodeStatus> NodeStatusAsync(string node) =>
        RequestAsync<NodeStatus>("GET", $"/api2/json/nodes/{Seg(node)}/status");

    // MARK: Creating and managing VMs

    /// <summary>A VM's or container's configuration as strings (for display and checks).</summary>
    public async Task<Dictionary<string, string>> ConfigAsync(ProxmoxVM vm)
    {
        var config = await RequestAsync<JsonObject>("GET", $"{VmPath(vm)}/config");
        return config.ToDictionary(kv => kv.Key, kv => kv.Value is JsonValue v ? v.ToString() : kv.Value?.ToJsonString() ?? "");
    }

    /// <summary>Creates a QEMU VM; returns the task id (UPID).</summary>
    public Task<string> CreateVmAsync(string node, IReadOnlyDictionary<string, string> parameters) =>
        RequestAsync<string>("POST", $"/api2/json/nodes/{Seg(node)}/qemu", parameters);

    /// <summary>Creates an LXC container; returns the task id.</summary>
    public Task<string> CreateContainerAsync(string node, IReadOnlyDictionary<string, string> parameters) =>
        RequestAsync<string>("POST", $"/api2/json/nodes/{Seg(node)}/lxc", parameters);

    public Task<string> PowerAsync(ProxmoxVM vm, PowerAction action) =>
        RequestAsync<string>("POST", $"{VmPath(vm)}/status/{action.ToString().ToLowerInvariant()}",
                             new Dictionary<string, string>());

    /// <summary>Deletes a stopped VM or container together with its disks.</summary>
    public Task<string> DeleteAsync(ProxmoxVM vm) =>
        RequestAsync<string>("DELETE", $"{VmPath(vm)}?purge=1&destroy-unreferenced-disks=1");

    // MARK: Containers

    public async Task<List<StorageItem>> ContainerTemplatesAsync(string node, string storage) =>
        SortByFileName(await RequestAsync<List<StorageItem>>("GET",
            $"/api2/json/nodes/{Seg(node)}/storage/{Seg(storage)}/content?content=vztmpl"));

    /// <summary>Proxmox' catalogue of downloadable container templates.</summary>
    public async Task<List<Appliance>> AppliancesAsync(string node)
    {
        var list = await RequestAsync<List<Appliance>>("GET", $"/api2/json/nodes/{Seg(node)}/aplinfo");
        return list.Where(a => a.Section == "system").OrderBy(a => a.Template, StringComparer.Ordinal).ToList();
    }

    public Task<string> DownloadTemplateAsync(string node, string storage, string template) =>
        RequestAsync<string>("POST", $"/api2/json/nodes/{Seg(node)}/aplinfo",
                             new() { ["storage"] = storage, ["template"] = template });

    // MARK: Tasks and logs

    /// <summary>Proxmox' task history for one VM or container, newest first.</summary>
    public async Task<List<TaskEntry>> TasksAsync(ProxmoxVM vm, int limit = 100)
    {
        var list = await RequestAsync<List<TaskEntry>>("GET",
            $"/api2/json/nodes/{Seg(vm.Node)}/tasks?vmid={vm.VmId}&limit={limit}&source=all");
        return list.OrderByDescending(t => t.StartTime).ToList();
    }

    public async Task<List<string>> TaskLogAsync(string node, string upid, int limit = 5000)
    {
        var lines = await RequestAsync<List<JsonObject>>("GET",
            $"/api2/json/nodes/{Seg(node)}/tasks/{Seg(upid)}/log?limit={limit}");
        return lines.Select(l => (string?)l["t"] ?? "").ToList();
    }

    /// <summary>The latest entries of the node's system journal (newest last).
    /// (/syslog pages from the oldest entry; /journal?lastentries gives the tail.)</summary>
    public async Task<List<string>> JournalAsync(string node, int lines = 1000)
    {
        var list = await RequestAsync<List<string>>("GET", $"/api2/json/nodes/{Seg(node)}/journal?lastentries={lines}");
        return list.Where(l => !IsJournalMarker(l)).ToList();
    }

    /// <summary>journalctl's cursor lines ("s=…;i=…;b=…") and "-- …" markers.</summary>
    public static bool IsJournalMarker(string line) =>
        line.StartsWith("-- ", StringComparison.Ordinal)
        || (line.StartsWith("s=", StringComparison.Ordinal) && line.Contains(";i=") && line.Contains(";b="));

    /// <summary>Waits for a Proxmox task; throws with the task's last log lines if it failed.</summary>
    public async Task WaitForTaskAsync(string node, string upid, TimeSpan? timeout = null)
    {
        var limit = timeout ?? TimeSpan.FromMinutes(10);
        var started = DateTime.UtcNow;
        while (DateTime.UtcNow - started < limit)
        {
            var st = await RequestAsync<JsonObject>("GET", $"/api2/json/nodes/{Seg(node)}/tasks/{Seg(upid)}/status");
            if ((string?)st["status"] == "stopped")
            {
                var exit = (string?)st["exitstatus"];
                if (exit == "OK") return;
                List<string> log;
                try { log = await TaskLogAsync(node, upid, 500); } catch { log = []; }
                var tail = string.Join("\n", log.TakeLast(6));
                throw new HttpProxmoxException(0, string.Join("\n\n", new[] { exit ?? "", tail }.Where(s => s.Length > 0)));
            }
            await Task.Delay(700);
        }
        throw new HttpProxmoxException(0, L.T("The task is taking too long; check it in Proxmox."));
    }

    // MARK: Consoles

    /// <summary>Asks Proxmox for a one-time SPICE ticket (valid ~30 s, single use). The connection
    /// goes through the node's spiceproxy (TCP 3128) on the host we're talking to.</summary>
    public async Task<ViewerConfig> SpiceConfigAsync(ProxmoxVM vm)
    {
        try
        {
            var bytes = await RawAsync("POST", $"/api2/spiceconfig/nodes/{Seg(vm.Node)}/qemu/{vm.VmId}/spiceproxy",
                                       new Dictionary<string, string> { ["proxy"] = Host.Trim('[', ']') });
            var text = Encoding.UTF8.GetString(bytes);
            if (!text.Contains("[virt-viewer]")) throw new BadResponseException();
            return ViewerConfig.Parse(text);
        }
        catch (HttpProxmoxException e) when (e.Status >= 500)
        {
            // The reason is only in the HTTP status line; check the usual suspect ourselves.
            if (!await HasSpiceDisplayAsync(vm)) throw new NoSpiceException();
            throw;
        }
    }

    private async Task<bool> HasSpiceDisplayAsync(ProxmoxVM vm)
    {
        var config = await RequestAsync<JsonObject>("GET", $"/api2/json/nodes/{Seg(vm.Node)}/qemu/{vm.VmId}/config");
        return ((string?)config["vga"])?.StartsWith("qxl", StringComparison.Ordinal) ?? false;
    }

    /// <summary>The web UI URL that opens Proxmox's own console page (noVNC / xterm.js).</summary>
    public Uri WebConsoleUri(WebConsoleKind kind)
    {
        var q = kind switch
        {
            WebConsoleKind.Vm { Machine: var vm } when vm.IsContainer =>
                $"console=lxc&xtermjs=1&vmid={vm.VmId}&vmname={Seg(vm.Name ?? "")}&node={Seg(vm.Node)}",
            WebConsoleKind.Vm { Machine: var vm } =>
                $"console=kvm&novnc=1&vmid={vm.VmId}&vmname={Seg(vm.Name ?? "")}&node={Seg(vm.Node)}&resize=scale",
            WebConsoleKind.NodeShell { Node: var node } => $"console=shell&xtermjs=1&node={Seg(node)}",
            _ => throw new ArgumentOutOfRangeException(nameof(kind)),
        };
        return new Uri(BaseUri(), "/?" + q);
    }

    /// <summary>Value of the PVEAuthCookie that logs Proxmox' web console pages in. They need a
    /// password-based ticket: API tokens can't be used there (null then).</summary>
    public string? AuthCookieValue => auth is TicketAuth t ? Uri.EscapeDataString(t.Ticket) : null;

    // MARK: Plumbing

    private static string Seg(string s) => Uri.EscapeDataString(s);
    private static string VmPath(ProxmoxVM vm) => $"/api2/json/nodes/{Seg(vm.Node)}/{vm.Type}/{vm.VmId}";

    private static List<StorageItem> SortByFileName(List<StorageItem> list) =>
        list.OrderBy(i => i.FileName, StringComparer.CurrentCultureIgnoreCase).ToList();

    private static int? IntValue(JsonNode? node) => node switch
    {
        JsonValue v when v.TryGetValue<int>(out var i) => i,
        JsonValue v when v.TryGetValue<string>(out var s) && int.TryParse(s, out var j) => j,
        _ => null,
    };

    private static readonly JsonSerializerOptions Json = new() { NumberHandling = System.Text.Json.Serialization.JsonNumberHandling.AllowReadingFromString };

    private async Task<T> RequestAsync<T>(string method, string path, Dictionary<string, string>? form = null,
                                          bool authenticated = true, CancellationToken ct = default) =>
        await RequestAsync<T>(method, path, (IReadOnlyDictionary<string, string>?)form, authenticated, ct);

    private async Task<T> RequestAsync<T>(string method, string path, IReadOnlyDictionary<string, string>? form,
                                          bool authenticated = true, CancellationToken ct = default)
    {
        var bytes = await RawAsync(method, path, form, authenticated, ct);
        try
        {
            var root = JsonNode.Parse(bytes)?["data"];
            var value = root is null ? default : root.Deserialize<T>(Json);
            return value ?? throw new BadResponseException();
        }
        catch (JsonException) { throw new BadResponseException(); }
        catch (InvalidOperationException) { throw new BadResponseException(); }
    }

    /// <summary>Strict form encoding: Proxmox splits form fields on ';' as well as '&amp;', and VM
    /// options such as "boot=order=scsi0;ide2" are full of ';', '=' and ','. Only A–Z a–z 0–9 - . _ ~
    /// stay literal.</summary>
    public static string FormEncode(IEnumerable<KeyValuePair<string, string>> form) =>
        string.Join("&", form.Select(kv => Escape(kv.Key) + "=" + Escape(kv.Value)));

    private static string Escape(string s)
    {
        var sb = new StringBuilder();
        foreach (var b in Encoding.UTF8.GetBytes(s))
        {
            char c = (char)b;
            if (c is >= 'A' and <= 'Z' or >= 'a' and <= 'z' or >= '0' and <= '9' or '-' or '.' or '_' or '~') sb.Append(c);
            else sb.Append('%').Append(b.ToString("X2"));
        }
        return sb.ToString();
    }

    private async Task<byte[]> RawAsync(string method, string path, IReadOnlyDictionary<string, string>? form = null,
                                        bool authenticated = true, CancellationToken ct = default)
    {
        using var req = new HttpRequestMessage(new HttpMethod(method), new Uri(BaseUri(), path));
        if (form is not null)
            req.Content = new StringContent(FormEncode(form), Encoding.ASCII, "application/x-www-form-urlencoded");
        if (authenticated)
        {
            switch (auth)
            {
                case TicketAuth t:
                    req.Headers.TryAddWithoutValidation("Cookie", $"PVEAuthCookie={t.Ticket}");
                    if (method != "GET") req.Headers.TryAddWithoutValidation("CSRFPreventionToken", t.Csrf);
                    break;
                case TokenAuth t:
                    req.Headers.TryAddWithoutValidation("Authorization", $"PVEAPIToken={t.Id}={t.Secret}");
                    break;
            }
        }

        HttpResponseMessage res;
        try
        {
            lastRejectedFingerprint = null;
            res = await http.SendAsync(req, ct);
        }
        catch (HttpRequestException e) when (lastRejectedFingerprint is { } fp && e.InnerException is AuthenticationException)
        {
            throw new UntrustedCertificateException(Host, fp);
        }
        catch (HttpRequestException e)
        {
            throw new HttpProxmoxException(0, e.InnerException?.Message ?? e.Message);
        }
        catch (TaskCanceledException) when (!ct.IsCancellationRequested)
        {
            throw new HttpProxmoxException(0, L.F("%@ did not answer in time.", Host));
        }
        using (res)
        {
            var body = await res.Content.ReadAsByteArrayAsync(ct);
            if (!res.IsSuccessStatusCode)
                throw new HttpProxmoxException((int)res.StatusCode, ErrorMessage(res.ReasonPhrase, body));
            return body;
        }
    }

    /// <summary>"message" and, for "Parameter verification failed.", one line per parameter from
    /// "errors"; otherwise Proxmox' reason from the HTTP status line.</summary>
    public static string ErrorMessage(string? reasonPhrase, byte[] body)
    {
        try
        {
            if (JsonNode.Parse(body) is JsonObject obj)
            {
                var parts = new List<string>();
                if ((string?)obj["message"] is { } msg && msg.Trim().Length > 0) parts.Add(msg.Trim());
                if (obj["errors"] is JsonObject errors)
                    parts.AddRange(errors.OrderBy(e => e.Key, StringComparer.Ordinal)
                                         .Select(e => $"{e.Key}: {(e.Value is JsonValue v ? v.ToString() : e.Value?.ToJsonString())?.Trim()}"));
                if (parts.Count > 0) return string.Join("\n", parts);
            }
        }
        catch (JsonException) { }
        var text = Encoding.UTF8.GetString(body).Trim();
        if (text.Length > 0 && !text.StartsWith('{')) return text;
        return reasonPhrase?.Trim() ?? "";
    }

    // MARK: TLS — Proxmox ships a self-signed certificate, so we trust on first use

    private bool ValidateCertificate(object sender, X509Certificate? certificate, X509Chain? chain, SslPolicyErrors errors)
    {
        if (errors == SslPolicyErrors.None) return true;
        if (certificate is null) return false;
        var fp = Fingerprint(certificate);
        if (trust.IsTrusted(Host, Port, fp)) return true;
        lastRejectedFingerprint = fp;
        return false;
    }

    /// <summary>SHA-256 of the DER certificate, formatted AA:BB:…</summary>
    public static string Fingerprint(X509Certificate certificate) =>
        string.Join(":", SHA256.HashData(certificate.GetRawCertData()).Select(b => b.ToString("X2")));
}
