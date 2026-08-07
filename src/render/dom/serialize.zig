//! The DOM edition's `drawNode`: one case per element, writing markup
//! where the Skia edition writes draw calls.
//!
//! The walk is [renderer.zig](../renderer.zig)'s walk. What differs is
//! the vocabulary it lands in — a browser's, which already knows what a
//! heading, a list, a table and a switch are, and already exposes each
//! to assistive tech. That is the whole argument for the edition: on
//! this platform the accessibility tree is not a mirror of the pixels,
//! it *is* the thing the pixels come from, which is what
//! [../../../docs/introduction.md](../../../docs/introduction.md) claims
//! every nokre platform does and only this one gets for free.
//!
//! Roles come from `a11y/semantics.zig`'s `roleOf`, not from a second
//! table here: an element whose HTML tag already carries the right
//! implicit role gets no ARIA, and everything else states the role the
//! snapshot would have stated. The two editions cannot disagree about
//! what an element *is*, because they ask the same function.
//!
//! Layout is computed and then ignored. Geometry stays in core — the
//! rects still feed hit testing, focus and a11y bounds — but this
//! edition's freedom is inside each element's box, and inside the box a
//! browser wraps the line. Pixel determinism is the Skia edition's
//! promise; this one's is the semantics
//! ([renderer-editions.md](../../../docs/internals/renderer-editions.md)).

const std = @import("std");

const app_mod = @import("../../core/app.zig");
const class_names = @import("class_names.zig");
const color = @import("../../core/color.zig");
const element_mod = @import("../../core/element.zig");
const layout = @import("../../core/layout.zig");
const wrap = @import("../../core/wrap.zig");
const nav_mod = @import("../../core/nav.zig");
const semantics = @import("../../a11y/semantics.zig");
const text_mod = @import("../../core/text.zig");
const tree_mod = @import("../../core/tree.zig");

const App = app_mod.App;
const Element = element_mod.Element;
const Gray = color.Gray;
const IconName = element_mod.IconName;
const NodeId = tree_mod.NodeId;
const Scale = text_mod.Scale;

/// How a route reference becomes an `href`.
///
/// The hook answers *where the route lives* — a destination, never
/// bytes. The emitter owns the whole attribute in both forms, so a
/// driver can never hold a half-open quote: closing `href="` by hand
/// to smuggle attributes in was the sharpest bypass any consumer had,
/// and this shape is what removes it. An `internal` destination is a
/// plain `href`; an `external` one takes the same new-tab posture
/// every external anchor here takes (`hrefExternal`).
///
/// The default is the fragment the web shell already mirrors routes
/// into (`#note~42`), so a link in a serialized page and a link in a
/// running app point at the same screen. A driver that publishes one
/// file per screen — a static site — installs its own.
///
/// `ctx` + function pointer, like every other action in nokre: no
/// closure is allocated, ever. The emitter is passed for its state —
/// the app a resolver may read the current route off, the allocator,
/// and the scratch below — never for its output: a hook that writes
/// `em.out` is re-opening the door this signature closed.
pub const Refs = struct {
    ctx: ?*anyopaque = null,
    resolve: *const fn (ctx: ?*anyopaque, em: *Emitter, route: []const u8) anyerror!Dest = fragment,

    pub fn fragment(_: ?*anyopaque, em: *Emitter, route: []const u8) anyerror!Dest {
        // The one-byte prefix needs a home that outlives this call, and
        // the emitter's ref scratch is that home: retained capacity
        // keeps the steady state allocation-free, where a heap string
        // per href under the live driver would be a leak with a
        // scroll bar.
        em.ref_buf.clearRetainingCapacity();
        try em.ref_buf.append(em.gpa, '#');
        try em.ref_buf.appendSlice(em.gpa, route);
        return .{ .internal = em.ref_buf.items };
    }
};

/// Where a route reference points, as the `Refs` hook answers it. The
/// slice is borrowed until the attribute is written — a resolver's own
/// arena, or the emitter's `ref_buf`, both hold exactly long enough.
pub const Dest = union(enum) {
    /// A destination on this app or site: a plain `href`, through the
    /// one attribute escape.
    internal: []const u8,
    /// A destination that leaves it: written with the new-tab pair
    /// every external anchor carries (`hrefExternal` says why).
    external: []const u8,
};

pub const Emitter = struct {
    /// The emitter's own knobs, scoped here because "Options" alone is
    /// ambiguous at the edition's surface: the stylesheet has options
    /// too, and each set belongs to the thing it configures.
    pub const Options = struct {
        refs: Refs = .{},
        /// Give every heading an `id` **derived** from its words, so a
        /// section can be linked to. Ids only — never an anchor control
        /// beside the heading: a control the tree does not have is a
        /// control assistive tech hears that the app never wrote, and the
        /// set is closed here too.
        ///
        /// It governs the derivation and nothing else. A heading that
        /// *states* its address (`element.Heading.anchor`) writes it
        /// either way and joins the roster either way: turning off a
        /// guess the library was making cannot be the same act as
        /// dropping a destination the driver stated.
        heading_ids: bool = true,
        /// Write each focus stop's `NodeId` as `data-n`, so a driver that
        /// resolves hits itself can name the node the reader meant. The
        /// live driver needs it; a page written to a file has nobody to
        /// tell, and leaves it off (live.zig).
        node_ids: bool = false,
    };

    gpa: std.mem.Allocator,
    app: *App,
    out: *std.ArrayList(u8),
    options: Options = .{},

    /// Heading ids already emitted on this document — derived and
    /// stated alike — for the numeric suffix a repeat takes and the
    /// collision a stated one is refused for.
    ids: std.ArrayList([]const u8) = .empty,

    /// Scratch for a `Refs` hook that has to assemble its answer — the
    /// default fragment's `#` prefix. A hook that uses it clears it
    /// first; the slice it returns is read before the next resolve, so
    /// one buffer is enough and its capacity is reused frame after
    /// frame.
    ref_buf: std.ArrayList(u8) = .empty,

    pub fn deinit(self: *Emitter) void {
        for (self.ids.items) |id| self.gpa.free(id);
        self.ids.deinit(self.gpa);
        self.ref_buf.deinit(self.gpa);
    }

    /// The heading ids this document exported, in the order they were
    /// minted — the sanctioned answer to "what can another page's
    /// `#anchor` name". `ids` above is bookkeeping for the numeric
    /// suffix a repeated heading takes; this is the same list read as a
    /// *fact about the document*, which is a question a documents-mode
    /// edition has (docs/internals/dom-edition.md) and an app-in-a-page
    /// does not.
    ///
    /// One roster, both origins: a stated anchor is in here beside the
    /// derived ones, because a reference gate that only saw the guesses
    /// would fail exactly the addresses a driver cared enough to write
    /// down.
    ///
    /// Ownership transfers: the strings are copied into `gpa` and the
    /// emitter's own roster comes back empty, so `deinit` frees nothing
    /// here and the caller frees everything. Copied rather than handed
    /// over because a caller keeping anchors past the emitter is by
    /// definition a caller whose allocator outlives the emitter's.
    ///
    /// Call it once, when the document is finished: the roster is also
    /// the dedup bookkeeping, so an emitter that keeps writing past this
    /// can mint an id it already used.
    pub fn takeAnchors(self: *Emitter, gpa: std.mem.Allocator) ![]const []const u8 {
        const out = try gpa.alloc([]const u8, self.ids.items.len);
        errdefer gpa.free(out);
        var copied: usize = 0;
        errdefer for (out[0..copied]) |s| gpa.free(s);
        for (self.ids.items) |id| {
            out[copied] = try gpa.dupe(u8, id);
            copied += 1;
        }
        for (self.ids.items) |id| self.gpa.free(id);
        self.ids.clearAndFree(self.gpa);
        return out;
    }

    /// A second emitter over a buffer of the caller's own.
    ///
    /// This is how a driver builds the bytes the document's seams take
    /// (`document.zig`'s `Document.head` and `body_end`) with the same
    /// escape the document itself gets. Those seams are *bytes* rather
    /// than a `fn (em)` hook on purpose — a hook writing `em.out` is the
    /// door `Refs`'s signature closed — so the driver needs somewhere
    /// else to write, and this is it: same app, same allocator, a
    /// different `out`.
    ///
    /// It carries the options along, so a fragment resolves references
    /// the way the document does. What it does not carry is the heading
    /// roster: ids are deduplicated per emitter, so a fragment that
    /// emitted headings would mint ids the document does not know about
    /// and `takeAnchors` would not report. Fragments are for the markup
    /// around the screen, which has none.
    pub fn fragment(self: *const Emitter, out: *std.ArrayList(u8)) Emitter {
        return .{ .gpa = self.gpa, .app = self.app, .out = out, .options = self.options };
    }

    pub fn raw(self: *Emitter, s: []const u8) !void {
        try self.out.appendSlice(self.gpa, s);
    }

    pub fn print(self: *Emitter, comptime fmt: []const u8, args: anytype) !void {
        try self.out.print(self.gpa, fmt, args);
    }

    /// Text for a text node or a quoted attribute. One escape for both:
    /// the set is small, and two of them would be one more place to
    /// forget `&`.
    pub fn text(self: *Emitter, s: []const u8) !void {
        for (s) |c| switch (c) {
            '&' => try self.raw("&amp;"),
            '<' => try self.raw("&lt;"),
            '>' => try self.raw("&gt;"),
            '"' => try self.raw("&quot;"),
            '\'' => try self.raw("&#39;"),
            else => try self.out.append(self.gpa, c),
        };
    }

    /// A JSON document the caller already serialized, on its way into a
    /// `<script>` block — the one escape that destination needs and the
    /// only place in this type where `text` above would be actively
    /// wrong rather than merely redundant.
    ///
    /// `std.json` escapes JSON, which is a different question:
    /// `</script>` is legal JSON and fatal inside a `<script>`. And a
    /// script block's contents are **raw text**, so `&amp;` written into
    /// one is five characters of nothing rather than an ampersand —
    /// which is exactly why the markup escape cannot stand in here.
    ///
    /// **One byte, and it is the whole set.** A script block's data
    /// state is left on `<` and on nothing else, so every way out of it
    /// starts with one: `</script` ends the element; `<!--` opens the
    /// escaped state, in which a later `</script>` no longer does —
    /// which is how two innocent strings on one page combine to swallow
    /// the rest of the document — and `<script` inside that opens the
    /// double-escaped one. Escaping `<` closes all three, the way
    /// document.zig's `js` does for the boot script. The escape it
    /// takes is spelled `\u003C` here and `\x3C` there, because JSON
    /// has no `\x` escape at all: that one difference is why these are
    /// two functions and not one, however alike their argument reads.
    ///
    /// **What is deliberately left alone.** `&`, because raw text
    /// decodes no character reference and an escape written where none
    /// is needed is a false claim about where the bytes are going.
    /// U+2028 and U+2029, because what they break is *JavaScript
    /// source* (and only before ES2019); a block whose type is not a
    /// script type is never parsed as source, and in JSON they are
    /// ordinary characters inside a string.
    ///
    /// **Valid JSON carries no `<` outside a string literal** — its
    /// structure is braces, brackets, commas, colons and literals — and
    /// no continuation byte of a UTF-8 sequence can be `0x3C` either. So
    /// a byte-wise pass over the finished document is the whole
    /// transformation, and what comes out parses to the value that went
    /// in.
    ///
    /// Serializing the value is not this function's business.
    /// `std.json.Stringify` writes the document; whether the graph in it
    /// is a FAQPage or a product listing is the site's content, and this
    /// library has no opinion about either.
    pub fn json(self: *Emitter, doc: []const u8) !void {
        var rest = doc;
        while (std.mem.indexOfScalar(u8, rest, '<')) |i| {
            try self.raw(rest[0..i]);
            try self.raw("\\u003C");
            rest = rest[i + 1 ..];
        }
        try self.raw(rest);
    }

    /// The node a focus stop belongs to, for a driver that answers
    /// "which element did the user mean" on its own.
    fn stop(self: *Emitter, id: NodeId) !void {
        if (!self.options.node_ids) return;
        try self.print(" data-n=\"{d}\"", .{@as(u32, @bitCast(id))});
    }

    /// The route's `href`, in whichever of the two forms `Refs`
    /// resolved it to. Both attributes are written here in full —
    /// opening quote, closing quote, and the external posture — so no
    /// consumer ever writes a byte of one.
    fn href(self: *Emitter, route: []const u8) !void {
        const refs = self.options.refs;
        switch (try refs.resolve(refs.ctx, self, route)) {
            .internal => |url| {
                try self.raw(" href=\"");
                try self.text(url);
                try self.raw("\"");
            },
            .external => |url| try self.hrefExternal(url),
        }
    }

    /// The external twin of `href`: the URL verbatim (through the one
    /// attribute escape — the allowlist already excludes `javascript:`
    /// and friends, so escaping is about markup, not schemes), never
    /// through `Refs`, which maps route references and nothing else —
    /// though a route `Refs` resolved to an `external` destination
    /// lands here too: same posture, one writer.
    /// `target="_blank"` because same-tab would tear down the running
    /// app under the live driver and lose a static page's reader their
    /// place; `noopener noreferrer` severs the handle the new page
    /// would otherwise hold on this window.
    fn hrefExternal(self: *Emitter, url: []const u8) !void {
        try self.raw(" href=\"");
        try self.text(url);
        try self.raw("\" target=\"_blank\" rel=\"noopener noreferrer\"");
    }
};

// ---------------------------------------------------------------- entry

/// The class list for the element a driver wraps `content` in — the
/// whole attribute value, not the names to build one from.
///
/// The stylesheet hangs the root stack's padding, gap and bottom-chrome
/// reserve off these classes, so a wrapper that carries the wrong list
/// is a screen drawn with none of them. The reserve half is conditional
/// and the condition is *layout's*, not the page's: whether a screen
/// owes the clear space bottom chrome stands in is
/// `layout.hasBottomChrome`, the one predicate the reference edition
/// asks to reserve the trailing band and the live driver asks to toggle
/// the same class — so a driver reads the answer here rather than
/// deciding it, and the three cannot drift.
///
/// A driver's own classes go beside it: `class="{s} page"` is the
/// intended shape (class_names.zig).
pub fn rootClass(em: *const Emitter) []const u8 {
    if (layout.hasBottomChrome(&em.app.tree)) return class_names.root ++ " " ++ class_names.has_chrome;
    return class_names.root;
}

/// The screen: every root child that is not framework chrome.
///
/// A driver wraps this in whatever the page needs and puts `rootClass`
/// on that wrapper.
pub fn content(em: *Emitter) !void {
    const tree = &em.app.tree;
    var it = tree.children(tree.rootId());
    while (it.next()) |id| {
        const el = tree.getConst(id) orelse continue;
        if (el.role().isChromeLayer()) continue;
        try node(em, id);
    }
}

/// The layers the framework installs, in paint order: the notice banner
/// and the nav stand on the page, the modal layers go over it. Emitted
/// after the content so the modal ones need no stacking games — and so
/// the nav, which leads the focus order, is where a driver can put it
/// first if it wants to.
pub fn chrome(em: *Emitter) !void {
    const tree = &em.app.tree;
    // The banner owns the bottom pane; the nav is hidden and inert
    // until the notices minimize. Layout says so by zeroing every nav
    // rect (`layoutNavChrome`) and the reference by branching on it
    // (`render`) — this edition reads no rects, so the branch is the
    // only place it can say the same thing. Two bottom bars, one
    // stacked on the other, is what leaving it out looked like.
    const banner = layout.findNotice(tree);
    if (banner) |id| try node(em, id);
    if (banner == null) {
        if (layout.findNav(tree)) |id| try node(em, id);
        // Standing alone the indicator is a layer of its own, centred as
        // the bar's only content. Where the bar has a group — a row of
        // destinations or the collapsed chip — it is not: that row
        // emitted it (`node`), because there it is measured and centred
        // with what it stands beside.
        if (layout.findIndicator(tree)) |id| {
            if (!layout.indicatorRidesNavGroup(tree)) {
                try em.raw("<div class=\"nav-indicator\">");
                try node(em, id);
                try em.raw("</div>");
            }
        }
    }
    // The modal layers, bottom of the stack first, so the markup order
    // is the paint order — the reverse of `layout.topModalLayer`'s
    // precedence, which is the same fact read from the other end.
    if (layout.findNoticesPane(tree)) |id| try node(em, id);
    if (layout.findSheet(tree)) |id| try node(em, id);
    if (layout.findPicker(tree)) |id| try node(em, id);
}

// ----------------------------------------------------------------- walk

/// One element, then its children. The switch is exhaustive with no
/// `else`: an element added to the set without a case here does not
/// render as a `<div>`, it fails to compile — which is the same
/// discipline that keeps the set closed in the first place.
pub fn node(em: *Emitter, id: NodeId) anyerror!void {
    const tree = &em.app.tree;
    const el = tree.getConst(id) orelse return;
    switch (el.*) {

        // ---- static ----

        .text => |t| {
            try em.raw("<p");
            try textClass(em, t.style, "");
            try em.raw(">");
            try inlines(em, id, t.content, t.spans);
            try em.raw("</p>");
        },
        .heading => |h| {
            const level = @intFromEnum(h.level);
            try em.print("<h{d}", .{level});
            if (h.anchor.len != 0 or em.options.heading_ids) {
                try em.raw(" id=\"");
                try em.text(try headingId(em, h.anchor, h.content));
                try em.raw("\"");
            }
            try em.raw(">");
            try inlines(em, id, h.content, h.spans);
            try em.print("</h{d}>", .{level});
        },
        .icon => |i| try icon(em, i.name, i.label, i.ink, i.scale, .square),
        .divider => try em.raw("<hr>"),
        .badge => |b| {
            try em.raw("<span class=\"badge\">");
            // A `mark`, not the `square` a tile's leading glyph takes: a
            // chip hugs its content, so it is charged the glyph's own
            // advance and the chip's flex `gap` (`badgeIconWidth`).
            if (b.icon) |name| try icon(em, name, "", .ink, .small, .mark);
            try em.text(b.label);
            try em.raw("</span>");
        },
        .meter => |m| {
            // The words carry the state; the bar only restates it, so
            // the bar is hidden and the label is what is announced.
            // The share as a ratio rather than a rounded percentage:
            // `drawMeter` fills `inner_w * value / max` of the track, so
            // the division happens against the real width here too
            // instead of against a truncated hundredth of it.
            const value: i64 = if (m.max <= 0 or m.value <= 0) 0 else @min(m.value, m.max);
            const max: i64 = if (m.max <= 0) 1 else m.max;
            try em.raw("<div class=\"meter\"><p class=\"field-label\">");
            try em.text(m.label);
            try em.print("</p><div class=\"meter-track\" aria-hidden=\"true\">" ++
                "<div class=\"meter-fill\" style=\"width:calc(100% * {d} / {d})\"></div></div></div>", .{ value, max });
        },
        .qr => |q| try qr(em, id, q),

        // ---- containers ----

        .stack => |s| {
            const row = s.axis == .horizontal;
            // A vertical stack that pads nothing does not own the row's
            // first line — the block inside it does — so a back control
            // beside it hands the pairing down (`handsDownBack`). The
            // class is that predicate, said once here rather than
            // guessed at from a selector.
            const hands_back = !row and s.padding == 0;
            // And the predicate no selector could answer either: which of
            // the two things this row does when it runs out of line.
            // `layout.rowOverflow` is the one place that decides, so the
            // browser wraps exactly the rows core wraps.
            const wraps = row and layout.rowOverflow(&em.app.tree, id) == .wrap;
            try em.print("<div class=\"stack{s}{s}{s}\"", .{
                if (row) " row" else "",
                if (wraps) " wrap" else "",
                if (hands_back) " hands-back" else "",
            });
            const d: element_mod.Stack = .{};
            try boxStyle(em, .{ .value = s.gap, .default = d.gap }, .{ .value = s.padding, .default = d.padding }, null);
            try em.raw(">");
            try children(em, id);
            try em.raw("</div>");
        },
        .box => |b| {
            try em.print("<div class=\"box{s}\"", .{if (b.border) "" else " bare"});
            const d: element_mod.Box = .{};
            try boxStyle(em, null, .{ .value = b.padding, .default = d.padding }, b.fill);
            try em.raw(">");
            try children(em, id);
            try em.raw("</div>");
        },
        .scroll_region => |r| {
            try em.raw("<div class=\"scroll\" tabindex=\"0\"");
            try em.stop(id);
            if (r.height) |h| try em.print(" style=\"height:{d}px\"", .{h});
            try em.raw(">");
            try children(em, id);
            try em.raw("</div>");
        },
        .document => |d| {
            // The role the snapshot gives it: a landmark named by its
            // label. Its Markdown expanded into ordinary children at
            // `append`, so there is nothing of its own to draw.
            try em.raw("<div class=\"document\" role=\"document\" aria-label=\"");
            try em.text(d.label);
            try em.raw("\">");
            try children(em, id);
            try em.raw("</div>");
        },

        // ---- prose blocks ----

        .list => |l| {
            // The leading band the items reserve for their markers is a
            // *measured* width — the widest marker in the list plus the
            // gap after it — so no constant in the stylesheet can stand
            // in for it and layout's own answer is written on instead.
            // Uniform across the list, exactly as `listGutter` is, so
            // item words align down one column however the ordinals
            // grow.
            const gutter = layout.listGutter(em.app.measurer, tree, id);
            if (l.ordered) {
                try em.print("<ol class=\"list\" start=\"{d}\" style=\"--list-gutter:{d}px\">", .{ l.start, gutter });
            } else {
                try em.print("<ul class=\"list\" style=\"--list-gutter:{d}px\">", .{gutter});
            }
            try children(em, id);
            try em.raw(if (l.ordered) "</ol>" else "</ul>");
        },
        .list_item => {
            // The marker is derived from the list and the position, and
            // `<li>` derives its own the same way — so nokre's never
            // reaches the markup, and assistive tech announces exactly
            // one.
            try em.raw("<li>");
            try children(em, id);
            try em.raw("</li>");
        },
        .code_block => |c| {
            // Focusable because it scrolls: ←/→ walk it in the Skia
            // edition, and a scroll container that no key reaches is a
            // pane a keyboard user cannot read (WCAG 2.1.1).
            try em.raw("<pre class=\"code\" tabindex=\"0\"");
            try em.stop(id);
            // How far the block may reach past its column before it
            // meets a drawn edge. Layout accumulated it (`Ctx.margin`)
            // and wrote the answer on the element: zero for a block that
            // fits, the whole advice for one that overflows and bleeds.
            if (c.bleed != 0) try em.print(" style=\"--bleed:{d}px\"", .{c.bleed});
            try em.raw("><code>");
            try em.text(c.content);
            try em.raw("</code></pre>");
        },
        .blockquote => {
            try em.raw("<blockquote>");
            try children(em, id);
            try em.raw("</blockquote>");
        },
        .table => {
            try em.raw("<div class=\"table-wrap\"><table>");
            try children(em, id);
            try em.raw("</table></div>");
        },
        .row => |r| {
            try em.print("<tr{s}>", .{if (r.header) " class=\"header\"" else ""});
            try children(em, id);
            try em.raw("</tr>");
        },
        .cell => {
            const header = blk: {
                const parent = tree.parentOf(id) orelse break :blk false;
                const pe = tree.getConst(parent) orelse break :blk false;
                break :blk pe.role() == .row and pe.row.header;
            };
            try em.raw(if (header) "<th>" else "<td>");
            try children(em, id);
            try em.raw(if (header) "</th>" else "</td>");
        },

        // ---- controls ----

        .button => |b| try button(em, id, b),
        .link => |l| {
            if (l.folded) return;
            // `block`, because a `link` element is not a run inside a
            // paragraph: it is a line of its own with the rule on a
            // pixel `intrinsicSize` reserved for it, and a span's
            // browser-drawn underline lands wherever the face's own
            // metric says instead.
            try em.raw("<a class=\"link block\"");
            if (l.external) |url| try em.hrefExternal(url) else try em.href(l.route);
            try em.stop(id);
            try em.raw(">");
            try em.text(l.label);
            try em.raw("</a>");
        },
        // The row is the control: the box and its words are one target,
        // and the press resolves on the label around them. Resolving it
        // on the box alone would reach this driver only *after* the
        // browser had acted on the label — and cancelling that late
        // reverts it, leaving the control showing one state while the
        // tree holds the other.
        .toggle => |t| try switchRow(em, id, "toggle", t.label, .{ .on = t.on, .busy = t.in_progress }),
        .checkbox => |c| try switchRow(em, id, "check", c.label, .{ .on = c.checked, .busy = c.in_progress }),
        .text_input => |t| {
            try fieldOpen(em, t.problem);
            try em.raw("<label class=\"field\"><span class=\"field-label\">");
            try em.text(t.label);
            try em.print("</span><span class=\"field-box\"><input type=\"{s}\" value=\"", .{
                if (t.obscured) "password" else "text",
            });
            try em.text(t.value);
            try em.raw("\" placeholder=\"");
            try em.text(t.placeholder);
            try em.raw("\"");
            try fieldDisabled(em, t.disabled);
            try fieldProblemRef(em, id, t.problem);
            try em.stop(id);
            try em.raw("></span></label>");
            try fieldClose(em, id, t.problem);
        },
        .text_area => |t| {
            try fieldOpen(em, t.problem);
            try em.raw("<label class=\"field\"><span class=\"field-label\">");
            try em.text(t.label);
            try em.print("</span><span class=\"field-box\"><textarea rows=\"{d}\" placeholder=\"", .{
                layout.metrics.text_area_min_rows,
            });
            try em.text(t.placeholder);
            try em.raw("\"");
            try fieldDisabled(em, t.disabled);
            try fieldProblemRef(em, id, t.problem);
            try em.stop(id);
            try em.raw(">");
            // The HTML parser drops one newline immediately after the
            // <textarea> tag, so a value that starts with one needs a
            // sacrificial extra or it round-trips shorter than it is.
            if (std.mem.startsWith(u8, t.value, "\n")) try em.raw("\n");
            try em.text(t.value);
            try em.raw("</textarea></span></label>");
            try fieldClose(em, id, t.problem);
        },
        .select => |s| {
            // Not a `<select>`. A native one opens the platform's own
            // list, and this element's whole contract is that pressing
            // it opens *nokre's* picker — so a real dropdown would flash
            // its own list on the way to being replaced, and would be a
            // second exclusive-choice UI the tree does not know about.
            //
            // The snapshot already says what it is: `combo_box`, the
            // same role the collapsed nav's chip takes. So it is drawn
            // the way that one is — a control that opens a list and
            // takes a choice, naming the field and announcing the
            // current option as its value.
            const owned = if (em.app.picker_owner) |o| o.eql(id) else false;
            try em.print("<div class=\"field\"><span class=\"field-label\" id=\"field-{d}\">", .{@as(u32, @bitCast(id))});
            try em.text(s.label);
            try em.print("</span><button type=\"button\" class=\"field-box select\" role=\"combobox\"" ++
                " aria-haspopup=\"listbox\" aria-expanded=\"{s}\" aria-labelledby=\"field-{d}\"", .{
                if (owned) "true" else "false",
                @as(u32, @bitCast(id)),
            });
            if (owned) try em.raw(" aria-controls=\"nokre-listbox\"");
            try em.stop(id);
            try em.raw("><span class=\"field-value\">");
            if (s.selected < s.options.len) try em.text(s.options[s.selected]);
            try em.raw("</span>");
            try icon(em, .chevron_down, "", .ink, .body, .mark);
            try em.raw("</button></div>");
        },
        // A column of rows has no track to overflow, so it never bleeds.
        .radio_group => |g| try choice(em, id, "radios", g.label, g.options, g.selected, .rows, 0),
        .segmented => |s| try choice(em, id, "segmented", s.label, s.options, s.selected, .chips, s.bleed),
        .copyable => |c| {
            // Activation is intrinsic — it writes the value to the
            // platform clipboard — so it is a button named by its label,
            // carrying the value. Assistive tech reads both.
            //
            // And the acknowledgement: a copy leaves the screen
            // identical, so without a mark the press looks inert. The
            // affordance stands in as a check while this field holds
            // it, until the next input takes it back (`App.ack`) — a
            // latch rather than a timer, because clearing it "after a
            // moment" wants a wall clock core will not have.
            const acked = if (em.app.ack) |a| a.eql(id) else false;
            try em.raw("<div class=\"field\"><span class=\"field-label\">");
            try em.text(c.label);
            try em.raw("</span><button type=\"button\" class=\"field-box copyable\"");
            try em.stop(id);
            try em.raw("><code>");
            try em.text(c.value);
            try em.print("</code><span class=\"icon{s}\" aria-hidden=\"true\">&#x{X};</span></button></div>", .{
                if (acked) "" else " mid",
                try std.unicode.utf8Decode(if (acked) element_mod.copy_check else element_mod.copy_glyph),
            });
        },
        .tile_group => |g| {
            // The caption hangs below the border at the labeled-field
            // gap (`tileGroupDescHeight` spends `input_label_gap` on
            // it), which is not the page's flow gap — so the card and
            // its caption are wrapped and spaced together rather than
            // left to the stack that holds them.
            const captioned = g.description.len != 0;
            if (captioned) try em.raw("<div class=\"tile-group\">");
            try em.raw("<div class=\"tiles\">");
            try children(em, id);
            try em.raw("</div>");
            if (captioned) {
                try em.raw("<p class=\"tiles-desc\">");
                try em.text(g.description);
                try em.raw("</p></div>");
            }
        },
        .tile => |t| try tile(em, id, t),
        .more => |m| {
            // Drawn *as* one of the buttons it stands among — the same
            // outlined pill, leading an ellipsis — so the row keeps
            // reading as one row.
            try em.raw("<button type=\"button\" class=\"btn secondary more\"");
            try em.stop(id);
            try em.raw(">");
            try icon(em, .ellipsis, "", .ink, .body, .mark);
            try em.text(m.label);
            try em.raw("</button>");
        },

        // ---- navigation chrome ----

        .nav => {
            // The landmark's name is the framework's, in the app's
            // language: the same word the collapsed chip's picker is
            // titled with, because it names the same set.
            //
            // One class and no modifier. Which shape this wears is the
            // reader's window's, decided by the sheet over these same
            // bytes, and nothing about the file it was served in is a
            // term in that question — not who wrote it, not whether
            // anything will mount over it. The band that a modifier once
            // held such a page out of has an answer for a row that will
            // not fit which needs nobody running (stylesheet.zig).
            try em.print("<nav class=\"nav\" aria-label=\"{s}\"><div class=\"nav-row\">", .{
                em.app.chrome.sections,
            });
            try children(em, id);
            // The indicator is one more thing standing in the bar's
            // group, not a layer beside it: `layoutNavChrome` counts its
            // square and the gap before it into the group's width, and
            // centres *that* on the viewport. So it is emitted here,
            // inside the flex row the browser centres, rather than
            // pinned to an edge — which is an edge the destinations know
            // nothing about, so the two drifted apart the wider the
            // window got.
            if (layout.indicatorRidesNavGroup(tree)) {
                if (layout.findIndicator(tree)) |ind| try node(em, ind);
            }
            try em.raw("</div></nav>");
        },
        .nav_item => |n| {
            const current = nav_mod.isCurrent(em.app, n.route);
            try em.print("<a class=\"chip{s}\"", .{if (current) " current" else ""});
            try em.href(n.route);
            if (current) try em.raw(" aria-current=\"page\"");
            try em.stop(id);
            try em.raw(">");
            // Absent on an unmarked roster, and absent whole: no glyph
            // and no empty span standing in for one, so `.chip`'s flex
            // gap has nothing left to hold apart. The reference draws
            // the same nothing (`renderer.drawNavGroup`).
            if (n.icon) |mark| try icon(em, mark, "", if (current) .ink else .dark, .body, .mark);
            try em.text(n.label);
            try em.raw("</a>");
        },
        .nav_current => |n| {
            // A combo box, not a link: it opens a list and takes a
            // choice. Its accessible name stays the framework's word for
            // the control and the current section is its *value*, so the
            // control a screen-reader user looks for does not rename
            // itself every time it is used.
            const open = if (em.app.picker_owner) |o| o.eql(id) else false;
            try em.print("<button type=\"button\" class=\"chip current\" role=\"combobox\"" ++
                " aria-haspopup=\"listbox\" aria-expanded=\"{s}\"{s}", .{
                if (open) "true" else "false",
                if (open) " aria-controls=\"nokre-listbox\"" else "",
            });
            try em.stop(id);
            // Name from the element's own field (`App.Chrome.section`,
            // copied in at construction) — the string `label()` hands
            // the native a11y tree, so both editions say this control's
            // name in one language. The colon joins a name to its value
            // and is punctuation, not a word: keeping it out of the
            // catalog spares every locale a re-typed separator.
            try em.raw("><span class=\"visually-hidden\">");
            try em.text(n.name);
            try em.raw(": </span>");
            if (n.icon) |mark| try icon(em, mark, "", .ink, .body, .mark);
            try em.text(n.section);
            // The chevron is not the roster's mark and does not follow
            // it: it says a list opens above, which is true of the
            // control whatever the destinations wear.
            try icon(em, .chevron_up, "", .ink, .body, .mark);
            try em.raw("</button>");
        },
        .nav_here => |n| {
            // A label, not a destination: it goes where you already are,
            // takes no focus, and answers no press.
            try em.raw("<span class=\"chip current here\"><span class=\"visually-hidden\">");
            try em.text(n.name);
            try em.raw(": </span>");
            if (n.icon) |mark| try icon(em, mark, "", .ink, .body, .mark);
            try em.text(n.value);
            try em.raw("</span>");
        },
        .back => |b| {
            // Nothing draws this word, so the attribute is the only
            // place it reaches anyone — and it is the element's own
            // (`App.Chrome.back`), the string `label()` gives the
            // native tree.
            try em.raw("<button type=\"button\" class=\"icon-button back\" aria-label=\"");
            try em.text(b.label);
            try em.raw("\"");
            try em.stop(id);
            try em.raw(">");
            // Back points along the reading direction, so a mirrored
            // chrome flips it — the reference's `back_chevron` /
            // `back_chevron_rtl` pair.
            const mark: IconName = if (em.app.direction == .rtl) .chevron_right else .chevron_left;
            try icon(em, mark, "", .ink, .body, .mark);
            try em.raw("</button>");
        },

        // ---- layers ----

        .sheet => |s| {
            // While one is open the rest of the tree is inert: focus,
            // taps and scrolling stay inside. `aria-modal` is how that
            // is said here; the scrim is the same statement in pixels.
            try modalSurface(em, id, "sheet", s.title);
            try children(em, id);
            try em.raw("</div>");
        },
        .sheet_close => |c| {
            try em.raw("<button type=\"button\" class=\"icon-button sheet-close\" aria-label=\"");
            try em.text(c.label);
            try em.raw("\"");
            try em.stop(id);
            try em.raw(">");
            try glyph(em, .dismiss);
            try em.raw("</button>");
        },
        .notice => |n| {
            // A polite live region: notices persist, never auto-dismiss
            // (WCAG 2.2.1) and never steal focus (WCAG 3.2.1).
            try em.raw("<div class=\"notice\" role=\"status\">");
            // The flanks, in the order `layoutNoticeRow` places them:
            // the open/expand control leads, the words hold the column,
            // and the trailing pair stacks outermost-last — minimize,
            // then dismiss at the far edge. Document order *is* the
            // visual order here, so a control emitted after the words
            // is a control drawn after them.
            try noticeControls(em, id, .lead);
            // A `square` box like the standalone icon element's, not a
            // mark: layout charged the words' column a `lineHeight` box
            // plus a gap (`noticeTextBand`), and the flex gap is that
            // gap. Decorative — the title is the accessible name.
            if (n.icon) |name| try icon(em, name, "", .ink, .body, .square);
            try em.raw("<div class=\"notice-words\"><p class=\"notice-title\">");
            try em.text(n.title);
            try em.raw("</p>");
            if (n.description.len != 0) {
                try em.raw("<p class=\"notice-desc\">");
                try em.text(n.description);
                try em.raw("</p>");
            }
            try em.raw("</div>");
            try noticeControls(em, id, .trail);
            try em.raw("</div>");
        },
        .notices_pane => |p| {
            // The framework's own word for it, in the app's language
            // (`App.Chrome.notices`) — carried on the node, so the
            // reference and this edition name the pane from one place.
            try modalSurface(em, id, "notices-pane", p.title);
            try children(em, id);
            try em.raw("</div>");
        },
        .icon_button => |b| {
            try em.raw("<button type=\"button\" class=\"icon-button\" aria-label=\"");
            try em.text(b.label);
            try em.raw("\"");
            try em.stop(id);
            try em.raw(">");
            try glyph(em, b.glyph);
            try em.raw("</button>");
        },
        .picker => |p| {
            if (p.above_nav) {
                // The collapsed nav's section list is the tile group's
                // card, not the modal pane's surface, and it draws no
                // title: a card standing on the chip is named by the
                // chip. The string stays on the element, where it is
                // still what a screen reader is told this layer is
                // called.
                try em.raw("<div class=\"scrim\"></div><div class=\"picker above-nav\" id=\"nokre-listbox\" role=\"listbox\" aria-label=\"");
                try em.text(p.title);
                try em.raw("\">");
            } else {
                try modalSurface(em, id, "picker", p.title);
            }
            try children(em, id);
            try em.raw("</div>");
        },
        .picker_item => |p| {
            try em.print("<div class=\"picker-item\" role=\"option\" tabindex=\"-1\" aria-selected=\"{s}\"", .{
                if (p.selected) "true" else "false",
            });
            try em.stop(id);
            try em.raw(">");
            if (p.icon) |name| try icon(em, name, "", .ink, .body, .mark);
            try em.text(p.label);
            try em.raw("</div>");
        },
    }
}

/// One `button`, in every form the type permits: the secondary,
/// provider, and icon faces, and work in progress written as words —
/// never animated.
fn button(em: *Emitter, id: NodeId, b: element_mod.Button) !void {
    // A folded action is not on the row any more; the `more`
    // beside it is what stands there.
    if (b.folded) return;
    try em.raw("<button type=\"button\" class=\"btn");
    if (b.form.outlined()) try em.raw(" secondary");
    if (b.form == .provider) try em.raw(" auth");
    if (b.form.vendor() == .google) try em.raw(" google");
    if (b.form == .glyph) try em.raw(" icon-only");
    try em.raw("\"");
    if (b.disabled) try em.raw(" disabled");
    try em.stop(id);
    // Waiting is written in words, so the label already says it;
    // `aria-busy` is what says it to a screen reader mid-task.
    if (b.in_progress) {
        // The strut is hidden, so the name moves onto the control: a
        // button that stopped being named while it worked would be one
        // a screen-reader user lost hold of.
        try em.raw(" aria-busy=\"true\" aria-label=\"");
        try em.text(b.label);
        try em.raw("\"");
    }
    try em.raw(">");
    // Work in flight replaces the words rather than sitting beside
    // them: a percentage fills the pill as it goes, and a job that
    // cannot report one says so with an ellipsis. Waiting is written,
    // never animated.
    if (b.in_progress) {
        // The pill keeps the size its label gave it. Layout measured
        // the words, so they stay in flow as the hidden strut and what
        // replaces them is drawn over the top. A button that shrank
        // when it started working would be motion by another name.
        try em.raw("<span class=\"btn-strut\" aria-hidden=\"true\">");
        try em.text(b.label);
        try em.raw("</span>");
        if (b.progress_percent) |pct| {
            if (!b.disabled) {
                try em.print("<span class=\"btn-track\" aria-hidden=\"true\">" ++
                    "<span class=\"btn-fill\" style=\"width:{d}%\"></span></span>", .{@min(pct, 100)});
            }
        } else {
            try em.print("<span class=\"btn-wait\" aria-hidden=\"true\">{s}</span>", .{wrap.ellipsis});
        }
    } else {
        // The vendor's mark leads the words, decorative beside
        // the real label like every lead mark. It stands down
        // while work runs (the branch above), exactly as the
        // reference's lead does. Google's G is four arc glyphs
        // the stylesheet overlays into one drawing and colors
        // on the live pill — the markup itself carries no
        // color, here or anywhere.
        if (b.form.vendor()) |v| switch (v) {
            .apple => try em.raw("<span class=\"brand-mark\" aria-hidden=\"true\">&#xE900;</span>"),
            .google => try em.raw("<span class=\"brand-mark g\" aria-hidden=\"true\">" ++
                "<span>&#xE901;</span><span>&#xE902;</span><span>&#xE903;</span><span>&#xE904;</span></span>"),
        };
        if (b.form.icon()) |name| try icon(em, name, "", .ink, .body, .mark);
        if (b.form == .glyph) {
            try em.raw("<span class=\"visually-hidden\">");
            try em.text(b.label);
            try em.raw("</span>");
        } else {
            try em.text(b.label);
        }
    }
    try em.raw("</button>");
}

/// One `tile`: an anchor when it navigates, a button when it acts —
/// the same split the snapshot makes.
fn tile(em: *Emitter, id: NodeId, t: element_mod.Tile) !void {
    const navigates = t.route.len != 0;
    if (navigates) {
        try em.raw("<a class=\"tile\"");
        try em.href(t.route);
        try em.stop(id);
        try em.raw(">");
    } else {
        try em.raw("<button type=\"button\" class=\"tile\"");
        try em.stop(id);
        try em.raw(">");
    }
    // The leading mark takes the *square* box while the trailing
    // chevron below takes the mark box, in the same row. They are
    // not the same kind of glyph: the chevron is a mark inside a
    // control, costing its own advance, while the leading one is
    // a band a column of rows share, so it costs `lineHeight`
    // whatever glyph it holds (`layout.tileIconBand`). The row's
    // flex gap spends `icon_gap` on each of them.
    if (t.icon) |name| try icon(em, name, "", .ink, .body, .square);
    try em.raw("<span class=\"tile-text\"><span class=\"tile-label\">");
    try em.text(t.label);
    try em.raw("</span>");
    if (t.detail.len != 0) {
        try em.raw("<span class=\"tile-detail\">");
        try em.text(t.detail);
        try em.raw("</span>");
    }
    try em.raw("</span>");
    if (navigates) {
        // The chevron points where navigation goes, so a
        // mirrored chrome flips it — the reference's
        // `tile_chevron` / `tile_chevron_rtl` pair.
        const mark: IconName = if (em.app.direction == .rtl) .chevron_left else .chevron_right;
        try icon(em, mark, "", .ink, .body, .mark);
        try em.raw("</a>");
    } else {
        try em.raw("</button>");
    }
}

/// The surface a sheet, a select's picker and the notices pane share:
/// a paper body with the title at its header edge, over a scrim.
///
/// The title is the layer's accessible name *and* its header — one
/// string, so it is written once and pointed at. `aria-label` beside a
/// visible heading of the same words is that name said twice.
fn modalSurface(em: *Emitter, id: NodeId, class: []const u8, title: []const u8) !void {
    const key: u32 = @bitCast(id);
    try em.print(
        "<div class=\"scrim\"></div><div class=\"{s}\"{s} role=\"{s}\" aria-modal=\"true\"" ++
            " aria-labelledby=\"pane-title-{d}\"><h2 class=\"pane-title\" id=\"pane-title-{d}\">",
        .{
            class,
            if (std.mem.eql(u8, class, "picker")) " id=\"nokre-listbox\"" else "",
            if (std.mem.eql(u8, class, "picker")) "listbox" else "dialog",
            key,
            key,
        },
    );
    try em.text(title);
    try em.raw("</h2>");
}

/// A notice row's icon controls, one flank at a time. The census is the
/// one `noticeTextBand` takes — which glyph a control carries is what
/// decides the side it stands on — so the column the words get and the
/// order they are written in cannot disagree.
fn noticeControls(em: *Emitter, notice: NodeId, flank: enum { lead, trail }) !void {
    const glyphs: []const element_mod.ChromeGlyph = switch (flank) {
        .lead => &.{ .open, .expand },
        .trail => &.{ .minimize, .dismiss },
    };
    for (glyphs) |want| {
        var it = em.app.tree.children(notice);
        while (it.next()) |c| {
            const el = em.app.tree.getConst(c) orelse continue;
            if (el.role() != .icon_button) continue;
            if (el.icon_button.glyph != want) continue;
            try node(em, c);
        }
    }
}

/// A field's problem, in three pieces around the field's own markup.
///
/// The words hang below the field's outline at the labeled-field gap
/// (`fieldProblemHeight` spends `input_label_gap` on it), which is not
/// the page's flow gap — so the field and its problem are wrapped and
/// spaced together, exactly as `tile_group` wraps its caption. The
/// wrapper exists only when there is something to group.
///
/// The wrapping is also load-bearing for the a11y tree, and this is the
/// one place the two editions had to be argued separately: a text field
/// is inside an *implicit* `<label>`, whose whole subtree text becomes
/// the field's accessible name. Words placed in there would be spliced
/// into the name — "Email That address is already in use" — so the
/// problem stands outside the label and is reached by reference
/// instead.
///
/// The wrapper's one cost, weighed and taken: a tag change is an
/// identity change to the live driver, so the frame a problem first
/// appears in replaces the field's subtree rather than patching it.
/// Focus and the caret are restored from core on every frame, so what
/// that actually costs is an *open IME session* — and a problem lands
/// on a submission or on a committed change, never mid-preedit.
/// Emitting the wrapper unconditionally would buy the invariant and
/// charge every field on every page a div it has no use for.
///
/// `aria-describedby`, not `aria-errormessage`: the latter is the
/// tighter-fitting attribute and the one screen readers support least
/// evenly, while `describedby` is what every AT already reads and what
/// the WAI's own form-validation tutorial pairs with `aria-invalid`.
/// The relation computes to the same accessible *description* the
/// native snapshot carries, so both editions land on one property.
fn fieldOpen(em: *Emitter, problem: []const u8) !void {
    if (problem.len == 0) return;
    try em.raw("<div class=\"field-group\">");
}

/// A field that is not taking edits, in the platform's own word.
///
/// The native `disabled` attribute rather than `aria-disabled`, and the
/// same choice `button` makes for the same reason: this control really
/// is inert — out of the tab order, deaf to keys and to the pointer —
/// and `aria-disabled` would announce a state the markup then failed to
/// keep, leaving a keyboard user able to Tab into a field core says has
/// no stop. The two editions would disagree about the focus order,
/// which is the one thing a second edition may never do.
///
/// No `readonly` twin: `readonly` keeps the focus stop and the caret,
/// which is a different state from this one and not a state nokre has.
fn fieldDisabled(em: *Emitter, disabled: bool) !void {
    if (disabled) try em.raw(" disabled");
}

fn fieldProblemRef(em: *Emitter, id: NodeId, problem: []const u8) !void {
    if (problem.len == 0) return;
    try em.print(" aria-invalid=\"true\" aria-describedby=\"problem-{d}\"", .{@as(u32, @bitCast(id))});
}

fn fieldClose(em: *Emitter, id: NodeId, problem: []const u8) !void {
    if (problem.len == 0) return;
    try em.print("<p class=\"field-problem\" id=\"problem-{d}\">", .{@as(u32, @bitCast(id))});
    try em.text(problem);
    try em.raw("</p></div>");
}

/// Work in flight stands the control's *drawing* down and nothing else
/// (`Toggle.in_progress`): the input stays in the markup and stays the
/// control — it is what carries the role, the value, and `aria-busy` —
/// while the stylesheet puts `…` in the track's or the box's slot. The
/// words are untouched, so the row keeps its size and its name, and the
/// busy pair reaches a screen reader exactly as the button's does.
fn switchRow(em: *Emitter, id: NodeId, class: []const u8, label: []const u8, state: struct { on: bool, busy: bool }) !void {
    const on = state.on;
    const busy = state.busy;
    try em.print("<label class=\"ctl{s}\"", .{if (busy) " busy" else ""});
    try em.stop(id);
    try em.print("><input type=\"checkbox\" class=\"{s}\"{s}", .{
        class,
        if (std.mem.eql(u8, class, "toggle")) " role=\"switch\"" else "",
    });
    if (on) try em.raw(" checked");
    if (busy) try em.raw(" aria-busy=\"true\"");
    try em.stop(id);
    try em.raw("><span class=\"ctl-label\">");
    try em.text(label);
    try em.raw("</span></label>");
}

fn children(em: *Emitter, id: NodeId) !void {
    var it = em.app.tree.children(id);
    while (it.next()) |child| try node(em, child);
}

// ------------------------------------------------------------- inlines

/// Markdown's inline vocabulary, which is what `spans` is — not a
/// styling hook. A span with a route is the one carve-out: a control,
/// its own tab stop, announced as a link inside the paragraph.
fn inlines(em: *Emitter, owner: NodeId, plain: []const u8, spans: []const element_mod.Span) !void {
    if (spans.len == 0) return em.text(plain);
    for (spans, 0..) |s, i| {
        if (s.isLink()) {
            try em.raw("<a class=\"link\"");
            if (s.route.len > 0) try em.href(s.route) else try em.hrefExternal(s.external.?);
            // A link inside a paragraph is its own focus stop, so it
            // carries the node *and* which span it is.
            try em.stop(owner);
            if (em.options.node_ids) try em.print(" data-s=\"{d}\"", .{i});
            try em.raw(">");
        }
        const tinted = if (s.ink) |g| g != Gray.ink else false;
        if (tinted) try em.print("<span class=\"{t}\">", .{s.ink.?});
        if (s.strong) try em.raw("<strong>");
        if (s.emphasis) try em.raw("<em>");
        if (s.strike) try em.raw("<s>");
        if (s.code) try em.raw("<code>");
        try em.text(s.text);
        if (s.code) try em.raw("</code>");
        if (s.strike) try em.raw("</s>");
        if (s.emphasis) try em.raw("</em>");
        if (s.strong) try em.raw("</strong>");
        if (tinted) try em.raw("</span>");
        if (s.isLink()) try em.raw("</a>");
    }
}

// -------------------------------------------------------------- pieces

fn choice(
    em: *Emitter,
    id: NodeId,
    class: []const u8,
    label: []const u8,
    options: []const []const u8,
    selected: usize,
    shape: enum { rows, chips },
    bleed: i32,
) !void {
    const chips = shape == .chips;
    // Radiogroup semantics either way — `segmented` is a track of chips
    // and `radio_group` a column of rows, and neither is a tab list.
    try em.print("<fieldset class=\"{s}\"><legend class=\"{s}\">", .{
        class,
        if (chips) "visually-hidden" else "field-label",
    });
    try em.text(label);
    if (bleed != 0) {
        // How far the track may reach past its column before it meets a
        // drawn edge. Layout accumulated it (`Ctx.margin`) and wrote the
        // answer on the element, and it is non-zero only where the
        // reference bleeds: chips too wide for the column, and an edge
        // to run to. It arrives as an inline style rather than a
        // cascade, for `pre.code`'s reason — the accumulation is a walk,
        // and a custom property that added its parent's value to its own
        // is a cycle, which resolves to nothing at all.
        try em.print("</legend><div class=\"seg-track bled\" style=\"--bleed:{d}px\">", .{bleed});
    } else {
        try em.print("</legend><div class=\"{s}\">", .{if (chips) "seg-track" else "tiles"});
    }
    for (options, 0..) |opt, i| {
        // The id and the index ride on the *label*, which is the whole
        // chip. A driver that resolved the press on the input alone
        // would see it only after the browser had already acted on the
        // label — and cancelling that late leaves the control showing
        // one answer and the tree holding another.
        try em.print("<label class=\"{s}\"", .{if (chips) "seg" else "tile radio"});
        try em.stop(id);
        if (em.options.node_ids) try em.print(" data-i=\"{d}\"", .{i});
        // The name is what partitions the browser's radio groups, so it
        // must be unique per *control*, not per label: two same-labeled
        // groups on one page would share one group, and checking a chip
        // in one would uncheck the other on the static page. The node id
        // is the unique handle; AT already hears the label through the
        // legend.
        try em.print("><input type=\"radio\" name=\"c{d}\"", .{@as(u32, @bitCast(id))});
        if (i == selected) try em.raw(" checked");
        try em.stop(id);
        try em.print("><span{s}>", .{if (chips) "" else " class=\"tile-label\""});
        try em.text(opt);
        try em.raw("</span></label>");
    }
    try em.raw("</div></fieldset>");
}

/// How much room a glyph takes, which is not one answer in this library.
///
/// A `mark` is a glyph inside a control — a button's leading icon, a
/// destination's, a tile's chevron — and every place layout measures one
/// it costs the glyph's own advance plus `icon_gap` and nothing else
/// (`navItemWidth`, `intrinsicSize`). A `square` is a `lineHeight` box on
/// both axes: the `icon` element standing on its own, which
/// `intrinsicSize` sizes that way so it lines up with same-scale text
/// beside it, and the two *leading* marks that head a row — a `notice`'s
/// and a `tile`'s (`noticeTextBand`, `tileIconBand`). Those take the box
/// rather than the advance because a band that varied with the glyph
/// would start each row's words on a different column.
///
/// The distinction has to reach the markup because CSS cannot see which
/// one it is holding, and getting it wrong is not a visual nit: a mark in
/// a square box makes the control wider than the width core measured it
/// at, and every decision made against that width is then made against
/// the wrong number.
const IconBox = enum { mark, square };

/// An empty label means decorative: hidden from assistive tech, any ink
/// allowed. A non-empty one makes it a meaningful image, announced by
/// name and held to the same contrast gate as text.
fn icon(em: *Emitter, name: IconName, label: []const u8, ink: Gray, scale: Scale, box: IconBox) !void {
    try em.raw("<span class=\"icon");
    if (box == .square) try em.raw(" square");
    if (ink != Gray.ink) try em.print(" {t}", .{ink});
    if (scale != .body) try em.print(" s-{t}", .{scale});
    if (label.len == 0) {
        try em.raw("\" aria-hidden=\"true\">");
    } else {
        try em.raw("\" role=\"img\" aria-label=\"");
        try em.text(label);
        try em.raw("\">");
    }
    try em.print("&#x{X};</span>", .{@intFromEnum(name)});
}

/// The framework's own glyphs, which are codepoints in the same icon
/// face rather than names in `IconName`.
fn glyph(em: *Emitter, g: element_mod.ChromeGlyph) !void {
    // The same numeric-entity form `icon` uses: these are private-use
    // codepoints, and a raw one in the byte stream is at the mercy of
    // whatever decides the document's encoding.
    const cp = std.unicode.utf8Decode(g.utf8()) catch return;
    try em.print("<span class=\"icon\" aria-hidden=\"true\">&#x{X};</span>", .{cp});
}

/// A QR is modules, and modules are squares. One path is one node; one
/// `<span>` per dark module would be thousands. The symbol ignores the
/// appearance — a scanner wants dark on light, and a photo-negative code
/// is a different code.
fn qr(em: *Emitter, id: NodeId, q: element_mod.Qr) !void {
    const n: usize = @intCast(q.size);
    const quiet = layout.metrics.qr_quiet;
    const side = n + 2 * quiet;
    // Label first, then the code: the labeled-field shape `drawQr`
    // draws, with the caption on the rect's first line and the square
    // standing on its bottom edge.
    //
    // The rendered side is `layout.qrSide` — whole pixels per module,
    // capped at `qr_max_side` — measured against the span layout gave
    // this node. A fractional module blurs and a blurred module does
    // not scan, which is the whole reason that function quantizes.
    const px = layout.qrSide(q.size, em.app.tree.rectOf(id).w);
    try em.print("<div class=\"qr\"><p class=\"field-label\">", .{});
    try em.text(q.label);
    try em.print("</p><svg viewBox=\"0 0 {d} {d}\" width=\"{d}\" height=\"{d}\" role=\"img\" aria-label=\"", .{ side, side, px, px });
    try em.text(q.label);
    try em.print("\"><rect width=\"{d}\" height=\"{d}\" fill=\"#{x:0>2}{x:0>2}{x:0>2}\"/><path fill=\"#{x:0>2}{x:0>2}{x:0>2}\" d=\"", .{
        side,                  side,
        Gray.g12.byte(.light), Gray.g12.byte(.light),
        Gray.g12.byte(.light), Gray.g0.byte(.light),
        Gray.g0.byte(.light),  Gray.g0.byte(.light),
    });
    for (0..n) |y| {
        for (0..n) |x| {
            if (!q.module(@intCast(x), @intCast(y))) continue;
            try em.print("M{d} {d}h1v1h-1z", .{ x + quiet, y + quiet });
        }
    }
    try em.raw("\"/></svg></div>");
}

/// `gap` and `padding` are element fields, not styling: the renderer
/// reads them off the node exactly as the Skia edition does. Written
/// only where they differ from the element's own default — and the
/// default is read off the struct rather than repeated here, so a
/// change to one in `element.zig` cannot leave this quietly emitting
/// the wrong thing.
const Styled = struct { value: i32, default: i32 };

fn boxStyle(em: *Emitter, gap: ?Styled, padding: Styled, fill: ?Gray) !void {
    var open = false;
    if (gap) |g| if (g.value != g.default) {
        try em.print("{s}--gap:{d}px", .{ if (open) ";" else " style=\"", g.value });
        open = true;
    };
    if (padding.value != padding.default) {
        try em.print("{s}--pad:{d}px", .{ if (open) ";" else " style=\"", padding.value });
        open = true;
    }
    if (fill) |f| {
        try em.print("{s}background:var(--{t})", .{ if (open) ";" else " style=\"", f });
        open = true;
    }
    if (open) try em.raw("\"");
}

fn textClass(em: *Emitter, style: text_mod.Style, extra: []const u8) !void {
    const mono = style.family == .mono;
    const scaled = style.scale != .body;
    const tinted = style.ink != Gray.ink;
    if (!mono and !scaled and !tinted and extra.len == 0) return;
    try em.raw(" class=\"");
    if (extra.len != 0) try em.print("{s} ", .{extra});
    if (mono) try em.raw("mono ");
    if (scaled) try em.print("s-{t} ", .{style.scale});
    if (tinted) try em.print("{t}", .{style.ink});
    try em.raw("\"");
}

/// What a driver can get wrong about a stated anchor that no single
/// `Tree.append` could see. It is raised at the heading rather than
/// pre-write the way `MetaError` is, because uniqueness is a fact about
/// a whole document and the walk is what establishes it — the same
/// place, and the same error path, a `Refs` hook that cannot honor a
/// route already fails at.
pub const AnchorError = error{
    /// A stated `Heading.anchor` names an id this document already
    /// minted — an earlier stated one, or a heading whose words derive
    /// to the same slug. Refused rather than suffixed: the numeric
    /// suffix is right for two headings that merely repeat, and wrong
    /// for the one address something outside the page was told to use.
    AnchorTaken,
};

/// The heading's address: the one it stated, or GitHub's slug of its
/// words.
///
/// **Stated** goes in verbatim. Its grammar was settled at append
/// (`element.Heading.validAnchor`), so what is left here is the only
/// question a whole document can answer — whether the name is free —
/// and a taken one is `AnchorTaken` rather than a suffix.
///
/// **Derived** is GitHub's slug, because that is the slug the Markdown
/// a `document` carries was written against: lowercase, spaces to
/// hyphens, Unicode word characters kept, punctuation — ASCII and the
/// General Punctuation block both — dropped, repeats numbered.
/// Deterministic from the words alone, so the same heading is the same
/// anchor on every run. Why it is GitHub's and not nokre's is
/// docs/internals/dom-edition.md, "A heading is an address".
///
/// Both land in the same roster, so document order is the whole of the
/// arbitration: a stated anchor is refused if the name is gone by the
/// time it is reached, and a derived slug takes its usual suffix when a
/// stated one got there first. Neither ordering can move a stated
/// address, which is the property being defended.
fn headingId(em: *Emitter, stated: []const u8, words: []const u8) ![]const u8 {
    if (stated.len != 0) {
        if (taken(em.ids.items, stated)) return AnchorError.AnchorTaken;
        const owned = try em.gpa.dupe(u8, stated);
        errdefer em.gpa.free(owned);
        try em.ids.append(em.gpa, owned);
        return owned;
    }
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(em.gpa);
    var i: usize = 0;
    while (i < words.len) : (i += 1) {
        const c = words[i];
        switch (c) {
            'a'...'z', '0'...'9', '-', '_' => try buf.append(em.gpa, c),
            'A'...'Z' => try buf.append(em.gpa, c + 32),
            ' ' => try buf.append(em.gpa, '-'),
            // Non-ASCII passes through whole: GitHub's slug KEEPS Unicode
            // word characters, and dropping these bytes would slug every
            // Persian or Arabic heading to "section" — one anchor for a
            // whole document. Byte-wise pass-through keeps UTF-8 sequences
            // intact without a Unicode table.
            //
            // With one carve-out: GitHub drops Unicode PUNCTUATION the way
            // it drops "&", and General Punctuation (U+2000–U+206F) is the
            // block a heading actually reaches for — the em dash in
            // "Part 1 — A project" slugs to "part-1--a-project" there, and
            // every TOC written against GitHub's anchors says so. The
            // block is three fixed bytes (E2 80 80 … E2 81 AF), so it
            // costs no table either.
            0x80...0xff => {
                if (c == 0xe2 and i + 2 < words.len and
                    (words[i + 1] == 0x80 or (words[i + 1] == 0x81 and words[i + 2] <= 0xaf)))
                {
                    i += 2;
                    continue;
                }
                try buf.append(em.gpa, c);
            },
            else => {},
        }
    }
    if (buf.items.len == 0) try buf.appendSlice(em.gpa, "section");
    const stem = try buf.toOwnedSlice(em.gpa);
    defer em.gpa.free(stem);

    var n: usize = 0;
    var candidate = try em.gpa.dupe(u8, stem);
    while (taken(em.ids.items, candidate)) {
        em.gpa.free(candidate);
        n += 1;
        candidate = try std.fmt.allocPrint(em.gpa, "{s}-{d}", .{ stem, n });
    }
    errdefer em.gpa.free(candidate);
    try em.ids.append(em.gpa, candidate);
    return candidate;
}

fn taken(seen: []const []const u8, candidate: []const u8) bool {
    for (seen) |s| {
        if (std.mem.eql(u8, s, candidate)) return true;
    }
    return false;
}

comptime {
    // The roles this edition conveys come from the snapshot's own
    // mapping, never a second table. Referenced so a change there is a
    // change here.
    _ = semantics.roleOf;
}
