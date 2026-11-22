using System.Runtime.InteropServices.WindowsRuntime;
using Windows.ApplicationModel.DataTransfer;
using Windows.Graphics.Imaging;
using Windows.Storage.Streams;

namespace Chili.Spice;

/// <summary>Two-way clipboard sharing between Windows and the guests' SPICE agents
/// (text and PNG images). Guest copies go to the Windows clipboard; Windows copies are
/// offered to every connected guest.</summary>
public static class ClipboardSync
{
    private static readonly List<WeakReference<SpiceConnection>> connections = [];
    private static bool started, ignoreNextChange;

    private static bool Enabled => App.Model.Settings.Preferences.ShareClipboard;

    public static void Attach(SpiceConnection connection)
    {
        if (!started)
        {
            started = true;
            Clipboard.ContentChanged += async (_, _) =>
            {
                if (ignoreNextChange) { ignoreNextChange = false; return; }
                await OfferToAll();
            };
        }
        connections.RemoveAll(w => !w.TryGetTarget(out _));
        connections.Add(new WeakReference<SpiceConnection>(connection));
        connection.SetShareClipboard(Enabled);

        bool agent = false;
        connection.Changed += async () =>
        {
            // Offer the current clipboard to an agent that just connected.
            if (connection.AgentConnected && !agent) { agent = true; await OfferTo([connection]); }
            agent = connection.AgentConnected;
        };
        connection.GuestClipboardText += text =>
        {
            if (!Enabled) return;
            var package = new DataPackage();
            package.SetText(text);
            SetClipboard(package);
        };
        connection.GuestClipboardPng += async png =>
        {
            if (!Enabled) return;
            var stream = new InMemoryRandomAccessStream();
            await stream.WriteAsync(png.AsBuffer());
            stream.Seek(0);
            var package = new DataPackage();
            package.SetBitmap(RandomAccessStreamReference.CreateFromStream(stream));
            SetClipboard(package);
        };
    }

    private static void SetClipboard(DataPackage package)
    {
        try
        {
            ignoreNextChange = true;   // don't bounce it back to the guest
            Clipboard.SetContent(package);
            Clipboard.Flush();
        }
        catch (Exception e) { ignoreNextChange = false; Services.Debug.Log($"clipboard: {e.Message}"); }
    }

    private static Task OfferToAll()
    {
        var live = connections.Select(w => w.TryGetTarget(out var c) ? c : null).OfType<SpiceConnection>().ToList();
        return OfferTo(live);
    }

    private static async Task OfferTo(IReadOnlyList<SpiceConnection> targets)
    {
        if (!Enabled || !targets.Any(c => c.AgentConnected)) return;
        string? text = null;
        byte[]? png = null;
        try
        {
            var content = Clipboard.GetContent();
            if (content.Contains(StandardDataFormats.Text)) text = await content.GetTextAsync();
            else if (content.Contains(StandardDataFormats.Bitmap)) png = await ToPng(await content.GetBitmapAsync());
        }
        catch (Exception e) { Services.Debug.Log($"clipboard read: {e.Message}"); return; }
        if (text is null && png is null) return;
        foreach (var c in targets) c.OfferClipboard(text, png);
    }

    private static async Task<byte[]> ToPng(RandomAccessStreamReference reference)
    {
        using var source = await reference.OpenReadAsync();
        var decoder = await BitmapDecoder.CreateAsync(source);
        using var bitmap = await decoder.GetSoftwareBitmapAsync(BitmapPixelFormat.Bgra8, BitmapAlphaMode.Premultiplied);
        using var output = new InMemoryRandomAccessStream();
        var encoder = await BitmapEncoder.CreateAsync(BitmapEncoder.PngEncoderId, output);
        encoder.SetSoftwareBitmap(bitmap);
        await encoder.FlushAsync();
        var bytes = new byte[output.Size];
        output.Seek(0);
        await output.ReadAsync(bytes.AsBuffer(), (uint)bytes.Length, InputStreamOptions.None);
        return bytes;
    }
}
