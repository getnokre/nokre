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
    notices: std.ArrayList(notices_mod.OwnedNotice) = .empty,
    /// How the pending notices surface; `.none` iff there are none.
    notice_state: NoticeState = .none,
    /// The framework's own words, in this app's language (`setChrome`).
    /// English until an app says otherwise. Borrowed, never owned — a
    /// catalog's `tr` hands back constant data, `RouteDef.title`'s rule.
    chrome: Chrome = .{},

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

    pub const setNav = nav_mod.setNav;
    pub const clearNav = nav_mod.clearNav;
    pub const openSheet = overlays.openSheet;
    pub const presentSheet = overlays.presentSheet;
    pub const dismissSheet = overlays.dismissSheet;
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
            .safe_bottom = options.safe_bottom,
            .ctx = options.ctx,
            .scheme = options.scheme,
        };
        errdefer self.runtime.destroy();
        try self.services.init(gpa, self.runtime);
        return self;
    }

    pub fn deinit(self: *App) void {
        // Workers first: threads join and queued deliveries drop before
        // anything they could reference goes away. Services next —
        // their parked state points into the runtime's tickets.
        self.runtime.destroy();
        self.services.deinit();
        for (self.notices.items) |n| n.deinit(self.gpa);
        self.notices.deinit(self.gpa);
        self.nav_items.deinit(self.gpa);
        self.router.deinit(self.gpa);
        self.tree.deinit();
        self.gpa.destroy(self.bidi_scratch);
    }

    pub fn navigate(self: *App, route: []const u8) !void {
        try self.router.push(self, route);
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
    pub fn reload(self: *App) !void {
        try self.router.reload(self);
    }

    /// Enter `ref` with the stack reset to just it (router.zig says
    /// when that is the right arrival), aliased for the same reason
    /// as `reload`.
    pub fn switchTo(self: *App, ref: []const u8) !void {
        try self.router.switchTo(self, ref);
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
    /// against the table before a byte lands (router.zig `ref`), so
    /// the site that builds a reference is the site that learns it is
    /// wrong, and no consumer holds the `~` literal or a guessed
    /// buffer size. `[Router.max_ref_bytes]u8` always fits.
    pub fn routeRef(self: *const App, buf: []u8, name: []const u8, args: []const []const u8) ![]u8 {
        return self.router.ref(buf, name, args);
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
    /// nokre's: `setRouteTitles` is that half. Pair the two with
    /// `setDirection` at boot and again wherever the locale changes:
    ///
    ///     app.setChrome(.{ .back = L.tr(loc, .back), … });
    ///     try app.setRouteTitles(routeTable(loc));
    ///     app.setDirection(L.dir(loc));
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

    /// Re-declares the route table in another language: the same table,
    /// said differently.
    ///
    /// What a *screen* is called is `RouteDef.title`'s and nothing
    /// else's — the nav's destinations, the collapsed chip's section,
    /// the picker's rows and the marker for an off-roster screen are all
    /// labelled from there (`nav.effectiveRoster`), which is what keeps
    /// one screen to one name. But that table is comptime and a locale
    /// is not, so a translated app has to be able to hand over the same
    /// table with translated titles. Build it from your catalog and pass
    /// it here.
    ///
    /// Only the titles may differ, and that is enforced: same length,
    /// same names, same arities, same builders, position for position.
    /// A stack entry holds an *index* into the table, so a different
    /// table would silently rename every screen on the stack after the
    /// first mismatch — `error.RouteTablesDiffer` instead. Nothing is
    /// committed until the whole table has passed, so a refused call
    /// leaves the app exactly as it was.
    ///
    /// The nav's roster re-borrows from the new table on the spot and
    /// its chrome resyncs, so a row of destinations, a collapsed chip
    /// and the marker beside them all change together.
    pub fn setRouteTitles(self: *App, routes: []const router_mod.RouteDef) !void {
        try self.router.retitle(routes);
        // The roster borrowed every string it holds from the old table
        // (`nav.RosterItem`), so it is re-pointed rather than merely
        // re-labelled: the table it was reading may be about to go.
        for (self.nav_items.items) |*item| {
            const def = self.router.lookup(item.route).?;
            item.route = def.name;
            item.label = def.title;
        }
        nav_mod.syncNavChrome(self) catch {};
        self.invalidate();
    }

    /// Sets the chrome direction, mirroring the layout when it changes.
    /// Pair it with the locale — `app.setDirection(L.dir(state.locale))`
    /// — or with the device tag via `l10n.directionOfTag`. This mirrors
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
        self.root_content_height = layout.computeScrolled(&self.tree, self.measurer, self.viewport, self.root_scroll, self.safe_bottom, self.direction, self.chrome.more);
        const limit = layout.contentArea(&self.tree, self.viewport, self.safe_bottom).h;
        const clamped = std.math.clamp(self.root_scroll, 0, @max(0, self.root_content_height - limit));
        if (clamped != self.root_scroll) {
            self.root_scroll = clamped;
            _ = layout.computeScrolled(&self.tree, self.measurer, self.viewport, clamped, self.safe_bottom, self.direction, self.chrome.more);
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
