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
called from [live.js](../../src/render/dom/live.js) before boot).
[dev.c](../../src/services/secure_store/dev.c) is the sixth
implementation of the same four verbs and the only one no app ships: the
dev file store a driver binary opts into at build time (below). The
contract tests are
[secure_store_test.zig](../../src/services/secure_store/secure_store_test.zig),
and the one gate that runs the *real* verbs is
[tests/dev_store.zig](../../tests/dev_store.zig).

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

Which platform sets which ceiling is the consumer table's job
([../services.md](../services.md)); what internals adds is the sizing
that is *ours*, and the naming.

- **2560-byte values.** Windows' number, pinned on both sides so
  neither copy can drift off it: a `#error` in windows.c against the C
  one, an equality test against the Zig one. The *name* stays ours on
  http's `BodyTooLarge` precedent — the cap is ours to enforce even
  where the number is not ours to pick.
- **128-byte keys, 256 entries.** No backend counts entries, so the
  entry cap is nothing but what the caller-owned buffers hold:
  `ListBuf` is 36 KiB (32 KiB of key bytes + 4 KiB of slices),
  `native.list` spends 72 KiB more of its own frame (the packing
  scratch plus the slice array it sorts), and the wasm table is
  256 × (128 + 2560) ≈ 673 KiB of linear memory. Frame- and .bss-sized,
  none of it allocated, against a 1 MiB stack at the tightest (iOS,
  Windows). The base64 sessionStorage shadow is ~875 KiB of characters
  worst case against a ~5 MB origin quota — and it is best-effort
  anyway, so the quota is not a bound the contract can trip over.
- **Why 256 and not 64.** The number that retired 64 came from the
  first real consumer: three entries per (cycle, channel) pair, and a
  user in a dozen circles plus a dozen connections is 24 pairs — 72
  entries, refused by a 64-entry store. 256 carries 85 such triples.
  Past that the thing being stored has stopped being a pouch of
  secrets, and no ceiling nokre picks would make it one.
- **Why not more than 256.** Every entry of headroom is bought three
  times: 144 bytes in the caller's `ListBuf` (a key slot plus its
  slice), 290 in `native.list`'s frame (the doubled scratch and the
  slice array it sorts), and 2,692 in the wasm table, which is sized
  entry × (key + value) whether or not a value is ever that big —
  ~3.1 KiB per entry, of which 2.6 KiB is paid by every linked web
  build at boot. 1024 entries is a 144 KiB caller buffer, a 290 KiB
  frame under it on the 1 MiB stacks iOS and Windows give, and a
  2.6 MiB table. The shapes that would bend that curve each cost more
  than the capacity is worth: `list` over a caller-sized buffer with a
  there-was-more flag turns the one verb that must be total into a
  partial one — and the count `StoreFull` consults is seeded from
  `list`'s length, so a partial listing is a partial cap; a byte-arena
  web table decouples entries from the value cap only by making
  `StoreFull` fire on total bytes, so whether a `set` succeeds would
  depend on the sizes of unrelated values, and would stop meaning the
  same thing on every platform; shortening the key cap buys entries in
  the two key-sized buffers and nothing at all in the table, where the
  value dominates. An allocator would break all three at once, and it
  would be the only one in the service.
- **The pressure to raise it, named.** What would ask for 1024 is the
  shape the bullet above refuses — an entry count tracking the user's
  graph — and 1024 postpones it by 4× while charging every app the
  table. The answer is the one this service already gives values: keep
  one secret and derive the per-channel material from it. That the derived
  material then needs somewhere to live is a real gap — nokre ships no
  general local store — but it is a gap for another service to fill.
  Inflating the pouch is not how it gets filled: every linked app would
  pay the table, and only one shape of app would spend it.
- **StoreFull is the service's line, not the OS's.** `set` of a
  possibly-new key probes for presence; an insert consults the app's
  cached count — seeded by one `list` enumeration on the first insert,
  adjusted on inserts and deletes thereafter — so the key past the cap
  fails identically on a keychain, in CredMan, in the web table,
  and in the MockState. One O(n) enumeration per app lifetime, not per
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
   `zig build test` is immune because tests only ever reach the MockState.

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

That choice is also what sets the whole contract's value ceiling:
`CredWriteW` refuses a `CredentialBlobSize` past
`CRED_MAX_CREDENTIAL_BLOB_SIZE` (5 × 512 = 2560) with
`ERROR_INVALID_PARAMETER`, while no other backend bounds a value at all
(the per-platform table in [../services.md](../services.md)). The
alternative was weighed again when the caps were raised, and declined
again — now with its price named rather than assumed. DPAPI over a file
in the app's data directory has the same protection boundary
(user-scoped keys, readable by anything running as that user) and no
ceiling, but it buys the bigger value three ways nokre will not pay:
by inventing the container the stateless-native charter forbids, by
dropping the entries out of the panel where a user can revoke them, and
by rewriting the one backend no gate in this repo can execute —
`check-targets` compiles Windows, it never runs it. A 2560-byte secret
is not a shape any consumer has asked for, and a bigger one is a
document. So the ceiling is stated instead of engineered around, and
windows.c `#error`s if the C copy of it drifts.

**Chunking, weighed and worse.** Splitting one logical value across
several credentials — `ns/key`, `ns/key/1`, … on the same `/` join that
already cannot alias — meets those objections worse than the file does,
on every one of them. `CredWriteW` is atomic per blob and nothing is
atomic across blobs: a crash or a refusal between chunks leaves a value
no `set` ever wrote, and a torn secret is the one torn value worse than
absence — half an old key and half a new one decrypts nothing and reads
as corruption. Making it whole again needs a generation counter and a
commit record, which is the file format back, now smeared across the OS
store instead of confined to one file. The panel fares worse, not
better: DPAPI-over-a-file drops the entry out of the panel, where
chunking puts N rows into it and makes each separately revocable — a
user who revokes one chunk has revoked half a secret, and the orphaned
rest is garbage nothing collects. The property CredMan was chosen *for*
— revoke means signed out — is the first thing to break. `list` would
then have to hide the chunk rows, since it may never show a key `get`
could not be asked for, so the panel and `list` would stop agreeing in
the direction the contract has no name for. And the entry cap divides:
chunks consume credentials, so either the count cache counts what
`list` hides, or `StoreFull` fires at a different entry number on
Windows than everywhere else — the one error whose whole point is that
no platform gets a vote. Against all of which it rewrites the backend
no gate here executes, and unlike the file it does not stop at the C:
`native.list` and the count cache are shared Zig, so the untestable
surface grows rather than staying put.

The one variant that survives the atomicity and panel objections is
worth naming, because it looks like the answer and is not. A credential
carries up to `CRED_MAX_ATTRIBUTES` (64) attributes of
`CRED_MAX_VALUE_SIZE` (256) bytes — 16 KiB more, written by the same
single `CredWriteW`, showing as one panel row with one revoke. It dies
elsewhere: `CredentialBlob` is the field Windows documents as the
protected secret, an attribute is metadata, and an attribute's at-rest
protection is documented nowhere. Splitting a secret across one field
known to be encrypted and 64 whose protection is unstated is a weaker
boundary sold as a bigger cap — the opposite of the trade this service
makes everywhere else. It would also rest on composing two constants
into behavior neither documents and no gate here can measure: the caps
that landed came from measurement or from the constant the API itself
enforces, and `check-targets` compiles Windows without ever running it.

Nor does the ceiling become Windows-only. A cap of 2560 there and
unbounded elsewhere makes `ValueTooLarge` a fact about the developer's
laptop: an app that stores fine all through development fails at a
user's first `set`, and the one property the whole cap doctrine buys —
one number, one meaning, every platform — is what pays for it. Every
route past 2560 spends something the store's own users can see: the
panel, the atomic write, or the single meaning of `StoreFull`. The
value that does not fit is still a document.

One sharp edge, recorded because it reads like a bug: 2560 is
written out in windows.c rather than taken from the header in scope,
because the headers disagree. Vista raised
`CRED_MAX_CREDENTIAL_BLOB_SIZE` to 5 × 512 and the Windows SDK says so,
but mingw-w64's `wincred.h` — what `zig build check-targets`
cross-compiles that file against — still carries the pre-Vista 512.
Trusting whichever header was in scope would have fired the gate on the
cross-check and passed it on the build that ships.

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

- `nokre_ss_get`'s `value_len` is in/out — capacity in (always
  `max_value_bytes` from Zig), stored length out. A blob larger than the capacity returns
  `Unavailable`, never truncated bytes: the entry exists but cannot be
  served in-contract, and reporting absence would invite an overwrite.
- Native `nokre_ss_list` skips entries whose key exceeds 128 bytes (so
  its `[len:u8][key…]` packing can always represent what it packs);
  the Zig side additionally drops any listed key failing `validKey`.
  The service refuses to hallucinate foreign entries into the contract
  — `list` never shows a key `get` could not be asked for.
- **The determinism bound.** Native list packs up to `2 × max_entries`
  entries into a 66 KiB stack scratch inside `list()`'s frame; Zig
  sorts everything received bytewise, then truncates to `max_entries`.
  This app's own writes can never exceed the cap, so the doubling is
  pure headroom against external writers: "the first 256 in sorted
  order" is deterministic up to 512 externally-visible entries; beyond
  that the subset is unspecified — external-writer territory the OS
  itself cannot make deterministic, since no OS promises an
  enumeration order. The wasm table and the MockState are capped at
  `max_entries` by construction and never hit this.

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
and `error.Unavailable` never occurs. The price is the table:
~673 KiB of wasm linear memory when linked (`.bss` — zero bytes of
download), paid even for one 20-byte token. That is the cost of the
table being the *truth* rather than a cache: blocked or full storage
degrades to a dead mirror, never to a store that lies, which is the
whole reason the web leg has no `Unavailable` to return. It scales
with the caps, so the caps stay contract (see Refusals).

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
and the file, which is stateless in the contract's sense. Nothing here
bounds a value: the ciphertext is a base64 string in a prefs map, so
the value cap plus the GCM envelope (12-byte IV + 16-byte tag) fits by
construction, and nothing bounds the entry count either. The key carries **no** user-authentication or
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
arbitrary bytes up to the cap (embedded NULs included), so values are
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
| stored value's hex is malformed or decodes past the value cap (an external writer's) | `Unavailable` — the entry exists but cannot be served in-contract |
| any `GError` (locked keyring, no daemon, denied) | `Unavailable` |

## The dev file store: the driver's backend, opted into at build time

[dev.c](../../src/services/secure_store/dev.c) answers the same four
`nokre_ss_*` verbs against a plaintext file. It is selected in
build.zig — `.secure_store_dev = true` alongside `.secure_store`
(`-Dsecure_store_dev` for nokre's own build) — and it is *instead of*
the platform leg, never beside it: `addSecureStore` compiles either
dev.c or macos.m/linux.c, so a binary has one backend and no runtime
state can change which. Everything above it is untouched. The Zig
policy layer never learns of it, `native.zig` is the same file, and the
caps, the sort order, the `StoreFull` line and every error name are
therefore the same by construction rather than by re-implementation —
which is the whole reason the swap happens at the C seam and not higher.

**What it is for.** An executable that drives a real app against real
backends — the tier [../testing.md](../testing.md#where-the-harness-stops)
says nokre owes on its own side, since under `zig test` a service *is*
its mock. Two platforms make the OS store the wrong thing for such a
binary to use:

- **macOS.** `SecItemAdd` with `kSecUseDataProtectionKeychain = YES`
  answers `errSecMissingEntitlement` (-34018) from an ad-hoc /
  linker-signed binary — measured, and ad-hoc signing the entitlement
  *in* is no way out either: the process is SIGKILLed at launch, with
  `keychain-access-groups` and with `com.apple.application-identifier`
  alike. What keeps an unsigned binary working today is the legacy
  file-keychain fallback the Apple section above describes — and that
  section already calls it dev-only posture rather than contract. It is
  deprecated, macOS-only, it is the developer's own login keychain, and
  its per-item ACL binds to a signature that changes on every rebuild,
  so it can raise a modal the synchronous API blocks the thread behind.
  A driver riding it is one macOS dialog away from a hung CI job, and
  every run shares one store with every other.
- **Linux.** A headless machine runs no Secret Service daemon, so
  libsecret has nothing to talk to and every verb is `Unavailable`.
  There is no fallback there at all.

So the dev store is not "the store that works where none does" — it is
the store a driver *should* be using: named by the build, isolated per
run, shared with nothing, and unable to prompt.

**The file.** `$NOKRE_SECURE_STORE_DEV` names it outright, which is how
one driver run gets a store no previous run can have touched; otherwise
it is `$HOME/.nokre-dev-store/<pkg_id>`, one directory named for what it
is, where a developer can find it and delete it. With neither, there is
no file and every verb answers `Unavailable` — the locked-keychain
posture every consumer already handles. Mode 0600: the protection
boundary is the user's account, which is the same boundary DPAPI and a
login keyring give, and the only one a plaintext file can honestly
claim.

The format is a 16-byte magic and then `[key_len:u8][value_len:u16
le][key][value]` records, streamed rather than slurped — a 128-byte key
scratch and one value buffer, so the frame stays ~3 KiB whatever the
store holds, and there is still no allocator anywhere in the service.
`set` and `delete` are one function: rewrite into a sibling `.tmp` and
`rename` over, which is the atomic upsert `CredWriteW` and
`SecItemUpdate` give for free — a crash leaves the old file or the new
one, never half a store. Nothing is held between calls (the charter),
so two `App`s, or two processes, see one store with no cache to
reconcile. A file whose magic does not match is refused by every verb
and never overwritten; a record whose lengths the caps could not have
produced makes the file corrupt rather than skippable, because this
format has exactly one writer and a store that lies is worse than one
that refuses.

**How a shipping build cannot get here.** Four things, all at build
time, none of them a property of the machine that runs the build:

1. **It must be asked for, by name.** `.secure_store_dev` defaults
   false and reads as what it is. There is no environment variable, no
   signature check, no probe: nothing an app *runs into* selects this
   backend.
2. **It must be Debug.** Any other `-Doptimize` fails the build with a
   message saying why. An optimized artifact is one somebody is
   preparing to hand out.
3. **It must be macOS or desktop Linux.** iOS, Android and wasm fail
   the build: those artifacts exist only to be installed, and their
   stores answer any build already. Windows fails too — Credential
   Manager answers any process in a logon session, so a dev store there
   would be a weaker store solving nothing.
4. **It must be linked.** `.secure_store_dev` without `.secure_store`
   fails: it is a backend for the service, not a second service.

And if all four ever held by accident, the binary says so: dev.c's
`__attribute__((constructor))` prints one line to stderr at every
launch, before any app code runs — at process start rather than at
first use, so a build carrying this store announces it even on the run
that never touches it, and so the file itself still holds nothing
between calls.

**What runs it.** `zig build test` builds
[tests/dev_store.zig](../../tests/dev_store.zig) as an executable — not
a `zig test` binary — and runs it on a native macOS or desktop-Linux
host, against a store file in the build cache. It is the only place in
this repository where the verbs a consumer calls reach a store the OS
answers: everywhere else they reach the MockState (`zig test`), a
compile-only object (`check-targets`), or a linked artifact nothing
runs (the examples). It also demonstrates the driver shape whole — an
`App` constructed outside `zig test`, its screens driven through
`testing.driver`, the a11y audit run on each one, and the shell hooks a
linking program owes exported by the program itself (emit_css.zig's
note).

## Testing: one fake per app, constructed with it

Under `builtin.is_test` the four verbs route — comptime, so test
builds never reference the native externs and `zig build test` stays
dependency-free — to `app.services.secure_store.state`, the per-app
`MockState` the app was constructed with. It is the only store that exists
under `zig test`: `secure_store.Service` *is* the mock there, so a
test build has no fake-less state to reach — never a silent empty
store, never the real keychain.

The binding is construction, nothing else. `App.init` allocates the
MockState on the heap (move-safe across the by-value returns a stack App
makes), applies the mock config's seeds and availability before
`build` runs, and `App.deinit` frees it — no registry, no
install/uninstall pairing, no serial keys. Two concurrently-driven
apps get two of them with disjoint entries, journals, and knobs by
construction: the state is a field of the app, so cross-app leakage
is unrepresentable, not merely checked (the design rule in
[architecture.md](architecture.md): service state lives on the App;
a module-global `var` in a service is a bug).

The MockState itself is plain unconditional code, dead-stripped from
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
`web.zig`, and the dispatch analyze on every OS tag. dev.c gets its own
twin on the two targets it is allowed on; being plain POSIX with no
framework and no daemon behind it, it is the one backend that step can
analyze without an SDK.

**What the MockState does not prove, and who proves it.** The MockState is a
contract asserted against itself: its fidelity to a keychain is
asserted by nothing under `zig test`, because the keychain is not
compiled into a test binary at all. The dev store is what closes that
on nokre's side — `tests/dev_store.zig` runs the release verbs, in an
executable, against a store the OS actually answers, on every
`zig build test` on a desktop POSIX host. It proves the *dispatch and
the policy layer* work outside `is_test`, which is the half no unit
test can reach; it does not make macos.m or windows.c any more
executed than they were, and nothing here pretends otherwise.

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
- **No cap knobs.** 128 / 2560 / 256 are contract, not configuration —
  they are what makes `ValueTooLarge` mean one thing everywhere, and
  two of the three are sized to fixed buffers a knob could not move.
  Raising one is a change to this file and the tables it points at, not
  a build option. The store-the-session-id argument is consumer-facing
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
