# Services

The platform shell contract
([internals/platform-shells.md](internals/platform-shells.md)) is
deliberately dumb: surface, input, blit, clipboard. Real apps also need
the OS for
things that have nothing to do with rendering — secure storage, inbound
links, sign-in, purchases. Those live in a **second, parallel contract**:
services.

A service is an optional per-platform capability module. Each one is its
own small C header + native file, in the style of
[shell.h](../src/platform/shell.h): the native side is thin and
stateless, the Zig side owns all state. An app links only the services it
uses; an unlinked service is a comptime error at the call site, never a
runtime surprise.

Services are **constructed with the app, not installed onto it**: every
`App` carries its services (`Options.services`), and all service state
lives on the instance. Release builds default to the platform set —
shells and examples never name the field. Under `zig test` each service
is nokre's canonical mock, injected at the same spot and enforced at
compile time; you configure seeds, handlers, and knobs, never transport
semantics ([testing.md](testing.md)).

Services keep the shell honest. Any proposal to add intelligence to a
shell gets redirected here; any proposal to add rendering or input to a
service is rejected the same way. The authoring rules that hold both
lines are in [internals/contributing.md](internals/contributing.md).

## Roster

This table is the status-of-record; [roadmap.md](roadmap.md) points here.
Ordered by build order, not size. Each **Working** service has its
consumer contract below; the per-platform wiring lives in the linked
internals doc.

| Service | Job | Status |
| --- | --- | --- |
| `secure_store` | Encrypted key/value for small secrets: get, set, delete, list. | **Working** — five native backends; web is session-scoped |
| `package_info` | App identity: name, id, version, build, installer source. One struct. | **Working** |
| `clipboard` | One verb: copy UTF-8 text out. Write-only by design. | **Working** |
| `deep_link` | Inbound URL at launch and while running. Delivers the URL; routing is the app's. | **Working** — native + web; Windows is custom-scheme only |
| `worker` | Long-lived compute actors off the UI thread: typed messages in, typed replies out, in order on the UI thread. | **Working** |
| `http` | Request/response client: a request from any action, one typed `Result` back on the UI thread. | **Working** |
| `locale` | Device locale at boot + change events — the tag that feeds `l10n.Bundle`'s `resolve` ([localization.md](localization.md)). | **Working** — every shell and the web; nothing links; the Linux tag is boot-only |
| `oauth` | The sign-in browser session: open an authorize URL where the user can trust it, get the callback URL back. | **Working** — all six platforms; no vendor SDK |
| `iap` | The platform stores: catalog, payment sheet, purchase-update stream, finish, restore. | **Working** — StoreKit and Play Billing; no store on Windows, Linux, or the web |
| `haptic` | The back gesture's threshold knock. **Framework-internal: no app can call it.** | **Working** — iOS only, the one platform that runs a threshold of nokre's own ([internals/haptics.md](internals/haptics.md)) |
| `open_url` | One verb: hand a URL (https/http/mailto — a closed set) to the system browser. Fire-and-forget. | **Working** — every shell and the web; nothing links |
| `share` | One verb: put the OS share sheet up with UTF-8 text on it; the user picks the destination. Fire-and-forget. | **Working** — four native sheets and the web's `navigator.share`; no sheet on the Linux desktop, and `available` says so |
| `clock` | One verb: the wall clock, in milliseconds since the Unix epoch, UTC. Read on demand. | **Working** — every target; nothing links, and no shell is involved |
| `notification` | The OS's own notification surface: ask, post, schedule, cancel, and one lane back for taps, arrivals and push tokens. | **Working** — all six platforms for the local half; push on four, and `scheduleAvailable` is false on the Linux desktop and the web |

`haptic` is on this list for completeness, not for use: it is a
`Services` field because everything platform-flavored is injected and
observable in tests, and it has no consumer verb at all. "Buzz when I say
so" is a feedback hook in the same family as a styling hook. The roster
grows the way the element set does — a row is argued on semantics, and
`open_url` earned its place when the `document` element's motivating
content (fetched legal text, with its `mailto:` and third-party
references) made "no external URLs" a refusal stricter than its
rationale — never as a grab-bag of platform bindings.

**One failure shape.** Every service whose verb can fail without an
answer — http's transport, oauth's session, iap's store — fails with
the same type, `nokre.services.Failure`: a value carrying one stable
`name`, never an exception, and never a display string (the name is
for dispatch and logs; the app owns the words it shows). Each module
re-exports it as its own `Failure` and states which names it delivers,
so per-service code reads unchanged — but the type is *one*, so a
shared failure surface (an offline banner, a retry notice) takes
`nokre.services.Failure` and accepts all three.

### secure_store: a pouch, not a database

Small secrets — a session token, a device id — as encrypted key/value
behind four synchronous calls: `get`, `set`, `delete`, `list`.
Synchronous on purpose: a secret is local state, every backend answers
in-process, and the reads that matter happen at boot — nokre has no
tickers to retire the loading frame an async boot read would strand,
so the stored token is one call inside `build`, deciding the first
screen with no handshake.

Like `package_info` — and unlike `http` — the service links: linking
costs something real (Security.framework on Apple, advapi32 on
Windows, a ~673 KiB static table on wasm), and a store is meaningless
without an identity to namespace it, so it requires `pkg_id`:

```zig
const nokre = b.dependency("nokre", .{
    // ...
    .pkg_id = @as([]const u8, "com.example.notes"), // the store's namespace
    .secure_store = true,
});
```

Unlinked, every call site is a comptime error naming that one-line
fix.

```zig
// At boot, inside build: the stored token decides the first screen.
var buf: nokre.services.secure_store.ValueBuf = undefined;
const token = nokre.services.secure_store.get(app, "auth.token", &buf) catch |err| switch (err) {
    error.Unavailable => null,      // locked keychain: degrade to signed-out
    error.InvalidKey => unreachable, // "auth.token" is in the charset
};
// null is absence — a missing key is data, like a 404, never a
// failure; an empty slice is a present, empty value. The returned
// slice aliases `buf`: reusing the buffer invalidates it.

// In actions:
try nokre.services.secure_store.set(app, "auth.token", tk); // upsert
try nokre.services.secure_store.delete(app, "auth.token");  // idempotent: absent is success
var lb: nokre.services.secure_store.ListBuf = undefined;
const keys = try nokre.services.secure_store.list(app, &lb); // bytewise ascending, keys only
```

Caller buffers everywhere — no allocator in the API, no allocation on
any path, on any platform. The caps are contract, not configuration:

| Cap | Value | Why this number |
| --- | --- | --- |
| key | 1–128 bytes of `[a-z0-9._-]` | lowercase-only because Windows credential lookup is case-insensitive — `"Token"` and `"token"` would be one entry there and two everywhere else; the set also survives verbatim as a Keychain account, a CredMan target segment, a libsecret attribute, and a JS storage key — one namespace rule, zero escaping |
| value | ≤ 2560 bytes | Windows sets it: `CRED_MAX_CREDENTIAL_BLOB_SIZE` (5 × 512) is the largest credential blob `CredWriteW` accepts, and no other backend bounds a value anywhere near it. Enforced on the Zig side everywhere, so `ValueTooLarge` means one thing on every platform — the platform's own number, not rounded down to a power of two |
| entries | 256 per app | nokre's number, not a platform's: no backend counts entries, so the line falls where a whole listing stops fitting a caller's buffer — 256 keys is a 36 KiB `ListBuf`. Sized from a real app's shape (three entries per conversation channel, so ~85 channels), which is also what retired the 64 that came before |

A value that doesn't fit is a document, and documents are refused.
Store the refresh token or the session id, not the fat JWT: a JWT
balloons with its claims and expires anyway, while the small
credential you re-derive everything else from is exactly what belongs
in a keychain. The entry count answers to the same rule: a store whose
size tracks the user's graph — an entry per channel, per contact, per
device — has stopped being a pouch, and the way out is one secret with
the rest derived from it, never a bigger cap. Why neither number moves,
and what each route past them would cost, is
[internals/secure_store.md](internals/secure_store.md).

The ceiling is the weakest platform's, and this is which — what each
backend actually bounds, by the API it calls:

| Platform | Backend | What bounds a value | What bounds the entry count |
| --- | --- | --- | --- |
| Windows | Credential Manager — `CredWriteW`, `CRED_TYPE_GENERIC` | **2560 bytes**: `CRED_MAX_CREDENTIAL_BLOB_SIZE`; a larger `CredentialBlobSize` is `ERROR_INVALID_PARAMETER` | nothing documented |
| macOS / iOS | Keychain — `SecItemAdd`, `kSecClassGenericPassword` | nothing: `kSecValueData` is a `CFData`, and 16 MiB stores and reads back byte-exact (measured, macOS 26) | nothing: 1000 items under one `kSecAttrService` all store and enumerate (measured) |
| Android | AES-GCM key in the AndroidKeyStore over app-private `SharedPreferences` | nothing: the ciphertext is a base64 string in a prefs map | nothing: prefs is a map |
| Linux | Secret Service via libsecret — `secret_password_store_sync` | nothing: a secret is a D-Bus byte array (hex-encoded here) | nothing |
| Web | a table inside the wasm module, shadowed to `sessionStorage` | nokre's table, sized to the contract | nokre's table; the shadow's ~5 MB origin quota is best-effort and can never fail a `set` |

So Windows is the binding constraint, and it binds because of an API
choice nokre stands by: Credential Manager ships the whole CRUD and
lists entries in a panel where the user can inspect and revoke them,
where DPAPI over a private file would have no ceiling and the same
protection boundary — and would cost both of those. The trade and its
price are [internals/secure_store.md](internals/secure_store.md).

Errors are closed and per-operation — `get` can never return
`ValueTooLarge`; each signature states exactly what can go wrong:

| Error | On | Producible |
| --- | --- | --- |
| `InvalidKey` | get, set, delete | everywhere, identically — a pure function of the argument, checked before any OS call |
| `ValueTooLarge` | set | everywhere, identically — the cap is the service's, checked on the Zig side |
| `StoreFull` | set | everywhere, identically — the *distinct* key past the entry cap; overwriting an existing key never fails with it |
| `Unavailable` | all four | platform posture: a locked or denying keychain on Apple, a dead logon session on Windows, a Keystore/crypto fault on Android, a locked or absent Secret Service on Linux — and never on the web |

Only `Unavailable` is environmental, and only `Unavailable` is
injectable in tests ([testing.md](testing.md)) — the other three occur
organically, by passing such arguments. The non-errors are decided
too: a `get` miss is `null`, an empty value is legal and distinct from
absent, `delete` is idempotent, `set` is an upsert, and `list` of an
empty store is an empty slice.

**Nothing roams.** Entries never leave the device on any platform:
`kSecAttrSynchronizable` is never set, and Windows credentials persist
per-machine. Two devices merging secrets is nondeterminism — an entry
can only appear because this app wrote it on this device. The cap and
the namespace are the service's, not the OS's: on Windows the entries
are visible in the OS's own Credential Manager panel, where a user can
inspect and delete them — an externally deleted entry surfaces as
`get → null`; treat it as "signed out", never as impossible.

**On the web,** "secure" means session-scoped, not encrypted: entries
live in the tab's sessionStorage — readable by any same-origin script,
surviving a reload but not the tab's close, never leaving the device.
That scope is the point: nokre refuses to park plaintext secrets in
long-term browser storage, so treat the web store as a session cache
for re-derivable secrets and expect to re-authenticate in a new
session. (Client-side JS encryption is refused as theater: the key
would live beside the data.) sessionStorage is also per-tab — a
duplicated tab forks the store — and `error.Unavailable` never occurs
on the web: the in-memory table always answers. That asymmetry is
stated posture, not a bug — and a tested one: nokre boots a real wasm
app against a stubbed browser on every `zig build test`, including with
sessionStorage blocked and with it full, where every verb keeps its
answers and only reload-survival is lost
([testing.md](testing.md#the-webs-own-gate)).

**macOS dev builds** may show an authorization prompt that shipping
builds do not. Signed apps (Developer ID / App Store) use the
data-protection keychain, keyed by application identifier, and are
expected not to prompt; the bare ad-hoc binary `zig build run-…`
produces has no identifier, so it falls back to the legacy file
keychain, whose ACL binds to the ad-hoc signature — which changes every
rebuild, and the synchronous API blocks the UI thread while the dialog
is up. This is dev-only posture, not contract: "Always Allow" holds
until the next rebuild, signing with any stable identity (even
self-signed) ends it, and a Deny maps to `error.Unavailable` — a free
rehearsal of the locked-keychain path every shipping app must handle.
Tests never see it (they only reach the fake,
[testing.md](testing.md)). Packaging note: static-lib consumers (the
iOS Xcode project) add Security.framework themselves.

**The dev store,** for the binary that drives your app end to end
outside `zig test`. That binary is the one case the OS store is not
really yours to use: on macOS an unentitled process is refused the
data-protection keychain outright and lands in the deprecated legacy
one — the developer's own login keychain, ACL-bound to a signature that
changes every rebuild, which is the prompt the paragraph above
describes — and a headless Linux CI machine runs no keyring daemon at
all. Declare it and the Keychain / Secret Service leg is replaced by a
plaintext file:

```zig
const nokre = b.dependency("nokre", .{
    .pkg_id = @as([]const u8, "com.example.notes"),
    .secure_store = true,
    .secure_store_dev = true, // never in a build you ship
});
```

The API does not change, and neither do the caps, the errors or the
sort order: the swap happens under the four native verbs, so the same
policy layer runs above it. The file is `$NOKRE_SECURE_STORE_DEV` if
you set it — one driver run, one store, which is how a run gets a store
nothing else has touched — otherwise `$HOME/.nokre-dev-store/<pkg_id>`,
mode 0600, and yours to delete.

It cannot reach a shipping build, and not because you remembered: the
declaration is refused unless the build is **Debug** and the target is
**macOS or desktop Linux** (iOS, Android, the web and Windows all fail
the build — their stores answer any binary already), it is refused
without `.secure_store`, and the binary that carries it prints one line
to stderr at every launch saying so. There is no runtime path in at
all: which backend a binary has is decided when it is compiled.

The wiring — the Keychain/CredMan mappings, the web snapshot/mirror
flow, the dev store's file format and its four gates, and why each
refusal holds — is
[internals/secure_store.md](internals/secure_store.md).

### clipboard: one verb, write-only

`app.copyText(utf8)` replaces the system clipboard with text — the
whole surface. Activating a `copyable` element lands here
([elements.md](elements.md)); app actions may call it directly. The
acknowledgement — the field's copy glyph standing in as a check — is
the element's, not this verb's: calling `copyText` from an action marks
nothing, because there is no control it belongs to, and that screen's
feedback stays the screen's business.

Write-only is the design: reading the clipboard is a permission prompt
and a privacy posture nokre refuses to take, and paste already
arrives as ordinary text input through the platform's IME/text events.
Nothing links — every shell exports the same C hook (NSPasteboard,
UIPasteboard, the Win32 clipboard, `navigator.clipboard` on the web,
ClipboardManager on Android, a `wl_data_source` selection on the Wayland
shell on Linux).

In tests the app's mock journals every write, in order:
`app.services.clipboard.copies()`, or the harness's
`expectCopied(text)` ([testing.md](testing.md)).

### package_info: identity is declared, not discovered

The pattern-setter for cross-platform configuration. App identity —
name, reverse-DNS id, display version, build number — is declared once,
in the consumer's build.zig, and baked into
[package_info.zig](../src/services/package_info/package_info.zig) at
comptime: the same four values on every platform, wasm included.

Nothing is read back at runtime; instead the manifests are packaging
*outputs*. The emitters in
[src/packaging/packaging.zig](../src/packaging/packaging.zig) generate
them all from this one declaration — `Info.plist`, `AndroidManifest.xml`
(plus the identity properties Gradle reads), the web page and its app
manifest (which a web build folds into the site it hands back —
[getting-started.md](getting-started.md)), and the app icon in each
platform's format — so no file can
become a second source of truth or need hand-writing; generated ones
stay gitignored. The icon is derived too: a deterministic grayscale
mark computed from the id
([src/packaging/icon.zig](../src/packaging/icon.zig)) — the
no-custom-visual-identity refusal ([introduction.md](introduction.md))
applied to the home screen. The same id draws the same mark everywhere,
forever; renaming the display name keeps it.

An app that has real art for Apple's platforms declares it, and that is
the one packaging *input* nokre takes:

```zig
    .apple_icon = b.path("assets/AppIcon.icon"),   // requires .pkg
```

The value is an Icon Composer bundle — the `.icon` **directory** Apple's
tool exports, holding `icon.json` and the layer images it names under
`Assets/`. That format earns the exception by being a declaration
itself: appearance (light, dark, tinted), lighting, shadow and the glass
material are values over vector layers, and every idiom's pixels are
compiled by Xcode's `actool`, never by nokre — which resamples nothing,
re-encodes nothing, and models none of the schema. The bundle is checked
where it is declared (a `.icon` directory, a parseable `icon.json`, every
layer image it names present) and delivered whole to
`pkg/ios/AppIcon.icon` and `pkg/macos/AppIcon.icon` — one icon, both
Apple platforms, which is Icon Composer's own claim, not a duplication
nokre invented. It replaces the derived appiconset rather than joining
it: `actool` resolves the app icon by name, and two answers named
`AppIcon` is one too many. **Xcode 26 is the floor** — an older `actool`
cannot compile a `.icon` at all, and the answer on one is to declare no
`apple_icon` and ship the derived mark. Android and the web keep the
mark either way; `.icon` is an Apple format and nothing else reads it.
Pointing an Xcode project at the delivered bundle — and assembling the
macOS `.app` around what `pkg/macos/` carries — is
[getting-started.md](getting-started.md).

The native side answers only the question the build cannot: installer
provenance (app store / TestFlight / direct / bare `dev` binary; `web`
on wasm), as one stateless synchronous query. The query is real on
macOS and iOS — on iOS `direct` never occurs, because the only
distribution runs through Apple — and answers `dev` on the platforms
whose store detection has not landed.

Because one id now serves every platform, its charset is the
intersection of their rules, checked at build time: two or more
dot-separated `[a-z][a-z0-9_]*` segments (Android's applicationId is
the narrowest; lowercase because Apple compares bundle ids
case-insensitively). Permissions are derived from the linked-service
set, never declared — the always-linked `http` implies Android's
`INTERNET`, `secure_store` implies nothing anywhere (Keychain and
Keystore need no manifest entry) — each service's row lives with the
emitters. One duplication survives, and it is Apple's: the Xcode
project's `PRODUCT_BUNDLE_IDENTIFIER` belongs to the signing machinery,
and Xcode fails the build if it disagrees with the declared id — drift
is loud, never silent.

The in-repo examples consume the tree automatically (`zig build pkg` →
`zig-out/pkg`; the Android example's Gradle regenerates it at every
configuration — manifest and icon res tree both, the iOS project reads
`pkg/ios/Info.plist` and the asset catalog from the install prefix its
build phase already fills, and `zig build web` copies the web
files). A consumer building through `addApp` gets the tree as
`App.pkg`, carrying the declared identity
([getting-started.md](getting-started.md)); a module-only consumer
that declares `pkg_*` gets the same tree as named write-files:

```zig
const pkg = b.step("pkg", "Generate packaging manifests");
pkg.dependOn(&b.addInstallDirectory(.{
    .source_dir = nokre.namedWriteFiles("pkg").getDirectory(),
    .install_dir = .prefix,
    .install_subdir = "pkg",
}).step);
```

```zig
const nokre = b.dependency("nokre", .{
    .target = target,
    .optimize = optimize,
    // Setting pkg_id is what links the service.
    .pkg_id = @as([]const u8, "com.example.notes"),
    .pkg_name = @as([]const u8, "Notes"),
    .pkg_version = @as([]const u8, "1.2.0"),
    .pkg_build = @as(u32, 42),
});
```

Then `nokre.services.package_info.get()` anywhere. With `pkg_id`
unset the service is unlinked and that call is a comptime error naming
the fix.

### worker: compute off the UI thread

App code runs entirely inside the UI thread's loop, so an `Action` that
takes 200ms freezes taps, keys, and paint for 200ms. A **worker** is
where heavy synchronous work — indexing, search, parsing, media
crunching — goes instead, without app code ever seeing a thread. The
model is the app's own loop with the screen removed: the app sends typed
**messages**, the worker turns them into typed **replies**, and the
replies land back **on the UI thread, in order**, as an `Action` in
shape — ctx + function pointer, mutate state, `invalidate()`. Nothing is
shared: every message is copied across, so no app author can write a
data race.

A worker is a plain struct — message types nested inside, no base class,
no trait — and it never sees the `App`:

```zig
const h = @import("nokre");

/// Runs off the UI thread. Owns its state; only its own loop touches it.
const Search = struct {
    gpa: std.mem.Allocator,
    corpus: std.ArrayList(Doc) = .empty,

    pub const Msg = union(enum) {          // app → worker
        add_doc: struct { title: []const u8, body: []const u8 },
        query: struct { text: []const u8, limit: u32 },
    };
    pub const Reply = union(enum) {        // worker → app
        progress: struct { percent: u8 },
        hits: struct { titles: []const []const u8 },
        abandoned,                         // yielded, no result coming
    };

    pub fn init(gpa: std.mem.Allocator) !Search { return .{ .gpa = gpa }; }
    pub fn deinit(self: *Search) void { /* free corpus */ }

    /// One message at a time, in order. `msg`'s slices are valid only
    /// for this call — copy anything that must outlive it.
    pub fn handle(self: *Search, msg: Msg, out: *h.workers.Outbox(Reply)) !void {
        switch (msg) {
            .add_doc => |d| try self.corpus.append(self.gpa, try Doc.dupe(self.gpa, d)),
            .query => |q| {
                var hits: std.ArrayList([]const u8) = .empty;
                for (self.corpus.items, 0..) |doc, i| {
                    // Any queued message makes this stale, not just a
                    // newer query — and a silent return leaves the app
                    // waiting on a reply that is never coming.
                    if (out.interrupted()) return out.send(.abandoned);
                    if (doc.matches(q.text)) try hits.append(out.arena, doc.title);
                    if (i % 1024 == 0)
                        try out.send(.{ .progress = .{ .percent = pct(i, self.corpus.items.len) } });
                }
                try out.send(.{ .hits = .{ .titles = hits.items } });
            },
        }
    }
};

/// The closed set of workers this app can spawn — the role routes play
/// for screens. Root-level so every thread's copy of the artifact can
/// find the code from a wire id.
pub const nokreWorkers = .{Search};
```

The app side is three verbs — `spawn`, `send`, `retire` — plus the
reply handler:

```zig
// Spawn on the UI thread (boot or first use). Not in nokreWorkers → a
// curated compile error naming the fix.
state.search = try h.workers.spawn(Search, .{ .app = app, .ctx = state, .on_reply = onSearchReply });

// Send from any action. `send` serializes immediately — the slices are
// borrowed only for the call, then the caller's memory is its own again.
try state.search.send(.{ .query = .{ .text = q, .limit = 20 } });

// Replies arrive on the UI thread, between events — an Action in shape.
fn onSearchReply(ctx: ?*anyopaque, reply: Search.Reply) void {
    const state: *State = @ptrCast(@alignCast(ctx.?));
    switch (reply) {
        .progress => |p| setProgress(state, p.percent),
        .hits => |found| rebuildResults(state, found.titles),
    }
    state.app.invalidate();
}

// Retire: no more sends accepted, the current message finishes, deinit
// runs, the thread joins. Replies already sent still arrive first.
state.search.retire();
```

`spawn` returns a generation-checked `Handle(Search)` — a stale handle
is `error.WorkerRetired`, never a dangling pointer; spawning the same
type twice gives two independent workers. Inside `handle`, `out` is the
worker's whole capability surface:

- `send(reply)` — serialize and post now; callable any number of times
  per message, so progress is just more replies.
- `interrupted()` — true when a newer message is waiting or retirement
  was requested. Cooperative cancellation: a search loop polls it
  between chunks, a batch insert ignores it — per-message judgment,
  which is why it is a query and not a mechanism.
- `arena` — scratch allocator freed after `handle` returns; the natural
  place to assemble reply slices.

A very large payload can move instead of copy: `h.workers.Bytes` is an
owned `[]u8` whose *ownership* crosses the boundary (`Bytes.adopt(buf)`
to send, `view()` to read on arrival, `take()` to keep it past the
call). Exactly one side can reach the buffer at any moment, so "values,
not references" survives it; native moves the pointer for zero copies,
the web pays one copy by physics.

What a consumer can rely on:

- **In order, exactly once**, both directions, per worker.
- **One message at a time** — a worker is single-threaded, so its state
  needs no locks.
- **Handlers run on the UI thread only**, between input events; app code
  stays single-threaded, full stop.
- **Values, not references** — `send` copies at the call; a delivered
  message's slices are valid only for the handler call, or ownership
  moves whole via `Bytes`.
- **Causality** — a worker runs only downstream of a message: no timers,
  no self-wake, so a worker at rest costs zero CPU.
- **Failure is a message** — `handle` returning an error drops that one
  message, reports a `Fault` to spawn's optional `on_fault`, and the
  worker lives on; a dead worker is `Fault.died` and the handle retires.

#### ask: a question with exactly one answer

`send` feeds a reply *stream*: which reply answers which message is the
app's own bookkeeping, which is right for progress and sessions and
wrong for request/response — every consumer that wanted "solve this,
tell *this* callback" ended up hand-rolling a pending-callback queue in
front of the handle. `spawnAsker` is the same worker struct behind that
contract, kept by the library instead:

```zig
state.solver = try h.workers.spawnAsker(Pow, app);

// Each ask carries its own callback; the message is serialized inside
// the call, exactly like `send`.
try state.solver.ask(.{ .solve = spec }, state, onSolved);

// Exactly one answer per accepted ask: the worker's one reply, or the
// fault that took its place.
fn onSolved(ctx: ?*anyopaque, answer: h.workers.Answer(Pow)) void {
    const state: *State = @ptrCast(@alignCast(ctx.?));
    switch (answer) {
        .reply => |r| acceptProof(state, r),
        .fault => |f| failPending(state, f),
    }
    state.app.invalidate();
}
```

The contract, each line load-bearing:

- **Exactly one answer per accepted ask, in ask order.** A reply, a
  `handle` error's fault, or `.died` — never zero, never two. The
  order is part of the contract: a consumer whose per-ask context is
  wider than one pointer keeps its own plain FIFO and pops in
  lockstep.
- **The queue is bounded**: `max_pending_asks` (32) questions open at
  once, counting the one in flight. A full queue refuses at the call —
  `error.TooManyAsks`, nothing queued, no callback coming — rather
  than hiding an unbounded backlog behind a growing latency.
- **Only the front question is in the worker's inbox**; the next
  routes when it answers. So `interrupted()` mid-answer means
  retirement, never an unrelated ask — queueing a mutation cannot make
  an in-flight solve stale.
- **The worker's side of the bargain**: exactly one reply per message
  on this surface. Extra replies have no question left and are
  dropped; a message answered by silence leaves the next answer
  landing on the wrong question — the same class of bug as yielding
  silently under `interrupted()`.
- **`retire()` drains.** Every queued question still reaches the
  worker — mid-retirement it sees `interrupted()` and may answer cheap,
  but it answers — then `deinit` runs and the transport falls.
- **`pending()`** is the questions still open — an e2e driver's idle
  probe: settled when zero.

A port that is single-flight *without* a worker behind it — an adapter
that can hold only one caller's callback — queues the same way with
`h.Queue`, the bounded FIFO this surface grew from
(src/core/queue.zig owns its contract).

Like `http` — and unlike `package_info` — nothing links: the service is
always available, and an app that spawns no worker pays nothing.
Request/response is `spawnAsker`/`ask`; progress streams and long-lived
stateful sessions are `spawn`/`send`. The wiring — the per-platform
transports, the wire codec, why there is one artifact per thread, and
the refusals (no shared memory, no futures, no thread pool, no forced
kill) — is [internals/workers.md](internals/workers.md).

### http: the network as a message

One API on every platform; behind it the shells wire what they have —
native blocks one visible thread per request on `std.http.Client` and
nothing else (no pool hides under it, deliberately — the reason is
[internals/http.md](internals/http.md#no-pool-under-the-native-transport),
and one consequence is that a host's addresses are tried in sequence
rather than raced), the web hands the job to the browser's `fetch`,
tests park the request until the test answers it — and the consumer
contract never changes: no futures, no locks, no callback off the UI
thread. Requests and
worker messages share one delivery lane, so ordering, thread
discipline, and the testing story are the same fact, not three
parallel ones. One platform wants the hosts in advance: a web build's
page allows only the origins its declaration named, so a host reached
from here is a `web_connect_src` entry there
([getting-started.md](getting-started.md)).

```zig
_ = try nokre.services.http.request(.{
    .app = app,
    .url = "https://api.example.com/notes",
    // Echoed to on_result untouched, on success and failure alike. The
    // caller's correlation tag: a generation, an index, a packed pair —
    // the receiver's business. Answers "which ask is this the answer
    // to?" without a client instance per outstanding request.
    .tag = state.notes_generation,
    .ctx = state,
    .on_result = onNotes,
});

fn onNotes(ctx: ?*anyopaque, tag: u64, result: nokre.services.http.Result) void {
    const state: *State = @ptrCast(@alignCast(ctx.?));
    // The stale-response race, closed by comparison: a reply to a
    // superseded ask identifies itself and is dropped whole.
    if (tag != state.notes_generation) return;
    switch (result) {
        // Status codes are data — a 404 lands here, whole, once the
        // body has fully arrived. Slices are valid only for the call;
        // the body is a Bytes: view() to read, take() to keep.
        .response => |r| showNotes(state, r.status, r.body.view()),
        // Transport failure is a value with a stable name, never an
        // exception: "ConnectionRefused" natively, "FetchFailed" on
        // the web (the browser hides reasons by design),
        // "BodyTooLarge" on both when max_body holds the line.
        .failure => |f| showOffline(state, f.name),
    }
}
```

`request` copies everything at the call and returns a
generation-checked handle; `handle.cancel()` guarantees the callback
never runs (the wire transfer may still finish where the platform
cannot abort it — its delivery is dropped). `max_body` (default 16 MiB)
caps what a rogue server can push into the app's memory. Every request
carries one fixed transport deadline: 30 seconds after `request`, an
unfinished request fails like any other transport failure —
`"TimedOut"` natively, the web's one name `"FetchFailed"`. The
deadline is a contract constant, not a knob, for the reason `max_body`
is a cap: it is transport policy, not an app decision — and it is what
guarantees the failure path eventually runs, so recovery (clearing an
`in_progress` button, showing offline) belongs to the app's failure
handling, which now always gets its turn. Under `zig test` the mock
ignores it: parked requests stay parked until the test answers, so the
network stays a test input. The verb set is closed — GET, HEAD, POST,
PUT, PATCH, DELETE — and the verb, not the bytes, decides whether a
request carries a body: POST, PUT and PATCH always do, empty or not
(`content-length: 0` is a body a server can read as one), and passing
`body` on any other verb is a programmer error nokre asserts on rather
than a request one platform would send and the other would refuse.
There is no streaming, no timeout knob, and
no per-request configuration surface. Like `worker` — and unlike
`package_info` — nothing links: the service is always available, and
an app that never calls it pays nothing.

### deep_link: the URL comes in, routing stays yours

A link into the app — `https://notes.example.com/n/42` tapped in Mail, a
custom-scheme re-open, a `#/n/42` fragment on the web — arrives as one
thing: the URL. nokre hands it over and stops. Where that URL goes is
the router's job, which the app already owns; deep_link owns only *that a
URL came in*. That line is the whole design: no route table baked into
the service, no URL scheme convention imposed, no matching rules to
configure. The app reads the URL and decides.

Not to be confused with the current route, which the web shell mirrors
into the address bar without any service at all
([routing.md](routing.md)). That one is a reference nokre fully owns —
a screen name plus identifier arguments, `#note~42` — and can therefore
both write and honor; this one is a URL nokre deliberately does not
interpret. Reach for deep_link when the link carries what a reference
cannot: free text, a query, a path, or a claimed domain.

One handler, one lane. The launch URL — present because the app was
opened by a link — is the first callback after boot; every runtime link
is a callback after that, each on the UI thread, interleaved with input
like a worker reply. Register once, inside `build`:

```zig
// Inside build (or the route builder): wire the handler once.
nokre.services.deep_link.setHandler(app, state, onLink);

fn onLink(ctx: ?*anyopaque, url: []const u8) void {
    const state: *State = @ptrCast(@alignCast(ctx.?));
    // The web deep link is the fragment; native links carry a path.
    // Route on whichever the app speaks — this is the app's job.
    const target = nokre.services.deep_link.fragment(url) orelse url;
    state.app.navigate(target) catch {};
}
```

`fragment(url)` is the one helper: the bytes after the first `#`, or
null when there is none (an empty fragment, `…#`, is present and empty —
absence and emptiness are distinct, secure_store's rule). Nothing else is
parsed for you; a URL is the app's to read.

Like secure_store — and unlike http — it links, and linking requires
`pkg_id`: the iOS entitlement and the Android assetlinks are keyed to the
app's identity, and the domains the app claims drive the packaging
derivation. Linking is the domains:

```zig
const nokre = b.dependency("nokre", .{
    // ...
    .pkg_id = @as([]const u8, "com.example.notes"),
    // Claim the domains the OS should route into the app. Empty (unset)
    // leaves the service unlinked; every setHandler call site is then a
    // comptime error naming this fix.
    .deep_link = @as([]const []const u8, &.{ "notes.example.com", "example.com" }),
});
```

That one declaration lights up the packaging tree
([packaging.zig](../src/packaging/packaging.zig)): the iOS
associated-domains entitlement (`ios/App.entitlements`), the Android
App-Links `intent-filter` (`autoVerify`, one https `<data>` host per
domain), and the two server files the developer hosts at each domain's
`/.well-known/` — `assetlinks.json` and `apple-app-site-association`.
Everything derivable is derived; the two values a declaration cannot know
— Apple's Team ID and the Android signing cert's SHA-256 — are marked
with a loud `REPLACE_…` placeholder in those server files, never a
fabricated value that would silently fail verification.

**Domains, not a `myapp://` custom scheme — on purpose.** A deep link can
be a private scheme the app registers or a real `https://` URL on a domain
the app owns (Universal Links / App Links); nokre derives only the
second, because only the second is *verified*. The `.well-known/`
handshake above is a two-way proof — the app names the domain, the domain
vouches for the app — whereas any installed app can claim `myapp://` and
intercept it. The verified link also degrades gracefully: one
`https://notes.example.com/n/42` opens the app when installed and the
website when not, while a custom-scheme URL is dead wherever the app is
absent. The runtime side is scheme-agnostic — the handler receives
whatever URL the OS delivers, custom scheme included — but a custom scheme
is a *different*, underived manifest declaration (`CFBundleURLTypes` / a
`scheme=` intent-filter): its own opt-in if a need appears.

**On Windows** the custom scheme is the only inbound leg — the roster's
"custom-scheme only" — because a verified https link for an unpackaged
Win32 app does not exist: that is MSIX's `windows.appUriHandler`, a
different packaging model. The contract is otherwise the one above:
one instance surfaces (a link tapped while the app runs reaches the
running window rather than stacking a duplicate), a launch link is
buffered until the first build wires `setHandler` so it is never
dropped, and the handler receives whatever URL the OS delivers — the
process hand-off behind that is
[internals/platform-shells.md](internals/platform-shells.md)'s to
explain. What nokre does not do: register the scheme. The
registration — `HKCU\Software\Classes\<scheme>` with `URL Protocol` and
a `shell\open\command` naming the exe — is the app's or its
installer's, and packaging deliberately derives none of it, for the
reason the paragraph above states: nokre derives only *verified* links,
and a registry key any installed app can also write is precisely not
one.

**On the web** the deep link is the URL fragment: a `hashchange` is a
runtime link, and a fragment present at load is the launch URL, delivered
once after boot. No entitlement, no server file — the origin already
proves ownership. It is also the one leg here nokre executes rather than
mocks on its own side: a launch fragment, a later `hashchange`, and a
percent-encoded payload byte for byte, on every `zig build test`
([testing.md](testing.md#the-webs-own-gate)).

In tests the mock is one app's fake link source: `deliver(url)` is the
launch URL as the first call, then any runtime link, journaled in order
and routed to the registered handler on the spot — the harness's
`deliverDeepLink` adds the trace step and re-audit
([testing.md](testing.md)). A URL delivered before the app registers a
handler is journaled but unhandled (`received()` shows it, `hasHandler()`
is false) — a launch link the app has not wired to route yet is data, not
a crash.

### locale: the device's tag, cached

The OS knows which language the user reads; a bundle knows which
languages the app speaks. This service is the sentence between them,
and nothing more: the device's BCP 47 tag at boot, and a callback when
it changes. It carries no language logic of its own — matching a tag
to a catalog is `Bundle.resolve`'s job and was before this existed,
and direction is `L.dir` / `l10n.directionOfTag`
([localization.md](localization.md)). Three lines cover the whole
handoff, inside `build`:

```zig
const dev = nokre.services.locale.tag(app);  // "" when the platform has none
const loc = L.resolve(dev);                   // the template if none match
app.setLocale(L.tag(loc)) catch {};           // the app is now *in* that locale
app.setDirection(L.dir(loc));                 // mirror the chrome to it

// Optional, and also inside build: the user switching languages
// mid-session. Registering again replaces, so a rebuild that
// re-registers the same handler is a no-op.
nokre.services.locale.setHandler(app, state, onLocale);

fn onLocale(ctx: ?*anyopaque, tag: []const u8) void {
    const state: *State = @ptrCast(@alignCast(ctx.?));
    const loc = L.resolve(tag);
    state.app.setLocale(L.tag(loc)) catch {};
    state.app.setDirection(L.dir(loc));
    state.app.invalidate();   // what a new locale changes is the app's call
}
```

**The tag is cached, not read live.** `tag(app)` returns a slice of app
state — no allocation, no OS call, no error — which is what makes it
legal inside `build`, where a per-frame `CFLocaleCopyCurrent` would
not be; an on-demand read would also owe the caller an error path for
a question that cannot usefully fail. Freshness comes from the other
direction: the shell fires the callback on every OS locale change, so
the cache is stale only across the gap between the change and a
callback the shell had to send anyway. The Wayland shell is the one
with no change signal to send: its tag comes from `LC_ALL` /
`LC_MESSAGES` / `LANG`, which do not change under a running process,
so it fires once at boot and the app never hears again. The tag is
still right, it just never moves.

The boot read is synchronous, and the install happens inside
`App.init` rather than at the first `setHandler`, because the first
`build` must already know the language: nokre has no ticker to retire
the loading frame an async boot read would strand (secure_store's
argument), and a first-use install would fire the boot callback in the
middle of the `build` that triggered it. So `setHandler` is the
*change* lane only, and stays optional — an app that reads the tag at
boot and never again registers nothing at all.

**Unknown is the empty tag, never an invented `"en"`.** A platform that
declines to name a locale, a shell without the hook, and a tag past
the 64-byte cap all report `""`, which `resolve` answers with the
template — the app's own source language, the only defensible guess.
`"en"` would instead pick the *English* catalog of a bundle whose
template is Persian, and pick it unfalsifiably: nothing downstream can
tell a real `en` device from a fabricated one. The cap refuses
truncation for the same reason it refuses invention. A truncated tag
still looks like a tag and can still match a catalog, so it fails
silently in the wrong language; empty fails to the template, which is
the failure you can reason about.

**Nothing links.** secure_store and deep_link link because linking buys
something that costs something — a framework, an entitlement, a
manifest declaration, `pkg_id` to namespace it by. A locale buys none
of that: no framework, no permission prompt, no server file, no
identity, nothing in any manifest. The tag is already in the shell's
hands, so this is clipboard's posture — every shell exports the same
hook and reports the tag it has (`NSCurrentLocaleDidChangeNotification`
on macOS and iOS, `onConfigurationChanged` on Android,
`WM_SETTINGCHANGE`/`"intl"` on Windows, the environment on Wayland).
There is no build flag, no options module, and no unlinked comptime
error to hit. **On the web** the tag is `navigator.language`, seeded
into wasm strictly before boot — so the boot read is synchronous there
too — and `languagechange` is the change event; the origin declares
nothing.

In tests the mock is one app's fake device: the boot tag is config
(`.locale = .mock(.{ .tag = "fa-IR" })`), readable inside the first
`build`; `change("de-CH")` is the OS switching under the running app,
routed to the handler on the spot; and every tag reported is
journaled, boot first, so "the app never read the boot locale" is an
assertion and not a hope ([testing.md](testing.md)).

### oauth: the browser session, and where it stops

Most of a sign-in already works without this service. The app builds
the authorize URL, `http` exchanges the code, `secure_store` keeps the
refresh token, `deep_link` carries an inbound URL. The gap is the
middle — opening that URL somewhere the user can *trust*, and getting
the callback URL back — and that is all this service is.

"Somewhere the user can trust" is RFC 8252, not taste: the system
browser or an in-app browser tab, **never an embedded web view**,
because an embedded view can read the password field. That single rule
is also why no vendor SDK is needed — the argument, provider by
provider, is [internals/oauth.md](internals/oauth.md)'s — at exactly
one named cost: no Android Credential Manager one-tap, the user sees a
Custom Tab.

Two calls, in this order, once per flow:

```zig
var buf: oauth.RedirectBuf = undefined;
const redirect = try oauth.redirectUri(app, "com.example.notes", &buf);

var vbuf: oauth.pkce.VerifierBuf = undefined;
var cbuf: oauth.pkce.ChallengeBuf = undefined;
const verifier = oauth.pkce.verifier(app, &vbuf); // keep it for the exchange
const challenge = oauth.pkce.challenge(verifier, &cbuf);
// …build the authorize URL from `redirect`, `challenge`, scopes, state…

_ = try oauth.start(.{
    .app = app,
    .url = authorize_url,
    .redirect = redirect,
    .ctx = state,
    .on_result = onAuth,
});

fn onAuth(ctx: ?*anyopaque, result: oauth.Result) void {
    switch (result) {
        // The OS handed the callback URL back. Parse it, exchange the
        // code over `http`, store the refresh token in `secure_store`.
        .callback => |url| exchange(ctx, oauth.param(url, "code") orelse return),
        // The user dismissed the sheet. A first-class value, not an
        // error: cancelling a login is a normal thing to do.
        .cancelled => dismiss(ctx),
        // Transport or configuration failure, as a stable name — http's
        // `.failure` posture.
        .failure => |f| showAuthError(ctx, f.name),
    }
}
```

`redirectUri` is not ceremony. On Windows and Linux the redirect is a
loopback URL whose port the OS picks (RFC 8252 §7.3), so the listener
has to bind *before* the authorize URL can be written down; on the web
it is the page's own address, because in a browser the origin is the
registration; everywhere else it is the custom scheme. One call covers
all three, and the token exchange needs the same string back — so
exposing it beats hiding it. `scheme` is validated on every platform,
even where that platform ignores it, so a scheme that is legal on the
developer's machine cannot be illegal on the CI target.

**One flow at a time**, per app: a second `start` is
`error.AuthInFlight`. A browser sheet is modal and a person can only be
signing in once, and that fact is what lets the native contract carry a
bare session pointer instead of a request id. The returned handle's
`cancel()` dismisses the sheet, and then no callback arrives at all —
distinct from `.cancelled`, which is the user's decision, not the
app's.

**PKCE and `state`** are `oauth.pkce`: `verifier`, `challenge` (S256 —
`plain` is not offered, since it is precisely the mode that protects
nothing on a device where another app can see the redirect), and
`state`. These are the one place nokre uses randomness, and the
carve-out is deliberate: a service is not core, and a verifier without
cryptographic randomness is not a verifier. Determinism is preserved
where it matters instead — under `zig test` both read seeds from the
app's mock, so a screen that renders an authorize URL renders the same
one every run. nokre does not compare `state` for you: what a mismatch
means is the app's, and a framework that swallowed one would hide the
attack it exists to reveal.

Per platform: **macOS and iOS** are `ASWebAuthenticationSession`, plus
the native `ASAuthorizationController` when `.provider = .apple` and the
app declared Sign in with Apple — one consumer call, two implementations
chosen at comptime, `secure_store`'s dispatch. Apple's native leg
reports its grant as a *synthetic* callback URL (`code`, `id_token`, and
the app's own `state`, percent-encoded in Zig), so the app parses one
shape everywhere. **Android** is a Custom Tab, with the redirect
arriving as an intent through the same activity path `deep_link` uses;
backing out of the tab is the cancel, because nothing else reports one.
**Windows and Linux** are the default browser plus a loopback listener —
one detached thread per flow, delivering through the same one-shot lane
`http` uses. **On the web** it is a popup on the app's own origin, which
posts its landing URL back and closes; a top-level redirect would tear
down the wasm instance mid-flow and take the verifier with it.

Linking needs identity, like `secure_store` and `deep_link`: the URL-type
registration and the intent-filter are keyed to the app id. Declaring
`.oauth` derives a `CFBundleURLTypes` entry on Apple and a VIEW
intent-filter on Android; `.oauth_apple` derives the
`com.apple.developer.applesignin` entitlement. Windows, Linux, and the
web derive nothing — a loopback listener registers nothing, and the
origin is its own registration. This is the custom-scheme opt-in
`deep_link` deferred; `deep_link`'s refusal is unchanged, and still
derives only verified `https://` domains.

Where the service stops is `deep_link`'s line: nokre hands over the
callback URL and stops. No token refresh policy — when to refresh is
the app's session model, and a timer is a ticker, which nokre has
none of. No user model: an idToken is a JWT the app decodes and sends
to its backend to verify. No JWT signature checking: that needs the
provider's rotating JWKS, a fetch with a cache policy and a clock — the
server does it, and nokre returns bytes. No route table: post-login
navigation is the router's, which the app owns. Apple's token exchange
needs the app's backend regardless, since the client secret is a JWT
signed with the developer's `.p8` key, which must never ship in a
binary.

The button that starts the flow is `button` with `provider` set: nokre
draws the vendor's conforming sign-in button — Apple's in the palette
it already had, Google's with the multicolour G, which is the one
colored thing nokre ever draws and is the renderer's, never the app's
(the words are yours to supply in your locale on both) — see
[elements.md](elements.md#button). Google's mark was long refused and
the refusal was deliberately reversed; the record of both decisions is
in [internals/oauth.md](internals/oauth.md).

In tests the mock is one app's fake browser: `start` parks and journals
what the app actually built — so "the app requested the wrong scopes"
and "the app never sent a PKCE challenge" are assertions — and nothing
moves until the test says what the user did (`completeAuth`,
`cancelAuth`, `failAuth`; [testing.md](testing.md)). The web's popup
flow is additionally executed on nokre's own side — the redirect it
seeds, the message it accepts, and the three it refuses
([testing.md](testing.md#the-webs-own-gate)); the native browser
sessions are still asserted by nothing but their mock.

### iap: the stores, and the money nokre never formats

Four verbs, one query, one stream. The only service that genuinely
needs a per-platform SDK — which is why its Android leg asks for the
one dependency nokre has ever asked a consumer to add.

```zig
// Boot, inside build: is there a store here at all? Cached at App.init
// like locale's tag — synchronous, no OS call, no error.
if (!nokre.services.iap.available(app)) return; // draw no paywall

// Register once, inside build. The stream is the *only* place a
// purchase arrives, including ones this launch never asked for.
nokre.services.iap.setHandler(app, state, onPurchase);

// The catalog. Request/response, http's shape.
_ = try nokre.services.iap.products(.{
    .app = app,
    .ids = &.{ "coins.100", "pro.month" },
    .ctx = state,
    .on_result = onProducts,
});

fn onProducts(ctx: ?*anyopaque, catalog: nokre.services.iap.Catalog) void {
    switch (catalog) {
        // An id the store does not sell is simply absent — data, like a
        // secure_store miss. Slices are valid only for the call.
        .products => |rows| for (rows) |p| showPrice(ctx, p.id, p.price),
        .failure => |f| showOffline(ctx, f.name),
    }
}

// From a tap. The outcome arrives on the stream, not here.
try nokre.services.iap.purchase(.{ .app = app, .product = "coins.100" });

fn onPurchase(ctx: ?*anyopaque, update: nokre.services.iap.Update) void {
    switch (update) {
        .purchase => |p| switch (p.state) {
            // Send p.token to your backend; when it has written the
            // entitlement, and not one line before, finish.
            .purchased, .restored => deliver(ctx, p),
            // Committed, unpaid: Play's cash flow, Apple's Ask to Buy.
            // The real purchase arrives later — maybe days later, in
            // another launch.
            .pending => showAwaitingApproval(ctx),
        },
        // The user dismissed the sheet. A value, not an error.
        .cancelled => dismiss(ctx),
        .failure => |f| showPurchaseError(ctx, f.name),
    }
}

// After the goods are durably delivered.
nokre.services.iap.finish(app, txn_id, .consumed);

// Apple requires a visible control for this; results arrive as .restored.
try nokre.services.iap.restore(app);
```

**Money is a string the store hands over.** `Product.price` is already
formatted — `"$4.99"`, `"4,99 €"`, `"۴۹٬۰۰۰ تومان"` — and it is the only
field to draw. nokre performs no currency math and no money formatting:
that is a function of locale, currency, and the store's own regional
rounding, all three applied on the other side of the call, and core is
integer-only with no floats — a framework that reformatted the number
would show a price that disagrees with the one on the payment sheet.
`price_micros` (an integer) and `currency` sit beside it, never drawn,
for reporting a number to a backend, so nobody has to parse
the display string — the failure mode the pair exists to prevent.

**The purchase stream is the only lane**, and it is `deep_link`'s shape
rather than `http`'s for a reason worth stating: the store pushes. An
interrupted purchase redelivered at launch, an Ask-to-Buy approval days
later, a subscription renewal, every result of `restore`, a purchase made
on another device — none of those was requested by this launch. A result
delivered through `purchase`'s own callback would leave all five nowhere
to land, so there is one handler and an app writes one path. Like
`deep_link`'s launch URL, transactions the store had queued before the
handler existed are buffered and flushed at the first `setHandler`, so
registering inside `build` is early enough.

**`finish` is the crash-safety mechanism, not bookkeeping.** Until it is
called, the store redelivers the transaction on every launch — which is
what makes "the app died between the charge and the delivery" a
recoverable state instead of a support ticket. The disposition is the one
place the two stores genuinely differ and cannot be hidden: Apple
finishes both dispositions the same way because it knows the product
type; Play needs a different call for each, and an unacknowledged
purchase is **auto-refunded after three days**. nokre could only pick
for the caller by keeping its own catalog of which SKU is consumable — a
second source of truth for a fact the app declared in the store console
and already knows — so the app says, in one word.

**Ask for a price before charging.** `purchase` only works for an id that
came back from a `products` query in this session, because neither store
takes an id: Apple's `SKPayment` is built from an `SKProduct` and Play's
`launchBillingFlow` from a `ProductDetails`, and both come only from a
query. An unpriced id is the failure `"UnknownProduct"`. That is not a
limitation to work around — an app that has not shown a price has no
business charging.

The caps and the charset are contract, not configuration, and every one
is a pure function of the argument checked before any OS call:

| Cap | Value | Why this number |
| --- | --- | --- |
| ids per query | 20 | Play's per-query cap — Apple documents none, so the store with a bound sets it — enforced on the Zig side everywhere so `TooManyProducts` means one thing on every platform |
| product id | 1–128 bytes of `[a-z0-9._]`, leading `[a-z0-9]` | the intersection of the two consoles' rules (Play's is narrower, and lowercase-only) — an id that is legal on the developer's Apple device and rejected by the Play console should fail on the machine that typed it, which is package_info's argument for the app id |

One sheet and one query at a time per app: a second `purchase` is
`error.PurchaseInFlight` (`oauth`'s `AuthInFlight` argument, sheet for
sheet), a second query is
`error.QueryInFlight` (a paywall asks for its whole catalog at once,
because the id set is a parameter).

**Three platforms have no store, and say so.** `available` is false on
Windows, Linux, and the web, and every other verb is `error.Unavailable`
there. Microsoft's store needs MSIX packaging with a Store identity, which
nokre does not emit; Linux has none; and on the web a page cannot charge
through an app store, while the processors that would work there are the
"payments outside the platform stores" this file lists as not planned.
That is a runtime answer rather than a compile error on purpose: an app
ships one build tree to all six platforms, and the honest instruction is
"do not draw a Buy button", not "fork your source".

**Linking needs identity**, like `secure_store` — both stores resolve
products against the app id:

```zig
const nokre = b.dependency("nokre", .{
    // ...
    .pkg_id = @as([]const u8, "com.example.notes"),
    .iap = true,
});
```

That derives Android's `com.android.vending.BILLING` permission and
nothing else anywhere: In-App Purchase is a capability on the App ID,
enabled in Apple's own console, so there is no plist key and no
entitlement — Apple's cost is `StoreKit.framework` at link time.

**On Android, two lines are the consumer's.** Google requires the Play
Billing Library and removed the AIDL interface that used to be a
protocol, so this is the one place nokre asks for a Maven coordinate —
and it asks in the open, in the consumer's own `app/build.gradle`, rather
than inventing a dependency manager:

```groovy
android { sourceSets { main { java.srcDirs += '<nokre>/src/services/iap/java' } } }
dependencies { implementation 'com.android.billingclient:billing:7.1.1' }
```

…and a third line, in `gradle.properties`, because that coordinate drags
AndroidX in and AGP refuses the classpath without it:

```properties
android.useAndroidX=true
```

That is the only service whose Android leg forces the flag, and it is
stated here rather than discovered at the first Gradle sync: the
kitchen sink never hits it, because the example builds iap's C leg
without the billing dependency behind it. An app that links no `iap`
adds none of the three. On Play the transaction id *is* the purchase
token — it is what your backend verifies with and what `finish` needs;
the reasons are [internals/iap.md](internals/iap.md)'s.

Where the service stops is `oauth`'s line. No receipt verification — the
`token` goes to the app's backend, which calls the App Store Server API or
the Play Developer API; verifying on the device is verifying with the
attacker's copy of the key. No entitlement or expiry model — `isActive`,
renewal windows, and grace periods are a policy with a schedule behind
it, and a schedule is a timer, which is a ticker nokre has none of (the
`clock` service reports the time and `notification.schedule` hands a
date to the OS; nothing in nokre runs one); `restore`
reports what the store says is owned right now, with no dates and no
arithmetic. No catalog, no price cache, no paywall layout, no route
table.

In tests the mock is one app's fake store: seed a catalog and queries
answer themselves with fixed price strings, so a paywall renders
byte-identically every run; leave it empty and the test *is* the store.
Every query, purchase, and finish is journaled, so "the app charged for
the wrong SKU" and "the app never finished the transaction" are
assertions ([testing.md](testing.md)). The wiring — the StoreKit 1
decision, the Maven exception, and why three platforms answer at runtime —
is [internals/iap.md](internals/iap.md).

### open_url: one verb, and the browser is the destination

`open_url.open(app, url)` hands a URL to the system browser — or the
OS's default handler for its scheme, so `mailto:` opens the mail app —
and stops. The whole surface:

```zig
// From an action, or implicitly: activating an external link — a
// span or `link` element carrying `.external` — lands here.
try nokre.services.open_url.open(app, "https://example.com/changelog");
```

**The scheme set is closed**: `https`, `http`, `mailto`, checked on the
Zig side before any OS call, so `error.UnsupportedScheme` means one
thing on every platform (secure_store's pure-function rule). The OS
would happily open `file:`, `javascript:`, or whatever custom handler
an installed app registered; the closed set is the element-set posture
applied to destinations. It is the same allowlist
[markdown](markdown.md)'s link parser and `append`'s external-link
validation consult, so a link that can be constructed is a link this
service will open.

**Fire-and-forget, and never an in-app view.** The posture is
[oauth](#oauth-the-browser-session-and-where-it-stops)'s, generalized:
nokre renders no external content, because the system browser is where
the user's trust actually lives — their cookies, their password
manager, an address bar the app cannot draw over (RFC 8252's argument,
outside the sign-in flow that made it). And once the handoff happens,
the page belongs to the user: the only thing the call could honestly
report is that the OS was asked, so nothing is reported at all. A
device with no handler — a headless session, a browserless container —
fails silently, which is the same signal a failed `xdg-open` gives.

**Nothing links** — clipboard's posture: every shell exports the same
hook (`NSWorkspace` on macOS, `UIApplication` on iOS, ShellExecuteW on
Windows, an ACTION_VIEW intent on Android, `xdg-open` on the Wayland
shell, `window.open(…, "_blank", "noopener")` on the web), there is no
build flag, and an app that never opens a URL pays nothing. On the web
the pointer path never even reaches the service: an external link is a
real `<a target="_blank" rel="noopener noreferrer">` and the browser
handles the click natively — middle-click and "open in new window"
included — while keyboard activation crosses into core and out through
the hook ([internals/dom-edition.md](internals/dom-edition.md)).

In tests the mock journals every open, in order:
`app.services.open_url.opens()`, or the harness's `urlsOpened()` — so
"pressing this link asked the OS for X" is a first-class assertion,
and a rejected scheme journals nothing, because the OS was never asked
([testing.md](testing.md)).

### share: the sheet is the user's

`share.show(app, text)` puts the OS share sheet on screen with a piece
of UTF-8 text on it, and stops. The user picks the destination — a chat
app, mail, notes, another device — from UI the OS draws, populated with
the accounts and apps the OS knows about and nokre never sees.

```zig
// Boot, inside build: is there a sheet here at all? Cached at App.init
// like locale's tag — synchronous, no OS call, no error. False means
// draw no share affordance; iap's "do not draw a Buy button" rule.
const can_share = nokre.services.share.available(app);

// From an action:
try nokre.services.share.show(app, "Look at this: https://example.com/n/42");
```

**One string, and a URL rides as text.** There is no `url` field, no
`title`, no subject line: those are knobs only some destinations honor —
mail reads a subject, a chat app drops it — and a field that works on
half the sheet is a styling hook wearing a lanyard. Every share target
accepts text, and the ones that special-case links find the link in the
text. Files, images, and multiple items are refused for the same
reason the payload is not a document (below): a share is a message.

**Fire-and-forget, twice over.** Once the sheet is up, the only thing
this call could honestly report is that the OS was asked — open_url's
line — so nothing comes back. And which destination the user picked, or
whether they dismissed the sheet, is deliberately unobservable:
clipboard's write-only posture applied to sharing out. Three platforms
would report the chosen target and three would not, and the three that
would are reporting on the user, not for the app.

The caps are contract, not configuration, checked on the Zig side
before any OS call so each error means one thing on every platform:

| Error | Why |
| --- | --- |
| `EmptyText` | a sheet with nothing on it shares nothing — open_url's bare-`mailto:` rule |
| `TextTooLarge` | over 64 KiB. Android sets the bound: the chooser intent crosses the binder transaction buffer — 1 MiB, shared by everything the process has in flight, and overflowing it kills the process rather than returning an error. 64 KiB stays an order of magnitude clear of a cliff whose exact edge depends on traffic, and a share bigger than that is a document — share a URL to the document instead (secure_store's refusal, restated) |
| `Unavailable` | `available` is false: the Linux desktop, or a browser without `navigator.share` |

**Two platforms have no sheet, and say so.** The Linux desktop has no
share target convention — no portal, no chooser; a sheet built from
`.desktop` files would be nokre inventing OS UI — and a browser only
sometimes has `navigator.share` (secure contexts, and not every
browser/OS pair). Both answer at runtime through `available`, iap's
shape: an app ships one build tree, and the honest instruction is "do
not draw the share affordance", not "fork your source". Everywhere
else the sheet is the OS's own — always the system chooser, so the
user picks from everything installed rather than whatever won the last
"always". Which sheet each platform shows, and the Win32 bridge to the
WinRT pane, is [internals/share.md](internals/share.md).

**No geometry in the API.** The sheet is app-level, not
element-anchored: the platforms that need a rect (the iPad popover,
macOS's picker) get the view's center from the shell, arrowless. A
share anchored to the control that fired it would need the tap's
coordinates in a service call, and coordinates are core's, not a
service's.

**On the web,** the browser requires the call to ride the user's own
gesture (transient activation): a share from a tap's action shows the
sheet, a share fired later from an http callback is refused by the
browser — and swallowed by fire-and-forget, so put the call in the
action, not in the response handler. `navigator.share` absent at boot
is `available` false for the session.

**Nothing links** — clipboard's posture: no framework, no permission,
no entitlement, no manifest entry anywhere, and an app that never
shares pays nothing. There is no share element and no share glyph
auto-wired: the icon set carries `share` and `share_2` for the button
an app builds itself, and whether a screen offers sharing is the
screen's business.

In tests the mock journals every text put on the sheet, in order:
`app.services.share.shares()`, or the harness's `sharesShown()` — and a
refused share journals nothing, because the OS was never asked. Boot a
sheetless target with `.share = .mock(.{ .available = false })`
([testing.md](testing.md)).

### clock: the time, and nothing that ticks

`clock.now(app)` answers the wall clock in milliseconds since the Unix
epoch, UTC. One verb, one integer, no error, no allocation, and nothing
to settle:

```zig
// In an action — a tap, a reply handler — not inside `build`.
state.saved_at = nokre.services.clock.now(app);
```

Reading the time is the whole service. What the number *means* is the
app's: a "saved at" stamp, an age to compare a token's expiry against, a
created date to sort by. nokre does no arithmetic on it and draws none
of it.

**Core stays clockless, and that is why this is a service rather than a
utility.** A frame is a function of state, so a screen that changed
because time passed changed for a reason no golden can hold still and no
test can reproduce — which is exactly what the refusals that name a
clock are protecting: no animation, no fading scrollbar, no
self-clearing copy mark, no velocity on the back gesture
([introduction.md](introduction.md)). Nothing in nokre's core or its
renderers calls this, ever. It is `oauth`'s randomness carve-out
restated — a service is not core — and it costs the pixel model nothing,
because a timestamp an app read is app state, and the frame that renders
it is a frame that renders state like every other.

**Read it in the action; keep what you read.** Nothing stops a `build`
from calling this — a value with no error has no honest failure to
raise — but a screen built from the clock is a screen that differs on
every frame: its golden cannot hold still and two runs of the same test
disagree. Read the clock where the event happens, put the result in your
own state, and let `build` render state.

**Milliseconds, UTC, an integer.** Milliseconds is the resolution
people's events happen at, and an i64 of them spans ±292 million years
where an i64 of nanoseconds runs out in 2262 and buys precision no app
that draws text can spend. UTC because a time zone is not a fact about
the instant: converting to local time means the platform's zone database
and date formatter, which is the locale library
[localization.md](localization.md) refuses for producing different bytes
on different OS versions. The same instant is the same number on all six
platforms; a human-readable date is the app's to write, as the same doc
already asks for decimals and dates in messages.

**It can go backwards, and there is no monotonic twin.** An NTP
correction, a user setting the date, a laptop waking up somewhere else —
wall time moves in both directions, so an app that subtracts two stamps
must survive a negative difference. nokre offers no monotonic clock to
hide behind because there is nothing here to time: no animation, no
ticker, no frame budget an app can observe, and a second clock would be
a second thing to explain for a duration nobody is drawing.

**No timers and no scheduling — nokre keeps none, and that is the
precise claim.** "Call me in 30 seconds" is a ticker, and a nokre app at
rest costs zero CPU
([internals/architecture.md](internals/architecture.md)). Expiry
policies, refresh windows, and retry backoff are the app's, computed
from stamps it took — the line `oauth` and `iap` already draw, unmoved
by this service existing. `notification.schedule` is not the exception
it looks like: it hands a fire date to the *OS* and returns, so the
countdown belongs to a system that was going to run anyway and the
process is usually not alive when it fires. Nothing in nokre waits.
Where no such system exists — the Linux desktop, the web —
`scheduleAvailable` says so rather than nokre filling in with a timer of
its own ([internals/notifications.md](internals/notifications.md)
records the decision).

**Nothing links, and no shell is involved** — clipboard's posture,
without even clipboard's C hook. There is no header, no build flag, no
permission and no entitlement anywhere: the call is Zig's own on every
native family (`clock_gettime(CLOCK_REALTIME)` on macOS, iOS, Android
and Linux; `GetSystemTimePreciseAsFileTime` on Windows — the precise
form, because the plain one is quantized to the ~15.6 ms scheduler tick
and would make two stamps either side of real work read as one instant).
**On the web** it is `Date.now()` through services.js, implemented by
both instances the driver runs, so a compute worker can stamp what it
computes. And unlike `share` there is no `available` to ask: a platform
without a clock is not one of the six.

In tests the mock is one app's fake clock, and under `zig test` it is
the *only* clock on every platform — the machine's real time is
unreachable, so a screen that stamps an instant goldens byte-for-byte.
Boot it at an instant with `.clock = .{ .millis = … }` (the default is a
fixed, obviously fake one), move it with `advanceClock(ms)` — signed,
because a device really does correct backwards — and assert that a
screen never asked at all with `clockReads()`
([testing.md](testing.md)).

### notification: the OS's surface, and the interrupt you have to ask for

A message shown **outside** the app — on a lock screen, in a shade, in a
notification centre — now or at a fire date, raised locally or pushed
from your server. nokre asks; the OS draws. Not one pixel of it is
nokre's, which is why a service that reaches someone who put the app
down costs the pixel model nothing (the share sheet's bargain) and why
there is no styling surface here to refuse.

```zig
// Boot, inside build: three synchronous answers, cached at App.init like
// locale's tag. Draw no notifications row where the device has none.
const N = nokre.services.notification;
if (!N.available(app)) return;

// One handler, registered once inside build — the whole inbound lane.
N.setHandler(app, state, onNotification);

// From a control the user pressed, never at boot: the prompt has one
// answer per install, and an app that asks before it has shown why gets
// the reflexive no that cannot be taken back.
try N.authorize(app);

fn onNotification(ctx: ?*anyopaque, event: N.Event) void {
    const state: *State = @ptrCast(@alignCast(ctx.?));
    switch (event) {
        // The prompt was answered — or the user changed their mind in
        // Settings while the app ran. `status` is already updated.
        .authorized => |s| if (s == .granted) requestToken(state),
        // The user tapped one. May be the first thing that happens in a
        // launch: the tap is what started the process.
        .opened => |p| state.app.navigate(p.route) catch {},
        // One came due with the app on screen. No OS banner is drawn for
        // it — what to do is yours: raise an in-app notice, refresh a
        // list, ignore it.
        .received => |p| state.app.notify(.{ .title = "Updated", .route = p.route }),
        // The push transport minted (or rotated) a token. Ship it to
        // your backend over `http`; nokre speaks to no push service.
        .push_token => |t| postTokenToBackend(state, t),
    }
    state.app.invalidate();
}

// In an action:
try N.post(app, .{ .id = "msg.42", .title = "Two new messages", .route = "thread~42" });
try N.schedule(app, .{ .id = "remind.1", .title = "Stand up" }, nokre.services.clock.now(app) + 30 * 60_000);
try N.cancel(app, "remind.1"); // idempotent: already gone is success
```

**The interrupt decision is yours, and you make it twice.**
`app.notify` interrupts inside the app ([elements.md](elements.md));
this interrupts outside it. Neither derives from the other, and that is
deliberate: a framework that turned every in-app notice into a lock-screen
banner would be deciding, on your behalf, to reach someone who had put
the app down. `important` is the same word in both places and means the
same thing — quiet by default, because interrupting is the thing a
message has to ask for. It selects Android's high-importance channel,
Apple's time-sensitive interruption level, and the Linux daemon's normal
urgency; the levels that override Do Not Disturb are deliberately not
used, because "this one may interrupt" asks for less than that.

**The tap carries a route reference, not a URL.** `deep_link` carries
URLs precisely because nokre does not interpret them; both ends of this
wire are nokre's, so what crosses is the reference the router already
speaks (`thread~42` — [routing.md](routing.md)). Routing stays yours, as
it is there.

**Authorization is three states, not a bool.** `not_determined` is a
fresh install where asking is still legal, `denied` is a decision no
platform lets an app re-prompt its way out of, and only `granted` posts
anything. Collapsing the first two makes "ask again" an app's most
tempting bug. The state is cached and re-read whenever the app comes
forward, so a user who switched it off in Settings is a `.authorized`
event, not a stale screen.

The caps are contract, not configuration — checked on the Zig side
before any OS call, so each error means one thing on all six platforms:

| Cap | Value | Why this number |
| --- | --- | --- |
| id | 1–64 bytes of `[a-z0-9._-]` | secure_store's charset for secure_store's reason: the id survives verbatim as a `UNNotificationRequest` identifier, an Android tag, a toast's launch argument and a D-Bus lookup key — one namespace rule, zero escaping |
| title | 1–128 bytes | every platform truncates in display long before this; past it the payload is a document, and a document belongs behind the tap |
| body | ≤ 512 bytes | the same rule, one line down |
| route | ≤ 256 bytes | a route reference is a screen name plus identifier arguments, short by construction |

| Error | On | Meaning |
| --- | --- | --- |
| `InvalidId` | post, schedule, cancel | outside the charset or the cap — a pure function of the argument |
| `EmptyTitle` / `TitleTooLarge` / `BodyTooLarge` / `RouteTooLarge` | post, schedule | the caps above |
| `NotAuthorized` | post, schedule, requestPushToken | `status` is not `granted` |
| `FireDateInPast` | schedule | the instant has passed. Refused rather than fired immediately, because the platforms disagree — iOS rejects a non-positive interval and Android's alarm fires at once — and one meaning everywhere is worth more than a convenience that hides a clock bug |
| `Unavailable` | all | the platform posture the three probes already report |

**Three probes, because three different things can be missing.**
`available` is whether the device notifies at all (false on a Linux
session with no daemon on the bus, and in a browser without the
Notification API). `scheduleAvailable` is whether a fire date can be
handed over — false on the Linux desktop and the web, where nothing
outlives the process to fire it, and nokre will not fake it with a timer
of its own that would die with the tab. `pushAvailable` is whether there
is a push transport: false on the Linux desktop and on Windows, whose
WNS needs the packaged Store identity nokre does not emit (iap's answer,
one row over), and false on the web until you declare a VAPID key. All
three are cached at `App.init` and legal inside `build`, so an app draws
around what is missing rather than offering a switch that fails.

**Push stops where oauth stops.** The device token comes back — hex on
APNs, the FCM token on Android, a JSON subscription on the web — and you
ship it to your own backend over `http`. nokre speaks to no push
service, holds no credential, and refuses silent (`content-available`)
payloads: a push that wakes an app to run code with no UI is background
execution, a different contract with a different owner.

Linking needs identity, like `secure_store` — three platforms' worth at
once: Android names its channel after the app, Windows derives its
AppUserModelID from the id, and Apple keys the entitlement to it.

```zig
const nokre = b.dependency("nokre", .{
    // ...
    .pkg_id = @as([]const u8, "com.example.notes"),
    .notification = true,
    // Push is its own flag: local notifications derive one permission
    // and no entitlement, and an app that only reminds locally should
    // ship neither the entitlement nor the FCM declaration.
    .notification_push = true,
    .notification_push_key = @as([]const u8, "BEl62iUYgUiv…"), // web push only
});
```

**One permission is derived, and it is the first one a user will see.**
Android's `POST_NOTIFICATIONS` is *dangerous*: prompted at runtime from
API 33, refusable, and revocable in Settings afterwards. Every
permission nokre derived before it was normal and invisible, which is
why those derivations could be silent and this one is stated here, where
you read it, rather than only in the emitter. Push adds Apple's
`aps-environment` entitlement and Android's FCM `<service>`. No
exact-alarm permission is derived and none will be: `USE_EXACT_ALARM` is
policed by Play, `SCHEDULE_EXACT_ALARM` is user-revocable, and a
reminder that fires inside the OS's batching window is the right trade
for a framework that draws no clock.

**Two platform postures worth knowing before you design around them.** A
scheduled notification is lost to a reboot on Android alone — alarms do
not survive one, and re-arming them would mean nokre keeping a durable
schedule of its own, which is the thing `schedule` exists not to be. And
on Android, push means the Firebase messaging library: one Maven
coordinate and one source directory in your own `app/build.gradle`, iap's
exception restated in the open —

```groovy
android { sourceSets { main { java.srcDirs += '<nokre>/src/services/notification/java' } } }
dependencies { implementation 'com.google.firebase:firebase-messaging:24.0.0' }
```

— and without them `pushAvailable` answers false on Android and nothing
else changes.

In tests the mock is one app's fake notification centre: every post,
schedule, cancel, prompt and token request is journaled in order, and
nothing the *user* does happens until the test says so —
`grantNotifications`, `denyNotifications`, `deliverNotificationTap`,
`deliverNotification`, `deliverPushToken` ([testing.md](testing.md)).
Boot a device with no notifications, no scheduling, or no push with
`.notification = .mock(.{ .available = false })` and its siblings. The
wiring — the per-platform legs, the two recorded reversals, and why the
fire date is the OS's — is
[internals/notifications.md](internals/notifications.md).

## Not services

Zig already covers these; adding a service would be re-inventing the
toolchain:

- **FFI to native libraries** — Zig links C-ABI static libs natively.
  On web, link the library's wasm build into the app's own module.
- **Platform detection** — `builtin.os.tag`, at comptime.
- **Build-time configuration** — Zig build options.
- **Assets** — `@embedFile`.
- **Raw threads (native)** — `std.Thread`, when a thread without the
  delivery contract will do. The `worker` service adds what a bare
  thread cannot: typed messaging, in-order UI-thread delivery, the
  deterministic testing story, and the web
  ([internals/workers.md](internals/workers.md)).
- **Filesystem** — `std.fs`, native only, dev/test affordances.
- **Raw HTTP (native)** — `std.http.Client`, when a blocking call on a
  thread you already own will do. The `http` service adds what the
  bare client cannot: UI-thread delivery, the web, cancellation
  safety, and the deterministic testing story.

## Not planned

- **ML runtimes** (ONNX and friends): the app links them like any other
  native library. nokre ships no inference.
- **Payments outside the platform stores**, geolocation, camera,
  microphone, Bluetooth: no current requirement. Each would be a new
  roster row with this same shape, argued for on its own. Push
  notifications used to head this list; the row it became, and the
  record of the reversal, are above and in
  [internals/notifications.md](internals/notifications.md).
