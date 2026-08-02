// C contract between the secure_store native side and Zig, in the
// shape of package_info.h: thin, stateless, synchronous. The Zig side
// owns every buffer and every policy — validation, caps, sort order,
// the entry-count line; the native side is four verbs against the OS
// store and holds nothing between calls.
#ifndef NOKRE_SVC_SECURE_STORE_H
#define NOKRE_SVC_SECURE_STORE_H

#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

// Mirrors the mapping in src/services/secure_store/native.zig.
enum {
    NOKRE_SS_OK = 0,
    NOKRE_SS_ABSENT = 1,           // get: no such key — data, not an error
    NOKRE_SS_ERR_UNAVAILABLE = -1, // locked / denied / no backend
};

// The two caps every backend has to know, mirroring max_key_bytes and
// max_value_bytes in secure_store.zig — declared once here rather than
// per-.c, so the C side has one home for them too. Macros, not an
// enum, so the backend whose platform *sets* a cap can gate on it in
// the preprocessor — windows.c #errors when this value cap climbs past
// what CredWriteW would accept.
#define NOKRE_SS_MAX_KEY_BYTES 128
#define NOKRE_SS_MAX_VALUE_BYTES 2560

// ns is the app's reverse-DNS id. Keys and ns are ptr+len,
// [a-z0-9._-] enforced Zig-side.
//
// value_len is in/out: in = the buffer's capacity (always the Zig
// side's max_value_bytes), out = the stored length. A blob larger
// than the capacity — an external writer's, never this service's —
// returns NOKRE_SS_ERR_UNAVAILABLE: the entry exists but cannot be
// served in-contract, and ABSENT would invite an overwrite.
int32_t nokre_ss_get(const uint8_t* ns, size_t ns_len,
                   const uint8_t* key, size_t key_len,
                   uint8_t* value_buf, size_t* value_len);
int32_t nokre_ss_set(const uint8_t* ns, size_t ns_len,
                   const uint8_t* key, size_t key_len,
                   const uint8_t* value, size_t value_len);   // upsert
int32_t nokre_ss_delete(const uint8_t* ns, size_t ns_len,
                      const uint8_t* key, size_t key_len);    // absent -> OK
// Packs [len:u8][key bytes]... into list_buf, order unspecified — the
// Zig side sorts (determinism lives in Zig, not per-platform).
// Returns the entry count, or a negative error; an empty namespace is
// count 0, never an error (errSecItemNotFound / ERROR_NOT_FOUND map
// here, not to UNAVAILABLE — the first-ever set consults list).
// Skips entries whose key exceeds NOKRE_SS_MAX_KEY_BYTES, so the
// [len:u8] packing always represents what it packs; the Zig side
// additionally drops any key outside the charset. list_cap is twice
// the Zig side's entry cap worth of packed entries — headroom over
// anything this app could have written; when the next entry would not
// fit, stop without error (past it the subset is external-writer
// territory the OS itself cannot make deterministic).
int32_t nokre_ss_list(const uint8_t* ns, size_t ns_len,
                    uint8_t* list_buf, size_t list_cap);

#ifdef __cplusplus
}
#endif

#endif // NOKRE_SVC_SECURE_STORE_H
