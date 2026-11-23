using System.Text.Json;
using System.Text.Json.Serialization;
using Chili.Core.Proxmox;

namespace Chili.Services;

/// <summary>A saved Proxmox server. Secrets live in Credential Manager, never in settings.json.</summary>
public sealed record ServerProfile
{
    public enum AuthMethod { Password, Token }

    public Guid Id { get; init; } = Guid.NewGuid();
    public string Name { get; init; } = "";
    public string Host { get; init; } = "";
    public int Port { get; init; } = 8006;
    [JsonConverter(typeof(JsonStringEnumConverter<AuthMethod>))]
    public AuthMethod Auth { get; init; } = AuthMethod.Password;
    public string Username { get; init; } = "root";
    public string Realm { get; init; } = "pam";
    public string TokenId { get; init; } = "";      // "user@realm!name"
    public bool RememberSecret { get; init; } = true;
    /// <summary>Hostname of a Cloudflare Tunnel TCP service for spiceproxy (port 3128), when the
    /// server is only reachable through the tunnel. Empty: SPICE goes to Host:3128 directly.</summary>
    public string SpiceTunnelHost { get; init; } = "";

    [JsonIgnore] public string Title => Name.Length == 0 ? Host : Name;
    [JsonIgnore] public string FullUsername => Username.Contains('@') ? Username : $"{Username}@{Realm}";
}

public sealed class Preferences
{
    public string ConsolePlacement { get; set; } = "main";    // "main" or "window"
    public bool Fullscreen { get; set; }
    public bool ShowStoppedVMs { get; set; } = true;
    public bool ViewerDebugLog { get; set; }
    public bool ResizeGuest { get; set; } = true;
    public bool ShareClipboard { get; set; } = true;
    /// <summary>remote-viewer in its own window instead of the built-in console.</summary>
    public bool UseClassicViewer { get; set; }
    public string QuickHost { get; set; } = "";
    public int QuickPort { get; set; } = 5900;
    public bool QuickTls { get; set; }
}

/// <summary>%APPDATA%\Chili\settings.json: servers (without secrets), pinned certificate
/// fingerprints and preferences.</summary>
public sealed class SettingsStore : ITrustStore
{
    private sealed class Data
    {
        public List<ServerProfile> Servers { get; set; } = [];
        public Dictionary<string, string> TrustedCertificates { get; set; } = [];
        public Preferences Preferences { get; set; } = new();
    }

    private static readonly JsonSerializerOptions Json = new() { WriteIndented = true };
    private readonly string path;
    private readonly bool readOnly;
    private Data data;

    public SettingsStore(bool demo)
    {
        var dir = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "Chili");
        path = Path.Combine(dir, "settings.json");
        readOnly = demo;   // demo mode never overwrites the real settings
        data = Load(path);
        if (demo) data.Servers = [Demo.Profile];
    }

    public static string Directory =>
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "Chili");

    private static Data Load(string path)
    {
        try
        {
            if (File.Exists(path)) return JsonSerializer.Deserialize<Data>(File.ReadAllText(path), Json) ?? new();
        }
        catch (Exception e) when (e is JsonException or IOException)
        {
            // Keep the broken file for inspection; start afresh.
            try { File.Copy(path, path + ".broken", overwrite: true); } catch (IOException) { }
        }
        return new();
    }

    public void Save()
    {
        if (readOnly) return;
        System.IO.Directory.CreateDirectory(Path.GetDirectoryName(path)!);
        var tmp = path + ".tmp";
        File.WriteAllText(tmp, JsonSerializer.Serialize(data, Json));
        File.Move(tmp, path, overwrite: true);
    }

    public IReadOnlyList<ServerProfile> Servers => data.Servers;
    public Preferences Preferences => data.Preferences;

    public void Upsert(ServerProfile profile)
    {
        int i = data.Servers.FindIndex(s => s.Id == profile.Id);
        if (i >= 0) data.Servers[i] = profile; else data.Servers.Add(profile);
        Save();
    }

    public void Remove(ServerProfile profile)
    {
        data.Servers.RemoveAll(s => s.Id == profile.Id);
        Save();
    }

    // MARK: Certificate pins

    private static string PinKey(string host, int port) => $"{host.ToLowerInvariant()}:{port}";

    public bool IsTrusted(string host, int port, string fingerprint) =>
        data.TrustedCertificates.TryGetValue(PinKey(host, port), out var fp) && fp == fingerprint;

    public void Trust(string host, int port, string fingerprint)
    {
        data.TrustedCertificates[PinKey(host, port)] = fingerprint;
        Save();
    }

    public void ForgetCertificates()
    {
        data.TrustedCertificates.Clear();
        Save();
    }
}
