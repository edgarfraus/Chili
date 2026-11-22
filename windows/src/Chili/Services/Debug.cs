using System.Runtime.InteropServices.WindowsRuntime;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Imaging;
using Windows.Graphics.Imaging;
using Windows.Storage.Streams;

namespace Chili.Services;

/// <summary>Dev aids, harmless in production:
/// CHILI_DEBUG_SNAPSHOT=&lt;dir&gt; saves a PNG of each window every 3 s (rendered from the XAML
/// tree, so it works without a visible desktop, e.g. a disconnected RDP session; open dialogs
/// and flyouts are composited on top); CHILI_DEBUG_ACTION drives the UI (see
/// MainWindow.RunDebugAction); CHILI_LANG=it|en forces the language.</summary>
public static class Debug
{
    public static readonly string? Action = Env("CHILI_DEBUG_ACTION");
    public static readonly string? SnapshotDir = Env("CHILI_DEBUG_SNAPSHOT");
    private static readonly string LogPath = Path.Combine(Path.GetTempPath(), "chili-debug.log");

    private static string? Env(string name) => Environment.GetEnvironmentVariable(name) is { Length: > 0 } v ? v : null;

    public static void Log(string message)
    {
        if (Action is null && SnapshotDir is null) return;
        try { File.AppendAllText(LogPath, $"{DateTime.Now:HH:mm:ss.fff} {message}\n"); } catch (IOException) { }
    }

    /// <summary>Starts periodic snapshots of <paramref name="window"/> named &lt;name&gt;.png.</summary>
    public static void StartSnapshots(Window window, string name)
    {
        if (SnapshotDir is null) return;
        Directory.CreateDirectory(SnapshotDir);
        var timer = window.DispatcherQueue.CreateTimer();
        timer.Interval = TimeSpan.FromSeconds(3);
        timer.Tick += async (_, _) =>
        {
            try { await SnapshotAsync(window, Path.Combine(SnapshotDir, name + ".png")); }
            catch (Exception e) { Log($"snapshot failed: {e.Message}"); }
        };
        timer.Start();
        window.Closed += (_, _) => timer.Stop();
    }

    public static async Task SnapshotAsync(Window window, string path)
    {
        if (window.Content is not FrameworkElement root || root.XamlRoot is null) return;
        var (pixels, w, h) = await RenderAsync(root);
        if (w == 0 || h == 0) return;

        // The window's backdrop (Mica) isn't part of the XAML tree: start from the theme's
        // solid background so transparent areas don't come out black.
        bool dark = root.ActualTheme == ElementTheme.Dark;
        byte bg = dark ? (byte)0x20 : (byte)0xF3;
        var canvas = new byte[w * h * 4];
        for (int i = 0; i < canvas.Length; i += 4) { canvas[i] = canvas[i + 1] = canvas[i + 2] = bg; canvas[i + 3] = 255; }
        Blend(canvas, w, h, pixels, w, h, 0, 0);

        double scale = root.XamlRoot.RasterizationScale;
        foreach (var popup in VisualTreeHelper.GetOpenPopupsForXamlRoot(root.XamlRoot))
        {
            if (popup.Child is not FrameworkElement child || child.ActualWidth < 1) continue;
            var (pp, pw, ph) = await RenderAsync(child);
            var at = child.TransformToVisual(root).TransformPoint(new Windows.Foundation.Point(0, 0));
            Blend(canvas, w, h, pp, pw, ph, (int)Math.Round(at.X * scale), (int)Math.Round(at.Y * scale));
        }

        using var stream = new InMemoryRandomAccessStream();
        var encoder = await BitmapEncoder.CreateAsync(BitmapEncoder.PngEncoderId, stream);
        encoder.SetPixelData(BitmapPixelFormat.Bgra8, BitmapAlphaMode.Ignore, (uint)w, (uint)h, 96, 96, canvas);
        await encoder.FlushAsync();
        var bytes = new byte[stream.Size];
        stream.Seek(0);
        await stream.ReadAsync(bytes.AsBuffer(), (uint)bytes.Length, InputStreamOptions.None);
        var tmp = path + ".tmp";
        await File.WriteAllBytesAsync(tmp, bytes);
        File.Move(tmp, path, overwrite: true);
    }

    private static async Task<(byte[] Pixels, int Width, int Height)> RenderAsync(UIElement element)
    {
        var rtb = new RenderTargetBitmap();
        await rtb.RenderAsync(element);
        var buffer = await rtb.GetPixelsAsync();
        return (buffer.ToArray(), rtb.PixelWidth, rtb.PixelHeight);
    }

    /// <summary>Draws premultiplied BGRA <paramref name="src"/> over <paramref name="dst"/>.</summary>
    private static void Blend(byte[] dst, int dw, int dh, byte[] src, int sw, int sh, int x0, int y0)
    {
        for (int y = 0; y < sh; y++)
        {
            int dy = y + y0;
            if (dy < 0 || dy >= dh) continue;
            for (int x = 0; x < sw; x++)
            {
                int dx = x + x0;
                if (dx < 0 || dx >= dw) continue;
                int s = (y * sw + x) * 4, d = (dy * dw + dx) * 4;
                int a = src[s + 3];
                if (a == 0) continue;
                for (int c = 0; c < 3; c++) dst[d + c] = (byte)(src[s + c] + dst[d + c] * (255 - a) / 255);
            }
        }
    }
}
