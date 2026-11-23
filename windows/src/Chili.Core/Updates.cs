using System.Security.Cryptography;
using System.Text.Json.Nodes;

namespace Chili.Core;

/// <summary>A Windows release on GitHub that is newer than the running app.</summary>
public sealed record ReleaseInfo(Version Version, string Tag, string PageUrl, string SetupUrl, string? Sha256Url, string Notes);

/// <summary>
/// Update checks against the GitHub releases of the project. Windows releases are tagged
/// <c>windows-v&lt;version&gt;</c> and carry <c>Chili-&lt;version&gt;-&lt;arch&gt;-setup.exe</c> plus a
/// <c>.sha256</c> file. Drafts and pre-releases are ignored.
/// </summary>
public static class Updates
{
    public const string Repository = "edgarfraus/Chili";
    private const string TagPrefix = "windows-v";

    /// <summary>"windows-v1.2.3" → 1.2.3; anything else → null.</summary>
    public static Version? ParseTag(string? tag)
    {
        if (tag is null || !tag.StartsWith(TagPrefix, StringComparison.OrdinalIgnoreCase)) return null;
        var text = tag[TagPrefix.Length..];
        int dash = text.IndexOf('-');   // "1.2.3-beta" isn't a release we offer
        if (dash >= 0) return null;
        return Version.TryParse(text, out var v) ? Normalize(v) : null;
    }

    /// <summary>1.2 → 1.2.0, and the build/revision parts compare as 0 when missing.</summary>
    public static Version Normalize(Version v) =>
        new(v.Major, v.Minor, Math.Max(v.Build, 0), Math.Max(v.Revision, 0));

    /// <summary>The newest Windows release in a GitHub /releases response that is newer than
    /// <paramref name="current"/> and has a setup for <paramref name="arch"/> (x64, arm64).</summary>
    public static ReleaseInfo? Newest(JsonArray releases, Version current, string arch)
    {
        ReleaseInfo? best = null;
        foreach (var r in releases.OfType<JsonObject>())
        {
            if ((bool?)r["draft"] == true || (bool?)r["prerelease"] == true) continue;
            var tag = (string?)r["tag_name"];
            if (ParseTag(tag) is not { } version || version <= Normalize(current)) continue;
            if (best is not null && version <= best.Version) continue;
            string? setup = null, sha = null;
            foreach (var a in (r["assets"] as JsonArray ?? []).OfType<JsonObject>())
            {
                var name = (string?)a["name"] ?? "";
                var url = (string?)a["browser_download_url"];
                if (name.EndsWith($"-{arch}-setup.exe", StringComparison.OrdinalIgnoreCase)) setup = url;
                else if (name.EndsWith($"-{arch}-setup.exe.sha256", StringComparison.OrdinalIgnoreCase)) sha = url;
            }
            if (setup is null) continue;
            best = new ReleaseInfo(version, tag!, (string?)r["html_url"] ?? "", setup, sha, (string?)r["body"] ?? "");
        }
        return best;
    }

    public static HttpClient CreateClient(Version current)
    {
        var http = new HttpClient { Timeout = TimeSpan.FromMinutes(10) };
        // GitHub's API requires a User-Agent.
        http.DefaultRequestHeaders.UserAgent.ParseAdd($"Chili/{current} (+https://github.com/{Repository})");
        http.DefaultRequestHeaders.Accept.ParseAdd("application/vnd.github+json");
        return http;
    }

    public static async Task<ReleaseInfo?> CheckAsync(HttpClient http, Version current, string arch, CancellationToken ct = default)
    {
        var json = await http.GetStringAsync($"https://api.github.com/repos/{Repository}/releases?per_page=30", ct);
        return JsonNode.Parse(json) is JsonArray list ? Newest(list, current, arch) : null;
    }

    /// <summary>Downloads the setup into <paramref name="directory"/> and checks it against the
    /// release's .sha256 file. Returns the path of the verified installer.</summary>
    public static async Task<string> DownloadAsync(HttpClient http, ReleaseInfo release, string directory,
                                                   IProgress<double>? progress = null, CancellationToken ct = default)
    {
        Directory.CreateDirectory(directory);
        var path = Path.Combine(directory, Path.GetFileName(new Uri(release.SetupUrl).LocalPath));
        using (var response = await http.GetAsync(release.SetupUrl, HttpCompletionOption.ResponseHeadersRead, ct))
        {
            response.EnsureSuccessStatusCode();
            long total = response.Content.Headers.ContentLength ?? 0, done = 0;
            await using var input = await response.Content.ReadAsStreamAsync(ct);
            await using var output = File.Create(path);
            var buffer = new byte[256 * 1024];
            int n;
            while ((n = await input.ReadAsync(buffer, ct)) > 0)
            {
                await output.WriteAsync(buffer.AsMemory(0, n), ct);
                done += n;
                if (total > 0) progress?.Report((double)done / total);
            }
        }
        if (release.Sha256Url is { } shaUrl)
        {
            var expected = ParseSha256(await http.GetStringAsync(shaUrl, ct));
            await using var file = File.OpenRead(path);
            var actual = Convert.ToHexStringLower(await SHA256.HashDataAsync(file, ct));
            if (!string.Equals(expected, actual, StringComparison.OrdinalIgnoreCase))
            {
                File.Delete(path);
                throw new InvalidDataException(L.T("The downloaded update is damaged (checksum mismatch). Try again later."));
            }
        }
        return path;
    }

    /// <summary>"&lt;hex&gt;  file.exe" (sha256sum format) → the hex digest.</summary>
    public static string ParseSha256(string text) =>
        text.Trim().Split([' ', '\t', '\n', '\r'], StringSplitOptions.RemoveEmptyEntries).FirstOrDefault() ?? "";
}
