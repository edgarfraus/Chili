using System.Globalization;

namespace Chili.Services;

public static class Format
{
    private static readonly string[] Units = ["bytes", "KB", "MB", "GB", "TB", "PB"];

    /// <summary>Like macOS' ByteCountFormatter (memory style): "8 GB", "512 MB", "1.5 GB".</summary>
    public static string Bytes(long? value)
    {
        double v = value ?? 0;
        int unit = 0;
        while (v >= 1024 && unit < Units.Length - 1) { v /= 1024; unit++; }
        if (unit == 0) return $"{(long)v} {Units[0]}";
        var text = v >= 10 || Math.Abs(v - Math.Round(v)) < 0.05
            ? Math.Round(v).ToString("0", CultureInfo.CurrentCulture)
            : v.ToString("0.#", CultureInfo.CurrentCulture);
        return $"{text} {Units[unit]}";
    }

    /// <summary>Network rate: "336 KB/s"; zero reads "0 KB/s".</summary>
    public static string Rate(double? bytesPerSecond)
    {
        long v = (long)(bytesPerSecond ?? 0);
        return (v < 1 ? "0 KB" : v < 1024 ? "1 KB" : Bytes(v)) + "/s";
    }

    public static string Percent(double fraction) =>
        $"{(int)Math.Round(Math.Clamp(fraction, 0, 1) * 100)}%";
}
