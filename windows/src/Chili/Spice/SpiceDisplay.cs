using System.Runtime.InteropServices;
using System.Runtime.InteropServices.WindowsRuntime;
using Microsoft.UI.Input;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Imaging;
using Windows.Foundation;
using Windows.System;

namespace Chili.Spice;

/// <summary>Shows a connection's display and forwards keyboard and mouse to it. Port of
/// CSDisplayView (macOS). In server mouse mode the pointer is captured after a click and
/// Ctrl+Alt releases it.</summary>
public sealed partial class SpiceDisplay : UserControl
{
    private readonly Grid root = new() { Background = new SolidColorBrush(Microsoft.UI.Colors.Black) };
    private readonly Image image = new()
    {
        Stretch = Stretch.Uniform, HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center,
    };
    private readonly Canvas overlay = new() { IsHitTestVisible = false };
    private readonly Image cursorImage = new() { IsHitTestVisible = false, Visibility = Visibility.Collapsed };

    private SpiceConnection? connection;
    private WriteableBitmap? bitmap;
    private byte[] pixels = [];
    private bool framePending, renderingHooked;
    private int buttonMask;
    private bool ctrlDown, altDown;
    private bool systemCursorHidden;
    private Point lastPointer;
    private readonly DispatcherTimerLite resizeTimer;

    public bool ResizeGuestToFit { get; set; } = true;
    public bool PointerCaptured { get; private set; }
    /// <summary>Capture changes, for the "Press Ctrl+Alt to release" hint.</summary>
    public event Action<bool>? CaptureChanged;

    public SpiceDisplay()
    {
        IsTabStop = true;
        UseSystemFocusVisuals = false;
        root.Children.Add(image);
        overlay.Children.Add(cursorImage);
        root.Children.Add(overlay);
        Content = root;
        resizeTimer = new DispatcherTimerLite(DispatcherQueue, TimeSpan.FromMilliseconds(400), RequestGuestResize);

        PointerPressed += OnPointerPressed;
        PointerReleased += OnPointerReleased;
        PointerMoved += OnPointerMoved;
        PointerWheelChanged += OnPointerWheelChanged;
        PointerEntered += (_, _) => UpdateSystemCursor(inside: true);
        PointerExited += (_, _) => { UpdateSystemCursor(inside: false); cursorImage.Visibility = Visibility.Collapsed; };
        PreviewKeyDown += OnKey;
        PreviewKeyUp += OnKey;
        LostFocus += (_, _) => { connection?.ReleaseAllKeys(); ReleasePointer(); ctrlDown = altDown = false; };
        SizeChanged += (_, _) => resizeTimer.Restart();
        Unloaded += (_, _) => { ReleasePointer(); UpdateSystemCursor(inside: false); UnhookRendering(); };
    }

    public SpiceConnection? Connection
    {
        get => connection;
        set
        {
            if (connection is not null)
            {
                connection.Changed -= OnConnectionChanged;
                connection.FrameInvalidated -= OnFrameInvalidated;
            }
            connection = value;
            bitmap = null;
            image.Source = null;
            if (connection is not null)
            {
                connection.Changed += OnConnectionChanged;
                connection.FrameInvalidated += OnFrameInvalidated;
                OnConnectionChanged();
            }
        }
    }

    // MARK: Frames

    private int agentSeen = -1;

    private void OnConnectionChanged()
    {
        if (connection is null) return;
        if (connection.DisplayWidth > 0 && (bitmap is null || bitmap.PixelWidth != connection.DisplayWidth
                                             || bitmap.PixelHeight != connection.DisplayHeight))
        {
            bitmap = new WriteableBitmap(connection.DisplayWidth, connection.DisplayHeight);
            pixels = new byte[connection.DisplayWidth * connection.DisplayHeight * 4];
            image.Source = bitmap;
            framePending = true;
            HookRendering();
        }
        image.Opacity = connection.DisplayReady ? 1 : 0.35;
        if (connection.MouseMode == SpiceConnection.MouseModes.Client) ReleasePointer();
        // Resize the guest once its agent shows up.
        int agent = connection.AgentConnected ? 1 : 0;
        if (agent != agentSeen) { agentSeen = agent; if (agent == 1) resizeTimer.Restart(); }
        UpdateCursorImage();
        UpdateSystemCursor(inside: pointerInside);
    }

    private void OnFrameInvalidated()
    {
        framePending = true;
        HookRendering();
    }

    private void HookRendering()
    {
        if (renderingHooked) return;
        renderingHooked = true;
        CompositionTarget.Rendering += OnRendering;
    }

    private void UnhookRendering()
    {
        if (!renderingHooked) return;
        renderingHooked = false;
        CompositionTarget.Rendering -= OnRendering;
    }

    /// <summary>Copies the frame at most once per screen refresh.</summary>
    private void OnRendering(object? sender, object e)
    {
        if (!framePending || connection is null || bitmap is null) { UnhookRendering(); return; }
        framePending = false;
        int w = bitmap.PixelWidth, h = bitmap.PixelHeight;
        var pin = GCHandle.Alloc(pixels, GCHandleType.Pinned);
        bool copied;
        try { copied = connection.CopyFrame(pin.AddrOfPinnedObject(), w * 4, w, h, onlyIfChanged: false); }
        finally { pin.Free(); }
        if (!copied) return;
        using (var stream = bitmap.PixelBuffer.AsStream()) stream.Write(pixels, 0, pixels.Length);
        bitmap.Invalidate();
    }

    // MARK: Guest resolution

    private void RequestGuestResize()
    {
        if (!ResizeGuestToFit || connection is not { AgentConnected: true } || ActualWidth < 320 || ActualHeight < 200) return;
        // Logical pixels: at 150% scaling the guest gets the size the window shows, not a huge desktop.
        connection.RequestResolution((int)ActualWidth, (int)ActualHeight);
    }

    // MARK: Mouse

    private bool pointerInside;

    /// <summary>Pointer position in guest pixels, clamped to the display.</summary>
    private (int X, int Y) GuestPoint(PointerRoutedEventArgs e)
    {
        var p = e.GetCurrentPoint(image).Position;
        if (connection is null || image.ActualWidth <= 0 || image.ActualHeight <= 0) return (0, 0);
        int x = (int)(p.X * connection.DisplayWidth / image.ActualWidth);
        int y = (int)(p.Y * connection.DisplayHeight / image.ActualHeight);
        return (Math.Clamp(x, 0, Math.Max(connection.DisplayWidth - 1, 0)), Math.Clamp(y, 0, Math.Max(connection.DisplayHeight - 1, 0)));
    }

    private static int ButtonOf(PointerPointProperties p) => p.PointerUpdateKind switch
    {
        PointerUpdateKind.LeftButtonPressed or PointerUpdateKind.LeftButtonReleased => 1,
        PointerUpdateKind.MiddleButtonPressed or PointerUpdateKind.MiddleButtonReleased => 2,
        PointerUpdateKind.RightButtonPressed or PointerUpdateKind.RightButtonReleased => 3,
        _ => 0,
    };

    private static int MaskOf(PointerPointProperties p) =>
        (p.IsLeftButtonPressed ? 1 : 0) | (p.IsMiddleButtonPressed ? 2 : 0) | (p.IsRightButtonPressed ? 4 : 0);

    private void OnPointerPressed(object sender, PointerRoutedEventArgs e)
    {
        Focus(FocusState.Pointer);
        e.Handled = true;
        if (connection is not { State: SpiceConnection.ConnectionState.Connected }) return;
        var props = e.GetCurrentPoint(this).Properties;
        if (connection.MouseMode == SpiceConnection.MouseModes.Server && !PointerCaptured)
        {
            CapturePointerForGuest();
            return;   // the click that captures isn't sent
        }
        buttonMask = MaskOf(props);
        CapturePointer(e.Pointer);
        if (connection.MouseMode == SpiceConnection.MouseModes.Client)
        {
            var (x, y) = GuestPoint(e);
            connection.Position(x, y, buttonMask);
        }
        if (ButtonOf(props) is var b and > 0) connection.Button(b, true, buttonMask);
    }

    private void OnPointerReleased(object sender, PointerRoutedEventArgs e)
    {
        e.Handled = true;
        if (connection is not { State: SpiceConnection.ConnectionState.Connected }) return;
        var props = e.GetCurrentPoint(this).Properties;
        buttonMask = MaskOf(props);
        if (ButtonOf(props) is var b and > 0) connection.Button(b, false, buttonMask);
        ReleasePointerCapture(e.Pointer);
    }

    private void OnPointerMoved(object sender, PointerRoutedEventArgs e)
    {
        pointerInside = true;
        lastPointer = e.GetCurrentPoint(root).Position;
        PositionCursorImage();
        if (connection is not { State: SpiceConnection.ConnectionState.Connected }) return;
        buttonMask = MaskOf(e.GetCurrentPoint(this).Properties);
        if (connection.MouseMode == SpiceConnection.MouseModes.Client)
        {
            var (x, y) = GuestPoint(e);
            connection.Position(x, y, buttonMask);
        }
        else if (PointerCaptured)
        {
            // Relative motion: measure how far the pointer moved from the centre, then put it back.
            GetCursorPos(out var now);
            int dx = now.X - captureCentre.X, dy = now.Y - captureCentre.Y;
            if (dx != 0 || dy != 0)
            {
                connection.Motion(dx, dy, buttonMask);
                SetCursorPos(captureCentre.X, captureCentre.Y);
            }
        }
    }

    private void OnPointerWheelChanged(object sender, PointerRoutedEventArgs e)
    {
        e.Handled = true;
        if (connection is not { State: SpiceConnection.ConnectionState.Connected }) return;
        int delta = e.GetCurrentPoint(this).Properties.MouseWheelDelta;
        int notches = Math.Max(1, Math.Abs(delta) / 120);
        int button = delta > 0 ? 4 : 5;
        for (int i = 0; i < notches; i++)
        {
            connection.Button(button, true, buttonMask);
            connection.Button(button, false, buttonMask);
        }
    }

    // MARK: Pointer capture (server mouse mode)

    private POINT captureCentre;

    private void CapturePointerForGuest()
    {
        var hwnd = WindowHandle();
        if (hwnd == IntPtr.Zero) return;
        var scale = XamlRoot?.RasterizationScale ?? 1;
        var topLeft = TransformToVisual(null).TransformPoint(new Point(0, 0));
        var origin = new POINT { X = 0, Y = 0 };
        ClientToScreen(hwnd, ref origin);
        var rect = new RECT
        {
            Left = origin.X + (int)(topLeft.X * scale),
            Top = origin.Y + (int)(topLeft.Y * scale),
            Right = origin.X + (int)((topLeft.X + ActualWidth) * scale),
            Bottom = origin.Y + (int)((topLeft.Y + ActualHeight) * scale),
        };
        captureCentre = new POINT { X = (rect.Left + rect.Right) / 2, Y = (rect.Top + rect.Bottom) / 2 };
        ClipCursor(ref rect);
        SetCursorPos(captureCentre.X, captureCentre.Y);
        PointerCaptured = true;
        UpdateSystemCursor(inside: true);
        CaptureChanged?.Invoke(true);
    }

    public void ReleasePointer()
    {
        if (!PointerCaptured) return;
        ClipCursor(IntPtr.Zero);
        PointerCaptured = false;
        UpdateSystemCursor(inside: pointerInside);
        CaptureChanged?.Invoke(false);
    }

    private IntPtr WindowHandle()
    {
        foreach (var w in App.Windows)
            if (w.Content?.XamlRoot == XamlRoot) return WinRT.Interop.WindowNative.GetWindowHandle(w);
        return IntPtr.Zero;
    }

    // MARK: Cursor

    private void UpdateCursorImage()
    {
        if (connection?.Cursor is not { } c || connection.MouseMode != SpiceConnection.MouseModes.Client || connection.CursorHidden)
        {
            cursorImage.Visibility = Visibility.Collapsed;
            return;
        }
        if (!ReferenceEquals(cursorImage.Tag, c))
        {
            var bmp = new WriteableBitmap(c.Width, c.Height);
            // WriteableBitmap wants premultiplied alpha.
            var data = new byte[c.Bgra.Length];
            for (int i = 0; i < data.Length; i += 4)
            {
                int a = c.Bgra[i + 3];
                data[i] = (byte)(c.Bgra[i] * a / 255);
                data[i + 1] = (byte)(c.Bgra[i + 1] * a / 255);
                data[i + 2] = (byte)(c.Bgra[i + 2] * a / 255);
                data[i + 3] = (byte)a;
            }
            using (var s = bmp.PixelBuffer.AsStream()) s.Write(data, 0, data.Length);
            bmp.Invalidate();
            cursorImage.Source = bmp;
            cursorImage.Tag = c;
        }
        PositionCursorImage();
    }

    private void PositionCursorImage()
    {
        if (connection?.Cursor is not { } c || connection.MouseMode != SpiceConnection.MouseModes.Client
            || connection.CursorHidden || !pointerInside || image.ActualWidth <= 0 || connection.DisplayWidth <= 0)
        {
            cursorImage.Visibility = Visibility.Collapsed;
            return;
        }
        double scale = image.ActualWidth / connection.DisplayWidth;
        cursorImage.Width = c.Width * scale;
        cursorImage.Height = c.Height * scale;
        Canvas.SetLeft(cursorImage, lastPointer.X - c.HotX * scale);
        Canvas.SetTop(cursorImage, lastPointer.Y - c.HotY * scale);
        cursorImage.Visibility = Visibility.Visible;
    }

    /// <summary>Hides the Windows pointer over the display while the guest draws its own
    /// (client mode with a guest cursor, or hidden by the guest) or while captured.</summary>
    private void UpdateSystemCursor(bool inside)
    {
        pointerInside = inside;
        bool hide = connection is { State: SpiceConnection.ConnectionState.Connected } &&
                    (PointerCaptured || (inside && connection.MouseMode == SpiceConnection.MouseModes.Client
                                         && (connection.Cursor is not null || connection.CursorHidden)));
        if (hide == systemCursorHidden) return;
        systemCursorHidden = hide;
        ShowCursor(!hide);
    }

    // MARK: Keyboard

    private void OnKey(object sender, KeyRoutedEventArgs e)
    {
        if (connection is not { State: SpiceConnection.ConnectionState.Connected }) return;
        bool down = !e.KeyStatus.IsKeyReleased;
        if (e.Key is VirtualKey.Control or VirtualKey.LeftControl or VirtualKey.RightControl) ctrlDown = down;
        if (e.Key is VirtualKey.Menu or VirtualKey.LeftMenu or VirtualKey.RightMenu) altDown = down;
        e.Handled = true;   // Tab, Alt, arrows… all belong to the guest
        if (PointerCaptured && ctrlDown && altDown && down)
        {
            ReleasePointer();
        }
        int code = (int)e.KeyStatus.ScanCode;
        if (code == 0) return;
        if (e.KeyStatus.IsExtendedKey) code |= 0x100;
        connection.Key(code, down);
    }

    // MARK: Win32

    [StructLayout(LayoutKind.Sequential)] private struct POINT { public int X, Y; }
    [StructLayout(LayoutKind.Sequential)] private struct RECT { public int Left, Top, Right, Bottom; }
    [DllImport("user32.dll")] private static extern bool ClipCursor(ref RECT rect);
    [DllImport("user32.dll")] private static extern bool ClipCursor(IntPtr rect);
    [DllImport("user32.dll")] private static extern bool SetCursorPos(int x, int y);
    [DllImport("user32.dll")] private static extern bool GetCursorPos(out POINT p);
    [DllImport("user32.dll")] private static extern bool ClientToScreen(IntPtr hwnd, ref POINT p);
    [DllImport("user32.dll")] private static extern int ShowCursor(bool show);
}

/// <summary>A restartable one-shot timer (debounce).</summary>
internal sealed class DispatcherTimerLite
{
    private readonly Microsoft.UI.Dispatching.DispatcherQueueTimer timer;

    public DispatcherTimerLite(Microsoft.UI.Dispatching.DispatcherQueue queue, TimeSpan delay, Action action)
    {
        timer = queue.CreateTimer();
        timer.Interval = delay;
        timer.IsRepeating = false;
        timer.Tick += (_, _) => action();
    }

    public void Restart() { timer.Stop(); timer.Start(); }
}
