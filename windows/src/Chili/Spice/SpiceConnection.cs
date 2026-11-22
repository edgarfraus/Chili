using System.Runtime.InteropServices;
using Chili.Core;
using Microsoft.UI.Dispatching;

namespace Chili.Spice;

/// <summary>One SPICE session through chili-spice.dll (spice-glib, bundled in viewer\bin).
/// Events arrive on the SPICE thread and are forwarded to the UI thread; every member is
/// meant to be used from the UI thread.</summary>
public sealed class SpiceConnection : IDisposable
{
    public enum ConnectionState { Connecting, Connected, Disconnected }
    public enum MouseModes { Server = 1, Client = 2 }

    public sealed record CursorImage(int Width, int Height, int HotX, int HotY, byte[] Bgra);

    public ConnectionState State { get; private set; } = ConnectionState.Disconnected;
    public string? ErrorMessage { get; private set; }
    public MouseModes MouseMode { get; private set; } = MouseModes.Server;
    public bool AgentConnected { get; private set; }
    public bool GuestUsesCrlf { get; private set; }
    public int DisplayWidth { get; private set; }
    public int DisplayHeight { get; private set; }
    public bool DisplayReady { get; private set; }
    public CursorImage? Cursor { get; private set; }
    public bool CursorHidden { get; private set; }

    /// <summary>Any property above changed.</summary>
    public event Action? Changed;
    /// <summary>The frame changed: copy it with <see cref="CopyFrame"/>. Raised on the UI thread.</summary>
    public event Action? FrameInvalidated;
    public event Action<string>? GuestClipboardText;
    public event Action<byte[]>? GuestClipboardPng;

    private IntPtr handle;
    private readonly DispatcherQueue ui;
    private readonly Native.EventCallback callback;   // kept alive as long as the native side may call it
    private GCHandle self;
    private readonly Dictionary<string, string> options;

    public SpiceConnection(IReadOnlyList<KeyValuePair<string, string>> options, DispatcherQueue ui)
    {
        Native.EnsureLoaded();
        this.ui = ui;
        this.options = options.ToDictionary(o => o.Key, o => o.Value);
        callback = OnEvent;
        self = GCHandle.Alloc(this);
        handle = Native.cs_new(callback, GCHandle.ToIntPtr(self));
    }

    public string? Option(string key) => options.GetValueOrDefault(key);

    public void Connect(bool audio)
    {
        if (handle == IntPtr.Zero || State != ConnectionState.Disconnected) return;
        foreach (var (k, v) in options) Native.cs_set_option(handle, k, v);
        State = ConnectionState.Connecting;
        ErrorMessage = null;
        Native.cs_connect(handle, audio ? 1 : 0);
        Changed?.Invoke();
    }

    public void Disconnect() { if (handle != IntPtr.Zero) Native.cs_disconnect(handle); }

    public void Dispose()
    {
        if (handle == IntPtr.Zero) return;
        Native.cs_free(handle);
        handle = IntPtr.Zero;
        // The SPICE thread may deliver events until it has processed the teardown, so the
        // GCHandle (which roots this object and its callback) is deliberately never freed:
        // a few bytes per closed console.
        Changed = null;
        FrameInvalidated = null;
        GuestClipboardText = null;
        GuestClipboardPng = null;
    }

    // MARK: Frames

    public bool CopyFrame(IntPtr dst, int stride, int maxWidth, int maxHeight, bool onlyIfChanged) =>
        handle != IntPtr.Zero && Native.cs_copy_frame(handle, dst, stride, maxWidth, maxHeight, onlyIfChanged ? 1 : 0) != 0;

    // MARK: Input

    public void Key(int scancode, bool pressed) { if (handle != IntPtr.Zero) Native.cs_key(handle, scancode, pressed ? 1 : 0); }
    public void ReleaseAllKeys() { if (handle != IntPtr.Zero) Native.cs_release_all_keys(handle); }
    public void CtrlAltDel() { if (handle != IntPtr.Zero) Native.cs_ctrl_alt_del(handle); }
    public void Motion(int dx, int dy, int mask) { if (handle != IntPtr.Zero) Native.cs_motion(handle, dx, dy, mask); }
    public void Position(int x, int y, int mask) { if (handle != IntPtr.Zero) Native.cs_position(handle, x, y, mask); }
    public void Button(int button, bool pressed, int mask) { if (handle != IntPtr.Zero) Native.cs_button(handle, button, pressed ? 1 : 0, mask); }
    public void RequestResolution(int width, int height) { if (handle != IntPtr.Zero) Native.cs_request_resolution(handle, width, height); }

    // MARK: Clipboard

    public void SetShareClipboard(bool share) { if (handle != IntPtr.Zero) Native.cs_set_share_clipboard(handle, share ? 1 : 0); }

    public void OfferClipboard(string? text, byte[]? png)
    {
        if (handle == IntPtr.Zero || !AgentConnected) return;
        if (text is not null && GuestUsesCrlf) text = text.Replace("\r\n", "\n").Replace("\n", "\r\n");
        else if (text is not null) text = text.Replace("\r\n", "\n");
        Native.cs_clipboard_offer(handle, text, png, png?.Length ?? 0);
    }

    // MARK: Events (SPICE thread → UI thread)

    private static void OnEvent(IntPtr user, int ev, int a, int b, IntPtr data, int size)
    {
        if (GCHandle.FromIntPtr(user).Target is not SpiceConnection me) return;
        byte[]? bytes = null;
        if (data != IntPtr.Zero && size > 0)
        {
            bytes = new byte[size];
            Marshal.Copy(data, bytes, 0, size);
        }
        me.ui.TryEnqueue(() => me.Handle((Native.Event)ev, a, b, bytes));
    }

    private void Handle(Native.Event ev, int a, int b, byte[]? data)
    {
        switch (ev)
        {
            case Native.Event.State:
                State = (ConnectionState)a;
                if (State == ConnectionState.Disconnected)
                {
                    DisplayReady = false;
                    if (data is not null) ErrorMessage ??= Translate(System.Text.Encoding.UTF8.GetString(data));
                }
                break;
            case Native.Event.Display:
                DisplayWidth = a;
                DisplayHeight = b;
                DisplayReady = true;
                break;
            case Native.Event.Mark:
                DisplayReady = a != 0;
                break;
            case Native.Event.MouseMode:
                MouseMode = (MouseModes)a;
                break;
            case Native.Event.Agent:
                AgentConnected = a != 0;
                GuestUsesCrlf = b != 0;
                break;
            case Native.Event.Cursor when data is not null:
                Cursor = new CursorImage(a & 0xffff, a >> 16, b & 0xffff, b >> 16, data);
                CursorHidden = false;
                break;
            case Native.Event.CursorHide:
                CursorHidden = true;
                break;
            case Native.Event.CursorReset:
                Cursor = null;
                CursorHidden = false;
                break;
            case Native.Event.ClipboardText when data is not null:
                GuestClipboardText?.Invoke(System.Text.Encoding.UTF8.GetString(data).TrimEnd('\0').Replace("\r\n", "\n").Replace("\n", "\r\n"));
                return;
            case Native.Event.ClipboardPng when data is not null:
                GuestClipboardPng?.Invoke(data);
                return;
            case Native.Event.Invalidate:
                FrameInvalidated?.Invoke();
                return;
        }
        Changed?.Invoke();
    }

    /// <summary>Native messages are "English reason\n\ndetail": translate the reason.</summary>
    private static string Translate(string message)
    {
        int split = message.IndexOf("\n\n", StringComparison.Ordinal);
        return split < 0 ? L.T(message) : L.T(message[..split]) + message[split..];
    }
}

internal static class Native
{
    public enum Event
    {
        State = 1, Display = 2, Mark = 3, MouseMode = 4, Agent = 5, Cursor = 6, CursorHide = 7, CursorReset = 8,
        ClipboardText = 9, ClipboardPng = 10, Invalidate = 11,
    }

    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    public delegate void EventCallback(IntPtr user, int ev, int a, int b, IntPtr data, int size);

    private const string Dll = "chili-spice.dll";
    public static string BinDirectory => Path.Combine(AppContext.BaseDirectory, "viewer", "bin");
    public static bool IsAvailable => File.Exists(Path.Combine(BinDirectory, Dll));

    private static bool loaded;

    /// <summary>Loads chili-spice.dll with spice-glib and GStreamer from viewer\bin, sets up
    /// GStreamer (our plugins only, registry in our cache, no scanner) and starts the SPICE thread.</summary>
    public static void EnsureLoaded()
    {
        if (loaded) return;
        if (!IsAvailable) throw new InvalidOperationException(L.T("The built-in console is missing. Please reinstall Chili."));
        var root = Path.GetFullPath(Path.Combine(BinDirectory, ".."));
        var cache = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Chili", "Cache");
        Directory.CreateDirectory(cache);
        var plugins = Path.Combine(root, "lib", "gstreamer-1.0");
        Environment.SetEnvironmentVariable("GST_PLUGIN_SYSTEM_PATH_1_0", plugins);
        Environment.SetEnvironmentVariable("GST_PLUGIN_PATH_1_0", plugins);
        Environment.SetEnvironmentVariable("GST_REGISTRY_1_0", Path.Combine(cache,
            $"gst-registry-console-{RuntimeInformation.ProcessArchitecture}.bin".ToLowerInvariant()));
        Environment.SetEnvironmentVariable("GST_REGISTRY_FORK", "no");
        // The DLLs that chili-spice.dll and the GStreamer plugins depend on live next to it.
        SetDllDirectoryW(BinDirectory);
        NativeLibrary.SetDllImportResolver(typeof(Native).Assembly, (name, _, _) =>
            name == Dll ? NativeLibrary.Load(Path.Combine(BinDirectory, Dll)) : IntPtr.Zero);
        cs_initialize();
        loaded = true;
    }

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)] private static extern bool SetDllDirectoryW(string path);

    [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)] public static extern void cs_initialize();
    [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)] public static extern IntPtr cs_new(EventCallback cb, IntPtr user);
    [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)]
    public static extern void cs_set_option(IntPtr c, [MarshalAs(UnmanagedType.LPUTF8Str)] string key, [MarshalAs(UnmanagedType.LPUTF8Str)] string value);
    [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)] public static extern void cs_connect(IntPtr c, int audio);
    [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)] public static extern void cs_disconnect(IntPtr c);
    [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)] public static extern void cs_free(IntPtr c);
    [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)]
    public static extern int cs_copy_frame(IntPtr c, IntPtr dst, int stride, int maxW, int maxH, int onlyIfChanged);
    [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)] public static extern void cs_key(IntPtr c, int scancode, int pressed);
    [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)] public static extern void cs_release_all_keys(IntPtr c);
    [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)] public static extern void cs_ctrl_alt_del(IntPtr c);
    [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)] public static extern void cs_motion(IntPtr c, int dx, int dy, int mask);
    [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)] public static extern void cs_position(IntPtr c, int x, int y, int mask);
    [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)] public static extern void cs_button(IntPtr c, int button, int pressed, int mask);
    [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)] public static extern void cs_request_resolution(IntPtr c, int w, int h);
    [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)] public static extern void cs_set_share_clipboard(IntPtr c, int share);
    [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)]
    public static extern void cs_clipboard_offer(IntPtr c, [MarshalAs(UnmanagedType.LPUTF8Str)] string? text, byte[]? png, int pngSize);
}
