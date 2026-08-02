// Linux side of the secure_store service: four verbs against the Secret
// Service (secure_store.h) via libsecret. The Secret Service is the
// desktop's own keyring daemon (GNOME Keyring, KWallet's secretsd) — the
// twin of Keychain and Credential Manager: entries are encrypted at rest
// under the login keyring and appear in the user's own keyring UI where
// they can be inspected and revoked. The native side holds nothing
// between calls; every policy (validation, caps, sort order, the
// entry-count line) already ran Zig-side.
//
// libsecret's password API stores a NUL-terminated string, but a
// secure_store value is arbitrary bytes up to the value cap (embedded
// NULs included), so values are hex-encoded on the way in and decoded
// on the way out — the round-trip is exact and the stored form stays a clean C
// string, the way the Windows leg widens keys per-unit. Two indexed
// attributes, "namespace" and "key", scope every entry; search by
// "namespace" alone backs list.
#include <libsecret/secret.h>
#include <string.h>

#include "secure_store.h"

enum {
    NOKRE_SS_NS_CAP = 256, // reverse-DNS ids are short; longer is out of contract
};

// One schema for every nokre app; the "namespace" attribute (the app's
// reverse-DNS id) is what keeps two apps' stores disjoint, exactly as the
// Zig side promises. SECRET_SCHEMA_NONE: no libsecret-side name matching,
// so an id that is not a dotted reverse-DNS string still stores cleanly.
static const SecretSchema *nokre_ss_schema(void) {
    static const SecretSchema schema = {
        "dev.nokre.secure_store",
        SECRET_SCHEMA_NONE,
        {
            {"namespace", SECRET_SCHEMA_ATTRIBUTE_STRING},
            {"key", SECRET_SCHEMA_ATTRIBUTE_STRING},
            {NULL, 0},
        },
    };
    return &schema;
}

// ptr+len (never NUL-terminated, [a-z0-9._-] Zig-side) → a C string in
// `out` of capacity `cap`. Returns 0 if it would not fit.
static int to_cstr(const uint8_t *p, size_t len, char *out, size_t cap) {
    if (len + 1 > cap) return 0;
    memcpy(out, p, len);
    out[len] = 0;
    return 1;
}

static char hex_digit(unsigned v) { return (char)(v < 10 ? '0' + v : 'a' + (v - 10)); }

// Lowercase-hex encode `value` into `out` (capacity 2*len+1); NUL-terminates.
static void hex_encode(const uint8_t *value, size_t len, char *out) {
    for (size_t i = 0; i < len; i++) {
        out[2 * i] = hex_digit(value[i] >> 4);
        out[2 * i + 1] = hex_digit(value[i] & 0xF);
    }
    out[2 * len] = 0;
}

static int hex_val(char c, unsigned *out) {
    if (c >= '0' && c <= '9') { *out = (unsigned)(c - '0'); return 1; }
    if (c >= 'a' && c <= 'f') { *out = (unsigned)(c - 'a' + 10); return 1; }
    if (c >= 'A' && c <= 'F') { *out = (unsigned)(c - 'A' + 10); return 1; }
    return 0;
}

// Decode hex `s` into `buf` (capacity `cap`), writing the length to
// `*out_len`. Returns 0 for malformed or oversized input — an external
// writer's, never this service's — so get can refuse it in-contract.
static int hex_decode(const char *s, uint8_t *buf, size_t cap, size_t *out_len) {
    size_t slen = strlen(s);
    if (slen % 2 != 0) return 0;
    size_t n = slen / 2;
    if (n > cap) return 0;
    for (size_t i = 0; i < n; i++) {
        unsigned hi, lo;
        if (!hex_val(s[2 * i], &hi) || !hex_val(s[2 * i + 1], &lo)) return 0;
        buf[i] = (uint8_t)((hi << 4) | lo);
    }
    *out_len = n;
    return 1;
}

int32_t nokre_ss_get(const uint8_t *ns, size_t ns_len,
                   const uint8_t *key, size_t key_len,
                   uint8_t *value_buf, size_t *value_len) {
    char ns_z[NOKRE_SS_NS_CAP], key_z[NOKRE_SS_MAX_KEY_BYTES + 1];
    if (!to_cstr(ns, ns_len, ns_z, sizeof(ns_z)) ||
        !to_cstr(key, key_len, key_z, sizeof(key_z)))
        return NOKRE_SS_ERR_UNAVAILABLE;
    GError *err = NULL;
    gchar *hex = secret_password_lookup_sync(nokre_ss_schema(), NULL, &err,
                                             "namespace", ns_z, "key", key_z, NULL);
    if (err != NULL) {
        // A locked or denied keyring — the environmental failure every
        // consumer already handles.
        g_error_free(err);
        return NOKRE_SS_ERR_UNAVAILABLE;
    }
    if (hex == NULL) return NOKRE_SS_ABSENT; // missing is data, not a failure
    size_t decoded = 0;
    int ok = hex_decode(hex, value_buf, *value_len, &decoded);
    secret_password_free(hex);
    if (!ok) {
        // An external writer's malformed or oversized value: the entry
        // exists but cannot be served in-contract, and ABSENT would
        // invite an overwrite (secure_store.h).
        return NOKRE_SS_ERR_UNAVAILABLE;
    }
    *value_len = decoded;
    return NOKRE_SS_OK;
}

int32_t nokre_ss_set(const uint8_t *ns, size_t ns_len,
                   const uint8_t *key, size_t key_len,
                   const uint8_t *value, size_t value_len) {
    char ns_z[NOKRE_SS_NS_CAP], key_z[NOKRE_SS_MAX_KEY_BYTES + 1];
    if (!to_cstr(ns, ns_len, ns_z, sizeof(ns_z)) ||
        !to_cstr(key, key_len, key_z, sizeof(key_z)))
        return NOKRE_SS_ERR_UNAVAILABLE;
    if (value_len > NOKRE_SS_MAX_VALUE_BYTES) return NOKRE_SS_ERR_UNAVAILABLE;
    char hex[2 * NOKRE_SS_MAX_VALUE_BYTES + 1];
    hex_encode(value, value_len, hex);
    // The label is what the user sees in their keyring app; "<ns>/<key>"
    // reads the way the entry is scoped. Storing an existing pair
    // overwrites it — libsecret's store is the atomic upsert set wants.
    char label[NOKRE_SS_NS_CAP + 1 + NOKRE_SS_MAX_KEY_BYTES + 1];
    g_snprintf(label, sizeof(label), "%s/%s", ns_z, key_z);
    GError *err = NULL;
    gboolean ok = secret_password_store_sync(nokre_ss_schema(), SECRET_COLLECTION_DEFAULT,
                                             label, hex, NULL, &err,
                                             "namespace", ns_z, "key", key_z, NULL);
    if (err != NULL) g_error_free(err);
    return ok ? NOKRE_SS_OK : NOKRE_SS_ERR_UNAVAILABLE;
}

int32_t nokre_ss_delete(const uint8_t *ns, size_t ns_len,
                      const uint8_t *key, size_t key_len) {
    char ns_z[NOKRE_SS_NS_CAP], key_z[NOKRE_SS_MAX_KEY_BYTES + 1];
    if (!to_cstr(ns, ns_len, ns_z, sizeof(ns_z)) ||
        !to_cstr(key, key_len, key_z, sizeof(key_z)))
        return NOKRE_SS_ERR_UNAVAILABLE;
    GError *err = NULL;
    gboolean removed = secret_password_clear_sync(nokre_ss_schema(), NULL, &err,
                                                  "namespace", ns_z, "key", key_z, NULL);
    if (err != NULL) {
        g_error_free(err);
        return NOKRE_SS_ERR_UNAVAILABLE;
    }
    // removed == FALSE with no error means there was nothing to remove —
    // deleting an absent key is the postcondition already met.
    (void)removed;
    return NOKRE_SS_OK;
}

int32_t nokre_ss_list(const uint8_t *ns, size_t ns_len,
                    uint8_t *list_buf, size_t list_cap) {
    char ns_z[NOKRE_SS_NS_CAP];
    if (!to_cstr(ns, ns_len, ns_z, sizeof(ns_z))) return NOKRE_SS_ERR_UNAVAILABLE;
    GError *err = NULL;
    // Search every entry in our namespace; attributes come back so we can
    // read each "key" without unlocking the secrets themselves.
    GList *items = secret_password_search_sync(
        nokre_ss_schema(), SECRET_SEARCH_ALL, NULL, &err, "namespace", ns_z, NULL);
    if (err != NULL) {
        g_error_free(err);
        return NOKRE_SS_ERR_UNAVAILABLE;
    }
    int32_t n = 0;
    size_t buf_off = 0;
    for (GList *l = items; l != NULL; l = l->next) {
        SecretRetrievable *item = SECRET_RETRIEVABLE(l->data);
        GHashTable *attrs = secret_retrievable_get_attributes(item);
        const char *k = attrs ? g_hash_table_lookup(attrs, "key") : NULL;
        if (k != NULL) {
            size_t key_len = strlen(k);
            // A key the [len:u8] packing cannot represent is refused here,
            // not hallucinated into the contract; the Zig side additionally
            // drops any key outside the charset.
            if (key_len > 0 && key_len <= NOKRE_SS_MAX_KEY_BYTES &&
                buf_off + 1 + key_len <= list_cap) {
                list_buf[buf_off] = (uint8_t)key_len;
                memcpy(list_buf + buf_off + 1, k, key_len);
                buf_off += 1 + key_len;
                n += 1;
            }
            // Past capacity the subset is unspecified external-writer
            // territory the OS cannot make deterministic: stop, no error.
            else if (buf_off + 1 + key_len > list_cap) {
                if (attrs) g_hash_table_unref(attrs);
                break;
            }
        }
        if (attrs) g_hash_table_unref(attrs);
    }
    g_list_free_full(items, g_object_unref);
    return n;
}
