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

`haptic` is on this list for completeness, not for use: it is a
`Services` field because everything platform-flavored is injected and
observable in tests, and it has no consumer verb at all. "Buzz when I say
so" is a feedback hook in the same family as a styling hook. The roster
grows the way the element set does — a row is argued on semantics, and
`open_url` earned its place when the `document` element's motivating
content (fetched legal text, with its `mailto:` and third-party
references) made "no external URLs" a refusal stricter than its
rationale — never as a grab-bag of platform bindings.

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
Windows, a ~139 KiB static table on wasm), and a store is meaningless
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
| value | ≤ 2048 bytes | the largest power of two under the Windows credential blob limit (`CRED_MAX_CREDENTIAL_BLOB_SIZE`, 2560) — the tightest native bound, enforced on the Zig side everywhere, so `ValueTooLarge` means one thing on every platform |
| entries | 64 per app | a pouch, not a database — small enough that every buffer is a stack array and browser quota is unreachable by construction |

A value that doesn't fit is a document, and documents are refused.
Store the refresh token or the session id, not the fat JWT: a JWT
balloons with its claims and expires anyway, while the small
credential you re-derive everything else from is exactly what belongs
in a keychain.

Errors are closed and per-operation — `get` can never return
`ValueTooLarge`; each signature states exactly what can go wrong:

| Error | On | Producible |
| --- | --- | --- |
| `InvalidKey` | get, set, delete | everywhere, identically — a pure function of the argument, checked before any OS call |
| `ValueTooLarge` | set | everywhere, identically — the cap is the service's, checked on the Zig side |
| `StoreFull` | set | everywhere, identically — the 65th *distinct* key; overwriting an existing key never fails with it |
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
stated posture, not a bug.

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

The wiring — the Keychain/CredMan mappings, the web snapshot/mirror
flow, and why each refusal holds — is
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
manifest, and the app icon in each platform's format — so no file can
become a second source of truth or need hand-writing; generated ones
stay gitignored. The icon is derived too: a deterministic grayscale
mark computed from the id
([src/packaging/icon.zig](../src/packaging/icon.zig)) — the
no-custom-visual-identity refusal ([introduction.md](introduction.md))
applied to the home screen. The same id draws the same mark everywhere,
forever; renaming the display name keeps it.

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

Like `http` — and unlike `package_info` — nothing links: the service is
always available, and an app that spawns no worker pays nothing.
Request/response, progress streams, and long-lived stateful sessions are
all the same three verbs. The wiring — the per-platform transports, the
wire codec, why there is one artifact per thread, and the refusals (no
shared memory, no futures, no thread pool, no forced kill) — is
[internals/workers.md](internals/workers.md).

### http: the network as a message

One API on every platform; behind it the shells wire what they have —
native blocks one visible thread per request on `std.http.Client`, the
web hands the job to the browser's `fetch`, tests park the request
until the test answers it — and the consumer contract never changes:
no futures, no locks, no callback off the UI thread. Requests and
worker messages share one delivery lane, so ordering, thread
discipline, and the testing story are the same fact, not three
parallel ones.

```zig
_ = try nokre.services.http.request(.{
    .app = app,
    .url = "https://api.example.com/notes",
    .ctx = state,
    .on_result = onNotes,
});

fn onNotes(ctx: ?*anyopaque, result: nokre.services.http.Result) void {
    const state: *State = @ptrCast(@alignCast(ctx.?));
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
PUT, PATCH, DELETE — and there is no streaming, no timeout knob, and
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
proves ownership.

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
state.locale = L.resolve(dev);                // the template if none match
app.setDirection(L.dir(state.locale));        // mirror the chrome to it

// Optional, and also inside build: the user switching languages
// mid-session. Registering again replaces, so a rebuild that
// re-registers the same handler is a no-op.
nokre.services.locale.setHandler(app, state, onLocale);

fn onLocale(ctx: ?*anyopaque, tag: []const u8) void {
    const state: *State = @ptrCast(@alignCast(ctx.?));
    state.locale = L.resolve(tag);
    state.app.setDirection(L.dir(state.locale));
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
draws Apple's conforming sign-in button, mark and mandated wording
included, in the palette it already had — see
[elements.md](elements.md#button). Google's is not offered and will not
be: its guidelines require a multicolour mark, drawing one compliantly
means colour in the frame, and grayscale is a guarantee rather than a
default. The full argument is in
[internals/oauth.md](internals/oauth.md).

In tests the mock is one app's fake browser: `start` parks and journals
what the app actually built — so "the app requested the wrong scopes"
and "the app never sent a PKCE challenge" are assertions — and nothing
moves until the test says what the user did (`completeAuth`,
`cancelAuth`, `failAuth`; [testing.md](testing.md)).

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
`error.PurchaseInFlight` (the sheet is modal, and a person can only be
buying one thing at once — `oauth`'s argument), a second query is
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

An app that links no `iap` adds neither. On Play the transaction id *is*
the purchase token: `getOrderId()` is absent for pending and test
purchases, and Google's Developer API is keyed by token, so one honest
value beats a nullable one that vanishes exactly when a purchase is most
interesting.

Where the service stops is `oauth`'s line. No receipt verification — the
`token` goes to the app's backend, which calls the App Store Server API or
the Play Developer API; verifying on the device is verifying with the
attacker's copy of the key. No entitlement or expiry model — `isActive`,
renewal windows, and grace periods need a clock, and a timer is a ticker,
which nokre has none of; `restore` reports what the store says is owned
right now, with no dates and no arithmetic. No catalog, no price cache, no
paywall layout, no route table.

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
- **Payments outside the platform stores**, push notifications,
  geolocation, camera, microphone, Bluetooth: no current requirement.
  Each would be a new roster row with this same shape, argued for on its
  own.
