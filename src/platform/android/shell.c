// Android JNI shell — the native side between NokreView.java and the Zig
// exports in android.zig. Thin by charter: register the Java natives,
// blit the RGBX frame into the ANativeWindow, ferry strings as UTF-8
// bytes, and lend the main thread's ALooper as the post target for
// worker wakes and out-of-stream frame requests. No state beyond the
// JNI plumbing; everything intelligent lives above this line.
//
// Compiled by the consumer's CMake next to the Skia shim (see
// examples/kitchen_sink/android) — the same split as the web, where
// services.js provides the service hooks on the wasm import object.
#define _GNU_SOURCE // pipe2 on bionic
#include <jni.h>

#include <android/looper.h>
#include <android/native_window.h>
#include <android/native_window_jni.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include "../shell.h" // NOKRE_POINTER_* — nativeTap speaks the shared phase enum
#include "../../../shim/nokre_accesskit.h"
#include "../../services/deep_link/deep_link.h"
#include "../../services/oauth/oauth.h"
#include "../../services/notification/notification.h"
#include "../../services/locale/locale.h"
#include "../../services/open_url/open_url.h"
#include "../../services/share/share.h"

// ---- the Zig doorway (android.zig exports) ----

extern int32_t nokre_android_boot(void);
extern const uint8_t *nokre_android_frame(int32_t logical_w, int32_t logical_h, int32_t safe_bottom,
                                        int32_t scale, int32_t *out_w, int32_t *out_h);
extern void nokre_android_pointer(int32_t x, int32_t y, int32_t phase);
extern void nokre_android_key(int32_t key, uint8_t mods);
extern void nokre_android_text(const char *utf8, size_t len);
extern void nokre_android_scroll(int32_t x, int32_t y, int32_t dx, int32_t dy, int32_t phase);
extern int32_t nokre_android_back(void);
extern void nokre_android_ime_update(const char *utf8, size_t len, size_t cursor);
extern void nokre_android_ime_commit(const char *utf8, size_t len);
extern void nokre_android_ime_cancel(void);
extern int32_t nokre_android_wants_pointer_stream(int32_t x, int32_t y);
extern int32_t nokre_android_wants_frame(void);
extern int32_t nokre_android_wants_text_input(void);
extern void nokre_android_appearance(int32_t dark);
extern void nokre_android_window_focus(int32_t focused);
extern const nokre_a11y_node *nokre_android_a11y_fill(size_t *count, uint64_t *focus_id);
extern void nokre_android_a11y_action(uint64_t target, int32_t action);

// ---- JNI plumbing ----

static JavaVM *g_vm;
static jclass g_view_class; // global ref
static jobject g_view;      // global ref; refreshed on every nativeBoot
static jmethodID g_mid_request_render; // requestRenderFromNative()
static jmethodID g_mid_a11y_changed;   // a11yChanged()
static jmethodID g_mid_a11y_begin;     // a11yBegin(int, long)
static jmethodID g_mid_a11y_node;      // a11yNode(...)
static jmethodID g_mid_write_clipboard; // writeClipboard(byte[])
static jmethodID g_mid_open_url;        // openUrl(byte[])
static jmethodID g_mid_show_share;      // showShare(byte[])
static jmethodID g_mid_locale_tag;      // localeTag() -> byte[]

static ANativeWindow *g_window;

// deep_link service inbound hook (docs/services.md;
// src/services/deep_link/deep_link.h). The single-app anchor, like g_view:
// one activity per process. A URL delivered before the app registers its
// handler — a cold-launch link reaches onCreate before the surface boots
// the app — is buffered in one slot and flushed on install, so it is
// never dropped.
static void *g_deep_link_ctx;
static nokre_deep_link_cb g_deep_link_cb;
static char *g_deep_link_pending;
static size_t g_deep_link_pending_len;

// locale service inbound hook (docs/services.md;
// src/services/locale/locale.h). Nothing to buffer, unlike a launch URL:
// the tag is readable on demand, so install reads it and fires before it
// returns. The one piece of state past ctx+cb is a copy of the last tag
// reported, and it exists because Android answers an OS locale change by
// *recreating the Activity*: the shell reboots (nativeBoot) while the app
// does not (nokre_android_boot is idempotent, so install runs once per
// process). The boot-path report is therefore the change lane here, and
// comparing against the last tag is what keeps a plain recreate — a
// rotation on a manifest that lets one through — from looking like a
// locale change. A tag too long for the copy is never equal, so it always
// fires; the cap and what an over-long tag means are Zig's policy, and
// the callback always gets the full length.
static void *g_locale_ctx;
static nokre_locale_cb g_locale_cb;
static char g_locale_last[64];
static size_t g_locale_last_len = SIZE_MAX; // never equal to a real length

// The main thread's env. All shell entry points but the post-main wake
// run on the main thread (the input-callback contract), so GetEnv
// suffices — no attach bookkeeping.
static JNIEnv *mainEnv(void) {
    JNIEnv *env = NULL;
    if ((*g_vm)->GetEnv(g_vm, (void **)&env, JNI_VERSION_1_6) != JNI_OK) return NULL;
    return env;
}

// Lends the process JavaVM to services compiled into the same .so that
// must call Java themselves — secure_store's JNI leg (android.c) reaches
// NokreSecureStore this way. Generic JNI plumbing, no service knowledge:
// there is one JNI_OnLoad per .so and it lives here, so the VM does too.
JavaVM *nokre_android_vm(void) {
    return g_vm;
}

// ---- main-thread post (ALooper pipe) ----
// The worker service's delivery hop (docs/internals/workers.md) and the
// out-of-stream frame request both land here: a pipe registered with
// the main thread's looper, drained in the callback. Writes up to
// PIPE_BUF are atomic, so items never tear across threads.

typedef struct {
    void (*work)(void *ctx); // NULL means "request a frame"
    void *ctx;
} nokre_post_item;

static int g_post_pipe[2] = {-1, -1};

static int postCallback(int fd, int events, void *data) {
    (void)events;
    (void)data;
    nokre_post_item item;
    while (read(fd, &item, sizeof item) == (ssize_t)sizeof item) {
        if (item.work != NULL) {
            item.work(item.ctx);
        } else {
            JNIEnv *env = mainEnv();
            if (env != NULL && g_view != NULL) {
                (*env)->CallVoidMethod(env, g_view, g_mid_request_render);
            }
        }
    }
    return 1; // keep the callback registered
}

void nokre_shell_post_main(void *view, void (*work)(void *ctx), void *ctx) {
    (void)view;
    if (g_post_pipe[1] < 0) return;
    nokre_post_item item = {work, ctx};
    // A full pipe would mean thousands of undrained posts; dropping the
    // write then would lose a pump, but the next reply's wake retries.
    (void)!write(g_post_pipe[1], &item, sizeof item);
}

void nokre_shell_request_frame(void *view) {
    (void)view;
    if (g_post_pipe[1] < 0) return;
    nokre_post_item item = {NULL, NULL};
    (void)!write(g_post_pipe[1], &item, sizeof item);
}

// ---- clipboard (shell.h free function; the clipboard service calls it) ----

void nokre_shell_write_clipboard(const char *utf8, size_t len) {
    JNIEnv *env = mainEnv(); // main thread only, like all input callbacks
    if (env == NULL || g_view == NULL) return;
    jbyteArray bytes = (*env)->NewByteArray(env, (jsize)len);
    if (bytes == NULL) return;
    (*env)->SetByteArrayRegion(env, bytes, 0, (jsize)len, (const jbyte *)utf8);
    (*env)->CallVoidMethod(env, g_view, g_mid_write_clipboard, bytes);
    (*env)->DeleteLocalRef(env, bytes);
}

// ---- open_url (service outbound hook; NokreView.openUrl fires the intent) ----

void nokre_open_url_open(const char *url, size_t len) {
    JNIEnv *env = mainEnv(); // main thread only, like all input callbacks
    if (env == NULL || g_view == NULL) return;
    jbyteArray bytes = (*env)->NewByteArray(env, (jsize)len);
    if (bytes == NULL) return;
    (*env)->SetByteArrayRegion(env, bytes, 0, (jsize)len, (const jbyte *)url);
    (*env)->CallVoidMethod(env, g_view, g_mid_open_url, bytes);
    (*env)->DeleteLocalRef(env, bytes);
}

// ---- share (service outbound hook; NokreView.showShare fires the chooser) ----

void nokre_share_show(const char *text, size_t len) {
    JNIEnv *env = mainEnv(); // main thread only, like all input callbacks
    if (env == NULL || g_view == NULL) return;
    jbyteArray bytes = (*env)->NewByteArray(env, (jsize)len);
    if (bytes == NULL) return;
    (*env)->SetByteArrayRegion(env, bytes, 0, (jsize)len, (const jbyte *)text);
    (*env)->CallVoidMethod(env, g_view, g_mid_show_share, bytes);
    (*env)->DeleteLocalRef(env, bytes);
}

// ---- a11y push (android.zig's a11y_push after every rendered frame) ----

void nokre_android_a11y_changed(void) {
    JNIEnv *env = mainEnv(); // frames render on the main thread
    if (env == NULL || g_view == NULL) return;
    (*env)->CallVoidMethod(env, g_view, g_mid_a11y_changed);
}

// ---- deep_link (service inbound hook; nativeDeepLink calls the first) ----

static void nokre_deep_link_dispatch(const char *url, size_t len) {
    if (g_deep_link_cb == NULL) {
        // No handler yet: buffer the cold-launch link until install. One
        // slot, latest wins — an app opened by exactly one URL.
        free(g_deep_link_pending);
        g_deep_link_pending = malloc(len ? len : 1); // malloc(1) marks "buffered"
        if (g_deep_link_pending == NULL) {
            g_deep_link_pending_len = 0;
            return;
        }
        memcpy(g_deep_link_pending, url, len);
        g_deep_link_pending_len = len;
        return;
    }
    g_deep_link_cb(g_deep_link_ctx, url, len);
    // The handler routed and invalidated; mark the frame dirty from
    // outside the input stream (the pipe wake, on the main thread).
    nokre_shell_request_frame(NULL);
}

void nokre_deep_link_install(void *ctx, nokre_deep_link_cb cb) {
    g_deep_link_ctx = ctx;
    g_deep_link_cb = cb;
    if (g_deep_link_pending != NULL) {
        cb(ctx, g_deep_link_pending, g_deep_link_pending_len);
        free(g_deep_link_pending);
        g_deep_link_pending = NULL;
        g_deep_link_pending_len = 0;
        nokre_shell_request_frame(NULL);
    }
}

void nokre_deep_link_uninstall(void) {
    // Back to the pre-install posture: an intent that arrives now is
    // buffered for the next install, never delivered into per-app state
    // the app has already freed.
    g_deep_link_ctx = NULL;
    g_deep_link_cb = NULL;
}

// ---- locale (service inbound hook; the read goes up into Java) ----

// Reads the tag Java has and hands it to the app if it moved. The value
// lives in the Configuration's LocaleList (NokreView.localeTag), not in
// any C API: bionic's environment carries no locale, and AConfiguration
// needs an AssetManager the shell never holds. `on_install` fires even
// when the tag is unchanged, because the first callback is promised
// unconditionally, and skips the repaint — install runs inside
// App.init, so the boot frame is already coming.
static void localeReport(int on_install) {
    if (g_locale_cb == NULL) return;
    JNIEnv *env = mainEnv(); // configuration reports are main-thread, like input
    if (env == NULL || g_view == NULL) return;
    jbyteArray bytes = (jbyteArray)(*env)->CallObjectMethod(env, g_view, g_mid_locale_tag);
    // No locale in the list (or no array to hand back) is the contract's
    // unknown: length 0. Zig turns that into the app's own template
    // language — naming a default is not the shell's decision.
    const char *tag = "";
    size_t len = 0;
    jbyte *elems = NULL;
    if (bytes != NULL) {
        elems = (*env)->GetByteArrayElements(env, bytes, NULL);
        if (elems != NULL) {
            tag = (const char *)elems;
            len = (size_t)(*env)->GetArrayLength(env, bytes);
        }
    }
    if (on_install || len != g_locale_last_len || memcmp(g_locale_last, tag, len) != 0) {
        if (len <= sizeof g_locale_last) {
            memcpy(g_locale_last, tag, len);
            g_locale_last_len = len;
        } else {
            g_locale_last_len = SIZE_MAX;
        }
        g_locale_cb(g_locale_ctx, tag, len);
        // The handler ran outside the input stream; mark the frame dirty
        // through the pipe, as the deep_link leg does.
        if (!on_install) nokre_shell_request_frame(NULL);
    }
    if (elems != NULL) (*env)->ReleaseByteArrayElements(env, bytes, elems, JNI_ABORT);
    if (bytes != NULL) (*env)->DeleteLocalRef(env, bytes);
}

void nokre_locale_install(void *ctx, nokre_locale_cb cb) {
    g_locale_ctx = ctx;
    g_locale_cb = cb;
    // Synchronous, as the header promises: this runs inside App.init,
    // itself inside nativeBoot, which publishes g_view *before* calling
    // nokre_android_boot — so Java is reachable here even though no
    // surface exists yet.
    localeReport(1);
}

void nokre_locale_uninstall(void) {
    // Configuration changes keep arriving; with the callback gone,
    // localeReport drops them instead of calling into per-app state the
    // app has already freed.
    g_locale_ctx = NULL;
    g_locale_cb = NULL;
}

// ---- Java natives ----

static jboolean nativeBoot(JNIEnv *env, jobject view) {
    // Activity recreation reboots the shell but never the app: refresh
    // the view the callbacks target, keep the looper pipe and the Zig
    // state (nokre_android_boot is idempotent).
    if (g_view != NULL) (*env)->DeleteGlobalRef(env, g_view);
    g_view = (*env)->NewGlobalRef(env, view);
    if (g_post_pipe[0] < 0) {
        if (pipe2(g_post_pipe, O_NONBLOCK | O_CLOEXEC) != 0) return JNI_FALSE;
        ALooper *looper = ALooper_forThread(); // nativeBoot runs on the main thread
        if (looper == NULL) return JNI_FALSE;
        ALooper_addFd(looper, g_post_pipe[0], ALOOPER_POLL_CALLBACK, ALOOPER_EVENT_INPUT,
                      postCallback, NULL);
    }
    return nokre_android_boot() != 0 ? JNI_TRUE : JNI_FALSE;
}

static void nativeSetSurface(JNIEnv *env, jobject view, jobject surface) {
    (void)view;
    if (g_window != NULL) {
        ANativeWindow_release(g_window);
        g_window = NULL;
    }
    if (surface != NULL) {
        g_window = ANativeWindow_fromSurface(env, surface);
        if (g_window != NULL) {
            // 0×0 keeps the buffer at the window's own pixel size — the
            // compositor never scales, which is the pixel guarantee.
            ANativeWindow_setBuffersGeometry(g_window, 0, 0, WINDOW_FORMAT_RGBX_8888);
        }
    }
}

static void nativeRender(JNIEnv *env, jobject view, jint logical_w, jint logical_h,
                         jint safe_bottom, jint scale) {
    (void)env;
    (void)view;
    if (g_window == NULL) return;
    int32_t out_w = 0, out_h = 0;
    const uint8_t *pixels =
        nokre_android_frame(logical_w, logical_h, safe_bottom, scale, &out_w, &out_h);
    if (pixels == NULL || out_w <= 0 || out_h <= 0) return;

    ANativeWindow_Buffer buf;
    if (ANativeWindow_lock(g_window, &buf, NULL) != 0) return;
    // logical is the ceiling of window/scale, so the frame covers the
    // buffer and the sub-scale remainder crops at the right/bottom edge
    // (the Windows shell's policy).
    int32_t w = buf.width < out_w ? buf.width : out_w;
    int32_t h = buf.height < out_h ? buf.height : out_h;
    for (int32_t y = 0; y < h; y++) {
        const uint8_t *src = pixels + (size_t)y * (size_t)out_w * 4;
        uint32_t *dst = (uint32_t *)buf.bits + (size_t)y * (size_t)buf.stride;
        // The frame is RGBX (shell.h) and so is the buffer — the one
        // shell whose blit is a straight row copy; the format ignores
        // the padding byte on both sides.
        memcpy(dst, src, (size_t)w * 4);
    }
    ANativeWindow_unlockAndPost(g_window);
}

// GestureDetector still owns tap detection, so the press and the release
// arrive together at the recognized point — identical behavior to the
// single event this replaced. Driving the real MotionEvent stream comes
// later, and has to keep the fling-stop refusal (onDown) intact.
static void nativePointer(JNIEnv *env, jobject view, jint x, jint y, jint phase) {
    (void)env;
    (void)view;
    nokre_android_pointer(x, y, phase);
}

// Asked once per touch-down, before the GestureDetector sees anything:
// core says whether whatever is there needs the press and the release as
// separate events. No means this touch takes the ordinary path.
static jboolean nativeWantsPointerStream(JNIEnv *env, jobject view, jint x, jint y) {
    (void)env;
    (void)view;
    return nokre_android_wants_pointer_stream(x, y) ? JNI_TRUE : JNI_FALSE;
}

static void nativeTap(JNIEnv *env, jobject view, jint x, jint y) {
    (void)env;
    (void)view;
    nokre_android_pointer(x, y, NOKRE_POINTER_DOWN);
    nokre_android_pointer(x, y, NOKRE_POINTER_UP);
}

// The system back. Android is the only shell with this leg: its own
// gesture navigation owns both screen edges, so the app never sees the
// edge pan the iOS shell reports (on_edge_pan) and gets the decided
// command instead. False means there was nothing to go back to, and the
// Activity finishes as it otherwise would.
static jboolean nativeBack(JNIEnv *env, jobject view) {
    (void)env;
    (void)view;
    return nokre_android_back() != 0 ? JNI_TRUE : JNI_FALSE;
}

static void nativeKey(JNIEnv *env, jobject view, jint key, jint mods) {
    (void)env;
    (void)view;
    nokre_android_key(key, (uint8_t)mods);
}

// Text and IME strings travel as Java byte[] holding standard UTF-8
// (String.getBytes(UTF_8)) — GetStringUTFChars would hand over
// *modified* UTF-8, which encodes supplementary characters (emoji) as
// surrogate pairs core would render as garbage.
static void nativeText(JNIEnv *env, jobject view, jbyteArray utf8) {
    (void)view;
    jsize len = (*env)->GetArrayLength(env, utf8);
    jbyte *bytes = (*env)->GetByteArrayElements(env, utf8, NULL);
    if (bytes == NULL) return;
    nokre_android_text((const char *)bytes, (size_t)len);
    (*env)->ReleaseByteArrayElements(env, utf8, bytes, JNI_ABORT);
}

// An inbound App Link the Activity received (onCreate launch intent /
// onNewIntent), as standard-UTF-8 byte[]. Runs on the main thread, so it
// reaches the handler synchronously like every other input.
static void nativeDeepLink(JNIEnv *env, jobject view, jbyteArray utf8) {
    (void)view;
    jsize len = (*env)->GetArrayLength(env, utf8);
    jbyte *bytes = (*env)->GetByteArrayElements(env, utf8, NULL);
    if (bytes == NULL) return;
    nokre_deep_link_dispatch((const char *)bytes, (size_t)len);
    (*env)->ReleaseByteArrayElements(env, utf8, bytes, JNI_ABORT);
}

// An oauth result the Activity's NokreOAuth reported: the redirect URL
// (status 0) or the user backing out of the Custom Tab (status 1). Runs
// on the main thread, so it reaches the app's handler the way every
// other inbound event does. The dispatch itself lives in the service's
// own android.c — a shell never learns what a flow is.
static void nativeAuthResult(JNIEnv *env, jobject view, jint status, jbyteArray utf8) {
    (void)view;
    jsize len = (*env)->GetArrayLength(env, utf8);
    jbyte *bytes = (*env)->GetByteArrayElements(env, utf8, NULL);
    if (bytes == NULL) return;
    nokre_oauth_dispatch((int)status, (const char *)bytes, (size_t)len);
    (*env)->ReleaseByteArrayElements(env, utf8, bytes, JNI_ABORT);
}

// A notification event NokreNotifications reported: the permission
// answered, a tap, a foreground arrival, or a push token. Runs on the
// main thread, so it reaches the app's handler the way every other
// inbound event does. The dispatch lives in the service's own android.c —
// a shell never learns what a notification is, the oauth rule.
static void nativeNotificationEvent(JNIEnv *env, jobject view, jint kind, jint status,
                                    jbyteArray a, jbyteArray b) {
    (void)view;
    jsize a_len = a == NULL ? 0 : (*env)->GetArrayLength(env, a);
    jsize b_len = b == NULL ? 0 : (*env)->GetArrayLength(env, b);
    jbyte *a_bytes = a_len == 0 ? NULL : (*env)->GetByteArrayElements(env, a, NULL);
    jbyte *b_bytes = b_len == 0 ? NULL : (*env)->GetByteArrayElements(env, b, NULL);
    nokre_notification_dispatch((int32_t)kind, (int32_t)status,
                                a_bytes == NULL ? "" : (const char *)a_bytes, (size_t)a_len,
                                b_bytes == NULL ? "" : (const char *)b_bytes, (size_t)b_len);
    if (a_bytes != NULL) (*env)->ReleaseByteArrayElements(env, a, a_bytes, JNI_ABORT);
    if (b_bytes != NULL) (*env)->ReleaseByteArrayElements(env, b, b_bytes, JNI_ABORT);
    // The handler routed and invalidated like any action; repaint on the
    // next looper turn (the on-demand loop, worker-pump rule).
    nokre_shell_request_frame(NULL);
}

static void nativeScroll(JNIEnv *env, jobject view, jint x, jint y, jint dx, jint dy,
                         jint phase) {
    (void)env;
    (void)view;
    nokre_android_scroll(x, y, dx, dy, phase);
}

static void nativeImeUpdate(JNIEnv *env, jobject view, jbyteArray utf8, jint cursor) {
    (void)view;
    jsize len = (*env)->GetArrayLength(env, utf8);
    jbyte *bytes = (*env)->GetByteArrayElements(env, utf8, NULL);
    if (bytes == NULL) return;
    nokre_android_ime_update((const char *)bytes, (size_t)len, (size_t)cursor);
    (*env)->ReleaseByteArrayElements(env, utf8, bytes, JNI_ABORT);
}

static void nativeImeCommit(JNIEnv *env, jobject view, jbyteArray utf8) {
    (void)view;
    jsize len = (*env)->GetArrayLength(env, utf8);
    jbyte *bytes = (*env)->GetByteArrayElements(env, utf8, NULL);
    if (bytes == NULL) return;
    nokre_android_ime_commit((const char *)bytes, (size_t)len);
    (*env)->ReleaseByteArrayElements(env, utf8, bytes, JNI_ABORT);
}

static void nativeImeCancel(JNIEnv *env, jobject view) {
    (void)env;
    (void)view;
    nokre_android_ime_cancel();
}

static jboolean nativeWantsFrame(JNIEnv *env, jobject view) {
    (void)env;
    (void)view;
    return nokre_android_wants_frame() != 0 ? JNI_TRUE : JNI_FALSE;
}

static jboolean nativeWantsTextInput(JNIEnv *env, jobject view) {
    (void)env;
    (void)view;
    return nokre_android_wants_text_input() != 0 ? JNI_TRUE : JNI_FALSE;
}

static void nativeAppearance(JNIEnv *env, jobject view, jboolean dark) {
    (void)env;
    (void)view;
    nokre_android_appearance(dark == JNI_TRUE ? 1 : 0);
}

// A configuration report from the Activity (a locale change recreates it,
// so this also runs once per boot) — the shell re-reads the tag rather
// than being handed one, keeping a single read path.
static void nativeLocale(JNIEnv *env, jobject view) {
    (void)env;
    (void)view;
    localeReport(0);
}

static void nativeWindowFocus(JNIEnv *env, jobject view, jboolean focused) {
    (void)env;
    (void)view;
    nokre_android_window_focus(focused == JNI_TRUE ? 1 : 0);
}

// Walks the flattened snapshot and hands each node to the Java
// provider (a11yBegin then one a11yNode per entry) — a JNI call per
// node instead of Java parsing raw structs, because the struct layout
// is pointer-width-dependent and snapshots are tens of nodes.
static jint nativeA11yFill(JNIEnv *env, jobject view) {
    size_t count = 0;
    uint64_t focus_id = 0;
    const nokre_a11y_node *nodes = nokre_android_a11y_fill(&count, &focus_id);
    if (nodes == NULL) return 0;
    (*env)->CallVoidMethod(env, view, g_mid_a11y_begin, (jint)count, (jlong)focus_id);
    for (size_t i = 0; i < count; i++) {
        const nokre_a11y_node *n = &nodes[i];
        jbyteArray label = NULL;
        jbyteArray value = NULL;
        if (n->label_len > 0) {
            label = (*env)->NewByteArray(env, (jsize)n->label_len);
            if (label != NULL)
                (*env)->SetByteArrayRegion(env, label, 0, (jsize)n->label_len,
                                           (const jbyte *)n->label);
        }
        if (n->value_len > 0) {
            value = (*env)->NewByteArray(env, (jsize)n->value_len);
            if (value != NULL)
                (*env)->SetByteArrayRegion(env, value, 0, (jsize)n->value_len,
                                           (const jbyte *)n->value);
        }
        (*env)->CallVoidMethod(env, view, g_mid_a11y_node, (jlong)n->id, (jint)n->role, label,
                               value, (jint)n->x, (jint)n->y, (jint)n->w, (jint)n->h,
                               (jint)(n->parent == (size_t)-1 ? -1 : (jint)n->parent),
                               (jboolean)(n->focusable != 0), (jboolean)(n->focused != 0),
                               (jboolean)(n->disabled != 0), (jboolean)(n->modal != 0),
                               (jboolean)(n->clickable != 0), (jint)n->checked,
                               (jint)n->selected, (jint)n->heading_level,
                               (jboolean)(n->busy != 0));
        if (label != NULL) (*env)->DeleteLocalRef(env, label);
        if (value != NULL) (*env)->DeleteLocalRef(env, value);
    }
    return (jint)count;
}

static void nativeA11yAction(JNIEnv *env, jobject view, jlong id, jint action) {
    (void)env;
    (void)view;
    nokre_android_a11y_action((uint64_t)id, action);
}

static const JNINativeMethod g_methods[] = {
    {"nativeBoot", "()Z", (void *)nativeBoot},
    {"nativeSetSurface", "(Landroid/view/Surface;)V", (void *)nativeSetSurface},
    {"nativeRender", "(IIII)V", (void *)nativeRender},
    {"nativeTap", "(II)V", (void *)nativeTap},
    {"nativePointer", "(III)V", (void *)nativePointer},
    {"nativeWantsPointerStream", "(II)Z", (void *)nativeWantsPointerStream},
    {"nativeKey", "(II)V", (void *)nativeKey},
    {"nativeText", "([B)V", (void *)nativeText},
    {"nativeDeepLink", "([B)V", (void *)nativeDeepLink},
    {"nativeAuthResult", "(I[B)V", (void *)nativeAuthResult},
    {"nativeNotificationEvent", "(II[B[B)V", (void *)nativeNotificationEvent},
    {"nativeScroll", "(IIIII)V", (void *)nativeScroll},
    {"nativeBack", "()Z", (void *)nativeBack},
    {"nativeImeUpdate", "([BI)V", (void *)nativeImeUpdate},
    {"nativeImeCommit", "([B)V", (void *)nativeImeCommit},
    {"nativeImeCancel", "()V", (void *)nativeImeCancel},
    {"nativeWantsFrame", "()Z", (void *)nativeWantsFrame},
    {"nativeWantsTextInput", "()Z", (void *)nativeWantsTextInput},
    {"nativeAppearance", "(Z)V", (void *)nativeAppearance},
    {"nativeLocale", "()V", (void *)nativeLocale},
    {"nativeWindowFocus", "(Z)V", (void *)nativeWindowFocus},
    {"nativeA11yFill", "()I", (void *)nativeA11yFill},
    {"nativeA11yAction", "(JI)V", (void *)nativeA11yAction},
};

JNIEXPORT jint JNI_OnLoad(JavaVM *vm, void *reserved) {
    (void)reserved;
    g_vm = vm;
    JNIEnv *env = NULL;
    if ((*vm)->GetEnv(vm, (void **)&env, JNI_VERSION_1_6) != JNI_OK) return JNI_ERR;
    jclass cls = (*env)->FindClass(env, "dev/nokre/shell/NokreView");
    if (cls == NULL) return JNI_ERR;
    g_view_class = (*env)->NewGlobalRef(env, cls);
    if ((*env)->RegisterNatives(env, cls, g_methods,
                                sizeof(g_methods) / sizeof(g_methods[0])) != 0)
        return JNI_ERR;
    g_mid_request_render = (*env)->GetMethodID(env, cls, "requestRenderFromNative", "()V");
    g_mid_a11y_changed = (*env)->GetMethodID(env, cls, "a11yChanged", "()V");
    g_mid_a11y_begin = (*env)->GetMethodID(env, cls, "a11yBegin", "(IJ)V");
    g_mid_a11y_node = (*env)->GetMethodID(env, cls, "a11yNode", "(JI[B[BIIIIIZZZZZIIIZ)V");
    g_mid_write_clipboard = (*env)->GetMethodID(env, cls, "writeClipboard", "([B)V");
    g_mid_open_url = (*env)->GetMethodID(env, cls, "openUrl", "([B)V");
    g_mid_show_share = (*env)->GetMethodID(env, cls, "showShare", "([B)V");
    g_mid_locale_tag = (*env)->GetMethodID(env, cls, "localeTag", "()[B");
    if (g_mid_request_render == NULL || g_mid_a11y_changed == NULL || g_mid_a11y_begin == NULL ||
        g_mid_a11y_node == NULL || g_mid_write_clipboard == NULL || g_mid_open_url == NULL ||
        g_mid_show_share == NULL || g_mid_locale_tag == NULL)
        return JNI_ERR;
    return JNI_VERSION_1_6;
}
