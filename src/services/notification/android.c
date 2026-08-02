// Android side of the notification service: the notification.h verbs
// bridged over JNI to dev.nokre.shell.NokreNotifications, whose
// NotificationManager, AlarmManager and runtime permission are the actual
// implementation (docs/internals/notifications.md).
//
// secure_store's android.c placement and posture: policy already ran in
// Zig — the id charset, the byte caps, the authorization gate, the
// refusal of a past fire date — so this file ferries bytes and holds
// nothing but the installed ctx + callback. The JavaVM comes from the
// shell (nokre_android_vm — the one JNI_OnLoad in the .so), and the
// inbound leg arrives through NokreView.nativeNotificationEvent, which
// the shell declares and this file implements: oauth's split, where a
// shell routes an event without learning what it means.
//
// Compiled by the consumer's CMake next to shell.c (the Android split: C
// is NDK-built, the Zig arrives as a static lib).
#include <jni.h>
#include <stdint.h>
#include <string.h>

#include "notification.h"

extern JavaVM *nokre_android_vm(void); // shell.c

static void *g_ctx;
static nokre_notification_cb g_cb;
// The tap that launched the process: NokreActivity reads its intent in
// onCreate, which runs before nativeBoot has reached App.init, so the
// event lands here with nothing installed. deep_link's launch-URL buffer,
// and the one thing notification.h asks a native side to hold.
static char g_pending_id[128];
static size_t g_pending_id_len;
static char g_pending_route[256];
static size_t g_pending_route_len;
static int g_has_pending;

static jclass g_cls;
static jmethodID g_available, g_status, g_authorize, g_post, g_cancel;

static JNIEnv *nt_env(void) {
    JavaVM *vm = nokre_android_vm();
    if (vm == NULL) return NULL;
    JNIEnv *env = NULL;
    // GetEnv suffices: every verb runs on the main thread, already
    // attached — the input-callback contract.
    if ((*vm)->GetEnv(vm, (void **)&env, JNI_VERSION_1_6) != JNI_OK) return NULL;
    return env;
}

static int nt_init(JNIEnv *env) {
    if (g_cls != NULL) return 1;
    jclass cls = (*env)->FindClass(env, "dev/nokre/shell/NokreNotifications");
    if (cls == NULL) {
        (*env)->ExceptionClear(env);
        return 0;
    }
    g_cls = (*env)->NewGlobalRef(env, cls);
    (*env)->DeleteLocalRef(env, cls);
    if (g_cls == NULL) return 0;
    g_available = (*env)->GetStaticMethodID(env, g_cls, "available", "()Z");
    g_status = (*env)->GetStaticMethodID(env, g_cls, "status", "()I");
    g_authorize = (*env)->GetStaticMethodID(env, g_cls, "authorize", "()V");
    g_post = (*env)->GetStaticMethodID(env, g_cls, "post", "([B[B[B[BZJ)V");
    g_cancel = (*env)->GetStaticMethodID(env, g_cls, "cancel", "([B)V");
    if (g_available == NULL || g_status == NULL || g_authorize == NULL || g_post == NULL ||
        g_cancel == NULL) {
        (*env)->ExceptionClear(env);
        return 0;
    }
    return 1;
}

static jbyteArray nt_bytes(JNIEnv *env, const char *s, size_t len) {
    jbyteArray arr = (*env)->NewByteArray(env, (jsize)len);
    if (arr == NULL) return NULL;
    if (len != 0) (*env)->SetByteArrayRegion(env, arr, 0, (jsize)len, (const jbyte *)s);
    return arr;
}

void nokre_notification_install(void *ctx, nokre_notification_cb cb) {
    g_ctx = ctx;
    g_cb = cb;
    if (g_has_pending) {
        g_has_pending = 0;
        cb(ctx, NOKRE_NOTIFICATION_OPENED, nokre_notification_status(), g_pending_id,
           g_pending_id_len, g_pending_route, g_pending_route_len);
    }
}

void nokre_notification_uninstall(void) {
    // Back to the pre-install posture: a tap arriving now buffers for the
    // next install rather than reaching per-app state the app has freed.
    g_ctx = NULL;
    g_cb = NULL;
}

int32_t nokre_notification_available(void) {
    JNIEnv *env = nt_env();
    if (env == NULL || !nt_init(env)) return 0;
    jboolean ok = (*env)->CallStaticBooleanMethod(env, g_cls, g_available);
    if ((*env)->ExceptionCheck(env)) {
        (*env)->ExceptionClear(env);
        return 0;
    }
    return ok ? 1 : 0;
}

int32_t nokre_notification_push_available(void) {
    JNIEnv *env = nt_env();
    if (env == NULL) return 0;
    // The class exists only when the consumer added the Firebase
    // coordinate to their own build.gradle (docs/services.md) — so its
    // presence *is* the answer, with no version probing and no reflection
    // into Google's own classes. A missing class is a normal outcome, not
    // an error: clear the exception FindClass raises and report false.
    jclass cls = (*env)->FindClass(env, "dev/nokre/shell/NokrePushService");
    if (cls == NULL) {
        (*env)->ExceptionClear(env);
        return 0;
    }
    (*env)->DeleteLocalRef(env, cls);
    return 1;
}

int32_t nokre_notification_schedule_available(void) {
    // AlarmManager holds the date without the app running. It does not
    // survive a reboot — Android clears alarms, and re-arming them would
    // mean nokre keeping a durable schedule of its own, which the design
    // refuses (docs/services.md states the posture).
    return 1;
}

int32_t nokre_notification_status(void) {
    JNIEnv *env = nt_env();
    if (env == NULL || !nt_init(env)) return NOKRE_NOTIFICATION_NOT_DETERMINED;
    jint s = (*env)->CallStaticIntMethod(env, g_cls, g_status);
    if ((*env)->ExceptionCheck(env)) {
        (*env)->ExceptionClear(env);
        return NOKRE_NOTIFICATION_NOT_DETERMINED;
    }
    return (int32_t)s;
}

void nokre_notification_authorize(void) {
    JNIEnv *env = nt_env();
    if (env == NULL || !nt_init(env)) return;
    (*env)->CallStaticVoidMethod(env, g_cls, g_authorize);
    if ((*env)->ExceptionCheck(env)) (*env)->ExceptionClear(env);
}

void nokre_notification_post(const char *id, size_t id_len, const char *title, size_t title_len,
                             const char *body, size_t body_len, const char *route, size_t route_len,
                             int32_t important, int64_t at_millis) {
    JNIEnv *env = nt_env();
    if (env == NULL || !nt_init(env)) return;
    jbyteArray jid = nt_bytes(env, id, id_len);
    jbyteArray jtitle = nt_bytes(env, title, title_len);
    jbyteArray jbody = nt_bytes(env, body, body_len);
    jbyteArray jroute = nt_bytes(env, route, route_len);
    if (jid != NULL && jtitle != NULL && jbody != NULL && jroute != NULL) {
        (*env)->CallStaticVoidMethod(env, g_cls, g_post, jid, jtitle, jbody, jroute,
                                     important ? JNI_TRUE : JNI_FALSE, (jlong)at_millis);
        if ((*env)->ExceptionCheck(env)) (*env)->ExceptionClear(env);
    }
    if (jid != NULL) (*env)->DeleteLocalRef(env, jid);
    if (jtitle != NULL) (*env)->DeleteLocalRef(env, jtitle);
    if (jbody != NULL) (*env)->DeleteLocalRef(env, jbody);
    if (jroute != NULL) (*env)->DeleteLocalRef(env, jroute);
}

void nokre_notification_cancel(const char *id, size_t id_len) {
    JNIEnv *env = nt_env();
    if (env == NULL || !nt_init(env)) return;
    jbyteArray jid = nt_bytes(env, id, id_len);
    if (jid == NULL) return;
    (*env)->CallStaticVoidMethod(env, g_cls, g_cancel, jid);
    if ((*env)->ExceptionCheck(env)) (*env)->ExceptionClear(env);
    (*env)->DeleteLocalRef(env, jid);
}

void nokre_notification_request_push(const char *key, size_t key_len) {
    (void)key;
    (void)key_len; // FCM identifies the sender by the project the app registered with
    JNIEnv *env = nt_env();
    if (env == NULL) return;
    jclass cls = (*env)->FindClass(env, "dev/nokre/shell/NokrePushService");
    if (cls == NULL) {
        (*env)->ExceptionClear(env);
        return; // push_available already answered 0
    }
    jmethodID req = (*env)->GetStaticMethodID(env, cls, "requestToken", "()V");
    if (req != NULL) {
        (*env)->CallStaticVoidMethod(env, cls, req);
        if ((*env)->ExceptionCheck(env)) (*env)->ExceptionClear(env);
    } else {
        (*env)->ExceptionClear(env);
    }
    (*env)->DeleteLocalRef(env, cls);
}

// ---- the inbound leg (NokreView.nativeNotificationEvent calls this) ----
// Every kind arrives here: the permission answered, a tap, a foreground
// arrival, a push token. The shell routes it without learning what any of
// them mean — oauth's rule, one service over.

void nokre_notification_dispatch(int32_t kind, int32_t status, const char *a, size_t a_len,
                                 const char *b, size_t b_len) {
    if (g_cb == NULL) {
        // Only a tap is worth holding: it is the reason the launch
        // happened. A token or a permission answer with nothing installed
        // is re-readable — the probes answer both at install.
        if (kind != NOKRE_NOTIFICATION_OPENED) return;
        if (a_len >= sizeof g_pending_id || b_len >= sizeof g_pending_route) return;
        memcpy(g_pending_id, a, a_len);
        g_pending_id_len = a_len;
        memcpy(g_pending_route, b, b_len);
        g_pending_route_len = b_len;
        g_has_pending = 1;
        return;
    }
    g_cb(g_ctx, kind, status, a, a_len, b, b_len);
}
