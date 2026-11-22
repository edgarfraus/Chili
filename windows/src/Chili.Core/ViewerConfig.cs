namespace Chili.Core;

/// <summary>Connection settings understood by remote-viewer, serialized as a virt-viewer ".vv"
/// file (an INI file with a single [virt-viewer] group). Keys keep their order.</summary>
public sealed class ViewerConfig
{
    private readonly List<KeyValuePair<string, string>> entries = [new("type", "spice")];

    public IReadOnlyList<KeyValuePair<string, string>> Entries => entries;

    public string? this[string key]
    {
        get => entries.FirstOrDefault(e => e.Key == key).Value;
        set
        {
            entries.RemoveAll(e => e.Key == key);
            if (value is not null) entries.Add(new(key, value));
        }
    }

    /// <summary>Parses the body of a .vv file (as returned by Proxmox' spiceconfig API).</summary>
    public static ViewerConfig Parse(string vvText)
    {
        var config = new ViewerConfig();
        config.entries.Clear();
        foreach (var raw in vvText.Split('\n', '\r'))
        {
            var line = raw.Trim();
            int eq = line.IndexOf('=');
            if (line.StartsWith('[') || line.StartsWith('#') || line.StartsWith(';') || eq < 0) continue;
            config[line[..eq].Trim()] = line[(eq + 1)..].Trim();
        }
        return config;
    }

    public string VvText =>
        "[virt-viewer]\n" + string.Concat(entries.Select(e => $"{e.Key}={e.Value}\n"));

    public ViewerConfig Clone() => Parse(VvText);
}

/// <summary>Command-line handling shared with the file / URL associations.</summary>
public static class LaunchArguments
{
    /// <summary>spice://host:port?password=…&amp;tls-port=… (and spice+tls://host:tls-port) → a .vv config.</summary>
    public static ViewerConfig? ParseSpiceUri(string text)
    {
        if (!Uri.TryCreate(text.Trim(), UriKind.Absolute, out var uri)) return null;
        bool tls = uri.Scheme.Equals("spice+tls", StringComparison.OrdinalIgnoreCase);
        if (!tls && !uri.Scheme.Equals("spice", StringComparison.OrdinalIgnoreCase)) return null;
        if (uri.Host.Length == 0) return null;
        var c = new ViewerConfig();
        c["host"] = uri.Host.Trim('[', ']');
        if (!uri.IsDefaultPort && uri.Port > 0) c[tls ? "tls-port" : "port"] = uri.Port.ToString();
        foreach (var pair in uri.Query.TrimStart('?').Split('&', StringSplitOptions.RemoveEmptyEntries))
        {
            int eq = pair.IndexOf('=');
            var key = Uri.UnescapeDataString(eq < 0 ? pair : pair[..eq]).ToLowerInvariant();
            var value = eq < 0 ? "" : Uri.UnescapeDataString(pair[(eq + 1)..].Replace('+', ' '));
            if (key is "port" or "tls-port" or "password") c[key] = value;
        }
        if (c["port"] is null && c["tls-port"] is null) c["port"] = "5900";
        return c;
    }

    /// <summary>Splits a Windows command line (quotes, backslashes before quotes).</summary>
    public static List<string> Split(string commandLine)
    {
        var result = new List<string>();
        var current = new System.Text.StringBuilder();
        bool quoted = false, any = false;
        for (int i = 0; i < commandLine.Length; i++)
        {
            char ch = commandLine[i];
            if (ch == '"') { quoted = !quoted; any = true; }
            else if (char.IsWhiteSpace(ch) && !quoted)
            {
                if (any || current.Length > 0) result.Add(current.ToString());
                current.Clear();
                any = false;
            }
            else current.Append(ch);
        }
        if (any || current.Length > 0) result.Add(current.ToString());
        return result;
    }

    /// <summary>The .vv file or spice:// link among the arguments, if any.</summary>
    public static string? Target(IEnumerable<string> args) =>
        args.FirstOrDefault(a => a.EndsWith(".vv", StringComparison.OrdinalIgnoreCase)
                                 || a.StartsWith("spice://", StringComparison.OrdinalIgnoreCase)
                                 || a.StartsWith("spice+tls://", StringComparison.OrdinalIgnoreCase));
}
