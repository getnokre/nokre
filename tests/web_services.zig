//! The app the web harness boots (tests/web_services.mjs): a real nokre
//! app on the *real* web legs of deep_link, oauth, secure_store and
//! locale, compiled to wasm32-freestanding and driven through the
//! shipped live.js — the one place those four legs execute.
//!
//! Under `zig test` a service is its mock, and `check-targets` compiles
//! the web legs into objects it never links or runs, so until this
//! program nothing anywhere called `nokre_deep_link_receive`, opened the
//! oauth popup loop, poured a seed into the in-wasm table, or answered
//! `nokre_locale_seed` (docs/testing.md, "Where the harness stops").
//!
//! It is the dev-store driver's shape on the other side of the language
//! gap: an ordinary app, no mock in the binary, plus one probe export
//! per question the harness asks. The probes are the *only* thing here
//! that a shipping app would not have — they read back what a handler
//! recorded, so every assertion is about what the app saw, not about
//! what the driver claims it sent.
//!
//! Two buffers carry every string across, because JS never allocates in
//! the wasm heap: the harness writes arguments into `nokre_probe_arg`
//! and reads answers out of `nokre_probe_result` — the http transport's
//! three beats, which is also how live.js and services.js talk to every
//! service leg in here.

const std = @import("std");
const h = @import("nokre");

const dom = h.render.dom;
const deep_link = h.services.deep_link;
const locale = h.services.locale;
const oauth = h.services.oauth;
const ss = h.services.secure_store;

/// Two locales, and the second is right-to-left on purpose: the tag the
/// shell seeds decides the words *and* the direction the document gets
/// stamped with, and only an RTL locale makes the second one visible.
/// English is the template, so the empty tag resolves here
/// (docs/localization.md).
const L = h.l10n.Bundle(&.{
    @embedFile("l10n/webcheck_en.arb"),
    @embedFile("l10n/webcheck_fa.arb"),
});

/// The scheme is validated on every platform even where the web leg
/// ignores it (oauth.redirectUri says why), so the app declares the one
/// its packaging registers.
const scheme = "dev.nokre.webcheck";

const State = struct {
    app: *h.App = undefined,

    // deep_link: what arrived, and how many times. Both, because "the
    // fragment was delivered once" and "the fragment was delivered" are
    // different claims and the second is the weaker one.
    links: u32 = 0,
    link: [4096]u8 = undefined,
    link_len: usize = 0,

    // secure_store: the value a *boot read inside the first build*
    // found, kept apart from every later read — the seed's whole
    // contract is that it landed before this call, not eventually.
    boot_len: isize = -1,
    boot: ss.ValueBuf = undefined,
    built: bool = false,

    // oauth: the flow's one result, plus the redirect the page seeded
    // and the error name of a verb that refused.
    results: u32 = 0,
    status: i32 = 0,
    text: [4096]u8 = undefined,
    text_len: usize = 0,
    handle: ?oauth.Handle = null,
    redirect: oauth.RedirectBuf = undefined,
    redirect_len: isize = -1,
    err: [64]u8 = undefined,
    err_len: usize = 0,

    // locale: how many times the device reported a *change* after boot.
    // The boot fire is not one — it lands before any handler is
    // registered — so this counts what the app was told, not what the
    // service cached.
    locale_changes: u32 = 0,

    // The segmented control's answer, and the only screen state a press
    // moves. The hydration scenario asserts on it from both sides: the
    // app saw the press, and the words the rebuild wrote came out of it.
    view: usize = 0,
};

var state_ptr: ?*State = null;

var arg_buf: [8 * 1024]u8 = undefined;
var result_buf: [8 * 1024]u8 = undefined;
/// Where `nokre_probe_document` builds; the answer is copied into
/// `result_buf` like every other, so the harness reads one buffer.
var doc_buf: std.ArrayList(u8) = .empty;

// ---- the app ----------------------------------------------------

/// The handler registered inside `build`, which is what makes a launch
/// fragment land at all (docs/services.md's "first callback after
/// boot").
fn onLink(ctx: ?*anyopaque, url: []const u8) void {
    const state: *State = @ptrCast(@alignCast(ctx.?));
    state.links += 1;
    const n = @min(url.len, state.link.len);
    @memcpy(state.link[0..n], url[0..n]);
    state.link_len = n;
}

/// The three lines every localized nokre app writes
/// (docs/localization.md, "Choosing the locale"): resolve the tag the
/// shell reported against the bundle, tell the app which locale it is
/// *in*, and mirror the chrome with it. Written here rather than
/// paraphrased, because what the harness is checking is that these three
/// lines land in the page's language and not the reader's.
fn applyLocale(state: *State) void {
    const loc = L.resolve(locale.tag(state.app));
    state.app.setLocale(L.tag(loc)) catch |err| return note(state, err);
    state.app.setDirection(L.dir(loc));
}

/// A device locale change after boot. The service does not rebuild for
/// you — what a new locale changes is the app's business — and the
/// screen's words came out of the catalog inside `build`, so the verb is
/// `reload`, the deliberate-gesture one `App.reload` names a locale
/// change as: `invalidate` alone would re-lay-out and re-serialize the
/// tree that is already there, in the old language.
fn onLocale(ctx: ?*anyopaque, _: []const u8) void {
    const state: *State = @ptrCast(@alignCast(ctx.?));
    state.locale_changes += 1;
    applyLocale(state);
    state.app.reload() catch |err| note(state, err);
}

fn onAuth(ctx: ?*anyopaque, result: oauth.Result) void {
    const state: *State = @ptrCast(@alignCast(ctx.?));
    state.results += 1;
    state.handle = null;
    switch (result) {
        .callback => |url| {
            state.status = 1;
            state.text_len = @min(url.len, state.text.len);
            @memcpy(state.text[0..state.text_len], url[0..state.text_len]);
        },
        .cancelled => {
            state.status = 2;
            state.text_len = 0;
        },
        .failure => |f| {
            state.status = 3;
            state.text_len = @min(f.name.len, state.text.len);
            @memcpy(state.text[0..state.text_len], f.name[0..state.text_len]);
        },
    }
    state.app.invalidate();
}

/// A press starts the flow, not an export: `window.open` is a
/// user-activation API, so the popup a browser will actually allow is
/// one opened inside the press — and driving it from the DOM makes
/// click → live.js → core → service one path rather than two.
fn onSignIn(state: *State) void {
    state.redirect_len = -1;
    state.err_len = 0;
    const redirect = oauth.redirectUri(state.app, scheme, &state.redirect) catch |err| return note(state, err);
    state.redirect_len = @intCast(redirect.len);
    // The authorize URL is the app's, whole — nothing about a
    // provider's parameter names lives in nokre.
    var url_buf: [1024]u8 = undefined;
    const url = std.fmt.bufPrint(
        &url_buf,
        "https://provider.example/authorize?client_id=webcheck&state=xyz&redirect_uri={s}",
        .{redirect},
    ) catch |err| return note(state, err);
    state.handle = oauth.start(.{
        .app = state.app,
        .url = url,
        .redirect = redirect,
        .ctx = state,
        .on_result = onAuth,
    }) catch |err| return note(state, err);
}

fn note(state: *State, err: anyerror) void {
    const name = @errorName(err);
    state.err_len = @min(name.len, state.err.len);
    @memcpy(state.err[0..state.err_len], name[0..state.err_len]);
}

/// The two chips of the one control on this app's screen, and the two
/// sentences under it. A press has to change both, because a chip that
/// moves proves the browser resolved the hit and nothing else: the
/// sentence is written by the *builder*, so it only moves if the app
/// rebuilt the screen and the driver patched the result in.
const views = [_][]const u8{ "List", "Grid" };
const shown = [_][]const u8{ "Showing a list.", "Showing a grid." };

/// A press on a chip. `reload` and not `invalidate`: the words above
/// come out of `build`, and `invalidate` re-lays-out and re-serializes
/// the tree that is already there (docs/routing.md, the four motions).
fn onView(state: *State, selected: usize) void {
    state.view = selected;
    state.app.reload() catch |err| note(state, err);
}

fn buildHome(state: *State, app: *h.App) !void {
    state.app = app;
    deep_link.setHandler(app, state, onLink);
    locale.setHandler(app, state, onLocale);
    // Inside the first build and nowhere else: a boot read is
    // synchronous by contract, and the seed either beat it or the
    // contract is broken.
    if (!state.built) {
        state.built = true;
        var buf: ss.ValueBuf = undefined;
        if (ss.get(app, "token", &buf) catch null) |v| {
            @memcpy(state.boot[0..v.len], v);
            state.boot_len = @intCast(v.len);
        }
    }
    const root = app.tree.rootId();
    // From the catalog, so the *rendered* words are what a scenario
    // reads back: the failure this gate exists for is a page whose text
    // is silently in the other language.
    try app.tree.setTitle(L.of(app).tr(.title));
    try app.tree.append(root, .{ .text = .{ .content = "The harness drives this app through the shipped live.js." } });
    try app.tree.append(root, .{ .button = .{
        .label = "Sign in",
        .on_press = .bind(onSignIn, state),
    } });
    try app.tree.append(root, .{ .segmented = .{
        .label = "View",
        .options = &views,
        .selected = state.view,
        .on_select = .bind(onView, state),
    } });
    try app.tree.append(root, .{ .text = .{ .content = shown[state.view] } });
}

/// The nav's second destination, and nothing more: a roster is two
/// entries at the least (`setNav`), and a roster is what puts anything
/// at all in the *chrome* mount — which is half of what a page with two
/// of them is for.
fn buildSecond(_: *State, app: *h.App) !void {
    // Nothing at all, and the page still has a top: the router drew
    // this screen's title from the route's before the builder ran
    // (`Tree.setTitle`).
    _ = app;
}

/// A press with nothing behind it. What makes the second tile below a
/// button is that it is wired at all, not what the wire runs.
fn onSignOut(state: *State) void {
    state.view = 0;
}

/// A hub of rows that navigate — a site's home page, and the shape a
/// section index is. Every tile carries a route, so every one of them
/// is an `<a href>` the browser answers (`serialize.tile`) and the page
/// is whole with nothing running.
///
/// It is here because the census that decides that used to ask the
/// *role*, where `.tile` is a control unconditionally: a page like this
/// derived a need it does not have, and a driver had no way to decline
/// what a derivation asserts.
fn buildHub(_: *State, app: *h.App) !void {
    const group = try app.tree.appendId(app.tree.rootId(), .{ .tile_group = .{} });
    for ([_][]const u8{ "second", "explore", "collections" }) |name| {
        try app.tree.append(group, .{ .tile = .{ .label = name, .route = name } });
    }
}

/// The same rows with one that acts instead of navigating — a button in
/// row clothing, which nothing but an app can answer. The pair is the
/// assertion: one page derives no need and one derives it.
fn buildActions(state: *State, app: *h.App) !void {
    const group = try app.tree.appendId(app.tree.rootId(), .{ .tile_group = .{} });
    try app.tree.append(group, .{ .tile = .{ .label = "Explore everything", .route = "explore" } });
    try app.tree.append(group, .{ .tile = .{ .label = "Sign out", .on_press = .bind(onSignOut, state) } });
}

/// The hub with a **footer**, in the shape a site's page builder gives
/// one: a stack of links and a line of text, appended last.
///
/// It used to be a string. `Document.body_end` spliced a driver's
/// `<footer>` after `</main>`, and the three revisions that seam
/// survived were three rounds of paying for it — the browser's default
/// serif, then 73px of it under a fixed band, and never an audit, a
/// landmark or a resolved route (docs/static-sites.md, "A seam is for
/// what does not render"). Here it is content: inside the screen, so
/// the reserve already clears it and the sheet already styles it.
///
/// Everything on it is answered by the browser, so the page still
/// publishes with no module — which is what lets this one screen carry
/// both halves of the claim.
///
/// It carries the **language row** too, which is the thing a footer
/// actually has on a site published in more than one language: one link
/// per bundled locale, each named in its own language, all of them
/// sitting in a page that is in English. That is WCAG 3.1.2's textbook
/// case, and until revision 50 nothing in the element set could say
/// which language a run of words was in — so a screen reader read
/// `فارسی` with English phonemes and the only word that could have
/// helped the reader was the one it got wrong. The tag is on the
/// element now (`element.Link.lang`) and this is where it reaches a
/// browser: an attribute in a unit test is a string comparison, and an
/// attribute on a parsed document is an anchor with a language.
fn buildFooted(state: *State, app: *h.App) !void {
    try buildHub(state, app);
    const stack = try app.tree.appendId(app.tree.rootId(), .{ .stack = .{} });
    try app.tree.append(stack, .{ .link = .{ .label = "Terms", .route = "terms" } });
    try app.tree.append(stack, .{ .link = .{ .label = "Privacy", .route = "privacy" } });
    try app.tree.append(stack, .{ .link = .{
        .label = "Source",
        .external = "https://github.com/getnokre/nokre",
    } });
    // English is the page's own language and still states it: a chooser
    // is a set, and a set whose members are annotated except one is a
    // reader's question about the one. What states nothing is the link
    // above that is not part of the set.
    //
    // And none of the three is a route. A reference names a screen and
    // the arguments that pick which page of it this is, and nokre's
    // grammar has no third slot a locale could ride in — so a real
    // multi-locale site writes a reference of its own here and answers
    // it in its `Refs` against whatever screen is current, which is how
    // a reader keeps their place when they switch. `lang:` is the
    // spelling rokovski.com uses; the colon is outside a route name's
    // charset, so nothing can collide with it and the router can never
    // spell it. That is the whole point of it being here: this is the
    // destination the *browser* has to take, because core cannot.
    try app.tree.append(stack, .{ .link = .{ .label = "English", .route = "lang:en", .lang = "en" } });
    try app.tree.append(stack, .{ .link = .{ .label = "فارسی", .route = "lang:fa", .lang = "fa" } });
    try app.tree.append(stack, .{ .link = .{ .label = "Türkçe", .route = "lang:tr", .lang = "tr" } });
    try app.tree.append(stack, .{ .text = .{ .content = "© nokre" } });
}

/// The four extra destinations `nokre_probe_wide_nav` declares. Long
/// names on purpose: a roster is measured in the words it holds, so
/// this is the set that makes the row's width a real question in a
/// desktop window rather than only on a phone.
const routes = h.Routes(State).table(&.{
    .{ .name = "home", .title = .{ .fixed = "Home" }, .build = buildHome },
    .{ .name = "second", .title = .{ .fixed = "Second" }, .build = buildSecond },
    .{ .name = "explore", .title = .{ .fixed = "Explore everything" }, .build = buildSecond },
    .{ .name = "collections", .title = .{ .fixed = "Saved collections" }, .build = buildSecond },
    .{ .name = "account", .title = .{ .fixed = "Your whole account" }, .build = buildSecond },
    .{ .name = "documentation", .title = .{ .fixed = "Documentation" }, .build = buildSecond },
    .{ .name = "hub", .title = .{ .fixed = "Everything here" }, .build = buildHub },
    .{ .name = "actions", .title = .{ .fixed = "Things to do" }, .build = buildActions },
    .{ .name = "footed", .title = .{ .fixed = "Everything here" }, .build = buildFooted },
    // The two a footer points at, and the reason they are in the table
    // rather than typed into an href: a footer's links are the site's
    // own places, so they resolve through `Refs` like every other route
    // and a reference to a page that does not exist is a build failure
    // rather than a dead anchor a reader finds.
    .{ .name = "terms", .title = .{ .fixed = "Terms" }, .build = buildSecond },
    .{ .name = "privacy", .title = .{ .fixed = "Privacy" }, .build = buildSecond },
    // The chooser's three destinations are deliberately *not* here.
    // `buildFooted` says why: a locale's copy of this page is not a
    // route, so the table cannot spell one and the default fragment
    // resolver answers `#lang:fa` for it. Adding entries would make
    // this gate the one arrangement no site has.
});

comptime {
    // `main` never runs on the web; without this nothing pulls the
    // library into the build at all (the kitchen sink's note).
    _ = h;
}

pub fn main() void {}

pub fn nokreWebBuild(alloc: std.mem.Allocator) !*h.App {
    const state = try alloc.create(State);
    errdefer alloc.destroy(state);
    state.* = .{};
    const app = try alloc.create(h.App);
    errdefer alloc.destroy(app);
    app.* = try h.App.init(alloc, .{
        .viewport = .{ .w = 480, .h = 640 },
        .routes = &routes,
        .ctx = state,
    });
    state.app = app;
    state_ptr = state;
    // After `App.init` and before the first build, which is where a
    // boot locale is readable at all: the service's install fired inside
    // `init` with whatever the shell seeded (services/locale/locale.zig).
    applyLocale(state);
    try app.setNav(&.{
        .{ .route = "home", .icon = .house },
        .{ .route = "second", .icon = .settings },
    });
    try app.navigate("home");
    return app;
}

// ---- the probes -------------------------------------------------

pub export fn nokre_probe_arg() [*]u8 {
    return &arg_buf;
}

pub export fn nokre_probe_result() [*]u8 {
    return &result_buf;
}

fn probe() *State {
    return state_ptr.?;
}

fn out(bytes: []const u8) isize {
    const n = @min(bytes.len, result_buf.len);
    @memcpy(result_buf[0..n], bytes[0..n]);
    return @intCast(n);
}

pub export fn nokre_probe_links() u32 {
    return probe().links;
}

pub export fn nokre_probe_link() isize {
    const s = probe();
    return out(s.link[0..s.link_len]);
}

/// The value the first `build` read, or -1 for a store that had none.
pub export fn nokre_probe_boot_value() isize {
    const s = probe();
    if (s.boot_len < 0) return -1;
    return out(s.boot[0..@intCast(s.boot_len)]);
}

/// -1 is absence (a missing key is data, never a failure); -2 is the
/// error the verb returned, named in `nokre_probe_error`.
pub export fn nokre_probe_store_get(k_len: usize) isize {
    const s = probe();
    s.err_len = 0;
    var buf: ss.ValueBuf = undefined;
    const value = ss.get(s.app, arg_buf[0..k_len], &buf) catch |err| {
        note(s, err);
        return -2;
    };
    return if (value) |v| out(v) else -1;
}

pub export fn nokre_probe_store_set(k_len: usize, v_len: usize) isize {
    const s = probe();
    s.err_len = 0;
    ss.set(s.app, arg_buf[0..k_len], arg_buf[k_len..][0..v_len]) catch |err| {
        note(s, err);
        return -2;
    };
    return 0;
}

pub export fn nokre_probe_store_delete(k_len: usize) isize {
    const s = probe();
    s.err_len = 0;
    ss.delete(s.app, arg_buf[0..k_len]) catch |err| {
        note(s, err);
        return -2;
    };
    return 0;
}

/// The keys, newline-joined in the order `list` returned them — so the
/// harness asserts the contract's sort, not a set.
pub export fn nokre_probe_store_list() isize {
    const s = probe();
    s.err_len = 0;
    var buf: ss.ListBuf = undefined;
    const keys = ss.list(s.app, &buf) catch |err| {
        note(s, err);
        return -2;
    };
    var len: usize = 0;
    for (keys, 0..) |key, i| {
        if (i != 0) {
            result_buf[len] = '\n';
            len += 1;
        }
        @memcpy(result_buf[len..][0..key.len], key);
        len += key.len;
    }
    return @intCast(len);
}

/// The redirect `redirectUri` composed on the last press: the page's own
/// address as live.js seeded it, or -1 when the seed was refused.
pub export fn nokre_probe_redirect() isize {
    const s = probe();
    if (s.redirect_len < 0) return -1;
    return out(s.redirect[0..@intCast(s.redirect_len)]);
}

/// 0 none yet, 1 callback, 2 cancelled, 3 failure.
pub export fn nokre_probe_oauth_status() i32 {
    return probe().status;
}

pub export fn nokre_probe_oauth_results() u32 {
    return probe().results;
}

/// The callback URL, or a failure's name.
pub export fn nokre_probe_oauth_text() isize {
    const s = probe();
    return out(s.text[0..s.text_len]);
}

/// The app dismissing its own session — `Handle.cancel`, which is not
/// the user closing the popup and must reach `nokre_oauth_js_close`.
pub export fn nokre_probe_oauth_cancel() void {
    const s = probe();
    if (s.handle) |handle| handle.cancel();
    s.handle = null;
}

/// The tag the *shell* reported — what live.js poured into the seed
/// lane, before any resolution. Kept apart from the one below so "the
/// page's locale never arrived" and "it arrived and the app resolved it
/// elsewhere" stay different findings.
pub export fn nokre_probe_device_tag() isize {
    return out(locale.tag(probe().app));
}

/// The locale the app is *in* (`App.locale()`) — the resolved tag,
/// which is also what `L.of(app)` spends and what a generated document
/// would have carried as its `lang`.
pub export fn nokre_probe_locale() isize {
    return out(probe().app.locale());
}

/// 1 when the chrome is mirrored. Read from the app rather than from
/// the attribute, so a scenario can hold the two against each other.
pub export fn nokre_probe_rtl() i32 {
    return @intFromBool(probe().app.direction == .rtl);
}

/// Device locale changes delivered *after* boot.
pub export fn nokre_probe_locale_changes() u32 {
    return probe().locale_changes;
}

/// Which chip the app believes is chosen. Read from the app, so a
/// scenario can hold it against the chip the *document* is showing —
/// the two disagreeing is a press the browser resolved and core never
/// heard, which is exactly the failure a hydrated page can have.
pub export fn nokre_probe_view() usize {
    return probe().view;
}

/// The file a generator would publish for the screen this app is on:
/// `dom.document`, over this app's own tree, with the two mount ids and
/// the boot options the harness then mounts back over it.
///
/// It is a probe rather than markup the harness holds because the
/// hydration claim is about *two writers of one page* — the static
/// driver wrote the file, the live driver rebuilds it — and a fixture
/// typed in JavaScript would be a third, agreeing with neither. -2 is a
/// document too long for the result buffer: a probe that outgrew its
/// transport, not a fault in what it measured.
pub export fn nokre_probe_document() isize {
    return writeDocument(true);
}

/// The same file with the boot left off — the 1,124-in-1,126 page of a
/// static site, which nothing will ever mount over.
///
/// Two assertions ride it now. On a screen that holds a control an app
/// has to answer, it is refused (`error.PageNeedsBoot`, read back
/// through `nokre_probe_error`): nokre derives the need from the tree,
/// so a driver cannot publish an inert page by forgetting. On a screen
/// of prose and links, it is written — and byte for byte its roster is
/// the booted file's, because which shape a roster wears is the
/// reader's window's and nothing about the file is a term in it.
pub export fn nokre_probe_document_unbooted() isize {
    return writeDocument(false);
}

/// Puts the app on a screen by name, arriving rather than pushing —
/// `switchTo`, which is what a generator does per page and what the
/// live driver does for a document (live.zig). The push is deliberately
/// not offered: a pushed screen wears the Back control, and Back is one
/// of the things that makes a page need a runtime.
pub export fn nokre_probe_switch_to(len: usize) i32 {
    const s = probe();
    s.app.switchTo(arg_buf[0..len]) catch |err| {
        note(s, err);
        return 0;
    };
    return 1;
}

/// Re-declares the roster as six destinations with long names — the set
/// that does not make a line in a browser window of six or seven
/// hundred pixels, which is where a header stopped being a header.
pub export fn nokre_probe_wide_nav() i32 {
    const s = probe();
    s.app.setNav(&.{
        .{ .route = "home", .icon = .house },
        .{ .route = "second", .icon = .settings },
        .{ .route = "explore", .icon = .search },
        .{ .route = "collections", .icon = .bookmark },
        .{ .route = "account", .icon = .user },
        .{ .route = "documentation", .icon = .file_text },
    }) catch |err| {
        note(s, err);
        return 0;
    };
    return 1;
}

fn writeDocument(booted: bool) isize {
    const s = probe();
    doc_buf.clearRetainingCapacity();
    var em: dom.Emitter = .{
        .gpa = std.heap.wasm_allocator,
        .app = s.app,
        .out = &doc_buf,
        // What the live driver renders with (live.zig), and what makes
        // a node's identity *stated* across the handover rather than
        // guessed at.
        .options = .{ .node_ids = true },
    };
    defer em.deinit();
    dom.document(&em, .{
        .title = "web services",
        .stylesheet = "/style.css",
        .chrome_id = "chrome",
        .content_id = "content",
        .content_class = "page",
        .skip = "Skip to content",
        .boot = if (booted) .{ .wasm = "/app.wasm", .addressing = .documents } else null,
        // The page states its own policy, which is what makes this gate
        // the one that can hold it against a boot. Every directive in it
        // is derived from the fields above, so a booted file and an
        // unbooted one carry different ones — and the browser stub
        // enforces whichever it is served (tests/web_browser.mjs).
        .csp = .{},
    }) catch |err| {
        note(s, err);
        return -2;
    };
    if (doc_buf.items.len > result_buf.len) return -2;
    return out(doc_buf.items);
}

/// The name of the error the last verb returned, empty if it succeeded.
pub export fn nokre_probe_error() isize {
    const s = probe();
    return out(s.err[0..s.err_len]);
}
