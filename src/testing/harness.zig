//! The e2e harness: a full nokre app, headless. No window, no platform,
//! no Skia required — the same `App`, layout, focus, and event pipeline
//! that production uses, driven synthetically.
//!
//! Accessibility is not opt-in here either: the a11y audit runs at init
//! and after every driver action. Interactions go through the user's
//! pipeline; assertions read the a11y snapshot — tests can only assert
//! what a screen reader could perceive.

const std = @import("std");
const focus = @import("../core/focus.zig");
const app_mod = @import("../core/app.zig");
const tree_mod = @import("../core/tree.zig");
const element_mod = @import("../core/element.zig");
const event_mod = @import("../core/event.zig");
const geometry = @import("../core/geometry.zig");
const text = @import("../core/text.zig");
const router_mod = @import("../core/router.zig");
const nav_mod = @import("../core/nav.zig");
const notices_mod = @import("../core/notices.zig");
const renderer = @import("../render/renderer.zig");
const canvas_mod = @import("../render/canvas.zig");
const semantics = @import("../a11y/semantics.zig");
const workers = @import("../workers/workers.zig");
const clock = @import("../services/clock/clock.zig");
const haptic = @import("../services/haptic/haptic.zig");
const http = @import("../services/http/http.zig");
const secure_store = @import("../services/secure_store/secure_store.zig");
const locale = @import("../services/locale/locale.zig");
const oauth = @import("../services/oauth/oauth.zig");
const iap = @import("../services/iap/iap.zig");
const share = @import("../services/share/share.zig");

/// The two ends of the back gesture's threshold, for asserting against
/// `knocks()`. Re-exported here and nowhere else: the haptic service has
/// no consumer verb (docs/internals/haptics.md), so `nokre.services`
/// deliberately does not carry it — a test needs the type, an app needs
/// nothing at all.
pub const Knock = haptic.Knock;

pub const diag = @import("diag.zig");
pub const queries = @import("queries.zig");
pub const driver = @import("driver.zig");
pub const audit = @import("audit.zig");
pub const golden = @import("golden.zig");
pub const trace = @import("trace.zig");

const App = app_mod.App;
const NodeId = tree_mod.NodeId;

pub const BuildFn = *const fn (ctx: ?*anyopaque, app: *App) anyerror!void;

/// The http mock's own types, re-exported so harness users read one
/// import: a handler decides respond/fail/null per parked request —
/// null leaves it parked for the test to answer by hand.
pub const HttpOutcome = http.Outcome;
pub const HttpHandler = http.Handler;
pub const HttpOp = http.Op;

/// One pending notice as the app holds it — title, description, route,
/// icon, and whether it is important. Re-exported so a test asserting on
/// `noticesPending()` reads one import, `Knock`'s rationale for a type
/// only tests name.
pub const PendingNotice = notices_mod.OwnedNotice;

pub const InitOptions = struct {
    ctx: ?*anyopaque = null,
    build: ?BuildFn = null, // plain screen…
    routes: []const router_mod.RouteDef = &.{}, // …or routed (exactly one of build/routes)
    nav: []const nav_mod.Destination = &.{},
    initial_route: []const u8 = "", // required when routes given
    store: secure_store.Mock.Config = .{},
    locale: locale.Mock.Config = .{}, // the device tag at boot; "" is "the platform said nothing"
    clock: clock.Mock.Config = .{}, // the wall clock at boot; the default is a fixed, obviously fake instant
    oauth: oauth.Mock.Config = .{}, // the PKCE seeds, and optionally what the browser does
    iap: iap.Mock.Config = .{}, // the store's shelf, and whether there is a store at all
    share: share.Mock.Config = .{}, // whether this boot has a share sheet at all
};

pub const Harness = struct {
    app: App,
    /// This app's whole secure store — the app-owned fake, aliased for
    /// assertion ergonomics (t.store.journal()); dead with the app at
    /// deinit so nothing leaks to the next test.
    store: *secure_store.Fake,
    step_observer: ?trace.StepObserver = null,
    step_index: u32 = 0,

    /// The general form the named variants wrap. The app is
    /// constructed with its mocks — `opts.store` and `opts.locale`
    /// apply inside App.init, before `build`/`navigate` runs, so a
    /// boot-time read sees the seeded state synchronously.
    pub fn initWith(gpa: std.mem.Allocator, viewport: geometry.Size, opts: InitOptions) !Harness {
        if ((opts.build == null) == (opts.routes.len == 0)) {
            diag.print("initWith needs exactly one of build/routes\n", .{});
            return error.InitOptionsShape;
        }
        var self: Harness = .{
            .app = try App.init(gpa, .{
                .viewport = viewport,
                .routes = opts.routes,
                .ctx = opts.ctx,
                .services = .{
                    .secure_store = .mock(opts.store),
                    .locale = .mock(opts.locale),
                    .clock = .mock(opts.clock),
                    .oauth = .mock(opts.oauth),
                    .iap = .mock(opts.iap),
                    .share = .mock(opts.share),
                },
            }),
            .store = undefined,
        };
        self.store = self.app.services.secure_store.state.?;
        errdefer self.app.deinit();
        if (opts.build) |build| {
            try build(opts.ctx, &self.app);
        } else {
            if (opts.nav.len != 0) try self.app.setNav(opts.nav);
            try self.app.navigate(opts.initial_route);
        }
        try self.audit();
        return self;
    }

    /// Builds a single screen. Uses the fixed measurer: layout in harness
    /// tests is deterministic without any native dependency.
    pub fn init(gpa: std.mem.Allocator, viewport: geometry.Size, ctx: ?*anyopaque, build: BuildFn) !Harness {
        return initWith(gpa, viewport, .{ .ctx = ctx, .build = build });
    }

    /// Builds a routed app and navigates to `initial_route`.
    pub fn initWithRoutes(
        gpa: std.mem.Allocator,
        viewport: geometry.Size,
        routes: []const router_mod.RouteDef,
        ctx: ?*anyopaque,
        initial_route: []const u8,
    ) !Harness {
        return initWith(gpa, viewport, .{
            .routes = routes,
            .ctx = ctx,
            .initial_route = initial_route,
        });
    }

    /// Same, with app-level nav chrome installed before the first route.
    pub fn initWithNav(
        gpa: std.mem.Allocator,
        viewport: geometry.Size,
        routes: []const router_mod.RouteDef,
        nav_items: []const nav_mod.Destination,
        ctx: ?*anyopaque,
        initial_route: []const u8,
    ) !Harness {
        return initWith(gpa, viewport, .{
            .routes = routes,
            .nav = nav_items,
            .ctx = ctx,
            .initial_route = initial_route,
        });
    }

    /// Boot with a populated (or unavailable) store — the seeded
    /// token is readable inside `build`, synchronously; available =
    /// false boots the app into a locked keychain.
    pub fn initWithStore(
        gpa: std.mem.Allocator,
        viewport: geometry.Size,
        boot: secure_store.Mock.Config,
        ctx: ?*anyopaque,
        build: BuildFn,
    ) !Harness {
        return initWith(gpa, viewport, .{ .store = boot, .ctx = ctx, .build = build });
    }

    pub fn deinit(self: *Harness) void {
        self.app.deinit();
    }

    // ---- queries ----
    // `get*` fails loudly, listing what does exist; `query*` returns null
    // and is the tool for asserting absence.

    pub fn getByLabel(self: *const Harness, label: []const u8) !NodeId {
        return queries.queryByLabel(&self.app.tree, label) orelse
            queries.noMatch(&self.app.tree, "label", label);
    }

    pub fn getByLabelContaining(self: *const Harness, needle: []const u8) !NodeId {
        return queries.queryByLabelContaining(&self.app.tree, needle) orelse
            queries.noMatch(&self.app.tree, "label containing", needle);
    }

    /// Role plus accessible name — never an index; users don't perceive
    /// tree positions.
    pub fn getByRole(self: *const Harness, role: element_mod.Role, name: []const u8) !NodeId {
        return queries.queryByRole(&self.app.tree, role, name) orelse
            queries.noMatch(&self.app.tree, @tagName(role), name);
    }

    pub fn queryByLabel(self: *const Harness, label: []const u8) ?NodeId {
        return queries.queryByLabel(&self.app.tree, label);
    }

    pub fn queryByRole(self: *const Harness, role: element_mod.Role, name: []const u8) ?NodeId {
        return queries.queryByRole(&self.app.tree, role, name);
    }

    pub fn focusedLabel(self: *const Harness) []const u8 {
        const stop = self.app.focused orelse return "";
        const el = self.app.tree.getConst(stop.node) orelse return "";
        // A focused inline link reports the link's own words, not the
        // whole paragraph it sits in — what the user hears is what the
        // assertion should read.
        if (stop.span) |i| {
            const spans = focus.spansOf(el.*);
            if (i < spans.len) return spans[i].text;
        }
        return el.label();
    }

    // ---- tracing ----

    /// Installs a per-step observer (e.g. `trace.TreeSink.observer()`,
    /// `render.skia.PixelSink.observer()`) and emits step 0, the
    /// post-build state. When no observer is installed, steps cost a
    /// single null check.
    pub fn startTrace(self: *Harness, observer: trace.StepObserver) !void {
        self.step_observer = observer;
        try observer.call(observer.ctx, 0, "init", &self.app);
    }

    fn observe(self: *Harness, comptime fmt: []const u8, args: anytype) !void {
        const obs = self.step_observer orelse return;
        self.step_index += 1;
        var buf: [64]u8 = undefined;
        var w = std.Io.Writer.fixed(&buf);
        w.print(fmt, args) catch {}; // overflow truncates the action name
        try obs.call(obs.ctx, self.step_index, w.buffered(), &self.app);
    }

    /// Every driver action ends here: emit the trace step, then re-audit
    /// the screen the action produced.
    fn afterStep(self: *Harness, comptime fmt: []const u8, args: anytype) !void {
        try self.observe(fmt, args);
        try self.audit();
    }

    fn labelOf(self: *const Harness, id: NodeId) []const u8 {
        const el = self.app.tree.getConst(id) orelse return "";
        return el.label();
    }

    // ---- input ----

    pub fn tap(self: *Harness, id: NodeId) !void {
        try driver.tap(&self.app, id);
        try self.afterStep("tap {s}", .{self.labelOf(id)});
    }

    pub fn tapLabel(self: *Harness, label: []const u8) !void {
        // An inline link has no node of its own, so it cannot come
        // back from `getByLabel` — but to a user it is just another
        // control with those words on it, and `tapLabel` is how a test
        // says "tap the thing that says this".
        if (queries.queryLink(&self.app.tree, label)) |link| return self.tapLink(link);
        try self.tap(try self.getByLabel(label));
    }

    pub fn tapLink(self: *Harness, link: focus.Focus) !void {
        try driver.tapLink(&self.app, link);
        try self.afterStep("tap link {s}", .{queries.linkLabel(&self.app.tree, link) orelse ""});
    }

    /// The inline link with these words, or null. Link spans are
    /// controls without nodes, so they are addressed as focus stops.
    pub fn queryLink(self: *const Harness, label: []const u8) ?focus.Focus {
        return queries.queryLink(&self.app.tree, label);
    }

    pub fn pressKey(self: *Harness, key: event_mod.Key, mods: event_mod.Modifiers) !void {
        try driver.pressKey(&self.app, key, mods);
        try self.afterStep("key {s}", .{@tagName(key)});
    }

    pub fn typeText(self: *Harness, bytes: []const u8) !void {
        try driver.typeText(&self.app, bytes);
        try self.afterStep("type {s}", .{bytes});
    }

    pub fn composeText(self: *Harness, composition: []const u8, committed: []const u8) !void {
        try driver.composeText(&self.app, composition, committed);
        try self.afterStep("compose {s}", .{committed});
    }

    pub fn scroll(self: *Harness, id: NodeId, delta_y: i32) !void {
        try driver.scroll(&self.app, id, delta_y);
        try self.afterStep("scroll {d}", .{delta_y});
    }

    pub fn scrollX(self: *Harness, id: NodeId, delta_x: i32) !void {
        try driver.scrollX(&self.app, id, delta_x);
        try self.afterStep("scroll x {d}", .{delta_x});
    }

    /// Drag in from the leading edge, past the threshold, and let go —
    /// the gesture that goes back. Fails the same way any other action
    /// does if the screen it lands on cannot pass the audit; a test
    /// asserting the threshold itself dispatches `.edge_pan` steps.
    pub fn edgePanBack(self: *Harness) !void {
        try driver.edgePanBack(&self.app);
        try self.afterStep("edge pan back", .{});
    }

    /// Every haptic knock the framework fired, in order. The gesture's
    /// threshold is the only thing that fires one, so this reads as
    /// "armed, then disarmed, then armed again" — the crossings a finger
    /// would have felt (docs/internals/haptics.md).
    pub fn knocks(self: *const Harness) []const haptic.Knock {
        return self.app.services.haptic.fired();
    }

    pub fn focusVia(self: *Harness, id: NodeId) !void {
        try driver.focusVia(&self.app, id);
        try self.afterStep("focus {s}", .{self.labelOf(id)});
    }

    /// Runs every queued worker message and delivers every queued
    /// reply, to quiescence. In tests workers run inline, so this is
    /// the moment "background" work lands — the test *is* the
    /// interleaving: send, type, then settle reproduces the race
    /// exactly, every run (docs/internals/workers.md).
    pub fn settleWorkers(self: *Harness) !void {
        self.app.runtime.pumpAll();
        try self.afterStep("settle workers", .{});
    }

    /// Answer the oldest parked http request and land the result now.
    /// Requests park in this app's mock under the harness, so the
    /// canned response *is* the network: what the test supplies is
    /// what the app sees, at exactly this moment (docs/testing.md).
    pub fn fulfillHttp(self: *Harness, canned: http.CannedResponse) !void {
        try self.app.services.http.fulfill(canned);
        self.app.runtime.pumpAll();
        try self.afterStep("fulfill http {d}", .{canned.status});
    }

    /// Fail the oldest parked http request with a transport failure
    /// name — the offline case, one call.
    pub fn failHttp(self: *Harness, name: []const u8) !void {
        try self.app.services.http.fail(name);
        self.app.runtime.pumpAll();
        try self.afterStep("fail http {s}", .{name});
    }

    /// Answer the i-th parked request (oldest first) — out-of-order
    /// completion, for writing down the stale-response race: the test
    /// fulfills index 1 before index 0 and the app must cope.
    pub fn fulfillHttpAt(self: *Harness, i: usize, canned: http.CannedResponse) !void {
        try self.app.services.http.fulfillAt(i, canned);
        self.app.runtime.pumpAll();
        try self.afterStep("fulfill http {d}", .{canned.status});
    }

    /// Fail the i-th parked request — fulfillHttpAt's twin.
    pub fn failHttpAt(self: *Harness, i: usize, name: []const u8) !void {
        try self.app.services.http.failAt(i, name);
        self.app.runtime.pumpAll();
        try self.afterStep("fail http {s}", .{name});
    }

    /// Install the test's fake server (see `HttpHandler`) on this
    /// app's mock. It answers nothing by itself: delivery stays an
    /// explicit move, at `settleHttp`.
    pub fn onHttp(self: *Harness, ctx: ?*anyopaque, handler: HttpHandler) void {
        self.app.services.http.setHandler(ctx, handler);
    }

    /// Run the installed handler over this app's parked requests,
    /// oldest first, landing each answer before the next ask — a
    /// callback may issue follow-up requests and the handler sees
    /// those too, to quiescence. Requests the handler declines (null)
    /// stay parked. Loudly refuses to settle without a handler.
    pub fn settleHttp(self: *Harness) !void {
        self.app.services.http.settle() catch |e| {
            if (e == error.NoHttpHandler)
                diag.print("settleHttp without a handler — call onHttp first\n", .{});
            return e;
        };
        try self.afterStep("settle http", .{});
    }

    /// Every http request this app issued, in request order — method
    /// and url, surviving fulfill/fail/cancel. Reads the journaling
    /// mock directly, like `knocks()`: "these requests, in this
    /// order" is an assertion, not a reconstruction from whatever is
    /// still parked.
    pub fn httpJournal(self: *const Harness) []const HttpOp {
        return self.app.services.http.journal();
    }

    /// Assert the most recent clipboard write — "activating this
    /// copyable wrote X", first class. Reads the journaling mock
    /// directly: a copy is sync, there is nothing to settle.
    pub fn expectCopied(self: *Harness, expected: []const u8) !void {
        const copies = self.app.services.clipboard.copies();
        if (copies.len == 0) {
            diag.print("expected \"{s}\" copied, but nothing was\n", .{expected});
            return error.CopiedMismatch;
        }
        const actual = copies[copies.len - 1];
        if (std.mem.eql(u8, actual, expected)) return;
        diag.print("expected \"{s}\" copied, got \"{s}\"\n", .{ expected, actual });
        return error.CopiedMismatch;
    }

    /// Every URL the app handed to the system browser, in order —
    /// external links pressed, or direct `open_url.open` calls. Reads
    /// the journaling mock directly, like `knocks()`: the handoff is
    /// fire-and-forget, so there is nothing to settle and no result to
    /// deliver — the journal is the whole observable effect.
    pub fn urlsOpened(self: *const Harness) []const []u8 {
        return self.app.services.open_url.opens();
    }

    /// Every text the app put on the OS share sheet, in order — direct
    /// `share.show` calls from actions. Reads the journaling mock
    /// directly, like `urlsOpened()`: the handoff is fire-and-forget
    /// and the destination is deliberately unobservable, so the
    /// journal is the whole observable effect.
    pub fn sharesShown(self: *const Harness) []const []u8 {
        return self.app.services.share.shares();
    }

    // ---- deep links ----
    // Inbound URLs the app routes (deep_link.setHandler). One lane: the
    // launch URL is the first deliverDeepLink after init, then any
    // runtime link. Synchronous like the store — the mock routes to the
    // handler on this thread, so there is nothing to settle.

    /// Deliver an inbound URL to the app's registered handler — the
    /// launch URL as the first call, then any runtime link. Emits a trace
    /// step and re-audits, so the screen the handler routed to is
    /// asserted through the a11y snapshot like any other action.
    pub fn deliverDeepLink(self: *Harness, url: []const u8) !void {
        self.app.services.deep_link.deliver(url);
        try self.afterStep("deep link {s}", .{url});
    }

    /// Every URL delivered to this app, in order — including one that
    /// arrived before the app registered a handler (a launch URL nothing
    /// was wired to route yet).
    pub fn deepLinksReceived(self: *const Harness) []const []u8 {
        return self.app.services.deep_link.received();
    }

    // ---- device locale ----
    // The device's BCP 47 tag. Boot state, not an action: `InitOptions
    // .locale` seeds it inside App.init, so the first `build` already
    // reads it — there is no "before the locale arrived" frame to write
    // a test against. `changeLocale` is the OS changing it afterwards,
    // synchronous like the store.

    /// The OS switched the device locale under the running app. Routes
    /// to the registered handler on this thread, then emits a trace step
    /// and re-audits. The audit reads the tree as it stands: a locale
    /// handler re-resolves state and direction, and that reaches the
    /// screen at the next rebuild (a routed app's `navigate`, a device's
    /// next frame) — unlike a deep link, whose handler navigates and so
    /// changes the snapshot on the spot.
    pub fn changeLocale(self: *Harness, tag: []const u8) !void {
        self.app.services.locale.change(tag);
        try self.afterStep("locale {s}", .{tag});
    }

    /// What `locale.tag(&app)` returns right now — the *effective* tag,
    /// after the cap, so an over-long tag reads here as "" exactly as
    /// the app sees it.
    pub fn deviceLocale(self: *const Harness) []const u8 {
        return self.app.services.locale.tag();
    }

    /// Every tag the device reported, in order; `[0]` is always the boot
    /// tag, so "the app never read a locale" and "the app read the empty
    /// one" stay distinguishable.
    pub fn localesSeen(self: *const Harness) []const []u8 {
        return self.app.services.locale.seen();
    }

    // ---- the wall clock ----
    // Boot state like the locale's tag: `InitOptions.clock` seeds the
    // instant inside App.init, so the first action already reads it.
    // Nothing here settles and nothing is delivered — a clock has no
    // handler to route to and nokre has no ticker that could move it —
    // so time passes only where a test says it does.

    /// Move the wall clock under the running app: `clock.now(app)`
    /// answers `ms` later from here on. Signed, because wall time is
    /// not monotonic — a negative delta is the NTP correction a device
    /// really does perform, and an app that subtracts two stamps has to
    /// survive it. Nothing on the app's side runs; the trace step is
    /// there so a trace shows *when* time moved, which is otherwise the
    /// one thing about a run that leaves no mark.
    pub fn advanceClock(self: *Harness, ms: i64) !void {
        self.app.services.clock.advance(ms);
        try self.afterStep("clock {d}ms", .{ms});
    }

    /// What `clock.now(&app)` answers right now.
    pub fn clockNow(self: *const Harness) i64 {
        return self.app.services.clock.now();
    }

    /// How many times the app has asked the time — a count, not a
    /// journal, since a stopped clock answers every read identically.
    /// Zero is assertable and is the point: "this screen is clockless"
    /// is the app-side spelling of what core promises.
    pub fn clockReads(self: *const Harness) usize {
        return self.app.services.clock.reads();
    }

    // ---- sign-in (docs/services.md) ----
    // The browser is a test input: `start` parks in this app's mock and
    // nothing moves until the test says what the user did. The three
    // verbs below are the three things that can happen, and each lands
    // the result now — the app's handler runs, the screen it produced is
    // re-audited, and the trace gets its step.

    /// The browser redirected: hand the app the callback URL it would
    /// have received, and land it. What the app does with the code —
    /// exchange it over `http`, store the refresh token — happens inside
    /// its own handler, so a whole sign-in reads as three calls.
    pub fn completeAuth(self: *Harness, url: []const u8) !void {
        try self.app.services.oauth.complete(url);
        self.app.runtime.pumpAll();
        try self.afterStep("auth callback", .{});
    }

    /// The user dismissed the sheet. A first-class outcome, not an
    /// error: an app that strands its user on a spinner after a
    /// cancelled login fails this test rather than a bug report.
    pub fn cancelAuth(self: *Harness) !void {
        try self.app.services.oauth.cancel();
        self.app.runtime.pumpAll();
        try self.afterStep("auth cancelled", .{});
    }

    /// The session failed by name — `failHttp`'s twin for the flow's
    /// first half.
    pub fn failAuth(self: *Harness, name: []const u8) !void {
        try self.app.services.oauth.fail(name);
        self.app.runtime.pumpAll();
        try self.afterStep("auth failed {s}", .{name});
    }

    /// Every sign-in this app started, in order — the URL it actually
    /// built, the redirect it prepared, the provider it named. For
    /// asserting scopes and the PKCE challenge.
    pub fn authorizations(self: *const Harness) []const oauth.Authorization {
        return self.app.services.oauth.authorizations();
    }

    // ---- purchases (docs/services.md) ----
    // The store is a test input, and the verbs name what a *store* does
    // rather than what an app asked for: a purchase arrives whether or
    // not this launch requested one, which is the whole shape of the
    // service. Seed `InitOptions.iap` with a catalog and queries answer
    // themselves; leave it empty and the two deliver verbs are the store.
    //
    // Named `…Purchase` / `…Products`, never bare "store": that word is
    // secure_store's here, and two services sharing it would read as one.

    /// The store answered the parked catalog query. Prices are strings
    /// the test writes down, so a paywall screen renders byte-identically
    /// every run.
    pub fn deliverProducts(self: *Harness, rows: []const iap.Product) !void {
        self.app.services.iap.deliverProducts(rows);
        self.app.runtime.pumpAll();
        try self.afterStep("products {d}", .{rows.len});
    }

    /// The catalog query failed by name — `failHttp`'s twin for the
    /// paywall's first half, and the case an app most often forgets:
    /// prices that never arrive.
    pub fn failProducts(self: *Harness, name: []const u8) !void {
        self.app.services.iap.failProducts(name);
        self.app.runtime.pumpAll();
        try self.afterStep("products failed {s}", .{name});
    }

    /// A purchase arrived on the stream and landed. Either the answer to
    /// a live payment sheet or an unsolicited one — an Ask-to-Buy
    /// approval, a renewal, a restore replay, an interrupted purchase
    /// redelivered at launch. The app's handler cannot tell the
    /// difference, and neither can this call, on purpose.
    pub fn deliverPurchase(self: *Harness, p: iap.Purchase) !void {
        self.app.services.iap.deliverPurchase(p);
        self.app.runtime.pumpAll();
        try self.afterStep("purchase {s}", .{p.product});
    }

    /// The user dismissed the payment sheet. A first-class outcome, not
    /// an error — `cancelAuth`'s twin, and the same test it earns: an app
    /// that strands its user on a spinner fails here rather than in a
    /// bug report.
    pub fn cancelPurchase(self: *Harness) !void {
        self.app.services.iap.cancelPurchase();
        self.app.runtime.pumpAll();
        try self.afterStep("purchase cancelled", .{});
    }

    /// The purchase failed by name — the declined-card case.
    pub fn failPurchase(self: *Harness, name: []const u8) !void {
        self.app.services.iap.failPurchase(name);
        self.app.runtime.pumpAll();
        try self.afterStep("purchase failed {s}", .{name});
    }

    /// Assert the app told the store the goods were delivered. Until it
    /// does, the store redelivers on every launch — so "the app never
    /// finished the transaction" is the assertion that catches the bug
    /// nobody sees until a refund, and the disposition catches its
    /// sibling: consuming an unlock, or keeping a coin.
    pub fn expectFinished(self: *Harness, transaction: []const u8, disposition: iap.Disposition) !void {
        for (self.app.services.iap.completions()) |c| {
            if (!std.mem.eql(u8, c.transaction, transaction)) continue;
            if (c.disposition == disposition) return;
            diag.print("expected \"{s}\" finished as .{s}, got .{s}\n", .{
                transaction,
                @tagName(disposition),
                @tagName(c.disposition),
            });
            return error.FinishMismatch;
        }
        diag.print("expected \"{s}\" finished, but it never was\n", .{transaction});
        return error.FinishMismatch;
    }

    /// Every `purchase` this app made, in order — the assertion surface
    /// for "the app charged for the wrong SKU".
    pub fn purchases(self: *const Harness) []const iap.Attempt {
        return self.app.services.iap.purchases();
    }

    /// Every catalog query this app made, in order.
    pub fn productQueries(self: *const Harness) []const iap.Query {
        return self.app.services.iap.queries();
    }

    // ---- the store ----
    // Deliberately no onStore handler and no out-of-order surface: a
    // sync store completes at the call — there is nothing to park,
    // reorder, or fulfill (the contrast with fulfillHttpAt is the
    // point; docs/testing.md).

    /// Seed after boot — the token that appears mid-session. Emits a
    /// trace step and re-audits.
    pub fn seedStore(self: *Harness, key: []const u8, value: []const u8) !void {
        try self.store.seed(key, value);
        try self.afterStep("seed store {s}", .{key});
    }

    /// Assert stored state. Reads the fake directly — no app code
    /// runs, no settle: sync means there is nothing to settle.
    pub fn expectStored(self: *Harness, key: []const u8, expected: []const u8) !void {
        const actual = self.store.peek(key) orelse {
            diag.print("expected \"{s}\" stored as \"{s}\", but it is absent\n", .{ key, expected });
            return error.StoredMismatch;
        };
        if (std.mem.eql(u8, actual, expected)) return;
        diag.print("expected \"{s}\" stored as \"{s}\", got \"{s}\"\n", .{ key, expected, actual });
        return error.StoredMismatch;
    }

    pub fn expectStoredAbsent(self: *Harness, key: []const u8) !void {
        const actual = self.store.peek(key) orelse return;
        diag.print("expected no stored \"{s}\", but found \"{s}\"\n", .{ key, actual });
        return error.UnexpectedlyStored;
    }

    /// The keychain locks (or recovers) under the running app; emits
    /// a trace step.
    pub fn setStoreAvailable(self: *Harness, available: bool) !void {
        self.store.available = available;
        try self.afterStep("store available {}", .{available});
    }

    // ---- notices (docs/elements.md) ----
    // The one piece of app state the a11y snapshot cannot speak for.
    // What is *shown* it covers exactly — the banner, the pane's rows,
    // the indicator are all elements — but a quiet notice behind that
    // indicator is pending and unrendered, a title `notify` dropped as a
    // duplicate leaves no mark at all, and dismiss-all is asserted by an
    // absence. So these read the App's own list, the way `knocks()` and
    // `urlsOpened()` read a mock's journal, and for the same reason: it
    // is the whole observable effect.

    /// Every notice pending right now — important ones in front, arrival
    /// order within each group: the order the banner takes its front
    /// from and the pane groups its rows in (`App.notify`). Borrowed
    /// from the app, so it lives until the next notice call.
    pub fn noticesPending(self: *const Harness) []const PendingNotice {
        return self.app.notices.items;
    }

    /// Assert a notice with this title is pending. Titles are the
    /// identity — `notify` dedups on them — so this is the whole of
    /// "was it raised", whether it is showing as the banner, listed in
    /// the pane, or waiting quietly behind the indicator.
    pub fn expectNotified(self: *Harness, title: []const u8) !void {
        for (self.app.notices.items) |n| {
            if (std.mem.eql(u8, n.title, title)) return;
        }
        diag.print("expected a notice titled \"{s}\", but the pending ones are:\n", .{title});
        if (self.app.notices.items.len == 0) diag.print("  (none)\n", .{});
        for (self.app.notices.items) |n| {
            diag.print("  {s} \"{s}\"\n", .{ if (n.important) "important" else "quiet    ", n.title });
        }
        return error.NoticeMismatch;
    }

    /// The app dismissed one notice, by title — `App.dismissNoticeAt`
    /// reached the way a test can name it. Named, never indexed: an
    /// index is a position in a list the user does not perceive, and the
    /// titles are already unique. Dismissing a notice a *user* would
    /// dismiss is a press like any other — `tapLabel("Dismiss: …")` on
    /// the control the chrome puts on every notice — and this is its
    /// app-side twin, the notice that clears itself when the state
    /// behind it resolves. Emits a trace step and re-audits, so the
    /// chrome the dismissal reshaped is asserted like any other screen.
    pub fn dismissNotice(self: *Harness, title: []const u8) !void {
        for (self.app.notices.items, 0..) |n, i| {
            if (!std.mem.eql(u8, n.title, title)) continue;
            self.app.dismissNoticeAt(i);
            return self.afterStep("dismiss notice {s}", .{title});
        }
        diag.print("expected to dismiss a notice titled \"{s}\", but no such notice is pending\n", .{title});
        return error.NoticeMismatch;
    }

    /// The app cleared the lot — `App.dismissAllNotices`, the header
    /// control's twin. A no-op with nothing pending, like the app call.
    pub fn dismissAllNotices(self: *Harness) !void {
        self.app.dismissAllNotices();
        try self.afterStep("dismiss all notices", .{});
    }

    // ---- assertions ----
    // All state assertions read the a11y snapshot: if the expectation
    // can't be met there, a screen reader user can't meet it either.

    /// The built-in a11y audit. Runs automatically at init and after
    /// every action; call it directly only after mutating the tree by
    /// hand.
    pub fn audit(self: *Harness) !void {
        // This verb shadows the module export inside `Harness`, so the
        // one call that must reach the module names its file.
        try @import("audit.zig").audit(&self.app);
    }

    pub fn a11ySnapshot(self: *Harness, gpa: std.mem.Allocator) !semantics.Snapshot {
        return semantics.snapshot(gpa, &self.app);
    }

    pub fn expectFocused(self: *Harness, label: []const u8) !void {
        const actual = self.focusedLabel();
        if (std.mem.eql(u8, actual, label)) return;
        diag.print("expected focus on \"{s}\", but focus is on \"{s}\"\n", .{ label, actual });
        return error.FocusMismatch;
    }

    pub fn expectChecked(self: *Harness, label: []const u8, expected: bool) !void {
        var snap = try self.a11ySnapshot(self.app.gpa);
        defer snap.deinit();
        const node = snap.findByLabel(label) orelse
            return queries.noMatch(&self.app.tree, "label", label);
        const actual = node.checked orelse {
            diag.print("\"{s}\" is a {s}; it has no checked state\n", .{ label, @tagName(node.role) });
            return error.NotCheckable;
        };
        if (actual != expected) {
            diag.print("expected \"{s}\" checked={}, got checked={}\n", .{ label, expected, actual });
            return error.CheckedMismatch;
        }
    }

    /// Text-input value or the selected option of a choice control
    /// (segmented, radio group).
    pub fn expectValue(self: *Harness, label: []const u8, expected: []const u8) !void {
        var snap = try self.a11ySnapshot(self.app.gpa);
        defer snap.deinit();
        const node = snap.findByLabel(label) orelse
            return queries.noMatch(&self.app.tree, "label", label);
        if (std.mem.eql(u8, node.value, expected)) return;
        diag.print("expected \"{s}\" value \"{s}\", got \"{s}\"\n", .{ label, expected, node.value });
        return error.ValueMismatch;
    }

    pub fn expectRoute(self: *Harness, route: []const u8) !void {
        const actual = self.app.router.current() orelse {
            diag.print("expected route \"{s}\", but no route is active\n", .{route});
            return error.RouteMismatch;
        };
        if (std.mem.eql(u8, actual, route)) return;
        diag.print("expected route \"{s}\", got \"{s}\"\n", .{ route, actual });
        return error.RouteMismatch;
    }

    pub fn expectAbsent(self: *Harness, label: []const u8) !void {
        const id = queries.queryByLabel(&self.app.tree, label) orelse return;
        const el = self.app.tree.getConst(id).?;
        diag.print("expected no element labeled \"{s}\", but found a {s}\n", .{ label, @tagName(el.role()) });
        return error.UnexpectedlyPresent;
    }

    /// Inline snapshot of the whole laid-out tree in the trace format
    /// (see docs/testing.md). On mismatch both trees are printed — copy
    /// the actual into the test once you've reviewed it.
    pub fn expectTree(self: *Harness, expected: []const u8) !void {
        var actual: std.ArrayList(u8) = .empty;
        defer actual.deinit(self.app.gpa);
        try trace.dump(self.app.gpa, &actual, &self.app);
        const a = std.mem.trim(u8, actual.items, "\n");
        const e = std.mem.trim(u8, expected, "\n");
        if (std.mem.eql(u8, a, e)) return;
        diag.print("tree mismatch\n---- expected ----\n{s}\n---- actual ----\n{s}\n------------------\n", .{ e, a });
        return error.TreeMismatch;
    }

    /// Renders through the production renderer into any canvas — pass a
    /// Skia surface canvas for golden tests, a recording canvas for
    /// structural assertions.
    pub fn renderTo(self: *Harness, canvas: canvas_mod.Canvas) void {
        renderer.render(&self.app, canvas);
    }
};
