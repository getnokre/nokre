//! The application object: owns the tree, focus, router, and viewport,
//! and turns platform events into semantic state changes. Platform
//! shells and the testing harness drive this identically — that is what
//! makes nokre e2e tests faithful.
//!
//! App itself stays thin: interaction lives in input.zig, text editing
//! in editing.zig, the sheet and picker in overlays.zig, and notices in
//! notices.zig — sibling modules operating on this one struct. The
//! consumer-facing methods below alias into them, so the API is all in
//! one place.

const std = @import("std");
const builtin = @import("builtin");
const bidi = @import("bidi.zig");
const color = @import("color.zig");
const cursor_mod = @import("cursor.zig");
const editing = @import("editing.zig");
const element_mod = @import("element.zig");
const event_mod = @import("event.zig");
const focus = @import("focus.zig");
const geometry = @import("geometry.zig");
const input = @import("input.zig");
const scrolling = @import("scrolling.zig");
const layout = @import("layout.zig");
const nav_mod = @import("nav.zig");
const notices_mod = @import("notices.zig");
const overflow = @import("overflow.zig");
const overlays = @import("overlays.zig");
const router_mod = @import("router.zig");
const text = @import("text.zig");
const tree_mod = @import("tree.zig");
const workers = @import("../workers/workers.zig");
const services_mod = @import("../services/services.zig");
const clipboard = @import("../services/clipboard/clipboard.zig");
const locale_svc = @import("../services/locale/locale.zig");

const Size = geometry.Size;
const Tree = tree_mod.Tree;
const NodeId = tree_mod.NodeId;
const Event = event_mod.Event;

pub const App = struct {
    gpa: std.mem.Allocator,
    tree: Tree,
    router: router_mod.Router,
    /// This app's worker service — slot table, delivery queue, wake —
    /// heap-pinned so the pointers embedded in handles and tickets
    /// survive the by-value moves a stack App makes. Owned: created in
    /// `init`, torn down first in `deinit` (threads join before
    /// anything else goes away).
    runtime: *workers.Runtime,
    /// This app's services, injected at construction (`Options.services`):
    /// platform transports in release, mocks under `zig test`. The
    /// stateful halves are heap-allocated by `init` — the config the
    /// consumer passed stays small and by-value.
    services: services_mod.Services,
    measurer: text.Measurer,
    /// What the surface this app is drawn on does with a row too wide
    /// for it (`layout.Medium`) — the driver's fact, installed by the
    /// driver, exactly like `measurer` above and for the same reason:
    /// the thing that will actually draw the page is the thing to ask.
    ///
    /// Not an `Options` field, and that is the point. There is one
    /// place per edition that knows the answer — `live.zig` at boot,
    /// `dom.document` at the top of a file it is about to write — and a
    /// consumer that could also state it would be a second place for it
    /// to be wrong, in the direction where being wrong is silent: a
    /// header that swaps itself for a chip nobody asked for.
    medium: layout.Medium = .clips,
    /// Bidi resolution workspace for the renderer and editing (~100 KB,
    /// so heap-pinned like the runtime rather than riding the by-value
    /// moves a stack App makes). Per-app: two apps on two threads must
    /// not share working memory.
    bidi_scratch: *bidi.Scratch,
    viewport: Size,
    /// The chrome's frame of reference: under `.rtl`, layout and the
    /// renderer mirror every leading/trailing choice (block alignment,
    /// nav order, field chrome, chevrons — see `setDirection`). Text
    /// alignment is not this: paragraphs align by their own content
    /// (UAX #9 first-strong), whatever the chrome does.
    direction: bidi.Direction = .ltr,
    /// Height of the device band at the viewport's bottom the OS draws
    /// over (the iPhone home indicator). Geometry, not styling: layout
    /// anchors all chrome and content above it; the renderer extends
    /// pane fills through it so bottom chrome reaches the physical
    /// edge. Zero on platforms without one.
    safe_bottom: i32 = 0,
    /// Where focus sits: a node, plus which of its link spans holds
    /// it (see focus.zig). Typed as a pair so no path can move focus
    /// and leave a stale span index behind.
    focused: ?focus.Focus = null,
    /// Whether the focus indicator is drawn — the `:focus-visible`
    /// split every platform ships. Keyboard input sets it and pointer
    /// or touch focus clears it (input.zig): a ring after a tap points
    /// at what the finger just pressed, which is noise, while keyboard
    /// focus with no ring is invisible (WCAG 2.4.7). Focus itself — the
    /// stop, activation, the a11y snapshot — never depends on this;
    /// only the renderer's drawn indicator reads it. Starts true so
    /// programmatic focus (tests, assistive-tech actions) shows itself.
    focus_visible: bool = true,
    /// The app's own state, handed back to every screen builder
    /// (`RouteDef.build`). One for the whole table, not one per route —
    /// which is what lets `Routes(State)` type it at the table and leaves
    /// this the single place a consumer's type is asserted rather than
    /// the fifty-nine builders it used to be asserted at.
    ///
    /// It stays erased because the alternative is an `App` generic over
    /// consumer state, and `*App` is in the signature of every element
    /// call, every service, the renderer, the shells and the harness — a
    /// framework-wide type parameter to name a field that, past the typed
    /// door, no consumer reads.
    ctx: ?*anyopaque = null,
    scheme: color.Scheme = .auto,
    system_appearance: color.Appearance = .light,
    /// Scroll offset of the window content itself: content taller than
    /// the viewport scrolls with no wrapper element and no tab stop.
    root_scroll: i32 = 0,
    /// Live touch-drag lock, set at scroll `.begin` and cleared at
    /// `.end`: the targets under the initial touch own every `.move`.
    scroll_gesture: ?scrolling.ScrollGesture = null,
    /// The press in flight, waiting on its release (see input.zig's
    /// `Press`). Null between presses, and cleared without activating
    /// when a scroll claims the same finger.
    press: ?input.Press = null,
    /// The edge pan in progress, and whether it is past the point where
    /// releasing goes back — null between gestures, and null for the
    /// whole of one that was never eligible (see input.zig's
    /// `handleEdgePan`). Nothing on screen tracks the finger: the only
    /// visible state is `armed`, latched like `ack`, and the only reason
    /// it is drawn at all is that a threshold nobody can see or feel
    /// (haptics off, and there are many such devices) is a gesture that
    /// commits blind.
    back_gesture: ?input.BackGesture = null,
    /// The scroll surface the last scrolling input actually moved: its
    /// indicator draws emphasized, every other one rests quiet.
    /// Interaction state, not time — "hide after the scroll stops"
    /// needs a wall-clock timer, which the pixel-deterministic core
    /// cannot have — so emphasis latches until the next non-scroll
    /// input releases it (see `dispatch`). Gesture `.end` deliberately
    /// does not: the bar stays readable at rest after a drag.
    scroll_hot: ScrollHot = .none,
    /// The one element showing an acknowledgement: the `copyable` whose
    /// activation just wrote to the clipboard, drawn with a check in the
    /// copy glyph's slot. A copy leaves the screen identical, so without
    /// a mark activation looks inert — and the mark is nokre's to draw,
    /// not the screen's, because the screen cannot draw it either: "clear
    /// it after a moment" needs a wall-clock timer the pixel-deterministic
    /// core cannot have. So this latches like `scroll_hot` and an input
    /// releases it instead of time (see `dispatch`).
    ///
    /// `?NodeId` is the exclusivity rule stated as a type: acknowledging
    /// takes the mark from whoever held it, and no two elements are ever
    /// marked at once. Only an element whose activation completes
    /// intrinsically and changes nothing else on screen may hold it —
    /// today `copyable` alone; everything else either mutates visible
    /// state or hands off to the app, and has its own reaction to show.
    /// `copyText` called from an action does not arm it: there is no
    /// element to mark, and that screen's feedback stays its own business.
    ack: ?NodeId = null,
    /// Written by layout; consumers read, never write.
    root_content_height: i32 = 0,
    /// Set whenever visible state changed; shells clear it after painting.
    needs_frame: bool = true,
    layout_dirty: bool = true,
    /// Where focus returns when the open sheet is dismissed.
    sheet_return_focus: ?focus.Focus = null,
    /// The open sheet as data: who builds it, and who to tell when it
    /// closes (`overlays.openSheet`). Kept until the sheet closes;
    /// `reload` runs it again, so the sheet outlives the rebuild.
    sheet_builder: ?overlays.SheetBuilder = null,
    /// The open sheet, when it is a row's folded tail rather than a
    /// consumer's (overflow.zig). Pressing one of the buttons it lists
    /// closes it, so activation has to know which sheet it is standing
    /// in — the same thing `picker_owner` is for. The row rides along
    /// because the sheet is only true while that row's fold is: layout
    /// can move the fold under it at any width change.
    more_sheet: ?MoreSheet = null,
    /// The select or collapsed nav whose picker is open; focus and the
    /// committed choice return to it.
    picker_owner: ?NodeId = null,
    /// The nav's destinations, in the order `setNav` was given them and
    /// already resolved against the route table. The tree holds whichever
    /// *shape* fits the viewport — the row of items, or the one chip
    /// standing in for all of them — so the roster itself has to live
    /// somewhere that survives reshaping (`nav.syncNavChrome`). Empty
    /// when there is no nav; borrows every string it holds, and so frees
    /// none of them (`nav.RosterItem`).
    nav_items: std.ArrayList(nav_mod.RosterItem) = .empty,
    /// Every pending notice: important ones in front, arrival order
    /// within each group; the front one is the banner (see `notify`).
    /// A bounded ring — all `notices_mod.max_pending` slots reserved at
    /// `init`, which is what makes `notify` infallible; past the bound
    /// it evicts drop-oldest.
    notices: std.ArrayList(notices_mod.OwnedNotice) = .empty,
    /// How the pending notices surface; `.none` iff there are none.
    notice_state: NoticeState = .none,
    /// The framework's own words, in this app's language (`setChrome`).
    /// English until an app says otherwise. Borrowed, never owned — a
    /// catalog's `tr` hands back constant data, `RouteDef.title`'s rule.
    chrome: Chrome = .{},
    /// The app's *chosen* locale, as a BCP 47 tag — read it with
    /// `locale()`, choose it with `setLocale` (or at boot,
    /// `Options.locale`). Empty until chosen, which every `.of_locale`
    /// title must answer as the template (`router.Title`). A copy, not
    /// a borrow — the tag often arrives from the locale *service*'s
    /// mutable buffer, and language state must not change under the
    /// app because the device's did.
    locale_buf: [locale_svc.max_tag_bytes]u8 = undefined,
    locale_len: u8 = 0,

    /// Every string nokre itself puts on a screen. Declared with the
    /// elements it names (element.zig), because each chrome element
    /// copies its own out at construction: `Element.label()` is pure and
    /// has no App to ask which language this app is in.
    pub const Chrome = element_mod.Chrome;

    pub const NoticeState = enum { none, banner, pane, minimized };

    /// See `scroll_hot`. `.window` is the implicit root scroll; `.node`
    /// is a scroll region or segmented track.
    pub const ScrollHot = union(enum) { none, window, node: NodeId };

    /// See `more_sheet`: the folded tail on screen, and the row it is
    /// the tail of.
    pub const MoreSheet = struct { row: NodeId, sheet: NodeId };

    /// A sheet declared as data — what `openSheet` takes (overlays.zig).
    pub const SheetBuilder = overlays.SheetBuilder;

    /// In a test build `services` loses its default (see below): every
    /// test constructs its app with its mocks — `.services = .mocks()`
    /// when it doesn't care — and omission is a compile error, so no
    /// test depends on state it didn't declare. Release keeps the
    /// default: shells and examples stay one-line. nokre's own tests
    /// say the uninteresting half once, in test_app.zig.
    pub const Options = if (builtin.is_test) WithoutDefault(OptionsRelease, "services") else OptionsRelease;

    const OptionsRelease = struct {
        viewport: Size,
        direction: bidi.Direction = .ltr,
        safe_bottom: i32 = 0,
        measurer: text.Measurer = text.Measurer.fixed,
        routes: []const router_mod.RouteDef = &.{},
        /// The chosen locale's tag at boot, for an app that knows it
        /// before `init` (a restored preference). "" is "not chosen
        /// yet" — the common boot, refined by `setLocale` once the
        /// device has said or the session has restored.
        locale: []const u8 = "",
        /// The framework's own words at boot, beside the locale and the
        /// direction that restore with them (`App.Chrome`,
        /// `setChrome`). Without it a boot that already knows its
        /// language — a restored Arabic preference — stands its whole
        /// nav bar up in English and needs a second call to say what
        /// `.locale` and `.direction` said here: the correct path was
        /// longer than the wrong one, which is the shape of every
        /// half-translated chrome bug. Defaults to English, as the
        /// field it fills does.
        chrome: element_mod.Chrome = .{},
        ctx: ?*anyopaque = null,
        scheme: color.Scheme = .auto,
        /// The platform set. (Keep Options decl-free: the test-build
        /// variant is reified with @Struct, which carries no decls.)
        services: services_mod.Services = .{},
    };

    /// Same struct, minus the named field's default — the mechanism
    /// that turns "forgot to inject services" into a compile error at
    /// the init site instead of shared state at runtime. (A
    /// @compileError default doesn't work: Zig resolves field defaults
    /// eagerly even when every site supplies the field.)
    fn WithoutDefault(comptime T: type, comptime field_name: []const u8) type {
        const src = @typeInfo(T).@"struct".fields;
        var names: [src.len][]const u8 = undefined;
        var types: [src.len]type = undefined;
        var attrs: [src.len]std.builtin.Type.StructField.Attributes = undefined;
        for (src, &names, &types, &attrs) |f, *name, *Ty, *attr| {
            name.* = f.name;
            Ty.* = f.type;
            attr.* = .{
                .default_value_ptr = if (std.mem.eql(u8, f.name, field_name)) null else f.default_value_ptr,
                .@"align" = f.alignment,
            };
        }
        return @Struct(.auto, null, &names, &types, &attrs);
    }

    // ---- feature APIs, implemented in the sibling modules ----

    /// The builder cursor at the tree root — where a screen builder
    /// starts (core/cursor.zig).
    pub const root = cursor_mod.root;
    /// The builder cursor at a node the framework handed back — in
    /// consumer code, `presentSheet`'s.
    pub const at = cursor_mod.at;
    pub const setNav = nav_mod.setNav;
    pub const clearNav = nav_mod.clearNav;
    pub const openSheet = overlays.openSheet;
    /// `openSheet` with the sheet's name typed and the context bound —
    /// the door for a controller whose sheets are named (overlays.zig).
    pub const openSheetAs = overlays.openSheetAs;
    /// Which declared sheet is up (`SheetBuilder.tag`), or null — the
    /// framework's answer to the question every controller used to
    /// mirror in an enum beside it (overlays.zig).
    pub const openSheetTag = overlays.openSheetTag;
    /// Which of *this* controller's sheets is up, typed — null unless
    /// the open sheet is one this context opened (overlays.zig).
    pub const sheetTagAs = overlays.sheetTagAs;
    pub const presentSheet = overlays.presentSheet;
    pub const dismissSheet = overlays.dismissSheet;
    /// Takes the sheet down and rebuilds the screen behind it — the
    /// pair every close handler wrote by hand (overlays.zig).
    pub const closeSheet = overlays.closeSheet;
    /// What the sheet doors answer instead of `anyerror` (overlays.zig).
    pub const OpenSheetError = overlays.OpenSheetError;
    pub const notify = notices_mod.notify;
    pub const dismissNotice = notices_mod.dismissNotice;
    pub const dismissNoticeAt = notices_mod.dismissNoticeAt;
    pub const openNoticesPane = notices_mod.openNoticesPane;
    pub const minimizeNotices = notices_mod.minimizeNotices;
    pub const dismissAllNotices = notices_mod.dismissAllNotices;
    pub const hitTest = input.hitTest;
    /// Press and release at one point — see input.zig's `tap`.
    pub const tap = input.tap;
    /// Activates an element exactly as a tap or Enter would.
    pub const activate = input.activate;

    pub fn init(gpa: std.mem.Allocator, options: Options) !App {
        var tree = try Tree.init(gpa);
        errdefer tree.deinit();
        const scratch = try gpa.create(bidi.Scratch);
        errdefer gpa.destroy(scratch);
        var self: App = .{
            .gpa = gpa,
            .tree = tree,
            .router = try router_mod.Router.init(options.routes),
            .runtime = try workers.Runtime.create(gpa),
            .services = options.services,
            .bidi_scratch = scratch,
            .measurer = options.measurer,
            .viewport = options.viewport,
            .direction = options.direction,
            .chrome = options.chrome,
            .safe_bottom = options.safe_bottom,
            .ctx = options.ctx,
            .scheme = options.scheme,
        };
        errdefer self.runtime.destroy();
        // The notice ring, reserved whole up front: `notify` returns
        // void because this line already paid for every slot it could
        // ever need (notices.zig, `max_pending`).
        try self.notices.ensureTotalCapacity(gpa, notices_mod.max_pending);
        errdefer self.notices.deinit(gpa);
        // Through the one door, so a boot locale is vetted exactly as a
        // chosen one: every title must answer it, or `init` fails here
        // instead of a screen booting half-said. Before the services
        // stand, so a refusal has nothing of theirs to unwind.
        if (options.locale.len != 0) try self.setLocale(options.locale);
        try self.services.init(gpa, self.runtime);
        return self;
    }

    pub fn deinit(self: *App) void {
        // Workers first: threads join and queued deliveries drop before
        // anything they could reference goes away. Services next —
        // their parked state points into the runtime's tickets.
        self.runtime.destroy();
        self.services.deinit();
        self.notices.deinit(self.gpa);
        self.nav_items.deinit(self.gpa);
        self.router.deinit(self.gpa);
        self.tree.deinit();
        self.gpa.destroy(self.bidi_scratch);
    }

    pub fn navigate(self: *App, ref: []const u8) !void {
        try self.router.push(self, ref);
    }

    pub fn navigateBack(self: *App) !void {
        try self.router.pop(self);
    }

    /// Whether a `reload` right now would take something the user
    /// holds. Two things say no: an overlay that owns the screen — a
    /// sheet, a picker, the notices pane (`focusScope`) — and an
    /// editable holding focus, whose caret, composition, and unwritten
    /// value a rebuild drops along with the on-screen keyboard that
    /// follows them. The carried focus (router.zig `restoreFocus`)
    /// softens neither: it returns the *place*, not the edit.
    ///
    /// `reload` itself never asks — a deliberate gesture (retry,
    /// pull-to-refresh, a locale change) must be honored even mid-edit.
    /// This is for the rebuilds nobody asked for: a reply landing
    /// between events checks first, writes its state either way, and
    /// leaves a screen it would disturb alone.
    pub fn reloadSafe(self: *const App) bool {
        if (!self.focusScope().eql(self.tree.rootId())) return false;
        const stop = self.focused orelse return true;
        const el = self.tree.getConst(stop.node) orelse return true;
        return switch (el.role()) {
            .text_input, .text_area => false,
            else => true,
        };
    }

    /// Rebuild the current screen from state — the router verb at the
    /// same hop as `navigate`, so a controller never threads the app
    /// through itself (`app.router.reload(app)`) to say it.
    ///
    /// This is the *deliberate-gesture* verb — retry, pull-to-refresh,
    /// a locale change — and it never asks `reloadSafe`: a gesture must
    /// be honored even mid-edit. A rebuild nobody asked for — a reply
    /// landing between events — says `refresh` instead, which composes
    /// the polite checks once. Called from inside a route builder it is
    /// a recorded refusal, not a rebuild (router.zig, `reload_in_build`):
    /// tearing down the half-built screen to run its builder again
    /// would duplicate it.
    pub fn reload(self: *App) !void {
        try self.router.reload(self);
    }

    /// What `refresh` may filter on.
    pub const Refresh = struct {
        /// Only refresh if this route is on top — the route's *name*,
        /// so `"note"` covers `note~42`, the same comparison nav chrome
        /// makes (`router.current`). "" means any. For a reply that
        /// lands after the user has walked away: the state is written
        /// either way, and a screen the reply no longer owns is left
        /// alone.
        route: []const u8 = "",
    };

    /// "This state changed; update whatever is showing, politely" —
    /// the composed verb for the rebuilds nobody asked for, which every
    /// consumer of the old primitives re-derived by hand (the survey
    /// found 22 copies of the same five lines). Re-runs the open
    /// sheet's builder if one owns the screen — a sheet is a tree node
    /// a reload would take with it, so the state change re-presents it
    /// instead — else reloads unless `reloadSafe` says the user holds
    /// something a rebuild would take (an edit in flight, an open
    /// picker, the notices pane). The deliberate-gesture path stays
    /// `reload()`, which never asks.
    ///
    /// Declining is the point, so nothing here reports: a reply writes
    /// its state, calls this, and the state is on screen now or the
    /// moment the user lets go of what they hold (the next navigation
    /// or gesture rebuilds from that same state).
    pub fn refresh(self: *App, opts: Refresh) void {
        // Inside `rebuild` there is nothing to update politely: the
        // screen is being built from the very state the caller just
        // wrote — a builder-issued load can be answered synchronously
        // (a cached corpus, a transport refusing a double send), and
        // the running builder reads that answer the line after. A quiet
        // decline, where the deliberate verb records a refusal: from a
        // callback this is a normal flow, not a programmer error.
        if (self.router.building) return;
        if (opts.route.len != 0) {
            const current = self.router.current() orelse return;
            if (!std.mem.eql(u8, current, opts.route)) return;
        }
        if (self.sheet_builder != null) {
            // The sheet owns the screen and answers the state itself;
            // the content behind it stays as it was, like every hand
            // policy kept it. What makes that safe rather than a way to
            // lose the state is that every close rebuilds — Esc, the
            // scrim, the × and Cancel are all `overlays.closeSheet`,
            // which is where that invariant is enforced and argued.
            overlays.representSheet(self) catch {};
            return;
        }
        if (!self.reloadSafe()) return;
        self.reload() catch {};
    }

    /// Enter `ref` with the stack reset to just it (router.zig says
    /// when that is the right arrival), aliased for the same reason
    /// as `reload`.
    pub fn switchTo(self: *App, ref: []const u8) !void {
        try self.router.switchTo(self, ref);
    }

    /// Swap the screen on top for `ref` — same depth, so whatever is
    /// behind it stays behind it. The redirect for a screen that is
    /// *not* the first: `switchTo` would take the trail with it, and
    /// `navigate` would leave the screen that redirected sitting under
    /// a Back control that returns to it.
    ///
    /// Aliased for the same reason as `reload`, and by the same
    /// argument the other four motions already carry: `replace` was the
    /// last one reachable only as `app.router.replace(app, ref)` — the
    /// shape this file condemns two screens up, threading the app
    /// through its own member to say something about the app. A verb
    /// with no consumers is exactly the verb a consumer never found.
    pub fn replaceWith(self: *App, ref: []const u8) !void {
        try self.router.replace(self, ref);
    }

    /// The `i`th positional argument of the current screen — `"42"` on
    /// `note~42` (docs/routing.md). Null past the declared arity, so a
    /// builder that reads what its `RouteDef` declares always gets a
    /// value. Borrowed; the tree copies whatever it is given.
    pub fn routeArg(self: *const App, i: usize) ?[]const u8 {
        return self.router.arg(i);
    }

    /// Formats a reference into `buf` — `routeArg`'s writing mirror,
    /// at the same hop for the same reason. The router validates it
    /// against the table before a byte lands (router.zig `writeRef`), so
    /// the site that builds a reference is the site that learns it is
    /// wrong, and no consumer holds the `~` literal or a guessed
    /// buffer size. `[Router.max_ref_bytes]u8` always fits.
    pub fn routeRef(self: *const App, buf: []u8, name: []const u8, args: []const []const u8) ![]u8 {
        return self.router.writeRef(buf, name, args);
    }

    /// The same reference, formatted into the tree's arena instead of a
    /// buffer you declared — `Tree.fmt`'s bargain applied to references,
    /// for the one place references are overwhelmingly built: a `route`
    /// field on an element about to be appended.
    ///
    /// ```zig
    /// try group.tile(.{ .label = row.name, .route = try app.refTo("circle", &.{row.id}) });
    /// ```
    ///
    /// What it removes is not a line but a *declaration*: every such
    /// site had a `[Router.max_ref_bytes]u8` beside it, often inside the
    /// row loop, and two of them across the real consumers had invented
    /// a shorter cap of their own — a buffer whose size is a guess about
    /// a rule the router already owns. The slice lives as long as any
    /// other string a builder hands the tree (`Tree.fmt`: until the next
    /// rebuild frees the arena), which is past the `append` that copies
    /// it.
    ///
    /// `routeRef` stays for the reference that is *not* going into the
    /// tree — one built to navigate with, where a stack buffer is the
    /// honest lifetime and the arena would be litter.
    pub fn refTo(self: *App, name: []const u8, args: []const []const u8) ![]const u8 {
        var buf: [router_mod.max_ref_bytes]u8 = undefined;
        const written = try self.router.writeRef(&buf, name, args);
        return self.tree.ownString(written);
    }

    /// Writes `utf8` to the platform clipboard (the clipboard service —
    /// in tests, the app's journaling mock). Activating a `copyable`
    /// lands here; app actions may also call it directly. What to show
    /// for feedback is the caller's build's business; nokre adds none.
    pub fn copyText(self: *const App, utf8: []const u8) void {
        clipboard.copy(self, utf8);
    }

    pub fn invalidate(self: *App) void {
        self.needs_frame = true;
        self.layout_dirty = true;
    }

    // ---- mid-flight patches ----
    //
    // The third way state reaches the screen, beside `reload` (the
    // deliberate gesture) and `refresh` (the polite rebuild): change
    // one node and leave the rest of the tree exactly where the user
    // left it. It exists because a rebuild is the wrong answer for the
    // two things that move *while* work is running — a status line's
    // words and a control's percentage — where the screen the user is
    // reading, scrolled, and possibly typing into must not be rebuilt
    // twenty times a second to move a bar.
    //
    // Both verbs take a `NodeId` a builder kept (`Cursor.textId`,
    // `styledId`, `buttonId`, `meterId`) and both **decline on a stale
    // one**. That is the same posture `refresh` established and it is
    // not politeness for its own sake: a recorded id outlives its node
    // by construction — every rebuild frees the tree the id names, and
    // a reply landing one frame later is the ordinary case, not a
    // programmer error. What the caller wanted was for the state to be
    // on screen; the rebuild that took the node put it there already.
    //
    // Nothing reports, for the same reason `refresh` reports nothing:
    // there is no action a callback could take on the answer.

    /// Replaces a text-bearing node's content and marks the frame —
    /// `tree.setContent` plus `invalidate`, which is every call site
    /// there was. Silent on a stale or non-text id.
    ///
    /// The content is copied like every append's (and re-runs the
    /// contrast gate, since new words may be the first visible ones the
    /// ink has had), so a caller may hand it a scratch buffer.
    ///
    /// ```zig
    /// // in the builder:
    /// state.status_id = try b.textId(state.statusCopy());
    ///
    /// // in the callback, with the user mid-form:
    /// state.app.patchText(state.status_id, state.statusCopy());
    /// ```
    pub fn patchText(self: *App, id: NodeId, content: []const u8) void {
        // `setContent` refuses a bad id and a non-text element the same
        // way, and its other failure — a refused ink/fill pair, or the
        // arena — leaves the element untouched. Nothing is half-written
        // either way, so one `catch` covers all of them and the frame
        // is only marked when something actually changed.
        self.tree.setContent(id, content) catch return;
        self.invalidate();
    }

    /// Moves the progress a node shows, 0–100, and marks the frame.
    /// Silent on a stale id, and on an element with no progress to
    /// show.
    ///
    /// Two elements answer this, because two elements in the set carry
    /// a percentage:
    /// - `button` — sets `progress_percent` and, with it, `in_progress`.
    ///   The two are one state (a percentage on a button that is not
    ///   working means nothing, and append rejects that pair), so the
    ///   verb writes the state rather than half of it. The two forms
    ///   append refuses a percentage on — the 24px glyph, which has
    ///   nowhere to read one, and the vendor sign-in pill, whose
    ///   artwork is not nokre's to draw a track across — are refused
    ///   here too: a value that could not have entered through append
    ///   does not get in through a patch.
    /// - `meter` — sets `value` to that percentage of its own `max`,
    ///   truncating. With the default `max = 100` it is the number
    ///   itself. A meter counting *things* ("3 of 7") is not what this
    ///   is for: its label changes with its value, and words are a
    ///   rebuild.
    ///
    /// Percent, not the element's own units, because the callers are
    /// worker progress — a fraction of a job — and one meaning across
    /// both elements beats a parameter that means two things.
    pub fn patchProgress(self: *App, id: NodeId, percent: u8) void {
        if (percent > 100) return;
        const el = self.tree.get(id) orelse return;
        switch (el.*) {
            .button => |*b| {
                if (b.form == .glyph or b.form == .provider) return;
                b.in_progress = true;
                b.progress_percent = percent;
            },
            .meter => |*m| m.value = @divTrunc(@as(i32, percent) * m.max, 100),
            else => return,
        }
        self.invalidate();
    }

    /// The active focus layer: the topmost open modal layer
    /// (`layout.topModalLayer`), or the whole tree.
    pub fn focusScope(self: *const App) NodeId {
        return layout.topModalLayer(&self.tree) orelse self.tree.rootId();
    }

    pub fn setViewport(self: *App, viewport: Size) void {
        self.viewport = viewport;
        // A viewport that no longer fits the roster reshapes the nav
        // (nav.zig). A failed reshape leaves the old shape standing —
        // the wrong width to draw at, but drawable, which beats a nav
        // that vanished because an allocation did.
        nav_mod.syncNavChrome(self) catch {};
        self.invalidate();
    }

    /// Says the framework's own words in this app's language: the back
    /// control's name, the sheet's close, the nav chip and the marker
    /// beside it, the notices pane and every control on it
    /// (`App.Chrome`). English until this is called, so an app shipping
    /// one language never calls it.
    ///
    /// One call for all of them, and one struct, because they are one
    /// fact — what nokre calls its own chrome — and a locale changes
    /// every one at once. A setter per control would let a nav bar be
    /// half translated, which is exactly the bug this exists for.
    ///
    /// The other half of a translated nav bar is the *destinations*,
    /// whose words are the route table's (`RouteDef.title`) and never
    /// nokre's: `setLocale` says those. Pair the two with
    /// `setDirection` wherever the locale changes:
    ///
    ///     try app.setLocale(L.tag(loc));
    ///     app.setChrome(L.chrome(loc));
    ///     app.setDirection(L.dir(loc));
    ///
    /// `L.chrome` is the localized app's shape on purpose: it reads
    /// one reserved catalog key per `Chrome` field (`chromeBack`, …,
    /// derived from the field names), so a missing chrome word is a
    /// missing-key compile error in the catalog — where a bare
    /// `Chrome` literal would ship the miss as English. The bare
    /// literal stays for what the defaults are for — an app saying one
    /// or two words.
    ///
    /// Chrome standing in the tree right now is re-said on the spot —
    /// the back control, the nav's shape, the whole notice chrome — so
    /// this does not wait for the rebuild that follows a locale change.
    /// The strings are borrowed: they must outlive the app, which an
    /// ARB catalog's constant data does.
    pub fn setChrome(self: *App, chrome: Chrome) void {
        self.chrome = chrome;
        // The chrome elements copied their words in when they were
        // built, so the ones already standing are re-said here rather
        // than left for whatever rebuild happens next.
        var it = self.tree.dfs();
        while (it.next()) |id| {
            const el = self.tree.get(id) orelse continue;
            switch (el.*) {
                .back => |*b| b.label = chrome.back,
                .sheet_close => |*c| c.label = chrome.close,
                .nav_current => |*n| n.name = chrome.section,
                .nav_here => |*n| n.name = chrome.current_screen,
                .notices_pane => |*p| p.title = chrome.notices,
                // The fold's control keeps its own copy like the rest,
                // and layout is handed the same word from `chrome`
                // itself on the next pass (`App.flow`) — so the words on
                // the pill and the width claimed for them never disagree.
                .more => |*m| m.label = chrome.more,
                else => {},
            }
        }
        // The notice chrome's controls name the notices they act on, so
        // there is nothing to patch in place — it is rebuilt, which is
        // what that function is for.
        notices_mod.syncNoticeChrome(self) catch {};
        self.invalidate();
    }

    /// Chooses the app's locale — the language the app is *in*, as a
    /// BCP 47 tag — and re-says every route title declared as a
    /// function of it (`RouteDef.Title.of_locale`) on the spot.
    ///
    /// What a *screen* is called is `RouteDef.title`'s and nothing
    /// else's — the nav's destinations, the collapsed chip's section,
    /// the picker's rows and the marker for an off-roster screen are all
    /// labelled from there (`nav.effectiveRoster`), which is what keeps
    /// one screen to one name. The table used to be re-handed whole to
    /// say it in another language; now the locale is the app's own
    /// state, and the titles are functions of it. There is no second
    /// table, so there is nothing to hold, stamp, or get positionally
    /// wrong.
    ///
    /// Pass the tag of the locale actually on screen — the *resolved*
    /// one (`L.tag(L.resolve(…))`), not the raw device ask — so the
    /// titles and the catalog agree. Chrome words and direction stay
    /// their own calls (`setChrome`, `setDirection`): nokre cannot
    /// read a consumer's catalog, and the chrome's mirror is a choice.
    ///
    /// Validated whole before anything is assigned, `Router.init`'s
    /// rule: every title must answer this tag with words, and an
    /// over-long tag is a programmer error, not a truncation — a
    /// refused call leaves the app exactly as it was.
    ///
    /// The nav's roster re-evaluates on the spot and its chrome
    /// resyncs, so a row of destinations, a collapsed chip and the
    /// marker beside them all change together.
    pub fn setLocale(self: *App, tag: []const u8) error{ LocaleTagTooLong, EmptyRouteTitle }!void {
        if (tag.len > locale_svc.max_tag_bytes) return error.LocaleTagTooLong;
        for (self.router.routes) |r| {
            if (r.title.text(tag).len == 0) return error.EmptyRouteTitle;
        }
        @memcpy(self.locale_buf[0..tag.len], tag);
        self.locale_len = @intCast(tag.len);
        // The roster holds evaluated titles (`nav.RosterItem` borrows
        // constant data), so it is re-evaluated here rather than left
        // reading the old language until the next `setNav`.
        for (self.nav_items.items) |*item| {
            const def = self.router.lookup(item.route).?;
            item.label = def.title.text(self.locale());
        }
        nav_mod.syncNavChrome(self) catch {};
        self.invalidate();
    }

    /// The chosen locale's tag (`setLocale`) — "" until the app has
    /// chosen. The *device's* ask is the locale service's
    /// (`services.locale.tag`); this is the app's answer to it.
    pub fn locale(self: *const App) []const u8 {
        return self.locale_buf[0..self.locale_len];
    }

    /// States what this screen is called, and draws it as the page's
    /// `h1` above everything the builder appends (`Tree.setTitle`).
    ///
    /// A routed screen already has one: the router draws
    /// `RouteDef.title` before the builder runs, so an app that says
    /// nothing here still publishes a page with a top. This is for the
    /// screen whose title is not the route's — `note~42` is "Note" to
    /// the chrome and "Meeting notes" to the reader — and for the one
    /// that wants no visible title at all, which is `setTitle("")` and
    /// nothing else.
    ///
    /// It is a screen's fact, not a builder's element, so it may be
    /// said at any point in the build and lands in the same place
    /// either way — which is what lets a screen state the title it only
    /// learns from a load it just finished.
    ///
    /// Content, not chrome: like every other word a builder writes, the
    /// drawn title follows a rebuild rather than `setLocale`.
    pub fn setTitle(self: *App, words: []const u8) !void {
        try self.tree.setTitle(words);
        self.invalidate();
    }

    /// What this screen is called (`setTitle`) — `""` when it draws no
    /// title. A static driver reads it for the `<title>` it would
    /// otherwise be made to restate (docs/static-sites.md).
    pub fn title(self: *const App) []const u8 {
        return self.tree.title();
    }

    /// Sets the chrome direction, mirroring the layout when it changes.
    /// Pair it with the locale — `app.setDirection(L.dir(loc))` beside
    /// `setLocale` — or with a raw tag via `l10n.directionOfTag`. This mirrors
    /// chrome only; text keeps aligning by its own content, so calling
    /// it is never needed for RTL *text* to render correctly.
    pub fn setDirection(self: *App, dir: bidi.Direction) void {
        if (self.direction == dir) return;
        self.direction = dir;
        self.invalidate();
    }

    /// Swaps how text is measured. Shells install the real measurer at
    /// construction and never touch it again; the golden harness swaps
    /// the fixed one for Skia's after building a tree, and that is the
    /// case this exists for.
    ///
    /// It resyncs the nav for the same reason `setViewport` does: label
    /// widths decide whether the destinations fit a row, so changing who
    /// measures them can change the answer (nav.zig).
    pub fn setMeasurer(self: *App, m: text.Measurer) void {
        self.measurer = m;
        nav_mod.syncNavChrome(self) catch {};
        self.invalidate();
    }

    /// Declares what the surface this app is drawn on does with a row
    /// too wide for it — `layout.Medium`, and the driver's word, not the
    /// consumer's (see the field).
    ///
    /// It resyncs the nav for `setMeasurer`'s reason and one more: the
    /// answer it carries is *whether the shape question is live at all*,
    /// so a bar already standing when a driver declares itself has to be
    /// re-asked, not left in the shape a default answered for it.
    pub fn setMedium(self: *App, m: layout.Medium) void {
        if (self.medium == m) return;
        self.medium = m;
        nav_mod.syncNavChrome(self) catch {};
        self.invalidate();
    }

    pub fn setSafeBottom(self: *App, px: i32) void {
        if (self.safe_bottom == px) return;
        self.safe_bottom = px;
        self.invalidate();
    }

    pub fn setScheme(self: *App, scheme: color.Scheme) void {
        if (self.scheme == scheme) return;
        self.scheme = scheme;
        self.needs_frame = true;
    }

    /// Shells call this when the OS appearance changes.
    pub fn setSystemAppearance(self: *App, system: color.Appearance) void {
        if (self.system_appearance == system) return;
        self.system_appearance = system;
        if (self.scheme == .auto) self.needs_frame = true;
    }

    pub fn appearance(self: *const App) color.Appearance {
        return self.scheme.resolve(self.system_appearance);
    }

    /// Recomputes layout if anything changed. Cheap to call every frame.
    pub fn performLayout(self: *App) void {
        if (!self.layout_dirty) return;
        self.flow();
        // A row of actions folding is a tree change that only a
        // measured pass can decide (overflow.zig), so it happens between
        // two of them. Exactly one extra pass, always: the width the fold
        // reserves for the control does not depend on the control being
        // there, so the second pass folds the row the same way the first
        // one did and has nothing left to change.
        if (overflow.syncOverflowChrome(self)) self.flow();
        self.layout_dirty = false;
    }

    /// One pass: place everything, then re-place it if the content
    /// turned out too short for where it was scrolled to.
    fn flow(self: *App) void {
        self.root_content_height = layout.computeScrolled(&self.tree, self.measurer, self.viewport, self.root_scroll, self.safe_bottom, self.direction, self.chrome.more, self.medium);
        const limit = layout.contentArea(&self.tree, self.viewport, self.safe_bottom).h;
        const clamped = std.math.clamp(self.root_scroll, 0, @max(0, self.root_content_height - limit));
        if (clamped != self.root_scroll) {
            self.root_scroll = clamped;
            _ = layout.computeScrolled(&self.tree, self.measurer, self.viewport, clamped, self.safe_bottom, self.direction, self.chrome.more, self.medium);
        }
    }

    pub fn dispatch(self: *App, event: Event) !void {
        self.performLayout();
        // Any non-scroll input releases the indicator-emphasis latch;
        // scroll movement below re-arms it (see `scroll_hot`). A latch
        // going out is a visible change like any other, and the handler
        // that runs next may have nothing of its own to repaint for —
        // a tap on dead space, a step of the back gesture — so the frame
        // is asked for here rather than left to it.
        if (event != .scroll and self.scroll_hot != .none) {
            self.scroll_hot = .none;
            self.needs_frame = true;
        }
        // What the acknowledgement rule below compares against. A tap is
        // a press and a release, and only the release can activate, so
        // the mark it "found" is the one the press saw — carried on the
        // press itself (input.zig's `Press`). Every other input is a
        // single event and reads the mark directly.
        const held = switch (event) {
            .pointer => |p| if (p.phase == .up)
                (if (self.press) |pr| pr.ack_before else self.ack)
            else
                null,
            else => self.ack,
        };
        switch (event) {
            .pointer => |p| try input.handlePointer(self, p),
            .key_down => |k| try input.handleKey(self, k.key, k.mods),
            .text => |t| try editing.insertText(self, t.bytes),
            .ime => |ime| try editing.handleIme(self, ime),
            .scroll => |s| scrolling.handleScroll(self, s),
            .edge_pan => |p| try input.handleEdgePan(self, p),
        }
        self.releaseAck(held);
    }

    /// What a backend that resolves its own hits delivers instead of a
    /// pointer: the element the reader meant, named rather than located.
    ///
    /// [renderer-editions.md](../../docs/internals/renderer-editions.md)
    /// anticipated exactly this — an edition that owns its layout
    /// "inverts the event flow: the backend would resolve hits and
    /// deliver semantic events". Which element was meant is the *only*
    /// thing such a backend knows better than core. Everything an input
    /// carries besides that — the latches it releases, the focus it
    /// moves, what activation means — is core's, and a backend applying
    /// any of it itself would be keeping a second copy of a rule that
    /// has one home. One press is one call.
    pub const Semantic = union(enum) {
        /// A press that landed on a focus stop. Focus moves to it and it
        /// activates: the pointer path's two halves, arriving together
        /// because the hit was already resolved.
        press: focus.Focus,
        /// Focus moved on its own — a traversal the backend handled.
        focus: focus.Focus,
        /// One option of an exclusive choice, chosen without measuring
        /// a chip.
        select: struct { node: NodeId, index: usize },
    };

    pub fn deliver(self: *App, event: Semantic) !void {
        self.performLayout();
        // Every input releases the indicator-emphasis latch; only
        // scrolling re-arms it, and none of these is a scroll.
        if (self.scroll_hot != .none) {
            self.scroll_hot = .none;
            self.needs_frame = true;
        }
        const held = self.ack;
        switch (event) {
            .press => |stop| {
                // A resolved press is pointer-origin by definition, so
                // the drawn focus indicator stands down exactly as it
                // does for the pointer path (`focus_visible`).
                self.focus_visible = false;
                if (self.tree.getConst(stop.node)) |el| {
                    // An inline link is a focus stop on a node that is
                    // not itself focusable — the paragraph carrying the
                    // span — so a span hit takes focus the way the
                    // pointer path's `pressDown` does for every stop.
                    if (el.isFocusable() or stop.span != null) self.focused = stop;
                }
                try input.activateStop(self, stop);
            },
            .focus => |f| {
                // The stop is a stranger's: a shell repeats what the OS
                // or the browser named, and neither knows this tree. So
                // it is vetted here, where `activateStop` vets the same
                // shape — one home, and every seam that delivers focus
                // gets the whole check instead of the part it thought
                // of. A stop that is not one is dropped, not invented:
                // `focused` pointing at a paragraph would draw a ring
                // nothing can leave by Tab.
                const el = self.tree.getConst(f.node) orelse return;
                if (f.span) |i| {
                    const spans = focus.spansOf(el.*);
                    if (i >= spans.len or !spans[i].isLink()) return;
                } else if (!el.isFocusable()) return;
                // A traversal the backend handled — keyboard or
                // assistive tech — is exactly the focus that must be
                // seen to be followed.
                self.focus_visible = true;
                self.focused = f;
                self.needs_frame = true;
            },
            .select => |s| input.selectOption(self, s.node, s.index),
        }
        self.releaseAck(held);
    }

    /// One rule, no exceptions: an input releases whatever
    /// acknowledgement it found, and only one armed during that input
    /// survives (see `ack`). Every case falls out of it — an untouched
    /// mark clears, a second element steals the mark, and re-activating
    /// the marked element copies again and toggles the mark off. That
    /// last one is why the rule is written this way: with no animation
    /// to replay, the mark leaving is the only visible sign the second
    /// copy happened, and a check that just sat there would read as the
    /// dead control this replaced. Unlike `scroll_hot` there is no
    /// scroll exemption: scroll movement is what arms that latch, and
    /// nothing arms this one but activation.
    ///
    /// It runs once per *input*, which is why it lives here and not in
    /// whatever delivered one: a caller that made two calls for one
    /// press would release the mark and re-arm it, and the check would
    /// never leave.
    fn releaseAck(self: *App, held: ?NodeId) void {
        const now = self.ack orelse return;
        const before = held orelse return;
        if (!now.eql(before)) return;
        self.ack = null;
        self.needs_frame = true; // the mark leaving is the visible part
    }
};
