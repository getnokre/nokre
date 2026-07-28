# The secure_store service

How the pouch contract in [../services.md](../services.md) is wired.
The policy layer is
[src/services/secure_store/secure_store.zig](../../src/services/secure_store/secure_store.zig)
— validation, caps, the StoreFull line, sort order, comptime dispatch,
and the per-app test fake.
[native.zig](../../src/services/secure_store/native.zig) declares the
four `nokre_ss_*` externs of
[secure_store.h](../../src/services/secure_store/secure_store.h) and
maps OS codes to the closed error sets; the verbs are implemented by
[macos.m](../../src/services/secure_store/macos.m) (macOS and iOS, one
file), [windows.c](../../src/services/secure_store/windows.c), and — for
Android — [android.c](../../src/services/secure_store/android.c), a JNI
bridge to [NokreSecureStore.java](../../src/platform/android/java/dev/nokre/shell/NokreSecureStore.java)
(Android has no synchronous C store API; the Keystore backend is Java).
On wasm, [web.zig](../../src/services/secure_store/web.zig) replaces the
native leg with a static in-module table plus the snapshot/mirror glue
in [services.js](../../src/render/dom/services.js) (the seed scan is
called from [live.js](../../src/render/dom/live.js) before boot). The
contract tests are
[secure_store_test.zig](../../src/services/secure_store/secure_store_test.zig).

The split is package_info's: the native side is thin, stateless,
synchronous — four verbs against the OS store, holding nothing between
calls — and the Zig side owns every buffer and every policy. That
placement is what makes three of the four error names producible
identically everywhere: `InvalidKey`, `ValueTooLarge`, and `StoreFull`
are decided in Zig before any OS call, so no platform gets a vote.

## Why synchronous

A secret is local state, and every backend answers in-process — the
Keychain and Credential Manager are syscalls-deep, not network-deep,
and the web table is memory. The reads that matter are boot reads (the
stored token decides the first screen), and nokre has no tickers to
retire the loading frame an async boot read would strand: sync means
one call inside `build`, no handshake, no stranded frame.

The one *designed* blocking case: the macOS *legacy dev-keychain
fallback* can show an ACL authorization prompt, and because the API is
synchronous that prompt blocks the UI thread while it is up. That is
dev-only posture, not contract — the two-layer strategy below. Linux
carries the honest footnote: libsecret's sync calls are D-Bus round
trips to the keyring daemon, and a locked collection can raise the
daemon's own unlock prompt, which blocks the same way.

## The caps, derived

- **2048-byte values.** Why this number is the consumer table's row
  ([../services.md](../services.md)); what internals adds is the
  naming: http's `BodyTooLarge` precedent — the cap is ours, so the
  name is ours.
- **128-byte keys, 64 entries.** Together they bound every buffer to a
  stack array: `ListBuf` is ~9 KiB, the wasm table 64 × (128 + 2048)
  ≈ 139 KiB, the base64 sessionStorage mirror ≈ 186 KiB worst case —
  browser quota unreachable by construction.
- **StoreFull is the service's line, not the OS's.** `set` of a
  possibly-new key probes for presence; an insert consults the app's
  cached count — seeded by one `list` enumeration on the first insert,
  adjusted on inserts and deletes thereafter — so the 65th distinct
  key fails identically on a keychain, in CredMan, in the web table,
  and in the Fake. One O(n) enumeration per app lifetime, not per
  write; cross-process writers could drift the cache, but
  enumerate-then-set was never atomic either, so best-effort is
  unchanged.

## The namespace

The store is namespaced by `pkg_id`, composed at **comptime only**:
build.zig bakes the id into secure_store's own options module
(`nokre_secure_store_options` — one options module per service, no
cross-import), so at runtime secure_store never calls
`package_info.get()` and the namespace crosses natively as nothing but
bytes. Linking without `pkg_id` fails in build.zig; an unlinked call
site fails with the curated comptime error, never a missing-module
error (package_info's rule — the options module is always added).

The join character between namespace and key is `/` — outside both the
key charset and reverse-DNS ids, so namespaces can never alias
(`com.a` + `b.c` vs `com.a.b` + `c`): the Windows TargetName is
`ns + "/" + key` and the web storage key is
`"nokre.ss." + pkg_id + "/" + key`, the same join. One residue:
CredMan target lookup is case-insensitive, so two apps whose pkg_ids
differ only by case would collide on Windows — noted, not legislated;
it isn't worth a rule on pkg_id.

## Apple: two layers, stated honestly

`kSecClassGenericPassword`; `kSecAttrService` = the namespace,
`kSecAttrAccount` = the key. `kSecAttrSynchronizable` is never set —
no iCloud; a store whose `list()` changes when another device syncs is
nondeterminism the contract refuses. `kSecAttrAccessible` =
`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`: boot reads work
whenever the app can run, and a pre-first-unlock read returns
`errSecInteractionNotAllowed` immediately — `Unavailable`, no dialog.
That attribute is effective on the data-protection keychain and
**inert on the legacy file keychain** — stated so the fallback path
doesn't borrow the primary path's rationale.

Verbs: get = `SecItemCopyMatching` (`kSecReturnData`, limit one); set
= `SecItemAdd` with `errSecDuplicateItem` retried as `SecItemUpdate` —
except an overwrite **to empty**, which is written as delete + add:
measured, not assumed, `SecItemUpdate` with a zero-length
`kSecValueData` reports success and silently keeps the old bytes, and
the contract says an empty value is a value. delete = `SecItemDelete`;
list = `SecItemCopyMatching` (`kSecMatchLimitAll`,
`kSecReturnAttributes`), packing accounts.

| OS result | Contract |
| --- | --- |
| `errSecSuccess` | OK |
| `errSecItemNotFound` | get → fall through to the legacy layer, then ABSENT (`null`); delete → OK (the postcondition already held); list → the layer contributes 0 entries — a fresh install's first insert seeds the count from list and must see an empty store, never a failure |
| `errSecDuplicateItem` on add | retry as `SecItemUpdate` — upsert (delete + add when the new value is empty) |
| `errSecInteractionNotAllowed`, `errSecAuthFailed`, `errSecUserCanceled`, `errSecNotAvailable`, `errSecBufferTooSmall` (an external writer's oversized blob), anything else non-data | `Unavailable` |

The two-layer strategy — one store, coherent across both layers:

1. Every query sets `kSecUseDataProtectionKeychain = YES` first. The
   data-protection keychain has no per-item ACL dialogs; access is
   keyed by application identifier, stable across rebuilds for signed
   apps — properly signed builds (Developer ID / App Store, with an
   application-identifier entitlement) are expected not to prompt.
   Not promised as "never": DP-keychain entitlement behavior for
   non-App-Store Developer ID builds has known murk, and the fallback
   is the safety net.
2. The unentitled binary's refusal is **asymmetric** — measured on
   macOS 15: `SecItemAdd` and `SecItemDelete` answer
   `errSecMissingEntitlement`, but `SecItemCopyMatching` answers
   `errSecItemNotFound`, indistinguishable from genuine absence. So
   the fallback cannot key on the entitlement error alone: reads
   (get, list) fall through to the legacy file keychain on *either*
   answer — DP shadows legacy on a hit — list serves the union of
   both layers (get and list may never disagree about what exists),
   and delete sweeps both (the postcondition is "no such entry" in
   the store, not in whichever layer answered; deleting only the DP
   item would let a dev-era legacy leftover resurrect on the next
   get). All of it `#if TARGET_OS_OSX` — iOS has no legacy keychain,
   so there the DP answers are authoritative and a missing
   entitlement maps straight to `Unavailable`. On an end-user machine
   the legacy layer is empty (a signed app never writes it), so the
   fall-throughs cost one extra `errSecItemNotFound` per miss and
   cannot prompt; on a dev machine the legacy ACL binds to the ad-hoc
   signature, which changes every rebuild, so macOS may prompt. The
   consumer-facing consequences and ways out live in
   [../services.md](../services.md); the structural facts here: an
   explicit Deny maps to `Unavailable` — a free rehearsal of the
   locked-keychain path every shipping app must handle — and
   `zig build test` is immune because tests only ever reach the Fake.

## Windows: Credential Manager, not raw DPAPI

DPAPI is a cipher, not a store: `CryptProtectData` hands back
ciphertext and would force this service to invent an on-disk container
— a file format, a location, locking, atomic rename, corruption
recovery — which is state, and the native side is forbidden to hold
state. Credential Manager ships the entire CRUD, its blobs are
DPAPI-encrypted at rest (services.md says "Credential Manager
(DPAPI-backed)" to preempt the review question), and it adds user
agency: entries appear in the OS's own Credential Manager panel, where
a user can inspect and revoke them — which is why an externally
deleted entry must read as `get → null`, "signed out", never
"impossible".

`TargetName` = UTF-16(`ns + "/" + key`) — the lowercase charset makes
the widening trivial and case-insensitive lookup unable to alias two
contract keys — `CRED_TYPE_GENERIC`, `CRED_PERSIST_LOCAL_MACHINE`
(per-user, survives reboot, never roams: the deliberate twin of
`ThisDeviceOnly`). get = `CredReadW`; set = `CredWriteW` with flags 0
(atomic upsert); delete = `CredDeleteW`; list =
`CredEnumerateW(L"<ns>/*")`, `CredFree` inside the call.

| OS result | Contract |
| --- | --- |
| success | OK |
| `ERROR_NOT_FOUND` | get → ABSENT; delete → OK; `CredEnumerateW` → 0 entries (fresh install, same rationale as the Apple table) |
| `ERROR_NO_SUCH_LOGON_SESSION`, anything else | `Unavailable` |

## External writers

Keychain Access, the CredMan panel, or a second process can write into
the namespace, and nothing they write is trusted into the contract:

- `nokre_ss_get`'s `value_len` is in/out — capacity in (always 2048 from
  Zig), stored length out. A blob larger than the capacity returns
  `Unavailable`, never truncated bytes: the entry exists but cannot be
  served in-contract, and reporting absence would invite an overwrite.
- Native `nokre_ss_list` skips entries whose key exceeds 128 bytes (so
  its `[len:u8][key…]` packing can always represent what it packs);
  the Zig side additionally drops any listed key failing `validKey`.
  The service refuses to hallucinate foreign entries into the contract
  — `list` never shows a key `get` could not be asked for.
- **The determinism bound.** Native list packs up to 256 entries into
  a 33 KiB stack scratch inside `list()`'s frame; Zig sorts everything
  received bytewise, then truncates to 64. "The first 64 in sorted
  order" is therefore deterministic up to 256 externally-visible
  entries; beyond 256 the subset is unspecified — external-writer
  territory the OS itself cannot make deterministic, since no OS
  promises an enumeration order. The wasm table and the Fake are
  capped at 64 by construction and never hit this.

## Web: snapshot in, mirror out

The store is a static table inside the wasm module; sessionStorage is
only its shadow. The app instance runs on the main thread, right where
sessionStorage lives, so both directions of the shadow are plain
synchronous calls in services.js — which owns the storage schema (the
`"nokre.ss."` prefix and the base64 bridge), so the scan and the mirror
cannot drift apart:

1. **Boot snapshot.** live.js calls services.js's `seedSecureStore`
   after instantiation, strictly before `nokre_dom_boot`. It scans
   sessionStorage for keys prefixed `"nokre.ss."` — the JS side is
   namespace-agnostic; it cannot know pkg_id before wasm boots —
   base64-decodes values (an entry that does not decode is foreign,
   dropped at the door), and ferries each entry through the
   `nokre_ss_seed_scratch` / `nokre_ss_seed` exports — skipping when
   the export is absent (unlinked builds ship none) or when scratch
   returns null (an entry that large is by construction foreign or out
   of contract). web.zig filters to this app's `"<pkg_id>/"` prefix
   and applies the same out-of-contract refusals as native list.
   Seeding before boot is what lets a boot-time `get` inside the first
   `build` answer synchronously.
2. **Reads** never leave wasm.
3. **Writes** mutate the table synchronously — the table is the truth
   the app reads back — then mirror out best-effort:
   `nokre_ss_mirror_set` / `nokre_ss_mirror_del` (services.js) write
   sessionStorage inside try/catch. A throw (quota already burned by
   the host page, storage blocked) drops the write with one
   `console.warn`: `set`'s contract was "stored for this app", and the
   value stays readable all session — only reload-survival is lost,
   which was never in the sync contract. Blocked storage at boot =
   empty snapshot + dead mirror = a pure session cache; every call
   still behaves identically.

On web every outcome is a pure function of arguments + prior calls,
and `error.Unavailable` never occurs. The price is the table: ~139 KiB
of wasm memory when linked, paid even for one 20-byte token —
acceptable while the caps are contract, and they are (see Refusals).

**Why not OPFS.** Four counts, each sufficient: (1)
`createSyncAccessHandle()` is itself async, so first access needs a
boot handshake anyway; (2) a sync handle takes an exclusive lock — a
second tab throws `NoModificationAllowedError`, a failure mode with no
native analogue and no honest name in the closed set; (3) OPFS is
origin-persistent plaintext — exactly what the session-scoped posture
refuses; (4) Safari in-worker support is uneven. IndexedDB is
async-only and cannot back a sync API.

## Android: Keystore over private prefs

Landed with the Android shell.
[android.c](../../src/services/secure_store/android.c) is the JNI leg —
Android has no synchronous C store API, so the four `nokre_ss_*` verbs
bridge over JNI to
[NokreSecureStore.java](../../src/platform/android/java/dev/nokre/shell/NokreSecureStore.java),
which is the actual backend. The JavaVM comes from the shell
(`nokre_android_vm` in
[shell.c](../../src/platform/android/shell.c), the one `JNI_OnLoad` in
the `.so`); the class ref and method ids are cached lazily on the first
call, which is a boot read on the main thread whose env carries the app
classloader. `android.c` is NDK/CMake-compiled next to `shell.c` (the
Android split: C is NDK-built, the Zig arrives as a static lib), so
`build.zig`'s `addSecureStore` adds no C for Android — it only bakes the
namespace into the options module, and the Zig dispatch routes Android
to `native.zig` by OS tag (`os.tag` is `.linux`; Android and desktop
Linux share the tag and the `nokre_ss_*` contract, differing only in
which C file build.zig compiles behind it).

The store, per the frozen constraint: a per-namespace **AES-256-GCM key
in the AndroidKeyStore** wrapping the ciphertext (`iv ‖ ct+tag`, base64)
in an app-private `SharedPreferences` file — the OS owns both the key
and the file, which is stateless in the contract's sense. The 2048-byte
value cap plus the GCM envelope (12-byte IV + 16-byte tag) fits by
construction. The key carries **no** user-authentication or
unlocked-device requirement, so boot reads work whenever the app can run
(the `AfterFirstUnlockThisDeviceOnly` posture the Apple leg states), and
per-key biometry stays a refusal. `set` uses `commit()` (synchronous
durability, the boolean is the outcome the sync contract reports); the
key is created lazily on the first `set`, so an app that never writes
creates nothing. Deliberately no `androidx.security`
EncryptedSharedPreferences — that is a Jetpack dependency the shell
carries none of, and it wraps exactly this primitive.

| Java outcome | Contract |
| --- | --- |
| value bytes (may be zero-length) | get → OK; an empty value is a present, empty value |
| `getString` returns null | get → ABSENT (`null`) |
| `commit()` true | set / delete → OK (delete of an absent key is true — the postcondition already held) |
| empty key array | list → 0 entries (a fresh install; the first insert seeds the count from list) |
| any thrown `Exception` / false `commit` / null array | `Unavailable` — a decrypt failure (external tamper, key loss), a storage failure, a Keystore fault |

Keystore's failure texture (StrongBox, key invalidation) all funnels to
`Unavailable`: a thrown exception on any verb, and a decrypt that fails
because the key was invalidated, both read as the same closed answer
every consumer already handles.

## Linux: Secret Service via libsecret

Desktop Linux ([linux.c](../../src/services/secure_store/linux.c)) backs
the four verbs with libsecret's password API against the Secret Service —
the desktop's own keyring daemon (GNOME Keyring, KWallet's secretsd), the
twin of Keychain and Credential Manager. Entries are encrypted at rest
under the login keyring and appear in the user's keyring UI where they can
be inspected and revoked. `secret_password_store_sync` /
`lookup_sync` / `clear_sync` do get/set/delete against a single schema
(`SECRET_SCHEMA_NONE`, attributes `namespace` = the app id and `key`);
`secret_password_search_sync` (with `SECRET_SEARCH_ALL`, **no**
`SECRET_SEARCH_UNLOCK` — reading a stored key's attributes needs no
unlock) backs list, reading each item's `key` attribute off its
`GHashTable`.

libsecret's password API stores a NUL-terminated string, but a value is
arbitrary bytes up to 2048 (embedded NULs included), so values are
hex-encoded in and decoded out — the round-trip is exact and the stored
form stays a clean C string. Selection is by `os.tag == .linux` in
`secure_store.zig` (Android shares the tag but rides its own JNI leg); the
C compiles only on a Linux host (libsecret headers), so a cross-build's
compile-only check object leaves the externs undefined and resolves them
at a real Linux link — the macOS `.m` gate. A locked collection or an
absent Secret Service daemon maps to `error.Unavailable`, the environmental
posture every consumer already handles.

| libsecret outcome | maps to |
| --- | --- |
| `secret_password_lookup_sync` returns NULL, no error | `null` (absent — data, not a failure) |
| stored value's hex is malformed or decodes past 2048 (an external writer's) | `Unavailable` — the entry exists but cannot be served in-contract |
| any `GError` (locked keyring, no daemon, denied) | `Unavailable` |

## Testing: one fake per app, constructed with it

Under `builtin.is_test` the four verbs route — comptime, so test
builds never reference the native externs and `zig build test` stays
dependency-free — to `app.services.secure_store.state`, the per-app
`Fake` the app was constructed with. It is the only store that exists
under `zig test`: `secure_store.Service` *is* the mock there, so a
test build has no fake-less state to reach — never a silent empty
store, never the real keychain.

The binding is construction, nothing else. `App.init` allocates the
Fake on the heap (move-safe across the by-value returns a stack App
makes), applies the mock config's seeds and availability before
`build` runs, and `App.deinit` frees it — no registry, no
install/uninstall pairing, no serial keys. Two concurrently-driven
apps get two Fakes with disjoint entries, journals, and knobs by
construction: the state is a field of the app, so cross-app leakage
is unrepresentable, not merely checked (the design rule in
[architecture.md](architecture.md): service state lives on the App;
a module-global `var` in a service is a bug).

The Fake itself is plain unconditional code, dead-stripped from
production binaries because nothing in production references it; no
`if (builtin.is_test) type else void` gymnastics anywhere — the one
comptime fork is `Service = if (builtin.is_test) Mock else …`, the
same fork every service uses.

**The carve-out trade, stated.** `checkLinked` gates its curated
comptime error on `!options.linked and !builtin.is_test`: consumer
test builds never need the service linked, because the fake path is
the only compiled path there and requiring linking would demand OS
frameworks test code cannot reach. The hole is accepted and bounded —
a consumer's tests can pass while their unlinked release build fails
to compile — because that failure is a loud comptime error naming the
one-line fix, which cannot ship; the alternative taxes every consumer
test build with Security.framework for a path that is provably
unreachable. This keeps "optional means optional" true for test
builds.

The linked backends still compile-check everywhere: `secure_store.zig`
ends with a comptime block that takes the backend fns' addresses when
linked and non-test — lazy analysis would otherwise skip bodies
nothing references — and `zig build check-targets` builds a linked
twin object per target under a dummy identity, so `native.zig`,
`web.zig`, and the dispatch analyze on every OS tag.

## Refusals

These are guarantees, not gaps:

- **No change notifications.** The store never calls you; you read it.
  A watcher needs a ticker or an off-thread callback, and nokre has
  neither. If another process changes an entry, you see it on your
  next read — that is the whole contract.
- **No cross-device sync.** `kSecAttrSynchronizable` is never set;
  CredMan persists `LOCAL_MACHINE`. Two devices merging secrets is
  nondeterminism; the consumer argument — an entry can only appear
  because this app wrote it on this device — is made once in
  [../services.md](../services.md).
- **No per-item protection levels.** No biometry gates, no per-key
  accessibility classes, no access-control knobs. One store, one
  posture per platform, stated. A payment credential wanting Face ID
  wants a different product.
- **No encryption theater on the web.** Client-side JS encryption is
  refused: the key would live beside the data. The web posture is
  honestly weaker and honestly stated instead.
- **No cap knobs.** 128 / 2048 / 64 are contract, not configuration —
  they are what makes `ValueTooLarge` mean one thing everywhere. The
  store-the-session-id argument is consumer-facing
  ([../services.md](../services.md)).
- **No async shape, no timeout.** Every real backend answers
  in-process; a timeout is a timer, and nokre has none.
- **No custom namespaces.** The namespace is `pkg_id`, period. A
  second namespace is a second app.

## Deferred, not refused

- **A `getMany`-style batch read** — nothing blocks it, but four sync
  calls cost four sync calls; add it only if real code asks.

(The Linux libsecret and Android Keystore backends have both landed —
see the sections above.)
