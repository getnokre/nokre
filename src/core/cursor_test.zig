//! Tests for cursor.zig: that every method appends exactly the element
//! it names (the closed-set half the comptime name check cannot see),
//! and that container methods stand on the node they created.

const std = @import("std");
const cursor_mod = @import("cursor.zig");
const element_mod = @import("element.zig");
const tree_mod = @import("tree.zig");
const test_app = @import("test_app.zig");

const Cursor = cursor_mod.Cursor;
const Tree = tree_mod.Tree;
const NodeId = tree_mod.NodeId;
const Role = element_mod.Role;

fn rootCursor(tree: *Tree) Cursor {
    return .{ .tree = tree, .at = tree.rootId() };
}

/// The most recent append under `id` — what a just-run leaf method made.
fn lastChild(tree: *const Tree, id: NodeId) NodeId {
    var last: NodeId = .invalid;
    var it = tree.children(id);
    while (it.next()) |c| last = c;
    return last;
}

fn expectLast(tree: *const Tree, id: NodeId, role: Role) !void {
    try std.testing.expectEqual(role, tree.getConst(lastChild(tree, id)).?.role());
}

test "containers hand back the cursor standing on their own node" {
    var tree = try Tree.init(std.testing.allocator);
    defer tree.deinit();
    const root = rootCursor(&tree);

    // Nesting is the return value: each cursor's `at` must be the node
    // the method appended, so children land under it and not beside it.
    const outer = try root.stack(.{ .axis = .horizontal });
    const inner = try outer.box(.{});
    try inner.text("leaf");

    try std.testing.expectEqual(Role.stack, tree.getConst(outer.at).?.role());
    try std.testing.expectEqual(Role.box, tree.getConst(inner.at).?.role());
    try std.testing.expectEqual(tree.rootId(), tree.parentOf(outer.at).?);
    try std.testing.expectEqual(outer.at, tree.parentOf(inner.at).?);
    const leaf = lastChild(&tree, inner.at);
    try std.testing.expectEqual(inner.at, tree.parentOf(leaf).?);
    try std.testing.expectEqualStrings("leaf", tree.getConst(leaf).?.label());
}

test "a cursor is a position, not a mode: raw Tree calls interleave" {
    // The doctrine made checkable: the cursor IS Tree calls, so a raw
    // append against `c.at` and a method call build identical structure.
    var tree = try Tree.init(std.testing.allocator);
    defer tree.deinit();
    const b = try rootCursor(&tree).box(.{});
    try b.text("via cursor");
    try tree.append(b.at, .{ .text = .{ .content = "via tree" } });
    try std.testing.expectEqual(@as(usize, 2), tree.childCount(b.at));
}

test "every content method appends the element it names" {
    var tree = try Tree.init(std.testing.allocator);
    defer tree.deinit();
    const root = rootCursor(&tree);
    const root_id = tree.rootId();

    try root.text("plain");
    try expectLast(&tree, root_id, .text);
    try root.styled("dim", .{ .scale = .small, .ink = .dark });
    try expectLast(&tree, root_id, .text);
    const dim = tree.getConst(lastChild(&tree, root_id)).?.text;
    try std.testing.expectEqualStrings("dim", dim.content);
    try std.testing.expectEqual(@import("text.zig").Style{ .scale = .small, .ink = .dark }, dim.style);
    try root.spanned(&.{ .{ .text = "a " }, .{ .text = "b", .strong = true } });
    // Spans concatenate into content at append, exactly as raw.
    try std.testing.expectEqualStrings("a b", tree.getConst(lastChild(&tree, root_id)).?.label());
    try root.heading(.h2, "section");
    try std.testing.expectEqual(element_mod.HeadingLevel.h2, tree.getConst(lastChild(&tree, root_id)).?.heading.level);
    try root.icon(.{ .name = .globe, .label = "Globe" });
    try expectLast(&tree, root_id, .icon);
    try root.divider();
    try expectLast(&tree, root_id, .divider);
    try root.badge(.{ .label = "Active" });
    try expectLast(&tree, root_id, .badge);
    try root.meter(.{ .label = "3 of 9", .value = 3, .max = 9 });
    try expectLast(&tree, root_id, .meter);
    try root.qr(.{ .label = "This site", .value = "https://example.org" });
    try expectLast(&tree, root_id, .qr);
    try root.codeBlock("const x = 1;");
    try expectLast(&tree, root_id, .code_block);
    try root.document(.{ .label = "Terms", .source = "plain words" });
    try expectLast(&tree, root_id, .document);
}

test "every interactive method appends the element it names" {
    var tree = try Tree.init(std.testing.allocator);
    defer tree.deinit();
    const root = rootCursor(&tree);
    const root_id = tree.rootId();

    try root.button(.{ .label = "Go" });
    try expectLast(&tree, root_id, .button);
    try root.link(.{ .label = "Home", .route = "home" });
    try expectLast(&tree, root_id, .link);
    try root.toggle(.{ .label = "Sync" });
    try expectLast(&tree, root_id, .toggle);
    try root.checkbox(.{ .label = "Agree" });
    try expectLast(&tree, root_id, .checkbox);
    try root.textInput(.{ .label = "Title" });
    try expectLast(&tree, root_id, .text_input);
    try root.textArea(.{ .label = "Note" });
    try expectLast(&tree, root_id, .text_area);
    try root.segmented(.{ .label = "View", .options = &.{ "All", "Done" } });
    try expectLast(&tree, root_id, .segmented);
    try root.radioGroup(.{ .label = "Format", .options = &.{ "MD", "TXT" } });
    try expectLast(&tree, root_id, .radio_group);
    try root.select(.{ .label = "Sort", .options = &.{ "Age", "Name" } });
    try expectLast(&tree, root_id, .select);
    try root.copyable(.{ .label = "Code", .value = "XK-1" });
    try expectLast(&tree, root_id, .copyable);
}

test "every container method appends the element it names" {
    var tree = try Tree.init(std.testing.allocator);
    defer tree.deinit();
    const root = rootCursor(&tree);

    const stack = try root.stack(.{});
    try std.testing.expectEqual(Role.stack, tree.getConst(stack.at).?.role());
    const box = try root.box(.{});
    try std.testing.expectEqual(Role.box, tree.getConst(box.at).?.role());
    const region = try root.scrollRegion(.{ .height = 120 });
    try std.testing.expectEqual(Role.scroll_region, tree.getConst(region.at).?.role());

    const list = try root.list(.{ .ordered = true });
    const item = try list.listItem();
    try item.text("first");
    try std.testing.expectEqual(Role.list_item, tree.getConst(item.at).?.role());
    try std.testing.expectEqual(list.at, tree.parentOf(item.at).?);

    const quote = try root.blockquote();
    try quote.text("cited words");
    try std.testing.expectEqual(Role.blockquote, tree.getConst(quote.at).?.role());

    const table = try root.table();
    const row = try table.row(.{ .header = true });
    const cell = try row.cell();
    try cell.text("Element");
    try std.testing.expectEqual(Role.cell, tree.getConst(cell.at).?.role());
    try std.testing.expectEqual(row.at, tree.parentOf(cell.at).?);

    const group = try root.tileGroup(.{});
    try group.tile(.{ .label = "Testing", .route = "testing" });
    try expectLast(&tree, group.at, .tile);
}

test "every chrome method appends the element it names" {
    // Consumers rarely stand here, but the set is the element set,
    // whole — and every structural rule still gates the append inside.
    var tree = try Tree.init(std.testing.allocator);
    defer tree.deinit();
    const root = rootCursor(&tree);
    const root_id = tree.rootId();

    const nav = try root.nav();
    try std.testing.expectEqual(Role.nav, tree.getConst(nav.at).?.role());
    try nav.navItem(.{ .label = "Home", .route = "home", .icon = .house });
    try expectLast(&tree, nav.at, .nav_item);
    try nav.navHere(.{ .value = "Settings" });
    try expectLast(&tree, nav.at, .nav_here);
    try tree.remove(nav.at);
    const chip_nav = try root.nav();
    try chip_nav.navCurrent(.{ .section = "Home", .icon = .house });
    try expectLast(&tree, chip_nav.at, .nav_current);

    const sheet = try root.sheet(.{ .title = "Filters" });
    try std.testing.expectEqual(Role.sheet, tree.getConst(sheet.at).?.role());
    try sheet.sheetClose(.{});
    try expectLast(&tree, sheet.at, .sheet_close);

    try root.back(.{});
    try expectLast(&tree, root_id, .back);

    const notice = try root.notice(.{ .title = "Saved", .route = "home" });
    try std.testing.expectEqual(Role.notice, tree.getConst(notice.at).?.role());
    try notice.iconButton(.{ .glyph = .dismiss, .label = "Dismiss: Saved" });
    try expectLast(&tree, notice.at, .icon_button);

    const pane = try root.noticesPane(.{});
    try std.testing.expectEqual(Role.notices_pane, tree.getConst(pane.at).?.role());

    const picker = try root.picker(.{ .title = "Sort" });
    const rows = try picker.scrollRegion(.{ .height = 0 });
    try rows.pickerItem(.{ .label = "Age" });
    try expectLast(&tree, rows.at, .picker_item);

    const actions = try root.stack(.{ .axis = .horizontal });
    try actions.more(.{});
    try expectLast(&tree, actions.at, .more);
}

test "construction rules gate the cursor exactly as they gate append" {
    // One rule from each family, through the cursor: the cursor adds no
    // second door, so what append refuses the cursor refuses.
    var tree = try Tree.init(std.testing.allocator);
    defer tree.deinit();
    const root = rootCursor(&tree);

    try std.testing.expectError(error.UnlabeledInteractive, root.button(.{ .label = "" }));
    const table = try root.table();
    try std.testing.expectError(error.TableChildMustBeRow, table.text("not a row"));
    try std.testing.expectError(error.TileOutsideTileGroup, root.tile(.{ .label = "Row", .route = "home" }));
}

test "loadGate: the ready answer is the whole of ready" {
    // Ready appends nothing — the placeholder title and copy belong to
    // the not-ready states — and answers "go build the content".
    var tree = try Tree.init(std.testing.allocator);
    defer tree.deinit();
    const root = rootCursor(&tree);

    try std.testing.expect(try root.loadGate(.ready, .{
        .title = "Circle",
        .loading = "Loading…",
        .failed = "Could not load",
        .retry = .{ .label = "Retry", .on_press = .{} },
    }));
    try std.testing.expectEqual(@as(usize, 0), tree.childCount(tree.rootId()));
}

test "loadGate: idle and loading render identically" {
    // An ensure-on-first-render app shows .idle for at most one frame;
    // distinct words for it would flash. Both real apps grouped the two
    // arms in every one of their hand-written switches — the gate keeps
    // that grouping.
    for ([_]@import("load.zig").Load{ .idle, .loading }) |phase| {
        var tree = try Tree.init(std.testing.allocator);
        defer tree.deinit();
        const root = rootCursor(&tree);

        try std.testing.expect(!try root.loadGate(phase, .{ .loading = "Loading…" }));
        try std.testing.expectEqual(@as(usize, 1), tree.childCount(tree.rootId()));
        const copy = tree.getConst(lastChild(&tree, tree.rootId())).?;
        try std.testing.expectEqual(Role.text, copy.role());
        try std.testing.expectEqualStrings("Loading…", copy.label());
    }
}

test "loadGate: failed renders the copy and a secondary retry, wired" {
    var tree = try Tree.init(std.testing.allocator);
    defer tree.deinit();
    const root = rootCursor(&tree);

    const Counter = struct {
        hits: usize = 0,
        fn retry(self: *@This()) void {
            self.hits += 1;
        }
    };
    var counter: Counter = .{};

    try std.testing.expect(!try root.loadGate(.failed, .{
        .loading = "Loading…",
        .failed = "Could not load",
        .retry = .{ .label = "Retry", .on_press = .bind(Counter.retry, &counter) },
    }));

    // Exactly the two appends the apps wrote by hand: the copy, then a
    // secondary-form button carrying the given action.
    try std.testing.expectEqual(@as(usize, 2), tree.childCount(tree.rootId()));
    var it = tree.children(tree.rootId());
    const copy = tree.getConst(it.next().?).?;
    try std.testing.expectEqual(Role.text, copy.role());
    try std.testing.expectEqualStrings("Could not load", copy.label());
    const button = tree.getConst(it.next().?).?.button;
    try std.testing.expectEqualStrings("Retry", button.label);
    try std.testing.expectEqual(element_mod.Button.Form{ .secondary = null }, button.form);
    button.on_press.invoke();
    try std.testing.expectEqual(@as(usize, 1), counter.hits);
}

test "loadGate: every field defaults to appending nothing" {
    // The floor is a bare phase check: a section that quietly vanishes
    // while not ready (both apps have several) is `loadGate(phase, .{})`.
    var tree = try Tree.init(std.testing.allocator);
    defer tree.deinit();
    const root = rootCursor(&tree);

    try std.testing.expect(!try root.loadGate(.loading, .{}));
    try std.testing.expect(!try root.loadGate(.failed, .{}));
    try std.testing.expect(try root.loadGate(.ready, .{}));
    try std.testing.expectEqual(@as(usize, 0), tree.childCount(tree.rootId()));
}

test "loadGate: the title heads loading and failed alike" {
    // The h1 for screens that gate their whole body: the same
    // placeholder over both not-ready states, exactly where the apps
    // put it by hand.
    for ([_]@import("load.zig").Load{ .loading, .failed }) |phase| {
        var tree = try Tree.init(std.testing.allocator);
        defer tree.deinit();
        const root = rootCursor(&tree);

        try std.testing.expect(!try root.loadGate(phase, .{ .title = "Billing", .loading = "Loading…", .failed = "Could not load" }));
        var it = tree.children(tree.rootId());
        const title = tree.getConst(it.next().?).?;
        try std.testing.expectEqual(Role.heading, title.role());
        try std.testing.expectEqual(element_mod.HeadingLevel.h1, title.heading.level);
        try std.testing.expectEqualStrings("Billing", title.label());
        try std.testing.expectEqual(Role.text, tree.getConst(it.next().?).?.role());
    }
}

test "confirmSheet: the four appends every confirmation wrote by hand" {
    var tree = try Tree.init(std.testing.allocator);
    defer tree.deinit();
    const root = rootCursor(&tree);

    const Acts = struct {
        confirmed: usize = 0,
        cancelled: usize = 0,
        fn confirm(self: *@This()) void {
            self.confirmed += 1;
        }
        fn cancel(self: *@This()) void {
            self.cancelled += 1;
        }
    };
    var acts: Acts = .{};

    try root.confirmSheet(.{
        .body = "This removes their access.",
        .error_copy = "Could not remove them.",
        .confirm = .{ .label = "Remove", .on_press = .bind(Acts.confirm, &acts) },
        .cancel = .{ .label = "Cancel", .on_press = .bind(Acts.cancel, &acts) },
    });

    // Body, then what went wrong last time, then the filled primary,
    // then the secondary beside it — the order is the reading order,
    // and the failure sits where the user is about to press again.
    try std.testing.expectEqual(@as(usize, 4), tree.childCount(tree.rootId()));
    var it = tree.children(tree.rootId());
    try std.testing.expectEqualStrings("This removes their access.", tree.getConst(it.next().?).?.label());
    try std.testing.expectEqualStrings("Could not remove them.", tree.getConst(it.next().?).?.label());
    const confirm = tree.getConst(it.next().?).?.button;
    try std.testing.expectEqualStrings("Remove", confirm.label);
    try std.testing.expectEqual(element_mod.Button.Form{ .filled = null }, confirm.form);
    confirm.on_press.invoke();
    const cancel = tree.getConst(it.next().?).?.button;
    try std.testing.expectEqualStrings("Cancel", cancel.label);
    try std.testing.expectEqual(element_mod.Button.Form{ .secondary = null }, cancel.form);
    cancel.on_press.invoke();
    try std.testing.expectEqual(@as(usize, 1), acts.confirmed);
    try std.testing.expectEqual(@as(usize, 1), acts.cancelled);
}

test "confirmSheet: busy marks the primary and leaves the way out" {
    var tree = try Tree.init(std.testing.allocator);
    defer tree.deinit();
    const root = rootCursor(&tree);

    try root.confirmSheet(.{
        .confirm = .{ .label = "Delete", .on_press = .{} },
        .cancel = .{ .label = "Cancel", .on_press = .{} },
        .busy = true,
    });

    // The settled disagreement: with no spinner and no animation, a
    // busy sheet shows a static `in_progress` primary and nothing else
    // moves, so Cancel stays pressable — and stays a focus stop, which
    // is what makes it the way out rather than a control that lies.
    var it = tree.children(tree.rootId());
    const confirm = tree.getConst(it.next().?).?.button;
    try std.testing.expect(confirm.in_progress);
    try std.testing.expect(!confirm.disabled);
    const cancel = tree.getConst(it.next().?).?.button;
    try std.testing.expect(!cancel.disabled);
    try std.testing.expect(!cancel.in_progress);
    try std.testing.expect(tree.getConst(lastChild(&tree, tree.rootId())).?.isInteractive());
}

test "confirmSheet: both copies are optional, and the precondition is the primary's" {
    var tree = try Tree.init(std.testing.allocator);
    defer tree.deinit();
    const root = rootCursor(&tree);

    // A confirmation whose title asks the whole question, and whose
    // body is content the sheet appended itself before calling this —
    // a continuity warning, a checkbox — says neither line here.
    try root.confirmSheet(.{
        .confirm = .{ .label = "Delete", .on_press = .{}, .disabled = true },
        .cancel = .{ .label = "Cancel", .on_press = .{} },
    });
    try std.testing.expectEqual(@as(usize, 2), tree.childCount(tree.rootId()));
    var it = tree.children(tree.rootId());
    const confirm = tree.getConst(it.next().?).?.button;
    // The sheet's own precondition — a name not typed, a box not
    // ticked — is distinct from `busy`, and only the primary has one.
    try std.testing.expect(confirm.disabled);
    try std.testing.expect(!confirm.in_progress);
}

test "root and at stand where they say" {
    var app = try test_app.init(400, 400);
    defer app.deinit();

    const root = app.root();
    try std.testing.expectEqual(app.tree.rootId(), root.at);
    const box = try root.box(.{});
    try std.testing.expectEqual(box.at, app.at(box.at).at);
    try std.testing.expectEqual(&app.tree, app.at(box.at).tree);
}
