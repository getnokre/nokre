//! The driver tier's verb set: one installation of a *live* app, driven
//! by the same verbs a `Harness` test uses.
//!
//! **Why this exists at all.** `Harness` cannot leave `zig test`. Its
//! whole value is that every service is a mock, and a mock exists only
//! under `builtin.is_test` — `Service = if (is_test) Mock else
//! PlatformService` is the roster's rule, not one service's. So a
//! driver, which is an ordinary executable against real transports, can
//! never hold one. Before this module the consequence was that a driver
//! re-implemented the harness's verbs from the primitives, and the two
//! shipped drivers did exactly that: ~570 lines each, the same
//! twenty-odd verbs, under names that had drifted apart (`fill` for
//! `typeInto`, `expect` for `expectPresent`, `choose` for
//! `selectOption`) and, worse, with the algorithms drifted too — one
//! probed the fold before pressing, the other caught the tap's refusal
//! afterwards, and only one of those two is right.
//!
//! **What is shared, and how.** Not a base class and not a copy: the
//! *ladders* moved one layer down, into `driver.zig`, where they are
//! free functions over `*App` that name no mock. `Harness` calls them
//! and adds a trace step and a re-audit; `Device` calls the same ones
//! and adds a **wait** in front — because that is the only real
//! difference between the two tiers. Under the mocks nothing waits:
//! every settle is a verb. Against a real server there is no settle
//! verb, so a screen is done when it says what it came to say
//! (`wait.zig`). One ladder, two synchronizations.
//!
//! **What stays the driver's own.** Its transports, its clock (handed
//! in as a `Pacer` — nokre reads no wall clock and sleeps no thread),
//! its `App`'s address, and every wait whose condition is about *app
//! state* rather than the screen: a proof-of-work queue draining, a
//! prefetch sweep finishing. Those reach `waitUntil` through
//! `wait.Ready`, which `nokre.bindAs` fills from an ordinary method.
//!
//! ```zig
//! var d: nokre.testing.Device = .{ .app = &self.app, .pacer = self.pacer() };
//! try d.press(.button, "Sign in");
//! try d.typeInto("Email", "someone@example.com");
//! try d.expectPresent(.heading, "Your circles");
//! ```

const std = @import("std");
const app_mod = @import("../core/app.zig");
const element_mod = @import("../core/element.zig");
const tree_mod = @import("../core/tree.zig");
const semantics = @import("../a11y/semantics.zig");
const audit_mod = @import("audit.zig");
const diag = @import("diag.zig");
const driver = @import("driver.zig");
const queries = @import("queries.zig");
const wait = @import("wait.zig");

const App = app_mod.App;
const NodeId = tree_mod.NodeId;
const Role = element_mod.Role;

/// Extra context printed after any refusal this device raises — the
/// app-side state only the driver can name: the proofs still queued,
/// the load phases behind a screen that never filled in. nokre's own
/// dump says what is *on* the screen; this says what is behind it, and
/// a wait that timed out is exactly where the two together are worth
/// more than either.
///
/// A `{ ctx, call }` pair, so `nokre.bindAs` fills it from a method:
///
/// ```zig
/// self.d = .{ .app = &self.app, .pacer = self.pacer(),
///             .notes = nokre.bindAs(nokre.testing.Device.Notes, State.dumpPhases, &self.state) };
/// ```
pub const Notes = struct {
    ctx: ?*anyopaque = null,
    call: *const fn (ctx: ?*anyopaque) void,
};

pub const Device = struct {
    /// The live app, at a fixed address: a press handler holds a
    /// `*App`, so a driver builds its app into storage that outlives
    /// the call (docs/testing.md).
    app: *App,
    /// The driver's own clock and nap, and the deadline every wait
    /// here runs against.
    pacer: wait.Pacer,
    notes: ?Notes = null,

    // ---- waiting ----
    // Each answers what it found, so the wait and the lookup are one
    // call. `wait.zig` holds the predicates; this is the pacer, bound
    // once, so a driver's verbs stop repeating it.

    /// Pumps until an element with exactly this accessible label is on
    /// screen, and answers it.
    pub fn untilLabel(self: *Device, label: []const u8) !NodeId {
        return self.note(wait.untilLabel(self.app, self.pacer, label));
    }

    /// The same wait aimed by semantic identity — role plus accessible
    /// name, the shape every acting verb locates through.
    pub fn untilRole(self: *Device, role: Role, name: []const u8) !NodeId {
        return self.note(wait.untilRole(self.app, self.pacer, role, name));
    }

    /// Pumps until some element's label *contains* `needle`.
    pub fn untilLabelContaining(self: *Device, needle: []const u8) !NodeId {
        return self.note(wait.untilLabelContaining(self.app, self.pacer, needle));
    }

    /// Whichever of the two labels arrives first, answered by name —
    /// the shape a fork in a flow needs.
    pub fn untilEither(self: *Device, a: []const u8, b: []const u8) ![]const u8 {
        return self.note(wait.untilEither(self.app, self.pacer, a, b));
    }

    /// A wait on a condition only the driver can evaluate — its ports,
    /// its phases, its work queue. `what` is the caller's words, and
    /// they are what a timeout prints.
    pub fn waitUntil(self: *Device, what: []const u8, ready: wait.Ready) !void {
        return self.note(wait.waitUntil(self.app, self.pacer, what, ready));
    }

    /// Lets whatever is in flight land, for the one case a scenario has
    /// nothing on screen to wait for — a background sweep with no
    /// visible outcome. A deadline, not a condition: it always waits
    /// the whole `millis`, so it is the verb of last resort and every
    /// use of it is a screen that should have said something.
    pub fn quiesce(self: *Device, millis: i64) void {
        const deadline = self.pacer.nowMs() + millis;
        while (self.pacer.nowMs() < deadline) {
            _ = self.app.runtime.pump();
            self.pacer.rest();
        }
    }

    // ---- acting ----
    // The harness's four ladders, each with a wait in front and the
    // harness's own post-action audit behind. The audit is what makes
    // driving by accessible name safe: two live controls sharing a
    // label fail here rather than silently taking the first.

    /// Presses a control the way a user would — see `driver.press`.
    /// Waits for it first, except when it is already on screen but
    /// *folded*: that is checked without waiting, because a folded
    /// control is invisible to every query, and spending a minute's
    /// deadline discovering it is how one missing label costs an hour.
    pub fn press(self: *Device, role: Role, label: []const u8) !void {
        self.app.performLayout();
        if (queries.queryFolded(&self.app.tree, role, label) == null) _ = try self.untilRole(role, label);
        try self.note(driver.press(self.app, role, label));
        return self.settled();
    }

    /// Puts the caret in a named field and types, appending like
    /// typing does. `clearField` first is "leave it holding exactly
    /// this".
    pub fn typeInto(self: *Device, label: []const u8, bytes: []const u8) !void {
        _ = try self.untilLabel(label);
        try self.note(driver.typeInto(self.app, label, bytes));
        return self.settled();
    }

    /// Empties a named field the way a user empties one.
    pub fn clearField(self: *Device, label: []const u8) !void {
        _ = try self.untilLabel(label);
        try self.note(driver.clearField(self.app, label));
        return self.settled();
    }

    /// Chooses an option in a `segmented`, `radio_group` or `select` by
    /// the words on it, both ends named. The keyboard route, through
    /// real dispatch — see `driver.selectOption`.
    pub fn selectOption(self: *Device, group_label: []const u8, option: []const u8) !void {
        const id = try self.untilLabel(group_label);
        try self.note(driver.selectOption(self.app, id, option));
        return self.settled();
    }

    /// Crosses the nav to the destination with this title, whichever
    /// shape the bar is in — see `driver.goTab`.
    pub fn goTab(self: *Device, title: []const u8) !void {
        _ = self.app.runtime.pump();
        try self.note(driver.goTab(self.app, title));
        return self.settled();
    }

    /// What the harness does after every action, minus the mocks: let
    /// the frame the action produced settle, then audit it. Public
    /// because a driver's own verbs — a domain flow built out of
    /// several of these — owe the same check.
    pub fn settled(self: *Device) !void {
        _ = self.app.runtime.pump();
        return self.note(audit_mod.audit(self.app));
    }

    // ---- asserting ----
    // The harness's `expect*` spellings, so a verb means the same thing
    // in a unit test and in an e2e run. Most of them wait; the one
    // about absence deliberately does not.

    /// Presence by semantic identity — role plus accessible name.
    pub fn expectPresent(self: *Device, role: Role, name: []const u8) !void {
        _ = try self.untilRole(role, name);
    }

    /// Absence, against the screen as it stands — never waited for: a
    /// label that is *going* to appear would pass this check for as
    /// long as it took to arrive, so a wait here would assert the
    /// opposite of what it says.
    pub fn expectAbsent(self: *Device, label: []const u8) !void {
        _ = self.app.runtime.pump();
        const id = queries.queryByLabel(&self.app.tree, label) orelse return;
        const el = self.app.tree.getConst(id).?;
        diag.print("expected no element labeled \"{s}\", but found a {s}\n", .{ label, @tagName(el.role()) });
        wait.dumpScreen(self.app);
        return self.noted(error.UnexpectedlyPresent);
    }

    /// `expectAbsent`'s waiting twin, and the one absence it is safe to
    /// wait for: the label was on screen when the action was taken, so
    /// the wait can only be about the answer arriving. The outcome of a
    /// deletion. One spelling, not two — there is no `untilGone` here
    /// beside it, because "wait for it to go" and "assert it went" are
    /// the same act and a verb with two names is the thing this tier
    /// exists to stop.
    pub fn expectGone(self: *Device, label: []const u8) !void {
        return self.note(wait.untilGone(self.app, self.pacer, label));
    }

    /// The router stands on this route reference — the assertion for a
    /// screen a callback navigated to, where there is no label to name.
    pub fn expectRoute(self: *Device, ref: []const u8) !void {
        return self.note(wait.untilRoute(self.app, self.pacer, ref));
    }

    /// A notice with this title is pending. Titles are the identity
    /// (`App.notify` dedups on them), so this is the whole of "was it
    /// raised", banner or pane or quietly behind the indicator.
    pub fn expectNotified(self: *Device, title: []const u8) !void {
        return self.note(wait.untilNotice(self.app, self.pacer, title));
    }

    /// Whatever this control's a11y node reports as its *value* — a
    /// field's text, a choice's selection, a tile's detail line, a
    /// `copyable`'s payload, the URL a `qr` encodes. Waits for the
    /// label, then compares: a value that has not arrived yet is the
    /// commonest thing a driver is waiting on.
    pub fn expectValue(self: *Device, label: []const u8, expected: []const u8) !void {
        _ = try self.untilLabel(label);
        var snap = try self.note(semantics.snapshot(self.app.gpa, self.app));
        defer snap.deinit();
        const node = snap.findByLabel(label) orelse
            return self.noted(queries.noMatch(&self.app.tree, "label", label));
        if (std.mem.eql(u8, node.value, expected)) return;
        diag.print("expected \"{s}\" value \"{s}\", got \"{s}\"\n", .{ label, expected, node.value });
        return self.noted(error.ValueMismatch);
    }

    /// A control that declines rather than acts. Read off the node
    /// instead of pressed: pressing a disabled control refuses loudly
    /// and proves nothing either way.
    pub fn expectDisabled(self: *Device, label: []const u8) !void {
        const el = try self.buttonNamed(label);
        if (el.button.disabled) return;
        diag.print("expected \"{s}\" disabled, but it takes presses\n", .{label});
        return self.noted(error.DisabledMismatch);
    }

    /// `expectDisabled`'s twin: a control that has become live. Not the
    /// same as pressing it — a test that proved "the last field armed
    /// Save" by pressing would have submitted the form to prove it.
    pub fn expectEnabled(self: *Device, label: []const u8) !void {
        const el = try self.buttonNamed(label);
        if (!el.button.disabled) return;
        diag.print("expected \"{s}\" to take presses, but it is disabled\n", .{label});
        return self.noted(error.EnabledMismatch);
    }

    /// The button with this name, waited for. Buttons only — the one
    /// element that carries `disabled` (element.zig); everything else
    /// declines by not being built.
    fn buttonNamed(self: *Device, label: []const u8) !*const element_mod.Element {
        const id = try self.untilRole(.button, label);
        return self.app.tree.getConst(id) orelse self.noted(error.InvalidNode);
    }

    // ---- reading ----

    /// The value a control carries, copied into `gpa` — the caller owns
    /// the bytes, because the a11y snapshot they were read from dies
    /// with this call. Read off the snapshot, so a scenario can only
    /// read what a screen reader could.
    pub fn valueOf(self: *Device, gpa: std.mem.Allocator, label: []const u8) ![]u8 {
        _ = try self.untilLabel(label);
        var snap = try self.note(semantics.snapshot(self.app.gpa, self.app));
        defer snap.deinit();
        const node = snap.findByLabel(label) orelse
            return self.noted(queries.noMatch(&self.app.tree, "label", label));
        return gpa.dupe(u8, node.value);
    }

    /// The whole label of the first element whose label contains
    /// `needle` — how a scenario reads a value the screen prints into a
    /// sentence rather than into a control. Borrowed from the tree, so
    /// it lives until the next rebuild; copy it if it must outlive one.
    pub fn labelContaining(self: *Device, needle: []const u8) ![]const u8 {
        const id = try self.untilLabelContaining(needle);
        const el = self.app.tree.getConst(id) orelse return self.noted(error.InvalidNode);
        return el.label();
    }

    /// Every refusal leaves through one of these two, so the driver's
    /// own note — the phases and queues nokre cannot name — lands under
    /// the framework's picture exactly once, whichever verb failed.
    /// `note` wraps a call that may fail; `noted` marks an error this
    /// module raises itself.
    fn note(self: *Device, result: anytype) @TypeOf(result) {
        if (result) |_| {} else |_| {
            if (self.notes) |n| n.call(n.ctx);
        }
        return result;
    }

    fn noted(self: *Device, e: anytype) @TypeOf(e) {
        if (self.notes) |n| n.call(n.ctx);
        return e;
    }
};

// ---- tests ----
// The whole driver tier is proved in `device_test.zig` — these verbs
// and the waits under them share one fake pacer.
