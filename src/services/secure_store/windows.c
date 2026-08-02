// Windows side of the secure_store service: four verbs against the
// Credential Manager (secure_store.h). CredMan, not raw DPAPI: DPAPI is
// a cipher, not a store — CryptProtectData hands back ciphertext and
// would force this service to invent an on-disk container (a format, a
// location, locking, corruption recovery), which is state, and the
// native side holds none. CredMan blobs are DPAPI-encrypted at rest
// anyway, and entries appear in the OS's own Credential Manager panel
// where a user can inspect and revoke them. The trade has a price,
// paid in the open: CredMan's blob ceiling is what caps a value on
// every platform (docs/services.md's per-platform table), where a
// DPAPI file would have no ceiling at all.
#include <windows.h>
#include <wincred.h>
#include <string.h>

#include "secure_store.h"

// Windows is the platform that *sets* the value ceiling, so this is
// where the contract meets its source: CredWriteW refuses a blob past
// CRED_MAX_CREDENTIAL_BLOB_SIZE with ERROR_INVALID_PARAMETER, and no
// other linked backend bounds a value anywhere near it.
//
// The number is written out rather than taken from the header in
// scope, because the headers disagree: Vista raised the ceiling to
// 5 * 512 and the Windows SDK says so, but mingw-w64's wincred.h —
// what `zig build check-targets` cross-compiles this file against —
// still carries the pre-Vista 512. nokre ships no pre-Vista target, so
// 2560 is the number the contract is derived from, and the #error
// below is the gate that keeps secure_store.h's copy from drifting off
// it without someone reading this paragraph first.
#define NOKRE_SS_CRED_BLOB_MAX 2560 /* CRED_MAX_CREDENTIAL_BLOB_SIZE, Vista and later */
#if NOKRE_SS_MAX_VALUE_BYTES > NOKRE_SS_CRED_BLOB_MAX
#error "secure_store's value cap exceeds CRED_MAX_CREDENTIAL_BLOB_SIZE: CredWriteW would refuse it"
#endif

enum {
    // ns + "/" + key + NUL, in UTF-16 units. Keys are capped by the
    // contract and reverse-DNS ids are short; a target that cannot
    // fit is by construction out of contract, and refusing it here is
    // cheaper than a heap the native side is forbidden to have.
    NOKRE_SS_TARGET_CAP = 512,
};

// TargetName = UTF-16(ns + "/" + key). The Zig-side lowercase charset
// makes widening a per-unit copy and makes CredMan's case-insensitive
// lookup unable to alias two contract keys; "/" sits outside both the
// charset and reverse-DNS ids, so namespaces can never alias
// ("com.a" vs "com.a.b").
static int build_target(const uint8_t *ns, size_t ns_len,
                        const uint8_t *key, size_t key_len,
                        WCHAR *out) {
    if (ns_len + 1 + key_len + 1 > NOKRE_SS_TARGET_CAP) return 0;
    size_t off = 0;
    for (size_t i = 0; i < ns_len; i++) out[off++] = (WCHAR)ns[i];
    out[off++] = L'/';
    for (size_t i = 0; i < key_len; i++) out[off++] = (WCHAR)key[i];
    out[off] = 0;
    return 1;
}

int32_t nokre_ss_get(const uint8_t *ns, size_t ns_len,
                   const uint8_t *key, size_t key_len,
                   uint8_t *value_buf, size_t *value_len) {
    WCHAR target[NOKRE_SS_TARGET_CAP];
    if (!build_target(ns, ns_len, key, key_len, target)) return NOKRE_SS_ERR_UNAVAILABLE;
    PCREDENTIALW cred = NULL;
    if (!CredReadW(target, CRED_TYPE_GENERIC, 0, &cred)) {
        // A missing entry is data, not a failure; everything else — a
        // dead logon session, a broken vault — degrades to the same
        // closed answer every consumer must already handle.
        return GetLastError() == ERROR_NOT_FOUND ? NOKRE_SS_ABSENT : NOKRE_SS_ERR_UNAVAILABLE;
    }
    int32_t rc = NOKRE_SS_OK;
    if (cred->CredentialBlobSize > *value_len) {
        // An external writer's oversized blob is refused, never
        // truncated — the entry exists but cannot be served
        // in-contract, and ABSENT would invite an overwrite
        // (secure_store.h).
        rc = NOKRE_SS_ERR_UNAVAILABLE;
    } else {
        memcpy(value_buf, cred->CredentialBlob, cred->CredentialBlobSize);
        *value_len = cred->CredentialBlobSize;
    }
    CredFree(cred);
    return rc;
}

int32_t nokre_ss_set(const uint8_t *ns, size_t ns_len,
                   const uint8_t *key, size_t key_len,
                   const uint8_t *value, size_t value_len) {
    WCHAR target[NOKRE_SS_TARGET_CAP];
    if (!build_target(ns, ns_len, key, key_len, target)) return NOKRE_SS_ERR_UNAVAILABLE;
    CREDENTIALW cred = {0};
    cred.Type = CRED_TYPE_GENERIC;
    cred.TargetName = target;
    cred.CredentialBlob = value_len > 0 ? (LPBYTE)value : NULL;
    cred.CredentialBlobSize = (DWORD)value_len;
    // Per-user, survives reboot, never roams — the deliberate twin of
    // Apple's ThisDeviceOnly: an entry can only appear because this
    // app wrote it on this device.
    cred.Persist = CRED_PERSIST_LOCAL_MACHINE;
    // Flags 0 is the atomic upsert: one verb covers add and overwrite,
    // matching set's contract.
    return CredWriteW(&cred, 0) ? NOKRE_SS_OK : NOKRE_SS_ERR_UNAVAILABLE;
}

int32_t nokre_ss_delete(const uint8_t *ns, size_t ns_len,
                      const uint8_t *key, size_t key_len) {
    WCHAR target[NOKRE_SS_TARGET_CAP];
    if (!build_target(ns, ns_len, key, key_len, target)) return NOKRE_SS_ERR_UNAVAILABLE;
    if (CredDeleteW(target, CRED_TYPE_GENERIC, 0)) return NOKRE_SS_OK;
    // Deleting an absent key is the postcondition already met.
    return GetLastError() == ERROR_NOT_FOUND ? NOKRE_SS_OK : NOKRE_SS_ERR_UNAVAILABLE;
}

int32_t nokre_ss_list(const uint8_t *ns, size_t ns_len,
                    uint8_t *list_buf, size_t list_cap) {
    // CredEnumerate's filter is a target-name prefix: "<ns>/*".
    WCHAR filter[NOKRE_SS_TARGET_CAP];
    if (ns_len + 2 + 1 > NOKRE_SS_TARGET_CAP) return NOKRE_SS_ERR_UNAVAILABLE;
    size_t off = 0;
    for (size_t i = 0; i < ns_len; i++) filter[off++] = (WCHAR)ns[i];
    filter[off++] = L'/';
    filter[off++] = L'*';
    filter[off] = 0;

    DWORD count = 0;
    PCREDENTIALW *creds = NULL;
    if (!CredEnumerateW(filter, 0, &count, &creds)) {
        // A fresh install has no credentials: zero entries, never an
        // error — the first-ever set consults list for the StoreFull
        // check.
        return GetLastError() == ERROR_NOT_FOUND ? 0 : NOKRE_SS_ERR_UNAVAILABLE;
    }
    int32_t n = 0;
    size_t buf_off = 0;
    for (DWORD i = 0; i < count; i++) {
        const WCHAR *t = creds[i]->TargetName;
        if (creds[i]->Type != CRED_TYPE_GENERIC || t == NULL) continue;
        // The key part starts after the first "/" — the charset and
        // reverse-DNS ids both exclude it, so the first one is always
        // the namespace join.
        const WCHAR *key_start = wcschr(t, L'/');
        if (key_start == NULL) continue;
        key_start += 1;
        // External writers can park any target under our prefix; a key
        // the [len:u8] packing cannot represent, or whose UTF-16 does
        // not round-trip the per-unit widening build_target performs,
        // is refused here, not hallucinated into the contract (the Zig
        // side additionally drops keys outside the charset).
        size_t key_len = 0;
        int round_trips = 1;
        for (const WCHAR *p = key_start; *p != 0; p++) {
            if (*p > 0xFF) {
                round_trips = 0;
                break;
            }
            key_len += 1;
        }
        if (!round_trips || key_len == 0 || key_len > NOKRE_SS_MAX_KEY_BYTES) continue;
        // Past capacity the subset is unspecified external-writer
        // territory the OS itself cannot make deterministic: stop,
        // without error (secure_store.h).
        if (buf_off + 1 + key_len > list_cap) break;
        list_buf[buf_off] = (uint8_t)key_len;
        for (size_t k = 0; k < key_len; k++)
            list_buf[buf_off + 1 + k] = (uint8_t)key_start[k];
        buf_off += 1 + key_len;
        n += 1;
    }
    CredFree(creds);
    return n;
}
