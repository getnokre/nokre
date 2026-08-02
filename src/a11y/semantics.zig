//! Derives the accessibility tree from the semantic element tree.
//! This is automatic: if it renders, it is accessible. Platform adapters
//! (AccessKit natively, ARIA on web) consume `Snapshot`.

const std = @import("std");
const tree_mod = @import("../core/tree.zig");
const element_mod = @import("../core/element.zig");
const geometry = @import("../core/geometry.zig");
const app_mod = @import("../core/app.zig");
const focus = @import("../core/focus.zig");
const input = @import("../core/input.zig");
const layout = @import("../core/layout.zig");

const Tree = tree_mod.Tree;
const NodeId = tree_mod.NodeId;
const App = app_mod.App;

pub const A11yRole = enum {
    document,
    static_text,
    heading,
    group,
    separator,
    button,
    link,
    /// A two-state switch (ARIA `switch`, AccessKit `Switch`): announced
    /// as on/off, carried in `checked` like the wire formats do.
    toggle,
    text_field,
    table,
    row,
    cell,
    scroll_area,
    radio_group,
    navigation,
    dialog,
    status,
    combo_box,
    option,
    multiline_text_field,
    image,
    /// An obscured `text_input`: announced as a secure field, value
    /// never exposed.
    password_field,
    /// A checkbox (ARIA `checkbox`, AccessKit `CheckBox`): announced as
    /// checked/unchecked, carried in `checked` like `toggle`.
    checkbox,
    /// ARIA `list` / AccessKit `List`: a sequence whose item count and
    /// positions assistive tech announces itself, from the structure —
    /// which is why nokre's derived marker is never in the label.
    list,
    list_item,
    /// ARIA `code` / AccessKit `Code`: verbatim text, announced whole
    /// so the reading never turns into a line-by-line walk.
    code,
    /// ARIA / AccessKit `blockquote`: the words inside belong to
    /// someone other than the surrounding prose.
    blockquote,
};

// The enum's ordinals are a wire contract: `accesskit.flatten` sends
// `@intFromEnum` straight to the shim, and the Android and iOS shells
// each hold a parallel table (the NOKRE_A11Y_ROLE_* enum in
// shim/nokre_accesskit.h is the reference; the DOM edition derives its
// roles in Zig instead). New roles append; nothing is ever inserted or
// reordered.
comptime {
    if (@intFromEnum(A11yRole.checkbox) != 22) @compileError("a11y role ordinals are a wire contract; append only");
}

pub const A11yNode = struct {
    id: NodeId,
    /// Which link span of `id` this node is, when the node stands for
    /// an inline link rather than the element itself. Styling spans are
    /// invisible to assistive tech by design; a link is not, so it gets
    /// its own node — see `element.Span`.
    span: ?u16 = null,
    role: A11yRole,
    label: []const u8,
    value: []const u8 = "",
    rect: geometry.Rect,
    focusable: bool,
    focused: bool,
    /// Whether assistive tech may activate this node — what the bridge
    /// exposes as its click action (`accesskit.CNode.clickable`).
    /// Carried from `Element.isInteractive` at snapshot time, never
    /// re-derived from the role: interactivity is the element model's
    /// fact, and a parallel role list in the bridge drifted once
    /// already (a select assistive tech could focus but not open).
    activatable: bool = false,
    checked: ?bool = null,
    /// aria-current: set on nav items when their route is the current one.
    selected: ?bool = null,
    disabled: bool = false,
    /// aria-busy / AccessKit `busy`: the action this node started is
    /// still running. It rides *with* `disabled` — a busy control is
    /// announced as named, present, and not operable yet, which is the
    /// pair the ARIA practices prescribe and the reason the node keeps
    /// its focus stop (WCAG 4.1.2: the state is programmatically
    /// determinable, not merely drawn).
    busy: bool = false,
    heading_level: u8 = 0,
    /// True for the open sheet: adapters expose it as a modal dialog and
    /// treat everything outside as inert.
    modal: bool = false,
    /// True for a node nokre derives rather than one it mirrors from an
    /// element — today only the acknowledgement status (see `App.ack`).
    /// It shares its element's `NodeId` (it belongs to that element and
    /// dies with it), so this is what keeps its AccessKit id clear of the
    /// element's own — see `accesskit.a11yIdOf`.
    derived: bool = false,
    /// Index of the parent within the snapshot's node list; null for roots.
    parent: ?usize = null,
};

pub const Snapshot = struct {
    gpa: std.mem.Allocator,
    nodes: std.ArrayList(A11yNode),

    pub fn deinit(self: *Snapshot) void {
        self.nodes.deinit(self.gpa);
    }

    pub fn find(self: *const Snapshot, id: NodeId) ?*const A11yNode {
        for (self.nodes.items) |*n| {
            if (n.id.eql(id) and n.span == null and !n.derived) return n;
        }
        return null;
    }

    /// The node standing for one of an element's inline links.
    pub fn findSpan(self: *const Snapshot, id: NodeId, span: u16) ?*const A11yNode {
        for (self.nodes.items) |*n| {
            if (n.id.eql(id) and n.span == span) return n;
        }
        return null;
    }

    /// First node whose accessible label equals `label` — how assistive
    /// tech (and harness assertions) address elements.
    pub fn findByLabel(self: *const Snapshot, label: []const u8) ?*const A11yNode {
        for (self.nodes.items) |*n| {
            if (n.label.len > 0 and std.mem.eql(u8, n.label, label)) return n;
        }
        return null;
    }
};

/// Builds a flat, parent-linked accessibility snapshot in document order.
/// Labels/values borrow from the tree; use before the next tree mutation.
pub fn snapshot(gpa: std.mem.Allocator, app: *App) !Snapshot {
    app.performLayout();
    var snap: Snapshot = .{ .gpa = gpa, .nodes = .empty };
    errdefer snap.deinit();
    try appendNode(&snap, app, app.tree.rootId(), null);
    return snap;
}

fn appendNode(snap: *Snapshot, app: *App, id: NodeId, parent: ?usize) !void {
    const el = app.tree.getConst(id).?;
    // Decorative icons are invisible to assistive tech (alt="").
    if (el.* == .icon and el.icon.label.len == 0) return;
    // A folded action is not on the screen: the row's `more` control
    // stands in for it, and the sheet that control opens is the one way
    // to it (overflow.zig). Announcing a name nothing can reach would be
    // worse than not announcing it — the same reason the collapsed nav
    // exposes its roster only through its picker.
    if (el.isFolded()) return;
    const is_root = id.eql(app.tree.rootId());
    const focused = if (app.focused) |f| f.on(id) else false;

    var node: A11yNode = .{
        .id = id,
        .role = if (is_root) .document else roleOf(el.*),
        .label = el.label(),
        .rect = app.tree.rectOf(id),
        .focusable = el.isFocusable(),
        .focused = focused,
        .activatable = el.isInteractive(),
        .parent = parent,
    };
    switch (el.*) {
        .heading => |h| node.heading_level = @intFromEnum(h.level),
        // The value is still reported while the work runs: the `…` on
        // screen is a rendering, and a reader who cannot see it is owed
        // the value the app still holds. The disabled/busy pair beside
        // it is the button's, below, and says the rest.
        .toggle => |t| {
            node.checked = t.on;
            node.disabled = t.in_progress;
            node.busy = t.in_progress;
        },
        .checkbox => |c| {
            node.checked = c.checked;
            node.disabled = c.in_progress;
            node.busy = c.in_progress;
        },
        .tile => |t| node.value = t.detail,
        // The description rides on the group like a tile's detail rides
        // on the tile: assistive tech hears the caption with the group.
        .tile_group => |tg| node.value = tg.description,
        // A button whose work is running is announced disabled *and*
        // busy: not operable (a second press would start the action
        // twice) but not gone — it keeps its name and its focus stop,
        // so the user who pressed it hears what it is doing rather than
        // finding it missing. The `…` on screen is a rendering; this is
        // what assistive tech is told.
        .button => |b| {
            node.disabled = b.disabled or b.in_progress;
            node.busy = b.in_progress;
            // The bar is a rendering; this is the number. It rides in
            // the value, not in a progressbar role — the node is a
            // button and stays one — so every backend already carries
            // it, and a screen reader reads "Save changes, 60%". The
            // same trade `meter` makes: the state is in the words, the
            // fill only restates it.
            if (b.in_progress) if (b.progress_percent) |pct| {
                node.value = percentText(pct);
            };
        },
        .text_input => |i| {
            if (!i.obscured) node.value = i.value;
        },
        .text_area => |a| node.value = a.value,
        .segmented => |s| {
            if (s.selected < s.options.len) node.value = s.options[s.selected];
        },
        .radio_group => |rg| {
            if (rg.selected < rg.options.len) node.value = rg.options[rg.selected];
        },
        .select => |s| {
            if (s.selected < s.options.len) node.value = s.options[s.selected];
        },
        .copyable => |c| node.value = c.value,
        .qr => |q| node.value = q.value,
        .picker_item => |p| node.selected = p.selected,
        // The section it stands on, read as the combo box's value —
        // the roster behind it is reachable only through the picker,
        // so nothing is hidden that a press does not reveal.
        .nav_current => |n| node.value = n.section,
        // The same name/value split, for the screen that is no section:
        // "Current screen" is what it is called, the title is what it
        // is showing.
        .nav_here => |n| node.value = n.label,
        .nav_item => |n| {
            node.selected = if (app.router.current()) |c| std.mem.eql(u8, c, n.route) else false;
        },
        .sheet, .notices_pane, .picker => node.modal = true,
        else => {},
    }

    try snap.nodes.append(snap.gpa, node);
    const my_index = snap.nodes.items.len - 1;
    try appendAck(snap, app, id, my_index);
    try appendLinkSpans(snap, app, id, my_index);
    var it = app.tree.children(id);
    while (it.next()) |child| {
        try appendNode(snap, app, child, my_index);
    }
}

/// The acknowledgement, as a status child of the element holding it
/// (`App.ack`). A check appearing in the field is a state change with no
/// words, so it needs a voice: this is the same polite live region a
/// notice gets, arriving and leaving with the mark, which is how the
/// platforms' own copy confirmations reach assistive tech.
///
/// The words are nokre's, so they are the framework's own
/// (`App.Chrome.copied`, English until an app translates it) — the
/// element's own label and value stay untouched, because the
/// announcement must not disturb what an assistive-tech user reads back
/// to check the value they just copied.
fn appendAck(snap: *Snapshot, app: *App, id: NodeId, parent: usize) !void {
    const acked = if (app.ack) |a| a.eql(id) else false;
    if (!acked) return;
    try snap.nodes.append(snap.gpa, .{
        .id = id,
        .role = .status,
        .label = app.chrome.copied,
        // The field's own rect: the announcement is about this control,
        // and adapters that place their mirror need somewhere to put it.
        .rect = app.tree.rectOf(id),
        .focusable = false,
        .focused = false,
        .parent = parent,
        .derived = true,
    });
}

/// "0%" … "100%", built at comptime. A snapshot's strings borrow from
/// the tree and stay valid until it mutates, so a derived one has to
/// live somewhere that outlives both — and the whole range of a
/// percentage is 101 short strings. No allocator, no formatting buffer,
/// no lifetime to get wrong.
const percent_texts = blk: {
    @setEvalBranchQuota(20_000); // 101 formats, once, at compile time
    var out: [101][]const u8 = undefined;
    for (&out, 0..) |*slot, i| slot.* = std.fmt.comptimePrint("{d}%", .{i});
    break :blk out;
};

fn percentText(pct: u8) []const u8 {
    return percent_texts[@min(pct, 100)];
}

/// A paragraph's inline links, as link children of the paragraph node.
/// This is the one place a span is visible to assistive tech: styling
/// spans stay invisible (the element announces its concatenation as one
/// text node), but a link is a control, and a link nobody can hear is
/// worse than no link at all. The paragraph keeps announcing its full
/// words, so the link's text is heard twice — in context and as the
/// control — which is what every browser does with an `<a>` in a `<p>`.
fn appendLinkSpans(snap: *Snapshot, app: *App, id: NodeId, parent: usize) !void {
    const el = app.tree.getConst(id).?;
    const spans = focus.spansOf(el.*);
    var buf: [layout.max_span_rects]geometry.Rect = undefined;
    for (spans, 0..) |span, i| {
        // Routed or external, one role: `link` is what it does on this
        // screen — where it goes is the press's business.
        if (!span.isLink()) continue;
        const index: u16 = @intCast(i);
        const rects = input.spanRectsOf(app, id, index, &buf);
        try snap.nodes.append(snap.gpa, .{
            .id = id,
            .span = index,
            .role = .link,
            .label = span.text,
            .rect = if (rects.len > 0) rects[0] else app.tree.rectOf(id),
            .focusable = true,
            .focused = if (app.focused) |f| f.node.eql(id) and f.span == index else false,
            // Not an element, so `isInteractive` cannot answer for it —
            // but a link span exists in the snapshot precisely because
            // it is a control (see above), and a control assistive tech
            // can reach but not press is a dead end.
            .activatable = true,
            .parent = parent,
        });
    }
}

/// The role an element carries, for anything that has to state it.
/// Public because the DOM edition asks the same question — an element
/// whose HTML tag already carries the right implicit role gets no ARIA,
/// and everything else states what this returns. Two editions that
/// consult one function cannot disagree about what an element *is*.
pub fn roleOf(el: element_mod.Element) A11yRole {
    return switch (el) {
        .text => .static_text,
        // A badge is words with a border; the border says nothing the
        // words don't.
        .badge => .static_text,
        // A meter is words with a bar; the fill only restates the label,
        // so assistive tech hears the words and misses nothing.
        .meter => .static_text,
        .heading => .heading,
        .icon => .image,
        // A QR code is an image named by its label; the value it encodes
        // rides along so assistive tech misses nothing a camera gets.
        .qr => .image,
        .box, .stack => .group,
        .divider => .separator,
        .button => .button,
        // The sheet's close control is a plain button to assistive tech,
        // and so is the router's back control — and so is the folded
        // tail of a button row, which is named for what it holds and
        // opens a dialog the way any button may.
        .sheet_close, .back, .more => .button,
        // Nav items are links that navigate; aria-current rides on top.
        .link, .nav_item => .link,
        .tile_group => .group,
        // A navigating tile is a link; an acting one is a button.
        .tile => |t| if (t.route.len > 0) .link else .button,
        .toggle => .toggle,
        .checkbox => .checkbox,
        .text_input => |i| if (i.obscured) .password_field else .text_field,
        .text_area => .multiline_text_field,
        // The marker is derived from the list and the position, so
        // assistive tech renders its own — announcing nokre's would
        // double it.
        .list => .list,
        .list_item => .list_item,
        .code_block => .code,
        .blockquote => .blockquote,
        // A document is a landmark named by its label — the same role
        // the root stack takes, because that is what it is: a region of
        // self-contained content.
        .document => .document,
        .table => .table,
        .row => .row,
        .cell => .cell,
        .scroll_region => .scroll_area,
        .segmented, .radio_group => .radio_group,
        // The collapsed nav is a combo box, not a link: it opens a list
        // and takes a choice, which is the select's contract. Announcing
        // it as a link would promise a destination the press does not go
        // to. Reusing the existing role also leaves the ordinal wire
        // contract untouched.
        .select, .nav_current => .combo_box,
        // The row's off-roster marker is a label, not a destination: it
        // goes nowhere, takes no focus, and announcing it as a link
        // would promise a press that does nothing (`NavHere`).
        .nav_here => .static_text,
        // A copyable is a button named by its label, carrying the value
        // it copies — assistive tech reads both, like a tile's detail.
        .copyable => .button,
        .picker => .dialog,
        .picker_item => .option,
        .nav => .navigation,
        .sheet, .notices_pane => .dialog,
        .icon_button => .button,
        // A polite live region: notices persist, so interrupting the
        // user mid-task buys nothing.
        .notice => .status,
    };
}
