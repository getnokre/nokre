//! The modal layers above content: the bottom sheet (`App.openSheetAs`,
//! built by a declared `SheetBuilder`; `App.presentSheet` is the node
//! the builder starts from, `App.closeSheet` takes it back down) and the
//! select picker (opened by activating a `select`). While one is open
//! the rest of the tree is inert — `App.focusScope` and hit testing
//! enforce that; this module owns their lifecycle and focus hand-off.
//!
//! The sheet has an untyped floor and a typed door, and the door is
//! where consumers live: `openSheet` takes the builder as data (the
//! form the framework itself re-runs), `openSheetAs` writes it from a
//! name and a bound builder. The tag those names ride in is one flat
//! `u32` across the whole app, which is why the reading half is
//! `sheetTagAs` — the question with the context in it.

const std = @import("std");
const app_mod = @import("app.zig");
const bind = @import("bind.zig");
const element_mod = @import("element.zig");
const focus = @import("focus.zig");
const input = @import("input.zig");
const layout = @import("layout.zig");
const nav_mod = @import("nav.zig");
const notices = @import("notices.zig");
const tree_mod = @import("tree.zig");

const App = app_mod.App;
const NodeId = tree_mod.NodeId;

// ---- sheet ----

/// A sheet declared as data: the fn the framework calls to build the
/// sheet, and calls again when the screen reloads, so a sheet answers
/// changed state the way a screen does (`RouteDef.build`'s shape). It
/// lives on the App, not the route, because sheets are not
/// route-shaped: one screen can host several controllers' sheets, and
/// one controller's sheet can open from several screens. Held from
/// `openSheet` until the sheet closes — the framework never keeps a
/// builder it was not just handed.
pub const SheetBuilder = struct {
    ctx: ?*anyopaque = null,
    /// The consumer's name for this sheet; `App.sheetTagAs` answers it
    /// while the sheet is up, and `App.openSheetTag()` answers the raw
    /// number. 0 = unnamed. The framework never reads it — it exists so
    /// a controller with several sheets can ask *which* is open instead
    /// of mirroring the answer in its own state. Written by
    /// `openSheetAs` from an enum, which is the shape every consumer
    /// packed into it by hand.
    tag: u32 = 0,
    /// Presents the sheet (`App.presentSheet`) and fills it from state.
    /// It always runs against a tree with no sheet in it — the
    /// framework takes an open one down first, so building is building
    /// from scratch, and the builder never calls `dismissSheet` itself.
    /// Presenting nothing is how a builder declines — the sheet's
    /// subject can vanish under it — and quietly drops the builder,
    /// with no `on_dismiss`: the state it reads already knows.
    call: *const fn (ctx: ?*anyopaque, app: *App) anyerror!void,
    /// Told when the framework takes the sheet away — Esc, the close
    /// control, a tap outside, a navigation — so the state the builder
    /// reads can record a closure it did not initiate. Clear state
    /// here; do not navigate or present.
    on_dismiss: ?*const fn (ctx: ?*anyopaque) void = null,
};

/// Everything the sheet doors answer — a *declared* set where the
/// builder's `anyerror` used to be. A sheet is opened from a handler
/// that returns nothing (a button's `Action`), so the caller's whole
/// vocabulary is what it can do about a sheet that did not open, and
/// against `anyerror` that came to `catch {}` at every site: an error
/// nobody can name is an error nobody handles. Two members, because a
/// caller acts on exactly two things.
pub const OpenSheetError = error{
    /// The tree could not grow. Not about this sheet at all — the
    /// process is out of room — and kept separate for the app that
    /// reports memory pressure differently from a dialog that failed.
    OutOfMemory,
    /// The builder said no: it returned an error of its own, or the
    /// content it appended was refused at construction. Either way no
    /// sheet is up and the screen behind is untouched.
    ///
    /// The builder's own error *identity* stops here. A builder that
    /// must tell its failures apart catches them inside itself, where
    /// it still has them and is the only code that knows what they
    /// meant; what crosses this door is the one bit the opener can act
    /// on.
    SheetBuildFailed,
};

/// Opens the sheet `builder` describes, and keeps the builder: the
/// framework runs it again after `App.reload` rebuilds the screen, so
/// an open sheet answers changed state instead of dying with the tree
/// it stood on. A consumer whose state changed under an open sheet
/// calls this again — same builder, no ceremony: an open sheet is
/// rebuilt in place, never stacked. However the sheet then closes —
/// `closeSheet`, `dismissSheet`, Esc, the close control, a tap
/// outside, a navigation — the builder is dropped and its `on_dismiss`
/// told.
///
/// A controller whose sheets are named takes `openSheetAs` instead,
/// which is this verb with the tag typed and the context bound.
pub fn openSheet(app: *App, builder: SheetBuilder) OpenSheetError!void {
    teardownSheet(app);
    app.sheet_builder = builder;
    // A builder that fails half-way strands no half-built dialog: the
    // sheet comes down whole and the error surfaces at the caller.
    errdefer {
        teardownSheet(app);
        app.sheet_builder = null;
    }
    builder.call(builder.ctx, app) catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.SheetBuildFailed,
    };
    if (layout.findSheet(&app.tree) == null) app.sheet_builder = null;
}

/// `openSheet` with the sheet's name typed and its context bound: the
/// door a controller with named sheets takes.
///
/// ```zig
/// const Sheet = enum(u32) { remove_member = 1, refresh_code };
///
/// // at the point the user asks for it:
/// try app.openSheetAs(Sheet.remove_member, Security.render, self);
///
/// // in Security — a sheet builder is written like a screen builder:
/// fn render(self: *Security, app: *App, which: Sheet) !void {
///     const sheet = app.at(try app.presentSheet(self.title(which)));
///     switch (which) { … }
/// }
/// ```
///
/// The name arrives at the builder as the enum it was opened with,
/// because at that point the framework knows it: the builder it is
/// running is the one it just installed. That is the whole prologue
/// every controller wrote — the cast, `openSheetTag() orelse return`,
/// `@enumFromInt` — and none of the three says anything the caller of
/// this line did not already say.
///
/// A builder that has nothing to tell apart drops the parameter:
/// `fn (self: *State, app: *App) !void`, exactly a `Routes(State)`
/// screen builder. Nothing decides between the two forms but the
/// builder's own parameter list, and Zig refuses an unused parameter,
/// so the form that compiles is the honest one. A sheet is still
/// *named* either way — that is what makes `sheetTagAs` able to say the
/// open sheet is yours, which a controller with one sheet needs most,
/// being the kind that used to leave it unnamed and read another
/// controller's tag as its own.
///
/// A sheet that owes work when it closes declares the `SheetBuilder`
/// itself and hands it to `openSheet`: `on_dismiss` is a second
/// function over the same context, and binding fills a pair, not a
/// struct (core/bind.zig).
pub fn openSheetAs(app: *App, tag: anytype, comptime render: anytype, state: anytype) OpenSheetError!void {
    const E = @TypeOf(tag);
    comptime checkTagEnum(E, "openSheetAs");
    // Bound either way — the name is what decides *what* gets bound.
    // A builder that takes it is bound through a generated fn that
    // reads it back out; one that does not is handed to `bindAs`
    // untouched, so a mis-shaped builder fails against `bindAs`'s own
    // curated comparison rather than a second copy of it.
    var builder = if (comptime takesTag(E, render, @TypeOf(state)))
        bind.bindAs(SheetBuilder, Named(E, render, @TypeOf(state)).build, state)
    else
        bind.bindAs(SheetBuilder, render, state);
    builder.tag = @intFromEnum(tag);
    return openSheet(app, builder);
}

/// Whether `render` is the form that takes the sheet's name. Three
/// parameters is the only thing that can mean it, so a builder with any
/// other arity is refused here with both shapes printed.
fn takesTag(comptime E: type, comptime render: anytype, comptime StatePtr: type) bool {
    const F = switch (@typeInfo(@TypeOf(render))) {
        .pointer => |p| p.child,
        else => @TypeOf(render),
    };
    const info = switch (@typeInfo(F)) {
        .@"fn" => |f| f,
        else => @compileError(std.fmt.comptimePrint(
            "openSheetAs: `render` is `{s}`, not a function. A sheet is built by one.",
            .{@typeName(@TypeOf(render))},
        )),
    };
    const fits = switch (info.params.len) {
        2 => true,
        3 => info.params[2].type == E,
        else => false,
    };
    if (!fits) @compileError(std.fmt.comptimePrint(
        "openSheetAs: this builder is neither sheet-builder shape.\n" ++
            "  with the name: fn ({s}, *App, {s}) !void\n" ++
            "  without it:    fn ({s}, *App) !void\n" ++
            "  found:         {s}",
        .{ @typeName(StatePtr), @typeName(E), @typeName(StatePtr), @typeName(@TypeOf(render)) },
    ));
    return info.params.len == 3;
}

/// The generated builder for the named form: reads the name the sheet
/// was opened with and hands it over typed. `bindAs` still owns the
/// context — the erasure, the cast, the null unwrap — so this adds the
/// one thing binding cannot know and nothing else.
fn Named(comptime E: type, comptime render: anytype, comptime StatePtr: type) type {
    return struct {
        fn build(self: StatePtr, app: *App) anyerror!void {
            // The name is this builder's own, installed a line before
            // it ran. It answers null only where something re-installed
            // a foreign one over this context, and a builder that
            // cannot say which sheet it is declines rather than guess:
            // presenting nothing is how a builder says no.
            return render(self, app, sheetTagAs(app, E, self) orelse return);
        }
    };
}

/// The open sheet's `SheetBuilder.tag` — null when no declared sheet
/// is up, the declared tag (0 for an unnamed one) while one is. The
/// kept builder carries it, so it survives everything the sheet itself
/// survives: `refresh`'s re-present, `reload`'s carry, `openSheet`'s
/// rebuild-in-place. It answers *from the builder's own installation
/// on*, so a builder can read its own tag mid-build. A bare
/// `presentSheet` with no declared builder answers null — that sheet
/// has no consumer name, and dies on reload besides.
///
/// This is the raw answer over a namespace every controller shares:
/// "which sheet is up", including one this caller has never heard of.
/// The question a controller means is almost always `sheetTagAs`'s —
/// "is *mine* up, and which" — and asking it this way instead is how a
/// tag from another controller gets read as one of your own.
pub fn openSheetTag(app: *const App) ?u32 {
    const builder = app.sheet_builder orelse return null;
    return builder.tag;
}

/// Which of *this* controller's sheets is up: the open builder's tag as
/// an `E`, and null unless the open sheet is one this `ctx` opened.
///
/// The tag namespace is flat and shared — every controller in an app
/// mints into the same `u32` — so `openSheetTag` alone cannot say
/// whether the number it just handed back is yours. Two controllers
/// whose enums both start at 1 read each other's sheets as their own,
/// which is the hazard, and it shows up as a controller re-presenting
/// its dialog over whatever was open. The context is what disambiguates
/// them, and it is already on the kept builder, so nothing new is
/// stored to answer this.
///
/// `ctx` is the same pointer the sheet was opened with — the controller
/// itself at every real site (`openSheetAs` binds it for you). A tag
/// this controller minted from some *other* enum answers null too: it
/// is not a member of `E`, so it is not this question's answer, and
/// reading it as one would be an illegal cast.
pub fn sheetTagAs(app: *const App, comptime E: type, ctx: ?*anyopaque) ?E {
    comptime checkTagEnum(E, "sheetTagAs");
    const builder = app.sheet_builder orelse return null;
    if (builder.ctx != ctx) return null;
    return std.enums.fromInt(E, builder.tag);
}

/// Takes the sheet down and rebuilds the screen behind it — the pair
/// every consumer wrote at every close, once.
///
/// The rebuild is `reload`, not `refresh`: closing a sheet is the
/// user's own gesture (they pressed Cancel, or the work finished), and
/// the deliberate verb is the one that does not ask permission. Its
/// error is swallowed here for the reason `App.refresh` swallows the
/// same one — nothing at a close handler can act on a failed rebuild,
/// the state is already written, and the next navigation or gesture
/// builds the screen from it. The one failure that is a programmer
/// error, a `reload` issued from inside a builder, is recorded by the
/// router either way (`Router.refused`), so the `catch` hides nothing.
///
/// **Every gesture that closes a sheet arrives here** — Esc, the scrim,
/// the pinned × (input.zig), and a consumer's own Cancel. That is what
/// makes `App.refresh` safe to decline a rebuild while a sheet is up: a
/// controller that writes state behind its own dialog is answered by
/// the sheet's re-present now and by this reload the moment the sheet
/// goes, rather than at some unrelated later rebuild, detached from the
/// action that caused it. Route a fourth door through `dismissSheet`
/// and that decline starts losing screens again.
pub fn closeSheet(app: *App) void {
    dismissSheet(app);
    app.reload() catch {};
}

/// Re-runs the kept builder — the router's arm of `openSheet`'s
/// promise, called after a reload's rebuild. No-op without one.
pub fn representSheet(app: *App) OpenSheetError!void {
    const builder = app.sheet_builder orelse return;
    try openSheet(app, builder);
}

/// What a sheet enum must be, checked at both typed doors so a bad one
/// fails at the call that names it rather than at the cast inside.
///
/// The tag on the wire is a `u32` whose 0 means *unnamed* — the sheet a
/// controller with only one never bothered to name. An enum minting 0
/// would make "this sheet has no name" and "this sheet is my first one"
/// the same answer, at the one door whose whole job is telling sheets
/// apart, so it is refused here instead: start the enum at 1.
fn checkTagEnum(comptime E: type, comptime who: []const u8) void {
    const info = switch (@typeInfo(E)) {
        .@"enum" => |e| e,
        else => @compileError(std.fmt.comptimePrint(
            "{s}: `{s}` is not an enum. A sheet's name is one member of the enum " ++
                "listing that controller's sheets.",
            .{ who, @typeName(E) },
        )),
    };
    for (info.fields) |f| {
        if (f.value == 0) @compileError(std.fmt.comptimePrint(
            "{s}: `{s}.{s}` is 0, which is how a sheet says it has no name at all. " ++
                "Start the enum at 1: `enum(u32) {{ {s} = 1, … }}`.",
            .{ who, @typeName(E), f.name, f.name },
        ));
        if (f.value < 0 or f.value > std.math.maxInt(u32)) @compileError(std.fmt.comptimePrint(
            "{s}: `{s}.{s}` is {d}, which does not fit the `u32` a sheet's tag rides in.",
            .{ who, @typeName(E), f.name, f.value },
        ));
    }
}

/// Forgets the kept builder and tells its `on_dismiss` — the
/// bookkeeping half of a dismissal, shared with the router's
/// navigations, whose `clearContent` already took the node itself.
pub fn dropSheetBuilder(app: *App) void {
    const builder = app.sheet_builder orelse return;
    app.sheet_builder = null;
    if (builder.on_dismiss) |told| told(builder.ctx);
}

/// Opens a modal bottom sheet and returns its node to fill with
/// content — the verb a `SheetBuilder` starts from. While it is open
/// the rest of the tree is inert: focus, taps, and scrolling stay
/// inside. A close control (×, accessible name "Close") is pinned to
/// the header corner — an inescapable sheet cannot be built — and Esc
/// or tapping outside also close — all three through `closeSheet`, so
/// the screen behind is rebuilt whichever the user reaches for. Focus
/// moves in now and returns to the invoking element on dismissal.
pub fn presentSheet(app: *App, title: []const u8) !NodeId {
    closePicker(app, null); // an in-flight choice does not survive a new layer
    // Whatever this sheet is, it is not the one a folded row opened —
    // `overflow.presentMoreSheet` says so itself, afterwards.
    app.more_sheet = null;
    const sheet = try app.tree.appendId(app.tree.rootId(), .{ .sheet = .{ .title = title } });
    // A sheet without its close control is inescapable chrome; if the
    // control cannot be built, neither is the sheet.
    errdefer app.tree.remove(sheet) catch {};
    try app.tree.append(sheet, .{ .sheet_close = .{ .label = app.chrome.close } });
    app.sheet_return_focus = app.focused;
    app.focused = focus.firstFocusable(&app.tree, sheet);
    // The sheet wins the bottom pane; the banner or notices pane
    // waits as the minimized indicator until dismissal.
    try notices.syncNoticeChrome(app);
    app.invalidate();
    return sheet;
}

/// Takes the sheet down and leaves the screen behind exactly as it
/// stood. No-op when no sheet is open.
///
/// The half of `closeSheet` without the rebuild, for the two callers a
/// rebuild would be wrong for: a stale folded-tail sheet dropped from
/// inside layout (overflow.zig), and a sheet taken down on the way to a
/// navigation that is about to build the screen itself. A *user's*
/// close is not one of those — it takes `closeSheet`, whose doc says
/// why — and a consumer that dismisses here after writing state has
/// promised to rebuild the screen itself, because `App.refresh` will
/// not have.
pub fn dismissSheet(app: *App) void {
    teardownSheet(app);
    dropSheetBuilder(app);
}

/// The node's half of a dismissal — removal and the focus hand-back —
/// without touching the kept builder: `openSheet` rebuilds through
/// here, and a rebuild is not a closure.
fn teardownSheet(app: *App) void {
    const sheet = layout.findSheet(&app.tree) orelse return;
    closePicker(app, null); // its owner may be about to go with the sheet
    app.more_sheet = null;
    app.tree.remove(sheet) catch {};
    app.focused = if (app.sheet_return_focus) |f|
        (if (app.tree.getConst(f.node) != null) f else null)
    else
        null;
    app.sheet_return_focus = null;
    notices.syncNoticeChrome(app) catch {};
    app.invalidate();
}

// ---- picker ----

/// Option count at which the picker gains a filter field: fewer
/// rows scan faster by eye than by typing.
///
/// Exported because it bounds something outside this file. A collapsed
/// nav's whole roster is one of these lists and the section picker
/// carries no filter, so `nav.max_nav_items` is this number less the
/// row an off-roster screen may add — a derivation rather than a second
/// guess at where scanning ends.
pub const picker_filter_min = 8;

/// Opens the modal option picker for a select: its label as the
/// title, one row per option, focus on the current choice. Long
/// lists (>= `picker_filter_min` options) get a filter field pinned
/// above the rows, focused on open — those lists want typing, not
/// scanning. Stacks above everything, an open sheet included.
pub fn openPicker(app: *App, select_id: NodeId) !void {
    if (layout.findPicker(&app.tree) != null) return;
    const sel = app.tree.getConst(select_id).?.select;
    const picker = try app.tree.appendId(app.tree.rootId(), .{ .picker = .{
        .title = sel.label,
        .option_count = sel.options.len,
    } });
    const filtered = sel.options.len >= picker_filter_min;
    if (filtered) {
        try app.tree.append(picker, .{ .text_input = .{
            .label = "Filter",
            .on_change = .{ .ctx = app, .call = onPickerFilter },
        } });
    }
    const region = try app.tree.appendId(picker, .{ .scroll_region = .{ .height = 0 } });
    try fillPickerRows(app, region, sel, "");
    app.focused = if (filtered)
        focus.firstFocusable(&app.tree, picker)
    else blk: {
        var it = app.tree.children(region);
        while (it.next()) |c| {
            const el = app.tree.getConst(c).?;
            if (el.role() == .picker_item and el.picker_item.selected) break :blk .of(c);
        }
        break :blk null;
    };
    app.picker_owner = select_id;
    app.invalidate();
    input.revealFocused(app);
}

/// One row per option whose label contains `filter`
/// (ASCII-case-insensitively); "No matches" words when none does.
fn fillPickerRows(app: *App, region: NodeId, sel: element_mod.Select, filter: []const u8) !void {
    // ASCII-only case folding; Unicode options still match exactly.
    // Full case folding needs tables nokre doesn't carry.
    for (sel.options, 0..) |opt, i| {
        if (filter.len > 0 and std.ascii.indexOfIgnoreCase(opt, filter) == null) continue;
        try app.tree.append(region, .{ .picker_item = .{
            .label = opt,
            .selected = i == sel.selected,
            .index = i,
        } });
    }
    if (app.tree.childCount(region) == 0) {
        try app.tree.append(region, .{ .text = .{ .content = "No matches" } });
    }
}

fn onPickerFilter(ctx: ?*anyopaque, value: []const u8) void {
    const app: *App = @ptrCast(@alignCast(ctx.?));
    refilterPicker(app, value) catch {};
}

/// Rebuilds the picker's rows to the options matching `filter`.
fn refilterPicker(app: *App, filter: []const u8) !void {
    const picker = layout.findPicker(&app.tree) orelse return;
    const owner = app.picker_owner orelse return;
    // The tree can rebuild under an open picker; a stale owner filters
    // nothing rather than dereferencing a dead generation, the same
    // tolerance `closePicker` keeps.
    const sel = (app.tree.getConst(owner) orelse return).select;
    var region: ?NodeId = null;
    var it = app.tree.children(picker);
    while (it.next()) |c| {
        if (app.tree.getConst(c).?.role() == .scroll_region) region = c;
    }
    const reg = region orelse return;
    while (true) {
        var cit = app.tree.children(reg);
        const c = cit.next() orelse break;
        try app.tree.remove(c);
    }
    if (app.tree.get(reg)) |el| el.scroll_region.offset = 0;
    try fillPickerRows(app, reg, sel, filter);
    app.invalidate();
}

/// The collapsed nav's picker: the roster as rows, the current section
/// selected, opened by the chip that stands in for it
/// (`nav.syncNavChrome`). It is the select's picker in every respect but
/// where the options come from — the App's roster rather than an
/// element's `options` — so the modal layer, the focus hand-off, the
/// keyboard, and Esc are all the same code and cannot drift apart.
///
/// The title is the framework's own word, in the app's language
/// (`App.Chrome.sections`): no consumer named this control, so no
/// consumer's *data* can name it — only their catalog can. It is not
/// drawn — a card standing on the chip is named by the chip
/// (`renderer.drawNavMenu`) — but it is still what assistive tech is
/// told the dialog is called, which is the job it was written for.
pub fn openNavPicker(app: *App, nav_current: NodeId) !void {
    if (layout.findPicker(&app.tree) != null) return;
    // The same list the chip was built from, so the row it selects and
    // the row a choice commits are the same numbering. On an off-roster
    // screen that list ends with the screen itself: a combo box whose
    // value is one of its own options, rather than a chip naming
    // something the list it opens does not contain.
    var buf: nav_mod.RosterBuf = undefined;
    const roster = nav_mod.effectiveRoster(app, &buf);
    const current = nav_mod.currentIndex(app);
    const picker = try app.tree.appendId(app.tree.rootId(), .{ .picker = .{
        .title = app.chrome.sections,
        .option_count = roster.len,
        .above_nav = true,
    } });
    const region = try app.tree.appendId(picker, .{ .scroll_region = .{ .height = 0 } });
    // A roster (plus at most the screen's own entry) is always under
    // `picker_filter_min`, so there is no filter field to build and no
    // filtered/unfiltered split to keep: row position and roster index
    // stay the same number. That is not a hope about how many
    // destinations an app declares — `nav.max_nav_items` is derived
    // from this bound, so the list cannot reach it.
    for (roster, 0..) |item, i| {
        try app.tree.append(region, .{ .picker_item = .{
            .label = item.label,
            .selected = if (current) |c| c == i else false,
            .index = i,
            .icon = item.icon,
        } });
    }
    app.focused = blk: {
        var it = app.tree.children(region);
        while (it.next()) |c| {
            if (app.tree.getConst(c).?.picker_item.selected) break :blk .of(c);
        }
        break :blk focus.firstFocusable(&app.tree, picker);
    };
    app.picker_owner = nav_current;
    app.invalidate();
    input.revealFocused(app);
}

/// Removes the picker; commits `choice` to the owner when given — the
/// select's option, or the nav's section. Focus returns to the owner.
/// No-op when none is open.
pub fn closePicker(app: *App, choice: ?usize) void {
    const picker = layout.findPicker(&app.tree) orelse return;
    app.tree.remove(picker) catch {};
    const owner = app.picker_owner;
    app.picker_owner = null;
    app.focused = if (owner) |id|
        (if (app.tree.getConst(id) != null) .of(id) else null)
    else
        null;
    app.invalidate();
    const el = app.tree.get(owner orelse return) orelse return;
    switch (el.*) {
        .select => |*s| {
            const idx = choice orelse return;
            if (idx >= s.options.len or idx == s.selected) return;
            s.selected = idx;
            s.on_select.invoke(idx);
        },
        .nav_current => {
            const idx = choice orelse return;
            var buf: nav_mod.RosterBuf = undefined;
            const roster = nav_mod.effectiveRoster(app, &buf);
            if (idx >= roster.len) return;
            // The row's rule, reached by the other shape: a push, and a
            // no-op when the screen you picked is the one showing. The
            // select's arm declines the same no-op for the same reason.
            // The screen's own entry is declined by exactly that rule
            // and needs no arm of its own — it carries the current
            // reference, so `isCurrent` recognizes it.
            const route = roster[idx].route;
            if (nav_mod.isCurrent(app, route)) return;
            app.router.push(app, route) catch return;
            // After the push, not before: the rebuild resyncs the nav
            // and the chip the owner id named is gone. Focus follows the
            // chrome to the node that replaced it, so a keyboard user
            // keeps their place (the `nav_item` arm of `input.activate`
            // does this for the row).
            app.focused = if (layout.findNav(&app.tree)) |nav| blk: {
                var it = app.tree.children(nav);
                break :blk if (it.next()) |c| .of(c) else null;
            } else null;
        },
        else => {},
    }
}

/// The option index a picker row commits: carried on the row itself,
/// because filtering breaks the row-position/option-index identity.
pub fn pickerIndexOf(app: *const App, item: NodeId) ?usize {
    const el = app.tree.getConst(item) orelse return null;
    return el.picker_item.index;
}

/// ↑/↓ between option rows, clamped at the ends — no wrap, like a
/// native select.
pub fn movePickerFocus(app: *App, item: NodeId, delta: i32) void {
    const region = app.tree.parentOf(item) orelse return;
    var prev: ?NodeId = null;
    var it = app.tree.children(region);
    while (it.next()) |c| {
        if (c.eql(item)) {
            const next = if (delta < 0) prev else it.next();
            if (next) |n| {
                app.focused = .of(n);
                app.needs_frame = true;
                input.revealFocused(app);
            }
            return;
        }
        prev = c;
    }
}
