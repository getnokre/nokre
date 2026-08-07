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
//! and adds a trace step and a re-audit; `Device` calls the same ones,
//! adds the same trace step and the same re-audit behind, and a **wait**
//! in front — and that wait is the only real
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
const trace = @import("trace.zig");
const wait = @import("wait.zig");

const App = app_mod.App;
const NodeId = tree_mod.NodeId;
const Role = element_mod.Role;

/// The two text-entry roles and the three choice roles, named once:
/// these are the families `typeInto`/`clearField` and `selectOption`
/// act on, so they are the families those verbs wait for.
const text_field_roles: []const Role = &.{ .text_input, .text_area };
const choice_roles: []const Role = &.{ .segmented, .radio_group, .select };

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
    /// Installed by `startTrace`; null until then, and a null check per
    /// action when it stays that way.
    step_observer: ?trace.StepObserver = null,
    step_index: u32 = 0,

    // ---- tracing ----

    /// Installs a per-step observer over a *live* app and emits step 0,
    /// the screen as the driver found it. The same observers a
    /// `Harness` takes — `trace.TreeSink.observer()`,
    /// `render.skia.PixelSink.observer()`, `trace.Tee` over both — and
    /// the same numbering, because it is the same seam: the observer
    /// runs after the same ladder, one tier up.
    ///
    /// **This is the tier where it matters most.** A `Harness` failure
    /// already prints the tree; a driver's screen is one nobody watched.
    /// Every step is written unconditionally, pass or fail, to a path
    /// the driver named — the opposite of a golden, which writes nothing
    /// when it succeeds and is right not to. What is being asked here is
    /// not "did this match" but "what is on the screen", and that
    /// question has no baseline to compare against.
    pub fn startTrace(self: *Device, observer: trace.StepObserver) !void {
        self.step_observer = observer;
        self.app.performLayout();
        return self.note(observer.call(observer.ctx, 0, "init", self.app));
    }

    /// A numbered step at a moment of the driver's own choosing, named
    /// in the driver's own words: after a wait that has no action behind
    /// it, or at the top of a scenario worth marking. The acting verbs
    /// emit their own steps, so this is for the gaps between them.
    pub fn step(self: *Device, action: []const u8) !void {
        return self.observe("{s}", .{action});
    }

    fn observe(self: *Device, comptime fmt: []const u8, args: anytype) !void {
        const obs = self.step_observer orelse return;
        self.step_index += 1;
        var buf: [64]u8 = undefined;
        var w = std.Io.Writer.fixed(&buf);
        w.print(fmt, args) catch {}; // overflow truncates the action name
        return self.note(obs.call(obs.ctx, self.step_index, w.buffered(), self.app));
    }

    /// What every acting verb ends with: let the frame the action
    /// produced settle, write the step, then audit — `settled` with the
    /// trace in the middle, and the step names match the harness's for
    /// the same verb so one scenario's trace reads like the other's.
    fn afterStep(self: *Device, comptime fmt: []const u8, args: anytype) !void {
        _ = self.app.runtime.pump();
        try self.observe(fmt, args);
        return self.note(audit_mod.audit(self.app));
    }

    // ---- waiting ----
    // Each answers what it found, so the wait and the lookup are one
    // call. `wait.zig` holds the predicates; this is the pacer, bound
    // once, so a driver's verbs stop repeating it.
    //
    // What they hand back, and for how long. A `NodeId` is a tree
    // position with a generation on it, so one that outlives a rebuild
    // reads back as absent rather than as the wrong node — use it in
    // the statement that follows, not across another verb.
    // `untilEither` answers one of the two slices the *caller* passed
    // in, so it is as long-lived as the caller's own strings and needs
    // no copy. The one verb that hands back tree-owned bytes is
    // `labelContaining`, and it says so at itself.

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

    /// `untilRole` for a control family — what the verbs that act on a
    /// family wait for.
    pub fn untilAnyRole(self: *Device, roles: []const Role, name: []const u8) !NodeId {
        return self.note(wait.untilAnyRole(self.app, self.pacer, roles, name));
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
        return self.afterStep("press {s}", .{label});
    }

    /// Puts the caret in a named field and types, appending like
    /// typing does. `clearField` first is "leave it holding exactly
    /// this". Waits for a *field* with that label, not for the label:
    /// a heading carrying the same words would otherwise end the wait
    /// and leave the verb to refuse a control still on its way.
    pub fn typeInto(self: *Device, label: []const u8, bytes: []const u8) !void {
        _ = try self.untilAnyRole(text_field_roles, label);
        try self.note(driver.typeInto(self.app, label, bytes));
        return self.afterStep("type into {s}", .{label});
    }

    /// Empties a named field the way a user empties one.
    pub fn clearField(self: *Device, label: []const u8) !void {
        _ = try self.untilAnyRole(text_field_roles, label);
        try self.note(driver.clearField(self.app, label));
        return self.afterStep("clear {s}", .{label});
    }

    /// Chooses an option in a `segmented`, `radio_group` or `select` by
    /// the words on it, both ends named. The keyboard route, through
    /// real dispatch — see `driver.selectOption`. Waits for a *choice
    /// control*, for `typeInto`'s reason.
    pub fn selectOption(self: *Device, group_label: []const u8, option: []const u8) !void {
        const id = try self.untilAnyRole(choice_roles, group_label);
        try self.note(driver.selectOption(self.app, id, option));
        return self.afterStep("select {s}", .{option});
    }

    /// Crosses the nav to the destination with this title, whichever
    /// shape the bar is in — see `driver.goTab`. Waits for the bar to
    /// be able to answer for that destination at all: the row's
    /// `nav_item`, the `nav_here` marker when it is the screen already
    /// under foot, or the collapsed chip that stands in for the whole
    /// roster. All three, because which one a screen wears is layout's
    /// decision, and a bar whose roster has not arrived is the ordinary
    /// state of a screen one route into a session.
    pub fn goTab(self: *Device, title: []const u8) !void {
        try self.note(wait.untilDestination(self.app, self.pacer, title));
        try self.note(driver.goTab(self.app, title));
        return self.afterStep("go to {s}", .{title});
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
    /// `copyable`'s payload, the URL a `qr` encodes.
    ///
    /// Waits for the **value**, not for the label. A screen revisited
    /// against a real server stands there with the last answer's
    /// contents in it while the new one is in flight, and a wait that
    /// stopped at the label would assert the stale one every time.
    pub fn expectValue(self: *Device, label: []const u8, expected: []const u8) !void {
        wait.untilValue(self.app, self.pacer, label, expected) catch |e| {
            // The generic dump above named the screen; this names the
            // one thing it does not print — what the control actually
            // reads — so the reader is not left diffing a tree.
            var snap = semantics.snapshot(self.app.gpa, self.app) catch return self.noted(e);
            defer snap.deinit();
            if (snap.findByLabel(label)) |node| {
                diag.print("expected \"{s}\" value \"{s}\", got \"{s}\"\n", .{ label, expected, node.value });
            } else {
                diag.print("expected \"{s}\" value \"{s}\", but nothing on screen carries that label\n", .{ label, expected });
            }
            return self.noted(e);
        };
    }

    /// What a field says is wrong with its value, read the way
    /// assistive tech gets it — the description plus the invalid flag,
    /// never one without the other. The empty string waits for the
    /// field to come clean.
    ///
    /// Waits, because against a real server a refusal is exactly what
    /// arrives late: the field is on screen, unmarked and plausible,
    /// for the whole time the submission is in flight.
    pub fn expectProblem(self: *Device, label: []const u8, expected: []const u8) !void {
        wait.untilProblem(self.app, self.pacer, label, expected) catch |e| {
            var snap = semantics.snapshot(self.app.gpa, self.app) catch return self.noted(e);
            defer snap.deinit();
            if (snap.findByLabel(label)) |node| {
                diag.print("expected \"{s}\" problem \"{s}\", got \"{s}\" (invalid={})\n", .{ label, expected, node.description, node.invalid });
            } else {
                diag.print("expected \"{s}\" problem \"{s}\", but nothing on screen carries that label\n", .{ label, expected });
            }
            return self.noted(e);
        };
    }

    /// A control that declines rather than acts. Read off the node
    /// instead of pressed: acting on a disabled control refuses loudly
    /// and proves nothing either way. Waits for the **state** — the
    /// control is on screen for the whole time the reply that disarms
    /// it is in flight.
    ///
    /// Across the kinds that carry `disabled` (`driver.disabledOf`), so
    /// a form that stands its fields down while the submission is on
    /// the wire can be asserted on the fields and not only the button.
    pub fn expectDisabled(self: *Device, label: []const u8) !void {
        wait.untilDisabled(self.app, self.pacer, label) catch |e|
            return self.armMismatch(e, label, true);
    }

    /// `expectDisabled`'s twin: a control that has become live. Not the
    /// same as pressing it — a test that proved "the last field armed
    /// Save" by pressing would have submitted the form to prove it.
    /// Waits, because arming is exactly what a reply does.
    pub fn expectEnabled(self: *Device, label: []const u8) !void {
        wait.untilEnabled(self.app, self.pacer, label) catch |e|
            return self.armMismatch(e, label, false);
    }

    /// The half the screen dump cannot say: whether the control was
    /// there at all, whether it was a kind that can be disabled, and if
    /// so which way round it was.
    fn armMismatch(self: *Device, e: anyerror, label: []const u8, want_disabled: bool) anyerror {
        const id = driver.controlWithLabel(&self.app.tree, label) orelse {
            // The plain lookup runs only for the diagnostic: naming the
            // heading above a control is a different mistake from
            // naming nothing at all.
            if (queries.queryByLabel(&self.app.tree, label)) |other| {
                const el = self.app.tree.getConst(other).?;
                diag.print("expected \"{s}\" disabled or not, but it is a {s} — only buttons and the two text fields can be\n", .{ label, @tagName(el.role()) });
            } else {
                diag.print("expected the control \"{s}\", but nothing on screen carries that name\n", .{label});
            }
            return self.noted(e);
        };
        const el = self.app.tree.getConst(id).?;
        if (want_disabled) {
            diag.print("expected \"{s}\" disabled, but it takes {s}\n", .{ label, driver.takes(el.*) });
        } else {
            diag.print("expected \"{s}\" to take {s}, but it is disabled\n", .{ label, driver.takes(el.*) });
        }
        return self.noted(e);
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
    /// sentence rather than into a control.
    ///
    /// **Copy the result before calling anything else on this device.**
    /// The bytes are borrowed from the tree, and *every* verb here
    /// pumps — a pump delivers a reply, a reply rebuilds the screen,
    /// and the rebuild frees what this pointed at. It is not "until the
    /// next rebuild" in some distant sense: the very next `valueOf` or
    /// `expectPresent` is enough. `valueOf` is the verb that hands back
    /// memory the caller owns; this one trades that for not allocating,
    /// and the trade is the caller's to honour.
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
