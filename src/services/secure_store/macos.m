// macOS / iOS side of the secure_store service: four verbs against the
// Keychain (secure_store.h). Policy — validation, caps, sort order, the
// entry-count line — already ran in Zig; here is only the OS mapping:
// kSecClassGenericPassword with service = the app's namespace and
// account = the key. kSecAttrSynchronizable is never set: a store whose
// list() changes when another device syncs is nondeterminism the
// contract refuses — an entry can only appear because this app wrote it
// on this device.
//
// Every query goes data-protection-first (kSecUseDataProtectionKeychain):
// the DP keychain has no per-item ACL dialogs — access is keyed by
// application identifier, stable across rebuilds for signed apps, so
// properly signed builds are expected not to prompt. The bare ad-hoc
// `zig build run-…` binary carries no application-identifier
// entitlement, and — measured, not assumed — the refusal is asymmetric:
// SecItemAdd and SecItemDelete answer errSecMissingEntitlement, but
// SecItemCopyMatching answers errSecItemNotFound, indistinguishable
// from genuine absence. So on macOS the legacy file keychain is a
// second layer the verbs keep coherent as one store: reads fall
// through to it on *either* answer (DP shadows legacy on a hit),
// list serves the union of both layers, and delete sweeps both — the
// postcondition is "no such entry", not "no such entry in the layer
// that happened to answer". On an end-user machine the legacy layer is
// empty (a signed app never writes it), so the fall-throughs cost one
// extra ItemNotFound per miss and can never prompt; on a dev machine
// the legacy ACL is bound to the ad-hoc signature (fresh every
// rebuild) and macOS may show a blocking authorization prompt —
// documented dev-only posture, not contract (docs/services.md). iOS
// has no legacy keychain: there the DP answers are authoritative and
// an entitlement failure degrades straight to UNAVAILABLE.
#import <Foundation/Foundation.h>
#import <Security/Security.h>
#import <TargetConditionals.h>

#include "secure_store.h"

enum {
    // Mirrors max_key_bytes in secure_store.zig: the [len:u8] packing
    // in nokre_ss_list can only represent what the contract allows.
    NOKRE_SS_MAX_KEY_BYTES = 128,
};

static NSMutableDictionary *base_query(const uint8_t *ns, size_t ns_len,
                                       const uint8_t *key, size_t key_len,
                                       BOOL data_protection) {
    NSMutableDictionary *q = [NSMutableDictionary dictionary];
    q[(__bridge id)kSecClass] = (__bridge id)kSecClassGenericPassword;
    q[(__bridge id)kSecAttrService] = [[NSString alloc] initWithBytes:ns
                                                               length:ns_len
                                                             encoding:NSUTF8StringEncoding];
    if (key != NULL) {
        q[(__bridge id)kSecAttrAccount] = [[NSString alloc] initWithBytes:key
                                                                   length:key_len
                                                                 encoding:NSUTF8StringEncoding];
    }
    if (data_protection) q[(__bridge id)kSecUseDataProtectionKeychain] = @YES;
    return q;
}

// Which answers send a verb on to the legacy layer, macOS only: iOS
// never had a legacy file keychain to fall back to. Writes see the
// entitlement failure directly; reads cannot (SecItemCopyMatching
// hides it as errSecItemNotFound), so for them absence itself falls
// through — DP shadows legacy, and only a hit or a real failure (a
// locked keychain, a denial, an oversized blob) stops the search.
static bool retry_legacy_write(OSStatus status) {
#if TARGET_OS_OSX
    return status == errSecMissingEntitlement;
#else
    (void)status;
    return false;
#endif
}

static bool retry_legacy_read(OSStatus status) {
#if TARGET_OS_OSX
    return status == errSecMissingEntitlement || status == errSecItemNotFound;
#else
    (void)status;
    return false;
#endif
}

static OSStatus get_once(const uint8_t *ns, size_t ns_len,
                         const uint8_t *key, size_t key_len,
                         uint8_t *value_buf, size_t *value_len,
                         BOOL data_protection) {
    NSMutableDictionary *q = base_query(ns, ns_len, key, key_len, data_protection);
    q[(__bridge id)kSecMatchLimit] = (__bridge id)kSecMatchLimitOne;
    q[(__bridge id)kSecReturnData] = @YES;
    CFTypeRef result = NULL;
    OSStatus status = SecItemCopyMatching((__bridge CFDictionaryRef)q, &result);
    if (status != errSecSuccess) return status;
    NSData *data = CFBridgingRelease(result);
    // In/out capacity: an external writer's oversized blob is refused,
    // never truncated — the entry exists but cannot be served
    // in-contract, and ABSENT would invite an overwrite (secure_store.h).
    if (data.length > *value_len) return errSecBufferTooSmall;
    memcpy(value_buf, data.bytes, data.length);
    *value_len = data.length;
    return errSecSuccess;
}

static OSStatus set_once(const uint8_t *ns, size_t ns_len,
                         const uint8_t *key, size_t key_len,
                         const uint8_t *value, size_t value_len,
                         BOOL data_protection) {
    NSData *data = [NSData dataWithBytes:value length:value_len];
    NSMutableDictionary *add = base_query(ns, ns_len, key, key_len, data_protection);
    // AfterFirstUnlock: boot reads work whenever the app can run; a
    // pre-first-unlock read returns errSecInteractionNotAllowed
    // immediately (→ UNAVAILABLE, no dialog). ThisDeviceOnly is the
    // no-roaming refusal restated as an attribute. Effective on the
    // data-protection keychain, inert on the legacy file keychain —
    // the fallback path does not borrow this rationale.
    add[(__bridge id)kSecAttrAccessible] =
        (__bridge id)kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly;
    add[(__bridge id)kSecValueData] = data;
    OSStatus status = SecItemAdd((__bridge CFDictionaryRef)add, NULL);
    if (status == errSecDuplicateItem) {
        // set is an upsert: the duplicate answer routes to update, so
        // overwriting is one verb from the contract's point of view.
        // Except to empty — measured, not assumed: SecItemUpdate with a
        // zero-length kSecValueData reports success and silently keeps
        // the old bytes, so the one value update cannot express is
        // written as delete + add instead (the keychain has no
        // transactions for update either; nothing atomic is lost).
        if (value_len == 0) {
            NSMutableDictionary *q = base_query(ns, ns_len, key, key_len, data_protection);
            status = SecItemDelete((__bridge CFDictionaryRef)q);
            if (status != errSecSuccess) return status;
            return SecItemAdd((__bridge CFDictionaryRef)add, NULL);
        }
        NSMutableDictionary *q = base_query(ns, ns_len, key, key_len, data_protection);
        NSDictionary *change = @{(__bridge id)kSecValueData : data};
        status = SecItemUpdate((__bridge CFDictionaryRef)q, (__bridge CFDictionaryRef)change);
    }
    return status;
}

static OSStatus delete_once(const uint8_t *ns, size_t ns_len,
                            const uint8_t *key, size_t key_len,
                            BOOL data_protection) {
    NSMutableDictionary *q = base_query(ns, ns_len, key, key_len, data_protection);
    return SecItemDelete((__bridge CFDictionaryRef)q);
}

// True if the packed [len:u8][key]... prefix already holds this key —
// list unions two layers, and one entry per key is the union's meaning.
static bool list_contains(const uint8_t *list_buf, size_t used,
                          const uint8_t *key, size_t key_len) {
    size_t off = 0;
    while (off < used) {
        size_t len = list_buf[off];
        if (len == key_len && memcmp(list_buf + off + 1, key, len) == 0) return true;
        off += 1 + len;
    }
    return false;
}

// Appends one layer's accounts to the packed buffer, deduplicating
// against what earlier layers already contributed. *count / *used are
// running totals across calls.
static OSStatus list_once(const uint8_t *ns, size_t ns_len,
                          uint8_t *list_buf, size_t list_cap,
                          BOOL data_protection, int32_t *count, size_t *used) {
    NSMutableDictionary *q = base_query(ns, ns_len, NULL, 0, data_protection);
    q[(__bridge id)kSecMatchLimit] = (__bridge id)kSecMatchLimitAll;
    q[(__bridge id)kSecReturnAttributes] = @YES;
    CFTypeRef result = NULL;
    OSStatus status = SecItemCopyMatching((__bridge CFDictionaryRef)q, &result);
    if (status != errSecSuccess) return status;
    NSArray *items = CFBridgingRelease(result);
    for (NSDictionary *item in items) {
        NSString *account = item[(__bridge id)kSecAttrAccount];
        if (![account isKindOfClass:[NSString class]]) continue;
        NSData *bytes = [account dataUsingEncoding:NSUTF8StringEncoding];
        // External writers can park any account under our service; a
        // key the [len:u8] packing cannot represent — or one get()
        // could never be asked for — is refused here, not hallucinated
        // into the contract (the Zig side additionally drops keys
        // outside the charset).
        if (bytes == nil || bytes.length == 0 || bytes.length > NOKRE_SS_MAX_KEY_BYTES) continue;
        if (list_contains(list_buf, *used, bytes.bytes, bytes.length)) continue;
        // Past capacity the subset is unspecified external-writer
        // territory the OS itself cannot make deterministic: stop,
        // without error (secure_store.h).
        if (*used + 1 + bytes.length > list_cap) break;
        list_buf[*used] = (uint8_t)bytes.length;
        memcpy(list_buf + *used + 1, bytes.bytes, bytes.length);
        *used += 1 + bytes.length;
        *count += 1;
    }
    return errSecSuccess;
}

int32_t nokre_ss_get(const uint8_t *ns, size_t ns_len,
                   const uint8_t *key, size_t key_len,
                   uint8_t *value_buf, size_t *value_len) {
    OSStatus status = get_once(ns, ns_len, key, key_len, value_buf, value_len, YES);
    if (retry_legacy_read(status))
        status = get_once(ns, ns_len, key, key_len, value_buf, value_len, NO);
    if (status == errSecSuccess) return NOKRE_SS_OK;
    // A missing entry — now missing from both layers — is data, not a
    // failure. Everything else non-data — interaction not allowed, auth
    // failed, user canceled (the legacy-prompt Deny), not available,
    // buffer too small — degrades: the same closed answer every
    // consumer must already handle.
    if (status == errSecItemNotFound) return NOKRE_SS_ABSENT;
    return NOKRE_SS_ERR_UNAVAILABLE;
}

int32_t nokre_ss_set(const uint8_t *ns, size_t ns_len,
                   const uint8_t *key, size_t key_len,
                   const uint8_t *value, size_t value_len) {
    OSStatus status = set_once(ns, ns_len, key, key_len, value, value_len, YES);
    if (retry_legacy_write(status))
        status = set_once(ns, ns_len, key, key_len, value, value_len, NO);
    return status == errSecSuccess ? NOKRE_SS_OK : NOKRE_SS_ERR_UNAVAILABLE;
}

int32_t nokre_ss_delete(const uint8_t *ns, size_t ns_len,
                      const uint8_t *key, size_t key_len) {
    // The postcondition is "no such entry" — in the store, not in a
    // layer. On macOS that means sweeping both: deleting only the DP
    // item would let a dev-era legacy leftover resurrect on the next
    // get's fall-through. Absence and (on the DP layer) a missing
    // entitlement are the postcondition already met.
    OSStatus dp = delete_once(ns, ns_len, key, key_len, YES);
    bool dp_ok = dp == errSecSuccess || dp == errSecItemNotFound || retry_legacy_write(dp);
#if TARGET_OS_OSX
    OSStatus lg = delete_once(ns, ns_len, key, key_len, NO);
    bool lg_ok = lg == errSecSuccess || lg == errSecItemNotFound;
    return (dp_ok && lg_ok) ? NOKRE_SS_OK : NOKRE_SS_ERR_UNAVAILABLE;
#else
    return dp_ok ? NOKRE_SS_OK : NOKRE_SS_ERR_UNAVAILABLE;
#endif
}

int32_t nokre_ss_list(const uint8_t *ns, size_t ns_len,
                    uint8_t *list_buf, size_t list_cap) {
    // A fresh install has no items: zero entries, never an error — the
    // first-ever set consults list for the StoreFull check. On macOS
    // the answer is the union of both layers (get can find a key in
    // either, and list may never disagree with get about what exists);
    // errSecItemNotFound from a layer contributes nothing, like the
    // unsigned binary's DP layer, which hides its missing entitlement
    // behind that same code.
    int32_t count = 0;
    size_t used = 0;
    OSStatus status = list_once(ns, ns_len, list_buf, list_cap, YES, &count, &used);
    if (status != errSecSuccess && status != errSecItemNotFound && !retry_legacy_write(status))
        return NOKRE_SS_ERR_UNAVAILABLE;
#if TARGET_OS_OSX
    status = list_once(ns, ns_len, list_buf, list_cap, NO, &count, &used);
    if (status != errSecSuccess && status != errSecItemNotFound) return NOKRE_SS_ERR_UNAVAILABLE;
#endif
    return count;
}
