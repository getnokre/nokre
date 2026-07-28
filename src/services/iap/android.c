// Android side of the iap service: the verbs of iap.h bridged over JNI
// to dev.nokre.shell.NokreBilling, which drives the Play Billing Library
// (docs/services.md; design in docs/internals/iap.md).
//
// The shell registers nothing for this service and never learns what a
// purchase is — unlike oauth, whose redirect arrives as an Activity
// intent only the shell can see. Play calls NokreBilling directly, so the
// inbound half is plain name-mangled JNI exports below, resolved out of
// the app's own .so once the shell has loaded it.
//
// Policy stays out, as on every platform: the caps, the id charset, the
// one-sheet rule, and the queueing all ran in iap.zig before any call
// lands here. This file holds the ctx + callbacks of the one live app —
// the single-app anchor every Android leg takes, for the same reason.
//
// Compiled by the consumer's CMake next to shell.c (the Android split:
// C is NDK-built, the Zig arrives as a static lib), the same placement
// as oauth's and secure_store's android.c. The JavaVM comes from the
// shell (nokre_android_vm — the one JNI_OnLoad in the .so).
#include <jni.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#include "iap.h"

extern JavaVM *nokre_android_vm(void); // shell.c

// The stream's landing pad, installed once.
static void *g_ctx;
static nokre_iap_update_cb g_cb;
// The live catalog query. One at a time by contract, so a request id
// would be ceremony over a value that can only ever be one.
static void *g_query_ctx;
static nokre_iap_products_cb g_query_cb;

// Rows accumulate here between `nativeProductRow` calls and the single
// `nativeProductsDone` that ends the query. Bounded by the service's own
// cap, which is what makes the array legal; a row past it is dropped
// rather than growing an allocation the app never asked for.
#define NOKRE_IAP_MAX_ROWS 20
// Six owned strings per row — id, title, description, price, currency,
// offer — because a jstring's bytes are the JVM's and die long before
// the callback that reads them.
#define NOKRE_IAP_ROW_STRINGS 6
static nokre_iap_product g_rows[NOKRE_IAP_MAX_ROWS];
static char *g_row_strings[NOKRE_IAP_MAX_ROWS * NOKRE_IAP_ROW_STRINGS];
static size_t g_row_count;

static jclass g_cls;
static jmethodID g_available, g_install, g_query, g_purchase, g_finish, g_restore;

static JNIEnv *iap_env(void) {
    JavaVM *vm = nokre_android_vm();
    if (vm == NULL) return NULL;
    JNIEnv *env = NULL;
    // GetEnv suffices: every outbound call runs on the main thread (from
    // App.init or an input handler), already attached to the JVM, and
    // the inbound legs arrive from Java.
    if ((*vm)->GetEnv(vm, (void **)&env, JNI_VERSION_1_6) != JNI_OK) return NULL;
    return env;
}

static int iap_init(JNIEnv *env) {
    if (g_cls != NULL) return 1;
    jclass cls = (*env)->FindClass(env, "dev/nokre/shell/NokreBilling");
    if (cls == NULL) {
        // Not on the classpath: the app linked the service but did not
        // add the source set and the coordinate. Every verb then answers
        // "no store", which is the same honest answer Windows gives.
        (*env)->ExceptionClear(env);
        return 0;
    }
    jclass gcls = (*env)->NewGlobalRef(env, cls);
    (*env)->DeleteLocalRef(env, cls);
    if (gcls == NULL) {
        (*env)->ExceptionClear(env);
        return 0;
    }
    jmethodID available = (*env)->GetStaticMethodID(env, gcls, "available", "()Z");
    jmethodID install = (*env)->GetStaticMethodID(env, gcls, "install", "()V");
    jmethodID query = (*env)->GetStaticMethodID(env, gcls, "queryProducts", "([Ljava/lang/String;)V");
    jmethodID purchase = (*env)->GetStaticMethodID(env, gcls, "purchase",
                                                   "(Ljava/lang/String;Ljava/lang/String;)I");
    jmethodID finish = (*env)->GetStaticMethodID(env, gcls, "finish", "(Ljava/lang/String;Z)V");
    jmethodID restore = (*env)->GetStaticMethodID(env, gcls, "restore", "()V");
    if (available == NULL || install == NULL || query == NULL || purchase == NULL ||
        finish == NULL || restore == NULL) {
        // All-or-nothing: g_cls is the cache flag, so a half-resolved
        // class must not be published — a later call would invoke NULL
        // method ids with a NoSuchMethodError still pending.
        (*env)->ExceptionClear(env);
        (*env)->DeleteGlobalRef(env, gcls);
        return 0;
    }
    g_available = available;
    g_install = install;
    g_query = query;
    g_purchase = purchase;
    g_finish = finish;
    g_restore = restore;
    g_cls = gcls;
    return 1;
}

/// A jstring as a freshly allocated UTF-8 copy. The caller frees; NULL in
/// means an empty string out, so no caller needs a null branch.
static char *iap_utf8(JNIEnv *env, jstring s, size_t *out_len) {
    *out_len = 0;
    char *copy = (char *)malloc(1);
    if (copy == NULL) return NULL;
    copy[0] = 0;
    if (s == NULL) return copy;
    const char *raw = (*env)->GetStringUTFChars(env, s, NULL);
    if (raw == NULL) {
        (*env)->ExceptionClear(env);
        return copy;
    }
    size_t len = strlen(raw);
    char *grown = (char *)realloc(copy, len + 1);
    if (grown == NULL) {
        (*env)->ReleaseStringUTFChars(env, s, raw);
        return copy;
    }
    memcpy(grown, raw, len + 1);
    (*env)->ReleaseStringUTFChars(env, s, raw);
    *out_len = len;
    return grown;
}

static jstring iap_jstring(JNIEnv *env, const char *bytes, size_t len) {
    char *z = (char *)malloc(len + 1);
    if (z == NULL) return NULL;
    memcpy(z, bytes, len);
    z[len] = 0;
    jstring s = (*env)->NewStringUTF(env, z);
    free(z);
    if (s == NULL) (*env)->ExceptionClear(env);
    return s;
}

static void iap_clear_rows(void) {
    for (size_t i = 0; i < g_row_count * NOKRE_IAP_ROW_STRINGS; i++) {
        free(g_row_strings[i]);
        g_row_strings[i] = NULL;
    }
    g_row_count = 0;
}

// ---- iap.h, outbound ----

int nokre_iap_available(void) {
    JNIEnv *env = iap_env();
    if (env == NULL || !iap_init(env)) return 0;
    jboolean ok = (*env)->CallStaticBooleanMethod(env, g_cls, g_available);
    if ((*env)->ExceptionCheck(env)) {
        (*env)->ExceptionClear(env);
        return 0;
    }
    return ok ? 1 : 0;
}

void nokre_iap_uninstall(void) {
    // The Play listener stays registered (one per process); with the
    // callbacks gone, nativeUpdate and nativeProductsDone drop their
    // deliveries instead of calling into an app that no longer exists.
    g_ctx = NULL;
    g_cb = NULL;
    g_query_ctx = NULL;
    g_query_cb = NULL;
}

void nokre_iap_install(void *ctx, nokre_iap_update_cb cb) {
    g_ctx = ctx;
    g_cb = cb;
    JNIEnv *env = iap_env();
    if (env == NULL || !iap_init(env)) return;
    (*env)->CallStaticVoidMethod(env, g_cls, g_install);
    if ((*env)->ExceptionCheck(env)) (*env)->ExceptionClear(env);
}

void nokre_iap_products(void *ctx, nokre_iap_products_cb cb, const char *const *ids,
                      const size_t *id_lens, size_t count) {
    g_query_ctx = ctx;
    g_query_cb = cb;
    iap_clear_rows();

    JNIEnv *env = iap_env();
    if (env == NULL || !iap_init(env)) {
        if (cb != NULL) cb(ctx, NULL, 0, "StoreUnavailable", 16);
        return;
    }
    jclass string_cls = (*env)->FindClass(env, "java/lang/String");
    if (string_cls == NULL) {
        (*env)->ExceptionClear(env);
        if (cb != NULL) cb(ctx, NULL, 0, "StoreUnavailable", 16);
        return;
    }
    jobjectArray arr = (*env)->NewObjectArray(env, (jsize)count, string_cls, NULL);
    (*env)->DeleteLocalRef(env, string_cls);
    if (arr == NULL) {
        (*env)->ExceptionClear(env);
        if (cb != NULL) cb(ctx, NULL, 0, "OutOfMemory", 11);
        return;
    }
    for (size_t i = 0; i < count; i++) {
        jstring s = iap_jstring(env, ids[i], id_lens[i]);
        if (s == NULL) continue;
        (*env)->SetObjectArrayElement(env, arr, (jsize)i, s);
        (*env)->DeleteLocalRef(env, s);
    }
    (*env)->CallStaticVoidMethod(env, g_cls, g_query, arr);
    (*env)->DeleteLocalRef(env, arr);
    if ((*env)->ExceptionCheck(env)) {
        (*env)->ExceptionClear(env);
        if (cb != NULL) cb(ctx, NULL, 0, "StoreUnavailable", 16);
    }
}

int nokre_iap_purchase(const char *product, size_t product_len, const char *offer,
                     size_t offer_len) {
    JNIEnv *env = iap_env();
    if (env == NULL || !iap_init(env)) return NOKRE_IAP_ERR_NO_SHEET;
    jstring jproduct = iap_jstring(env, product, product_len);
    jstring joffer = iap_jstring(env, offer, offer_len);
    if (jproduct == NULL) {
        if (joffer != NULL) (*env)->DeleteLocalRef(env, joffer);
        return NOKRE_IAP_ERR_NO_SHEET;
    }
    jint rc = (*env)->CallStaticIntMethod(env, g_cls, g_purchase, jproduct, joffer);
    (*env)->DeleteLocalRef(env, jproduct);
    if (joffer != NULL) (*env)->DeleteLocalRef(env, joffer);
    if ((*env)->ExceptionCheck(env)) {
        (*env)->ExceptionClear(env);
        return NOKRE_IAP_ERR_NO_SHEET;
    }
    return (int)rc;
}

void nokre_iap_finish(const char *txn, size_t txn_len, int consume) {
    JNIEnv *env = iap_env();
    if (env == NULL || !iap_init(env)) return;
    // The transaction id this leg reports IS the purchase token
    // (NokreBilling.java says why), so it goes straight back.
    jstring jtxn = iap_jstring(env, txn, txn_len);
    if (jtxn == NULL) return;
    (*env)->CallStaticVoidMethod(env, g_cls, g_finish, jtxn, consume ? JNI_TRUE : JNI_FALSE);
    (*env)->DeleteLocalRef(env, jtxn);
    if ((*env)->ExceptionCheck(env)) (*env)->ExceptionClear(env);
}

void nokre_iap_restore(void) {
    JNIEnv *env = iap_env();
    if (env == NULL || !iap_init(env)) return;
    (*env)->CallStaticVoidMethod(env, g_cls, g_restore);
    if ((*env)->ExceptionCheck(env)) (*env)->ExceptionClear(env);
}

// ---- the inbound legs (NokreBilling's own natives) ----
// Play answers on the main thread, so these reach Zig where every other
// inbound event does.

JNIEXPORT void JNICALL Java_dev_nokre_shell_NokreBilling_nativeProductRow(
    JNIEnv *env, jclass cls, jstring id, jstring title, jstring description, jstring price,
    jstring currency, jstring offer, jlong price_micros, jint kind) {
    (void)cls;
    // A row past the cap is dropped: the app asked for at most that many
    // ids, so a store answering with more is answering something nobody
    // asked. Zig drops the same overflow for the same reason.
    if (g_row_count >= NOKRE_IAP_MAX_ROWS) return;
    size_t n = g_row_count;
    char **held = &g_row_strings[n * NOKRE_IAP_ROW_STRINGS];
    nokre_iap_product *row = &g_rows[n];

    held[0] = iap_utf8(env, id, &row->id_len);
    held[1] = iap_utf8(env, title, &row->title_len);
    held[2] = iap_utf8(env, description, &row->description_len);
    held[3] = iap_utf8(env, price, &row->price_len);
    held[4] = iap_utf8(env, currency, &row->currency_len);
    held[5] = iap_utf8(env, offer, &row->offer_len);
    for (int i = 0; i < NOKRE_IAP_ROW_STRINGS; i++) {
        if (held[i] != NULL) continue;
        // Out of memory: drop this row and keep the query. A catalog
        // short one row still prices the rest, which beats failing a
        // paywall whole.
        for (int j = 0; j < NOKRE_IAP_ROW_STRINGS; j++) {
            free(held[j]);
            held[j] = NULL;
        }
        return;
    }
    row->id = held[0];
    row->title = held[1];
    row->description = held[2];
    row->price = held[3];
    row->currency = held[4];
    row->offer = held[5];
    row->price_micros = (unsigned long long)price_micros;
    row->kind = (int)kind;
    g_row_count = n + 1;
}

JNIEXPORT void JNICALL Java_dev_nokre_shell_NokreBilling_nativeProductsDone(JNIEnv *env, jclass cls,
                                                                          jstring err) {
    (void)cls;
    nokre_iap_products_cb cb = g_query_cb;
    void *ctx = g_query_ctx;
    g_query_cb = NULL;
    g_query_ctx = NULL;
    size_t err_len = 0;
    char *err_z = iap_utf8(env, err, &err_len);
    if (cb != NULL) cb(ctx, g_row_count != 0 ? g_rows : NULL, g_row_count,
                       err_z != NULL ? err_z : "", err_len);
    free(err_z);
    iap_clear_rows();
}

JNIEXPORT void JNICALL Java_dev_nokre_shell_NokreBilling_nativeUpdate(JNIEnv *env, jclass cls,
                                                                     jint status, jstring txn,
                                                                     jstring product, jstring token,
                                                                     jstring err) {
    (void)cls;
    nokre_iap_update_cb cb = g_cb;
    if (cb == NULL) return; // the app has not registered a handler
    size_t txn_len = 0, product_len = 0, token_len = 0, err_len = 0;
    char *txn_z = iap_utf8(env, txn, &txn_len);
    char *product_z = iap_utf8(env, product, &product_len);
    char *token_z = iap_utf8(env, token, &token_len);
    char *err_z = iap_utf8(env, err, &err_len);
    if (txn_z != NULL && product_z != NULL && token_z != NULL && err_z != NULL) {
        cb(g_ctx, (int)status, txn_z, txn_len, product_z, product_len, token_z, token_len, err_z,
           err_len);
    }
    free(txn_z);
    free(product_z);
    free(token_z);
    free(err_z);
}
