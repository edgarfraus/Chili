// CSConnection: one SPICE session, driven on the SPICE thread.
// See ChiliSpice.h for the threading model.

#import "ChiliSpice.h"
#import "CSKeymap.h"

#include <os/lock.h>
#include <stdatomic.h>
#include <spice-client.h>
#include <spice/vd_agent.h>

NSNotificationName const CSConnectionDidChangeNotification = @"CSConnectionDidChange";

#pragma mark - SPICE thread

static dispatch_once_t cs_once;

static gpointer cs_thread_main(gpointer unused)
{
    GMainLoop *loop = g_main_loop_new(NULL, FALSE);   // owns the default context
    g_main_loop_run(loop);
    return NULL;
}

void CSSpiceInitialize(NSString *gstPluginDir, NSString *gstScanner, NSString *gstRegistry)
{
    dispatch_once(&cs_once, ^{
        // GStreamer reads these when spice-glib initializes it for audio/video.
        if (gstPluginDir) {
            setenv("GST_PLUGIN_SYSTEM_PATH_1_0", gstPluginDir.fileSystemRepresentation, 1);
            setenv("GST_PLUGIN_PATH_1_0", gstPluginDir.fileSystemRepresentation, 1);
        }
        if (gstScanner) setenv("GST_PLUGIN_SCANNER_1_0", gstScanner.fileSystemRepresentation, 1);
        if (gstRegistry) setenv("GST_REGISTRY_1_0", gstRegistry.fileSystemRepresentation, 1);
        setenv("GST_REGISTRY_FORK", "no", 1);
        g_thread_unref(g_thread_new("chili-spice", cs_thread_main, NULL));
    });
}

static gboolean cs_run_block(gpointer data)
{
    dispatch_block_t block = (__bridge_transfer dispatch_block_t)data;
    block();
    return G_SOURCE_REMOVE;
}

/// Runs `block` on the SPICE thread (asynchronously).
static void cs_spice_async(dispatch_block_t block)
{
    CSSpiceInitialize(nil, nil, nil);
    g_main_context_invoke(NULL, cs_run_block, (__bridge_retained void *)[block copy]);
}

#pragma mark - CSConnection

static void cs_teardown(SpiceSession *session, SpiceAudio *audio, GPtrArray *channels, void *me);

@interface CSConnection () {
    // Owned by the SPICE thread.
    SpiceSession *_session;
    SpiceMainChannel *_mainChannel;
    SpiceInputsChannel *_inputs;
    SpiceAudio *_audio;
    GPtrArray *_channels;                 // refs to every channel we attached handlers to
    NSMutableSet<NSNumber *> *_pressedKeys;
    NSDictionary<NSNumber *, NSData *> *_offeredClipboard;   // type -> data we grabbed with

    // Frame buffer handed over by the display channel; guarded by _frameLock.
    os_unfair_lock _frameLock;
    void *_frameData;
    int _frameWidth, _frameHeight, _frameStride, _frameFormat;
    atomic_bool _frameDirty;

    // Main thread.
    NSTimer *_pasteboardTimer;
    NSInteger _pasteboardChangeCount;
}
@property (nonatomic, readwrite) CSConnectionState state;
@property (nonatomic, readwrite, nullable) NSString *errorMessage;
@property (nonatomic, readwrite) CSMouseMode mouseMode;
@property (nonatomic, readwrite) BOOL agentConnected;
@property (nonatomic, readwrite) CGSize displaySize;
@property (nonatomic, readwrite) BOOL displayReady;
@property (nonatomic, readwrite, nullable) NSCursor *cursor;
@property (nonatomic, readwrite) BOOL cursorHidden;
@property (nonatomic) BOOL guestUsesCRLF;
@end

@implementation CSConnection

- (instancetype)initWithOptions:(NSDictionary<NSString *, NSString *> *)options
{
    if ((self = [super init])) {
        _options = [options copy];
        _title = options[@"title"].length ? options[@"title"] : (options[@"host"] ?: @"SPICE");
        _state = CSConnectionStateDisconnected;
        _mouseMode = CSMouseModeServer;
        _shareClipboard = YES;
        _enableAudio = YES;
        _frameLock = OS_UNFAIR_LOCK_INIT;
        _pressedKeys = [NSMutableSet set];
    }
    return self;
}

- (void)dealloc
{
    [_pasteboardTimer invalidate];
    // Normally -finishWithError: already ran; this covers a connection dropped
    // while still connected. Handlers must go before `self` does.
    cs_teardown(_session, _audio, _channels, (__bridge void *)self);
}

/// Detaches our signal handlers right away (safe even during an emission) and
/// releases the spice-glib objects on a later iteration of the SPICE loop.
static void cs_teardown(SpiceSession *session, SpiceAudio *audio, GPtrArray *channels, void *me)
{
    if (channels) {
        for (guint i = 0; i < channels->len; i++)
            g_signal_handlers_disconnect_by_data(channels->pdata[i], me);
    }
    if (session) g_signal_handlers_disconnect_by_data(session, me);
    if (!session && !audio && !channels) return;
    cs_spice_async(^{
        if (session) spice_session_disconnect(session);
        if (channels) g_ptr_array_unref(channels);
        if (audio) g_object_unref(audio);
        if (session) g_object_unref(session);
    });
}

- (void)post
{
    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter] postNotificationName:CSConnectionDidChangeNotification object:self];
    });
}

#pragma mark Connect / disconnect

static GByteArray *cs_byte_array(NSString *s)
{
    NSData *d = [s dataUsingEncoding:NSUTF8StringEncoding];
    GByteArray *a = g_byte_array_new();
    g_byte_array_append(a, d.bytes, (guint)d.length);
    return a;
}

- (void)connect
{
    if (self.state != CSConnectionStateDisconnected) return;
    self.state = CSConnectionStateConnecting;
    self.errorMessage = nil;
    [self post];

    NSDictionary<NSString *, NSString *> *o = self.options;
    cs_spice_async(^{
        SpiceSession *s = spice_session_new();
        self->_session = s;
        self->_channels = g_ptr_array_new_with_free_func(g_object_unref);
        void *me = (__bridge void *)self;

        NSString *host = o[@"host"];
        if (host.length) g_object_set(s, "host", host.UTF8String, NULL);
        if (o[@"port"].length && o[@"port"].intValue > 0) g_object_set(s, "port", o[@"port"].UTF8String, NULL);
        if (o[@"tls-port"].length && o[@"tls-port"].intValue > 0) g_object_set(s, "tls-port", o[@"tls-port"].UTF8String, NULL);
        if (o[@"password"].length) g_object_set(s, "password", o[@"password"].UTF8String, NULL);
        if (o[@"proxy"].length) g_object_set(s, "proxy", o[@"proxy"].UTF8String, NULL);
        if (o[@"host-subject"].length) g_object_set(s, "cert-subject", o[@"host-subject"].UTF8String, NULL);
        if (o[@"ca"].length) {
            // .vv files store the PEM on one line with literal "\n".
            NSString *pem = [o[@"ca"] stringByReplacingOccurrencesOfString:@"\\n" withString:@"\n"];
            GByteArray *ca = cs_byte_array(pem);
            g_object_set(s, "ca", ca, NULL);
            g_byte_array_unref(ca);
        }
        if (o[@"secure-channels"].length) {
            gchar **channels = g_strsplit(o[@"secure-channels"].UTF8String, ";", -1);
            g_object_set(s, "secure-channels", channels, NULL);
            g_strfreev(channels);
        }
        g_object_set(s, "enable-usbredir", FALSE, "enable-smartcard", FALSE, NULL);

        g_signal_connect(s, "channel-new", G_CALLBACK(cs_channel_new), me);
        g_signal_connect(s, "disconnected", G_CALLBACK(cs_session_disconnected), me);

        if (self.enableAudio) self->_audio = spice_audio_get(s, NULL);

        if (!spice_session_connect(s)) {
            [self finishWithError:NSLocalizedString(@"Could not start the connection.", nil)];
        }
    });
}

- (void)disconnect
{
    cs_spice_async(^{
        if (self->_session) spice_session_disconnect(self->_session);
    });
}

/// SPICE thread. Drops every reference to spice-glib objects.
- (void)finishWithError:(nullable NSString *)message
{
    SpiceSession *s = _session;
    if (!s) return;
    cs_teardown(s, _audio, _channels, (__bridge void *)self);
    _session = NULL;
    _audio = NULL;
    _channels = NULL;
    _mainChannel = NULL;
    _inputs = NULL;

    os_unfair_lock_lock(&_frameLock);
    _frameData = NULL;
    os_unfair_lock_unlock(&_frameLock);

    dispatch_async(dispatch_get_main_queue(), ^{
        if (message && !self.errorMessage) self.errorMessage = message;
        self.state = CSConnectionStateDisconnected;
        self.displayReady = NO;
        [self->_pasteboardTimer invalidate];
        self->_pasteboardTimer = nil;
        [[NSNotificationCenter defaultCenter] postNotificationName:CSConnectionDidChangeNotification object:self];
    });
}

static void cs_session_disconnected(SpiceSession *session, gpointer data)
{
    [(__bridge CSConnection *)data finishWithError:nil];
}

static NSString *cs_describe_event(SpiceChannel *channel, SpiceChannelEvent event)
{
    const GError *error = spice_channel_get_error(channel);
    NSString *detail = error ? @(error->message) : nil;
    NSString *base;
    switch (event) {
    case SPICE_CHANNEL_ERROR_AUTH:
        base = NSLocalizedString(@"Authentication failed: the password or ticket was refused (Proxmox tickets expire after about 30 seconds).", nil);
        break;
    case SPICE_CHANNEL_ERROR_TLS:
        base = NSLocalizedString(@"Secure connection failed (TLS).", nil);
        break;
    case SPICE_CHANNEL_ERROR_CONNECT:
        base = NSLocalizedString(@"Could not connect to the SPICE server.", nil);
        break;
    case SPICE_CHANNEL_ERROR_LINK:
        base = NSLocalizedString(@"The SPICE server refused the connection.", nil);
        break;
    default:
        base = NSLocalizedString(@"The connection was interrupted.", nil);
        break;
    }
    return detail.length ? [NSString stringWithFormat:@"%@\n\n%@", base, detail] : base;
}

static void cs_channel_event(SpiceChannel *channel, SpiceChannelEvent event, gpointer data)
{
    CSConnection *self = (__bridge CSConnection *)data;
    if (!SPICE_IS_MAIN_CHANNEL(channel)) return;
    switch (event) {
    case SPICE_CHANNEL_OPENED: {
        dispatch_async(dispatch_get_main_queue(), ^{
            self.state = CSConnectionStateConnected;
            [self startPasteboardWatch];
            [[NSNotificationCenter defaultCenter] postNotificationName:CSConnectionDidChangeNotification object:self];
        });
        break;
    }
    case SPICE_CHANNEL_CLOSED:
        [self finishWithError:nil];
        break;
    case SPICE_CHANNEL_ERROR_CONNECT:
    case SPICE_CHANNEL_ERROR_TLS:
    case SPICE_CHANNEL_ERROR_LINK:
    case SPICE_CHANNEL_ERROR_AUTH:
    case SPICE_CHANNEL_ERROR_IO:
        [self finishWithError:cs_describe_event(channel, event)];
        break;
    default:
        break;
    }
}

#pragma mark Channels

static void cs_channel_new(SpiceSession *session, SpiceChannel *channel, gpointer data)
{
    CSConnection *self = (__bridge CSConnection *)data;
    int id = 0;
    g_object_get(channel, "channel-id", &id, NULL);
    if (self->_channels) g_ptr_array_add(self->_channels, g_object_ref(channel));
    g_signal_connect(channel, "channel-event", G_CALLBACK(cs_channel_event), data);

    if (SPICE_IS_MAIN_CHANNEL(channel)) {
        self->_mainChannel = SPICE_MAIN_CHANNEL(channel);
        g_signal_connect(channel, "main-mouse-update", G_CALLBACK(cs_mouse_update), data);
        g_signal_connect(channel, "main-agent-update", G_CALLBACK(cs_agent_update), data);
        g_signal_connect(channel, "main-clipboard-selection-grab", G_CALLBACK(cs_clipboard_grab), data);
        g_signal_connect(channel, "main-clipboard-selection", G_CALLBACK(cs_clipboard_data), data);
        g_signal_connect(channel, "main-clipboard-selection-request", G_CALLBACK(cs_clipboard_request), data);
        cs_mouse_update(channel, data);
    } else if (SPICE_IS_DISPLAY_CHANNEL(channel) && id == 0) {
        g_signal_connect(channel, "display-primary-create", G_CALLBACK(cs_primary_create), data);
        g_signal_connect(channel, "display-primary-destroy", G_CALLBACK(cs_primary_destroy), data);
        g_signal_connect(channel, "display-invalidate", G_CALLBACK(cs_invalidate), data);
        g_signal_connect(channel, "display-mark", G_CALLBACK(cs_mark), data);
        spice_channel_connect(channel);
    } else if (SPICE_IS_INPUTS_CHANNEL(channel)) {
        self->_inputs = SPICE_INPUTS_CHANNEL(channel);
        spice_channel_connect(channel);
    } else if (SPICE_IS_CURSOR_CHANNEL(channel) && id == 0) {
        g_signal_connect(channel, "notify::cursor", G_CALLBACK(cs_cursor_changed), data);
        g_signal_connect(channel, "cursor-hide", G_CALLBACK(cs_cursor_hide), data);
        g_signal_connect(channel, "cursor-reset", G_CALLBACK(cs_cursor_reset), data);
        spice_channel_connect(channel);
    }
    // Playback/record channels are connected by SpiceAudio itself.
}

static void cs_mouse_update(SpiceChannel *channel, gpointer data)
{
    CSConnection *self = (__bridge CSConnection *)data;
    int mode = 0;
    g_object_get(channel, "mouse-mode", &mode, NULL);
    dispatch_async(dispatch_get_main_queue(), ^{
        self.mouseMode = mode == SPICE_MOUSE_MODE_CLIENT ? CSMouseModeClient : CSMouseModeServer;
        [[NSNotificationCenter defaultCenter] postNotificationName:CSConnectionDidChangeNotification object:self];
    });
}

static void cs_agent_update(SpiceChannel *channel, gpointer data)
{
    CSConnection *self = (__bridge CSConnection *)data;
    gboolean connected = FALSE;
    g_object_get(channel, "agent-connected", &connected, NULL);
    BOOL crlf = connected && spice_main_channel_agent_test_capability(SPICE_MAIN_CHANNEL(channel),
                                                                      VD_AGENT_CAP_GUEST_LINEEND_CRLF);
    dispatch_async(dispatch_get_main_queue(), ^{
        self.agentConnected = connected;
        self.guestUsesCRLF = crlf;
        self->_pasteboardChangeCount = -1;   // offer the current Mac clipboard to the new agent
        [[NSNotificationCenter defaultCenter] postNotificationName:CSConnectionDidChangeNotification object:self];
    });
}

#pragma mark Display

static void cs_primary_create(SpiceChannel *channel, gint format, gint width, gint height, gint stride,
                              gint shmid, gpointer imgdata, gpointer data)
{
    CSConnection *self = (__bridge CSConnection *)data;
    os_unfair_lock_lock(&self->_frameLock);
    self->_frameData = imgdata;
    self->_frameWidth = width;
    self->_frameHeight = height;
    self->_frameStride = stride;
    self->_frameFormat = format;
    os_unfair_lock_unlock(&self->_frameLock);
    atomic_store(&self->_frameDirty, true);
    dispatch_async(dispatch_get_main_queue(), ^{
        self.displaySize = CGSizeMake(width, height);
        self.displayReady = YES;
        [[NSNotificationCenter defaultCenter] postNotificationName:CSConnectionDidChangeNotification object:self];
    });
}

static void cs_primary_destroy(SpiceChannel *channel, gpointer data)
{
    CSConnection *self = (__bridge CSConnection *)data;
    // Taking the lock waits for any frame copy in progress before the buffer is freed.
    os_unfair_lock_lock(&self->_frameLock);
    self->_frameData = NULL;
    os_unfair_lock_unlock(&self->_frameLock);
}

static void cs_invalidate(SpiceChannel *channel, gint x, gint y, gint w, gint h, gpointer data)
{
    CSConnection *self = (__bridge CSConnection *)data;
    atomic_store(&self->_frameDirty, true);
}

static void cs_mark(SpiceChannel *channel, gint mark, gpointer data)
{
    CSConnection *self = (__bridge CSConnection *)data;
    dispatch_async(dispatch_get_main_queue(), ^{
        self.displayReady = mark != 0;
        [[NSNotificationCenter defaultCenter] postNotificationName:CSConnectionDidChangeNotification object:self];
    });
}

static void cs_release_cfdata(void *info, const void *data, size_t size)
{
    CFRelease((CFDataRef)info);
}

- (CGImageRef)copyFrameIfChanged:(BOOL)onlyIfChanged
{
    if (onlyIfChanged && !atomic_exchange(&_frameDirty, false)) return NULL;
    if (!onlyIfChanged) atomic_store(&_frameDirty, false);

    os_unfair_lock_lock(&_frameLock);
    if (!_frameData || _frameWidth <= 0 || _frameHeight <= 0) {
        os_unfair_lock_unlock(&_frameLock);
        return NULL;
    }
    int w = _frameWidth, h = _frameHeight, stride = _frameStride, format = _frameFormat;
    CFMutableDataRef copy = NULL;
    size_t outStride = stride;
    if (format == SPICE_SURFACE_FMT_16_565) {
        // CoreGraphics has no RGB565: expand to xRGB.
        outStride = (size_t)w * 4;
        copy = CFDataCreateMutable(NULL, outStride * h);
        CFDataSetLength(copy, outStride * h);
        uint32_t *dst = (uint32_t *)CFDataGetMutableBytePtr(copy);
        for (int y = 0; y < h; y++) {
            const uint16_t *src = (const uint16_t *)((const uint8_t *)_frameData + (size_t)y * stride);
            for (int x = 0; x < w; x++) {
                uint16_t p = src[x];
                uint32_t r = (p >> 11) & 0x1f, g = (p >> 5) & 0x3f, b = p & 0x1f;
                dst[(size_t)y * w + x] = ((r << 3 | r >> 2) << 16) | ((g << 2 | g >> 4) << 8) | (b << 3 | b >> 2);
            }
        }
        format = SPICE_SURFACE_FMT_32_xRGB;
    } else {
        copy = CFDataCreateMutable(NULL, (CFIndex)stride * h);
        CFDataAppendBytes(copy, _frameData, (CFIndex)stride * h);
    }
    os_unfair_lock_unlock(&_frameLock);

    CGDataProviderRef provider = CGDataProviderCreateWithData((void *)copy, CFDataGetBytePtr(copy),
                                                              CFDataGetLength(copy), cs_release_cfdata);
    CGColorSpaceRef cs = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGImageRef image;
    if (format == SPICE_SURFACE_FMT_16_555) {
        image = CGImageCreate(w, h, 5, 16, outStride, cs,
                              kCGBitmapByteOrder16Little | kCGImageAlphaNoneSkipFirst,
                              provider, NULL, false, kCGRenderingIntentDefault);
    } else {
        image = CGImageCreate(w, h, 8, 32, outStride, cs,
                              kCGBitmapByteOrder32Little | kCGImageAlphaNoneSkipFirst,
                              provider, NULL, false, kCGRenderingIntentDefault);
    }
    CGColorSpaceRelease(cs);
    CGDataProviderRelease(provider);
    return image;
}

#pragma mark Cursor

static void cs_cursor_changed(SpiceChannel *channel, GParamSpec *pspec, gpointer data)
{
    CSConnection *self = (__bridge CSConnection *)data;
    SpiceCursorShape *shape = NULL;
    g_object_get(channel, "cursor", &shape, NULL);
    NSCursor *cursor = nil;
    if (shape && shape->data && shape->width > 0 && shape->height > 0) {
        NSBitmapImageRep *rep = [[NSBitmapImageRep alloc]
            initWithBitmapDataPlanes:NULL pixelsWide:shape->width pixelsHigh:shape->height
                       bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES isPlanar:NO
                      colorSpaceName:NSDeviceRGBColorSpace
                        bitmapFormat:NSBitmapFormatAlphaNonpremultiplied
                         bytesPerRow:shape->width * 4 bitsPerPixel:32];
        // spice-glib hands out 0xAARRGGBB words, i.e. BGRA bytes on little endian.
        const uint8_t *src = shape->data;
        uint8_t *dst = rep.bitmapData;
        for (int i = 0; i < shape->width * shape->height; i++) {
            dst[i * 4 + 0] = src[i * 4 + 2];
            dst[i * 4 + 1] = src[i * 4 + 1];
            dst[i * 4 + 2] = src[i * 4 + 0];
            dst[i * 4 + 3] = src[i * 4 + 3];
        }
        NSImage *image = [[NSImage alloc] initWithSize:NSMakeSize(shape->width, shape->height)];
        [image addRepresentation:rep];
        cursor = [[NSCursor alloc] initWithImage:image hotSpot:NSMakePoint(shape->hot_spot_x, shape->hot_spot_y)];
    }
    if (shape) g_boxed_free(SPICE_TYPE_CURSOR_SHAPE, shape);
    dispatch_async(dispatch_get_main_queue(), ^{
        self.cursor = cursor;
        self.cursorHidden = NO;
        [[NSNotificationCenter defaultCenter] postNotificationName:CSConnectionDidChangeNotification object:self];
    });
}

static void cs_cursor_hide(SpiceChannel *channel, gpointer data)
{
    CSConnection *self = (__bridge CSConnection *)data;
    dispatch_async(dispatch_get_main_queue(), ^{
        self.cursorHidden = YES;
        [[NSNotificationCenter defaultCenter] postNotificationName:CSConnectionDidChangeNotification object:self];
    });
}

static void cs_cursor_reset(SpiceChannel *channel, gpointer data)
{
    CSConnection *self = (__bridge CSConnection *)data;
    dispatch_async(dispatch_get_main_queue(), ^{
        self.cursor = nil;
        self.cursorHidden = NO;
        [[NSNotificationCenter defaultCenter] postNotificationName:CSConnectionDidChangeNotification object:self];
    });
}

#pragma mark Input

- (void)sendKey:(uint16_t)scancode pressed:(BOOL)pressed
{
    if (!scancode) return;
    cs_spice_async(^{
        if (!self->_inputs) return;
        if (pressed) {
            [self->_pressedKeys addObject:@(scancode)];
            spice_inputs_channel_key_press(self->_inputs, scancode);
        } else {
            [self->_pressedKeys removeObject:@(scancode)];
            spice_inputs_channel_key_release(self->_inputs, scancode);
        }
    });
}

- (void)sendMacKeyCode:(uint16_t)keyCode pressed:(BOOL)pressed
{
    if (keyCode < sizeof(cs_keymap_osx2xtkbd) / sizeof(cs_keymap_osx2xtkbd[0]))
        [self sendKey:cs_keymap_osx2xtkbd[keyCode] pressed:pressed];
}

- (void)sendCtrlAltDel
{
    const uint16_t ctrl = 0x1d, alt = 0x38, del = 0x153;
    [self sendKey:ctrl pressed:YES];
    [self sendKey:alt pressed:YES];
    [self sendKey:del pressed:YES];
    [self sendKey:del pressed:NO];
    [self sendKey:alt pressed:NO];
    [self sendKey:ctrl pressed:NO];
}

- (void)releaseAllKeys
{
    cs_spice_async(^{
        if (!self->_inputs) return;
        for (NSNumber *k in self->_pressedKeys)
            spice_inputs_channel_key_release(self->_inputs, k.unsignedIntValue);
        [self->_pressedKeys removeAllObjects];
    });
}

- (void)sendMotionDx:(int)dx dy:(int)dy buttonMask:(int)mask
{
    cs_spice_async(^{
        if (self->_inputs) spice_inputs_channel_motion(self->_inputs, dx, dy, mask);
    });
}

- (void)sendPositionX:(int)x y:(int)y buttonMask:(int)mask
{
    cs_spice_async(^{
        if (self->_inputs) spice_inputs_channel_position(self->_inputs, x, y, 0, mask);
    });
}

- (void)sendButton:(int)button pressed:(BOOL)pressed buttonMask:(int)mask
{
    cs_spice_async(^{
        if (!self->_inputs) return;
        if (pressed) spice_inputs_channel_button_press(self->_inputs, button, mask);
        else spice_inputs_channel_button_release(self->_inputs, button, mask);
    });
}

- (void)requestResolutionWidth:(int)width height:(int)height
{
    if (width < 320 || height < 200) return;
    width &= ~1;   // some guest drivers dislike odd sizes
    cs_spice_async(^{
        SpiceMainChannel *main = self->_mainChannel;
        if (!main) return;
        gboolean agent = FALSE;
        g_object_get(main, "agent-connected", &agent, NULL);
        if (!agent) return;
        spice_main_channel_update_display_enabled(main, 0, TRUE, FALSE);
        spice_main_channel_update_display(main, 0, 0, 0, width, height, TRUE);
    });
}

#pragma mark Clipboard

// Guest -> Mac: the guest owns the clipboard; fetch its content right away.
static gboolean cs_clipboard_grab(SpiceMainChannel *main, guint selection, gpointer types, guint ntypes,
                                  gpointer data)
{
    CSConnection *self = (__bridge CSConnection *)data;
    if (!self.shareClipboard || selection != VD_AGENT_CLIPBOARD_SELECTION_CLIPBOARD) return TRUE;
    const guint32 *t = types;
    guint32 wanted = VD_AGENT_CLIPBOARD_NONE;
    for (guint i = 0; i < ntypes; i++) {
        if (t[i] == VD_AGENT_CLIPBOARD_UTF8_TEXT) { wanted = t[i]; break; }
        if (t[i] == VD_AGENT_CLIPBOARD_IMAGE_PNG) wanted = t[i];
    }
    if (wanted != VD_AGENT_CLIPBOARD_NONE) spice_main_channel_clipboard_selection_request(main, selection, wanted);
    return TRUE;
}

static void cs_clipboard_data(SpiceMainChannel *main, guint selection, guint type, gpointer bytes, guint size,
                              gpointer data)
{
    CSConnection *self = (__bridge CSConnection *)data;
    if (!self.shareClipboard || selection != VD_AGENT_CLIPBOARD_SELECTION_CLIPBOARD || !bytes) return;
    NSData *payload = [NSData dataWithBytes:bytes length:size];
    dispatch_async(dispatch_get_main_queue(), ^{
        NSPasteboard *pb = [NSPasteboard generalPasteboard];
        if (type == VD_AGENT_CLIPBOARD_UTF8_TEXT) {
            NSString *text = [[NSString alloc] initWithData:payload encoding:NSUTF8StringEncoding];
            text = [text stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"\0"]];
            if (!text) return;
            text = [text stringByReplacingOccurrencesOfString:@"\r\n" withString:@"\n"];
            [pb clearContents];
            [pb setString:text forType:NSPasteboardTypeString];
        } else if (type == VD_AGENT_CLIPBOARD_IMAGE_PNG) {
            [pb clearContents];
            [pb setData:payload forType:NSPasteboardTypePNG];
        }
        self->_pasteboardChangeCount = pb.changeCount;   // don't bounce it back
    });
}

// Mac -> guest: the guest asks for the data we announced.
static gboolean cs_clipboard_request(SpiceMainChannel *main, guint selection, guint type, gpointer data)
{
    CSConnection *self = (__bridge CSConnection *)data;
    NSData *payload = self->_offeredClipboard[@(type)];
    if (!self.shareClipboard || !payload) return FALSE;
    spice_main_channel_clipboard_selection_notify(main, selection, type, payload.bytes, payload.length);
    return TRUE;
}

- (void)startPasteboardWatch
{
    [_pasteboardTimer invalidate];
    _pasteboardChangeCount = -1;
    __weak CSConnection *weakSelf = self;
    _pasteboardTimer = [NSTimer scheduledTimerWithTimeInterval:0.5 repeats:YES block:^(NSTimer *t) {
        [weakSelf checkPasteboard];
    }];
}

- (void)checkPasteboard
{
    NSPasteboard *pb = [NSPasteboard generalPasteboard];
    if (!self.shareClipboard || !self.agentConnected || pb.changeCount == _pasteboardChangeCount) return;
    _pasteboardChangeCount = pb.changeCount;

    NSMutableDictionary<NSNumber *, NSData *> *offer = [NSMutableDictionary dictionary];
    NSString *text = [pb stringForType:NSPasteboardTypeString];
    if (text) {
        if (self.guestUsesCRLF) {
            text = [[text stringByReplacingOccurrencesOfString:@"\r\n" withString:@"\n"]
                    stringByReplacingOccurrencesOfString:@"\n" withString:@"\r\n"];
        }
        offer[@(VD_AGENT_CLIPBOARD_UTF8_TEXT)] = [text dataUsingEncoding:NSUTF8StringEncoding];
    } else {
        NSData *png = [pb dataForType:NSPasteboardTypePNG];
        if (!png) {
            NSData *tiff = [pb dataForType:NSPasteboardTypeTIFF];
            if (tiff) png = [[NSBitmapImageRep imageRepWithData:tiff] representationUsingType:NSBitmapImageFileTypePNG
                                                                                    properties:@{}];
        }
        if (png) offer[@(VD_AGENT_CLIPBOARD_IMAGE_PNG)] = png;
    }
    if (!offer.count) return;

    cs_spice_async(^{
        SpiceMainChannel *main = self->_mainChannel;
        if (!main || !spice_main_channel_agent_test_capability(main, VD_AGENT_CAP_CLIPBOARD_BY_DEMAND)) return;
        self->_offeredClipboard = offer;
        guint32 types[2];
        int n = 0;
        for (NSNumber *t in offer) types[n++] = t.unsignedIntValue;
        spice_main_channel_clipboard_selection_grab(main, VD_AGENT_CLIPBOARD_SELECTION_CLIPBOARD, types, n);
    });
}

@end
