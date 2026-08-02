//! The retained semantic tree. Consumers build and mutate this; layout,
//! rendering, accessibility, focus, and testing all read from it.
//!
//! NodeIds are generational: using an id after its node was removed is
//! detected, not undefined behavior, until a single slot has been freed
//! 4096 times — the generation counter then wraps and an id that old
//! could alias a live node (see `NodeId` for why the widths are what
//! they are). All strings passed in are duplicated
//! into a tree-owned arena — the tree never borrows consumer memory —
//! and the copy validates: the tree stores only well-formed UTF-8, with
//! invalid sequences replaced by U+FFFD (`dupeValid`), so every scan
//! downstream (wrapping, bidi, cursor motion) may trust sequence
//! lengths instead of re-checking them.
//! Arena memory is reclaimed on `reclaim` (a router rebuild does this)
//! or `deinit`, not on node removal; rebuild the tree rather than
//! churning nodes in place.

const std = @import("std");
const element_mod = @import("element.zig");
const geometry = @import("geometry.zig");
const color = @import("color.zig");
const markdown = @import("markdown.zig");
// For the external-destination scheme check only: the allowlist is the
// service's one fact, consulted here so construction and the OS call
// cannot disagree about which URLs exist.
const open_url = @import("../services/open_url/open_url.zig");
const qr = @import("qr.zig");

pub const Element = element_mod.Element;
pub const Rect = geometry.Rect;

/// The root every tree opens with: a vertical stack whose padding is the
/// page margin and whose gap is the space between two blocks. Named
/// rather than written inline at `init`, because a second edition lays
/// the root out itself — the DOM one hangs the `nokre` class's padding
/// and gap off exactly these two numbers — and a page margin that
/// disagreed with the reference's would be the one value no element
/// could correct for.
pub const root_stack: element_mod.Stack = .{ .axis = .vertical, .gap = 8, .padding = 16 };

/// Packed to exactly 32 bits: the DOM serializer, the a11y bridge, and
/// the wasm boundary all move an id as one `u32` (`@bitCast`), so the
/// total width is a wire format. Within it, the split favors the
/// generation over the index: a million-node tree is out of reach, but
/// a router rebuild frees and reallocates the content subtree on every
/// navigation, so low slots cycle once per screen change — the
/// generation counter is what a long session actually spends. At u12 a
/// stale id can alias a live node only after the same slot has been
/// freed 4096 times; at the u8 it replaces, ~256 navigations — an
/// ordinary session — was enough.
pub const NodeId = packed struct(u32) {
    index: u20,
    gen: u12,

    pub const invalid: NodeId = .{ .index = std.math.maxInt(u20), .gen = std.math.maxInt(u12) };

    pub fn eql(a: NodeId, b: NodeId) bool {
        return a.index == b.index and a.gen == b.gen;
    }

    pub fn isValid(self: NodeId) bool {
        return !self.eql(invalid);
    }
};

const Node = struct {
    element: Element,
    parent: NodeId = .invalid,
    first_child: NodeId = .invalid,
    last_child: NodeId = .invalid,
    next_sibling: NodeId = .invalid,
    prev_sibling: NodeId = .invalid,
    gen: u12 = 0,
    alive: bool = false,
    /// Written by layout each frame; coordinates are absolute logical px.
    rect: Rect = .zero,
};

pub const Tree = struct {
    gpa: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    nodes: std.ArrayList(Node),
    free_list: std.ArrayList(u20),
    root: NodeId,

    pub fn init(gpa: std.mem.Allocator) !Tree {
        var tree: Tree = .{
            .gpa = gpa,
            .arena = std.heap.ArenaAllocator.init(gpa),
            .nodes = .empty,
            .free_list = .empty,
            .root = .invalid,
        };
        tree.root = try tree.allocNode(.{ .stack = root_stack });
        return tree;
    }

    pub fn deinit(self: *Tree) void {
        self.nodes.deinit(self.gpa);
        self.free_list.deinit(self.gpa);
        self.arena.deinit();
    }

    pub fn rootId(self: *const Tree) NodeId {
        return self.root;
    }

    /// Appends a child under `parent`. String fields are copied.
    /// Malformed structure is rejected here, not detected later: an
    /// invalid tree cannot be built (see docs/accessibility.md).
    pub fn append(self: *Tree, parent: NodeId, element: Element) !NodeId {
        const id = try self.createDetached(parent, element);
        const p = self.nodePtrUnchecked(parent);
        const prev_last = p.last_child;
        const n = self.nodePtrUnchecked(id);
        if (prev_last.isValid()) {
            self.nodePtrUnchecked(prev_last).next_sibling = id;
            n.prev_sibling = prev_last;
        } else {
            self.nodePtrUnchecked(parent).first_child = id;
        }
        self.nodePtrUnchecked(parent).last_child = id;
        try self.expandLinked(id, element);
        return id;
    }

    /// A `document` is expanded once it is linked in, so its children
    /// go through `append` — the parser produces nothing the framework
    /// does not already know, and every rule there applies to parsed
    /// content for free. Every insertion path runs this, so a document
    /// lands expanded no matter where in the sibling order it enters. A
    /// parse that the tree refuses surfaces as the insertion's error.
    fn expandLinked(self: *Tree, id: NodeId, element: Element) !void {
        if (element != .document) return;
        errdefer self.remove(id) catch {};
        try markdown.expand(self, id, self.getConst(id).?.document.source);
    }

    /// `append`, but linked immediately after `sibling`. App chrome uses
    /// this to keep focus order aligned with visual order (a notice goes
    /// right after the nav, before content).
    pub fn insertAfter(self: *Tree, sibling: NodeId, element: Element) !NodeId {
        const sib = self.node(sibling) orelse return error.InvalidNode;
        const parent = sib.parent;
        if (!parent.isValid()) return error.InvalidNode;
        const id = try self.createDetached(parent, element);
        const next = self.nodePtrUnchecked(sibling).next_sibling;
        const n = self.nodePtrUnchecked(id);
        n.prev_sibling = sibling;
        n.next_sibling = next;
        self.nodePtrUnchecked(sibling).next_sibling = id;
        if (next.isValid()) {
            self.nodePtrUnchecked(next).prev_sibling = id;
        } else {
            self.nodePtrUnchecked(parent).last_child = id;
        }
        try self.expandLinked(id, element);
        return id;
    }

    /// `append`, but linked as the first child.
    pub fn insertFirst(self: *Tree, parent: NodeId, element: Element) !NodeId {
        if (self.node(parent) == null) return error.InvalidNode;
        const id = try self.createDetached(parent, element);
        const first = self.nodePtrUnchecked(parent).first_child;
        const n = self.nodePtrUnchecked(id);
        n.next_sibling = first;
        if (first.isValid()) {
            self.nodePtrUnchecked(first).prev_sibling = id;
        } else {
            self.nodePtrUnchecked(parent).last_child = id;
        }
        self.nodePtrUnchecked(parent).first_child = id;
        try self.expandLinked(id, element);
        return id;
    }

    fn createDetached(self: *Tree, parent: NodeId, element: Element) !NodeId {
        if (self.node(parent) == null) return error.InvalidNode;
        try self.validateAppend(parent, element);
        const owned = try dupeStringsInto(self.arena.allocator(), element);
        const id = try self.allocNode(owned);
        self.nodePtrUnchecked(id).parent = parent;
        return id;
    }

    /// Removes a node and its whole subtree.
    pub fn remove(self: *Tree, id: NodeId) !void {
        if (id.eql(self.root)) return error.CannotRemoveRoot;
        const n = self.node(id) orelse return error.InvalidNode;

        if (n.prev_sibling.isValid()) {
            self.nodePtrUnchecked(n.prev_sibling).next_sibling = n.next_sibling;
        } else if (n.parent.isValid()) {
            self.nodePtrUnchecked(n.parent).first_child = n.next_sibling;
        }
        if (n.next_sibling.isValid()) {
            self.nodePtrUnchecked(n.next_sibling).prev_sibling = n.prev_sibling;
        } else if (n.parent.isValid()) {
            self.nodePtrUnchecked(n.parent).last_child = n.prev_sibling;
        }
        self.releaseSubtree(id);
    }

    pub fn clearChildren(self: *Tree, id: NodeId) !void {
        const n = self.node(id) orelse return error.InvalidNode;
        var child = n.first_child;
        while (child.isValid()) {
            const next = self.nodePtrUnchecked(child).next_sibling;
            self.releaseSubtree(child);
            child = next;
        }
        const np = self.nodePtrUnchecked(id);
        np.first_child = .invalid;
        np.last_child = .invalid;
    }

    pub fn get(self: *Tree, id: NodeId) ?*Element {
        const n = self.nodePtr(id) orelse return null;
        return &n.element;
    }

    pub fn getConst(self: *const Tree, id: NodeId) ?*const Element {
        const n = self.node(id) orelse return null;
        return &n.element;
    }

    pub fn parentOf(self: *const Tree, id: NodeId) ?NodeId {
        const n = self.node(id) orelse return null;
        return if (n.parent.isValid()) n.parent else null;
    }

    /// Whether `id` is `ancestor` or one of its descendants.
    pub fn isDescendant(self: *const Tree, id: NodeId, ancestor: NodeId) bool {
        var cur: ?NodeId = id;
        while (cur) |c| : (cur = self.parentOf(c)) {
            if (c.eql(ancestor)) return true;
        }
        return false;
    }

    pub fn rectOf(self: *const Tree, id: NodeId) Rect {
        const n = self.node(id) orelse return .zero;
        return n.rect;
    }

    pub fn setRect(self: *Tree, id: NodeId, rect: Rect) void {
        if (self.nodePtr(id)) |n| n.rect = rect;
    }

    /// Replaces a text-bearing element's content, copying `content`.
    pub fn setContent(self: *Tree, id: NodeId, content: []const u8) !void {
        const el = self.get(id) orelse return error.InvalidNode;
        const owned = try dupeValid(self.arena.allocator(), content);
        switch (el.*) {
            // New content replaces the whole text, so stale spans (ranges
            // over the old bytes) are dropped rather than dangling.
            .text => |*t| {
                // The append-time contrast gate, re-run: append accepts
                // whitespace-only text with any ink because no ink is
                // rendered (`ambientTextInk`), so this is the first
                // moment an illegible ink could meet visible words —
                // same check, same error, and a refused pair leaves the
                // element untouched, exactly as append would have.
                if (std.mem.trim(u8, owned, " \t\n\r").len != 0)
                    try color.checkTextPair(t.style.ink, self.backgroundBehind(self.node(id).?.parent));
                t.content = owned;
                t.spans = &.{};
            },
            .heading => |*h| {
                h.content = owned;
                h.spans = &.{};
            },
            // Same rule for the caret: a position past the new value's
            // end is stale state, dropped (clamped) rather than dangling
            // into bytes that no longer exist — and clamped to a
            // codepoint boundary, not merely to length, or a caret kept
            // mid-codepoint would hand every prefix slice invalid UTF-8.
            .text_input => |*i| {
                i.value = owned;
                i.cursor = codepointFloor(owned, i.cursor);
            },
            .text_area => |*ta| {
                ta.value = owned;
                ta.cursor = codepointFloor(owned, ta.cursor);
            },
            else => return error.NotTextBearing,
        }
    }

    /// Copies `s` into tree-owned memory, validating like every other
    /// copy at this boundary. Used by event handling for text-input
    /// edits.
    pub fn ownString(self: *Tree, s: []const u8) ![]const u8 {
        return dupeValid(self.arena.allocator(), s);
    }

    /// The arena reclaim point the module doc promises. Every string
    /// owned by a *surviving* node is re-copied into a fresh arena and
    /// the old one — holding every removed screen's strings, every
    /// editing splice copy, every resynced chrome label since the last
    /// reclaim — is freed. Node identity is untouched: chrome that
    /// deliberately survives a router rebuild (the nav's shape, the
    /// collapsed chip) keeps the ids that focus and tests hold.
    ///
    /// Two phases so failure cannot half-poison the tree: everything
    /// fallible lands in the fresh arena and a gpa-side list first, and
    /// only then does an infallible swap rewrite the nodes and drop the
    /// old memory. On error the tree is exactly as it was.
    pub fn reclaim(self: *Tree) !void {
        var fresh = std.heap.ArenaAllocator.init(self.gpa);
        errdefer fresh.deinit();
        var ids: std.ArrayList(NodeId) = .empty;
        defer ids.deinit(self.gpa);
        var copies: std.ArrayList(Element) = .empty;
        defer copies.deinit(self.gpa);
        var it = self.dfs();
        while (it.next()) |id| {
            try ids.append(self.gpa, id);
            try copies.append(self.gpa, try dupeStringsInto(fresh.allocator(), self.node(id).?.element));
        }
        for (ids.items, copies.items) |id, el| self.nodePtrUnchecked(id).element = el;
        self.arena.deinit();
        self.arena = fresh;
    }

    pub const ChildIterator = struct {
        tree: *const Tree,
        next_id: NodeId,

        pub fn next(self: *ChildIterator) ?NodeId {
            if (!self.next_id.isValid()) return null;
            const id = self.next_id;
            self.next_id = self.tree.node(id).?.next_sibling;
            return id;
        }
    };

    pub fn children(self: *const Tree, id: NodeId) ChildIterator {
        const first = if (self.node(id)) |n| n.first_child else NodeId.invalid;
        return .{ .tree = self, .next_id = first };
    }

    pub fn childCount(self: *const Tree, id: NodeId) usize {
        var it = self.children(id);
        var n: usize = 0;
        while (it.next()) |_| n += 1;
        return n;
    }

    /// Allocation-free depth-first pre-order traversal of the whole tree.
    pub const DfsIterator = struct {
        tree: *const Tree,
        next_id: NodeId,
        /// Subtree boundary: the climb for a next sibling stops here.
        stop: NodeId = .invalid,

        pub fn next(self: *DfsIterator) ?NodeId {
            if (!self.next_id.isValid()) return null;
            const id = self.next_id;
            const n = self.tree.node(id).?;
            if (n.first_child.isValid()) {
                self.next_id = n.first_child;
            } else {
                var cur = id;
                self.next_id = .invalid;
                while (cur.isValid() and !cur.eql(self.stop)) {
                    const cn = self.tree.node(cur).?;
                    if (cn.next_sibling.isValid()) {
                        self.next_id = cn.next_sibling;
                        break;
                    }
                    cur = cn.parent;
                }
            }
            return id;
        }
    };

    pub fn dfs(self: *const Tree) DfsIterator {
        return .{ .tree = self, .next_id = self.root };
    }

    /// Depth-first pre-order over `scope` and its descendants only.
    pub fn dfsUnder(self: *const Tree, scope: NodeId) DfsIterator {
        return .{ .tree = self, .next_id = scope, .stop = scope };
    }

    /// The root's child of `role`, if it has one. Chrome (nav, sheet,
    /// picker, notice, notices pane, the notices indicator) lives at the
    /// root and at most one of each may exist, so this is both how
    /// `validateAppend` enforces uniqueness and how layout finds them.
    pub fn rootChild(self: *const Tree, role: element_mod.Role) ?NodeId {
        var it = self.children(self.root);
        while (it.next()) |c| {
            if (self.getConst(c).?.role() == role) return c;
        }
        return null;
    }

    /// Whether `id` is the notices pane or the scroll region it holds its
    /// rows in — the two nodes a notice row may hang off.
    pub fn inNoticesPane(self: *const Tree, id: NodeId) bool {
        return switch (self.getConst(id).?.role()) {
            .notices_pane => true,
            .scroll_region => if (self.parentOf(id)) |p|
                self.getConst(p).?.role() == .notices_pane
            else
                false,
            else => false,
        };
    }

    // ---- internals ----

    fn validateAppend(self: *const Tree, parent: NodeId, element: Element) !void {
        const parent_role = self.getConst(parent).?.role();
        switch (parent_role) {
            .table => if (element.role() != .row) return error.TableChildMustBeRow,
            .row => if (element.role() != .cell) return error.RowChildMustBeCell,
            // A nav renders one of two shapes and never a mix: the row of
            // destinations — optionally tailed by the marker for a screen
            // that is none of them — or the collapsed chip standing in
            // for all of them (`nav.syncNavChrome`). Row and chip
            // together would put the same section in the focus order
            // twice; the marker joins the row because it is *not* in the
            // focus order at all, and the chip already carries what it
            // would have said (`element.NavHere`).
            .nav => switch (element.role()) {
                // Past the marker there is nothing to add: it is the
                // tail of the row, and a destination behind it would be
                // read after the screen it is standing on.
                .nav_item => {
                    if (self.navHasCurrent(parent)) return error.NavShapeIsExclusive;
                    if (self.navHasHere(parent)) return error.NavItemAfterNavHere;
                },
                .nav_here => {
                    if (self.navHasCurrent(parent)) return error.NavShapeIsExclusive;
                    if (self.navHasHere(parent)) return error.MultipleNavHere;
                },
                .nav_current => if (self.childCount(parent) != 0) return error.NavShapeIsExclusive,
                else => return error.NavChildMustBeNavItem,
            },
            .tile_group => if (element.role() != .tile) return error.TileGroupChildMustBeTile,
            .list => if (element.role() != .list_item) return error.ListChildMustBeListItem,
            .list_item => if (!isDocumentBlock(element.role())) return error.InvalidListItemChild,
            .blockquote => if (!isDocumentBlock(element.role())) return error.InvalidBlockquoteChild,
            // A picker holds its option scroll region, optionally led by
            // the framework's filter field.
            .picker => if (element.role() != .scroll_region and element.role() != .text_input) return error.InvalidPickerChild,
            else => {},
        }
        // A sign-in button's words are the vendor's, so "any non-empty
        // label" is not the rule it is failing — checked ahead of the
        // general one so the error names the specific fix: the vendor's
        // own published string for the locale being rendered
        // (element.zig). nokre ships the mark, never a translation.
        if (element == .button and element.button.provider != null and element.button.label.len == 0)
            return error.AuthButtonNeedsVendorLabel;
        switch (element) {
            .button, .link, .toggle, .checkbox, .text_input, .text_area, .nav_item, .segmented, .tile, .radio_group, .select, .copyable, .icon_button, .picker_item => {
                if (element.label().len == 0) return error.UnlabeledInteractive;
            },
            else => {},
        }
        switch (element) {
            // Spanned text: content is derived (append writes the
            // concatenation), so providing both is ambiguous and
            // rejected rather than silently resolved.
            .text => |t| try self.validateSpans(parent, t.content, t.spans, t.style.ink),
            .heading => |h| try self.validateSpans(parent, h.content, h.spans, .ink),
            // A link goes exactly one place. Both destinations set is
            // ambiguity refused rather than resolved, and an external
            // one faces open_url's closed scheme set here, at
            // construction — so a link that can be built is a link that
            // can be opened.
            .link => |l| {
                if (l.external) |url| {
                    if (l.route.len != 0) return error.RouteAndExternal;
                    if (!open_url.schemeAllowed(url)) return error.UnsupportedScheme;
                } else if (l.route.len == 0) return error.EmptyRoute;
            },
            // Icon-only is a rendering exception, not a state of its own:
            // without a glyph there is nothing to render, and without a
            // pill there is no emphasis to vary.
            .button => |b| {
                // The vendor's mark occupies the icon slot, and no
                // vendor sanctions a glyph-only sign-in button — so
                // neither combination is a thing to resolve, and both
                // are refused at the call site instead. These come first
                // because they name the more specific misuse: a
                // provider button asking for the glyph form should hear
                // about the provider, not about a missing icon.
                if (b.provider != null and b.icon != null) return error.AuthButtonHasNoIcon;
                if (b.provider != null and b.icon_only) return error.AuthButtonNeedsItsLabel;
                // Apple sanctions an outlined third style and `secondary`
                // maps onto it; Google sanctions themes the appearance
                // already picks, and no outlined form exists to map to —
                // so the flag would render a button no guideline
                // describes, and is refused instead (element.zig).
                if (b.provider == .google and b.secondary) return error.GoogleButtonHasOneEmphasis;
                // No vendor sanctions a progress bar inside their
                // button, and the brand pill is drawn through a
                // light-pinned canvas at the true endpoints — a track on
                // that ground would be nokre restyling artwork that is
                // not nokre's. Sign-in has no percentage anyway.
                if (b.provider != null and b.progress_percent != null) return error.AuthButtonHasNoMeter;
                if (b.icon_only and b.icon == null) return error.IconOnlyButtonNeedsIcon;
                if (b.icon_only and b.secondary) return error.IconOnlyButtonHasNoEmphasis;
                // A percentage describes work; without work there is
                // nothing for it to describe, and on a 24px glyph target
                // there is nowhere to read it. Both are call-site
                // mistakes, not states to resolve at draw time.
                if (b.progress_percent) |pct| {
                    if (!b.in_progress) return error.ProgressNeedsInProgress;
                    if (b.icon_only) return error.IconOnlyButtonHasNoMeter;
                    if (pct > 100) return error.ProgressOutOfRange;
                }
            },
            // Margins are advice a child may decline (layout's
            // `Ctx.margin`); the outward escape a negative inset buys
            // elsewhere has no meaning here, so the hack cannot be built.
            .stack => |s| if (s.padding < 0 or s.gap < 0) return error.NegativeSpacing,
            .box => |bx| if (bx.padding < 0) return error.NegativeSpacing,
            .row => if (parent_role != .table) return error.RowOutsideTable,
            .cell => {
                if (parent_role != .row) return error.CellOutsideRow;
                // Layout can place `max_table_columns` columns and not
                // one more (layoutTable's per-column width table is
                // sized by it), so the cell that would open a wider
                // column cannot be built: past the cap a cell would
                // keep only a stale rect, which hit testing and
                // assistive tech would go on reading while nothing
                // draws it.
                if (self.childCount(parent) >= element_mod.max_table_columns) return error.TooManyColumns;
            },
            // A tile is the row-shaped form of `link` and `button`, and it
            // inherits the link's rule: exactly one destination. Both set
            // is not a richer row — activation takes the route and never
            // calls the press (`input.activate`), while the chevron and
            // the announced role both say link, so the press is a wire to
            // nowhere. Neither set is the same ambiguity from the other
            // side: a tab stop announced as a button
            // (`a11y/semantics.zig`) that answers no press.
            .tile => |t| {
                if (parent_role != .tile_group) return error.TileOutsideTileGroup;
                // `call`, not `ctx`: an action without a function is what
                // `Action.invoke` already treats as nothing to do.
                const pressable = t.on_press.call != null;
                if (t.route.len != 0 and pressable) return error.TileHasOneDestination;
                if (t.route.len == 0 and !pressable) return error.TileNeedsDestination;
                // A row's mark is a fixed-width leading band, so the
                // words of a group with marks all start one band in.
                // Give the band to some rows and not others and the
                // column is ragged — the words step in and out down the
                // group with nothing saying why, and the rows that
                // stepped in look subordinate to the ones that did not.
                // A `list` cannot have this bug because its markers are
                // derived; a tile group's are authored, so the check has
                // to be here. Whichever way the first row went, the rest
                // of them go.
                var sibs = self.children(parent);
                if (sibs.next()) |first| {
                    if ((self.getConst(first).?.tile.icon != null) != (t.icon != null)) {
                        return error.TileGroupMixedIcons;
                    }
                }
            },
            .list_item => if (parent_role != .list) return error.ListItemOutsideList,
            // The depth cap is a construction rule, not a rendering
            // one: past it the indent has eaten the line and says
            // nothing the words don't. Content nokre does not control
            // (parsed Markdown) flattens deeper levels onto this one
            // rather than failing, exactly as it rebases heading levels.
            .list => if (self.listDepth(parent) >= element_mod.max_list_depth) {
                return error.ListNestingTooDeep;
            },
            .nav_item, .nav_current => if (parent_role != .nav) return error.NavItemOutsideNav,
            // Not `UnlabeledInteractive` — the marker is not interactive
            // and never enters the focus order (`element.NavHere`). It
            // still may not be blank: a plate with no words is a plate
            // saying you are nowhere. The title it carries is already
            // non-empty by the time it gets here (`Router.init`), so
            // this catches a marker built by hand.
            .nav_here => |n| {
                if (parent_role != .nav) return error.NavItemOutsideNav;
                if (n.label.len == 0) return error.EmptyNavHere;
            },
            // The folded tail of a row of actions, and nothing else:
            // installed by `overflow.syncOverflowChrome` on the row that
            // overflowed, one per row. A consumer reaching for it is
            // reaching for a shape nokre chooses (element.zig).
            .more => {
                const parent_el = self.getConst(parent).?;
                if (parent_el.* != .stack or parent_el.stack.axis != .horizontal) {
                    return error.MoreOutsideButtonRow;
                }
                var it = self.children(parent);
                while (it.next()) |c| {
                    if (self.getConst(c).?.* == .more) return error.MultipleMoreControls;
                }
            },
            .nav => {
                if (!parent.eql(self.root)) return error.NavMustBeAtRoot;
                if (self.rootChild(.nav) != null) return error.MultipleNavs;
            },
            .segmented => |s| {
                if (s.options.len < 2) return error.SegmentedNeedsTwoOptions;
                for (s.options) |opt| {
                    if (opt.len == 0) return error.SegmentedEmptyOption;
                }
                if (s.selected >= s.options.len) return error.SegmentedSelectionOutOfRange;
            },
            .radio_group => |rg| {
                if (rg.options.len < 2) return error.RadioGroupNeedsTwoOptions;
                for (rg.options) |opt| {
                    if (opt.len == 0) return error.RadioGroupEmptyOption;
                }
                if (rg.selected >= rg.options.len) return error.RadioGroupSelectionOutOfRange;
            },
            .select => |s| {
                if (s.options.len < 2) return error.SelectNeedsTwoOptions;
                for (s.options) |opt| {
                    if (opt.len == 0) return error.SelectEmptyOption;
                }
                if (s.selected >= s.options.len) return error.SelectSelectionOutOfRange;
            },
            // A badge is chrome around its words; empty words leave a
            // meaningless floating border.
            .badge => |b| if (b.label.len == 0) return error.EmptyBadge,
            // A verbatim block with nothing verbatim in it is a tab
            // stop over blank space.
            .code_block => |c| if (c.content.len == 0) return error.EmptyCodeBlock,
            // The label is the document's accessible name, as a sheet's
            // title is: derived names fail on content that does not
            // open with a heading, and legal text often does not.
            .document => |d| if (d.label.len == 0) return error.UntitledDocument,
            // A copyable's value is the whole point; an empty one is a
            // control that copies nothing.
            .copyable => |c| if (c.value.len == 0) return error.EmptyCopyable,
            // A QR code's label is all assistive tech hears, and its
            // value is the whole point — neither may be empty. The value
            // must be text: an embedded NUL would silently truncate the
            // C encoder's input.
            .qr => |q| {
                if (q.label.len == 0) return error.UnlabeledQr;
                if (q.value.len == 0) return error.EmptyQr;
                if (std.mem.indexOfScalar(u8, q.value, 0) != null) return error.QrValueNotText;
            },
            // A meter's words are all assistive tech hears; a wordless
            // or out-of-range bar cannot exist.
            .meter => |m| {
                if (m.label.len == 0) return error.EmptyMeter;
                if (m.max <= 0 or m.value < 0 or m.value > m.max) return error.MeterValueOutOfRange;
            },
            .picker => |p| {
                if (p.title.len == 0) return error.UntitledPicker;
                if (!parent.eql(self.root)) return error.PickerMustBeAtRoot;
                if (self.rootChild(.picker) != null) return error.MultiplePickers;
            },
            .picker_item => {
                const ok = parent_role == .scroll_region and blk: {
                    const gp = self.node(parent).?.parent;
                    break :blk gp.isValid() and self.getConst(gp).?.role() == .picker;
                };
                if (!ok) return error.PickerItemOutsidePicker;
            },
            .sheet => |s| {
                if (s.title.len == 0) return error.UntitledSheet;
                if (!parent.eql(self.root)) return error.SheetMustBeAtRoot;
                if (self.rootChild(.sheet) != null) return error.MultipleSheets;
            },
            .sheet_close => {
                if (parent_role != .sheet) return error.SheetCloseOutsideSheet;
                var it = self.children(parent);
                while (it.next()) |c| {
                    if (self.getConst(c).?.role() == .sheet_close) return error.MultipleSheetCloses;
                }
            },
            .notice => |n| {
                if (n.title.len == 0) return error.EmptyNotice;
                // Two places, and only two: the root, where a notice is
                // the banner, and the notices pane, where it is a row.
                // The pane holds its rows in a scroll region, so that
                // region counts as the pane for this rule.
                if (!parent.eql(self.root) and !self.inNoticesPane(parent)) return error.NoticeMustBeAtRoot;
                if (parent.eql(self.root) and self.rootChild(.notice) != null) return error.MultipleNotices;
            },
            .notices_pane => {
                if (!parent.eql(self.root)) return error.NoticesPaneMustBeAtRoot;
                if (self.rootChild(.notices_pane) != null) return error.MultipleNoticesPanes;
            },
            // Chrome only: consumers compose labeled `button`s instead.
            .icon_button => switch (parent_role) {
                .notice, .notices_pane => {},
                else => if (!parent.eql(self.root)) return error.IconButtonOutsideChrome,
            },
            else => {},
        }
        if (element.ambientTextInk()) |ink| {
            try color.checkTextPair(ink, self.backgroundBehind(parent));
        }
    }

    /// Span construction rules shared by text and heading: content is
    /// append-derived so it must arrive empty; a span without words is
    /// dead weight; every run's effective ink faces the same contrast
    /// gate as plain text — a span may not smuggle in an illegible gray.
    fn validateSpans(self: *const Tree, parent: NodeId, content: []const u8, spans: []const element_mod.Span, base_ink: color.Gray) !void {
        if (spans.len == 0) return;
        if (content.len != 0) return error.ContentAlongsideSpans;
        const bg = self.backgroundBehind(parent);
        for (spans) |span| {
            if (span.text.len == 0) return error.EmptySpan;
            // A link span is a control, and every control here carries
            // a non-empty name and exactly one destination.
            // Whitespace-only words would be an invisible tab stop.
            if (span.route != null and span.external != null) return error.RouteAndExternal;
            if (span.route) |route| {
                if (route.len == 0) return error.EmptySpanRoute;
                if (std.mem.trim(u8, span.text, " \t\n\r").len == 0) return error.UnlabeledInteractive;
            }
            if (span.external) |url| {
                // open_url's closed scheme set, at construction — the
                // link element's rule, span-shaped.
                if (!open_url.schemeAllowed(url)) return error.UnsupportedScheme;
                if (std.mem.trim(u8, span.text, " \t\n\r").len == 0) return error.UnlabeledInteractive;
            }
            if (std.mem.trim(u8, span.text, " \t\n\r").len == 0) continue;
            try color.checkTextPair(span.ink orelse base_ink, bg);
        }
    }

    /// Whether `nav` is currently in its collapsed shape — holding the
    /// chip that stands in for the whole roster rather than the row.
    fn navHasCurrent(self: *const Tree, nav: NodeId) bool {
        var it = self.children(nav);
        while (it.next()) |c| {
            if (self.getConst(c).?.role() == .nav_current) return true;
        }
        return false;
    }

    fn navHasHere(self: *const Tree, nav: NodeId) bool {
        var it = self.children(nav);
        while (it.next()) |c| {
            if (self.getConst(c).?.role() == .nav_here) return true;
        }
        return false;
    }

    /// How deep `id` sits in enclosing lists, itself counted: 0 outside
    /// any list, 1 for a top-level one. `append` caps this at
    /// `element_mod.max_list_depth`; layout and the renderer read it to
    /// place markers.
    pub fn listDepth(self: *const Tree, id: NodeId) usize {
        var depth: usize = 0;
        var cur: ?NodeId = id;
        while (cur) |c| : (cur = self.parentOf(c)) {
            if (self.getConst(c).?.role() == .list) depth += 1;
        }
        return depth;
    }

    /// The block set a document container (`list_item`, `blockquote`)
    /// may hold: what Markdown's block grammar produces inside one.
    /// Headings are excluded — a heading nested in a list or a quote
    /// would claim an outline position its container cannot own — and
    /// so are tables: a grid at that depth reads as a mistake, and the
    /// Markdown parser degrades one to its literal source text rather
    /// than build it.
    fn isDocumentBlock(role: element_mod.Role) bool {
        return switch (role) {
            .text, .list, .code_block, .blockquote => true,
            else => false,
        };
    }

    /// The fill a child of `id` is drawn on: the nearest ancestor box
    /// fill (or chrome surface), or paper.
    pub fn backgroundBehind(self: *const Tree, id: NodeId) color.Gray {
        var cur = id;
        while (self.node(cur)) |n| {
            const el = n.element;
            if (el == .box) {
                if (el.box.fill) |f| return f;
            }
            if (el == .notice) return .g11;
            if (el == .sheet or el == .notices_pane or el == .picker) return .paper;
            if (!n.parent.isValid()) break;
            cur = n.parent;
        }
        return .paper;
    }

    fn allocNode(self: *Tree, element: Element) !NodeId {
        if (self.free_list.pop()) |index| {
            const n = &self.nodes.items[index];
            const gen = n.gen;
            n.* = .{ .element = element, .gen = gen, .alive = true };
            return .{ .index = index, .gen = gen };
        }
        // The top index is `invalid`'s sentinel; refusing to hand it out
        // keeps every real id distinguishable from "no node".
        if (self.nodes.items.len >= std.math.maxInt(u20)) return error.OutOfMemory;
        // Release must be infallible — `releaseSubtree` runs mid-teardown,
        // where an error could only strand slots — so the free list's room
        // for this slot is bought here, where failure still surfaces to
        // the caller. Capacity for every slot ever allocated means release
        // can always append without allocating.
        try self.free_list.ensureTotalCapacity(self.gpa, self.nodes.items.len + 1);
        const index: u20 = @intCast(self.nodes.items.len);
        try self.nodes.append(self.gpa, .{ .element = element, .alive = true });
        return .{ .index = index, .gen = 0 };
    }

    fn releaseSubtree(self: *Tree, id: NodeId) void {
        var child = self.nodePtrUnchecked(id).first_child;
        while (child.isValid()) {
            const next = self.nodePtrUnchecked(child).next_sibling;
            self.releaseSubtree(child);
            child = next;
        }
        const n = self.nodePtrUnchecked(id);
        n.alive = false;
        n.gen +%= 1;
        // Never allocates: `allocNode` reserved free-list capacity for
        // this slot when it first grew the node table, so a slot cannot
        // be stranded by an allocation failure during release.
        self.free_list.appendAssumeCapacity(id.index);
    }

    fn node(self: *const Tree, id: NodeId) ?*const Node {
        if (id.index >= self.nodes.items.len) return null;
        const n = &self.nodes.items[id.index];
        if (!n.alive or n.gen != id.gen) return null;
        return n;
    }

    fn nodePtr(self: *Tree, id: NodeId) ?*Node {
        if (id.index >= self.nodes.items.len) return null;
        const n = &self.nodes.items[id.index];
        if (!n.alive or n.gen != id.gen) return null;
        return n;
    }

    fn nodePtrUnchecked(self: *Tree, id: NodeId) *Node {
        return &self.nodes.items[id.index];
    }

    /// Copies every string an element carries into `a` — the arena on
    /// append, a fresh arena on `reclaim` — through the validating copy
    /// (`dupeValid`), so the stored tree holds only well-formed UTF-8
    /// wherever the bytes came from.
    fn dupeStringsInto(a: std.mem.Allocator, element: Element) !Element {
        var e = element;
        switch (e) {
            .text => |*t| if (t.spans.len == 0) {
                t.content = try dupeValid(a, t.content);
            } else {
                t.spans = try dupeSpans(a, t.spans, &t.content);
            },
            .heading => |*h| if (h.spans.len == 0) {
                h.content = try dupeValid(a, h.content);
            } else {
                h.spans = try dupeSpans(a, h.spans, &h.content);
            },
            .icon => |*i| i.label = try dupeValid(a, i.label),
            .code_block => |*c| c.content = try dupeValid(a, c.content),
            .document => |*d| {
                d.label = try dupeValid(a, d.label);
                d.source = try dupeValid(a, d.source);
            },
            .badge => |*b| b.label = try dupeValid(a, b.label),
            .meter => |*m| m.label = try dupeValid(a, m.label),
            .button => |*b| b.label = try dupeValid(a, b.label),
            .link => |*l| {
                l.label = try dupeValid(a, l.label);
                l.route = try dupeValid(a, l.route);
                if (l.external) |url| l.external = try dupeValid(a, url);
            },
            .toggle => |*t| t.label = try dupeValid(a, t.label),
            .checkbox => |*c| c.label = try dupeValid(a, c.label),
            .text_input => |*i| {
                i.label = try dupeValid(a, i.label);
                i.value = try dupeValid(a, i.value);
                i.placeholder = try dupeValid(a, i.placeholder);
                i.composition = try dupeValid(a, i.composition);
            },
            .text_area => |*ta| {
                ta.label = try dupeValid(a, ta.label);
                ta.value = try dupeValid(a, ta.value);
                ta.placeholder = try dupeValid(a, ta.placeholder);
                ta.composition = try dupeValid(a, ta.composition);
            },
            .segmented => |*s| {
                s.label = try dupeValid(a, s.label);
                s.options = try dupeOptions(a, s.options);
            },
            .radio_group => |*rg| {
                rg.label = try dupeValid(a, rg.label);
                rg.options = try dupeOptions(a, rg.options);
            },
            .select => |*s| {
                s.label = try dupeValid(a, s.label);
                s.options = try dupeOptions(a, s.options);
            },
            .tile_group => |*g| g.description = try dupeValid(a, g.description),
            .tile => |*t| {
                t.label = try dupeValid(a, t.label);
                t.detail = try dupeValid(a, t.detail);
                t.route = try dupeValid(a, t.route);
            },
            .copyable => |*c| {
                c.label = try dupeValid(a, c.label);
                c.value = try dupeValid(a, c.value);
            },
            .picker => |*p| p.title = try dupeValid(a, p.title),
            .picker_item => |*p| p.label = try dupeValid(a, p.label),
            .nav_item => |*n| {
                n.label = try dupeValid(a, n.label);
                n.route = try dupeValid(a, n.route);
            },
            .nav_current => |*n| n.section = try dupeValid(a, n.section),
            .nav_here => |*n| n.label = try dupeValid(a, n.label),
            .sheet => |*s| s.title = try dupeValid(a, s.title),
            .notice => |*n| {
                n.title = try dupeValid(a, n.title);
                n.description = try dupeValid(a, n.description);
                n.route = try dupeValid(a, n.route);
            },
            .icon_button => |*i| i.label = try dupeValid(a, i.label),
            .qr => |*q| {
                q.label = try dupeValid(a, q.label);
                const value = try dupeValidZ(a, q.value);
                q.value = value;
                const encoded = try qr.encode(a, value);
                q.modules = encoded.modules;
                q.size = encoded.size;
            },
            else => {},
        }
        return e;
    }

    /// The option list of a `segmented`, `radio_group`, or `select`:
    /// the slice and every string in it, into tree-owned memory.
    fn dupeOptions(a: std.mem.Allocator, options: []const []const u8) ![]const []const u8 {
        const owned = try a.alloc([]const u8, options.len);
        for (options, owned) |src, *dst| dst.* = try dupeValid(a, src);
        return owned;
    }

    /// Copies spans as slices of one contiguous buffer and hands that
    /// buffer back as the element's content: the concatenation exists
    /// once, spans are ranges over it, and byte offsets recovered from
    /// slice pointers (as layout and the renderer do) are exact. The
    /// copy validates like every other at this boundary, so a span's
    /// stored length is its sanitized length.
    fn dupeSpans(a: std.mem.Allocator, spans: []const element_mod.Span, content: *[]const u8) ![]const element_mod.Span {
        var total: usize = 0;
        for (spans) |span| total += sanitizedLen(span.text);
        const buf = try a.alloc(u8, total);
        const owned = try a.alloc(element_mod.Span, spans.len);
        var off: usize = 0;
        for (spans, owned) |src, *dst| {
            const len = sanitizedLen(src.text);
            writeSanitized(buf[off .. off + len], src.text);
            dst.* = src;
            dst.text = buf[off .. off + len];
            // A destination is its own string, not a slice of the
            // concatenation, so it needs its own copy — the tree never
            // borrows consumer memory.
            if (src.route) |route| dst.route = try dupeValid(a, route);
            if (src.external) |url| dst.external = try dupeValid(a, url);
            off += len;
        }
        content.* = buf;
        return owned;
    }

    /// The nearest codepoint boundary at or before `pos`. The stored
    /// value is valid UTF-8 by construction, so scanning back over
    /// continuation bytes always lands on a lead byte or the start.
    fn codepointFloor(bytes: []const u8, pos: usize) usize {
        var i = @min(pos, bytes.len);
        while (i > 0 and i < bytes.len and bytes[i] & 0xC0 == 0x80) i -= 1;
        return i;
    }
};

/// U+FFFD REPLACEMENT CHARACTER, what every invalid sequence becomes.
const replacement = "\u{FFFD}";

/// The validating copy at the tree's byte boundary. Consumer and
/// fetched bytes are copied into the arena anyway, so validation rides
/// the copy that already happens: invalid sequences come out as U+FFFD
/// and everything downstream can trust `utf8ByteSequenceLength` instead
/// of guarding every scan. Valid input — the overwhelmingly common case
/// — takes one scan and a plain copy.
fn dupeValid(a: std.mem.Allocator, s: []const u8) ![]u8 {
    if (std.unicode.utf8ValidateSlice(s)) return a.dupe(u8, s);
    const out = try a.alloc(u8, sanitizedLen(s));
    writeSanitized(out, s);
    return out;
}

/// `dupeValid` with the NUL sentinel the QR encoder's C API needs.
fn dupeValidZ(a: std.mem.Allocator, s: []const u8) ![:0]u8 {
    if (std.unicode.utf8ValidateSlice(s)) return a.dupeZ(u8, s);
    const out = try a.allocSentinel(u8, sanitizedLen(s), 0);
    writeSanitized(out, s);
    return out;
}

fn sanitizedLen(s: []const u8) usize {
    var n: usize = 0;
    var i: usize = 0;
    while (i < s.len) {
        const seq = sequenceAt(s, i);
        n += if (seq.valid) seq.len else replacement.len;
        i += seq.len;
    }
    return n;
}

/// Writes the sanitized form of `s` into `out`, which is exactly
/// `sanitizedLen(s)` long.
fn writeSanitized(out: []u8, s: []const u8) void {
    var o: usize = 0;
    var i: usize = 0;
    while (i < s.len) {
        const seq = sequenceAt(s, i);
        const bytes = if (seq.valid) s[i .. i + seq.len] else replacement;
        @memcpy(out[o .. o + bytes.len], bytes);
        o += bytes.len;
        i += seq.len;
    }
}

const Sequence = struct { len: usize, valid: bool };

/// One UTF-8 sequence at `i`, or the maximal subpart of an invalid one
/// (Unicode's substitution recommendation): a bad lead — or a bare
/// continuation — plus the continuation bytes that followed it, all
/// standing behind a single U+FFFD, so a truncated tail is one
/// replacement rather than one per byte.
fn sequenceAt(s: []const u8, i: usize) Sequence {
    const n = std.unicode.utf8ByteSequenceLength(s[i]) catch return .{ .len = 1, .valid = false };
    if (i + n <= s.len and std.unicode.utf8ValidateSlice(s[i .. i + n])) return .{ .len = n, .valid = true };
    var j = i + 1;
    while (j < s.len and j - i < n and s[j] & 0xC0 == 0x80) j += 1;
    return .{ .len = j - i, .valid = false };
}
