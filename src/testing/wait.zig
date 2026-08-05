//! Deadline-bounded waiting, for the driver tier only.
//!
//! Under the harness nothing ever waits: every mock settles at a verb
//! (`settleWorkers`, `settleHttp`, `fulfillHttp`), so a harness test
//! that polled would be rehearsing a race the mocks cannot produce.
//! A *driver* — an ordinary executable holding a real `App` against
//! real transports (docs/testing.md, "Driving an app outside
//! `zig test`") — has no settle verb, because a real server answers
//! when it answers. Its whole synchronization story is "pump until the
//! screen says what it came to say, or a deadline passes", and before
//! this module every driver hand-wrote that loop once per thing it
//! could wait for.
//!
//! nokre itself reads no clock and sleeps no thread here — that would
//! smuggle wall-clock nondeterminism into a library whose tests are
//! deterministic to the byte. The driver owns the real transports, so
//! the driver owns real time: it hands both reads and naps in as a
//! `Pacer`, and a test of this module hands in a fake one, which is
//! how a deadline failure is itself testable without waiting.

const std = @import("std");
const bind = @import("../core/bind.zig");
const diag = @import("diag.zig");
const driver = @import("driver.zig");
const queries = @import("queries.zig");
const semantics = @import("../a11y/semantics.zig");
const trace = @import("trace.zig");
const app_mod = @import("../core/app.zig");
const element_mod = @import("../core/element.zig");
const tree_mod = @import("../core/tree.zig");

const App = app_mod.App;
const NodeId = tree_mod.NodeId;
const Role = element_mod.Role;

/// The driver's time, injected. `now_ms` is whatever clock the driver
/// already bounds its run with; `nap` yields between polls so the
/// transport threads this wait is waiting on get the core.
pub const Pacer = struct {
    ctx: ?*anyopaque = null,
    now_ms: *const fn (ctx: ?*anyopaque) i64,
    nap: *const fn (ctx: ?*anyopaque, ns: u64) void,
    /// How long a screen has to answer. The shipped drivers' figure: a
    /// leg there is a proof of work, a round trip and a rebuild.
    timeout_ms: i64 = 60_000,
    /// How long to yield between polls.
    poll_ns: u64 = 200 * std.time.ns_per_us,

    /// The driver's clock, read. Public because a driver's own bounded
    /// loops — and `Device.quiesce` — run on the same clock this
    /// module's deadlines do, and two clocks in one run is one clock
    /// too many.
    pub fn nowMs(self: Pacer) i64 {
        return self.now_ms(self.ctx);
    }

    /// One poll's worth of yielding, so the transport threads a wait is
    /// waiting on get the core.
    pub fn rest(self: Pacer) void {
        self.nap(self.ctx, self.poll_ns);
    }
};

/// What a wait watches: asked once per pump, against the app as it
/// stands. Return true to end the wait.
///
/// A `{ ctx, call }` pair rather than a bare function pointer, because
/// the interesting predicates are about *app state* the framework
/// cannot see — "the proof-of-work queue is empty", "the prefetch
/// sweep finished" — and a bare pointer made every one of those a
/// hand-written `struct { fn check(ctx: ?*anyopaque, app: *App) bool }`
/// wrapper around an `@ptrCast`. The pair is the shape `nokre.bindAs`
/// fills (core/bind.zig), so an ordinary method on the driver's own
/// state becomes a predicate with no cast at all:
///
/// ```zig
/// // fn quiet(self: *State, _: *nokre.App) bool { return self.solver.pending() == 0; }
/// try wait.waitUntil(&app, pacer, "the queue to drain",
///     nokre.bindAs(wait.Ready, State.quiet, &state));
/// ```
pub const Ready = struct {
    ctx: ?*anyopaque = null,
    call: *const fn (ctx: ?*anyopaque, app: *App) bool,

    fn holds(self: Ready, app: *App) bool {
        return self.call(self.ctx, app);
    }
};

/// Pumps the delivery queue until `ready` holds or the pacer's deadline
/// passes. On timeout it prints what was waited for (`what`, the
/// caller's words) and the whole screen as it stands — the dump that
/// turns "waited 60000ms" into a diagnosis — then returns
/// `error.WaitTimeout`. The predicate runs after each pump, so a result
/// that is already on screen returns without a single nap.
pub fn waitUntil(app: *App, pacer: Pacer, what: []const u8, ready: Ready) error{WaitTimeout}!void {
    const deadline = pacer.nowMs() + pacer.timeout_ms;
    while (true) {
        _ = app.runtime.pump();
        if (ready.holds(app)) return;
        if (pacer.nowMs() > deadline) {
            diag.print("waited {d}ms for {s}; the screen stands at:\n", .{ pacer.timeout_ms, what });
            dumpScreen(app);
            return error.WaitTimeout;
        }
        pacer.rest();
    }
}

// ---- the predicates nokre can evaluate for itself ----
//
// Everything below is `waitUntil` with a condition the framework can
// answer off its own tree, router and notice list. They are here rather
// than in each driver because both shipped drivers wrote all seven, in
// the same order, with the same `@ptrCast` plumbing and the same
// diagnostic wording — ~110 lines apiece of a thing with exactly one
// correct implementation. A driver's own predicates (its ports, its
// phases, its work queue) stay its own, and reach `waitUntil` through
// `Ready`.
//
// Each answers what it found, so the wait and the lookup are one call:
// the predicate held on the last pump, so the query that follows it
// cannot miss.

/// How much of a formatted `what` a timeout prints. Long enough for a
/// role and a screen's worth of words; a longer one truncates to the
/// bare needle rather than failing a wait over its own diagnostic.
const what_cap = 256;

fn describe(buf: []u8, comptime fmt: []const u8, args: anytype, fallback: []const u8) []const u8 {
    return std.fmt.bufPrint(buf, fmt, args) catch fallback;
}

/// One label, five questions. The predicates are methods so `bindAs`
/// can make the pair — the same door a driver's own state uses, proved
/// here rather than only documented.
const Label = struct {
    text: []const u8,

    fn present(self: *Label, app: *App) bool {
        return queries.queryByLabel(&app.tree, self.text) != null;
    }

    fn gone(self: *Label, app: *App) bool {
        return queries.queryByLabel(&app.tree, self.text) == null;
    }

    fn containing(self: *Label, app: *App) bool {
        return queries.queryByLabelContaining(&app.tree, self.text) != null;
    }

    fn routed(self: *Label, app: *App) bool {
        const current = app.router.current() orelse return false;
        return std.mem.eql(u8, current, self.text);
    }

    fn notified(self: *Label, app: *App) bool {
        for (app.notices.items) |*n| {
            if (std.mem.eql(u8, n.title(), self.text)) return true;
        }
        return false;
    }
};

/// A name under any of a set of roles. A set, not one role, because
/// the acting verbs address control *families*: a field is a
/// `text_input` or a `text_area`, a choice is a `segmented`, a
/// `radio_group` or a `select`, and a wait that named only one of them
/// would return the moment a *label* element with the same words
/// arrived — leaving the verb to fail loudly on a control that was
/// still on its way.
const Named = struct {
    roles: []const Role,
    name: []const u8,

    fn found(self: *const Named, app: *App) ?NodeId {
        for (self.roles) |role| {
            if (queries.queryByRole(&app.tree, role, self.name)) |id| return id;
        }
        return null;
    }

    fn present(self: *Named, app: *App) bool {
        return self.found(app) != null;
    }
};

/// The nav bar wearing any of its three shapes. Which one a screen is
/// wearing is layout's decision, not the caller's: the row of
/// destinations where the labels fit, the `nav_here` marker when the
/// title is the screen already under foot (its accessible name is the
/// chrome's, so it is matched on the element's *value*), and the
/// collapsed chip that stands in for the whole roster when nothing
/// fit. A wait that knew only the first would time out on a phone.
const Destination = struct {
    title: []const u8,

    fn present(self: *Destination, app: *App) bool {
        if (queries.queryByRole(&app.tree, .nav_item, self.title) != null) return true;
        if (queries.queryByRole(&app.tree, .nav_current, app.chrome.section) != null) return true;
        var it = app.tree.dfs();
        while (it.next()) |id| {
            const el = app.tree.getConst(id).?;
            if (el.* == .nav_here and std.mem.eql(u8, el.nav_here.value, self.title)) return true;
        }
        return false;
    }
};

/// A control's *state*, not its presence. Waiting for the control and
/// then reading `disabled` off it asserts a state the screen may not
/// have reached yet — "the last field armed Save" is a reply landing,
/// and the control is on screen the whole time it is in flight.
///
/// By label across the kinds that carry `disabled` (`driver.disabledOf`),
/// not by the button role: a form that disables its fields while the
/// submission is on the wire is exactly the screen these waits are for,
/// and the field comes back before the button does.
const Armed = struct {
    name: []const u8,

    fn enabled(self: *Armed, app: *App) bool {
        return self.disabledIs(app, false);
    }

    fn disabled(self: *Armed, app: *App) bool {
        return self.disabledIs(app, true);
    }

    fn disabledIs(self: *const Armed, app: *App, want: bool) bool {
        const id = driver.controlWithLabel(&app.tree, self.name) orelse return false;
        return driver.disabledOf(app.tree.getConst(id).?.*).? == want;
    }
};

/// A control reading a particular value. Reads the a11y snapshot, like
/// every value assertion in this repository, so a wait can only settle
/// on something a screen reader could perceive. The snapshot is rebuilt
/// per poll, which costs nothing on the happy path (the value is
/// usually right within a poll or two) and is confined to a failure
/// that was already going to spend its whole deadline.
const Valued = struct {
    label: []const u8,
    expected: []const u8,

    fn reads(self: *Valued, app: *App) bool {
        var snap = semantics.snapshot(app.gpa, app) catch return false;
        defer snap.deinit();
        const node = snap.findByLabel(self.label) orelse return false;
        return std.mem.eql(u8, node.value, self.expected);
    }
};

/// A field's stated reason, and the invalid flag that must agree with
/// it. Both, because a message with no association is the state the
/// slot exists to abolish and a wait that read only the words would
/// stop on it.
const Refused = struct {
    label: []const u8,
    expected: []const u8,

    fn reads(self: *Refused, app: *App) bool {
        var snap = semantics.snapshot(app.gpa, app) catch return false;
        defer snap.deinit();
        const node = snap.findByLabel(self.label) orelse return false;
        return std.mem.eql(u8, node.description, self.expected) and
            node.invalid == (self.expected.len > 0);
    }
};

const Either = struct {
    a: []const u8,
    b: []const u8,

    fn present(self: *Either, app: *App) bool {
        return queries.queryByLabel(&app.tree, self.a) != null or
            queries.queryByLabel(&app.tree, self.b) != null;
    }
};

/// Pumps until an element with exactly this accessible label is on
/// screen, and answers it. The whole synchronization story of a driver
/// in one verb: there is no settle against a real server, and a screen
/// is done when it says what it came to say.
pub fn untilLabel(app: *App, pacer: Pacer, label: []const u8) error{WaitTimeout}!NodeId {
    var target: Label = .{ .text = label };
    var buf: [what_cap]u8 = undefined;
    try waitUntil(app, pacer, describe(&buf, "\"{s}\"", .{label}, label), bind.bindAs(Ready, Label.present, &target));
    return queries.queryByLabel(&app.tree, label).?;
}

/// `untilLabel` aimed by semantic identity — role plus accessible
/// name, the shape every acting verb locates through, and the wait
/// `press` synchronizes on.
pub fn untilRole(app: *App, pacer: Pacer, role: Role, name: []const u8) error{WaitTimeout}!NodeId {
    return untilAnyRole(app, pacer, &.{role}, name);
}

/// `untilRole` for a control *family* — a text field is a `text_input`
/// or a `text_area`, a choice control is one of three — so a verb that
/// acts on a family waits for the family it acts on rather than for a
/// bare label that anything on screen could satisfy.
pub fn untilAnyRole(app: *App, pacer: Pacer, roles: []const Role, name: []const u8) error{WaitTimeout}!NodeId {
    var target: Named = .{ .roles = roles, .name = name };
    var buf: [what_cap]u8 = undefined;
    try waitUntil(app, pacer, describeRoles(&buf, roles, name), bind.bindAs(Ready, Named.present, &target));
    return target.found(app).?;
}

/// "a button named …", "a text_input or text_area named …" — the role
/// list read out, so a timeout names the family it was looking for
/// rather than the first member of it.
fn describeRoles(buf: []u8, roles: []const Role, name: []const u8) []const u8 {
    var w = std.Io.Writer.fixed(buf);
    w.writeAll("a ") catch return name;
    for (roles, 0..) |role, i| {
        if (i != 0) w.writeAll(" or ") catch return name;
        w.writeAll(@tagName(role)) catch return name;
    }
    w.print(" named \"{s}\"", .{name}) catch return name;
    return w.buffered();
}

/// Pumps until some element's label *contains* `needle` — the wait for
/// a value the screen prints into a sentence rather than into a
/// control.
pub fn untilLabelContaining(app: *App, pacer: Pacer, needle: []const u8) error{WaitTimeout}!NodeId {
    var target: Label = .{ .text = needle };
    var buf: [what_cap]u8 = undefined;
    const what = describe(&buf, "a label containing \"{s}\"", .{needle}, needle);
    try waitUntil(app, pacer, what, bind.bindAs(Ready, Label.containing, &target));
    return queries.queryByLabelContaining(&app.tree, needle).?;
}

/// Whichever of the two labels arrives first, answered by name — the
/// shape a fork in a flow needs, like a sign-in that may or may not be
/// followed by a consent screen. Two, not a slice: every site in the
/// shipped drivers is a fork with two ends, and a slice would make the
/// common case allocate a literal array to say so.
pub fn untilEither(app: *App, pacer: Pacer, a: []const u8, b: []const u8) error{WaitTimeout}![]const u8 {
    var target: Either = .{ .a = a, .b = b };
    var buf: [what_cap]u8 = undefined;
    const what = describe(&buf, "\"{s}\" or \"{s}\"", .{ a, b }, a);
    try waitUntil(app, pacer, what, bind.bindAs(Ready, Either.present, &target));
    return if (queries.queryByLabel(&app.tree, a) != null) a else b;
}

/// Pumps until the label *leaves*. The outcome of a deletion, and the
/// one absence it is safe to wait for: the label was on screen when
/// the action was taken, so the wait can only be about the answer
/// arriving. Waiting for a label that was never there to go away
/// succeeds instantly and proves nothing — `expectAbsent` is the verb
/// for "and it never appears", and it deliberately does not wait.
pub fn untilGone(app: *App, pacer: Pacer, label: []const u8) error{WaitTimeout}!void {
    var target: Label = .{ .text = label };
    var buf: [what_cap]u8 = undefined;
    const what = describe(&buf, "\"{s}\" to leave the screen", .{label}, label);
    try waitUntil(app, pacer, what, bind.bindAs(Ready, Label.gone, &target));
}

/// Pumps until the router stands on this route reference — the wait
/// for a screen a *callback* navigated to, where there is no label to
/// name yet.
pub fn untilRoute(app: *App, pacer: Pacer, ref: []const u8) error{WaitTimeout}!void {
    var target: Label = .{ .text = ref };
    var buf: [what_cap]u8 = undefined;
    const what = describe(&buf, "route \"{s}\"", .{ref}, ref);
    try waitUntil(app, pacer, what, bind.bindAs(Ready, Label.routed, &target));
}

/// Pumps until a notice with this title is pending. Titles are the
/// identity (`App.notify` dedups on them), and the pending notices ride
/// along in the failure dump, so a miss says what *was* raised.
pub fn untilNotice(app: *App, pacer: Pacer, title: []const u8) error{WaitTimeout}!void {
    var target: Label = .{ .text = title };
    var buf: [what_cap]u8 = undefined;
    const what = describe(&buf, "a notice titled \"{s}\"", .{title}, title);
    try waitUntil(app, pacer, what, bind.bindAs(Ready, Label.notified, &target));
}

/// Pumps until the nav can answer for this destination in whichever
/// shape it is wearing — `Destination` has the three. The wait `goTab`
/// synchronizes on: a bar whose roster has not arrived yet is the
/// ordinary state of a screen one route into a session.
pub fn untilDestination(app: *App, pacer: Pacer, title: []const u8) error{WaitTimeout}!void {
    var target: Destination = .{ .title = title };
    var buf: [what_cap]u8 = undefined;
    const what = describe(&buf, "a nav destination named \"{s}\"", .{title}, title);
    try waitUntil(app, pacer, what, bind.bindAs(Ready, Destination.present, &target));
}

/// Pumps until the control with this name is taking input again — the
/// reply that arms a form landing, not merely the form being on screen.
/// The button it re-arms and the fields it hands back are one question.
pub fn untilEnabled(app: *App, pacer: Pacer, label: []const u8) error{WaitTimeout}!void {
    var target: Armed = .{ .name = label };
    var buf: [what_cap]u8 = undefined;
    const what = describe(&buf, "\"{s}\" to stop declining", .{label}, label);
    try waitUntil(app, pacer, what, bind.bindAs(Ready, Armed.enabled, &target));
}

/// `untilEnabled`'s twin: the control has gone back to declining.
pub fn untilDisabled(app: *App, pacer: Pacer, label: []const u8) error{WaitTimeout}!void {
    var target: Armed = .{ .name = label };
    var buf: [what_cap]u8 = undefined;
    const what = describe(&buf, "\"{s}\" to start declining", .{label}, label);
    try waitUntil(app, pacer, what, bind.bindAs(Ready, Armed.disabled, &target));
}

/// Pumps until the control with this label *reads* this value on the
/// a11y snapshot. The value, not the label: a field that is on screen
/// with last screen's contents in it satisfies a wait for the label and
/// fails the assertion the caller actually wrote.
pub fn untilValue(app: *App, pacer: Pacer, label: []const u8, expected: []const u8) error{WaitTimeout}!void {
    var target: Valued = .{ .label = label, .expected = expected };
    var buf: [what_cap]u8 = undefined;
    const what = describe(&buf, "\"{s}\" to read \"{s}\"", .{ label, expected }, label);
    try waitUntil(app, pacer, what, bind.bindAs(Ready, Valued.reads, &target));
}

/// Pumps until the field with this label states this problem — the
/// server's refusal landing, not merely the field being on screen. The
/// empty string waits for the field to come *clean*, which is the
/// other half of every validation test.
pub fn untilProblem(app: *App, pacer: Pacer, label: []const u8, expected: []const u8) error{WaitTimeout}!void {
    var target: Refused = .{ .label = label, .expected = expected };
    var buf: [what_cap]u8 = undefined;
    const what = if (expected.len == 0)
        describe(&buf, "\"{s}\" to have no problem", .{label}, label)
    else
        describe(&buf, "\"{s}\" to report \"{s}\"", .{ label, expected }, label);
    try waitUntil(app, pacer, what, bind.bindAs(Ready, Refused.reads, &target));
}

/// The failure dump, printed through the diag gate: route, every
/// labeled element with the state a user would notice (working,
/// disabled, folded), the pending notices the snapshot cannot speak
/// for, then the laid-out tree in the trace format. Public because a
/// driver's own failure paths (a refused tap, say) owe the same
/// picture waitUntil prints.
pub fn dumpScreen(app: *App) void {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(app.gpa);
    writeScreen(app.gpa, &out, app) catch return;
    diag.print("{s}", .{out.items});
}

/// `dumpScreen`'s body, into a caller-owned list — the seam that makes
/// the dump assertable without capturing stderr.
pub fn writeScreen(gpa: std.mem.Allocator, out: *std.ArrayList(u8), app: *App) !void {
    app.performLayout();
    try out.print(gpa, "  on route \"{s}\"\n", .{app.router.current() orelse "(none)"});
    var it = app.tree.dfs();
    while (it.next()) |id| {
        const el = app.tree.getConst(id).?;
        if (el.label().len == 0) continue;
        const state: []const u8 = switch (el.*) {
            .button => |b| if (b.in_progress) " (working)" else if (b.disabled) " (disabled)" else if (b.folded) " (folded)" else "",
            // The two fields say the same word for the same reason: a
            // failure dump whose form is mid-submission reads as a
            // screen full of fields that simply ignored the driver.
            .text_input => |i| if (i.disabled) " (disabled)" else "",
            .text_area => |a| if (a.disabled) " (disabled)" else "",
            else => if (el.isFolded()) " (folded)" else "",
        };
        try out.print(gpa, "  {s} \"{s}\"{s}\n", .{ @tagName(el.role()), el.label(), state });
    }
    for (app.notices.items) |*n| try out.print(gpa, "  notice \"{s}\"\n", .{n.title()});
    try trace.dump(gpa, out, app);
}

// ---- tests ----
// The whole driver tier is proved in one sibling suite,
// `device_test.zig`: these waits and the `Device` composed over them
// share a fake pacer — a clock that moves only when the wait naps —
// and a suite that split them would keep two copies of it (CLAUDE.md,
// tests in a sibling once a module is past a few hundred lines).
