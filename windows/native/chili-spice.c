/* chili-spice.dll: see chili-spice.h. Port of launcher/SpiceKit/CSConnection.m. */
#define CHILI_SPICE_BUILD
#include "chili-spice.h"

#include <string.h>
#include <spice-client.h>
#include <spice/vd_agent.h>

struct cs_conn {
    cs_event_cb cb;
    void *user;

    /* SPICE thread only. */
    GHashTable *options;
    SpiceSession *session;
    SpiceMainChannel *main;
    SpiceInputsChannel *inputs;
    SpiceAudio *audio;
    GPtrArray *channels;        /* refs to every channel we attached handlers to */
    guint8 pressed[512];
    GBytes *offer_text, *offer_png;
    gboolean freed;

    gint share_clipboard;       /* atomic */

    /* Frame buffer handed over by the display channel; guarded by frame_lock. */
    GMutex frame_lock;
    const guint8 *frame;
    int frame_w, frame_h, frame_stride, frame_format;
    gint dirty;                 /* atomic */
};

/* ---- SPICE thread ------------------------------------------------------------------ */

static gpointer thread_main(gpointer unused)
{
    (void)unused;
    /* spice-glib attaches its sources to the default context: this thread runs it. */
    GMainLoop *loop = g_main_loop_new(NULL, FALSE);
    g_main_loop_run(loop);
    return NULL;
}

CS_API void cs_initialize(void)
{
    static gsize once = 0;
    if (g_once_init_enter(&once)) {
        g_thread_unref(g_thread_new("chili-spice", thread_main, NULL));
        g_once_init_leave(&once, 1);
    }
}

typedef struct call call;
typedef void (*call_fn)(cs_conn *c, call *k);
struct call {
    cs_conn *c;
    call_fn fn;
    int a, b, d;
    char *s1, *s2;
    GBytes *bytes;
};

static void do_free(cs_conn *c, call *k);

static gboolean run_call(gpointer p)
{
    call *k = p;
    if (!k->c->freed || k->fn == do_free) k->fn(k->c, k);
    g_free(k->s1);
    g_free(k->s2);
    if (k->bytes) g_bytes_unref(k->bytes);
    g_free(k);
    return G_SOURCE_REMOVE;
}

/* Queues fn on the SPICE thread. (Not g_main_context_invoke: that runs the function on the
 * caller's thread when nobody owns the context yet.) Calls run in order. */
static void post(cs_conn *c, call_fn fn, int a, int b, int d, const char *s1, const char *s2, GBytes *bytes)
{
    cs_initialize();
    call *k = g_new0(call, 1);
    k->c = c;
    k->fn = fn;
    k->a = a;
    k->b = b;
    k->d = d;
    k->s1 = g_strdup(s1);
    k->s2 = g_strdup(s2);
    k->bytes = bytes;
    GSource *src = g_idle_source_new();
    g_source_set_priority(src, G_PRIORITY_DEFAULT);
    g_source_set_callback(src, run_call, k, NULL);
    g_source_attach(src, NULL);
    g_source_unref(src);
}

static void emit(cs_conn *c, int event, int a, int b, const void *data, int size)
{
    if (!c->freed && c->cb) c->cb(c->user, event, a, b, data, size);
}

/* ---- Teardown ---------------------------------------------------------------------- */

static gboolean unref_later(gpointer p)
{
    g_object_unref(p);
    return G_SOURCE_REMOVE;
}

/* Detaches our handlers right away (safe during an emission) and releases the session
 * on a later iteration of the loop. */
static void teardown(cs_conn *c)
{
    if (c->channels) {
        for (guint i = 0; i < c->channels->len; i++)
            g_signal_handlers_disconnect_by_data(c->channels->pdata[i], c);
        g_ptr_array_unref(c->channels);
        c->channels = NULL;
    }
    if (c->session) {
        g_signal_handlers_disconnect_by_data(c->session, c);
        spice_session_disconnect(c->session);
        /* spice_audio_get() is (transfer none): the session owns the SpiceAudio. */
        g_idle_add(unref_later, c->session);
        c->session = NULL;
    }
    c->audio = NULL;
    c->main = NULL;
    c->inputs = NULL;
    memset(c->pressed, 0, sizeof c->pressed);

    g_mutex_lock(&c->frame_lock);
    c->frame = NULL;
    g_mutex_unlock(&c->frame_lock);
}

static void finish(cs_conn *c, const char *message)
{
    if (!c->session) return;
    teardown(c);
    emit(c, CS_EVENT_STATE, 2, 0, message, message ? (int)strlen(message) : 0);
}

static void on_session_disconnected(SpiceSession *s, gpointer data)
{
    (void)s;
    finish(data, NULL);
}

static const char *describe_event(SpiceChannelEvent event)
{
    switch (event) {
    case SPICE_CHANNEL_ERROR_AUTH:
        return "Authentication failed: the password or ticket was refused (Proxmox tickets expire after about 30 seconds).";
    case SPICE_CHANNEL_ERROR_TLS: return "Secure connection failed (TLS).";
    case SPICE_CHANNEL_ERROR_CONNECT: return "Could not connect to the SPICE server.";
    case SPICE_CHANNEL_ERROR_LINK: return "The SPICE server refused the connection.";
    default: return "The connection was interrupted.";
    }
}

static void on_channel_event(SpiceChannel *channel, SpiceChannelEvent event, gpointer data)
{
    cs_conn *c = data;
    if (!SPICE_IS_MAIN_CHANNEL(channel)) return;
    switch (event) {
    case SPICE_CHANNEL_OPENED:
        emit(c, CS_EVENT_STATE, 1, 0, NULL, 0);
        break;
    case SPICE_CHANNEL_CLOSED:
        finish(c, NULL);
        break;
    case SPICE_CHANNEL_ERROR_CONNECT:
    case SPICE_CHANNEL_ERROR_TLS:
    case SPICE_CHANNEL_ERROR_LINK:
    case SPICE_CHANNEL_ERROR_AUTH:
    case SPICE_CHANNEL_ERROR_IO: {
        /* The English reason is the key the app translates; the detail follows after "\n\n". */
        const GError *error = spice_channel_get_error(channel);
        char *msg = error ? g_strdup_printf("%s\n\n%s", describe_event(event), error->message)
                          : g_strdup(describe_event(event));
        finish(c, msg);
        g_free(msg);
        break;
    }
    default:
        break;
    }
}

/* ---- Main channel ------------------------------------------------------------------ */

static void on_mouse_update(SpiceChannel *channel, gpointer data)
{
    int mode = 0;
    g_object_get(channel, "mouse-mode", &mode, NULL);
    emit(data, CS_EVENT_MOUSE_MODE, mode == SPICE_MOUSE_MODE_CLIENT ? 2 : 1, 0, NULL, 0);
}

static void on_agent_update(SpiceChannel *channel, gpointer data)
{
    gboolean connected = FALSE;
    g_object_get(channel, "agent-connected", &connected, NULL);
    int crlf = connected && spice_main_channel_agent_test_capability(SPICE_MAIN_CHANNEL(channel),
                                                                     VD_AGENT_CAP_GUEST_LINEEND_CRLF);
    emit(data, CS_EVENT_AGENT, connected ? 1 : 0, crlf, NULL, 0);
}

/* Guest -> host: the guest owns the clipboard; fetch its content right away. */
static gboolean on_clipboard_grab(SpiceMainChannel *main, guint selection, gpointer types, guint ntypes,
                                  gpointer data)
{
    cs_conn *c = data;
    if (!g_atomic_int_get(&c->share_clipboard) || selection != VD_AGENT_CLIPBOARD_SELECTION_CLIPBOARD) return TRUE;
    const guint32 *t = types;
    guint32 wanted = VD_AGENT_CLIPBOARD_NONE;
    for (guint i = 0; i < ntypes; i++) {
        if (t[i] == VD_AGENT_CLIPBOARD_UTF8_TEXT) { wanted = t[i]; break; }
        if (t[i] == VD_AGENT_CLIPBOARD_IMAGE_PNG) wanted = t[i];
    }
    if (wanted != VD_AGENT_CLIPBOARD_NONE) spice_main_channel_clipboard_selection_request(main, selection, wanted);
    return TRUE;
}

static void on_clipboard_data(SpiceMainChannel *main, guint selection, guint type, gpointer bytes, guint size,
                              gpointer data)
{
    (void)main;
    cs_conn *c = data;
    if (!g_atomic_int_get(&c->share_clipboard) || selection != VD_AGENT_CLIPBOARD_SELECTION_CLIPBOARD || !bytes) return;
    if (type == VD_AGENT_CLIPBOARD_UTF8_TEXT) emit(c, CS_EVENT_CLIPBOARD_TEXT, 0, 0, bytes, (int)size);
    else if (type == VD_AGENT_CLIPBOARD_IMAGE_PNG) emit(c, CS_EVENT_CLIPBOARD_PNG, 0, 0, bytes, (int)size);
}

/* Host -> guest: the guest asks for the data we announced. */
static gboolean on_clipboard_request(SpiceMainChannel *main, guint selection, guint type, gpointer data)
{
    cs_conn *c = data;
    GBytes *b = type == VD_AGENT_CLIPBOARD_UTF8_TEXT ? c->offer_text
              : type == VD_AGENT_CLIPBOARD_IMAGE_PNG ? c->offer_png : NULL;
    if (!g_atomic_int_get(&c->share_clipboard) || !b) return FALSE;
    gsize n;
    const void *p = g_bytes_get_data(b, &n);
    spice_main_channel_clipboard_selection_notify(main, selection, type, p, n);
    return TRUE;
}

/* ---- Display and cursor ------------------------------------------------------------ */

static void on_primary_create(SpiceChannel *channel, gint format, gint width, gint height, gint stride,
                              gint shmid, gpointer imgdata, gpointer data)
{
    (void)channel; (void)shmid;
    cs_conn *c = data;
    g_mutex_lock(&c->frame_lock);
    c->frame = imgdata;
    c->frame_w = width;
    c->frame_h = height;
    c->frame_stride = stride;
    c->frame_format = format;
    g_mutex_unlock(&c->frame_lock);
    g_atomic_int_set(&c->dirty, 1);
    emit(c, CS_EVENT_DISPLAY, width, height, NULL, 0);
    emit(c, CS_EVENT_MARK, 1, 0, NULL, 0);
}

static void on_primary_destroy(SpiceChannel *channel, gpointer data)
{
    (void)channel;
    cs_conn *c = data;
    /* Taking the lock waits for a frame copy in progress before the buffer is freed. */
    g_mutex_lock(&c->frame_lock);
    c->frame = NULL;
    g_mutex_unlock(&c->frame_lock);
}

static void on_invalidate(SpiceChannel *channel, gint x, gint y, gint w, gint h, gpointer data)
{
    (void)channel; (void)x; (void)y; (void)w; (void)h;
    cs_conn *c = data;
    /* Only tell the app once per batch: it copies the whole frame anyway. */
    if (!g_atomic_int_compare_and_exchange(&c->dirty, 0, 1)) return;
    emit(c, CS_EVENT_INVALIDATE, 0, 0, NULL, 0);
}

static void on_mark(SpiceChannel *channel, gint mark, gpointer data)
{
    (void)channel;
    emit(data, CS_EVENT_MARK, mark != 0, 0, NULL, 0);
}

static void on_cursor_changed(SpiceChannel *channel, GParamSpec *pspec, gpointer data)
{
    (void)pspec;
    SpiceCursorShape *shape = NULL;
    g_object_get(channel, "cursor", &shape, NULL);
    if (shape && shape->data && shape->width > 0 && shape->height > 0) {
        /* 0xAARRGGBB words: BGRA bytes on little endian. */
        emit(data, CS_EVENT_CURSOR, shape->width | (shape->height << 16), shape->hot_spot_x | (shape->hot_spot_y << 16),
             shape->data, shape->width * shape->height * 4);
    }
    if (shape) g_boxed_free(SPICE_TYPE_CURSOR_SHAPE, shape);
}

static void on_cursor_hide(SpiceChannel *channel, gpointer data)
{
    (void)channel;
    emit(data, CS_EVENT_CURSOR_HIDE, 0, 0, NULL, 0);
}

static void on_cursor_reset(SpiceChannel *channel, gpointer data)
{
    (void)channel;
    emit(data, CS_EVENT_CURSOR_RESET, 0, 0, NULL, 0);
}

static void on_channel_new(SpiceSession *session, SpiceChannel *channel, gpointer data)
{
    (void)session;
    cs_conn *c = data;
    int id = 0;
    g_object_get(channel, "channel-id", &id, NULL);
    if (c->channels) g_ptr_array_add(c->channels, g_object_ref(channel));
    g_signal_connect(channel, "channel-event", G_CALLBACK(on_channel_event), c);

    if (SPICE_IS_MAIN_CHANNEL(channel)) {
        c->main = SPICE_MAIN_CHANNEL(channel);
        g_signal_connect(channel, "main-mouse-update", G_CALLBACK(on_mouse_update), c);
        g_signal_connect(channel, "main-agent-update", G_CALLBACK(on_agent_update), c);
        g_signal_connect(channel, "main-clipboard-selection-grab", G_CALLBACK(on_clipboard_grab), c);
        g_signal_connect(channel, "main-clipboard-selection", G_CALLBACK(on_clipboard_data), c);
        g_signal_connect(channel, "main-clipboard-selection-request", G_CALLBACK(on_clipboard_request), c);
        on_mouse_update(channel, c);
    } else if (SPICE_IS_DISPLAY_CHANNEL(channel) && id == 0) {
        g_signal_connect(channel, "display-primary-create", G_CALLBACK(on_primary_create), c);
        g_signal_connect(channel, "display-primary-destroy", G_CALLBACK(on_primary_destroy), c);
        g_signal_connect(channel, "display-invalidate", G_CALLBACK(on_invalidate), c);
        g_signal_connect(channel, "display-mark", G_CALLBACK(on_mark), c);
        spice_channel_connect(channel);
    } else if (SPICE_IS_INPUTS_CHANNEL(channel)) {
        c->inputs = SPICE_INPUTS_CHANNEL(channel);
        spice_channel_connect(channel);
    } else if (SPICE_IS_CURSOR_CHANNEL(channel) && id == 0) {
        g_signal_connect(channel, "notify::cursor", G_CALLBACK(on_cursor_changed), c);
        g_signal_connect(channel, "cursor-hide", G_CALLBACK(on_cursor_hide), c);
        g_signal_connect(channel, "cursor-reset", G_CALLBACK(on_cursor_reset), c);
        spice_channel_connect(channel);
    }
    /* Playback/record channels are connected by SpiceAudio itself. */
}

/* ---- API --------------------------------------------------------------------------- */

CS_API cs_conn *cs_new(cs_event_cb callback, void *user)
{
    cs_conn *c = g_new0(cs_conn, 1);
    c->cb = callback;
    c->user = user;
    c->options = g_hash_table_new_full(g_str_hash, g_str_equal, g_free, g_free);
    c->share_clipboard = 1;
    g_mutex_init(&c->frame_lock);
    return c;
}

static void do_set_option(cs_conn *c, call *k)
{
    g_hash_table_replace(c->options, g_strdup(k->s1), g_strdup(k->s2 ? k->s2 : ""));
}

CS_API void cs_set_option(cs_conn *c, const char *key, const char *value)
{
    if (c && key) post(c, do_set_option, 0, 0, 0, key, value, NULL);
}

static const char *opt(cs_conn *c, const char *key)
{
    const char *v = g_hash_table_lookup(c->options, key);
    return v && *v ? v : NULL;
}

static void do_connect(cs_conn *c, call *k)
{
    if (c->session) return;
    emit(c, CS_EVENT_STATE, 0, 0, NULL, 0);
    SpiceSession *s = spice_session_new();
    c->session = s;
    c->channels = g_ptr_array_new_with_free_func(g_object_unref);

    const char *v;
    if ((v = opt(c, "host"))) g_object_set(s, "host", v, NULL);
    if ((v = opt(c, "port")) && atoi(v) > 0) g_object_set(s, "port", v, NULL);
    if ((v = opt(c, "tls-port")) && atoi(v) > 0) g_object_set(s, "tls-port", v, NULL);
    if ((v = opt(c, "password"))) g_object_set(s, "password", v, NULL);
    if ((v = opt(c, "proxy"))) g_object_set(s, "proxy", v, NULL);
    if ((v = opt(c, "host-subject"))) g_object_set(s, "cert-subject", v, NULL);
    if ((v = opt(c, "ca"))) {
        /* .vv files store the PEM on one line with literal "\n". */
        GString *pem = g_string_new(v);
        g_string_replace(pem, "\\n", "\n", 0);
        GByteArray *ca = g_byte_array_new();
        g_byte_array_append(ca, (const guint8 *)pem->str, (guint)pem->len);
        g_object_set(s, "ca", ca, NULL);
        g_byte_array_unref(ca);
        g_string_free(pem, TRUE);
    }
    if ((v = opt(c, "secure-channels"))) {
        gchar **channels = g_strsplit(v, ";", -1);
        g_object_set(s, "secure-channels", channels, NULL);
        g_strfreev(channels);
    }
    g_object_set(s, "enable-usbredir", FALSE, "enable-smartcard", FALSE, NULL);

    g_signal_connect(s, "channel-new", G_CALLBACK(on_channel_new), c);
    g_signal_connect(s, "disconnected", G_CALLBACK(on_session_disconnected), c);

    if (k->a) c->audio = spice_audio_get(s, NULL);
    if (!spice_session_connect(s)) finish(c, "Could not start the connection.");
}

CS_API void cs_connect(cs_conn *c, int audio)
{
    if (c) post(c, do_connect, audio, 0, 0, NULL, NULL, NULL);
}

static void do_disconnect(cs_conn *c, call *k)
{
    (void)k;
    if (c->session) spice_session_disconnect(c->session);
}

CS_API void cs_disconnect(cs_conn *c)
{
    if (c) post(c, do_disconnect, 0, 0, 0, NULL, NULL, NULL);
}

static void do_free(cs_conn *c, call *k)
{
    (void)k;
    c->freed = TRUE;
    teardown(c);
    if (c->offer_text) g_bytes_unref(c->offer_text);
    if (c->offer_png) g_bytes_unref(c->offer_png);
    g_hash_table_unref(c->options);
    g_mutex_clear(&c->frame_lock);
    /* Calls queued after this one see `freed` before touching anything else. Keep the
     * struct itself: a queued call still points at it. It's a few hundred bytes. */
}

CS_API void cs_free(cs_conn *c)
{
    if (c) post(c, do_free, 0, 0, 0, NULL, NULL, NULL);
}

CS_API int cs_frame_size(cs_conn *c, int *width, int *height)
{
    g_mutex_lock(&c->frame_lock);
    int ok = c->frame != NULL;
    *width = ok ? c->frame_w : 0;
    *height = ok ? c->frame_h : 0;
    g_mutex_unlock(&c->frame_lock);
    return ok;
}

CS_API int cs_copy_frame(cs_conn *c, void *dst, int stride, int max_w, int max_h, int only_if_changed)
{
    if (only_if_changed) {
        if (!g_atomic_int_compare_and_exchange(&c->dirty, 1, 0)) return 0;
    } else {
        g_atomic_int_set(&c->dirty, 0);
    }
    g_mutex_lock(&c->frame_lock);
    if (!c->frame || c->frame_w <= 0 || c->frame_h <= 0) {
        g_mutex_unlock(&c->frame_lock);
        return 0;
    }
    int w = MIN(c->frame_w, max_w), h = MIN(c->frame_h, max_h);
    for (int y = 0; y < h; y++) {
        const guint8 *src = c->frame + (gsize)y * c->frame_stride;
        guint32 *out = (guint32 *)((guint8 *)dst + (gsize)y * stride);
        switch (c->frame_format) {
        case SPICE_SURFACE_FMT_16_565:
            for (int x = 0; x < w; x++) {
                guint16 p = ((const guint16 *)src)[x];
                guint32 r = (p >> 11) & 0x1f, g = (p >> 5) & 0x3f, b = p & 0x1f;
                out[x] = 0xff000000u | ((r << 3 | r >> 2) << 16) | ((g << 2 | g >> 4) << 8) | (b << 3 | b >> 2);
            }
            break;
        case SPICE_SURFACE_FMT_16_555:
            for (int x = 0; x < w; x++) {
                guint16 p = ((const guint16 *)src)[x];
                guint32 r = (p >> 10) & 0x1f, g = (p >> 5) & 0x1f, b = p & 0x1f;
                out[x] = 0xff000000u | ((r << 3 | r >> 2) << 16) | ((g << 3 | g >> 2) << 8) | (b << 3 | b >> 2);
            }
            break;
        default: /* 32-bit xRGB/ARGB: BGRX bytes; the X byte may be anything, make it opaque. */
            for (int x = 0; x < w; x++) out[x] = ((const guint32 *)src)[x] | 0xff000000u;
            break;
        }
    }
    g_mutex_unlock(&c->frame_lock);
    return 1;
}

/* ---- Input ------------------------------------------------------------------------- */

static void do_key(cs_conn *c, call *k)
{
    int code = k->a;
    if (!c->inputs || code <= 0 || code >= (int)sizeof c->pressed) return;
    if (k->b) {
        c->pressed[code] = 1;
        spice_inputs_channel_key_press(c->inputs, code);
    } else {
        c->pressed[code] = 0;
        spice_inputs_channel_key_release(c->inputs, code);
    }
}

CS_API void cs_key(cs_conn *c, int scancode, int pressed)
{
    if (c && scancode) post(c, do_key, scancode, pressed, 0, NULL, NULL, NULL);
}

static void do_release_all(cs_conn *c, call *k)
{
    (void)k;
    if (!c->inputs) return;
    for (int i = 0; i < (int)sizeof c->pressed; i++)
        if (c->pressed[i]) spice_inputs_channel_key_release(c->inputs, i);
    memset(c->pressed, 0, sizeof c->pressed);
}

CS_API void cs_release_all_keys(cs_conn *c)
{
    if (c) post(c, do_release_all, 0, 0, 0, NULL, NULL, NULL);
}

CS_API void cs_ctrl_alt_del(cs_conn *c)
{
    const int ctrl = 0x1d, alt = 0x38, del = 0x153;
    cs_key(c, ctrl, 1);
    cs_key(c, alt, 1);
    cs_key(c, del, 1);
    cs_key(c, del, 0);
    cs_key(c, alt, 0);
    cs_key(c, ctrl, 0);
}

static void do_motion(cs_conn *c, call *k)
{
    if (c->inputs) spice_inputs_channel_motion(c->inputs, k->a, k->b, k->d);
}

CS_API void cs_motion(cs_conn *c, int dx, int dy, int mask)
{
    if (c) post(c, do_motion, dx, dy, mask, NULL, NULL, NULL);
}

static void do_position(cs_conn *c, call *k)
{
    if (c->inputs) spice_inputs_channel_position(c->inputs, k->a, k->b, 0, k->d);
}

CS_API void cs_position(cs_conn *c, int x, int y, int mask)
{
    if (c) post(c, do_position, x, y, mask, NULL, NULL, NULL);
}

static void do_button(cs_conn *c, call *k)
{
    if (!c->inputs) return;
    if (k->b) spice_inputs_channel_button_press(c->inputs, k->a, k->d);
    else spice_inputs_channel_button_release(c->inputs, k->a, k->d);
}

CS_API void cs_button(cs_conn *c, int button, int pressed, int mask)
{
    if (c) post(c, do_button, button, pressed, mask, NULL, NULL, NULL);
}

static void do_resolution(cs_conn *c, call *k)
{
    if (!c->main) return;
    gboolean agent = FALSE;
    g_object_get(c->main, "agent-connected", &agent, NULL);
    if (!agent) return;
    spice_main_channel_update_display_enabled(c->main, 0, TRUE, FALSE);
    spice_main_channel_update_display(c->main, 0, 0, 0, k->a, k->b, TRUE);
}

CS_API void cs_request_resolution(cs_conn *c, int width, int height)
{
    if (!c || width < 320 || height < 200) return;
    post(c, do_resolution, width & ~1, height, 0, NULL, NULL, NULL);   /* some drivers dislike odd sizes */
}

/* ---- Clipboard --------------------------------------------------------------------- */

CS_API void cs_set_share_clipboard(cs_conn *c, int share)
{
    if (c) g_atomic_int_set(&c->share_clipboard, share != 0);
}

static void do_offer(cs_conn *c, call *k)
{
    if (c->offer_text) g_bytes_unref(c->offer_text);
    if (c->offer_png) g_bytes_unref(c->offer_png);
    c->offer_text = k->s1 ? g_bytes_new(k->s1, strlen(k->s1)) : NULL;
    c->offer_png = k->bytes ? g_bytes_ref(k->bytes) : NULL;
    if (!c->main || !spice_main_channel_agent_test_capability(c->main, VD_AGENT_CAP_CLIPBOARD_BY_DEMAND)) return;
    guint32 types[2];
    int n = 0;
    if (c->offer_text) types[n++] = VD_AGENT_CLIPBOARD_UTF8_TEXT;
    if (c->offer_png) types[n++] = VD_AGENT_CLIPBOARD_IMAGE_PNG;
    if (n) spice_main_channel_clipboard_selection_grab(c->main, VD_AGENT_CLIPBOARD_SELECTION_CLIPBOARD, types, n);
}

CS_API void cs_clipboard_offer(cs_conn *c, const char *utf8_text, const void *png, int png_size)
{
    if (!c || !g_atomic_int_get(&c->share_clipboard)) return;
    GBytes *b = png && png_size > 0 ? g_bytes_new(png, (gsize)png_size) : NULL;
    post(c, do_offer, 0, 0, 0, utf8_text, NULL, b);
}
