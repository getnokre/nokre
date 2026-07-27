// Android side of the oauth service: the two browser verbs of oauth.h
// bridged over JNI to dev.nokre.shell.NokreOAuth, which launches a Custom
// Tab (docs/services.md; design in docs/internals/oauth.md).
//
// A Custom Tab, not a WebView: the tab is the user's own browser process
// with the user's own cookies, so it is the "system browser" RFC 8252
// asks for, and the app cannot read what is typed into it. Skipping
// Google's Play Services sign-in SDK costs exactly one thing, named
// plainly: no Credential Manager one-tap — the user sees a tab. It buys
// nokre not having to invent a dependency manager to host a vendored
// SDK, which is the whole reason the browser flow was chosen.
//
// Policy stays out, as on every platform: the redirect string, the
// scheme, and the one-flow rule all ran in oauth.zig before any call
// lands here. This file holds the ctx + callback of the one live flow —
// the single-app anchor deep_link's shell hook already uses on this
// platform, for the same reason: an Android process hosts one nokre
// app.
//
// Compiled by the consumer's CMake next to shell.c (the Android split:
// C is NDK-built, the Zig arrives as a static lib), the same placement
// as secure_store's android.c. The JavaVM comes from the shell
// (nokre_android_vm — the one JNI_OnLoad in the .so).
#include <jni.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#include "oauth.h"

extern JavaVM *nokre_android_vm(void); // shell.c

// The one live flow. Not a table: the service allows a single session
// per app and an Android process hosts a single app, so a request id
// would be ceremony over a value that can only ever be one.
static void *g_ctx;
static nokre_oauth_cb g_cb;
// A sentinel handle: the "session" is a tab in another process, so there
// is nothing to hold — but oauth.h's contract is that NULL means the
// flow never started, and this one did.
static int g_session;

static jclass g_cls;
static jmethodID g_start, g_forget;

static JNIEnv *oauth_env(void) {
    JavaVM *vm = nokre_android_vm();
    if (vm == NULL) return NULL;
    JNIEnv *env = NULL;
    // GetEnv suffices: start runs on the main thread (inside an input
    // handler), already attached to the JVM, and the inbound leg arrives
    // from Java.
    if ((*vm)->GetEnv(vm, (void **)&env, JNI_VERSION_1_6) != JNI_OK) return NULL;
    return env;
}

static int oauth_init(JNIEnv *env) {
    if (g_cls != NULL) return 1;
    jclass cls = (*env)->FindClass(env, "dev/nokre/shell/NokreOAuth");
    if (cls == NULL) {
        (*env)->ExceptionClear(env);
        return 0;
    }
    g_cls = (*env)->NewGlobalRef(env, cls);
    (*env)->DeleteLocalRef(env, cls);
    if (g_cls == NULL) return 0;
    g_start = (*env)->GetStaticMethodID(env, g_cls, "start", "(Ljava/lang/String;)Z");
    g_forget = (*env)->GetStaticMethodID(env, g_cls, "forget", "()V");
    return g_start != NULL && g_forget != NULL;
}

void *nokre_oauth_start(void *ctx, nokre_oauth_cb cb,
                      const char *url, size_t url_len,
                      const char *scheme, size_t scheme_len) {
    // The scheme is registered in the manifest, not passed to the
    // browser: on Android the OS routes the redirect by intent-filter,
    // so the tab is told nothing about where it will end up.
    (void)scheme;
    (void)scheme_len;
    JNIEnv *env = oauth_env();
    if (env == NULL || !oauth_init(env)) return NULL;

    // The authorize URL is arbitrary bytes as far as C is concerned, and
    // NewStringUTF wants a C string; a heap copy is the honest widening
    // (unlike secure_store's ASCII keys, a URL has no small fixed cap).
    char *url_z = (char *)malloc(url_len + 1);
    if (url_z == NULL) return NULL;
    memcpy(url_z, url, url_len);
    url_z[url_len] = 0;
    jstring jurl = (*env)->NewStringUTF(env, url_z);
    free(url_z);
    if (jurl == NULL) {
        (*env)->ExceptionClear(env);
        return NULL;
    }

    g_ctx = ctx;
    g_cb = cb;
    jboolean ok = (*env)->CallStaticBooleanMethod(env, g_cls, g_start, jurl);
    (*env)->DeleteLocalRef(env, jurl);
    if ((*env)->ExceptionCheck(env)) {
        (*env)->ExceptionClear(env);
        ok = JNI_FALSE;
    }
    if (!ok) {
        g_ctx = NULL;
        g_cb = NULL;
        return NULL;
    }
    return &g_session;
}

void nokre_oauth_cancel(void *session) {
    (void)session;
    g_ctx = NULL;
    g_cb = NULL;
    JNIEnv *env = oauth_env();
    // Best effort: the tab belongs to the browser and cannot be closed
    // from here. What `forget` does is stop Java reporting a cancel when
    // the app next resumes — the app already knows it cancelled.
    if (env != NULL && oauth_init(env)) {
        (*env)->CallStaticVoidMethod(env, g_cls, g_forget);
        if ((*env)->ExceptionCheck(env)) (*env)->ExceptionClear(env);
    }
}

// ---- the inbound leg (NokreView.nativeAuthResult calls this) ----
// Two ways a flow ends on Android and only one of them is an event: the
// redirect arrives as an intent (status 0, with the URL), or the user
// backs out of the tab and the app resumes with nothing (status 1). The
// second is not something the OS reports — it is the *absence* of the
// first, which is why the Java side has to notice it.

void nokre_oauth_dispatch(int status, const char *text, size_t len) {
    nokre_oauth_cb cb = g_cb;
    if (cb == NULL) return; // no flow, or the app already cancelled
    void *ctx = g_ctx;
    g_cb = NULL;
    g_ctx = NULL;
    cb(ctx, status, text, len);
}
