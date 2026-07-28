# Getting started

This is a course, not a tour. Over fourteen short parts you build one
app — **Notes**: sign-in gated by the secure store, a notes list, a
new-note sheet, sync over http, a background worker, settings, a second
language — and you test every part as you go, ending with an inline
tree snapshot, a step trace, and a byte-exact golden screenshot. The last part builds the same
code for macOS, Windows, Linux, iOS, Android, and the web. Finish it and you
have used the core of nokre's consumer surface; each part links the
document that owns the full contract, and the last part points at what
the course deliberately skipped.

Read [introduction.md](introduction.md) first if you haven't — nokre
makes more sense once you know what it refuses to do.

**Prerequisites:** Zig 0.16. A windowed app runs on all five shells
today — macOS, Windows, Linux, iOS and Android — and in a browser,
which has no shell because it is one. Everything headless
in this course — the
core model and the whole testing framework — is pure Zig and runs
anywhere.

**The course, part by part** — each one adds a feature and its test:

- [Part 0 — See it run](#part-0--see-it-run)
- [Part 1 — A project of your own](#part-1--a-project-of-your-own)
- [Part 2 — Your first test](#part-2--your-first-test)
- [Part 3 — Screens and navigation](#part-3--screens-and-navigation)
- [Part 4 — The sign-in screen](#part-4--the-sign-in-screen)
- [Part 5 — Remembering the session (secure_store)](#part-5--remembering-the-session-secure_store)
- [Part 6 — The list, the sheet, and a status line](#part-6--the-list-the-sheet-and-a-status-line)
- [Part 7 — Sync (http)](#part-7--sync-http)
- [Part 8 — Heavy work (workers)](#part-8--heavy-work-workers)
- [Part 9 — The note screen: copyable, qr, delete](#part-9--the-note-screen-copyable-qr-delete)
- [Part 10 — Settings: segmented, radio_group, toggle, package_info](#part-10--settings-segmented-radio_group-toggle-package_info)
- [Part 11 — A second language (l10n)](#part-11--a-second-language-l10n)
- [Part 12 — Proof: tree snapshots, step traces, goldens](#part-12--proof-tree-snapshots-step-traces-goldens)
- [Part 13 — Every platform](#part-13--every-platform)
- [Part 14 — Where you are now](#part-14--where-you-are-now)
- [Command reference](#command-reference)

## Part 0 — See it run

```sh
git clone https://github.com/getnokre/nokre
cd nokre
zig build test            # pure unit tests — no dependencies, any machine
tools/fetch-deps.sh       # fetch prebuilt Skia + AccessKit (once)
zig build run-hello -Dskia
zig build run-kitchen-sink -Dskia
```

`hello` is the smallest complete app
([examples/hello](../examples/hello)); `kitchen-sink` shows every
element on two screens and is the visual reference this course points at
whenever it skips one. Explore with the keyboard first: Tab, arrows,
Enter, Esc — everything reachable by pointer is reachable that way too,
and with VoiceOver running, everything is announced.

The same kitchen sink runs in a browser, and that is one command with
no toolchain behind it:

```sh
zig build web
python3 -m http.server 8000 -d zig-out/web
```

Then open <http://localhost:8000> — it has to be served over http,
since neither a wasm module nor an ES module loads from a `file://`
URL. What runs there is the **DOM edition**: the same tree, written as
markup and drawn by the browser, in one 200 KB wasm module with no
Skia in it ([internals/dom-edition.md](internals/dom-edition.md)). It
is the one platform whose pixels are not nokre's, and the one whose
accessibility tree *is* the page rather than a copy of it. Part 13 does
this for your own app.

Three platform notes before your own project starts:

- **macOS:** a bare `zig build run-…` binary is ad-hoc-signed, so an app
  using the `secure_store` service may see a keychain authorization
  prompt after a rebuild — dev-only posture, not contract; the why and
  the ways out are in [services.md](services.md).
- **Windows:** the same commands work from Git Bash (for the shell
  scripts) or any shell. `-Dskia` builds need Visual Studio's C++ Build
  Tools — the Skia prebuilt is MSVC-ABI, and build.zig targets
  `x86_64-windows-msvc` automatically. Text rasterizes through FreeType,
  so pixels match the Linux and Android builds rather than macOS/iOS
  ([internals/skia-build.md](internals/skia-build.md)); the golden suite
  reflects CoreText until nokre-owned builds land. Narrator, NVDA, and
  JAWS are wired via the same AccessKit binding as VoiceOver.
- **Linux:** the shell is Wayland, and the build wants the usual dev
  packages beside it: `wayland-protocols` plus the `wayland-client`,
  `libxkbcommon`, `dbus-1`, and `libsecret-1` headers. FreeType again,
  so the Windows golden note applies here too; Orca is wired via
  AccessKit over AT-SPI.

## Part 1 — A project of your own

Make a sibling directory next to the nokre checkout (the path
dependency below assumes `../nokre`; the prebuilts you fetched live
inside that checkout, which is why a side-by-side clone is the easy
route):

```sh
mkdir notes && cd notes
mkdir -p src
```

`build.zig.zon` — on the first `zig build`, Zig rejects a missing or
stale `.fingerprint` and prints the value to paste:

```zig
.{
    .name = .notes,
    .version = "0.1.0",
    .fingerprint = 0x0, // first `zig build` prints the real value
    .minimum_zig_version = "0.16.0",
    .dependencies = .{
        .nokre = .{ .path = "../nokre" },
    },
    .paths = .{ "build.zig", "build.zig.zon", "src", "tests" },
}
```

`build.zig` — nokre's build.zig is importable by package name, and
`addApp` assembles the right artifact for whatever target you pass: the
windowed executable on macOS and Windows, the static libraries an
Xcode or Gradle consumes on iOS and Android:

```zig
const std = @import("std");
const nokre = @import("nokre"); // the dependency's build.zig

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const app = nokre.addApp(b.dependency("nokre", .{}), .{
        .name = "notes",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        // Identity links package_info and makes `app.pkg` exist —
        // manifests and the app icon are outputs of this declaration
        // (docs/services.md).
        .pkg = .{ .name = "Notes", .id = "com.example.notes", .version = "0.1.0", .build = 1 },
        // The store's namespace is the id above; Part 5 uses it.
        .secure_store = true,
        // The domains the OS should route into the app; the entitlement
        // and assetlinks are derived from them. Part 3 routes the URL.
        .deep_link_domains = &.{"notes.example.com"},
    });
    b.installArtifact(app.artifact);
    if (app.shim) |shim| b.installArtifact(shim); // iOS: Xcode links both
    if (app.pkg) |pkg| b.installDirectory(.{ .source_dir = pkg, .install_dir = .prefix, .install_subdir = "pkg" });

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&b.addRunArtifact(app.artifact).step);
}
```

`src/main.zig` — the smallest complete program, and already the shape
every later part grows: state you own, builder functions that project
state into the element tree, and actions that change state:

```zig
//! The smallest complete nokre app: one screen, one action.
const std = @import("std");
const h = @import("nokre");

pub const State = struct {
    count: u32 = 0,
    app: *h.App = undefined,
    label_id: h.NodeId = .invalid,
};

fn onIncrement(ctx: ?*anyopaque) void {
    const state: *State = @ptrCast(@alignCast(ctx.?));
    state.count += 1;
    var buf: [32]u8 = undefined;
    const label = std.fmt.bufPrint(&buf, "Pressed {d} times", .{state.count}) catch return;
    state.app.tree.setContent(state.label_id, label) catch return;
    state.app.invalidate();
}

pub fn buildHome(ctx: ?*anyopaque, app: *h.App) !void {
    const state: *State = @ptrCast(@alignCast(ctx.?));
    const root = app.tree.rootId();
    _ = try app.tree.append(root, .{ .heading = .{ .content = "Notes", .level = .h1 } });
    state.label_id = try app.tree.append(root, .{ .text = .{ .content = "Pressed 0 times" } });
    _ = try app.tree.append(root, .{ .button = .{
        .label = "Increment",
        .on_press = .{ .ctx = state, .call = onIncrement },
    } });
}

pub fn main() !void {
    var gpa_state: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();

    var state = State{};
    var app = try h.App.init(gpa, .{
        .viewport = .{ .w = 480, .h = 640 },
        .routes = &.{.{ .name = "home", .title = "Home", .build = buildHome }},
        .ctx = &state,
    });
    defer app.deinit();
    state.app = &app;
    try app.navigate("home");

    try h.platform.run(&app, .{ .title = "Notes" });
}
```

**Checkpoint:** `zig build run` opens a window titled Notes. Tab reaches
the button, Enter presses it, the label counts. (`State` and `buildHome`
are `pub` because Part 2's tests import them.)

Things worth noticing, because they generalize:

- **`append` is where correctness happens.** A button with an empty
  label, a table row outside a table, text without enough contrast where
  it sits — all rejected at the call site with a named error. If the
  tree built, the screen is valid; an automatic audit covers what
  construction can't see. The rules are in
  [accessibility.md](accessibility.md).
- **Actions are context + function pointer.** `.{ .ctx = state, .call =
  onIncrement }` — nokre never allocates a closure. Every interactive
  element takes its action the same way (`on_press`, `on_toggle`,
  `on_change`, `on_select`).
- **You mutate, then `invalidate()`.** Nothing renders until state
  changes and you say so; an app at rest costs zero CPU. Mutate the tree
  in place (as here, `setContent`) or rebuild a whole screen — Part 3
  adds that second style.
- **Focus, keyboard access, and the a11y tree came for free.** None of
  that was written above, and none of it can be forgotten.

One aside for the other kind of consumer: headless use — the core model
and the testing framework, no window — needs none of `addApp`; nokre is
then an ordinary Zig dependency
(`mod.addImport("nokre", b.dependency("nokre", .{ .target = target, .optimize = optimize }).module("nokre"))`),
and the `pkg_*` / `secure_store` / `deep_link` build options replace the
`addApp` fields ([services.md](services.md)). Everything in this course except
`zig build run` and Part 13 works identically there.

## Part 2 — Your first test

The harness drives the same `App` your `main` does — headless, no
Skia, no window. The framework is asymmetric on purpose: interactions go
through the *user's* pipeline (real hit-testing, real dispatch), and
assertions read the *screen reader's* snapshot — so a test can only pass
if an assistive-tech user could do the same thing. The a11y audit runs
at init and again after every action.

Add the test wiring to `build.zig` — `app.nokre` is the same configured
nokre instance the app links, so tests exercise identical code:

```zig
    const tests_mod = b.createModule(.{
        .root_source_file = b.path("src/main_test.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "nokre", .module = app.nokre }},
    });
    const tests = b.addTest(.{ .root_module = tests_mod });
    const test_step = b.step("test", "Run headless e2e tests");
    test_step.dependOn(&b.addRunArtifact(tests).step);
```

`src/main_test.zig`:

```zig
const std = @import("std");
const nok = @import("nokre");
const app = @import("main.zig");

test "pressing Increment updates the label" {
    var state: app.State = .{};
    var t = try nok.testing.Harness.init(std.testing.allocator, .{ .w = 480, .h = 640 }, &state, app.buildHome);
    defer t.deinit();
    state.app = &t.app;
    // The a11y audit already ran, and re-runs after every action below.

    try t.tapLabel("Increment"); // real hit-test, real dispatch
    _ = try t.getByLabel("Pressed 1 times"); // asserted via the a11y snapshot
}
```

**Checkpoint:** `zig build test` passes in milliseconds, on any machine,
with no native dependencies.

Two habits to form now. First, `state.app = &t.app` comes *after* the
harness is in its final variable — actions dereference that pointer, and
a harness returned from a helper function has moved. Second, trust the
diagnostics: a failed `getByLabel` prints every labeled node on screen,
so a typo diagnoses itself, and `tap` refuses actions a user couldn't
perform (`NotVisible`, `Obscured`, `NotInteractive`) rather than
silently landing elsewhere. The full query and driver surface is
[testing.md](testing.md).

## Part 3 — Screens and navigation

Notes has two sections and one pushed screen. Screens are named routes,
each a builder; navigation is a stack. Replace the single-route setup:

```zig
pub const routes = [_]h.RouteDef{
    .{ .name = "notes", .title = "Notes", .build = buildNotes },
    .{ .name = "note", .title = "Note", .args = 1, .build = buildNote }, // pushed detail — Part 9
    .{ .name = "settings", .title = "Settings", .build = buildSettings }, // Part 10
};

pub const nav_items = [_]h.Destination{
    .{ .route = "notes", .icon = .notebook_pen },
    .{ .route = "settings", .icon = .settings },
};
```

and in `main`:

```zig
    var app = try h.App.init(gpa, .{
        .viewport = .{ .w = 480, .h = 640 },
        .routes = &routes,
        .ctx = &state,
    });
    defer app.deinit();
    state.app = &app;
    try app.setNav(&nav_items);
    try app.navigate("notes");
```

(Rename `buildHome` to `buildNotes`, and stub `buildNote` /
`buildSettings` with a lone `h1` heading each for now.) The rules, all
framework-enforced:

- `setNav` installs the app-level nav, called once before the first
  `navigate`. Activating an item pushes that destination, so Back
  returns to the section you crossed from (and the one you are already
  on does nothing). Everything else about the bar — its placement, its
  shape, why a destination is a route and a required `icon` with no
  label, when the row collapses to a chip — is the framework's
  contract, not the app's:
  [elements.md](elements.md#navigation-chrome) specifies it once.
- Every route carries a `title`, and the field has no default — omitting
  it will not compile. It is what chrome calls that screen — the nav
  labels its destinations from it, and it also covers the screens that
  are *not* destinations. The title is declared, never derived — your
  builder's `h1` is content and may say something else entirely.
- `app.navigate("note~42")` pushes a screen, and a pushed screen
  automatically gets a Back control (accessible name "Back") — you
  cannot build a screen with no way back. `link` elements and
  route-carrying `tile`s navigate the same way declaratively.
- Entering a route runs its builder against a fresh subtree — no
  diffing, no animation to wait out, which is also why tests never
  sleep. Besides push/pop there are `app.router.replace` (a different
  screen at the same depth), `app.router.switchTo` (reset the stack to
  this one screen, with nothing behind it) and `app.router.reload` (this
  screen again).
- The rebuild is from scratch, but the *viewport* is not: popping back
  (and reloading) returns a screen to where it was scrolled, so a list
  you were halfway down comes back halfway down. On iOS a drag in from
  the leading screen edge goes back too — nothing slides, a haptic knock
  marks the threshold ([routing.md](routing.md#the-back-gesture)).
- A screen that is about *something* says so in the route:
  `app.navigate("note~42")`, read back inside the builder as
  `app.routeArg(0)`. The argument belongs to the stack entry, so two
  notes pushed in turn stay two notes when you pop. The route declared
  `.args = 1`, so a bare `note` is refused rather than built blank.
- On the web the URL fragment is that reference — `#notes`, `#note~42` —
  mirrored both ways with nothing to wire: navigating writes it, and a
  typed or shared one puts the app there. See [routing.md](routing.md).

`reload` is how a whole screen reacts to changed state, and the app
uses it enough to deserve a helper — the rebuild counterpart of Part 1's
`setContent`:

```zig
/// Rebuild the current screen from state. Focus resets to the top, so
/// reach for this on committed changes, not keystrokes.
fn refresh(state: *State) void {
    state.app.router.reload(state.app) catch {};
}
```

**Checkpoint:** `zig build run` — the nav sits at the bottom, taps and
arrow keys switch sections, and the current section reads as a filled
chip.

### Opening from a link (deep_link)

Navigation also arrives from outside: a Universal Link tapped in Mail, an
App Link from another app, a `#` fragment on the web. That is the
`deep_link` service — Part 1's build.zig claimed the domains, which is
what links it. It hands you the inbound URL and stops there, because
*where* the URL goes is the router's job, which you already own.

One handler, wired in `main` once the app exists:

```zig
    state.app = &app;
    h.services.deep_link.setHandler(&app, &state, onDeepLink);
    try app.setNav(&nav_items);
    try app.navigate("notes");
```

```zig
/// The launch URL — if a link opened the app — is the first call, then
/// every link that arrives while running. Route on it; that is all
/// deep_link asks. The fragment is the web deep link and a fine
/// cross-platform key: "https://notes.example.com/#settings" opens
/// Settings.
pub fn onDeepLink(ctx: ?*anyopaque, url: []const u8) void {
    const state: *State = @ptrCast(@alignCast(ctx.?));
    const target = h.services.deep_link.fragment(url) orelse "notes";
    state.app.navigate(target) catch {}; // an unknown route is a no-op, never a crash
}
```

The test injects a link the way a shell would and asserts through the
same a11y snapshot as any tap — `deliverDeepLink` is the launch URL as
the first call, then any runtime link:

```zig
test "a link routes the app to a section" {
    var state = app.State{};
    var t = try nok.testing.Harness.initWithNav(
        std.testing.allocator, .{ .w = 480, .h = 640 },
        &app.routes, &app.nav_items, &state, "notes",
    );
    defer t.deinit();
    state.app = &t.app;
    nok.services.deep_link.setHandler(&t.app, &state, app.onDeepLink);

    try t.deliverDeepLink("https://notes.example.com/#settings");
    try t.expectRoute("settings");
}
```

Linking the service also grew the packaging tree with what the OS needs
to trust the app for those domains: the iOS associated-domains
entitlement, the Android App-Links `intent-filter`, and the two
`/.well-known/` files you host on each domain — all derived from the
declaration, the two signing-time values (Apple Team ID, Android cert
SHA-256) left as loud `REPLACE_…` placeholders, never fabricated
([services.md](services.md)). Part 13 hosts them; routing a link to a
specific note, rather than a section, is the same handler once Part 9's
list exists.

## Part 4 — The sign-in screen

The notes section starts gated. This part is pure element vocabulary —
a `box` to group the form, inline `spans`, an obscured `text_input`, a
`checkbox`, a `button` — every element's full contract is in
[elements.md](elements.md).

```zig
pub const State = struct {
    app: *h.App = undefined,
    signed_in: bool = false,
    remember: bool = true,
    passphrase: [64]u8 = undefined,
    passphrase_len: usize = 0,
    signin_status: []const u8 = "",
    // …the earlier fields stay; later parts add more.
};

fn buildSignIn(state: *State, app: *h.App) !void {
    const root = app.tree.rootId();
    _ = try app.tree.append(root, .{ .heading = .{ .content = "Notes", .level = .h1 } });
    _ = try app.tree.append(root, .{ .text = .{ .spans = &.{
        .{ .text = "Welcome. The passphrase is " },
        .{ .text = "letmein", .code = true },
        .{ .text = " — this is a course app, not a bank." },
    } } });
    const form = try app.tree.append(root, .{ .box = .{} });
    _ = try app.tree.append(form, .{ .text_input = .{
        .label = "Passphrase",
        .obscured = true,
        .on_change = .{ .ctx = state, .call = onPassphraseChange },
        .on_submit = .{ .ctx = state, .call = onSignIn },
    } });
    _ = try app.tree.append(form, .{ .checkbox = .{
        .label = "Stay signed in on this device",
        .checked = state.remember,
        .on_toggle = .{ .ctx = state, .call = onRememberToggle },
    } });
    _ = try app.tree.append(form, .{ .button = .{
        .label = "Sign in",
        .on_press = .{ .ctx = state, .call = onSignIn },
    } });
    if (state.signin_status.len != 0) {
        _ = try app.tree.append(root, .{ .text = .{ .content = state.signin_status, .style = .{ .scale = .small, .ink = .dark } } });
    }
}

pub fn buildNotes(ctx: ?*anyopaque, app: *h.App) !void {
    const state: *State = @ptrCast(@alignCast(ctx.?));
    if (!state.signed_in) return buildSignIn(state, app);
    // …the signed-in screen, from Part 6 on.
}

fn onPassphraseChange(ctx: ?*anyopaque, value: []const u8) void {
    const state: *State = @ptrCast(@alignCast(ctx.?));
    state.passphrase_len = @min(value.len, state.passphrase.len);
    @memcpy(state.passphrase[0..state.passphrase_len], value[0..state.passphrase_len]);
}

fn onRememberToggle(ctx: ?*anyopaque, checked: bool) void {
    const state: *State = @ptrCast(@alignCast(ctx.?));
    state.remember = checked;
}

fn onSignIn(ctx: ?*anyopaque) void {
    const state: *State = @ptrCast(@alignCast(ctx.?));
    if (!std.mem.eql(u8, state.passphrase[0..state.passphrase_len], "letmein")) {
        state.signin_status = "Wrong passphrase. (Hint: it's the one on screen.)";
        refresh(state);
        return;
    }
    state.signed_in = true;
    state.signin_status = "";
    state.passphrase_len = 0;
    refresh(state);
}
```

Three element choices carry design weight. `obscured` makes the input a
secure field: bullets on screen, value withheld from assistive tech
*and from test traces*. The `checkbox` is deliberately not a `toggle`:
checking it commits nothing by itself — the Sign in button gathers it
(consent-then-submit); a switch that applies immediately would be a
`toggle`, as Part 10 shows. And spans are Markdown's inline vocabulary,
not styling: assistive tech hears one plain text node.

The test drives it exactly like a user, keyboard-only:

```zig
test "wrong passphrase stays signed out" {
    var state: app.State = .{};
    var t = try nok.testing.Harness.initWithNav(std.testing.allocator, .{ .w = 480, .h = 640 }, &app.routes, &app.nav_items, &state, "notes");
    defer t.deinit();
    state.app = &t.app;

    try t.focusVia(try t.getByLabel("Passphrase")); // Tab-cycles like a real user
    try t.typeText("password1");
    try t.pressKey(.enter, .{});

    _ = try t.getByLabelContaining("Wrong passphrase");
}
```

`focusVia` fails with `error.NotKeyboardReachable` if Tab can't reach
the node — a test that passes only with a mouse is a bug.

## Part 5 — Remembering the session (secure_store)

`.secure_store = true` in Part 1's build.zig linked the store, and the
declared id is its namespace. It is a pouch, not a database — four
synchronous calls (`get`, `set`, `delete`, `list`), caller buffers, hard
caps — and synchronous is the point: the boot read is one call *inside
build*, deciding the first screen with no loading frame. Contract and
caps: [services.md](services.md).

Gate the notes section on the stored token — the top of `buildNotes`
becomes:

```zig
    // The boot read is synchronous — the stored session decides which
    // screen this is.
    if (!state.signed_in) {
        var buf: h.services.secure_store.ValueBuf = undefined;
        if (h.services.secure_store.get(app, "auth.token", &buf) catch null) |_| {
            state.signed_in = true;
        }
    }
    if (!state.signed_in) return buildSignIn(state, app);
```

Persist on sign-in (inside `onSignIn`, after the passphrase check) —
and note the degrade: a locked keychain must not gate the session:

```zig
    if (state.remember) {
        // `status` is the signed-in screen's status line — Part 6
        // renders it.
        h.services.secure_store.set(state.app, "auth.token", "tk_demo") catch {
            state.status = "Signed in — couldn't save your session.";
        };
    }
```

And sign out, wired to a Settings button in Part 10:

```zig
fn onSignOut(ctx: ?*anyopaque) void {
    const state: *State = @ptrCast(@alignCast(ctx.?));
    // Idempotent: signing out when nothing was stored is still success.
    h.services.secure_store.delete(state.app, "auth.token") catch {};
    state.signed_in = false;
    state.status = "Ready.";
    state.app.router.switchTo(state.app, "notes") catch {};
}
```

Under `zig test` the real keychain structurally cannot be reached: every
app is constructed with a journaling fake, and the harness seeds it at
boot, asserts against it, and injects the one environmental error.
These four tests are the store's whole story:

```zig
const gpa = std.testing.allocator;
const viewport: nok.Size = .{ .w = 480, .h = 640 };

/// Most tests want a returning user: seed the token the keychain would
/// hold. (Callers set `state.app = &t.app` once the harness has landed
/// in its final variable.)
fn signedIn(state: *app.State) !nok.testing.Harness {
    return nok.testing.Harness.initWith(gpa, viewport, .{
        .routes = &app.routes,
        .nav = &app.nav_items,
        .ctx = state,
        .initial_route = "notes",
        .store = .{ .seeds = &.{.{ .key = "auth.token", .value = "tk_demo" }} },
    });
}

test "a fresh install boots to sign-in; the stored token skips it" {
    var state: app.State = .{};
    var t = try nok.testing.Harness.initWithNav(gpa, viewport, &app.routes, &app.nav_items, &state, "notes");
    defer t.deinit();
    state.app = &t.app;
    _ = try t.getByLabel("Passphrase");
    try t.expectAbsent("New note");

    var returning: app.State = .{};
    var t2 = try signedIn(&returning);
    defer t2.deinit();
    returning.app = &t2.app;
    _ = try t2.getByLabel("New note"); // boot read is sync: no loading frame
    try t2.expectAbsent("Passphrase");
}

test "signing in stores the session; signing out deletes it and nothing else" {
    var state: app.State = .{};
    var t = try nok.testing.Harness.initWithNav(gpa, viewport, &app.routes, &app.nav_items, &state, "notes");
    defer t.deinit();
    state.app = &t.app;

    try t.focusVia(try t.getByLabel("Passphrase"));
    try t.typeText("letmein");
    try t.pressKey(.enter, .{});
    try t.expectStored("auth.token", "tk_demo");

    try t.tapLabel("Settings"); // the nav is real chrome — tap it
    try t.tapLabel("Sign out");
    try t.expectRoute("notes");
    try t.expectStoredAbsent("auth.token");
    // Boot get, sign-in set, sign-out delete, and the signed-out
    // screen's fresh boot get — the app never rewrote the secret.
    try std.testing.expectEqual(@as(usize, 4), t.store.journal().len);
}

test "unchecking 'stay signed in' keeps the keychain empty" {
    var state: app.State = .{};
    var t = try nok.testing.Harness.initWithNav(gpa, viewport, &app.routes, &app.nav_items, &state, "notes");
    defer t.deinit();
    state.app = &t.app;

    try t.tapLabel("Stay signed in on this device"); // uncheck: consent withdrawn
    try t.expectChecked("Stay signed in on this device", false);
    try t.focusVia(try t.getByLabel("Passphrase"));
    try t.typeText("letmein");
    try t.pressKey(.enter, .{});

    _ = try t.getByLabel("New note"); // signed in for this run…
    try t.expectStoredAbsent("auth.token"); // …but nothing persisted
}

test "a locked keychain degrades to signed-in-for-now" {
    var state: app.State = .{};
    var t = try nok.testing.Harness.initWithNav(gpa, viewport, &app.routes, &app.nav_items, &state, "notes");
    defer t.deinit();
    state.app = &t.app;

    try t.setStoreAvailable(false); // only Unavailable is injectable —
    try t.focusVia(try t.getByLabel("Passphrase")); // the other errors
    try t.typeText("letmein"); // occur organically, by argument
    try t.pressKey(.enter, .{});

    _ = try t.getByLabelContaining("couldn't save your session");
    _ = try t.getByLabel("New note"); // the session still works
    try t.expectStoredAbsent("auth.token");
}
```

That last test is table stakes, not an edge case: a locked keychain, an
absent Secret Service session on Linux, or a Keystore fault on Android
all surface as `Unavailable`, so an app that degrades gracefully is
ready everywhere. The journal assertion is the
habit to keep — it proves *behavior* ("never rewrote the secret"), not
just final state. The full store-testing surface: [testing.md](testing.md).

## Part 6 — The list, the sheet, and a status line

The signed-in screen: a `badge` when offline (Part 7 sets it), a status
line, the list as a `tile_group`, a capacity `meter`, and a "New note"
button that opens the one modal surface. New declarations:

```zig
const max_notes = 16;
const max_note_len = 120;

pub const Note = struct {
    text: [max_note_len]u8 = undefined,
    len: usize = 0,

    pub fn slice(self: *const Note) []const u8 {
        return self.text[0..self.len];
    }
};

/// ctx for per-row actions: which note a tile press means. Builders
/// fill one ref per visible row; the action reads it back.
pub const NoteRef = struct { state: *State, index: usize };

fn addNote(state: *State, text: []const u8) void {
    if (state.note_count == max_notes) return; // full — the meter says so
    const note = &state.notes[state.note_count];
    note.len = @min(text.len, max_note_len);
    @memcpy(note.text[0..note.len], text[0..note.len]);
    state.note_count += 1;
}
```

and the new `State` fields:

```zig
    notes: [max_notes]Note = @splat(.{}),
    note_count: usize = 0,
    refs: [max_notes]NoteRef = undefined,
    newest_first: bool = true,
    status: []const u8 = "Ready.",
    offline: bool = false,
    draft: [max_note_len]u8 = undefined,
    draft_len: usize = 0,
```

The signed-in half of `buildNotes`:

```zig
    const root = app.tree.rootId();
    const title_row = try app.tree.append(root, .{ .stack = .{ .axis = .horizontal } });
    _ = try app.tree.append(title_row, .{ .heading = .{ .content = "Notes", .level = .h1 } });
    if (state.offline) {
        _ = try app.tree.append(title_row, .{ .badge = .{ .label = "Offline" } });
    }

    const actions = try app.tree.append(root, .{ .stack = .{ .axis = .horizontal } });
    _ = try app.tree.append(actions, .{ .button = .{
        .label = "New note",
        .on_press = .{ .ctx = state, .call = onOpenNewNote },
    } });
    _ = try app.tree.append(actions, .{ .button = .{
        .label = "Sync", // Part 7
        .secondary = true,
        .on_press = .{ .ctx = state, .call = onSyncPressed },
    } });
    _ = try app.tree.append(root, .{ .text = .{ .content = state.status, .style = .{ .scale = .small, .ink = .dark } } });

    if (state.note_count == 0) {
        _ = try app.tree.append(root, .{ .text = .{ .content = "Nothing here yet. Press “New note” to write the first one." } });
    } else {
        const group = try app.tree.append(root, .{ .tile_group = .{
            .description = "Tap a note to read, share, or delete it.",
        } });
        for (0..state.note_count) |i| {
            const index = if (state.newest_first) state.note_count - 1 - i else i;
            state.refs[index] = .{ .state = state, .index = index };
            _ = try app.tree.append(group, .{ .tile = .{
                .label = state.notes[index].slice(),
                .on_press = .{ .ctx = &state.refs[index], .call = onOpenNote },
            } });
        }
    }

    _ = try app.tree.append(root, .{ .divider = .{} });
    var cap_buf: [32]u8 = undefined;
    const cap = try std.fmt.bufPrint(&cap_buf, "{d} of {d} notes", .{ state.note_count, max_notes });
    _ = try app.tree.append(root, .{ .meter = .{ .label = cap, .value = @intCast(state.note_count), .max = max_notes } });
```

Notice the meter label was formatted into a stack buffer — safe, because
the tree copies every string at `append`; it never borrows your memory.
And notice what's absent: the screen may outgrow the viewport, and
nothing wraps it — content taller than the window scrolls implicitly,
and Tab always scrolls the focused element into view. Reach for an
explicit `scroll_region` only to pin a viewport *within* a screen
([elements.md](elements.md), which also covers `select`, `table`, and
the rest this app doesn't need).

The sheet is created through the app, never appended by a builder, and
its lifecycle is framework-owned — close control pinned, focus moved in,
everything behind inert, Esc/scrim dismissal, focus returned:

```zig
fn onOpenNewNote(ctx: ?*anyopaque) void {
    const state: *State = @ptrCast(@alignCast(ctx.?));
    const app = state.app;
    state.draft_len = 0;
    const sheet = app.presentSheet("New note") catch return;
    _ = app.tree.append(sheet, .{ .text_area = .{
        .label = "Note",
        .placeholder = "Write it down…",
        .on_change = .{ .ctx = state, .call = onDraftChange },
    } }) catch return;
    _ = app.tree.append(sheet, .{ .button = .{
        .label = "Add",
        .on_press = .{ .ctx = state, .call = onAddNote },
    } }) catch return;
}

fn onAddNote(ctx: ?*anyopaque) void {
    const state: *State = @ptrCast(@alignCast(ctx.?));
    state.app.dismissSheet();
    if (state.draft_len != 0) {
        addNote(state, state.draft[0..state.draft_len]);
        state.status = "Note added.";
    }
    refresh(state);
}
```

(`onDraftChange` copies like `onPassphraseChange`. A `text_area`
because Enter must insert a newline; submission belongs to the explicit
button beside it.)

The tests assert the choreography the framework guarantees — and drive
an IME through the same pipeline a platform shell would:

```zig
test "the new-note sheet: focus moves in, Esc backs out, Add commits" {
    var state: app.State = .{};
    var t = try signedIn(&state);
    defer t.deinit();
    state.app = &t.app;

    try t.tapLabel("New note");
    try t.expectFocused("Close"); // the framework pinned it and moved focus

    try t.pressKey(.escape, .{});
    try t.expectAbsent("Add"); // the sheet is gone…
    try t.expectFocused("New note"); // …and focus returned to the opener

    try t.tapLabel("New note");
    try t.focusVia(try t.getByLabel("Note"));
    try t.typeText("Buy oat milk");
    try t.expectValue("Note", "Buy oat milk");
    try t.tapLabel("Add");

    try t.expectAbsent("Add");
    _ = try t.getByLabel("Buy oat milk"); // the tile is on screen
    _ = try t.getByLabel("1 of 16 notes"); // and the meter counted it
}

test "IME composition lands in the draft like typed text" {
    var state: app.State = .{};
    var t = try signedIn(&state);
    defer t.deinit();
    state.app = &t.app;

    try t.tapLabel("New note");
    try t.focusVia(try t.getByLabel("Note"));
    try t.composeText("nihongo", "日本語"); // start → update → commit
    try t.expectValue("Note", "日本語");
}
```

## Part 7 — Sync (http)

Your sync server doesn't exist. Build the client anyway: under the
harness a request parks instead of touching any socket, and the test
supplies the response — the canned answer *is* the network. One API on
every platform, no futures, no locks, exactly one typed `Result` back on
the UI thread ([services.md](services.md)):

```zig
fn onSyncPressed(ctx: ?*anyopaque) void {
    const state: *State = @ptrCast(@alignCast(ctx.?));
    _ = h.services.http.request(.{
        .app = state.app,
        .url = "https://api.example.com/notes",
        .ctx = state,
        .on_result = onSyncResult,
    }) catch return;
    state.status = "Syncing…";
    refresh(state);
}

fn onSyncResult(ctx: ?*anyopaque, result: h.services.http.Result) void {
    const state: *State = @ptrCast(@alignCast(ctx.?));
    switch (result) {
        .response => |r| {
            if (r.status != 200) {
                state.status = "The server had a problem — showing local notes.";
                refreshNotesIfIdle(state);
                return;
            }
            // The body is the notes, one per line. Status codes are
            // data; slices are valid only for this call, so copy.
            state.note_count = 0;
            var lines = std.mem.splitScalar(u8, r.body.view(), '\n');
            while (lines.next()) |line| {
                if (line.len != 0) addNote(state, line);
            }
            state.offline = false;
            state.status = "Synced.";
            refreshNotesIfIdle(state);
        },
        .failure => |f| {
            // Transport failure is a value with a stable name
            // ("ConnectionRefused", "FetchFailed"), never an exception.
            _ = f;
            state.offline = true;
            state.status = "Offline — showing local notes.";
            state.app.notify("Sync failed", "Your notes are unchanged on this device.", "notes") catch {};
            refreshNotesIfIdle(state);
        },
    }
}

/// Rebuild only if nothing modal is up and the notes screen is current —
/// a background reply must not knock down a sheet the user is typing in.
fn refreshNotesIfIdle(state: *State) void {
    if (state.app.focusScope() != state.app.tree.rootId()) return;
    const current = state.app.router.current() orelse return;
    if (!std.mem.eql(u8, current, "notes")) return;
    state.app.router.replace(state.app, current) catch {};
}
```

Two things here outlive this app. `refreshNotesIfIdle` is the guard
every asynchronous reply needs: results arrive on the UI thread between
events, but the user may have navigated or opened a sheet since the
request left — state is updated unconditionally, the *rebuild* is
polite. And the failure leg raises a **notice** — `app.notify(title,
description, route)` — nokre's persistent, never-timing-out surface
that survives navigation and deep-links back; its three states (banner,
pane, minimized) are specified in [elements.md](elements.md).

The tests own time. Park, inspect, answer — or refuse:

```zig
test "sync: the request parks, the canned response is the network" {
    var state: app.State = .{};
    var t = try signedIn(&state);
    defer t.deinit();
    state.app = &t.app;

    try t.tapLabel("Sync");
    _ = try t.getByLabel("Syncing…"); // the in-flight state is real UI

    const req = t.app.services.http.pendingAt(0);
    try std.testing.expectEqual(nok.services.http.Method.GET, req.method);
    try std.testing.expectEqualStrings("https://api.example.com/notes", req.url);

    try t.fulfillHttp(.{ .status = 200, .body = "Buy oat milk\nCall the plumber" });
    _ = try t.getByLabel("Synced.");
    _ = try t.getByLabel("Call the plumber"); // newest first
    _ = try t.getByLabel("2 of 16 notes");
}

test "sync failure: offline badge, a notice, and local notes untouched" {
    var state: app.State = .{};
    var t = try signedIn(&state);
    defer t.deinit();
    state.app = &t.app;

    try t.tapLabel("New note");
    try t.focusVia(try t.getByLabel("Note"));
    try t.typeText("Water the plants");
    try t.tapLabel("Add");

    try t.tapLabel("Sync");
    try t.failHttp("FetchFailed"); // the offline case, one line

    _ = try t.getByLabel("Offline"); // the badge
    _ = try t.getByLabelContaining("Sync failed"); // the notice banner
    _ = try t.getByLabel("Water the plants"); // the local note survived
}

test "a fake server serves the whole flow" {
    var state: app.State = .{};
    var t = try signedIn(&state);
    defer t.deinit();
    state.app = &t.app;
    t.onHttp(null, serve);

    try t.tapLabel("Sync");
    try t.settleHttp(); // however many requests the flow issues
    _ = try t.getByLabel("milk");
    _ = try t.getByLabel("bread");
}

fn serve(_: ?*anyopaque, req: nok.services.http.PendingRequest) ?nok.testing.HttpOutcome {
    if (std.mem.endsWith(u8, req.url, "/notes"))
        return .{ .respond = .{ .status = 200, .body = "milk\nbread" } };
    return .{ .fail = "FetchFailed" }; // everything unrouted: offline
}
```

When a flow issues *competing* requests — search-as-you-type, say —
`fulfillHttpAt(i, …)` answers by index instead of oldest-first, so the
stale-response race is a test you write once and reproduce every run
([testing.md](testing.md) has the worked example). Run the app with
`zig build run` too: `api.example.com` refuses real connections, so you
watch the failure path live — badge, notice, and all — exactly the path
the tests proved.

## Part 8 — Heavy work (workers)

Actions run on the UI thread: one that takes 200 ms freezes taps, keys,
and paint for 200 ms. Heavy synchronous compute goes on a **worker**: a
struct with typed messages in and typed replies out, on its own thread
natively and a Web Worker on the web, never touching your `App`. Notes
counts words — contrived at sixteen notes, but the shape is the lesson:

```zig
pub const Stats = struct {
    /// Messages are values: this fixed buffer is copied at `send`. For
    /// payloads worth moving instead of copying, see h.workers.Bytes
    /// (docs/internals/workers.md).
    pub const Corpus = struct { text: [max_notes * max_note_len]u8, len: u32 };
    pub const Msg = union(enum) { analyze: Corpus };
    pub const Reply = union(enum) { analyzed: struct { words: u64, longest: u64 } };

    pub fn init(_: std.mem.Allocator) !Stats {
        return .{};
    }
    pub fn deinit(_: *Stats) void {}

    pub fn handle(_: *Stats, msg: Msg, out: *h.workers.Outbox(Reply)) !void {
        switch (msg) {
            .analyze => |corpus| {
                var words: u64 = 0;
                var longest: u64 = 0;
                var word_len: u64 = 0;
                for (corpus.text[0..corpus.len]) |byte| {
                    if (byte == ' ' or byte == '\n') {
                        if (word_len > 0) words += 1;
                        longest = @max(longest, word_len);
                        word_len = 0;
                    } else word_len += 1;
                }
                if (word_len > 0) words += 1;
                longest = @max(longest, word_len);
                try out.send(.{ .analyzed = .{ .words = words, .longest = longest } });
            },
        }
    }
};

/// The closed set of workers this app can spawn — the role routes play
/// for screens. Root-level, so the web can boot the same artifact in
/// another thread and find the code; test roots re-export it.
pub const nokreWorkers = .{Stats};
```

Spawn lazily, send from an action, and let the reply land in state:

```zig
fn onStatsPressed(ctx: ?*anyopaque) void {
    const state: *State = @ptrCast(@alignCast(ctx.?));
    const worker = ensureStats(state) orelse return;
    var corpus: Stats.Corpus = .{ .text = undefined, .len = 0 };
    for (state.notes[0..state.note_count]) |*note| {
        const text = note.slice();
        @memcpy(corpus.text[corpus.len..][0..text.len], text);
        corpus.len += @intCast(text.len);
        corpus.text[corpus.len] = '\n';
        corpus.len += 1;
    }
    worker.send(.{ .analyze = corpus }) catch return;
    setStatsLine(state, "Counting…", .{});
    refreshNotesIfIdle(state);
}

fn onStatsReply(ctx: ?*anyopaque, reply: Stats.Reply) void {
    const state: *State = @ptrCast(@alignCast(ctx.?));
    switch (reply) {
        .analyzed => |a| setStatsLine(state, "{d} words across {d} notes; the longest word runs {d} letters.", .{ a.words, state.note_count, a.longest }),
    }
    refreshNotesIfIdle(state);
}

fn ensureStats(state: *State) ?h.workers.Handle(Stats) {
    if (state.stats) |w| return w;
    const w = h.workers.spawn(Stats, .{
        .app = state.app,
        .ctx = state,
        .on_reply = onStatsReply,
    }) catch return null;
    state.stats = w;
    return w;
}
```

(State grows `stats: ?h.workers.Handle(Stats) = null` plus a line
buffer `setStatsLine` formats into; `buildNotes` renders the line and a
"Word count" button behind a `show_stats` flag Part 10 toggles.) The
contract that generalizes: messages are values — no pointers cross,
ever; a field that can't travel is a compile error naming it. Replies
are delivered between input events on the UI thread, so there is no
data race you can write, and `handle` may send as often as it likes — a
reply is a stream, so progress is just more replies. Cancellation,
retirement, zero-copy `Bytes` handoff, and fault handling:
[internals/workers.md](internals/workers.md); the kitchen sink's
Workers section streams progress from a prime counter, live.

Under the harness workers run inline, and nothing arrives until the
test says so — send-then-settle *is* the race, reproduced identically
every run:

```zig
test "the word-count worker replies when the test says so" {
    var state: app.State = .{};
    var t = try signedIn(&state);
    defer t.deinit();
    state.app = &t.app;

    try t.tapLabel("New note");
    try t.focusVia(try t.getByLabel("Note"));
    try t.typeText("tea with honey");
    try t.tapLabel("Add");

    try t.tapLabel("Word count");
    _ = try t.getByLabel("Counting…"); // sent, not yet landed
    try t.settleWorkers(); // every queued message runs, every reply lands
    _ = try t.getByLabelContaining("3 words across 1 notes");
}
```

One wiring rule: workers resolve their wire ids through the *root
module*, so `main_test.zig` re-exports the registry —
`pub const nokreWorkers = app.nokreWorkers;` — and so does any other
test root you add.

## Part 9 — The note screen: copyable, qr, delete

The pushed detail screen pairs the clipboard path with the camera path —
same value, two ways out — and closes the loop on deletion. Which note
it shows rides in the reference — `note~2`, formatted where the tile is
wired and read back with `routeArg` — never in a `selected` field on
state, which would remember the depth and forget which note it was
([routing.md](routing.md#references) is the argument):

```zig
pub fn buildNote(ctx: ?*anyopaque, app: *h.App) !void {
    const state: *State = @ptrCast(@alignCast(ctx.?));
    const arg = app.routeArg(0) orelse return; // arity is declared, so it is there
    const index = std.fmt.parseInt(usize, arg, 10) catch return;
    if (index >= state.note_count) return;
    const note = &state.notes[index];
    const root = app.tree.rootId();
    // The framework's Back control shares this heading's line — a pushed
    // screen without a way back cannot exist.
    _ = try app.tree.append(root, .{ .heading = .{ .content = "Note", .level = .h1 } });
    _ = try app.tree.append(root, .{ .text = .{ .content = note.slice() } });
    _ = try app.tree.append(root, .{ .divider = .{} });
    _ = try app.tree.append(root, .{ .copyable = .{ .label = "Copy this note", .value = note.slice() } });
    _ = try app.tree.append(root, .{ .qr = .{ .label = "Scan to take it with you", .value = note.slice() } });
    _ = try app.tree.append(root, .{ .button = .{
        .label = "Delete",
        .secondary = true,
        .on_press = .{ .ctx = state, .call = onDeleteNote },
    } });
}

fn onOpenNote(ctx: ?*anyopaque) void {
    const ref: *NoteRef = @ptrCast(@alignCast(ctx.?));
    // A stack buffer is enough: the entry copies the reference.
    var buf: [32]u8 = undefined;
    const dest = std.fmt.bufPrint(&buf, "note~{d}", .{ref.index}) catch return;
    ref.state.app.navigate(dest) catch {};
}

fn onDeleteNote(ctx: ?*anyopaque) void {
    const state: *State = @ptrCast(@alignCast(ctx.?));
    // The action runs on the note screen, so the entry's argument is
    // still the one to read.
    const arg = state.app.routeArg(0) orelse return;
    var i = std.fmt.parseInt(usize, arg, 10) catch return;
    while (i + 1 < state.note_count) : (i += 1) {
        state.notes[i] = state.notes[i + 1];
    }
    state.note_count -= 1;
    state.status = "Note deleted.";
    // Popping rebuilds the notes screen from the changed state.
    state.app.navigateBack() catch {};
}
```

`copyable`'s behavior is intrinsic — activation writes the whole value
to the platform clipboard through the shell, and turns the copy glyph
into a check until the next input. There is no action to wire and no
confirmation to build, and in tests the app's journaling clipboard mock
makes the write first-class:

```zig
test "opening a note: detail, copy, delete" {
    var state: app.State = .{};
    var t = try signedIn(&state);
    defer t.deinit();
    state.app = &t.app;

    try t.tapLabel("New note");
    try t.focusVia(try t.getByLabel("Note"));
    try t.typeText("The wifi password is hunter2");
    try t.tapLabel("Add");

    try t.tapLabel("The wifi password is hunter2");
    try t.expectRoute("note");
    try t.tapLabel("Copy this note"); // activation copies the whole value
    try t.expectCopied("The wifi password is hunter2");

    try t.tapLabel("Back"); // the framework's control, by its accessible name
    try t.expectRoute("notes");
    try t.tapLabel("The wifi password is hunter2");
    try t.tapLabel("Delete");
    try t.expectRoute("notes");
    try t.expectAbsent("The wifi password is hunter2");
    _ = try t.getByLabel("0 of 16 notes");
}
```

## Part 10 — Settings: segmented, radio_group, toggle, package_info

Settings is where the three commit contracts sit side by side: a
`segmented` control the user switches repeatedly (appearance), a
`radio_group` for a choice made in place (sort order) — both commit on
arrow keys, immediately — and a `toggle`, the switch that applies now
(contrast with Part 4's checkbox, which waited for Sign in):

```zig
pub fn buildSettings(ctx: ?*anyopaque, app: *h.App) !void {
    const state: *State = @ptrCast(@alignCast(ctx.?));
    const root = app.tree.rootId();
    _ = try app.tree.append(root, .{ .heading = .{ .content = "Settings", .level = .h1 } });

    _ = try app.tree.append(root, .{ .segmented = .{
        .label = "Appearance",
        .options = &.{ "Light", "Dark", "Automatic" },
        .selected = switch (app.scheme) {
            .light => 0,
            .dark => 1,
            .auto => 2,
        },
        .on_select = .{ .ctx = state, .call = onSchemeSelect },
    } });
    _ = try app.tree.append(root, .{ .radio_group = .{
        .label = "Order",
        .options = &.{ "Newest first", "Oldest first" },
        .selected = if (state.newest_first) 0 else 1,
        .on_select = .{ .ctx = state, .call = onOrderSelect },
    } });
    _ = try app.tree.append(root, .{ .toggle = .{
        .label = "Show word-count stats",
        .on = state.show_stats,
        .on_toggle = .{ .ctx = state, .call = onStatsToggle },
    } });

    _ = try app.tree.append(root, .{ .divider = .{} });
    if (state.signed_in) {
        _ = try app.tree.append(root, .{ .button = .{
            .label = "Sign out",
            .secondary = true,
            .on_press = .{ .ctx = state, .call = onSignOut },
        } });
    } else {
        _ = try app.tree.append(root, .{ .text = .{ .content = "Not signed in." } });
    }

    // Identity is declared once in build.zig and baked in everywhere;
    // only the installer field is asked of the OS.
    const pkg = h.services.package_info.get();
    var pkg_buf: [96]u8 = undefined;
    const pkg_line = try std.fmt.bufPrint(&pkg_buf, "{s} {s} ({d}) — {s}", .{
        pkg.id, pkg.version, pkg.build, @tagName(pkg.installer),
    });
    _ = try app.tree.append(root, .{ .divider = .{} });
    _ = try app.tree.append(root, .{ .text = .{ .content = pkg_line, .style = .{ .family = .mono, .scale = .small, .ink = .dark } } });
}
```

The handlers are one-liners: `onSchemeSelect` maps the index to
`state.app.setScheme(…)` (dark mode is a scheme, not a style — the
palette flips, contrast guarantees hold); `onOrderSelect` sets
`state.newest_first`; `onStatsToggle` sets `state.show_stats`. No
`refresh` needed — the controls carry their own selected state, and the
notes screen reads the flags at its next build. The `package_info` line
at the bottom is the declaration from Part 1's build.zig read back —
run the app and it says `com.example.notes 0.1.0 (1) — dev`.

Two assertions worth stealing. `expectValue` reads a segmented control's
selected option straight from the a11y snapshot, and the raw snapshot
answers questions the named queries don't — like *document order*, the
order a screen reader walks:

```zig
test "appearance is a segmented control the keyboard drives" {
    var state: app.State = .{};
    var t = try signedIn(&state);
    defer t.deinit();
    state.app = &t.app;

    try t.tapLabel("Settings");
    try t.expectValue("Appearance", "Automatic");
    try t.focusVia(try t.getByLabel("Appearance"));
    try t.pressKey(.left, .{}); // each step commits — radiogroup semantics
    try t.expectValue("Appearance", "Dark");
}

test "settings commit immediately: order flips the list" {
    var state: app.State = .{};
    var t = try signedIn(&state);
    defer t.deinit();
    state.app = &t.app;

    // Add "first", then "second", via the sheet as in Part 6…
    try t.tapLabel("Settings");
    try t.focusVia(try t.getByLabel("Order"));
    try t.pressKey(.down, .{}); // radio groups commit on arrow, no submit
    try t.tapLabel("Notes");

    // Oldest first now: "first" precedes "second" in document order.
    var snap = try t.a11ySnapshot(gpa);
    defer snap.deinit();
    var first_at: ?usize = null;
    var second_at: ?usize = null;
    for (snap.nodes.items, 0..) |node, i| {
        if (std.mem.eql(u8, node.label, "first")) first_at = i;
        if (std.mem.eql(u8, node.label, "second")) second_at = i;
    }
    try std.testing.expect(first_at.? < second_at.?);
}
```

## Part 11 — A second language (l10n)

Notes speaks English out of string literals. This part moves the notes
screen's fixed text into ARB catalogs — the same file format Flutter's
gen_l10n reads — and lets Settings switch the language live. nokre
compiles the catalogs at comptime: no codegen step, no runtime parsing,
and a catalog mistake is a build error naming the locale, message, and
line. [localization.md](localization.md) owns the full contract.

Two files under `src/l10n/`. The first is the template: it defines the
key set and each message's placeholders.

`src/l10n/notes_en.arb`:

```json
{
  "@@locale": "en",
  "notesTitle": "Notes",
  "emptyState": "Nothing here yet. Press “New note” to write the first one.",
  "noteCount": "{count, plural, one{One note. Tap it to read, share, or delete it.} other{# notes. Tap one to read, share, or delete it.}}",
  "@noteCount": { "placeholders": { "count": { "type": "num" } } },
  "noteCapacity": "{count} of {max} notes",
  "@noteCapacity": {
    "description": "The capacity meter's label",
    "placeholders": { "count": { "type": "int" }, "max": { "type": "int" } }
  }
}
```

`src/l10n/notes_fa.arb` — Persian. Every template key must be here; a
missing one fails the build rather than silently showing English:

```json
{
  "@@locale": "fa",
  "notesTitle": "یادداشت‌ها",
  "emptyState": "هنوز چیزی اینجا نیست. برای نوشتن اولین یادداشت، «یادداشت نو» را بزنید.",
  "noteCount": "{count, plural, one{یک یادداشت. برای خواندن، هم‌رسانی یا حذف، آن را بزنید.} other{# یادداشت. برای خواندن، هم‌رسانی یا حذف، یکی را بزنید.}}",
  "noteCapacity": "{count} از {max} یادداشت"
}
```

Compile them into a bundle in `main.zig`:

```zig
/// The catalogs, compiled: L.Locale is {en, fa}, L.Key is the template's
/// key set, and every message was validated against its own locale's
/// grammar before this comment finished compiling.
const L = h.l10n.Bundle(&.{
    @embedFile("l10n/notes_en.arb"), // first source = the template
    @embedFile("l10n/notes_fa.arb"),
});
```

The current language is one more field in `State`, changed like any
other state:

```zig
    locale: L.Locale = L.default_locale,
```

In `buildNotes`' signed-in half, the literals become lookups. The
heading and the empty state are `tr` — messages with no placeholders,
returned as constant slices, no buffer:

```zig
    _ = try app.tree.append(title_row, .{ .heading = .{ .content = L.tr(state.locale, .notesTitle), .level = .h1 } });
```

```zig
    if (state.note_count == 0) {
        _ = try app.tree.append(root, .{ .text = .{ .content = L.tr(state.locale, .emptyState) } });
    } else {
        var desc_buf: [160]u8 = undefined;
        const desc = try L.fmt(&desc_buf, state.locale, .noteCount, .{ .count = state.note_count });
        const group = try app.tree.append(root, .{ .tile_group = .{ .description = desc } });
        // …the tiles loop, unchanged.
    }
```

and the meter label's `std.fmt.bufPrint` from Part 6 becomes `fmt` —
same stack buffer habit, because the tree copies at `append`:

```zig
    var cap_buf: [64]u8 = undefined;
    const cap = try L.fmt(&cap_buf, state.locale, .noteCapacity, .{ .count = state.note_count, .max = max_notes });
    _ = try app.tree.append(root, .{ .meter = .{ .label = cap, .value = @intCast(state.note_count), .max = max_notes } });
```

Settings grows the picker — options are native language names, so a
reader lost in the wrong locale can find their own; it commits on
arrow keys like the rest of Part 10:

```zig
    _ = try app.tree.append(root, .{ .segmented = .{
        .label = "Language",
        .options = &.{ "English", "فارسی" },
        .selected = if (state.locale == .en) 0 else 1,
        .on_select = .{ .ctx = state, .call = onLanguageSelect },
    } });
```

```zig
fn onLanguageSelect(ctx: ?*anyopaque, selected: usize) void {
    const state: *State = @ptrCast(@alignCast(ctx.?));
    state.locale = if (selected == 0) .en else .fa;
}
```

**Checkpoint:** `zig build run`, sign in, Settings → فارسی → Notes: the
heading, empty state, and meter read in Persian. Then break it on
purpose: delete `"noteCapacity"` from `notes_fa.arb` and rebuild — the
error names the locale and the missing key. That refusal is the design:
nokre has no fallback between locales, because fallback is what silent
untranslated text is made of.

Things worth noticing, because they generalize:

- **The English bytes barely changed.** The heading, empty state, and
  capacity label are byte-identical to Part 6's literals, so the tests
  that read them still pass; only `noteCount` changed behavior, because
  going plural-aware was the point of moving it. A pure refactor would
  have changed nothing — that is what makes localization safe to do
  late.
- **The checks run before the app does.** Key parity in both
  directions, placeholder names and types at every `fmt` call site, and
  plural forms against each locale's own CLDR categories — Persian's
  `one` covers 0 *and* 1, which the catalog above just handled without
  either of us thinking about it; a Russian catalog would be forced to
  carry its `few` and `many`. The full list of guarantees and refusals
  (no dates, no floats, no runtime loading):
  [localization.md](localization.md).
- **What's still English is a choice you can see.** The nav labels
  (`setNav` chrome), the sign-in screen, statuses, button labels — the
  same pattern extends to each; the course stops at one screen because
  the lesson doesn't repeat. Booting in the device's language is the
  `locale` service ([services.md](services.md)) and two lines in
  `build`: `state.locale = L.resolve(h.services.locale.tag(app))`, then
  `app.setDirection(L.dir(state.locale))` to mirror the chrome —
  [localization.md](localization.md) walks the wiring.

The test drives the switch like a user and asserts the translated
screen through the same a11y snapshot as always:

```zig
test "switching the language localizes the notes screen" {
    var state: app.State = .{};
    var t = try signedIn(&state);
    defer t.deinit();
    state.app = &t.app;

    try t.tapLabel("Settings");
    try t.focusVia(try t.getByLabel("Language"));
    try t.pressKey(.right, .{}); // segmented commits on arrow keys
    try t.tapLabel("Notes");

    _ = try t.getByLabel("یادداشت‌ها"); // the heading, translated
    _ = try t.getByLabel("0 از 16 یادداشت"); // fmt: two placeholders
    _ = try t.getByLabelContaining("هنوز چیزی اینجا نیست"); // the empty state
}
```

## Part 12 — Proof: tree snapshots, step traces, goldens

Three instruments turn "it works" into evidence. First, `expectTree`
pins the whole laid-out screen — role, rect, label, state per node — as
an inline snapshot. Write a placeholder, run once, review the printed
actual, paste it in:

```zig
test "the sign-in screen's whole laid-out tree, inline" {
    var state: app.State = .{};
    var t = try nok.testing.Harness.initWithNav(gpa, viewport, &app.routes, &app.nav_items, &state, "notes");
    defer t.deinit();
    state.app = &t.app;

    // On mismatch both trees print: review the actual, paste it here.
    try t.expectTree(
        \\viewport 480x640 light
        \\stack [0,0,480,640]
        \\  nav [0,592,480,48]
        \\    nav_item [16,596,224,40] "Notes" route= "notes" current
        \\    nav_item [240,596,224,40] "Settings" route= "settings"
        \\  heading [16,16,448,40] "Notes" level=1
        \\  text [16,64,448,48] "Welcome. The passphrase is letmein — this is a course app, not a bank."
        \\  box [16,120,448,160]
        \\    text_input [29,133,422,58] "Passphrase" obscured codepoints=0 cursor=0
        \\    checkbox [29,199,289,24] "Stay signed in on this device" checked
        \\    button [29,231,97,36] "Sign in"
    );
}
```

Second, **step traces** replace what headful debugging or screen
recording would give: every driver action writes a numbered,
action-named snapshot of that same format, diffable with plain `diff` —
and because tests are deterministic, re-running a failing test with
tracing on gives the identical run:

```zig
test "a step trace replays the run, one snapshot per action" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var state: app.State = .{};
    var t = try signedIn(&state);
    defer t.deinit();
    state.app = &t.app;

    var sink = try nok.testing.trace.TreeSink.init(std.testing.io, tmp.dir, gpa, "trace");
    try t.startTrace(sink.observer()); // writes 0000-init.txt

    try t.tapLabel("New note"); // writes 0001-tap-New-note.txt

    const snap = try tmp.dir.readFileAlloc(std.testing.io, "trace/0001-tap-New-note.txt", gpa, .limited(1 << 20));
    defer gpa.free(snap);
    try std.testing.expect(std.mem.indexOf(u8, snap, "sheet") != null);
}
```

(`nok.render.skia.PixelSink` is the pixel twin — one PGM frame per step
through the production renderer, numbering matched file-for-file.)

Third, **golden screenshot tests**: byte-exact frames, no tolerance, no
perceptual diffing — the pixel model makes exactness cheap, so any
variance is a bug by definition. Goldens render through the production
renderer, which needs the Skia prebuilt, so they live in their own test
module; importing the *app's* module (not just `app.nokre`) carries the
Skia link with it. In `build.zig`:

```zig
    const golden = b.option(bool, "golden", "Run golden screenshot tests (needs the Skia prebuilt)") orelse false;
    const update_goldens = b.option(bool, "update-goldens", "Create missing goldens and rewrite mismatched ones (requires -Dgolden)") orelse false;
    if (golden) {
        const golden_mod = b.createModule(.{
            .root_source_file = b.path("src/golden_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "nokre", .module = app.nokre },
                .{ .name = "app", .module = app.module },
            },
        });
        const golden_opts = b.addOptions();
        golden_opts.addOption(bool, "update_goldens", update_goldens);
        golden_mod.addOptions("build_options", golden_opts);
        const golden_tests = b.addTest(.{ .root_module = golden_mod });
        const run_golden = b.addRunArtifact(golden_tests);
        run_golden.setCwd(b.path(".")); // goldens resolve against the project root
        test_step.dependOn(&run_golden.step);
    }
```

`src/golden_test.zig`:

```zig
const std = @import("std");
const build_options = @import("build_options");
const nok = @import("nokre");
const app = @import("app");

pub const nokreWorkers = app.nokreWorkers;

const gpa = std.testing.allocator;

test "golden: the sign-in screen" {
    nok.testing.golden.update = build_options.update_goldens;
    var state: app.State = .{};
    var t = try nok.testing.Harness.initWithNav(gpa, .{ .w = 480, .h = 640 }, &app.routes, &app.nav_items, &state, "notes");
    defer t.deinit();
    state.app = &t.app;

    var surface = try nok.render.skia.Surface.init(480, 640, 1);
    defer surface.deinit();
    t.app.measurer = nok.render.skia.measurer(); // real text metrics
    t.app.invalidate();
    t.renderTo(surface.canvas());
    try nok.testing.golden.expectMatches(gpa, surface.pixels(), surface.pixelWidth(), surface.pixelHeight(), "tests/goldens/signin.pgm");
}
```

**Checkpoint:** `zig build test -Dgolden` fails, reporting that
`tests/goldens/signin.pgm` is *missing* — baselines are never created
implicitly. Rerun with `-Dupdate-goldens` to create it, open the PGM
(almost any image tool reads P5), review it, commit it; the plain run
now passes byte-exact, and every run after that proves the pixels never
drifted. On a mismatch the runner writes `<name>.actual.pgm` next to
the golden for eyeball diffing; if the change was intended, rerun with
`-Dupdate-goldens` to rewrite the golden in place and review the diff.
CI runs without `-Dupdate-goldens`, so a lost baseline fails instead of
silently re-minting — and it must run on the platform that created the
goldens: byte-identity is per-platform today, so a CI box on any other
platform fails by design until nokre-owned Skia builds land
([internals/skia-build.md](internals/skia-build.md)).

## Part 13 — Every platform

The Zig you wrote is finished — what remains is entry points and native
packaging. Desktop and iOS run `main`; on the web and Android the
platform owns the event loop and boots through exported builders. Append
to `main.zig` (and note `main`'s changed signature):

```zig
const builtin = @import("builtin");

const is_wasm = builtin.cpu.arch == .wasm32;
const is_android = builtin.abi.isAndroid();

// Nothing else pulls the platform into the build on these two, because
// main never runs there. Android names its shell; the web has none —
// build.zig routes every wasm32 target to the DOM edition, and nokre
// emits its exports. All an app owes there is the reference itself.
comptime {
    if (is_android) _ = h.platform.backend;
    if (is_wasm) _ = h;
}

pub fn main() if (is_wasm) void else anyerror!void {
    if (comptime is_wasm) {
        // The browser boots via nokreWebBuild; zig's start code still
        // wraps main on wasm, so keep it void and empty.
        return;
    } else {
        if (builtin.os.tag == .ios) return run(std.heap.c_allocator);
        var gpa_state: std.heap.DebugAllocator(.{}) = .init;
        defer _ = gpa_state.deinit();
        return run(gpa_state.allocator());
    }
}

fn run(gpa: std.mem.Allocator) !void {
    // …the body Part 3 wrote, unchanged.
}

/// Android entry: the Activity boots the app through the JNI shell.
pub fn nokreAndroidBuild(gpa: std.mem.Allocator) !*h.App {
    return nokreWebBuild(gpa);
}

/// Web entry: the browser owns the event loop; everything lives on the
/// heap because no enclosing stack frame outlives this call.
pub fn nokreWebBuild(gpa: std.mem.Allocator) !*h.App {
    const state = try gpa.create(State);
    errdefer gpa.destroy(state);
    state.* = .{};
    const app = try gpa.create(h.App);
    errdefer gpa.destroy(app);
    app.* = try h.App.init(gpa, .{
        .viewport = .{ .w = 480, .h = 640 },
        .routes = &routes,
        .ctx = state,
    });
    state.app = app;
    try app.setNav(&nav_items);
    try app.navigate("notes");
    return app;
}

// Panic symbolication can't link on iOS, and wasm has no stderr to
// lock — the same postures nokre's examples take.
pub const panic = if (is_wasm)
    std.debug.no_panic
else if (builtin.os.tag == .ios)
    std.debug.simple_panic
else
    std.debug.FullPanic(std.debug.defaultPanic);
```

Packaging is already done: `zig build` writes `zig-out/pkg/` — an iOS
`Info.plist` and asset catalog, an `AndroidManifest.xml` with the icon
res tree, a web page with manifest and icons — all generated from Part
1's declaration, never hand-written, never committed. The icon is a
deterministic grayscale mark computed from your app id
([services.md](services.md)). Part 3's `.deep_link` added to that tree:
`ios/App.entitlements` (point Xcode's `CODE_SIGN_ENTITLEMENTS` at it),
the App-Links `intent-filter` inside the manifest, and a `.well-known/`
directory with `assetlinks.json` and `apple-app-site-association` — copy
that directory to each claimed domain's web root and replace the two
`REPLACE_…` placeholders (your Apple Team ID, your Android signing cert's
SHA-256) so the OS verifies the link.

**macOS, Windows, and Linux** you have been shipping since Part 1: `zig
build` produces the windowed executable, and Linux runs the same `zig
build run-*` path as the other two (the platform notes from Part 0
apply). A cheap habit for the rest: the Android cross-compile check —
`zig build -Dtarget=aarch64-linux-android` compiles the full app in
seconds, no SDK required, so platform breakage surfaces at your desk
and not in a Gradle log. iOS is not that cheap a check: its build wants
a macOS host, `deps/skia`, and `xcrun`, so it is verified through the
Xcode project below.

**iOS.** Build Skia for iOS once, then let Xcode own packaging and
signing, with a build phase calling `zig build` for the Zig side — the
kitchen sink's project is the template to copy:

```sh
(cd ../nokre && tools/build-skia-ios.sh)     # once
cp -R ../nokre/examples/kitchen_sink/ios ios
```

Then repoint the copy at your app: the build phase's `zig build` runs in
*your* project directory; the link step consumes your `libnotes.a` and
the shim (`app.artifact` and `app.shim` — Part 1's build.zig installs
both); `INFOPLIST_FILE` and the asset catalog read from the `pkg/ios`
tree your install step fills; and `PRODUCT_BUNDLE_IDENTIFIER` must equal
the declared id — that one duplication belongs to Apple's signing
machinery, and Xcode fails the build if it disagrees, so drift is loud.
The per-target split of who compiles what is
[internals/platform-shells.md](internals/platform-shells.md). The
Simulator needs no signing setup; for your own iPhone, a free Apple ID's
personal team is enough.

**Android.** The same split with Gradle in Xcode's chair: a Gradle task
calls `zig build`, and the NDK's CMake compiles the shell and links
Skia:

```sh
(cd ../nokre && tools/build-skia-android.sh) # once; needs an NDK
cp -R ../nokre/examples/kitchen_sink/android android
```

Repoint the copy the same way — the Zig invocation, the consumed static
library, and the applicationId, which Gradle reads from the generated
identity properties so it tracks your declaration. Open the project in
Android Studio and Run, or `./gradlew installDebug` headlessly.

**Web.** The lightest of the six. There is no native link to arrange,
no archive to hand on, and no SDK: `addApp` sees a wasm target and
gives back one module. Add a flag to `build.zig`:

```zig
    const web = b.option(bool, "web", "Build the wasm module for the web") orelse false;
```

and pass `.target = if (web) nokre.webTarget(b) else target` to
`addApp`. `zig build -Dweb` then produces `zig-out/bin/notes.wasm`.
Serve it beside the four files nokre's own web step copies —
[live.js](../src/render/dom/live.js),
[live-worker.js](../src/render/dom/live-worker.js),
[services.js](../src/render/dom/services.js) and a page that calls
`mount({ wasm, into })` — plus the stylesheet the library generates and
the faces it serves ([index.html](../src/render/dom/index.html) is the
whole of that page, and `zig build web`'s step in nokre's `build.zig`
is the recipe). Everything carries over: keyboard, scrolling, the
software keyboard, dark mode from the OS, and an accessibility tree
that is not mirrored anywhere, because it is the page.

Text on Windows and Android rasterizes through FreeType rather than
CoreText, and byte-identity today is per-platform, not across
platforms — your goldens reflect the platform that created them
([internals/skia-build.md](internals/skia-build.md)); the web has its
own answer, which is that its pixels are the browser's. The `worker`
and `http` services need no porting anywhere: the same app code runs on
a `std.Thread` or a Web Worker, `std.http.Client` or `fetch`.

## Part 14 — Where you are now

You have used the core consumer surface: the element vocabulary and
its commit contracts, the tree's append-time correctness, routes and
the framework's navigation chrome, the sheet and notices, six of the
services (`secure_store`, `package_info`, `clipboard` through
`copyable`, `deep_link`, `http`, `worker`), ARB catalogs compiled and validated at
comptime, and a testing story that pinned
behavior, persistence, races, pixels, and the accessibility tree — the
audit having re-run after every action you dispatched. What you did
*not* write is the point: no focus management, no back buttons, no
ARIA, no styling, no sleep() in any test.

Where each thread continues:

- [elements.md](elements.md) — the elements this app skipped
  (`select` and its picker, `table`, `scroll_region`, icons, `link`,
  segmented overflow) and the full semantics of the ones it used.
- [testing.md](testing.md) — the complete harness surface, including
  the stale-response race and bare non-harness apps (two apps, two
  disjoint fakes, one test).
- [services.md](services.md) — the full roster and each service's
  contract; [accessibility.md](accessibility.md) — every rule
  `append` and the audit enforce.
- [localization.md](localization.md) — the full ARB subset, every
  compile-time guarantee, the plural-rule coverage, and the refusals
  Part 11 only gestured at.
- [internals/](internals/architecture.md) — how it works inside, when
  you're ready to contribute; new elements are argued in on semantics.

## Command reference

Inside the nokre checkout:

```sh
zig build test                  # nokre's own unit tests, no dependencies
tools/fetch-deps.sh             # fetch prebuilt Skia + AccessKit (once)
zig build test -Dskia -Dgolden  # + golden screenshot tests, byte-exact
zig build run-hello -Dskia      # examples (macOS / Windows / Linux)
zig build run-kitchen-sink -Dskia
tools/build-skia-ios.sh         # build Skia for iOS from source (once)
tools/build-skia-android.sh     # build Skia for Android from source (once; needs an NDK)
zig build web                   # kitchen sink for the browser → zig-out/web/
python3 -m http.server 8000 -d zig-out/web   # then open http://localhost:8000
zig build check-targets         # compile-check every platform stub
```

Inside your project:

```sh
zig build run                   # the windowed app (macOS / Windows / Linux)
zig build test                  # headless e2e tests, no dependencies
zig build test -Dgolden         # + byte-exact golden screenshots
zig build                       # artifact + generated zig-out/pkg/ manifests
zig build -Dweb                 # the wasm module the web page loads (zig-out/bin/notes.wasm)
zig build -Dtarget=aarch64-linux-android  # SDK-free compile check
```
