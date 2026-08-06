//! Navigation is a stack of named screens. Pushing, popping, replacing,
//! or switching sections rebuilds the tree via the route's registered
//! builder — instantly. Nav chrome installed by `App.setNav` survives
//! rebuilds. There are no transitions and never will be.
//!
//! A screen is named by a *reference*: a route name plus its positional
//! arguments, `note~42` (docs/routing.md). Everything that points at a
//! screen carries one — a `link`, a `tile`, a Markdown destination,
//! `navigate`, the web address bar — and resolution is the one place
//! that parses it. Each stack entry owns the reference it was entered
//! with, so two `note` screens pushed for different notes are different
//! entries and popping back to the first still knows which note it was.
//! An entry remembers where its screen was *scrolled* to as well: the
//! rebuild is still from scratch and still instant — what comes back is
//! a viewport, not a tree — but a screen returning to the top of a list
//! the user was halfway down is a different screen wearing the same
//! name, and no builder can be asked to put that back itself.
//!
//! The stack lives here and only here. What leaves is the reference of
//! the screen on top: every change announces it to an optional observer,
//! which the web shell mirrors into the address bar and every other
//! shell leaves null. A reference is an identity for a screen — one
//! screen, one reference, wherever the user came from — so the trail
//! that led there stays in memory where it belongs.
//!
//! A reference that does not resolve is a *refusal*, not an error. The
//! four ways one can be wrong — unknown name, wrong arity, an argument
//! outside the charset, over-long — plus the one wrong *moment*, a
//! `reload` issued while its own screen's builder is running
//! (`building`), are all programmer errors, and no
//! call site has anything to do with one but drop it: the consumer
//! survey that drove this found 87 `catch {}` around navigation and not
//! one handler. So the navigating verbs leave the stack exactly as it
//! was and record what they refused in `refused`, where the audit —
//! which the harness runs after every action — turns it into a failing
//! test with the reference in the diagnostic. What is left in a verb's
//! error set is the machine failing (allocation, and the screen
//! builder's own errors), which a `catch {}` is an honest answer to.
//! Bytes from outside the program — an address bar, a deep link, a
//! notification payload — are vetted at the door with `vet`, so a
//! stranger's typo never lands in the programmer-error record.

const std = @import("std");
const app_mod = @import("app.zig");
const focus_mod = @import("focus.zig");
const nav_mod = @import("nav.zig");
const overlays = @import("overlays.zig");
const tree_mod = @import("tree.zig");

const App = app_mod.App;
const NodeId = tree_mod.NodeId;

pub const RouteDef = struct {
    name: []const u8,
    /// What chrome calls this screen: every line of the nav's roster —
    /// the declared destinations and, on a screen that is none of them,
    /// the screen itself — is labelled from here (`nav.effectiveRoster`).
    /// One screen, one name, wherever it is being named from; a roster
    /// that carried its own labels would be a second place for the same
    /// fact to be wrong.
    ///
    /// Required, with no default, so a screen that cannot be named is a
    /// compile error at the route table and not a blank chip at run
    /// time. The alternative was to derive it: from `name`, which is an
    /// identifier and reads like one (`sign_in`), or from the screen's
    /// first heading, which is *content* — a builder may lead with
    /// anything, may localize it, may not have one at all, and nothing
    /// obliges it to still be there after the next edit.
    ///
    /// That refusal held, and the arrow now runs the other way: the
    /// page's `h1` is drawn from this title (`Router.rebuild`,
    /// `Tree.setTitle`) rather than this title being read off the page.
    /// Deriving a declaration from content was the mistake; drawing
    /// content from a declaration is what a declaration is for. So the
    /// nav's roster, the collapsed chip, the off-roster marker and the
    /// top of the page all say one thing, and a screen whose reader-
    /// facing title is per-reference restates only that one
    /// (`App.setTitle`) — the chrome goes on naming the *route*, which
    /// is what a roster of destinations whose builders have not run can
    /// name at all.
    ///
    /// It names the route, not the screen: `note~42` and `note~43` are
    /// both "Note". A `.of_locale` function is a function of the app's
    /// chosen locale and of nothing else — never of the reference — so
    /// this stays the one home for what a screen is called in *every*
    /// language, without becoming a per-screen callback.
    title: Title,
    /// How many positional arguments this screen takes. Declared, so a
    /// reference carrying the wrong number fails loudly instead of
    /// building a screen with nothing to show.
    args: u8 = 0,
    build: Build,

    /// What a screen builder is, erased. The context is the *app's* —
    /// `App.ctx`, one for the whole table, handed back at every rebuild —
    /// which is why a `RouteDef` carries no context of its own and why
    /// this is not a bindable `{ ctx, call }` pair (core/bind.zig): the
    /// state arrives at call time from the app, not at wiring time from
    /// the site that named the function. `Routes(State)` types it.
    pub const Build = *const fn (ctx: ?*anyopaque, app: *App) anyerror!void;
};

/// The route table with its `App.ctx` typed once, for the app that has
/// one state type — which is every app there has ever been. A survey of
/// the three consumer trees found 91 routed builders (42 + 17 + 32), and
/// every one of them opened by casting the context to that tree's single
/// state type, first statement, no exceptions. The erasure was never
/// carrying polymorphism; it was carrying a cast.
///
/// ```zig
/// const R = nokre.Routes(State);
/// const routes = R.table(&.{
///     .{ .name = "notes", .title = .{ .fixed = "Notes" }, .build = buildNotes },
///     .{ .name = "note", .title = .{ .fixed = "Note" }, .args = 1, .build = buildNote },
/// });
///
/// fn buildNotes(state: *State, app: *nokre.App) !void { ... }
/// ```
///
/// The entries are what they always were, so a table that grows to fifty
/// reads exactly as it does today; what changed is that the state type is
/// said once, at the top, instead of once per screen. What comes back is
/// an ordinary `[N]RouteDef`, which is the point: this is sugar over the
/// substrate the way `Cursor` is sugar over `Tree.append`, and a table
/// that mixes both — a stateless screen written raw beside typed ones —
/// is a table of the same values.
///
/// The one assertion left is the one no local type could have made
/// anyway: that `App.init`'s `ctx` really is a `*State`. It is now made
/// once, at that line, instead of at every builder (see `App.ctx`).
pub fn Routes(comptime State: type) type {
    return struct {
        /// A screen builder with its state restored: everything
        /// `RouteDef.build` is, minus the cast.
        pub const Build = *const fn (state: *State, app: *App) anyerror!void;

        /// A route as it is written — `RouteDef` with the typed builder.
        /// A handler that does not fit is a coercion error naming both
        /// signatures at the table entry, which is where the mistake is.
        ///
        /// **Reified from `RouteDef`, never re-listed.** A hand-written
        /// twin would be a second home for a route's shape: add a field
        /// to `RouteDef` and every typed table would silently drop it,
        /// with nothing failing anywhere. Here there is no twin to drift
        /// — a new field arrives with its own default and `table` carries
        /// it without a line changing. The price is that a reified struct
        /// carries no doc comments, so `RouteDef` stays where each field
        /// is explained; read it there.
        pub const Def = TypedDef(Build);

        /// The table, lowered. Call it at container scope and hand
        /// `App.init` the result's address, as with any route table.
        pub fn table(comptime defs: []const Def) [defs.len]RouteDef {
            var out: [defs.len]RouteDef = undefined;
            inline for (defs, &out) |d, *o| {
                // Field by field over `RouteDef`'s own list, so what a
                // route carries is asked of `RouteDef` at every build
                // rather than remembered here. `build` is the one field
                // this type exists to change; everything else moves
                // across untouched and unnamed.
                inline for (@typeInfo(RouteDef).@"struct".fields) |fld| {
                    if (comptime std.mem.eql(u8, fld.name, "build")) {
                        o.build = builder(d.build);
                    } else {
                        @field(o, fld.name) = @field(d, fld.name);
                    }
                }
            }
            return out;
        }

        /// One lowered builder, for a table an app assembles itself —
        /// both consumer apps lower their own entry type (a catalog key
        /// for a title, not a `Title`), and the site generates one
        /// builder per page. They need the trampoline, not the table.
        /// It is also what a test fixture hands the harness's `build`.
        pub fn builder(comptime f: Build) RouteDef.Build {
            return struct {
                fn build(ctx: ?*anyopaque, app: *App) anyerror!void {
                    return f(@ptrCast(@alignCast(ctx.?)), app);
                }
            }.build;
        }
    };
}

/// `RouteDef` with `build` swapped for a typed one, reified from
/// `RouteDef`'s own field list. The same mechanism `App.Options` uses to
/// drop a default (`app.zig`, `WithoutDefault`), and for the same reason:
/// a struct that differs from another by one field is *derived* from it,
/// so the two cannot disagree about the rest.
fn TypedDef(comptime Build: type) type {
    const src = @typeInfo(RouteDef).@"struct".fields;
    var names: [src.len][]const u8 = undefined;
    var types: [src.len]type = undefined;
    var attrs: [src.len]std.builtin.Type.StructField.Attributes = undefined;
    for (src, &names, &types, &attrs) |f, *name, *Ty, *attr| {
        const typed = std.mem.eql(u8, f.name, "build");
        name.* = f.name;
        Ty.* = if (typed) Build else f.type;
        attr.* = .{
            // A builder is required on a route and required here: a
            // default would let a table entry name no screen.
            .default_value_ptr = if (typed) null else f.default_value_ptr,
            .@"align" = if (typed) @alignOf(Build) else f.alignment,
        };
    }
    return @Struct(.auto, null, &names, &types, &attrs);
}

/// What a `RouteDef.title` is: the words themselves, or the words as a
/// function of the app's chosen locale (`App.setLocale`).
///
/// An app in one language writes `.{ .fixed = "Notes" }` and is done. A
/// translated app writes `.{ .of_locale = notesTitle }` and the title
/// follows the locale wherever it is read — the nav's roster, the
/// collapsed chip, the marker for an off-roster screen — with no second
/// table to hand over and no positional re-stamp to forget.
///
/// Either way the bytes are **borrowed, never owned**: a `.fixed` title
/// is a literal, and a `.of_locale` function must answer from constant
/// data (a catalog's `tr` does), because everything downstream — the
/// roster, the tree — borrows what it is given.
pub const Title = union(enum) {
    /// One language: the title as written, whatever the locale.
    fixed: []const u8,
    /// The title in the chosen locale, asked by tag. The function must
    /// answer *every* tag, the empty one included — "" is "the app
    /// never chose", and a catalog's `resolve` already reads it as the
    /// template.
    of_locale: *const fn (locale_tag: []const u8) []const u8,

    /// The words, under `locale_tag` — the one reader, so no call site
    /// holds the switch.
    pub fn text(self: Title, locale_tag: []const u8) []const u8 {
        return switch (self) {
            .fixed => |s| s,
            .of_locale => |f| f(locale_tag),
        };
    }
};

/// Separates a route name from its arguments: `note~42`, `sum~10~5`.
///
/// Not `/`, which promises that every prefix is itself a resource and so
/// invites truncation to `note` — with a declared arity that is an
/// error, not a parent. Not `.`, which collides with real argument
/// content and is therefore worth keeping *legal inside* one. `~`
/// carries no such convention, cannot appear in an identifier, and
/// survives `encodeURIComponent` unchanged, which is what keeps a
/// reference and its rendering in an address bar the same bytes.
pub const arg_separator = '~';

/// A reference can arrive from outside the app, and one enormous
/// argument would pass the arity check. The stack owns a copy of every
/// reference on it, so the bound is on the copy.
pub const max_ref_bytes = 256;

/// How many scroll positions one entry remembers (see `Entry`). Bounded
/// for the same reason `max_ref_bytes` is: a screen may nest
/// arbitrarily many regions, an entry may not grow arbitrarily. Past
/// this the deepest regions come back at the top, which is what every
/// screen did before any of this.
pub const max_saved_regions = 16;

/// The bytes a route name or an argument may contain. Deliberately a
/// conservative subset of what survives `encodeURIComponent`: `.` and
/// `-` are in, so versions, ids and slugs are arguments without
/// escaping, and everything else is not, because an argument is an
/// identifier and not a payload. Free text is a URL, which is
/// deep_link's business (docs/services.md).
fn validIdent(s: []const u8) bool {
    if (s.len == 0) return false;
    for (s) |c| switch (c) {
        'a'...'z', 'A'...'Z', '0'...'9', '_', '.', '-' => {},
        else => return false,
    };
    return true;
}

/// Which motion put the app on the current route. The router's own
/// vocabulary, not any shell's: a shell that mirrors the route decides
/// for itself what each motion means where it renders
/// (docs/internals/platform-shells.md).
pub const Change = enum { push, pop, replace, switch_to };

// The ordinals are a wire contract: the DOM driver exports the latest
// motion as `@intFromEnum` and live.js indexes its MOTION table with
// it. Append only; a reorder here without live.js turns a pop into a
// push in the browser's history.
comptime {
    const assert = @import("std").debug.assert;
    assert(@intFromEnum(Change.push) == 0 and @intFromEnum(Change.switch_to) == 3 and @typeInfo(Change).@"enum".fields.len == 4);
}

/// Installed by a shell that has somewhere to show the current route,
/// left null by every shell that does not — the `workers.Wake` shape.
/// `route` is the full reference, and it is borrowed **only for the
/// call**: it belongs to the stack entry and dies with it, so an
/// observer that wants to keep it copies it.
pub const RouteObserver = struct {
    ctx: ?*anyopaque = null,
    call: ?*const fn (ctx: ?*anyopaque, route: []const u8, change: Change) void = null,
};

/// What a navigating verb refused, and why — the record `Router.refused`
/// keeps. It owns a bounded copy of the reference (an over-long one is
/// truncated to `max_ref_bytes` — enough to name the culprit) because
/// the caller's bytes may be gone by the time anyone reads it.
pub const Refusal = struct {
    reason: Reason,
    len: u16,
    bytes: [max_ref_bytes]u8,

    /// One name per way `resolve` can say no — the same taxonomy `writeRef`
    /// reports as errors: there the caller is the site *building* the
    /// reference and can act; here nobody can, which is the whole
    /// argument for a record over an error. Plus the one refusal that
    /// is not `resolve`'s: a `reload` issued while `rebuild` is already
    /// running a builder (see `Router.building`), which no error set
    /// could reach either — the call site is a callback three frames
    /// from the builder that makes it wrong.
    pub const Reason = enum { unknown_route, arg_count, arg_charset, ref_too_long, reload_in_build };

    pub fn ref(self: *const Refusal) []const u8 {
        return self.bytes[0..self.len];
    }
};

pub const Router = struct {
    routes: []const RouteDef,
    stack: std.ArrayList(Entry),
    observer: RouteObserver = .{},
    /// The last navigation refused, kept until the next refusal — never
    /// cleared, because a refusal is a bug and the audit fails the test
    /// that trips one; in production the record is what a debugger
    /// finds. Only the navigating verbs write it: `vet` answers without
    /// recording, which is what the untrusted entry points use.
    refused: ?Refusal = null,
    /// True while `rebuild` runs — the route builder, and everything a
    /// rebuild runs after it (the re-presented sheet's builder, the nav
    /// resync). A `reload` from inside that window would tear down the
    /// half-built content and run the builder again over its own
    /// output, duplicating the screen — the one hazard the consumer
    /// survey found every controller guarding by hand — so `reload`
    /// refuses it instead (recorded, `.reload_in_build`), and the
    /// polite verb (`App.refresh`) declines it quietly: a load a
    /// builder issues can be answered synchronously, and the state that
    /// answer wrote is exactly what the running builder reads next.
    building: bool = false,

    /// One screen on the stack. It owns the reference it was entered
    /// with, arguments and all — which is the point: two `note` screens
    /// pushed for different notes are different entries, and popping
    /// back to the first still knows which note it was. Without this the
    /// depth is remembered and the identity is not.
    const Entry = struct {
        idx: usize,
        ref: []u8,
        /// Where this screen was scrolled to when it last lost the tree,
        /// so popping back to it returns the screen and not just its
        /// identity. Without it a list the user was halfway down comes
        /// back at the top, which reads as a different screen wearing
        /// the same name.
        ///
        /// Regions are keyed by their **DFS ordinal**, never by NodeId:
        /// ids are generational and the freelist reuses them, so nothing
        /// captured before a rebuild names anything after it. Matching by
        /// position is therefore best-effort by construction — a screen
        /// that rebuilds with a different shape restores what lines up,
        /// and layout clamps whatever no longer fits. Focus is
        /// deliberately not saved with it: `focus.Focus` is (node, span),
        /// and an ordinal match would drop a screen reader's cursor onto
        /// whatever happens to be nth now.
        root_scroll: i32 = 0,
        regions: [max_saved_regions]i32 = @splat(0),
        region_count: u8 = 0,
    };

    /// Validates the whole table once, at boot, rather than leaving a
    /// malformed name to surface as a mystery at first navigation. The
    /// duplicate is the quiet one: `find` would silently resolve every
    /// reference to the first of them.
    pub fn init(routes: []const RouteDef) !Router {
        for (routes, 0..) |r, i| {
            if (r.name.len == 0) return error.EmptyRouteName;
            if (!validIdent(r.name)) return error.RouteNameCharset;
            // The field has no default, so *forgetting* a title is a
            // compile error; this catches the one thing comptime cannot
            // see, an empty one written on purpose. Same footing as the
            // empty name above, and as `UnlabeledInteractive`. A
            // `.of_locale` title is probed with the empty tag — the
            // never-chosen locale every table boots under — and each
            // *chosen* tag is vetted the same way when it is chosen
            // (`App.setLocale`).
            if (r.title.text("").len == 0) return error.EmptyRouteTitle;
            for (routes[0..i]) |prev| {
                if (std.mem.eql(u8, prev.name, r.name)) return error.DuplicateRouteName;
            }
        }
        return .{ .routes = routes, .stack = .empty };
    }

    pub fn deinit(self: *Router, gpa: std.mem.Allocator) void {
        for (self.stack.items) |e| gpa.free(e.ref);
        self.stack.deinit(gpa);
    }

    /// Installs the mirror hook. A shell calls this once, after `App.init`
    /// returns — the App is moved by value out of it, so anything holding
    /// `&app` must wait (docs/internals/architecture.md).
    pub fn installObserver(
        self: *Router,
        ctx: ?*anyopaque,
        call: *const fn (ctx: ?*anyopaque, route: []const u8, change: Change) void,
    ) void {
        self.observer = .{ .ctx = ctx, .call = call };
    }

    /// The name of the screen on top — `"note"` for `note~42`. What nav
    /// chrome compares itself against, so a section stays current
    /// whichever of its screens is showing.
    pub fn current(self: *const Router) ?[]const u8 {
        if (self.top()) |e| return self.routes[e.idx].name;
        return null;
    }

    /// The whole reference the current screen was entered with, arguments
    /// included. What the address bar shows on the web.
    pub fn currentRef(self: *const Router) ?[]const u8 {
        if (self.top()) |e| return e.ref;
        return null;
    }

    /// What the current screen is called (`RouteDef.title`, said under
    /// `locale_tag` — pass `App.locale()`) — what nav chrome shows for a
    /// screen that is none of the destinations (`nav.effectiveRoster`).
    /// Borrowed from the route table's constant data (`Title`'s rule),
    /// so it outlives every tree built from it.
    pub fn currentTitle(self: *const Router, locale_tag: []const u8) ?[]const u8 {
        if (self.top()) |e| return self.routes[e.idx].title.text(locale_tag);
        return null;
    }

    /// The route `name` denotes, or null if the table has no such route
    /// — how the nav turns a declared destination into a title without
    /// storing one (`nav.setNav`). Borrowed from the route table, like
    /// `currentTitle` and for the same reason.
    pub fn lookup(self: *const Router, name: []const u8) ?RouteDef {
        const i = self.find(name) orelse return null;
        return self.routes[i];
    }

    /// Formats a reference — `name`, then `args` joined by
    /// `arg_separator` — into `buf`, and refuses everything `resolve`
    /// would refuse: an unknown name, the wrong arity, an argument
    /// outside the charset (`~` included, so an argument can never
    /// smuggle a second separator in), a result past `max_ref_bytes`.
    /// Refused before a byte is written, so a failed call leaves `buf`
    /// meaningless rather than half a reference.
    ///
    /// This is the writing mirror of `resolve`: one parses, one prints,
    /// and nothing else touches the separator. A consumer formatting a
    /// reference by hand holds a `~` literal it cannot check and a
    /// buffer size it guessed; here the table checks the reference at
    /// the site that builds it, and `[max_ref_bytes]u8` is always
    /// enough — a reference this accepts is one `resolve` will.
    pub fn writeRef(self: *const Router, buf: []u8, name: []const u8, args: []const []const u8) ![]u8 {
        const idx = self.find(name) orelse return error.UnknownRoute;
        if (args.len != self.routes[idx].args) return error.RouteArgCount;
        var len: usize = name.len;
        for (args) |a| {
            if (!validIdent(a)) return error.RouteArgCharset;
            len += 1 + a.len;
        }
        if (len > max_ref_bytes or len > buf.len) return error.RouteRefTooLong;
        @memcpy(buf[0..name.len], name);
        var at = name.len;
        for (args) |a| {
            buf[at] = arg_separator;
            at += 1;
            @memcpy(buf[at..][0..a.len], a);
            at += a.len;
        }
        return buf[0..len];
    }

    /// The `i`th positional argument of the current screen, or null past
    /// the end. Borrowed from the entry, so it lives exactly as long as
    /// the screen does — a builder may keep it for the tree, which copies.
    pub fn arg(self: *const Router, i: usize) ?[]const u8 {
        const e = self.top() orelse return null;
        var it = std.mem.splitScalar(u8, e.ref, arg_separator);
        _ = it.next(); // the name
        var n: usize = 0;
        while (it.next()) |a| : (n += 1) {
            if (n == i) return a;
        }
        return null;
    }

    pub fn depth(self: *const Router) usize {
        return self.stack.items.len;
    }

    fn top(self: *const Router) ?Entry {
        if (self.stack.items.len == 0) return null;
        return self.stack.items[self.stack.items.len - 1];
    }

    fn topMut(self: *Router) ?*Entry {
        if (self.stack.items.len == 0) return null;
        return &self.stack.items[self.stack.items.len - 1];
    }

    pub fn push(self: *Router, app: *App, ref: []const u8) !void {
        const idx = switch (self.resolve(ref)) {
            .idx => |i| i,
            .refused => |why| return self.refuse(ref, why),
        };
        // Where the outgoing screen was scrolled to, saved into the entry
        // that survives underneath. This is the only motion that has to:
        // pop, replace and switchTo all drop the entry they would be
        // capturing from.
        if (self.topMut()) |e| captureScroll(app, e);
        // Room first, then the copy: the only fallible step left cannot
        // then strand an owned reference outside the stack.
        try self.stack.ensureUnusedCapacity(app.gpa, 1);
        self.stack.appendAssumeCapacity(try own(app.gpa, idx, ref));
        try self.rebuild(app, .push, .fresh, .dropped, .fresh);
    }

    /// Pops back one screen. No-op at the root of the stack.
    pub fn pop(self: *Router, app: *App) !void {
        if (self.stack.items.len <= 1) return;
        self.dropTop(app.gpa);
        try self.rebuild(app, .pop, .restored, .dropped, .fresh);
    }

    pub fn replace(self: *Router, app: *App, ref: []const u8) !void {
        const idx = switch (self.resolve(ref)) {
            .idx => |i| i,
            .refused => |why| return self.refuse(ref, why),
        };
        try self.stack.ensureUnusedCapacity(app.gpa, 1);
        const entry = try own(app.gpa, idx, ref);
        if (self.stack.items.len != 0) self.dropTop(app.gpa);
        self.stack.appendAssumeCapacity(entry);
        try self.rebuild(app, .replace, .fresh, .dropped, .fresh);
    }

    /// Enters `ref` with the stack reset to just it: arriving somewhere
    /// with nothing behind you — which is what a visitor following a
    /// shared link has (`navigate` in render/dom/live.zig), and not what
    /// a visitor crossing the nav has: that pushes, so the section they
    /// were in stays behind them (nav.zig).
    pub fn switchTo(self: *Router, app: *App, ref: []const u8) !void {
        const idx = switch (self.resolve(ref)) {
            .idx => |i| i,
            .refused => |why| return self.refuse(ref, why),
        };
        try self.stack.ensureTotalCapacity(app.gpa, 1);
        const entry = try own(app.gpa, idx, ref);
        for (self.stack.items) |e| app.gpa.free(e.ref);
        self.stack.clearRetainingCapacity();
        self.stack.appendAssumeCapacity(entry);
        try self.rebuild(app, .switch_to, .fresh, .dropped, .fresh);
    }

    /// Rebuilds the current screen from its own reference — the way to
    /// react to changed state. `replace(app, current())` would drop the
    /// arguments, since `current` is the name alone.
    ///
    /// Scroll survives it. A reload is the same screen answering to
    /// changed state, so landing back at the top of a list the user was
    /// halfway down is the papercut `pop` has, arriving through a
    /// different door — and a screen that redraws a row cannot be asked
    /// to also put the viewport back.
    ///
    /// An open sheet survives it too, by the same argument: its builder
    /// (`App.openSheet`) runs again over the rebuilt screen, so a sheet
    /// is never the reason state cannot be answered.
    ///
    /// Focus survives it by *name*: the control the keyboard was on is
    /// re-found in the rebuilt tree by its label (`restoreFocus`), or
    /// focus starts over when no control answers to it anymore. What a
    /// reload cannot save is an editable mid-edit — caret, composition,
    /// and the unwritten value go with the node — which is what
    /// `App.reloadSafe` lets an unprompted rebuild check first.
    pub fn reload(self: *Router, app: *App) !void {
        if (self.stack.items.len == 0) return;
        // Re-entrant: some callback inside the running builder asked
        // for the screen the builder is mid-way through producing. A
        // refusal, not an error, by `refused`'s own argument — the
        // caller is a callback with nothing to do about it, and the
        // audit fails the first test that trips one. The record carries
        // the reference of the screen being built: the culprit's name.
        if (self.building) return self.refuse(self.top().?.ref, .reload_in_build);
        captureScroll(app, self.topMut().?);
        try self.rebuild(app, .replace, .restored, .carried, .carried);
    }

    fn own(gpa: std.mem.Allocator, idx: usize, reference: []const u8) !Entry {
        return .{ .idx = idx, .ref = try gpa.dupe(u8, reference) };
    }

    fn dropTop(self: *Router, gpa: std.mem.Allocator) void {
        if (self.stack.pop()) |e| gpa.free(e.ref);
    }

    /// Whether `ref` would be honored, and if not, why not — the
    /// reading gate without the navigation. The door for bytes from
    /// outside the program (an address bar, a deep link, a notification
    /// payload): vetting first keeps a stranger's typo out of `refused`,
    /// which records programmer errors and is read as one by the audit.
    pub fn vet(self: *const Router, ref: []const u8) ?Refusal.Reason {
        return switch (self.resolve(ref)) {
            .idx => null,
            .refused => |why| why,
        };
    }

    const Resolved = union(enum) { idx: usize, refused: Refusal.Reason };

    /// A reference to a route index, validating everything about it
    /// before anything is committed: a refused one leaves the stack
    /// exactly as it was.
    fn resolve(self: *const Router, reference: []const u8) Resolved {
        if (reference.len > max_ref_bytes) return .{ .refused = .ref_too_long };
        var it = std.mem.splitScalar(u8, reference, arg_separator);
        const name = it.next() orelse return .{ .refused = .unknown_route };
        const idx = self.find(name) orelse return .{ .refused = .unknown_route };
        var n: usize = 0;
        while (it.next()) |a| : (n += 1) {
            // Empty fails here too: a trailing `~` is a missing argument,
            // not an empty one — an identifier has no empty form.
            if (!validIdent(a)) return .{ .refused = .arg_charset };
        }
        if (n != self.routes[idx].args) return .{ .refused = .arg_count };
        return .{ .idx = idx };
    }

    fn refuse(self: *Router, reference: []const u8, why: Refusal.Reason) void {
        var r = Refusal{ .reason = why, .len = @intCast(@min(reference.len, max_ref_bytes)), .bytes = undefined };
        @memcpy(r.bytes[0..r.len], reference[0..r.len]);
        self.refused = r;
    }

    fn find(self: *const Router, name: []const u8) ?usize {
        for (self.routes, 0..) |r, i| {
            if (std.mem.eql(u8, r.name, name)) return i;
        }
        return null;
    }

    /// Whether the screen being built is arriving for the first time or
    /// coming back to a viewport it already had (see `Entry`). Kept
    /// separate from `Change`, which is the shells' vocabulary and must
    /// not grow a variant for a distinction only the router makes —
    /// which is also how `reload` keeps announcing itself as `.replace`.
    const Scroll = enum { fresh, restored };

    /// Whether an open sheet's builder (`App.openSheet`) rides this
    /// rebuild or dies with the screen. Kept separate from `Change` for
    /// `Scroll`'s reason — and only a reload carries: every real
    /// navigation is a new screen, and a sheet belongs to the state of
    /// the one that opened it.
    const SheetFate = enum { dropped, carried };

    /// Whether the keyboard's place rides this rebuild. Only a reload
    /// carries — a real navigation is a different screen, with no
    /// element the old focus could mean — and it carries by *name*,
    /// never by position (`restoreFocus`).
    const FocusFate = enum { fresh, carried };

    fn rebuild(self: *Router, app: *App, change: Change, scroll: Scroll, sheet: SheetFate, focus_fate: FocusFate) !void {
        // Saved and restored, not set and cleared: a builder may
        // legitimately *navigate* (a guard screen redirecting), and the
        // nested rebuild must hand the window back to the outer one
        // still open when it returns.
        const outer = self.building;
        self.building = true;
        defer self.building = outer;
        const entry = self.stack.items[self.stack.items.len - 1];
        const def = self.routes[entry.idx];
        // Copied out before the teardown: the node goes with the
        // content, and the label it is re-found by goes with the arena.
        const carried_focus: ?CarriedFocus = if (focus_fate == .carried) captureFocus(app) else null;
        try clearContent(app);
        // The arena reclaim point (tree.zig's module doc): the removed
        // screen's strings — with every editing splice copy, IME
        // update, and resynced chrome label since the last rebuild — go
        // with the old arena; the chrome that survives has its strings
        // re-copied, keeping the node ids focus and the picker hold. A
        // failed reclaim only postpones — the tree is untouched and the
        // next rebuild tries again — which beats failing a navigation
        // over memory that was only waiting to be freed.
        app.tree.reclaim() catch {};
        // Focus starts over even when the scroll position does not: the
        // node it named is gone, and putting a screen reader's cursor
        // back by ordinal would land it on whatever took that place.
        // A reload alone re-finds it by name once the tree stands
        // again (`restoreFocus`, at the end of this rebuild).
        app.focused = null;
        // The sheet's *node* went with the content either way; whether
        // its builder gets to build again is `sheet`'s call, below.
        app.sheet_return_focus = null;
        if (sheet == .dropped) overlays.dropSheetBuilder(app);
        app.picker_owner = null; // the picker went with the content
        app.more_sheet = null; // and the folded tail with the row it came from
        app.root_scroll = 0;
        // The latched node ids would dangle into the rebuilt tree.
        app.scroll_hot = .none;
        app.ack = null;
        // A pushed screen always has a way back, and the framework
        // installs it — consumers never wire their own. It leads the
        // content, sharing the screen title's line. At depth 1 (a
        // section root) there is nothing to go back to and no control.
        if (self.stack.items.len > 1) {
            try app.tree.append(app.tree.rootId(), .{ .back = .{ .label = app.chrome.back } });
        }
        // The page's top, drawn before the builder rather than left to
        // it. The screen is already named — a route with no title is a
        // refusal at the table — so making a builder write the same
        // words again as an `h1` would be a second copy of a fact the
        // app already answered, and the second copy is the one that
        // goes stale. A screen whose real title is per-reference
        // (`note~42` is "Note" to the chrome and the note's own name to
        // the reader) restates it with `App.setTitle`, which finds this
        // node rather than adding a second; `setTitle("")` takes it
        // away.
        try app.tree.setTitle(def.title.text(app.locale()));
        try def.build(app.ctx, app);
        // After the builder and before the invalidate, so the restored
        // offsets are what the rebuilt screen's *first* layout sees and
        // no frame ever shows the top of a list the user left halfway
        // down. Layout clamps whatever no longer fits.
        if (scroll == .restored) restoreScroll(app, entry);
        // After the screen, so the carried sheet stands on the rebuilt
        // content it is about — and its builder reads post-reload state.
        if (sheet == .carried) try overlays.representSheet(app);
        // The collapsed nav names the section it stands on, so the
        // chrome follows the stack (nav.zig). The row does not — it
        // reads the current route at draw time — so this is a no-op
        // there, and a no-op with no nav at all.
        nav_mod.syncNavChrome(app) catch {};
        // Last of the tree work, so the search runs over everything
        // that will actually stand: the rebuilt screen, the
        // re-presented sheet, the synced chrome.
        if (carried_focus) |c| restoreFocus(app, c);
        app.invalidate();
        // Last, so an observer that reads the app sees the finished tree.
        if (self.observer.call) |call| call(self.observer.ctx, entry.ref, change);
    }

    /// The label cap for a carried focus. A control named past it is
    /// simply not re-found — better than re-found wrong — and the cap
    /// exists because the label's own memory is the tree arena, which
    /// the rebuild reclaims mid-flight.
    const max_carried_label = 128;

    /// The keyboard's place, in the only terms that outlive a rebuild:
    /// the node id (chrome keeps its ids across `tree.reclaim`) and a
    /// copy of the accessible name (the audit forbids two interactive
    /// elements in one layer from sharing one —
    /// `duplicate_interactive_label` — so within a layer the same name
    /// is the same control).
    const CarriedFocus = struct {
        node: NodeId,
        label_len: u8 = 0,
        label: [max_carried_label]u8 = undefined,
    };

    /// Copies the focused stop out before the rebuild takes its node. A
    /// link span's stop is not carried at all: its paragraph has no
    /// accessible name of its own, and the span index is exactly the
    /// ordinal a restore must never trust.
    fn captureFocus(app: *const App) ?CarriedFocus {
        const stop = app.focused orelse return null;
        if (stop.span != null) return null;
        const el = app.tree.getConst(stop.node) orelse return null;
        var carried: CarriedFocus = .{ .node = stop.node };
        const label = el.label();
        if (label.len > 0 and label.len <= max_carried_label) {
            @memcpy(carried.label[0..label.len], label);
            carried.label_len = @intCast(label.len);
        }
        return carried;
    }

    /// The mirror of `captureFocus`, over the rebuilt tree: by identity
    /// when the node still stands (chrome survives rebuilds), else by
    /// name — first stop in the active layer wearing the carried label.
    /// No match leaves focus where the rebuild put it: a re-presented
    /// sheet's first stop, or nowhere, which is the old contract.
    fn restoreFocus(app: *App, carried: CarriedFocus) void {
        var by_name: ?NodeId = null;
        var it = focus_mod.stops(&app.tree, app.focusScope());
        while (it.next()) |stop| {
            if (stop.span != null) continue;
            const el = app.tree.getConst(stop.node).?;
            if (el.isFolded()) continue;
            if (stop.node.eql(carried.node)) {
                app.focused = .of(stop.node);
                return;
            }
            if (by_name == null and carried.label_len > 0 and
                std.mem.eql(u8, el.label(), carried.label[0..carried.label_len]))
            {
                by_name = stop.node;
            }
        }
        if (by_name) |id| app.focused = .of(id);
    }

    /// Saves the current screen's scroll positions into `entry`, in the
    /// DFS order `restoreScroll` reads them back in. Called by the two
    /// motions that take the tree away from a screen whose entry
    /// outlives it — a push (the entry underneath survives) and a reload
    /// (the same entry rebuilds in place).
    fn captureScroll(app: *const App, entry: *Entry) void {
        entry.root_scroll = app.root_scroll;
        entry.region_count = 0;
        var it = app.tree.dfs();
        while (it.next()) |id| {
            const el = app.tree.getConst(id).?;
            if (el.role() != .scroll_region) continue;
            if (entry.region_count == max_saved_regions) break;
            entry.regions[entry.region_count] = el.scroll_region.offset;
            entry.region_count += 1;
        }
    }

    /// The mirror of `captureScroll`, over the freshly built tree. A
    /// screen that came back with fewer regions than it left with simply
    /// runs out of nodes, and one that came back with more leaves its
    /// extras at the top — neither is an error, because the entry
    /// remembers a viewport, not a tree.
    fn restoreScroll(app: *App, entry: Entry) void {
        app.root_scroll = entry.root_scroll;
        var n: usize = 0;
        var it = app.tree.dfs();
        while (it.next()) |id| {
            if (n == entry.region_count) return;
            const el = app.tree.get(id).?;
            if (el.role() != .scroll_region) continue;
            el.scroll_region.offset = entry.regions[n];
            n += 1;
        }
    }

    /// Removes every root child except app chrome: nav (see App.setNav)
    /// and the notice chrome (banner, pane, or minimized indicator —
    /// status outlives the screen it was raised on). An open sheet's
    /// node belongs to the old tree and goes with it; whether its
    /// builder presents again is `rebuild`'s `SheetFate`.
    fn clearContent(app: *App) !void {
        const root = app.tree.rootId();
        var doomed: std.ArrayList(NodeId) = .empty;
        defer doomed.deinit(app.gpa);
        var it = app.tree.children(root);
        while (it.next()) |child| {
            switch (app.tree.getConst(child).?.role()) {
                .nav, .notice, .notices_pane, .icon_button => {},
                else => try doomed.append(app.gpa, child),
            }
        }
        for (doomed.items) |id| try app.tree.remove(id);
    }
};
