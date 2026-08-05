//! The builder cursor: one method per element, standing at the node
//! new children go under. It is sugar over `Tree.append`/`appendId` and
//! nothing else — no state, no deferral, no second truth about the
//! tree. Every construction rule (`tree.validateAppend`), every string
//! copy, every contrast gate runs exactly as it does for a raw append,
//! because the cursor *is* that call. The raw `Tree` API stays public
//! and legitimate: it is the substrate, and the one form for the rare
//! call the cursor does not carry (holding a leaf's `NodeId`, spanned
//! headings).
//!
//! Shape rules, derived from the element set:
//! - A leaf method takes its element struct and returns nothing, as
//!   `Tree.append` does — most children are leaves nobody addresses
//!   again.
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
//! union member the cursor cannot spell.

const std = @import("std");
const element_mod = @import("element.zig");
const text_mod = @import("text.zig");
const tree_mod = @import("tree.zig");
const app_mod = @import("app.zig");

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
