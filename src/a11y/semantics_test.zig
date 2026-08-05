//! Tests for semantics.zig: role mapping and state carried into the
//! accessibility snapshot.

const std = @import("std");
const accesskit = @import("accesskit.zig");
const app_mod = @import("../core/app.zig");
const element_mod = @import("../core/element.zig");
const layout = @import("../core/layout.zig");
const semantics = @import("semantics.zig");
const test_app = @import("../core/test_app.zig");

const testing = std.testing;
const App = app_mod.App;
const A11yNode = semantics.A11yNode;
const A11yRole = semantics.A11yRole;
const snapshot = semantics.snapshot;

fn noopPress(_: ?*anyopaque) void {}

test "snapshot mirrors the semantic tree with correct roles and states" {
    var app = try test_app.init(400, 400);
    defer app.deinit();
    try app.tree.append(app.tree.rootId(), .{ .heading = .{ .content = "Settings", .level = .h2 } });
    const tg = try app.tree.appendId(app.tree.rootId(), .{ .toggle = .{ .label = "Dark ink", .on = true } });
    app.focused = .of(tg);

    var snap = try snapshot(testing.allocator, &app);
    defer snap.deinit();

    try testing.expectEqual(A11yRole.document, snap.nodes.items[0].role);

    const h = snap.nodes.items[1];
    try testing.expectEqual(A11yRole.heading, h.role);
    try testing.expectEqual(@as(u8, 2), h.heading_level);
    try testing.expectEqualStrings("Settings", h.label);

    const t = snap.find(tg).?;
    try testing.expectEqual(A11yRole.toggle, t.role);
    try testing.expectEqual(@as(?bool, true), t.checked);
    try testing.expect(t.focused);
    try testing.expectEqual(@as(?usize, 0), t.parent);
}

test "checkbox maps to a checkbox carrying its checked state" {
    var app = try test_app.init(400, 400);
    defer app.deinit();
    const cb = try app.tree.appendId(app.tree.rootId(), .{ .checkbox = .{ .label = "I agree", .checked = true } });

    var snap = try snapshot(testing.allocator, &app);
    defer snap.deinit();

    const n = snap.find(cb).?;
    try testing.expectEqual(A11yRole.checkbox, n.role);
    try testing.expectEqualStrings("I agree", n.label);
    try testing.expectEqual(@as(?bool, true), n.checked);
    try testing.expect(n.focusable);
}

test "a button with work in progress is announced busy, disabled, and still reachable" {
    var app = try test_app.init(400, 400);
    defer app.deinit();
    const running = try app.tree.appendId(app.tree.rootId(), .{ .button = .{ .label = "Save changes", .in_progress = true } });
    const off = try app.tree.appendId(app.tree.rootId(), .{ .button = .{ .label = "Delete", .disabled = true } });

    var snap = try snapshot(testing.allocator, &app);
    defer snap.deinit();

    const n = snap.find(running).?;
    try testing.expectEqual(A11yRole.button, n.role);
    // The name is the words, never the `…` standing in for them: a
    // voice-control user keeps the phrase they were about to say.
    try testing.expectEqualStrings("Save changes", n.label);
    try testing.expect(n.busy);
    // Busy rides with disabled, not instead of it — not operable yet…
    try testing.expect(n.disabled);
    // …but still a stop, so the user who pressed it is where they were.
    try testing.expect(n.focusable);

    // Plain disabled is unavailable, not working: no busy, no stop.
    const d = snap.find(off).?;
    try testing.expect(d.disabled);
    try testing.expect(!d.busy);
    try testing.expect(!d.focusable);
}

test "a switch with work in progress keeps its value and gains the busy pair" {
    var app = try test_app.init(400, 400);
    defer app.deinit();
    const sw = try app.tree.appendId(app.tree.rootId(), .{ .toggle = .{ .label = "Push to phone", .on = true, .in_progress = true } });
    const box = try app.tree.appendId(app.tree.rootId(), .{ .checkbox = .{ .label = "Weekly digest", .in_progress = true } });

    var snap = try snapshot(testing.allocator, &app);
    defer snap.deinit();

    for ([_]@TypeOf(sw){ sw, box }) |id| {
        const n = snap.find(id).?;
        // The button's pair: not operable, not gone.
        try testing.expect(n.busy);
        try testing.expect(n.disabled);
        try testing.expect(n.focusable);
        try testing.expect(!n.activatable);
    }
    // The value the pixels stopped showing is still what a reader is
    // told: the `…` is a rendering, and the app still holds the state.
    try testing.expectEqual(@as(?bool, true), snap.find(sw).?.checked);
    try testing.expectEqual(@as(?bool, false), snap.find(box).?.checked);
    // And the name never became the mark.
    try testing.expectEqualStrings("Push to phone", snap.find(sw).?.label);
}

test "a known percentage reaches assistive tech as the button's value" {
    var app = try test_app.init(400, 400);
    defer app.deinit();
    const id = try app.tree.appendId(app.tree.rootId(), .{ .button = .{ .label = "Save changes", .in_progress = true, .progress_percent = 60 } });

    var snap = try snapshot(testing.allocator, &app);
    defer snap.deinit();

    const n = snap.find(id).?;
    // Still a button, still named, still busy — the number is the value,
    // so it is heard as "Save changes, 60%" rather than needing a role
    // the node cannot have.
    try testing.expectEqual(A11yRole.button, n.role);
    try testing.expectEqualStrings("Save changes", n.label);
    try testing.expectEqualStrings("60%", n.value);
    try testing.expect(n.busy);
    try testing.expect(n.disabled);
    try testing.expect(n.focusable);

    // The bar is not drawn while disabled, but the number is not the
    // bar: assistive tech still gets it.
    app.tree.get(id).?.button.disabled = true;
    var snap2 = try snapshot(testing.allocator, &app);
    defer snap2.deinit();
    try testing.expectEqualStrings("60%", snap2.find(id).?.value);

    // Without a number there is nothing to say — no invented zero.
    app.tree.get(id).?.button.progress_percent = null;
    var snap3 = try snapshot(testing.allocator, &app);
    defer snap3.deinit();
    try testing.expectEqualStrings("", snap3.find(id).?.value);
}

test "badges are static text to assistive tech" {
    var app = try test_app.init(400, 400);
    defer app.deinit();
    const badge = try app.tree.appendId(app.tree.rootId(), .{ .badge = .{ .label = "Active" } });

    var snap = try snapshot(testing.allocator, &app);
    defer snap.deinit();

    const n = snap.find(badge).?;
    try testing.expectEqual(A11yRole.static_text, n.role);
    try testing.expectEqualStrings("Active", n.label);
    try testing.expect(!n.focusable);
}

test "meters are static text to assistive tech" {
    var app = try test_app.init(400, 400);
    defer app.deinit();
    const meter = try app.tree.appendId(app.tree.rootId(), .{ .meter = .{ .label = "12 of 30 days", .value = 12, .max = 30 } });

    var snap = try snapshot(testing.allocator, &app);
    defer snap.deinit();

    const n = snap.find(meter).?;
    try testing.expectEqual(A11yRole.static_text, n.role);
    try testing.expectEqualStrings("12 of 30 days", n.label);
    try testing.expect(!n.focusable);
}

test "qr maps to an image named by its label, carrying its value" {
    var app = try test_app.init(400, 400);
    defer app.deinit();
    const qr = try app.tree.appendId(app.tree.rootId(), .{ .qr = .{
        .label = "Invite link",
        .value = "https://example.com/invite/XKCD-1234",
    } });

    var snap = try snapshot(testing.allocator, &app);
    defer snap.deinit();

    const n = snap.find(qr).?;
    try testing.expectEqual(A11yRole.image, n.role);
    try testing.expectEqualStrings("Invite link", n.label);
    try testing.expectEqualStrings("https://example.com/invite/XKCD-1234", n.value);
    try testing.expect(!n.focusable);
}

test "labeled icons are images; decorative icons vanish" {
    var app = try test_app.init(400, 400);
    defer app.deinit();
    const deco = try app.tree.appendId(app.tree.rootId(), .{ .icon = .{ .name = .airplay } });
    const named = try app.tree.appendId(app.tree.rootId(), .{ .icon = .{ .name = .accessibility, .label = "Accessible venue" } });

    var snap = try snapshot(testing.allocator, &app);
    defer snap.deinit();

    try testing.expectEqual(@as(?*const A11yNode, null), snap.find(deco));
    const img = snap.find(named).?;
    try testing.expectEqual(A11yRole.image, img.role);
    try testing.expect(!img.focusable);
    try testing.expectEqualStrings("Accessible venue", img.label);
}

test "snapshot rects come from layout" {
    var app = try test_app.init(400, 400);
    defer app.deinit();
    const btn = try app.tree.appendId(app.tree.rootId(), .{ .button = .{ .label = "Go" } });

    var snap = try snapshot(testing.allocator, &app);
    defer snap.deinit();

    try testing.expectEqual(app.tree.rectOf(btn), snap.find(btn).?.rect);
    try testing.expect(!snap.find(btn).?.rect.isEmpty());
}

fn buildNavHome(_: ?*anyopaque, app: *App) anyerror!void {
    try app.tree.append(app.tree.rootId(), .{ .heading = .{ .content = "Home" } });
}

test "nav maps to a navigation landmark with the current item selected" {
    var app = try App.init(testing.allocator, .{
        .viewport = .{ .w = 400, .h = 400 },
        .routes = &.{
            .{ .name = "home", .title = .{ .fixed = "Home" }, .build = buildNavHome },
            .{ .name = "settings", .title = .{ .fixed = "Settings" }, .build = buildNavHome },
        },
        .services = .mocks(),
    });
    defer app.deinit();
    try app.setNav(&.{
        .{ .route = "home", .icon = .house },
        .{ .route = "settings", .icon = .settings },
    });
    try app.navigate("home");

    var snap = try snapshot(testing.allocator, &app);
    defer snap.deinit();

    const nav_node = snap.nodes.items[1];
    try testing.expectEqual(A11yRole.navigation, nav_node.role);

    const home = snap.nodes.items[2];
    try testing.expectEqual(A11yRole.link, home.role);
    try testing.expectEqual(@as(?bool, true), home.selected);
    const settings = snap.nodes.items[3];
    try testing.expectEqual(@as(?bool, false), settings.selected);
}

test "the collapsed nav is a combo box named Section, valued by the current one" {
    var app = try App.init(testing.allocator, .{
        // Narrow enough that these titles cannot make a row.
        .viewport = .{ .w = 375, .h = 600 },
        .routes = &.{
            .{ .name = "library", .title = .{ .fixed = "Library" }, .build = buildNavHome },
            .{ .name = "settings", .title = .{ .fixed = "Settings" }, .build = buildNavHome },
            .{ .name = "explore", .title = .{ .fixed = "Explore" }, .build = buildNavHome },
            .{ .name = "subs", .title = .{ .fixed = "Subscriptions" }, .build = buildNavHome },
        },
        .services = .mocks(),
    });
    defer app.deinit();
    try app.setNav(&.{
        .{ .route = "library", .icon = .library },
        .{ .route = "settings", .icon = .settings },
        .{ .route = "explore", .icon = .compass },
        .{ .route = "subs", .icon = .user },
    });
    try app.navigate("settings");

    var snap = try snapshot(testing.allocator, &app);
    defer snap.deinit();

    try testing.expectEqual(A11yRole.navigation, snap.nodes.items[1].role);
    const chip = snap.nodes.items[2];
    // A combo box, not a link: pressing it opens a list rather than
    // going anywhere, and the name it is announced by does not move.
    try testing.expectEqual(A11yRole.combo_box, chip.role);
    try testing.expectEqualStrings("Section", chip.label);
    try testing.expectEqualStrings("Settings", chip.value);
    // One control stands for the whole landmark: the other three
    // destinations are behind the picker, not links to walk past.
    for (snap.nodes.items) |n| try testing.expect(n.role != .link);
}

test "the row's off-roster marker is static text, not a link" {
    var app = try App.init(testing.allocator, .{
        .viewport = .{ .w = 900, .h = 400 },
        .routes = &.{
            .{ .name = "home", .title = .{ .fixed = "Home" }, .build = buildNavHome },
            .{ .name = "settings", .title = .{ .fixed = "Settings" }, .build = buildNavHome },
            .{ .name = "terms", .title = .{ .fixed = "Terms of Service" }, .build = buildNavHome },
        },
        .services = .mocks(),
    });
    defer app.deinit();
    try app.setNav(&.{
        .{ .route = "home", .icon = .house },
        .{ .route = "settings", .icon = .settings },
    });
    try app.navigate("terms");

    var snap = try snapshot(testing.allocator, &app);
    defer snap.deinit();

    // Two destinations, then the screen that is neither.
    try testing.expectEqual(A11yRole.navigation, snap.nodes.items[1].role);
    try testing.expectEqual(A11yRole.link, snap.nodes.items[2].role);
    try testing.expectEqual(A11yRole.link, snap.nodes.items[3].role);
    const here = snap.nodes.items[4];
    // Announcing it as a link would promise a press that goes nowhere;
    // the name is the framework's and the title is its value, which is
    // the split the collapsed chip makes.
    try testing.expectEqual(A11yRole.static_text, here.role);
    try testing.expectEqualStrings("Current screen", here.label);
    try testing.expectEqualStrings("Terms of Service", here.value);
    try testing.expect(!here.focusable);
    // And neither destination claims to be the current one.
    try testing.expectEqual(@as(?bool, false), snap.nodes.items[2].selected);
    try testing.expectEqual(@as(?bool, false), snap.nodes.items[3].selected);
}

test "segmented maps to a radio group carrying the selected option" {
    var app = try test_app.init(400, 400);
    defer app.deinit();
    const seg = try app.tree.appendId(app.tree.rootId(), .{ .segmented = .{
        .label = "View",
        .options = &.{ "List", "Grid" },
        .selected = 1,
    } });

    var snap = try snapshot(testing.allocator, &app);
    defer snap.deinit();

    const n = snap.find(seg).?;
    try testing.expectEqual(A11yRole.radio_group, n.role);
    try testing.expectEqualStrings("View", n.label);
    try testing.expectEqualStrings("Grid", n.value);
    try testing.expect(n.focusable);
}

test "radio_group maps to a radio group carrying the selected option" {
    var app = try test_app.init(400, 400);
    defer app.deinit();
    const rg = try app.tree.appendId(app.tree.rootId(), .{ .radio_group = .{
        .label = "Delivery",
        .options = &.{ "Email", "SMS" },
        .selected = 1,
    } });

    var snap = try snapshot(testing.allocator, &app);
    defer snap.deinit();

    const n = snap.find(rg).?;
    try testing.expectEqual(A11yRole.radio_group, n.role);
    try testing.expectEqualStrings("Delivery", n.label);
    try testing.expectEqualStrings("SMS", n.value);
    try testing.expect(n.focusable);
}

test "text area maps to a multiline text field carrying its value" {
    var app = try test_app.init(400, 400);
    defer app.deinit();
    const ta = try app.tree.appendId(app.tree.rootId(), .{ .text_area = .{
        .label = "Notes",
        .value = "a\nb",
    } });

    var snap = try snapshot(testing.allocator, &app);
    defer snap.deinit();

    const n = snap.find(ta).?;
    try testing.expectEqual(A11yRole.multiline_text_field, n.role);
    try testing.expectEqualStrings("Notes", n.label);
    try testing.expectEqualStrings("a\nb", n.value);
    try testing.expect(n.focusable);
}

test "obscured input is a password field and never exposes its value" {
    var app = try test_app.init(400, 400);
    defer app.deinit();
    const pw = try app.tree.appendId(app.tree.rootId(), .{ .text_input = .{
        .label = "Passphrase",
        .value = "hunter2",
        .obscured = true,
    } });

    var snap = try snapshot(testing.allocator, &app);
    defer snap.deinit();

    const n = snap.find(pw).?;
    try testing.expectEqual(A11yRole.password_field, n.role);
    try testing.expectEqualStrings("Passphrase", n.label);
    try testing.expectEqualStrings("", n.value);
    try testing.expect(n.focusable);
}

test "a field's problem is its description, and lights invalid on both fields" {
    var app = try test_app.init(400, 400);
    defer app.deinit();
    const email = try app.tree.appendId(app.tree.rootId(), .{ .text_input = .{
        .label = "Email",
        .value = "not-an-address",
        .problem = "That is not an email address.",
    } });
    const notes = try app.tree.appendId(app.tree.rootId(), .{ .text_area = .{
        .label = "Notes",
        .value = "hi",
        .problem = "Say a little more than that.",
    } });
    const ok = try app.tree.appendId(app.tree.rootId(), .{ .text_input = .{ .label = "City" } });

    var snap = try snapshot(testing.allocator, &app);
    defer snap.deinit();

    const e = snap.find(email).?;
    try testing.expect(e.invalid);
    try testing.expectEqualStrings("That is not an email address.", e.description);
    // Name and value are untouched: the reason is a third thing, read
    // after both, never spliced into either.
    try testing.expectEqualStrings("Email", e.label);
    try testing.expectEqualStrings("not-an-address", e.value);
    // And it is not disabled — the field still takes input, which is
    // the whole difference from the busy pair.
    try testing.expect(!e.disabled);
    try testing.expect(!e.busy);

    const n = snap.find(notes).?;
    try testing.expect(n.invalid);
    try testing.expectEqualStrings("Say a little more than that.", n.description);

    const c = snap.find(ok).?;
    try testing.expect(!c.invalid);
    try testing.expectEqualStrings("", c.description);
}

test "an obscured field withholds its value and not its reason" {
    var app = try test_app.init(400, 400);
    defer app.deinit();
    const pw = try app.tree.appendId(app.tree.rootId(), .{ .text_input = .{
        .label = "Passphrase",
        .value = "hunter2",
        .obscured = true,
        .problem = "Too short by four characters.",
    } });

    var snap = try snapshot(testing.allocator, &app);
    defer snap.deinit();

    const n = snap.find(pw).?;
    try testing.expectEqualStrings("", n.value);
    // The secret is what was typed, never why it was refused: a
    // password field that cannot say what is wrong is one nobody can
    // fill in without sight of the screen.
    try testing.expect(n.invalid);
    try testing.expectEqualStrings("Too short by four characters.", n.description);
}

test "copyable maps to a button carrying the value it copies" {
    var app = try test_app.init(400, 400);
    defer app.deinit();
    const c = try app.tree.appendId(app.tree.rootId(), .{ .copyable = .{
        .label = "Recovery code",
        .value = "XKCD-1234",
    } });

    var snap = try snapshot(testing.allocator, &app);
    defer snap.deinit();

    const n = snap.find(c).?;
    try testing.expectEqual(A11yRole.button, n.role);
    try testing.expectEqualStrings("Recovery code", n.label);
    try testing.expectEqualStrings("XKCD-1234", n.value);
    try testing.expect(n.focusable);
}

test "an acknowledged copyable gains a status child announcing the copy" {
    var app = try test_app.init(400, 400);
    defer app.deinit();
    const c = try app.tree.appendId(app.tree.rootId(), .{ .copyable = .{
        .label = "Recovery code",
        .value = "XKCD-1234",
    } });
    app.performLayout();

    {
        var snap = try snapshot(testing.allocator, &app);
        defer snap.deinit();
        try testing.expect(snap.findByLabel("Copied") == null);
    }

    try app.tap(app.tree.rectOf(c).center());
    var snap = try snapshot(testing.allocator, &app);
    defer snap.deinit();

    // A check appearing in the field is a state change with no words;
    // the live region is where the words are.
    const ack = snap.findByLabel("Copied").?;
    try testing.expectEqual(A11yRole.status, ack.role);
    try testing.expect(ack.derived);
    try testing.expect(!ack.focusable);
    // A child of the field it belongs to, and the field itself is
    // untouched: the value an assistive-tech user reads back to check
    // what they copied must not move.
    const field = snap.find(c).?;
    try testing.expectEqual(A11yRole.button, field.role);
    try testing.expectEqualStrings("Recovery code", field.label);
    try testing.expectEqualStrings("XKCD-1234", field.value);
    try testing.expectEqual(snap.nodes.items[ack.parent.?].id, c);

    // It leaves with the mark.
    try app.dispatch(.{ .key_down = .{ .key = .tab } });
    var after = try snapshot(testing.allocator, &app);
    defer after.deinit();
    try testing.expect(after.findByLabel("Copied") == null);
}

test "tiles map to links or buttons; the group is a group" {
    var app = try test_app.init(400, 400);
    defer app.deinit();
    const group = try app.tree.appendId(app.tree.rootId(), .{ .tile_group = .{ .description = "Account actions" } });
    const nav_tile = try app.tree.appendId(group, .{ .tile = .{ .label = "Members", .route = "members" } });
    const act_tile = try app.tree.appendId(group, .{ .tile = .{ .label = "Sign out", .detail = "Ends the session", .on_press = .{ .call = noopPress } } });

    var snap = try snapshot(testing.allocator, &app);
    defer snap.deinit();

    try testing.expectEqual(A11yRole.group, snap.find(group).?.role);
    // The description rides on the group like a tile's detail on the tile.
    try testing.expectEqualStrings("Account actions", snap.find(group).?.value);
    const nv = snap.find(nav_tile).?;
    try testing.expectEqual(A11yRole.link, nv.role);
    try testing.expect(nv.focusable);
    const ac = snap.find(act_tile).?;
    try testing.expectEqual(A11yRole.button, ac.role);
    try testing.expectEqualStrings("Ends the session", ac.value);
}

test "a tile's leading mark stands down for the label" {
    var app = try test_app.init(400, 400);
    defer app.deinit();
    const group = try app.tree.appendId(app.tree.rootId(), .{ .tile_group = .{} });
    const row = try app.tree.appendId(group, .{ .tile = .{ .label = "Members", .route = "members", .icon = .users } });

    var snap = try snapshot(testing.allocator, &app);
    defer snap.deinit();

    // The mark is a field, not a node, so there is nothing in the tree
    // for it to be announced from — the row is one node saying one name,
    // the same standing-down `Notice.icon` does for its title and the
    // standalone `icon` element does with an empty label.
    const nv = snap.find(row).?;
    try testing.expectEqualStrings("Members", nv.label);
    try testing.expectEqual(A11yRole.link, nv.role);
    for (snap.nodes.items) |n| try testing.expect(n.role != .image);

    // Same node count as the row without one: the glyph adds nothing an
    // adapter could read out beside the label it already read.
    var bare = try test_app.init(400, 400);
    defer bare.deinit();
    const bare_group = try bare.tree.appendId(bare.tree.rootId(), .{ .tile_group = .{} });
    try bare.tree.append(bare_group, .{ .tile = .{ .label = "Members", .route = "members" } });
    var bare_snap = try snapshot(testing.allocator, &bare);
    defer bare_snap.deinit();
    try testing.expectEqual(bare_snap.nodes.items.len, snap.nodes.items.len);
}

test "a list maps to list/listitem and never announces its own marker" {
    var app = try test_app.init(400, 400);
    defer app.deinit();
    const list = try app.tree.appendId(app.tree.rootId(), .{ .list = .{ .ordered = true } });
    const item = try app.tree.appendId(list, .{ .list_item = .{} });
    const words = try app.tree.appendId(item, .{ .text = .{ .content = "Rinse" } });

    var snap = try snapshot(testing.allocator, &app);
    defer snap.deinit();

    try testing.expectEqual(A11yRole.list, snap.find(list).?.role);
    const li = snap.find(item).?;
    try testing.expectEqual(A11yRole.list_item, li.role);
    try testing.expect(!li.focusable);
    // Assistive tech renders positions itself from the structure. The
    // derived "1." is presentation, so it stays out of both the item's
    // label and its value — announcing it would double the ordinal.
    try testing.expectEqualStrings("", li.label);
    try testing.expectEqualStrings("", li.value);
    try testing.expectEqualStrings("1.", app.tree.getConst(item).?.list_item.marker());
    try testing.expectEqualStrings("Rinse", snap.find(words).?.label);
}

test "a code block is announced whole; a blockquote wraps what it quotes" {
    var app = try test_app.init(400, 400);
    defer app.deinit();
    const cb = try app.tree.appendId(app.tree.rootId(), .{ .code_block = .{ .content = "fn a() {}\nfn b() {}" } });
    const quote = try app.tree.appendId(app.tree.rootId(), .{ .blockquote = .{} });
    const cited = try app.tree.appendId(quote, .{ .text = .{ .content = "— Ada" } });

    var snap = try snapshot(testing.allocator, &app);
    defer snap.deinit();

    const code = snap.find(cb).?;
    try testing.expectEqual(A11yRole.code, code.role);
    // One node carrying every line, newline included: a verbatim block
    // is read out, not walked.
    try testing.expectEqualStrings("fn a() {}\nfn b() {}", code.label);
    // It scrolls, so it is reachable; it does not activate.
    try testing.expect(code.focusable);

    try testing.expectEqual(A11yRole.blockquote, snap.find(quote).?.role);
    // The attribution is words inside the quote, not a field on it.
    try testing.expectEqualStrings("— Ada", snap.find(cited).?.label);
}

test "styling spans stay invisible; a link span becomes a link node" {
    var app = try test_app.init(400, 400);
    defer app.deinit();
    const para = try app.tree.appendId(app.tree.rootId(), .{ .text = .{ .spans = &.{
        .{ .text = "Read the ", .route = "" },
        .{ .text = "terms", .route = "terms" },
        .{ .text = " and the " },
        .{ .text = "policy", .route = "policy", .strong = true },
        .{ .text = " before you sign." },
    } } });
    app.focused = .{ .node = para, .span = 3 };

    var snap = try snapshot(testing.allocator, &app);
    defer snap.deinit();

    // The paragraph still announces its full words as one text node —
    // the styling on "policy" is invisible, as ever.
    const p = snap.find(para).?;
    try testing.expectEqual(A11yRole.static_text, p.role);
    try testing.expectEqualStrings("Read the terms and the policy before you sign.", p.label);
    try testing.expect(!p.focusable);

    // The links are the carve-out: a link nobody can hear is worse than
    // no link at all, so each gets its own node under the paragraph.
    const terms = snap.findSpan(para, 1).?;
    try testing.expectEqual(A11yRole.link, terms.role);
    try testing.expectEqualStrings("terms", terms.label);
    try testing.expect(terms.focusable);
    try testing.expect(!terms.focused);
    // Both hang off the paragraph, the way an `<a>` hangs off its `<p>`.
    const para_index = for (snap.nodes.items, 0..) |n, i| {
        if (n.id.eql(para) and n.span == null) break i;
    } else unreachable;
    try testing.expectEqual(@as(?usize, para_index), terms.parent);

    const policy = snap.findSpan(para, 3).?;
    try testing.expectEqual(@as(?usize, para_index), policy.parent);
    try testing.expectEqualStrings("policy", policy.label);
    try testing.expect(policy.focused);
    // Its rect is the link's own ink, not the paragraph's block.
    try testing.expect(policy.rect.w < p.rect.w);
    try testing.expect(!policy.rect.isEmpty());

    // A merely styled run contributes nothing — and neither does the
    // first, which spells its routelessness out (`.route = ""`, the one
    // spelling of "no route" — `Span.route`).
    try testing.expectEqual(@as(?*const A11yNode, null), snap.findSpan(para, 0));
    try testing.expectEqual(@as(?*const A11yNode, null), snap.findSpan(para, 4));
}

test "an external link span is announced exactly as a routed one: a link, activatable" {
    var app = try test_app.init(400, 400);
    defer app.deinit();
    const para = try app.tree.appendId(app.tree.rootId(), .{ .text = .{ .spans = &.{
        .{ .text = "Mail " },
        .{ .text = "us", .external = "mailto:help@example.com" },
        .{ .text = "." },
    } } });

    var snap = try snapshot(testing.allocator, &app);
    defer snap.deinit();

    // Where the press goes is the press's business; to assistive tech
    // this is a link inside the paragraph, same role, same focus stop,
    // same click action as a routed span.
    const us = snap.findSpan(para, 1).?;
    try testing.expectEqual(A11yRole.link, us.role);
    try testing.expectEqualStrings("us", us.label);
    try testing.expect(us.focusable);
    try testing.expect(us.activatable);
}

test "a document is a named landmark over ordinary parsed elements" {
    var app = try test_app.init(400, 600);
    defer app.deinit();
    const doc = try app.tree.appendId(app.tree.rootId(), .{ .document = .{
        .label = "Terms of Service",
        .source =
        \\## Your data
        \\
        \\We keep the [minimum](privacy).
        ,
    } });

    var snap = try snapshot(testing.allocator, &app);
    defer snap.deinit();

    const d = snap.find(doc).?;
    try testing.expectEqual(A11yRole.document, d.role);
    // Explicit, never derived: legal text often does not open with a
    // heading, so the first h1 is not a name.
    try testing.expectEqualStrings("Terms of Service", d.label);

    // Everything inside is an ordinary element — nothing in the a11y
    // tree knows Markdown was involved, and the rebased "## " is an h1.
    const heading = snap.findByLabel("Your data").?;
    try testing.expectEqual(A11yRole.heading, heading.role);
    try testing.expectEqual(@as(u8, 1), heading.heading_level);
    const link = snap.findByLabel("minimum").?;
    try testing.expectEqual(A11yRole.link, link.role);
    try testing.expect(link.focusable);
}

test "select maps to a combo box; its picker to a modal dialog of options" {
    var app = try test_app.init(400, 600);
    defer app.deinit();
    const sel = try app.tree.appendId(app.tree.rootId(), .{ .select = .{
        .label = "Language",
        .options = &.{ "English", "Deutsch" },
        .selected = 1,
    } });
    {
        var snap = try snapshot(testing.allocator, &app);
        defer snap.deinit();
        const n = snap.find(sel).?;
        try testing.expectEqual(A11yRole.combo_box, n.role);
        try testing.expectEqualStrings("Language", n.label);
        try testing.expectEqualStrings("Deutsch", n.value);
        try testing.expect(n.focusable);
    }

    app.focused = .of(sel);
    try app.dispatch(.{ .key_down = .{ .key = .enter } });
    {
        var snap = try snapshot(testing.allocator, &app);
        defer snap.deinit();
        const picker = layout.findPicker(&app.tree).?;
        const dialog = snap.find(picker).?;
        try testing.expectEqual(A11yRole.dialog, dialog.role);
        try testing.expectEqualStrings("Language", dialog.label);
        try testing.expect(dialog.modal);

        var region_it = app.tree.children(picker);
        const region = region_it.next().?;
        var it = app.tree.children(region);
        const first = snap.find(it.next().?).?;
        try testing.expectEqual(A11yRole.option, first.role);
        try testing.expectEqualStrings("English", first.label);
        try testing.expectEqual(@as(?bool, false), first.selected);
        const second = snap.find(it.next().?).?;
        try testing.expectEqual(@as(?bool, true), second.selected);
    }
}

test "a select and its options carry the click action when enabled" {
    // The bridge only grants the CLICK action to clickable nodes, so
    // clickable must track Element.isInteractive: a combo box or an
    // option that is focusable but never activatable is a dead end for
    // assistive tech.
    var app = try test_app.init(400, 600);
    defer app.deinit();
    const sel = try app.tree.appendId(app.tree.rootId(), .{ .select = .{
        .label = "Language",
        .options = &.{ "English", "Deutsch" },
    } });
    {
        var snap = try semantics.snapshot(testing.allocator, &app);
        defer snap.deinit();
        var out: std.ArrayList(accesskit.CNode) = .empty;
        defer out.deinit(testing.allocator);
        _ = try accesskit.flatten(&snap, testing.allocator, &out);
        var found = false;
        for (out.items) |c| {
            if (c.id != accesskit.nodeIdU64(sel)) continue;
            found = true;
            try testing.expectEqual(@as(u8, 1), c.clickable);
        }
        try testing.expect(found);
    }

    app.focused = .of(sel);
    try app.dispatch(.{ .key_down = .{ .key = .enter } });
    {
        var snap = try semantics.snapshot(testing.allocator, &app);
        defer snap.deinit();
        var out: std.ArrayList(accesskit.CNode) = .empty;
        defer out.deinit(testing.allocator);
        _ = try accesskit.flatten(&snap, testing.allocator, &out);
        var options: usize = 0;
        for (out.items, snap.nodes.items) |c, n| {
            if (n.role != .option) continue;
            options += 1;
            try testing.expectEqual(@as(u8, 1), c.clickable);
        }
        try testing.expectEqual(@as(usize, 2), options);
    }
}

/// Snapshots `app`, flattens it, and asserts the derivation invariant:
/// every element node's bridge click action is exactly its element's
/// `isInteractive()`, a link span's is always set, a derived node's
/// never. Marks each element role encountered in `seen`.
fn expectClickTracksInteractive(app: *App, seen: *std.EnumSet(element_mod.Role)) !void {
    var snap = try semantics.snapshot(testing.allocator, app);
    defer snap.deinit();
    var out: std.ArrayList(accesskit.CNode) = .empty;
    defer out.deinit(testing.allocator);
    _ = try accesskit.flatten(&snap, testing.allocator, &out);
    try testing.expectEqual(snap.nodes.items.len, out.items.len);
    for (snap.nodes.items, out.items) |n, c| {
        if (n.span != null) {
            try testing.expectEqual(@as(u8, 1), c.clickable);
            continue;
        }
        if (n.derived) {
            try testing.expectEqual(@as(u8, 0), c.clickable);
            continue;
        }
        const el = app.tree.getConst(n.id).?;
        seen.insert(el.role());
        try testing.expectEqual(@intFromBool(el.isInteractive()), c.clickable);
    }
}

test "the click action is Element.isInteractive, for every element kind" {
    // The bridge carries no role list of its own — `clickable` is the
    // element model's `isInteractive`, mirrored. This walks one of every
    // element kind (plus the disabled and in-progress button states)
    // through snapshot and flatten, and the closing roster check makes a
    // new element kind fail here until it is added — the drift this
    // derivation exists to end.
    var seen = std.EnumSet(element_mod.Role).initEmpty();

    {
        var app = try test_app.init(600, 4000);
        defer app.deinit();
        const root = app.tree.rootId();
        try app.tree.append(root, .{ .text = .{ .content = "Prose" } });
        try app.tree.append(root, .{ .text = .{ .spans = &.{
            .{ .text = "See " },
            .{ .text = "the terms", .route = "home" },
        } } });
        try app.tree.append(root, .{ .heading = .{ .content = "Title" } });
        try app.tree.append(root, .{ .icon = .{ .name = .activity, .label = "Live" } });
        const box = try app.tree.appendId(root, .{ .box = .{} });
        try app.tree.append(box, .{ .divider = .{} });
        try app.tree.append(root, .{ .badge = .{ .label = "Beta" } });
        try app.tree.append(root, .{ .meter = .{ .label = "12 of 30 days", .value = 12, .max = 30 } });
        try app.tree.append(root, .{ .qr = .{ .label = "Invite", .value = "https://example.test/i" } });
        const stack = try app.tree.appendId(root, .{ .stack = .{} });
        try app.tree.append(stack, .{ .button = .{ .label = "Go" } });
        try app.tree.append(root, .{ .button = .{ .label = "Gone", .disabled = true } });
        try app.tree.append(root, .{ .button = .{ .label = "Working", .in_progress = true } });
        try app.tree.append(root, .{ .link = .{ .label = "Terms", .route = "home" } });
        try app.tree.append(root, .{ .toggle = .{ .label = "Dark ink" } });
        try app.tree.append(root, .{ .checkbox = .{ .label = "I agree" } });
        try app.tree.append(root, .{ .text_input = .{ .label = "Name" } });
        try app.tree.append(root, .{ .text_input = .{ .label = "Passphrase", .obscured = true } });
        try app.tree.append(root, .{ .text_area = .{ .label = "Notes" } });
        const list = try app.tree.appendId(root, .{ .list = .{} });
        const item = try app.tree.appendId(list, .{ .list_item = .{} });
        try app.tree.append(item, .{ .text = .{ .content = "One" } });
        try app.tree.append(root, .{ .code_block = .{ .content = "zig build" } });
        const quote = try app.tree.appendId(root, .{ .blockquote = .{} });
        try app.tree.append(quote, .{ .text = .{ .content = "Quoted" } });
        try app.tree.append(root, .{ .document = .{ .label = "Terms", .source = "Some *prose*." } });
        const table = try app.tree.appendId(root, .{ .table = .{} });
        const row = try app.tree.appendId(table, .{ .row = .{} });
        try app.tree.append(row, .{ .cell = .{} });
        try app.tree.append(root, .{ .scroll_region = .{ .height = 80 } });
        try app.tree.append(root, .{ .segmented = .{ .label = "View", .options = &.{ "Day", "Week" } } });
        const tiles = try app.tree.appendId(root, .{ .tile_group = .{ .description = "Places" } });
        try app.tree.append(tiles, .{ .tile = .{ .label = "Berlin", .route = "home" } });
        try app.tree.append(tiles, .{ .tile = .{ .label = "Rename", .on_press = .{ .call = noopPress } } });
        try app.tree.append(root, .{ .radio_group = .{ .label = "Plan", .options = &.{ "Free", "Pro" } } });
        try app.tree.append(root, .{ .select = .{ .label = "Language", .options = &.{ "English", "Deutsch" } } });
        try app.tree.append(root, .{ .copyable = .{ .label = "Recovery code", .value = "XKCD-1234" } });
        const nav = try app.tree.appendId(root, .{ .nav = .{} });
        try app.tree.append(nav, .{ .nav_item = .{ .label = "Home", .route = "home", .icon = .house } });
        try app.tree.append(nav, .{ .nav_here = .{ .value = "Detail" } });
        try app.tree.append(root, .{ .back = .{} });
        // A row too wide to fit: layout folds its tail and installs the
        // `more` control — the only way a real tree ever holds one.
        const action_row = try app.tree.appendId(root, .{ .stack = .{ .axis = .horizontal } });
        try app.tree.append(action_row, .{ .button = .{ .label = "Download the yearly report" } });
        try app.tree.append(action_row, .{ .button = .{ .label = "Share with the whole team" } });
        try app.tree.append(action_row, .{ .button = .{ .label = "Archive every closed item" } });
        try app.tree.append(action_row, .{ .button = .{ .label = "Export as a printable file" } });
        try app.tree.append(root, .{ .icon_button = .{ .glyph = .expand, .label = "Show notices" } });
        try expectClickTracksInteractive(&app, &seen);
    }

    {
        // The picker and its rows come from the one path that installs
        // them: activating a select.
        var app = try test_app.init(400, 600);
        defer app.deinit();
        const sel = try app.tree.appendId(app.tree.rootId(), .{ .select = .{
            .label = "Language",
            .options = &.{ "English", "Deutsch" },
        } });
        // The collapsed nav chip rides along here: a tree holds one nav,
        // and the first app's already wears the row shape.
        const collapsed = try app.tree.appendId(app.tree.rootId(), .{ .nav = .{} });
        try app.tree.append(collapsed, .{ .nav_current = .{ .section = "Home", .icon = .house } });
        app.focused = .of(sel);
        try app.dispatch(.{ .key_down = .{ .key = .enter } });
        try expectClickTracksInteractive(&app, &seen);
    }

    {
        // Sheet, notice, and the notices pane come from their installers
        // too.
        var app = try test_app.init(400, 600);
        defer app.deinit();
        _ = try app.presentSheet("Options");
        app.notify(.{ .title = "Sync failed", .route = "home", .important = true });
        try expectClickTracksInteractive(&app, &seen);
        app.dismissSheet();
        try app.openNoticesPane();
        try expectClickTracksInteractive(&app, &seen);
    }

    inline for (@typeInfo(element_mod.Role).@"enum".fields) |f| {
        if (!seen.contains(@field(element_mod.Role, f.name))) {
            std.debug.print("element kind not walked by the invariant test: {s}\n", .{f.name});
            return error.TestUnexpectedResult;
        }
    }
}

test "sheet and notices pane map to modal dialogs; notices are status" {
    var app = try test_app.init(400, 600);
    defer app.deinit();
    const sheet = try app.presentSheet("Options");
    {
        var snap = try snapshot(testing.allocator, &app);
        defer snap.deinit();
        const dialog = snap.find(sheet).?;
        try testing.expectEqual(A11yRole.dialog, dialog.role);
        try testing.expectEqualStrings("Options", dialog.label);
        try testing.expect(dialog.modal);
    }

    app.dismissSheet();
    app.notify(.{ .title = "Sync failed", .route = "home", .important = true });
    {
        var snap = try snapshot(testing.allocator, &app);
        defer snap.deinit();
        const banner = snap.find(layout.findNotice(&app.tree).?).?;
        try testing.expectEqual(A11yRole.status, banner.role);
        try testing.expectEqualStrings("Sync failed", banner.label);
        try testing.expect(!banner.modal);
    }

    try app.openNoticesPane();
    {
        var snap = try snapshot(testing.allocator, &app);
        defer snap.deinit();
        const pane = snap.find(layout.findNoticesPane(&app.tree).?).?;
        try testing.expectEqual(A11yRole.dialog, pane.role);
        try testing.expect(pane.modal);
    }
}

test "spans are invisible: one static_text node announcing the concatenation" {
    var app = try test_app.init(400, 400);
    defer app.deinit();
    try app.tree.append(app.tree.rootId(), .{ .text = .{ .spans = &.{
        .{ .text = "Rokovski " },
        .{ .text = "Feedback", .strong = true },
    } } });

    var snap = try snapshot(testing.allocator, &app);
    defer snap.deinit();

    // Document root plus exactly one text node — span boundaries add nothing.
    try testing.expectEqual(@as(usize, 2), snap.nodes.items.len);
    try testing.expectEqual(A11yRole.static_text, snap.nodes.items[1].role);
    try testing.expectEqualStrings("Rokovski Feedback", snap.nodes.items[1].label);
}

test "a folded button is absent; the control standing in for it is a button" {
    var app = try test_app.init(400, 400);
    defer app.deinit();
    const row = try app.tree.appendId(app.tree.rootId(), .{ .stack = .{ .axis = .horizontal, .gap = 8 } });
    for ([_][]const u8{ "One", "Two", "Three", "Four", "Five" }) |label| {
        try app.tree.append(row, .{ .button = .{ .label = label } });
    }

    var snap = try snapshot(testing.allocator, &app);
    defer snap.deinit();

    // Three fit; "Four" gave up its slot and "Five" never had one. What
    // is announced is what is there — nothing names a control that no
    // press could reach (overflow.zig).
    try testing.expect(snap.findByLabel("Three") != null);
    try testing.expect(snap.findByLabel("Four") == null);
    try testing.expect(snap.findByLabel("Five") == null);

    const more = snap.findByLabel("More") orelse return error.NoMoreControl;
    try testing.expectEqual(A11yRole.button, more.role);
    try testing.expect(more.focusable);
    try testing.expect(!more.disabled);

    // Pressing it puts them back, in a dialog, as the buttons they are.
    var it = app.tree.children(row);
    var more_id = it.next().?;
    while (it.next()) |c| more_id = c;
    try app.activate(more_id);
    var opened = try snapshot(testing.allocator, &app);
    defer opened.deinit();
    // The dialog wears the control's name, the way a menu wears its
    // button's — so it is found by role, not by looking the name up
    // twice.
    var dialog: ?*const A11yNode = null;
    for (opened.nodes.items) |*n| {
        if (n.role == .dialog) dialog = n;
    }
    try testing.expect(dialog.?.modal);
    try testing.expectEqualStrings("More", dialog.?.label);
    try testing.expectEqual(A11yRole.button, opened.findByLabel("Five").?.role);
}

test "wrapping a row changes no part of what is announced" {
    // Wrapping is where marks land, not what is said. The proof is the
    // snapshot taken twice — once on a row that fits, once on the same
    // row narrowed until it takes three lines — compared field by field
    // with the rect deliberately left out, because the rect is the only
    // thing that is *supposed* to move.
    var app = try test_app.init(600, 400);
    defer app.deinit();
    const row = try app.tree.appendId(app.tree.rootId(), .{ .stack = .{ .axis = .horizontal, .gap = 8 } });
    for ([_][]const u8{ "Admin", "Until cycle end", "Held for review" }) |label| {
        try app.tree.append(row, .{ .badge = .{ .label = label } });
    }

    var wide = try snapshot(testing.allocator, &app);
    defer wide.deinit();

    app.setViewport(.{ .w = 200, .h = 400 });
    var narrow = try snapshot(testing.allocator, &app);
    defer narrow.deinit();

    // It did wrap: three chips, three lines.
    var ys: [3]i32 = undefined;
    var it = app.tree.children(row);
    for (&ys) |*slot| slot.* = app.tree.rectOf(it.next().?).y;
    try testing.expect(ys[0] < ys[1] and ys[1] < ys[2]);

    try testing.expectEqual(wide.nodes.items.len, narrow.nodes.items.len);
    for (wide.nodes.items, narrow.nodes.items) |a, b| {
        var stripped_a = a;
        var stripped_b = b;
        stripped_a.rect = .zero;
        stripped_b.rect = .zero;
        try testing.expectEqualStrings(a.label, b.label);
        try testing.expectEqualDeep(stripped_a, stripped_b);
    }
}
