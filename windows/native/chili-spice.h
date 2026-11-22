/* Native SPICE client for Chili on Windows: a flat C API over spice-client-glib (no GTK),
 * called from C# through P/Invoke. Port of launcher/SpiceKit (macOS).
 *
 * Threading: spice-glib runs on its own GLib main loop thread. Every function here may be
 * called from any thread; calls into spice-glib are marshalled to the SPICE thread.
 * Events are delivered on the SPICE thread through the callback given to cs_new: copy
 * what you need and return quickly. cs_copy_frame is the only call that touches the
 * frame buffer from the caller's thread (under a lock). */
#pragma once
#include <stdint.h>

#ifdef CHILI_SPICE_BUILD
#define CS_API __declspec(dllexport)
#else
#define CS_API __declspec(dllimport)
#endif

typedef struct cs_conn cs_conn;

enum cs_event {
    CS_EVENT_STATE = 1,          /* a: 0 connecting, 1 connected, 2 disconnected; data: error text or NULL */
    CS_EVENT_DISPLAY = 2,        /* a: width, b: height (new primary surface) */
    CS_EVENT_MARK = 3,           /* a: 1 display content valid, 0 not (e.g. guest rebooting) */
    CS_EVENT_MOUSE_MODE = 4,     /* a: 1 server (relative), 2 client (absolute) */
    CS_EVENT_AGENT = 5,          /* a: agent connected, b: guest wants CRLF line ends */
    CS_EVENT_CURSOR = 6,         /* a: w | h << 16, b: hot_x | hot_y << 16, data: BGRA pixels (straight alpha) */
    CS_EVENT_CURSOR_HIDE = 7,
    CS_EVENT_CURSOR_RESET = 8,
    CS_EVENT_CLIPBOARD_TEXT = 9, /* data: UTF-8 text from the guest, size bytes */
    CS_EVENT_CLIPBOARD_PNG = 10, /* data: PNG image from the guest, size bytes */
    CS_EVENT_INVALIDATE = 11,    /* the frame changed: call cs_copy_frame */
};

typedef void (*cs_event_cb)(void *user, int event, int a, int b, const void *data, int size);

/* Starts the SPICE thread. Set GStreamer's environment (GST_PLUGIN_SYSTEM_PATH_1_0,
 * GST_REGISTRY_1_0, GST_REGISTRY_FORK=no) before the first call. */
CS_API void cs_initialize(void);

CS_API cs_conn *cs_new(cs_event_cb callback, void *user);
/* Options are the keys of a virt-viewer .vv file: host, port, tls-port, password, ca,
 * host-subject, proxy, secure-channels. Set them before cs_connect. */
CS_API void cs_set_option(cs_conn *c, const char *key, const char *value);
CS_API void cs_connect(cs_conn *c, int audio);
CS_API void cs_disconnect(cs_conn *c);
/* Tears the connection down. No callback runs after the teardown has been processed on
 * the SPICE thread; don't use `c` after this call. */
CS_API void cs_free(cs_conn *c);

/* Copies the current frame as opaque BGRA into dst (stride bytes per row), at most
 * max_w x max_h pixels. Returns 1 if copied, 0 if there is no frame (or, with
 * only_if_changed, nothing changed since the last copy). */
CS_API int cs_copy_frame(cs_conn *c, void *dst, int stride, int max_w, int max_h, int only_if_changed);
CS_API int cs_frame_size(cs_conn *c, int *width, int *height);

/* Input. Scancodes are PC set 1, 0x100 | code for extended (E0) keys.
 * Buttons: 1 left, 2 middle, 3 right, 4 wheel up, 5 wheel down.
 * Masks: bit 0 left, bit 1 middle, bit 2 right. */
CS_API void cs_key(cs_conn *c, int scancode, int pressed);
CS_API void cs_release_all_keys(cs_conn *c);
CS_API void cs_ctrl_alt_del(cs_conn *c);
CS_API void cs_motion(cs_conn *c, int dx, int dy, int mask);
CS_API void cs_position(cs_conn *c, int x, int y, int mask);
CS_API void cs_button(cs_conn *c, int button, int pressed, int mask);

/* Asks the guest agent for this resolution (no-op without agent). */
CS_API void cs_request_resolution(cs_conn *c, int width, int height);

/* Clipboard sharing (needs the guest agent). Default on. */
CS_API void cs_set_share_clipboard(cs_conn *c, int share);
/* Announces host clipboard content to the guest; the data is sent when it asks. */
CS_API void cs_clipboard_offer(cs_conn *c, const char *utf8_text, const void *png, int png_size);
