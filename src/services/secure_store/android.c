// Android side of the secure_store service: the four nokre_ss_* verbs
// (secure_store.h) bridged over JNI to dev.nokre.shell.NokreSecureStore,
// whose Keystore-wrapped SharedPreferences is the actual store
// (docs/internals/secure_store.md, "Android (Keystore)"). Unlike
// Keychain and Credential Manager, Android has no synchronous C store
// API — the encryption key lives in the AndroidKeyStore and the CRUD
// lives in the framework, so the "native leg" here is a JNI shim.
//
// Policy stays out, as on every platform: validation, caps, sort order,
// and the entry-count line all ran in secure_store.zig before any call
// lands here; this file ferries bytes and maps Java outcomes to the
// NOKRE_SS_* codes. It holds no store state — the key lives in the
// Keystore, the ciphertext in app-private prefs — matching the
// stateless-native charter (the class ref it caches is JNI plumbing,
// not the store).
//
// Compiled by the consumer's CMake next to shell.c (the Android split:
// C is NDK-built, the Zig arrives as a static lib), the same placement
// as the web leg's services.js hooks. The JavaVM comes from the shell
// (nokre_android_vm — the one JNI_OnLoad in the .so).
#include <jni.h>
#include <stdint.h>
#include <string.h>

#include "secure_store.h"

enum {
    // Mirrors max_key_bytes in secure_store.zig: the [len:u8] packing in
    // nokre_ss_list can only represent what the contract allows.
    NOKRE_SS_MAX_KEY_BYTES = 128,
    // ns + NUL and key + NUL as a C string for NewStringUTF. ns and key
    // are ASCII [a-z0-9._-] (Zig-validated), keys capped at 128 and
    // reverse-DNS ids short; a longer ns is out of contract by
    // construction, refused here rather than heaped.
    NOKRE_SS_STR_CAP = 256,
};

extern JavaVM *nokre_android_vm(void); // shell.c

// Lazily-cached NokreSecureStore class + its static verbs. First use is a
// boot read inside build, on the main thread, whose env carries the app
// classloader; a global class ref keeps it valid across later calls (and
// off the main thread, where AttachCurrentThread's env could not resolve
// an app class). Single-threaded by the sync contract — no locking.
static jclass g_cls;
static jmethodID g_get, g_set, g_delete, g_list;

static JNIEnv *ss_env(void) {
    JavaVM *vm = nokre_android_vm();
    if (vm == NULL) return NULL;
    JNIEnv *env = NULL;
    // GetEnv suffices: the verbs run on the main thread (boot read inside
    // build, or an input handler), already attached to the JVM.
    if ((*vm)->GetEnv(vm, (void **)&env, JNI_VERSION_1_6) != JNI_OK) return NULL;
    return env;
}

static int ss_init(JNIEnv *env) {
    if (g_cls != NULL) return 1;
    jclass cls = (*env)->FindClass(env, "dev/nokre/shell/NokreSecureStore");
    if (cls == NULL) {
        (*env)->ExceptionClear(env);
        return 0;
    }
    g_cls = (*env)->NewGlobalRef(env, cls);
    (*env)->DeleteLocalRef(env, cls);
    if (g_cls == NULL) return 0;
    g_get = (*env)->GetStaticMethodID(env, g_cls, "get",
                                      "(Ljava/lang/String;Ljava/lang/String;)[B");
    g_set = (*env)->GetStaticMethodID(env, g_cls, "set",
                                      "(Ljava/lang/String;Ljava/lang/String;[B)Z");
    g_delete = (*env)->GetStaticMethodID(env, g_cls, "delete",
                                         "(Ljava/lang/String;Ljava/lang/String;)Z");
    g_list = (*env)->GetStaticMethodID(env, g_cls, "list",
                                       "(Ljava/lang/String;)[Ljava/lang/String;");
    return g_get != NULL && g_set != NULL && g_delete != NULL && g_list != NULL;
}

// ns and key are ptr+len ASCII (never NUL-terminated); NewStringUTF
// needs a C string, and ASCII is identical in standard and modified
// UTF-8, so the widening is a NUL-terminated copy. Values, in contrast,
// are arbitrary bytes and always cross as byte[] (never a jstring).
static jstring ss_str(JNIEnv *env, const uint8_t *p, size_t len) {
    char buf[NOKRE_SS_STR_CAP];
    if (len >= sizeof buf) return NULL;
    memcpy(buf, p, len);
    buf[len] = 0;
    return (*env)->NewStringUTF(env, buf);
}

int32_t nokre_ss_get(const uint8_t *ns, size_t ns_len,
                   const uint8_t *key, size_t key_len,
                   uint8_t *value_buf, size_t *value_len) {
    JNIEnv *env = ss_env();
    if (env == NULL || !ss_init(env)) return NOKRE_SS_ERR_UNAVAILABLE;
    jstring jns = ss_str(env, ns, ns_len);
    jstring jkey = ss_str(env, key, key_len);
    if (jns == NULL || jkey == NULL) {
        if (jns != NULL) (*env)->DeleteLocalRef(env, jns);
        if (jkey != NULL) (*env)->DeleteLocalRef(env, jkey);
        return NOKRE_SS_ERR_UNAVAILABLE;
    }
    // Java: value bytes on success, null for absence, a thrown exception
    // for a Keystore/crypto failure. An empty value round-trips as a
    // zero-length array (a present empty value), never null.
    jbyteArray val = (*env)->CallStaticObjectMethod(env, g_cls, g_get, jns, jkey);
    (*env)->DeleteLocalRef(env, jns);
    (*env)->DeleteLocalRef(env, jkey);
    if ((*env)->ExceptionCheck(env)) {
        (*env)->ExceptionClear(env);
        return NOKRE_SS_ERR_UNAVAILABLE;
    }
    if (val == NULL) return NOKRE_SS_ABSENT;
    jsize n = (*env)->GetArrayLength(env, val);
    int32_t rc = NOKRE_SS_OK;
    if (n < 0 || (size_t)n > *value_len) {
        // An external writer's oversized blob is refused, never
        // truncated — the entry exists but cannot be served in-contract,
        // and ABSENT would invite an overwrite (secure_store.h).
        rc = NOKRE_SS_ERR_UNAVAILABLE;
    } else {
        (*env)->GetByteArrayRegion(env, val, 0, n, (jbyte *)value_buf);
        *value_len = (size_t)n;
    }
    (*env)->DeleteLocalRef(env, val);
    return rc;
}

int32_t nokre_ss_set(const uint8_t *ns, size_t ns_len,
                   const uint8_t *key, size_t key_len,
                   const uint8_t *value, size_t value_len) {
    JNIEnv *env = ss_env();
    if (env == NULL || !ss_init(env)) return NOKRE_SS_ERR_UNAVAILABLE;
    jstring jns = ss_str(env, ns, ns_len);
    jstring jkey = ss_str(env, key, key_len);
    jbyteArray jval = (*env)->NewByteArray(env, (jsize)value_len);
    if (jns == NULL || jkey == NULL || jval == NULL) {
        if (jns != NULL) (*env)->DeleteLocalRef(env, jns);
        if (jkey != NULL) (*env)->DeleteLocalRef(env, jkey);
        if (jval != NULL) (*env)->DeleteLocalRef(env, jval);
        return NOKRE_SS_ERR_UNAVAILABLE;
    }
    if (value_len > 0)
        (*env)->SetByteArrayRegion(env, jval, 0, (jsize)value_len, (const jbyte *)value);
    // Upsert; Java commits synchronously and returns false on failure.
    jboolean ok = (*env)->CallStaticBooleanMethod(env, g_cls, g_set, jns, jkey, jval);
    (*env)->DeleteLocalRef(env, jns);
    (*env)->DeleteLocalRef(env, jkey);
    (*env)->DeleteLocalRef(env, jval);
    if ((*env)->ExceptionCheck(env)) {
        (*env)->ExceptionClear(env);
        return NOKRE_SS_ERR_UNAVAILABLE;
    }
    return ok == JNI_TRUE ? NOKRE_SS_OK : NOKRE_SS_ERR_UNAVAILABLE;
}

int32_t nokre_ss_delete(const uint8_t *ns, size_t ns_len,
                      const uint8_t *key, size_t key_len) {
    JNIEnv *env = ss_env();
    if (env == NULL || !ss_init(env)) return NOKRE_SS_ERR_UNAVAILABLE;
    jstring jns = ss_str(env, ns, ns_len);
    jstring jkey = ss_str(env, key, key_len);
    if (jns == NULL || jkey == NULL) {
        if (jns != NULL) (*env)->DeleteLocalRef(env, jns);
        if (jkey != NULL) (*env)->DeleteLocalRef(env, jkey);
        return NOKRE_SS_ERR_UNAVAILABLE;
    }
    // Idempotent on the Java side: removing an absent key returns true
    // (the postcondition already held).
    jboolean ok = (*env)->CallStaticBooleanMethod(env, g_cls, g_delete, jns, jkey);
    (*env)->DeleteLocalRef(env, jns);
    (*env)->DeleteLocalRef(env, jkey);
    if ((*env)->ExceptionCheck(env)) {
        (*env)->ExceptionClear(env);
        return NOKRE_SS_ERR_UNAVAILABLE;
    }
    return ok == JNI_TRUE ? NOKRE_SS_OK : NOKRE_SS_ERR_UNAVAILABLE;
}

int32_t nokre_ss_list(const uint8_t *ns, size_t ns_len,
                    uint8_t *list_buf, size_t list_cap) {
    JNIEnv *env = ss_env();
    if (env == NULL || !ss_init(env)) return NOKRE_SS_ERR_UNAVAILABLE;
    jstring jns = ss_str(env, ns, ns_len);
    if (jns == NULL) return NOKRE_SS_ERR_UNAVAILABLE;
    // Java: the namespace's keys (order unspecified — Zig sorts), or null
    // on failure. A fresh install returns an empty array, count 0, never
    // an error — the first-ever set consults list for the StoreFull line.
    jobjectArray arr = (*env)->CallStaticObjectMethod(env, g_cls, g_list, jns);
    (*env)->DeleteLocalRef(env, jns);
    if ((*env)->ExceptionCheck(env)) {
        (*env)->ExceptionClear(env);
        return NOKRE_SS_ERR_UNAVAILABLE;
    }
    if (arr == NULL) return NOKRE_SS_ERR_UNAVAILABLE;

    jsize count = (*env)->GetArrayLength(env, arr);
    int32_t n = 0;
    size_t off = 0;
    for (jsize i = 0; i < count; i++) {
        jstring ks = (jstring)(*env)->GetObjectArrayElement(env, arr, i);
        if (ks == NULL) continue;
        // Keys are ASCII by contract (we only ever wrote validKey keys),
        // so the modified-UTF-8 length equals the byte length and the
        // chars are the bytes. A key the [len:u8] packing cannot
        // represent is skipped, defensively.
        jsize klen = (*env)->GetStringUTFLength(env, ks);
        if (klen <= 0 || klen > NOKRE_SS_MAX_KEY_BYTES) {
            (*env)->DeleteLocalRef(env, ks);
            continue;
        }
        // Past capacity the subset is unspecified: stop without error
        // (secure_store.h — the Zig side sorts then truncates to 64).
        if (off + 1 + (size_t)klen > list_cap) {
            (*env)->DeleteLocalRef(env, ks);
            break;
        }
        const char *chars = (*env)->GetStringUTFChars(env, ks, NULL);
        if (chars == NULL) {
            (*env)->DeleteLocalRef(env, ks);
            continue;
        }
        list_buf[off] = (uint8_t)klen;
        memcpy(list_buf + off + 1, chars, (size_t)klen);
        (*env)->ReleaseStringUTFChars(env, ks, chars);
        (*env)->DeleteLocalRef(env, ks);
        off += 1 + (size_t)klen;
        n += 1;
    }
    (*env)->DeleteLocalRef(env, arr);
    return n;
}
