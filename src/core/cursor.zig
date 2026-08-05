//! The builder cursor: one method per element, standing at the node
//! new children go under. It is sugar over `Tree.append`/`appendId` and
//! nothing else — no state, no deferral, no second truth about the
//! tree. Every construction rule (`tree.validateAppend`), every string
//! copy, every contrast gate runs exactly as it does for a raw append,
//! because the cursor *is* that call. The raw `Tree` API stays public
//! and legitimate: it is the substrate, and the one form for the rare
//! call the cursor does not carry (a spanned *heading*, and a leaf's
//! `NodeId` outside the four the twins below cover).
//!
//! Shape rules, derived from the element set:
//! - A leaf method takes its element struct and returns nothing, as
//!   `Tree.append` does — most children are leaves nobody addresses
//!   again. The few that *are* addressed again have an `...Id` twin
//!   returning the node — `textId`, `styledId`, `buttonId`, `meterId`,
//!   and no others. The set is receipts, not symmetry: those four are
//!   the leaves the two real consumers hold ids to (19 sites, all of
//!   them a status line or a control whose progress must move without
//!   rebuilding the screen under the user's fingers), and a twin for a
//!   leaf nobody addresses is a second way to spell the same append.
//!   A leaf that earns one later adds it then.
//! - A container method returns the child cursor, so parent threading
//!   is the return value instead of a variable the caller carries.
//!   A container's own id, where a caller needs it, is `.at`.
//! - Content-only elements (`text`, `heading`, `code_block`) take
//!   their content directly; their remaining fields are either
//!   defaults nobody sets or layout-owned state consumers may not set.
//!
//! The set is closed exactly as the element set is: a new element adds
//! its method in the same pass (docs/internals/contributing.md), and
//! the comptime check at the bottom of this file refuses to compile a
//! union member the cursor cannot spell. That check is over the
//! *element* methods; the `...Id` twins are a separate, smaller set
//! answering a separate question, so nothing here demands one per
//! element.

const std = @import("std");
const element_mod = @import("element.zig");
const text_mod = @import("text.zig");
const tree_mod = @import("tree.zig");
const app_mod = @import("app.zig");
const load_mod = @import("load.zig");

const Tree = tree_mod.Tree;
const NodeId = tree_mod.NodeId;
const App = app_mod.App;

pub const Cursor = struct {
    tree: *Tree,
    at: NodeId,

    // ---- static leaves ----

    /// Body copy in the default style. The overwhelmingly common text
    /// append; a dimmed or resized run is `styled`, inline structure is
    /// `spanned`.
    pub fn text(c: Cursor, content: []const u8) !void {
        try c.tree.append(c.at, .{ .text = .{ .content = content } });
    }

    /// `text` carrying a style — the second-commonest text shape in
    /// real consumers (detail lines, captions), so it earns the second
    /// method rather than pushing a quarter of all text appends back
    /// onto the raw form.
    pub fn styled(c: Cursor, content: []const u8, style: text_mod.Style) !void {
        try c.tree.append(c.at, .{ .text = .{ .content = content, .style = style } });
    }

    /// `text` as styled runs — Markdown's inline vocabulary
    /// (`element.Span`). Content is append-derived from the spans, as
    /// the raw form's is.
    pub fn spanned(c: Cursor, spans: []const element_mod.Span) !void {
        try c.tree.append(c.at, .{ .text = .{ .spans = spans } });
    }

    pub fn heading(c: Cursor, level: element_mod.HeadingLevel, content: []const u8) !void {
        try c.tree.append(c.at, .{ .heading = .{ .level = level, .content = content } });
    }

    pub fn icon(c: Cursor, i: element_mod.Icon) !void {
        try c.tree.append(c.at, .{ .icon = i });
    }

    pub fn divider(c: Cursor) !void {
        try c.tree.append(c.at, .{ .divider = .{} });
    }

    pub fn badge(c: Cursor, b: element_mod.Badge) !void {
        try c.tree.append(c.at, .{ .badge = b });
    }

    pub fn meter(c: Cursor, m: element_mod.Meter) !void {
        try c.tree.append(c.at, .{ .meter = m });
    }

    pub fn qr(c: Cursor, q: element_mod.Qr) !void {
        try c.tree.append(c.at, .{ .qr = q });
    }

    /// Verbatim block; the struct's other fields are layout-owned, so
    /// the content is the whole of what a consumer may say.
    pub fn codeBlock(c: Cursor, content: []const u8) !void {
        try c.tree.append(c.at, .{ .code_block = .{ .content = content } });
    }

    /// Expands inside the append (markdown.zig); a leaf to the caller,
    /// because its children are the parser's to write, never appended to.
    pub fn document(c: Cursor, d: element_mod.Document) !void {
        try c.tree.append(c.at, .{ .document = d });
    }

    // ---- interactive leaves ----

    pub fn button(c: Cursor, b: element_mod.Button) !void {
        try c.tree.append(c.at, .{ .button = b });
    }

    pub fn link(c: Cursor, l: element_mod.Link) !void {
        try c.tree.append(c.at, .{ .link = l });
    }

    pub fn toggle(c: Cursor, t: element_mod.Toggle) !void {
        try c.tree.append(c.at, .{ .toggle = t });
    }

    pub fn checkbox(c: Cursor, cb: element_mod.Checkbox) !void {
        try c.tree.append(c.at, .{ .checkbox = cb });
    }

    pub fn textInput(c: Cursor, t: element_mod.TextInput) !void {
        try c.tree.append(c.at, .{ .text_input = t });
    }

    pub fn textArea(c: Cursor, t: element_mod.TextArea) !void {
        try c.tree.append(c.at, .{ .text_area = t });
    }

    pub fn segmented(c: Cursor, s: element_mod.Segmented) !void {
        try c.tree.append(c.at, .{ .segmented = s });
    }

    pub fn radioGroup(c: Cursor, rg: element_mod.RadioGroup) !void {
        try c.tree.append(c.at, .{ .radio_group = rg });
    }

    pub fn select(c: Cursor, s: element_mod.Select) !void {
        try c.tree.append(c.at, .{ .select = s });
    }

    pub fn copyable(c: Cursor, cp: element_mod.Copyable) !void {
        try c.tree.append(c.at, .{ .copyable = cp });
    }

    pub fn tile(c: Cursor, t: element_mod.Tile) !void {
        try c.tree.append(c.at, .{ .tile = t });
    }

    // ---- the leaves a caller addresses again ----
    //
    // Same appends as their twins above and below — the id is the only
    // difference, because the id is the only thing the callers wanted
    // and could not have without dropping to `tree.appendId(b.at, …)`.
    // What that drop cost was not a line: it was the cursor, so the
    // element literal came back (`.{ .text = .{ .content = … } }`) at
    // exactly the sites whose whole business is a mid-flight patch.
    //
    // Each is the receipt for `App.patchText` / `App.patchProgress`: a
    // status line whose words change while a request is out, a control
    // whose percentage climbs while a worker runs. Hold the id, patch
    // it, and never rebuild a screen the user is holding.

    /// `text`, returning the node — for the status line a callback
    /// rewrites with `App.patchText`.
    pub fn textId(c: Cursor, content: []const u8) !NodeId {
        return c.tree.appendId(c.at, .{ .text = .{ .content = content } });
    }

    /// `styled`, returning the node. Present because the status lines
    /// in reach are split between the two: half are body copy, half are
    /// the small dark caption under a heading, and a caller who has to
    /// give up the style to get the id has been handed the wrong door.
    pub fn styledId(c: Cursor, content: []const u8, style: text_mod.Style) !NodeId {
        return c.tree.appendId(c.at, .{ .text = .{ .content = content, .style = style } });
    }

    /// `button`, returning the node — for the control that carries its
    /// own progress (`App.patchProgress`).
    pub fn buttonId(c: Cursor, b: element_mod.Button) !NodeId {
        return c.tree.appendId(c.at, .{ .button = b });
    }

    /// `meter`, returning the node — the other half of the same job:
    /// a bar that moves while the work it measures runs.
    pub fn meterId(c: Cursor, m: element_mod.Meter) !NodeId {
        return c.tree.appendId(c.at, .{ .meter = m });
    }

    // ---- containers: the child cursor is the return value ----

    pub fn stack(c: Cursor, s: element_mod.Stack) !Cursor {
        return c.child(.{ .stack = s });
    }

    pub fn box(c: Cursor, b: element_mod.Box) !Cursor {
        return c.child(.{ .box = b });
    }

    pub fn scrollRegion(c: Cursor, s: element_mod.ScrollRegion) !Cursor {
        return c.child(.{ .scroll_region = s });
    }

    pub fn list(c: Cursor, l: element_mod.List) !Cursor {
        return c.child(.{ .list = l });
    }

    /// Its fields are layout-owned (the derived marker), so there is
    /// nothing for a consumer to say.
    pub fn listItem(c: Cursor) !Cursor {
        return c.child(.{ .list_item = .{} });
    }

    pub fn blockquote(c: Cursor) !Cursor {
        return c.child(.{ .blockquote = .{} });
    }

    pub fn table(c: Cursor) !Cursor {
        return c.child(.{ .table = .{} });
    }

    pub fn row(c: Cursor, r: element_mod.Row) !Cursor {
        return c.child(.{ .row = r });
    }

    pub fn cell(c: Cursor) !Cursor {
        return c.child(.{ .cell = .{} });
    }

    pub fn tileGroup(c: Cursor, g: element_mod.TileGroup) !Cursor {
        return c.child(.{ .tile_group = g });
    }

    // ---- chrome ----
    // Consumers rarely stand here — the nav is `App.setNav`'s, the
    // sheet `App.presentSheet`'s, the picker and the notices are the
    // framework's — but the cursor's set is the element set, whole:
    // the framework's own chrome code is a consumer of the tree too,
    // and a hole here would be a second truth about what can be built.
    // Every structural rule (`NavMustBeAtRoot`, `MultipleSheets`, …)
    // still holds at the append inside.

    pub fn nav(c: Cursor) !Cursor {
        return c.child(.{ .nav = .{} });
    }

    pub fn navItem(c: Cursor, n: element_mod.NavItem) !void {
        try c.tree.append(c.at, .{ .nav_item = n });
    }

    pub fn navCurrent(c: Cursor, n: element_mod.NavCurrent) !void {
        try c.tree.append(c.at, .{ .nav_current = n });
    }

    pub fn navHere(c: Cursor, n: element_mod.NavHere) !void {
        try c.tree.append(c.at, .{ .nav_here = n });
    }

    pub fn sheet(c: Cursor, s: element_mod.Sheet) !Cursor {
        return c.child(.{ .sheet = s });
    }

    pub fn sheetClose(c: Cursor, s: element_mod.SheetClose) !void {
        try c.tree.append(c.at, .{ .sheet_close = s });
    }

    pub fn back(c: Cursor, b: element_mod.Back) !void {
        try c.tree.append(c.at, .{ .back = b });
    }

    pub fn notice(c: Cursor, n: element_mod.Notice) !Cursor {
        return c.child(.{ .notice = n });
    }

    pub fn noticesPane(c: Cursor, p: element_mod.NoticesPane) !Cursor {
        return c.child(.{ .notices_pane = p });
    }

    pub fn iconButton(c: Cursor, i: element_mod.IconButton) !void {
        try c.tree.append(c.at, .{ .icon_button = i });
    }

    pub fn picker(c: Cursor, p: element_mod.Picker) !Cursor {
        return c.child(.{ .picker = p });
    }

    pub fn pickerItem(c: Cursor, p: element_mod.PickerItem) !void {
        try c.tree.append(c.at, .{ .picker_item = p });
    }

    pub fn more(c: Cursor, m: element_mod.More) !void {
        try c.tree.append(c.at, .{ .more = m });
    }

    // ---- idioms ----
    // Not elements: compositions of the methods above that every real
    // consumer wrote identically, promoted whole. The closed-set check
    // below is by Role, so an idiom adds no second truth about the tree
    // — each one is exactly the appends its caller would have written.

    /// What `loadGate` renders in place of not-yet-ready content. Every
    /// field is copy the app supplies (localized words are the app's,
    /// never nokre's), and every field defaults to "append nothing" —
    /// the gate's floor is a bare `phase == .ready` check.
    pub const LoadGate = struct {
        /// An `h1` opening the loading and failed states, for screens
        /// that gate their whole body: the ready branch usually heads
        /// itself with a loaded value (a row's own name), so the
        /// placeholder title belongs to the not-ready states alone.
        /// Appended before the copy, never on ready.
        title: ?[]const u8 = null,
        /// Body copy while the value is `.idle` or `.loading` — the two
        /// phases render identically everywhere (an `ensure*`-on-build
        /// app requests on first render, so `.idle` is on screen for at
        /// most one frame and distinct words for it would flash).
        loading: ?[]const u8 = null,
        /// Body copy on `.failed`. null for the screens whose failure
        /// is said elsewhere (or not at all — a sidebar section that
        /// quietly vanishes).
        failed: ?[]const u8 = null,
        /// The retry control on `.failed`: label and action, rendered
        /// as a secondary button — retrying is recovery beside the
        /// failure copy, never the screen's primary act. null when the
        /// failure is terminal (a revoked invite is not retried into
        /// validity).
        retry: ?Retry = null,

        pub const Retry = struct {
            label: []const u8,
            on_press: element_mod.Action,
        };
    };

    /// The loading/failed/retry scaffold in front of async content —
    /// the one composition both real apps wrote at every phase switch.
    /// Renders the not-ready states from `g` and answers whether the
    /// caller should go on to build the ready content:
    ///
    /// ```zig
    /// if (!try b.loadGate(view.phase, .{
    ///     .loading = tr(.loading),
    ///     .failed = tr(.eFailed),
    ///     .retry = .{ .label = tr(.retry), .on_press = .bind(onRetry, state) },
    /// })) return;
    /// ```
    ///
    /// The phase is a parameter, deliberately: nokre never reads an
    /// app's `Load` (core/load.zig) — the gate is the app showing nokre
    /// its phase for one build, not nokre keeping it.
    pub fn loadGate(c: Cursor, phase: load_mod.Load, g: LoadGate) !bool {
        switch (phase) {
            .idle, .loading => {
                if (g.title) |t| try c.heading(.h1, t);
                if (g.loading) |copy| try c.text(copy);
                return false;
            },
            .failed => {
                if (g.title) |t| try c.heading(.h1, t);
                if (g.failed) |copy| try c.text(copy);
                if (g.retry) |r| try c.button(.{
                    .label = r.label,
                    .form = .{ .secondary = null },
                    .on_press = r.on_press,
                });
                return false;
            },
            .ready => return true,
        }
    }

    /// `loadGate`'s missing branch: the load is over, it succeeded, and
    /// there is nothing to list. `loadGate` answers `true` on `.ready`
    /// and says nothing about zero rows, so every screen wrote the tail
    /// itself — twenty-seven sites across the two real apps, in two
    /// different visual spellings.
    ///
    /// ```zig
    /// if (!try b.loadGate(c.phase, .{ .loading = tr(.loading), .failed = tr(.eFailed) })) return;
    /// try b.heading(.h2, tr(.invoices));
    /// if (!try b.emptyGate(c.phase, c.rows.len, tr(.noInvoices))) return;
    /// for (c.rows.items()) |*row| try appendInvoice(b, row);
    /// ```
    ///
    /// It takes the phase **again**, and that is the point: the empty
    /// line belongs where the list would have gone, which at most sites
    /// is a heading and a tile group past the `loadGate` that admitted
    /// it. A count-only verb standing there would print "No invoices"
    /// over a request still in flight — the one thing an empty state
    /// must never say. So the not-ready answer here is `false` with
    /// nothing appended: whatever renders the phase, this does not, and
    /// it will not speak before the phase is settled.
    ///
    /// `empty` is `null` for the section that vanishes silently when it
    /// has nothing (four consumer sites), the way `loadGate`'s copy
    /// fields default to appending nothing. One optional value, so it is
    /// an argument and not a struct — the moment a second piece of copy
    /// earns its place is the moment to grow one.
    ///
    /// **The line is plain body text.** The apps split evenly between
    /// `text` and `styled(…, .{ .scale = .small, .ink = .dark })`, so
    /// there was nothing to discover and the choice had to be argued:
    /// an empty state is the whole of what that region says, not a
    /// footnote under something else, and de-emphasis spent on the one
    /// sentence a user has to read buys nothing an audit could name. A
    /// screen that genuinely wants more — a second hint line, a control
    /// that fills the emptiness — writes those appends itself, as two
    /// consumer sites do; this is the common floor, not a required door.
    pub fn emptyGate(c: Cursor, phase: load_mod.Load, count: usize, empty: ?[]const u8) !bool {
        if (phase != .ready) return false;
        if (count != 0) return true;
        if (empty) |copy| try c.text(copy);
        return false;
    }

    /// What `confirmSheet` fills a confirmation with. Everything is the
    /// app's own copy, and the two optional lines default to appending
    /// nothing, as `LoadGate`'s do.
    pub const ConfirmSheet = struct {
        /// What is about to happen, in the app's words. Optional
        /// because a sheet whose title already asks the whole question
        /// says nothing twice, and because a confirmation with more to
        /// show — a continuity warning, a typed-name box — appends that
        /// itself before calling this.
        body: ?[]const u8 = null,
        /// What the last attempt reported, said where the user is about
        /// to press again. Plain body copy: nokre has no error styling,
        /// and the words are what carries it.
        error_copy: ?[]const u8 = null,
        /// The act being confirmed — the filled primary.
        confirm: Confirm,
        /// The way out — the secondary beside it.
        cancel: Cancel,
        /// The confirmed act is running: the primary takes
        /// `in_progress`, which is the whole of what a busy
        /// confirmation shows.
        busy: bool = false,

        pub const Confirm = struct {
            label: []const u8,
            on_press: element_mod.Action,
            /// The sheet's own precondition, when it has one — a
            /// checkbox not ticked, a name not typed. Distinct from
            /// `busy`, which the sheet derives from its work.
            disabled: bool = false,
        };

        /// No `disabled`, deliberately — see `confirmSheet`.
        pub const Cancel = struct {
            label: []const u8,
            on_press: element_mod.Action,
        };
    };

    /// The confirmation dialog's body: what is about to happen, what
    /// went wrong last time, and the two buttons — the composition
    /// every confirm sheet in both real consumers wrote identically.
    /// Called on the sheet's own cursor, after `presentSheet` (whose
    /// argument is the title: the question belongs to the sheet, not to
    /// this).
    ///
    /// ```zig
    /// const sheet = app.at(try app.presentSheet(tr(.removeMemberTitle)));
    /// try sheet.confirmSheet(.{
    ///     .body = tr(.removeMemberBody),
    ///     .error_copy = if (self.failed) tr(.couldNotRemove) else null,
    ///     .confirm = .{ .label = tr(.remove), .on_press = .bind(C.confirmRemove, self) },
    ///     .cancel = .{ .label = tr(.cancel), .on_press = .bind(App.closeSheet, app) },
    ///     .busy = self.removing,
    /// });
    /// ```
    ///
    /// **Cancel stays enabled while the act is running**, which is the
    /// question the two consumers disagreed about, settled here. nokre
    /// has no spinner and no animation: a busy confirmation shows a
    /// static `in_progress` primary and nothing else moves, so a user
    /// who cannot tell whether anything is happening must keep the way
    /// out. Taking it away is backwards at the moment the interface is
    /// least legible — and dismissal is reachable anyway, by Esc, by
    /// the scrim, and by the close control the framework pins, so a
    /// disabled Cancel would be a control lying about what the sheet
    /// permits. What a cancelled act owes — a reply landing on a sheet
    /// that is gone — belongs to the handler that started it, not to a
    /// button that pretends the door is locked. The audit already says
    /// the weaker half of this (`sheet_missing_dismiss`: a sheet whose
    /// buttons are all disabled leaves pointer users on Esc-less
    /// platforms with only the pinned ×); this says the rest of it.
    pub fn confirmSheet(c: Cursor, s: ConfirmSheet) !void {
        if (s.body) |copy| try c.text(copy);
        if (s.error_copy) |copy| try c.text(copy);
        try c.button(.{
            .label = s.confirm.label,
            .disabled = s.confirm.disabled,
            .in_progress = s.busy,
            .on_press = s.confirm.on_press,
        });
        try c.button(.{
            .label = s.cancel.label,
            .form = .{ .secondary = null },
            .on_press = s.cancel.on_press,
        });
    }

    /// The one shape every container method shares: append, then stand
    /// on what was appended.
    fn child(c: Cursor, e: element_mod.Element) !Cursor {
        return .{ .tree = c.tree, .at = try c.tree.appendId(c.at, e) };
    }
};

/// Where every screen builder starts: the cursor standing at the tree
/// root.
pub fn root(app: *App) Cursor {
    return .{ .tree = &app.tree, .at = app.tree.rootId() };
}

/// The cursor standing at `id` — the entry for a subtree whose node the
/// framework handed back, which in consumer code is one node:
/// `App.presentSheet`'s.
pub fn at(app: *App, id: NodeId) Cursor {
    return .{ .tree = &app.tree, .at = id };
}

/// The method a role's union field name spells: snake_case tag,
/// camelCase method, nokre's two casing conventions met at their
/// boundary.
fn methodName(comptime role_name: []const u8) []const u8 {
    var out: []const u8 = "";
    var upper = false;
    for (role_name) |ch| {
        if (ch == '_') {
            upper = true;
            continue;
        }
        out = out ++ &[_]u8{if (upper) std.ascii.toUpper(ch) else ch};
        upper = false;
    }
    return out;
}

// The closed-set guarantee, enforced where the checklist promises it:
// an element added to the union without its cursor method does not
// compile. The check is by name — the per-method behavior (right tag,
// container vs leaf) is cursor_test.zig's to prove.
comptime {
    for (@typeInfo(element_mod.Role).@"enum".fields) |f| {
        const m = methodName(f.name);
        if (!@hasDecl(Cursor, m))
            @compileError("element '" ++ f.name ++ "' has no Cursor method '" ++ m ++
                "' — the builder is closed exactly as the element set is; " ++
                "add the method in the same pass (docs/internals/contributing.md)");
    }
}
