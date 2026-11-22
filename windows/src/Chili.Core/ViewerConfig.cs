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
