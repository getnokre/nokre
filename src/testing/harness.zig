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
const notification = @import("../services/notification/notification.zig");

/// The two ends of the back gesture's threshold, for asserting against
/// `knocks()`. Re-exported here and nowhere else: the haptic service has
/// no consumer verb (docs/internals/haptics.md), so `nokre.services`
/// deliberately does not carry it — a test needs the type, an app needs
/// nothing at all.
pub const Knock = haptic.Knock;

pub const diag = @import("diag.zig");
pub const queries = @import("queries.zig");
pub const driver = @import("driver.zig");
/// Deadline-bounded waiting for the driver tier — `wait.waitUntil`,
/// the `until*` predicates nokre can evaluate for itself, and the
/// `Pacer` a driver hands its own clock in with. Not a harness verb on
/// purpose: under the mocks nothing ever waits (see wait.zig's own
/// rationale).
pub const wait = @import("wait.zig");
/// The driver tier's verb set: this harness's names and this harness's
/// ladders, with a wait in front of each, over a live `App` and no
/// mock anywhere. `testing.Device` is what a driver holds where a test
/// holds a `Harness` (docs/testing.md, "Driving an app outside
/// `zig test`").
pub const device = @import("device.zig");
pub const Device = device.Device;
pub const audit = @import("audit.zig");
pub const golden = @import("golden.zig");
pub const trace = @import("trace.zig");
/// The driver tier's shell: the C hooks a headless binary owes,
/// exported once here instead of hand-written per driver. Analyzed —
/// and therefore linked — only when a root names it
/// (`comptime { _ = nokre.testing.shell; }`); see its own doc comment.
pub const shell = @import("shell.zig");

const App = app_mod.App;
const NodeId = tree_mod.NodeId;

/// A fixture's screen is a route's screen, so it is the same type — one
/// home (`RouteDef.Build`), and `Routes(State).builder` types a fixture's
/// exactly as it types a table's.
pub const BuildFn = router_mod.RouteDef.Build;

/// The http mock's own types, re-exported so harness users read one
/// import: a handler decides respond/fail/null per parked request —
/// null leaves it parked for the test to answer by hand.
pub const HttpOutcome = http.Outcome;
pub const HttpHandler = http.Handler;
pub const HttpOp = http.Op;

/// What `expectRequest` checks a parked request against. Every field
/// is optional, and `.{}` — the whole assertion being "this path was
/// asked at all" — is the commonest spelling.
///
/// The set is what real suites assert, and no more: a body is either
/// pinned whole or probed for the fragments that carry the decision,
/// and a header is either an exact pair, a name that must have ridden
/// along (a proof-of-work nonce, whose value is random), or a name
/// that must not have (the `Authorization` an anonymous submission
/// must never carry — an assertion that is load-bearing, not
/// decorative). Lists, not single values, because one request routinely
/// earns several: seven body fragments and four headers is a real
/// call site, and a per-field verb would be seven calls.
pub const RequestExpectation = struct {
    method: ?http.Method = null,
    /// The whole body, byte for byte.
    body: ?[]const u8 = null,
    /// Fragments the body must carry — for the request assembled from
    /// several screens' worth of fields, where pinning it whole would
    /// pin the serializer's key order too.
    body_contains: []const []const u8 = &.{},
    /// Fragments it must not: the field this form deliberately omits.
    body_excludes: []const []const u8 = &.{},
    /// Headers by name and exact value.
    headers: []const http.Header = &.{},
    /// Headers that must be there, whatever they say.
    headers_present: []const []const u8 = &.{},
    /// Headers that must not be there at all.
    headers_absent: []const []const u8 = &.{},
};

/// One pending notice as the app holds it — `title()`, `description()`,
/// `route()` (inline ring-slot storage, read through the accessors),
/// icon, and whether it is important. Re-exported so a test asserting on
/// `noticesPending()` reads one import, `Knock`'s rationale for a type
/// only tests name.
pub const PendingNotice = notices_mod.OwnedNotice;

pub const InitOptions = struct {
    ctx: ?*anyopaque = null,
    build: ?BuildFn = null, // plain screen…
    routes: []const router_mod.RouteDef = &.{}, // …or routed (exactly one of build/routes)
    nav: []const nav_mod.Destination = &.{},
    initial_route: []const u8 = "", // with routes: the first screen, or "" to defer — a fixture that must wire consumer state before the first build navigates itself
    store: secure_store.Mock.Config = .{},
    http: http.Mock.Config = .{}, // the app's fake server, live from the first request
    locale: locale.Mock.Config = .{}, // the device tag at boot; "" is "the platform said nothing"
    clock: clock.Mock.Config = .{}, // the wall clock at boot; the default is a fixed, obviously fake instant
    oauth: oauth.Mock.Config = .{}, // the PKCE seeds, and optionally what the browser does
    iap: iap.Mock.Config = .{}, // the store's shelf, and whether there is a store at all
    share: share.Mock.Config = .{}, // whether this boot has a share sheet at all
    notification: notification.Mock.Config = .{}, // the authorization state at boot, and whether this device notifies or pushes at all
};

pub const Harness = struct {
    app: App,
    /// This app's whole secure store — the app-owned fake, aliased for
    /// assertion ergonomics (t.store.journal()); dead with the app at
    /// deinit so nothing leaks to the next test.
    store: *secure_store.Fake,
    step_observer: ?trace.StepObserver = null,
    step_index: u32 = 0,

    /// The one construction door: everything a boot can vary — screen
    /// or routes, nav, seeded services — is a field of `InitOptions`,
    /// so there is exactly one way to spell every boot and nothing to
    /// choose between. The app is constructed with its mocks —
    /// `opts.store` and `opts.locale` apply inside App.init, before
    /// `build`/`navigate` runs, so a boot-time read sees the seeded
    /// state synchronously.
    pub fn init(gpa: std.mem.Allocator, viewport: geometry.Size, opts: InitOptions) !Harness {
        if ((opts.build == null) == (opts.routes.len == 0)) {
            diag.print("init needs exactly one of build/routes\n", .{});
            return error.InitOptionsShape;
        }
        var self: Harness = .{
            .app = try App.init(gpa, .{
                .viewport = viewport,
                .routes = opts.routes,
                .ctx = opts.ctx,
                .services = .{
                    .secure_store = .mock(opts.store),
                    .http = .mock(opts.http),
                    .locale = .mock(opts.locale),
                    .clock = .mock(opts.clock),
                    .oauth = .mock(opts.oauth),
                    .iap = .mock(opts.iap),
                    .share = .mock(opts.share),
                    .notification = .mock(opts.notification),
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
            // "" defers the first navigation to the caller: a consumer
            // fixture wires its state against the constructed app first,
            // so the first build never reads a state that has no app yet
            // — main's own order.
            if (opts.initial_route.len != 0) try self.app.navigate(opts.initial_route);
        }
        try self.audit();
        return self;
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

    /// Chooses an option in a `segmented`, `radio_group`, or `select`,
    /// both named: the control by its label, the option by the words on
    /// it. The keyboard route, through real dispatch — see
    /// `driver.selectOption` for why that one and not a tap.
    pub fn selectOption(self: *Harness, group_label: []const u8, option: []const u8) !void {
        const id = try self.getByLabel(group_label);
        try driver.selectOption(&self.app, id, option);
        try self.afterStep("select {s}", .{option});
    }

    pub fn focusVia(self: *Harness, id: NodeId) !void {
        try driver.focusVia(&self.app, id);
        try self.afterStep("focus {s}", .{self.labelOf(id)});
    }

    // ---- the verbs above the primitives ----
    // Four ladders — `press`, `typeInto`, `clearField`, `goTab` — that
    // both shipped apps grew over the primitives above before they
    // moved into the framework. The ladders themselves live in
    // `driver.zig`, mock-free, because a *driver* holding a live `App`
    // needs the same four and cannot see a `Harness` (a mock exists
    // only under `builtin.is_test`). What this tier adds is what a
    // harness always adds: one trace step and one re-audit per action.
    // `testing.Device` is the same four with a wait in front of each.

    /// Presses a control the way a user would: a tap where the control
    /// is on screen, the keyboard where a long screen has pushed it
    /// past the fold, and More-then-the-action where a narrow row
    /// folded it away. Not for text fields — the keyboard fallback's
    /// Enter in a field it just focused is a submit, not a focus;
    /// `typeInto` is the field verb.
    pub fn press(self: *Harness, role: element_mod.Role, label: []const u8) !void {
        try driver.press(&self.app, role, label);
        try self.afterStep("press {s}", .{label});
    }

    /// Puts the caret in a named field and types, the way a user fills
    /// one — appending to what the field already holds, exactly as
    /// typing does. The label is looked up among the two text-entry
    /// roles only, so the words can never land on a control that
    /// merely shares them.
    pub fn typeInto(self: *Harness, label: []const u8, bytes: []const u8) !void {
        try driver.typeInto(&self.app, label, bytes);
        try self.afterStep("type into {s}", .{label});
    }

    /// Empties a named field the way a user empties one: to the end,
    /// then back over what is there. `clearField` then `typeInto` is
    /// how a test says "leave this field holding exactly this" — the
    /// shape a screen revisited with a value already in it needs, and
    /// the one a driver against a real server needs constantly.
    pub fn clearField(self: *Harness, label: []const u8) !void {
        try driver.clearField(&self.app, label);
        try self.afterStep("clear {s}", .{label});
    }

    /// Crosses the nav to the destination with this title, whichever
    /// shape the nav is in: the collapsed chip's picker where the
    /// labels did not fit, the row of destinations where they did, and
    /// the `nav_here` marker when the title is the screen already under
    /// foot — that marker is deliberately not a control (element.zig),
    /// so "go where you stand" is the no-op it is for a user. The chip
    /// is named by the app's chrome, so a localized app crosses its
    /// bar in its own words.
    pub fn goTab(self: *Harness, title: []const u8) !void {
        try driver.goTab(&self.app, title);
        try self.afterStep("go to {s}", .{title});
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

    /// Answer the oldest parked request whose URL ends in `suffix`.
    /// Tests name a request by its path, not its queue position — the
    /// position encodes issue order, which is the app's business, not
    /// the test's. On a miss the parked URLs are printed, so the
    /// diagnostic says what *was* in flight.
    pub fn fulfillHttpPath(self: *Harness, suffix: []const u8, canned: http.CannedResponse) !void {
        try self.fulfillHttpAt(try self.httpIndexOf(suffix, .oldest), canned);
    }

    /// fulfillHttpPath's newest-match twin, for the screen that asks
    /// the same endpoint twice: the sweep behind it owns the oldest
    /// ask, the screen the newest.
    pub fn fulfillHttpLastPath(self: *Harness, suffix: []const u8, canned: http.CannedResponse) !void {
        try self.fulfillHttpAt(try self.httpIndexOf(suffix, .newest), canned);
    }

    /// Fail the oldest parked request whose URL ends in `suffix` —
    /// fulfillHttpPath's failure twin.
    pub fn failHttpPath(self: *Harness, suffix: []const u8, name: []const u8) !void {
        try self.failHttpAt(try self.httpIndexOf(suffix, .oldest), name);
    }

    /// Index of the parked request whose URL ends in `suffix`, or a
    /// loud miss listing everything parked. `.newest` falls back to
    /// the oldest scan only through the shared miss path, so both
    /// directions fail identically.
    pub fn httpIndexOf(self: *Harness, suffix: []const u8, which: enum { oldest, newest }) !usize {
        const mock = &self.app.services.http;
        const n = mock.pendingCount();
        switch (which) {
            .oldest => for (0..n) |i| {
                if (std.mem.endsWith(u8, mock.pendingAt(i).url, suffix)) return i;
            },
            .newest => {
                var i = n;
                while (i > 0) {
                    i -= 1;
                    if (std.mem.endsWith(u8, mock.pendingAt(i).url, suffix)) return i;
                }
            },
        }
        diag.print("no parked request ending in \"{s}\"; in flight:\n", .{suffix});
        self.printParked();
        return error.NoSuchRequest;
    }

    /// Every parked request, method and URL, one per line — the tail
    /// every miss in this family prints, so "what was actually in
    /// flight" reads the same however the test asked. Nothing parked
    /// says so in words: a heading followed by silence is the
    /// two-integer failure in miniature.
    fn printParked(self: *const Harness) void {
        const mock = &self.app.services.http;
        const n = mock.pendingCount();
        if (n == 0) return diag.print("  (nothing is parked)\n", .{});
        for (0..n) |i| {
            const p = mock.pendingAt(i);
            diag.print("  {s} {s}\n", .{ @tagName(p.method), p.url });
        }
    }

    // ---- the observing side ----
    // `fulfillHttpPath` answers a request by name; these read one, and
    // name it the same way — the URL's tail, never the queue position,
    // because the position encodes issue order, which is the app's
    // business. Every refusal here ends in the parked listing above:
    // an assertion whose failure prints two integers has told the
    // reader nothing about the run that produced them.

    /// How many requests are parked — all of them (`null`), or just
    /// the ones whose URL ends in `suffix`. A query, not an assertion:
    /// `expectNoPendingHttp` and `expectNoRequest` are the loud forms
    /// and are what a test asserting emptiness should reach for. This
    /// is for the arithmetic they cannot say — "the retry asked once,
    /// not once per attempt" — and for the before/after pair that
    /// pins an action as issuing nothing.
    pub fn httpPending(self: *const Harness, suffix: ?[]const u8) usize {
        const mock = &self.app.services.http;
        // No filter is the empty tail: every URL ends in nothing, so
        // "all of them" needs no branch of its own.
        const tail = suffix orelse "";
        var found: usize = 0;
        for (0..mock.pendingCount()) |i| {
            if (std.mem.endsWith(u8, mock.pendingAt(i).url, tail)) found += 1;
        }
        return found;
    }

    /// Nothing at all is in flight — the assertion that closes a test
    /// which meant to answer everything it asked. The loud twin of a
    /// bare count: a failed `expectEqual(0, pendingCount())` prints
    /// two integers, and the one that matters is the request nobody
    /// expected, so this names each of them instead.
    pub fn expectNoPendingHttp(self: *Harness) !void {
        if (self.app.services.http.pendingCount() == 0) return;
        diag.print("expected nothing in flight, but these are parked:\n", .{});
        self.printParked();
        return error.PendingHttp;
    }

    /// Nothing was sent to this path — `expectRequest`'s negative
    /// twin, the assertion behind "the screen refused, so no call
    /// left". The matches are printed, because they are the surprise;
    /// `expectAbsent` names what it found for the same reason.
    pub fn expectNoRequest(self: *Harness, suffix: []const u8) !void {
        const mock = &self.app.services.http;
        var found = false;
        for (0..mock.pendingCount()) |i| {
            const p = mock.pendingAt(i);
            if (!std.mem.endsWith(u8, p.url, suffix)) continue;
            if (!found) diag.print("expected nothing parked for \"{s}\", but these are:\n", .{suffix});
            found = true;
            diag.print("  {s} {s}\n", .{ @tagName(p.method), p.url });
        }
        if (found) return error.UnexpectedRequest;
    }

    /// The request this action should have sent, named by the tail of
    /// its URL and checked against what it carried. Every field is
    /// optional and an empty expectation is the whole assertion "this
    /// path was asked at all", which is the commonest form of it.
    ///
    /// Pass the *whole* URL as the suffix and the locator is also the
    /// assertion — a full URL is a suffix of itself and of nothing
    /// else — so "the app asked exactly this address" needs no second
    /// call and no second spelling.
    pub fn expectRequest(self: *Harness, suffix: []const u8, expect: RequestExpectation) !void {
        const req = try self.httpRequest(suffix);
        if (expect.method) |want| {
            if (req.method != want) return mismatch(req, "expected method {s}\n", .{@tagName(want)});
        }
        if (expect.body) |want| {
            if (!std.mem.eql(u8, req.body, want)) {
                // Two bodies on one line are unreadable at JSON
                // lengths, so the block form — expectTree's, for the
                // same reason.
                diag.print("{s} {s}: body mismatch\n---- expected ----\n{s}\n---- actual ----\n{s}\n------------------\n", .{
                    @tagName(req.method), req.url, want, req.body,
                });
                return error.RequestMismatch;
            }
        }
        for (expect.body_contains) |needle| {
            if (std.mem.indexOf(u8, req.body, needle) == null)
                return mismatch(req, "expected the body to contain \"{s}\", but it is {s}\n", .{ needle, req.body });
        }
        for (expect.body_excludes) |needle| {
            if (std.mem.indexOf(u8, req.body, needle) != null)
                return mismatch(req, "expected the body not to mention \"{s}\", but it is {s}\n", .{ needle, req.body });
        }
        for (expect.headers) |want| {
            const got = req.headerValue(want.name) orelse
                return mismatchHeaders(req, "expected \"{s}: {s}\", but no such header rode along", .{ want.name, want.value });
            if (!std.mem.eql(u8, got, want.value))
                return mismatch(req, "expected \"{s}: {s}\", got \"{s}\"\n", .{ want.name, want.value, got });
        }
        for (expect.headers_present) |name| {
            if (req.headerValue(name) == null)
                return mismatchHeaders(req, "expected a \"{s}\" header", .{name});
        }
        for (expect.headers_absent) |name| {
            if (req.headerValue(name)) |got|
                return mismatch(req, "expected no \"{s}\" header, but it carries \"{s}\"\n", .{ name, got });
        }
    }

    /// Every failure above names the request first: which call this
    /// was is half of what the reader needs, and the queue position
    /// they did not write down cannot supply it.
    fn mismatch(req: http.PendingRequest, comptime fmt: []const u8, args: anytype) error{RequestMismatch} {
        diag.print("{s} {s}: ", .{ @tagName(req.method), req.url });
        diag.print(fmt, args);
        return error.RequestMismatch;
    }

    /// A header expectation that found nothing lists the names the
    /// request *does* carry — the queries' "here is what does exist",
    /// which is what turns a typo'd header name into a one-look fix.
    fn mismatchHeaders(req: http.PendingRequest, comptime fmt: []const u8, args: anytype) error{RequestMismatch} {
        diag.print("{s} {s}: ", .{ @tagName(req.method), req.url });
        diag.print(fmt, args);
        if (req.headers.len == 0) {
            diag.print("; it carries no headers at all\n", .{});
        } else {
            diag.print("; it carries:\n", .{});
            for (req.headers) |h| diag.print("  {s}\n", .{h.name});
        }
        return error.RequestMismatch;
    }

    /// The parked request whose URL ends in `suffix`, oldest first —
    /// for the assertion no expectation field can spell: a digest over
    /// the body, a header parsed as a number, the proof-of-work a
    /// server would verify. A miss is `httpIndexOf`'s loud one,
    /// because it is the same refusal.
    ///
    /// **Peeks.** The request stays parked and the borrowed slices
    /// stay valid until it is answered — which is the point: reading
    /// what was sent is what a test does immediately *before*
    /// answering it. Taking it out of the queue instead would leave
    /// the app waiting on a result that can never arrive, with the
    /// screen's `in_progress` up forever and nothing to say so.
    pub fn httpRequest(self: *Harness, suffix: []const u8) !http.PendingRequest {
        return self.app.services.http.pendingAt(try self.httpIndexOf(suffix, .oldest));
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

    /// Every http request this app issued, in request order — method,
    /// url, and tag, surviving fulfill/fail/cancel. Reads the journaling
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

    // ---- notifications ----
    // Two directions, like the service: what the app asked the OS to do
    // is journaled and asserted; what the *user* did is a verb the test
    // fires. Boot state — whether this device notifies or pushes at all,
    // and whether permission was already granted — is `InitOptions
    // .notification`, seeded inside App.init so the first `build` reads
    // the real answer (the locale tag's rule).

    /// The user allowed notifications: by answering a prompt the app
    /// raised, or by turning them on in Settings. Routes to the
    /// registered handler on this thread, then emits a trace step and
    /// re-audits — a notification handler commonly navigates, and that
    /// reaches the tree.
    pub fn grantNotifications(self: *Harness) !void {
        self.app.services.notification.grant();
        try self.afterStep("notifications granted", .{});
    }

    /// The user refused, or revoked in Settings while the app ran.
    pub fn denyNotifications(self: *Harness) !void {
        self.app.services.notification.deny();
        try self.afterStep("notifications denied", .{});
    }

    /// The user tapped a notification — including the tap that launched
    /// the app, which a test writes by calling this first. Takes the
    /// service's own `Payload`, so id and route cannot be swapped.
    pub fn deliverNotificationTap(self: *Harness, payload: notification.Payload) !void {
        self.app.services.notification.open(payload);
        try self.afterStep("notification tapped {s}", .{payload.id});
    }

    /// A notification came due with the app on screen — a scheduled one
    /// firing mid-session, or a push arriving during use. No OS banner is
    /// drawn for it, so the event is the whole delivery.
    pub fn deliverNotification(self: *Harness, payload: notification.Payload) !void {
        self.app.services.notification.arrive(payload);
        try self.afterStep("notification arrived {s}", .{payload.id});
    }

    /// The push transport minted (or rotated) this device's token.
    pub fn deliverPushToken(self: *Harness, token: []const u8) !void {
        self.app.services.notification.deliverToken(token);
        try self.afterStep("push token delivered", .{});
    }

    /// Everything the app asked the OS to do, in order — posts,
    /// schedules, cancels, the permission prompt, and the token request.
    /// A refused call journals nothing, because the OS was never asked.
    pub fn notificationsRequested(self: *const Harness) []const notification.Entry {
        return self.app.services.notification.entries();
    }

    /// Whether the app ever raised the permission prompt — the assertion
    /// behind "this screen posted without asking".
    pub fn askedToNotify(self: *const Harness) bool {
        return self.app.services.notification.askedForAuthorization();
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

    /// The keychain locks under the running app; emits a trace step.
    /// Named for the event, like `denyNotifications` — a bare bool at
    /// the call site reads as nothing in particular.
    pub fn lockStore(self: *Harness) !void {
        self.store.available = false;
        try self.afterStep("store locked", .{});
    }

    /// The keychain recovers.
    pub fn unlockStore(self: *Harness) !void {
        self.store.available = true;
        try self.afterStep("store unlocked", .{});
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
        for (self.app.notices.items) |*n| {
            if (std.mem.eql(u8, n.title(), title)) return;
        }
        diag.print("expected a notice titled \"{s}\", but the pending ones are:\n", .{title});
        if (self.app.notices.items.len == 0) diag.print("  (none)\n", .{});
        for (self.app.notices.items) |*n| {
            diag.print("  {s} \"{s}\"\n", .{ if (n.important) "important" else "quiet    ", n.title() });
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
        for (self.app.notices.items, 0..) |*n, i| {
            if (!std.mem.eql(u8, n.title(), title)) continue;
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

    /// Whatever this control's a11y node reports as its *value*, which
    /// is more than a field's text: the selected option of a choice
    /// control, a tile's detail line, the string a `copyable` puts on
    /// the clipboard, the URL a `qr` encodes, the section a collapsed
    /// nav chip stands on (`a11y/semantics.zig`). If a screen reader
    /// would announce it as the value, this is how a test reads it —
    /// reaching into `tree.getConst(id).?.tile.detail` asserts the same
    /// bytes through a door the audit does not watch.
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

    /// `expectAbsent`'s positive twin, by semantic identity: the
    /// discarded `getByRole` is the assertion, and a miss lists every
    /// labeled node on screen — presence claimed by role plus name,
    /// never by a bare label.
    pub fn expectPresent(self: *Harness, role: element_mod.Role, name: []const u8) !void {
        _ = try self.getByRole(role, name);
    }

    /// A control that declines rather than acts. Read off the node
    /// instead of pressed: `tap` refuses a disabled control loudly,
    /// and a diagnostic from a passing test reads as a failure to
    /// whoever is watching the build. Buttons only — the one element
    /// that carries `disabled` (element.zig); everything else declines
    /// by not being built.
    pub fn expectDisabled(self: *Harness, label: []const u8) !void {
        const id = try self.getByRole(.button, label);
        const el = self.app.tree.getConst(id).?;
        if (el.button.disabled) return;
        diag.print("expected \"{s}\" disabled, but it takes presses\n", .{label});
        return error.DisabledMismatch;
    }

    /// `expectDisabled`'s twin: a control that has become live. Not
    /// the same as pressing it — "filling the last field armed Save"
    /// is an assertion about the form, and a test that proved it by
    /// pressing would have submitted the form to prove it.
    pub fn expectEnabled(self: *Harness, label: []const u8) !void {
        const id = try self.getByRole(.button, label);
        const el = self.app.tree.getConst(id).?;
        if (!el.button.disabled) return;
        diag.print("expected \"{s}\" to take presses, but it is disabled\n", .{label});
        return error.EnabledMismatch;
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

    /// Takes a golden of this app's frame: a Skia surface at the
    /// viewport, the real Skia measurer swapped in — the fixed
    /// measurer's glyph positions match no device — one render, and a
    /// byte-exact comparison against the PPM at `sub_path`
    /// (`golden.expectMatchesIn`'s contract; thread the consumer
    /// build's `-Dupdate-goldens` in as `.update`). Assertions after
    /// this call see Skia metrics, as a device would.
    ///
    /// Skia is imported here and nowhere else in the harness, so a
    /// suite that never takes a golden stays headless-pure and links
    /// nothing; a suite that does needs the prebuilt on its test binary
    /// (`nokre.linkSkia` in the consumer's build.zig).
    pub fn expectGolden(self: *Harness, sub_path: []const u8, opts: golden.Options) !void {
        const skia = @import("../render/skia/canvas_skia.zig");
        self.app.setMeasurer(skia.measurer());
        var surface = try skia.Surface.init(self.app.viewport.w, self.app.viewport.h, 1);
        defer surface.deinit();
        self.renderTo(surface.canvas());
        try golden.expectMatches(self.app.gpa, surface.pixels(), surface.pixelWidth(), surface.pixelHeight(), sub_path, opts);
    }
};
