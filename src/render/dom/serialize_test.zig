//! The DOM edition's conformance tests.
//!
//! A pixel golden cannot apply to a non-reference edition
//! ([renderer-editions.md](../../../docs/internals/renderer-editions.md)),
//! so this is the **renderer contract** instead: per element, what must
//! be conveyed. Role, label, state, and place in the focus order — the
//! things that live on the tree and therefore hold whatever draws it.
//!
//! Two properties get asserted about the walk as a whole, and they are
//! the ones that replace the screenshot: the output is deterministic
//! (two runs over one tree are byte-identical, so a review is a text
//! diff), and every byte a consumer wrote is escaped on the way out.

const std = @import("std");

const app_mod = @import("../../core/app.zig");
const element_mod = @import("../../core/element.zig");
const semantics = @import("../../a11y/semantics.zig");
const serialize = @import("serialize.zig");
const stylesheet = @import("stylesheet.zig");
const test_app = @import("../../core/test_app.zig");
const tree_mod = @import("../../core/tree.zig");

const App = app_mod.App;
const NodeId = tree_mod.NodeId;
const testing = std.testing;

/// The screen, as markup. The caller frees.
fn render(app: *App) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(testing.allocator);
    var em: serialize.Emitter = .{ .gpa = testing.allocator, .app = app, .out = &out };
    defer em.deinit();
    try serialize.content(&em);
    return out.toOwnedSlice(testing.allocator);
}

/// The chrome the framework installed, as markup. The caller frees.
fn renderChrome(app: *App) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(testing.allocator);
    var em: serialize.Emitter = .{ .gpa = testing.allocator, .app = app, .out = &out };
    defer em.deinit();
    try serialize.chrome(&em);
    return out.toOwnedSlice(testing.allocator);
}

fn expectContains(haystack: []const u8, needle: []const u8) !void {
    if (std.mem.indexOf(u8, haystack, needle) == null) {
        std.debug.print("expected to find:\n  {s}\nin:\n  {s}\n", .{ needle, haystack });
        return error.TestExpectedContains;
    }
}

fn expectLacks(haystack: []const u8, needle: []const u8) !void {
    if (std.mem.indexOf(u8, haystack, needle) != null) {
        std.debug.print("expected NOT to find:\n  {s}\nin:\n  {s}\n", .{ needle, haystack });
        return error.TestExpectedLacks;
    }
}

// ---------------------------------------------------------- the shape

test "the root's children come through in tree order" {
    var app = try test_app.init(400, 400);
    defer app.deinit();
    const root = app.tree.rootId();
    _ = try app.tree.append(root, .{ .heading = .{ .content = "Notes", .level = .h1 } });
    _ = try app.tree.append(root, .{ .text = .{ .content = "One" } });
    _ = try app.tree.append(root, .{ .divider = .{} });

    const html = try render(&app);
    defer testing.allocator.free(html);
    try testing.expectEqualStrings(
        "<h1 id=\"notes\">Notes</h1><p>One</p><hr>",
        html,
    );
}

test "the walk is deterministic: two runs over one tree are identical" {
    // What replaces the byte-exact screenshot. A reviewer reads a text
    // diff, and an empty one means nothing changed.
    var app = try test_app.init(400, 400);
    defer app.deinit();
    const root = app.tree.rootId();
    _ = try app.tree.append(root, .{ .heading = .{ .content = "Same", .level = .h1 } });
    _ = try app.tree.append(root, .{ .heading = .{ .content = "Same", .level = .h2 } });
    _ = try app.tree.append(root, .{ .button = .{ .label = "Go" } });

    const first = try render(&app);
    defer testing.allocator.free(first);
    const second = try render(&app);
    defer testing.allocator.free(second);
    try testing.expectEqualStrings(first, second);
    // …including the suffix a repeated heading takes, which is state
    // that must not leak between runs.
    try expectContains(first, "id=\"same\"");
    try expectContains(first, "id=\"same-1\"");
}

test "non-ASCII headings keep their words in the slug" {
    // GitHub's slug KEEPS Unicode word characters; dropping the bytes
    // would give every Persian heading the same "section" anchor.
    var app = try test_app.init(400, 400);
    defer app.deinit();
    const root = app.tree.rootId();
    _ = try app.tree.append(root, .{ .heading = .{ .content = "معرفی نکته", .level = .h1 } });
    _ = try app.tree.append(root, .{ .heading = .{ .content = "مقدمة", .level = .h2 } });
    // …but Unicode PUNCTUATION goes the way "&" does: GitHub slugs the
    // em dash out, and every TOC written against its anchors says so.
    _ = try app.tree.append(root, .{ .heading = .{ .content = "Part 1 — A project", .level = .h2 } });

    const html = try render(&app);
    defer testing.allocator.free(html);
    try expectContains(html, "<h1 id=\"معرفی-نکته\">");
    try expectContains(html, "<h2 id=\"مقدمة\">");
    try expectContains(html, "<h2 id=\"part-1--a-project\">");
    try expectLacks(html, "id=\"section\"");
}

test "two same-labeled choice groups get distinct radio names" {
    var app = try test_app.init(400, 400);
    defer app.deinit();
    const root = app.tree.rootId();
    const a = try app.tree.append(root, .{ .segmented = .{
        .label = "View",
        .options = &.{ "All", "Starred" },
    } });
    const b = try app.tree.append(root, .{ .segmented = .{
        .label = "View",
        .options = &.{ "All", "Starred" },
    } });

    const html = try render(&app);
    defer testing.allocator.free(html);
    // Checking a chip in one group must not uncheck the other on the
    // static page, so each group's inputs carry their own node id.
    var buf_a: [32]u8 = undefined;
    var buf_b: [32]u8 = undefined;
    const name_a = try std.fmt.bufPrint(&buf_a, "name=\"c{d}\"", .{@as(u32, @bitCast(a))});
    const name_b = try std.fmt.bufPrint(&buf_b, "name=\"c{d}\"", .{@as(u32, @bitCast(b))});
    try testing.expect(!std.mem.eql(u8, name_a, name_b));
    try expectContains(html, name_a);
    try expectContains(html, name_b);
}

test "consumer bytes are escaped, never interpreted" {
    // A `document` parses bytes the app did not write; everything else
    // takes strings it did. Neither may reach the page as markup.
    var app = try test_app.init(400, 400);
    defer app.deinit();
    _ = try app.tree.append(app.tree.rootId(), .{ .text = .{
        .content = "<script>alert(\"x\")</script> & 'more'",
    } });

    const html = try render(&app);
    defer testing.allocator.free(html);
    try expectLacks(html, "<script>");
    try expectContains(html, "&lt;script&gt;alert(&quot;x&quot;)&lt;/script&gt; &amp; &#39;more&#39;");
}

// --------------------------------------------------- per-element contract

test "static elements: the words are what is conveyed" {
    var app = try test_app.init(400, 400);
    defer app.deinit();
    const root = app.tree.rootId();
    _ = try app.tree.append(root, .{ .badge = .{ .label = "3 pending" } });
    _ = try app.tree.append(root, .{ .meter = .{ .label = "12 of 30 days", .value = 12, .max = 30 } });

    const html = try render(&app);
    defer testing.allocator.free(html);
    try expectContains(html, "<span class=\"badge\">3 pending</span>");
    // The label is announced; the bar only restates it, so the bar is
    // hidden and carries no role of its own.
    try expectContains(html, "12 of 30 days");
    try expectContains(html, "<div class=\"meter-track\" aria-hidden=\"true\">");
    // The share as the ratio the reference fills, not a rounded
    // hundredth of it: `drawMeter` divides against the track's real
    // width, so the division is written out rather than pre-computed.
    try expectContains(html, "width:calc(100% * 12 / 30)");
}

test "an icon with no label is decorative, and a named one is an image" {
    var app = try test_app.init(400, 400);
    defer app.deinit();
    const root = app.tree.rootId();
    _ = try app.tree.append(root, .{ .icon = .{ .name = .house } });
    _ = try app.tree.append(root, .{ .icon = .{ .name = .house, .label = "Home" } });

    const html = try render(&app);
    defer testing.allocator.free(html);
    try expectContains(html, "aria-hidden=\"true\">&#xE0F5;");
    try expectContains(html, "role=\"img\" aria-label=\"Home\">&#xE0F5;");
    // The codepoint is the enum's value: one place decides what a name
    // draws, and it is `IconName`.
    try testing.expectEqual(@as(u32, 0xE0F5), @intFromEnum(element_mod.IconName.house));
}

test "spans are Markdown's inline vocabulary, and a routed one is a link" {
    var app = try test_app.init(400, 400);
    defer app.deinit();
    _ = try app.tree.append(app.tree.rootId(), .{ .text = .{ .spans = &.{
        .{ .text = "Read the " },
        .{ .text = "terms", .strong = true },
        .{ .text = ", or the " },
        .{ .text = "policy", .route = "privacy" },
        .{ .text = "." },
    } } });

    const html = try render(&app);
    defer testing.allocator.free(html);
    try testing.expectEqualStrings(
        "<p>Read the <strong>terms</strong>, or the <a class=\"link\" href=\"#privacy\">policy</a>.</p>",
        html,
    );
}

test "an external link is a real anchor: new tab, opener severed, href escaped" {
    var app = try test_app.init(400, 400);
    defer app.deinit();
    // The query string carries an `&` on purpose: the URL goes through
    // the one attribute escape, so it must arrive as `&amp;`.
    _ = try app.tree.append(app.tree.rootId(), .{ .text = .{ .spans = &.{
        .{ .text = "Read the " },
        .{ .text = "full terms", .external = "https://example.com/terms?v=2&lang=en" },
        .{ .text = "." },
    } } });
    _ = try app.tree.append(app.tree.rootId(), .{ .link = .{
        .label = "Mail us",
        .external = "mailto:help@example.com",
    } });

    const html = try render(&app);
    defer testing.allocator.free(html);
    // Verbatim, never through Refs: an external URL is not a route
    // reference, and same-tab would tear the running app down.
    try expectContains(html, "<a class=\"link\" href=\"https://example.com/terms?v=2&amp;lang=en\"" ++
        " target=\"_blank\" rel=\"noopener noreferrer\">full terms</a>");
    try expectContains(html, "<a class=\"link block\" href=\"mailto:help@example.com\"" ++
        " target=\"_blank\" rel=\"noopener noreferrer\">Mail us</a>");
}

test "the default reference is the fragment the web shell mirrors routes into" {
    var app = try test_app.init(400, 400);
    defer app.deinit();
    _ = try app.tree.append(app.tree.rootId(), .{ .link = .{ .label = "Note", .route = "note~42" } });

    const html = try render(&app);
    defer testing.allocator.free(html);
    // Every byte a reference may carry is one encodeURIComponent leaves
    // alone, so what the router writes is what the markup carries.
    try expectContains(html, "href=\"#note~42\"");
}

test "a driver may resolve references its own way" {
    const Site = struct {
        fn write(_: ?*anyopaque, em: *serialize.Emitter, route: []const u8) anyerror!void {
            try em.raw("/");
            try em.text(route);
            try em.raw("/");
        }
    };
    var app = try test_app.init(400, 400);
    defer app.deinit();
    _ = try app.tree.append(app.tree.rootId(), .{ .link = .{ .label = "Docs", .route = "docs" } });

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    var em: serialize.Emitter = .{
        .gpa = testing.allocator,
        .app = &app,
        .out = &out,
        .options = .{ .refs = .{ .write = Site.write } },
    };
    defer em.deinit();
    try serialize.content(&em);
    try expectContains(out.items, "href=\"/docs/\"");
}

test "a tile with a route is a link; one with an action is a button" {
    var app = try test_app.init(400, 400);
    defer app.deinit();
    const group = try app.tree.append(app.tree.rootId(), .{ .tile_group = .{} });
    _ = try app.tree.append(group, .{ .tile = .{ .label = "Open", .route = "settings" } });
    _ = try app.tree.append(group, .{ .tile = .{ .label = "Act", .on_press = .{} } });

    const html = try render(&app);
    defer testing.allocator.free(html);
    try expectContains(html, "<a class=\"tile\" href=\"#settings\">");
    try expectContains(html, "<button type=\"button\" class=\"tile\">");
    // …the same split the snapshot makes, asked of the same function.
    try testing.expectEqual(
        semantics.A11yRole.link,
        semantics.roleOf(.{ .tile = .{ .label = "Open", .route = "settings" } }),
    );
    try testing.expectEqual(
        semantics.A11yRole.button,
        semantics.roleOf(.{ .tile = .{ .label = "Act" } }),
    );
}

test "stateful controls carry their state, not just their label" {
    var app = try test_app.init(400, 400);
    defer app.deinit();
    const root = app.tree.rootId();
    _ = try app.tree.append(root, .{ .toggle = .{ .label = "Sync", .on = true } });
    _ = try app.tree.append(root, .{ .checkbox = .{ .label = "Remember" } });
    const seg = try app.tree.append(root, .{ .segmented = .{
        .label = "View",
        .options = &.{ "All", "Starred" },
        .selected = 1,
    } });

    const html = try render(&app);
    defer testing.allocator.free(html);
    // A switch, announced on/off — the role the snapshot gives it.
    try expectContains(html, "class=\"toggle\" role=\"switch\" checked>");
    try expectContains(html, "class=\"check\"><span class=\"ctl-label\">Remember");
    // Radiogroup semantics, not tabs: there is deliberately no tablist.
    try expectContains(html, "<fieldset class=\"segmented\">");
    // The radio name comes from the node id, not the label: unique per
    // control, so two same-labeled groups never share a browser group.
    var radio_buf: [80]u8 = undefined;
    const radio = try std.fmt.bufPrint(
        &radio_buf,
        "<input type=\"radio\" name=\"c{d}\" checked><span>Starred</span>",
        .{@as(u32, @bitCast(seg))},
    );
    try expectContains(html, radio);
    try expectLacks(html, "name=\"View\"");
}

test "a track that overflows bleeds to the edge; one that fits does not" {
    var app = try test_app.init(400, 400);
    defer app.deinit();
    const root = app.tree.rootId();
    _ = try app.tree.append(root, .{ .segmented = .{
        .label = "View",
        .options = &.{ "All", "Starred" },
    } });
    _ = try app.tree.append(root, .{ .segmented = .{
        .label = "Month",
        .options = &.{ "January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December" },
    } });
    // Both halves of the question are layout's — the chips' measured
    // width against the column, and how far the advised margin
    // accumulated on the way down — so the markup carries an answer that
    // already exists rather than asking again in CSS, which could not
    // see either number.
    app.performLayout();

    const html = try render(&app);
    defer testing.allocator.free(html);
    try expectContains(html, "View</legend><div class=\"seg-track\">");
    var expected: [64]u8 = undefined;
    try expectContains(html, try std.fmt.bufPrint(
        &expected,
        "Month</legend><div class=\"seg-track bled\" style=\"--bleed:{d}px\">",
        .{tree_mod.root_stack.padding},
    ));
}

test "an obscured field is a password field, and its value is not the label" {
    var app = try test_app.init(400, 400);
    defer app.deinit();
    _ = try app.tree.append(app.tree.rootId(), .{ .text_input = .{
        .label = "Passphrase",
        .value = "hunter2",
        .obscured = true,
    } });

    const html = try render(&app);
    defer testing.allocator.free(html);
    try expectContains(html, "<input type=\"password\"");
    try expectContains(html, "<span class=\"field-label\">Passphrase</span>");
}

test "a folded action is not on the row; the more control stands there" {
    var app = try test_app.init(400, 400);
    defer app.deinit();
    const row = try app.tree.append(app.tree.rootId(), .{ .stack = .{ .axis = .horizontal } });
    _ = try app.tree.append(row, .{ .button = .{ .label = "Kept" } });
    _ = try app.tree.append(row, .{ .button = .{ .label = "Folded", .folded = true } });
    _ = try app.tree.append(row, .{ .more = .{} });

    const html = try render(&app);
    defer testing.allocator.free(html);
    try expectContains(html, ">Kept</button>");
    try expectLacks(html, "Folded");
    try expectContains(html, ">More</button>");
}

test "a list's marker is derived, so the markup carries none" {
    var app = try test_app.init(400, 400);
    defer app.deinit();
    const list = try app.tree.append(app.tree.rootId(), .{ .list = .{ .ordered = true, .start = 3 } });
    const item = try app.tree.append(list, .{ .list_item = .{} });
    _ = try app.tree.append(item, .{ .text = .{ .content = "Third" } });

    const html = try render(&app);
    defer testing.allocator.free(html);
    // `<ol start>` renders the ordinal the same way nokre does, from
    // the structure — so nokre's own derived marker never reaches the
    // page and assistive tech announces exactly one.
    // The gutter is layout's own `listGutter` — a measured width, so no
    // constant in the stylesheet could stand in for it.
    try testing.expectEqualStrings(
        "<ol class=\"list\" start=\"3\" style=\"--list-gutter:26px\"><li><p>Third</p></li></ol>",
        html,
    );
    try expectLacks(html, "3.");
}

test "a header row's cells are headers" {
    var app = try test_app.init(400, 400);
    defer app.deinit();
    const table = try app.tree.append(app.tree.rootId(), .{ .table = .{} });
    const head = try app.tree.append(table, .{ .row = .{ .header = true } });
    const hc = try app.tree.append(head, .{ .cell = .{} });
    _ = try app.tree.append(hc, .{ .text = .{ .content = "Platform" } });
    const body = try app.tree.append(table, .{ .row = .{} });
    const bc = try app.tree.append(body, .{ .cell = .{} });
    _ = try app.tree.append(bc, .{ .text = .{ .content = "macOS" } });

    const html = try render(&app);
    defer testing.allocator.free(html);
    try expectContains(html, "<th><p>Platform</p></th>");
    try expectContains(html, "<td><p>macOS</p></td>");
}

test "a code block is focusable, because it scrolls" {
    var app = try test_app.init(400, 400);
    defer app.deinit();
    _ = try app.tree.append(app.tree.rootId(), .{ .code_block = .{ .content = "const x = 1;" } });

    const html = try render(&app);
    defer testing.allocator.free(html);
    // A scroll container no key reaches is a pane a keyboard user
    // cannot read (WCAG 2.1.1).
    try expectContains(html, "<pre class=\"code\" tabindex=\"0\"><code>const x = 1;</code></pre>");
}

test "element fields are written; styling is not" {
    var app = try test_app.init(400, 400);
    defer app.deinit();
    const root = app.tree.rootId();
    // Defaults say nothing: gap 8 and padding 0 on a stack, padding 12
    // on a box.
    _ = try app.tree.append(root, .{ .stack = .{} });
    _ = try app.tree.append(root, .{ .stack = .{ .gap = 16, .padding = 4 } });
    _ = try app.tree.append(root, .{ .box = .{ .fill = .g11, .border = false } });

    const html = try render(&app);
    defer testing.allocator.free(html);
    // A vertical stack that pads nothing hands a back control's pairing
    // down to its own first block (`handsDownBack`), and says so.
    try expectContains(html, "<div class=\"stack hands-back\"></div>");
    try expectContains(html, "<div class=\"stack\" style=\"--gap:16px;--pad:4px\">");
    try expectContains(html, "<div class=\"box bare\" style=\"background:var(--g11)\">");
}

// ------------------------------------------------------------ chrome

test "chrome is separable from content, and the nav names where you are" {
    const Screens = struct {
        fn build(_: ?*anyopaque, app: *App) anyerror!void {
            _ = try app.tree.append(app.tree.rootId(), .{ .heading = .{ .content = "Library", .level = .h1 } });
        }
    };
    var app = try App.init(testing.allocator, .{
        .viewport = .{ .w = 900, .h = 600 },
        .services = .mocks(),
        .routes = &.{
            .{ .name = "library", .title = "Library", .build = Screens.build },
            .{ .name = "settings", .title = "Settings", .build = Screens.build },
        },
    });
    defer app.deinit();
    try app.setNav(&.{
        .{ .route = "library", .icon = .library },
        .{ .route = "settings", .icon = .settings },
    });
    try app.navigate("library");

    const html = try render(&app);
    defer testing.allocator.free(html);
    // The nav is chrome: it is not in the screen's markup.
    try expectLacks(html, "<nav");
    try expectContains(html, "<h1 id=\"library\">Library</h1>");

    const bar = try renderChrome(&app);
    defer testing.allocator.free(bar);
    try expectContains(bar, "<nav class=\"nav\" aria-label=\"Sections\">");
    // Consumers never manage selected state; the current route is
    // exposed as aria-current.
    try expectContains(bar, "href=\"#library\" aria-current=\"page\">");
    try expectContains(bar, "href=\"#settings\">");
    try expectLacks(bar, "href=\"#settings\" aria-current");
}

test "a mark costs its glyph; only the icon element takes the square box" {
    var app = try test_app.init(400, 400);
    defer app.deinit();
    const root = app.tree.rootId();
    _ = try app.tree.append(root, .{ .icon = .{ .name = .settings, .label = "Settings" } });
    _ = try app.tree.append(root, .{ .button = .{ .label = "Save", .icon = .check } });

    const html = try render(&app);
    defer testing.allocator.free(html);
    // `intrinsicSize` gives an `icon` element a `lineHeight` box on both
    // axes; a button's leading mark costs the glyph's advance plus
    // `icon_gap` and nothing else. The class carries that split, because
    // CSS cannot see which one it is holding — and a mark sized as a
    // square makes the control wider than the width core measured it at,
    // which is a wrong number in every decision made against it.
    try expectContains(html, "<span class=\"icon square\" role=\"img\" aria-label=\"Settings\">");
    try expectContains(html, "<span class=\"icon\" aria-hidden=\"true\">");
    try expectLacks(html, "class=\"btn\"><span class=\"icon square\"");
}

test "the notices indicator stands in the nav's row, not beside it" {
    const Screens = struct {
        fn build(_: ?*anyopaque, app: *App) anyerror!void {
            _ = try app.tree.append(app.tree.rootId(), .{ .heading = .{ .content = "Library", .level = .h1 } });
        }
    };
    var app = try App.init(testing.allocator, .{
        .viewport = .{ .w = 900, .h = 600 },
        .services = .mocks(),
        .routes = &.{
            .{ .name = "library", .title = "Library", .build = Screens.build },
            .{ .name = "settings", .title = "Settings", .build = Screens.build },
        },
    });
    defer app.deinit();
    try app.setNav(&.{
        .{ .route = "library", .icon = .library },
        .{ .route = "settings", .icon = .settings },
    });
    try app.navigate("library");
    try app.notify("Saved", "", "library");
    app.minimizeNotices();

    const bar = try renderChrome(&app);
    defer testing.allocator.free(bar);
    // `layoutNavChrome` counts the square and the gap before it into the
    // row's own width and centres *that*, so the control is one more
    // thing standing in the row — a child of it here, which is how a
    // browser centres the same group. Pinned to an edge instead, the
    // destinations centred on the viewport and the control drifted off
    // to wherever the page's margin fell.
    try expectContains(bar, "Settings</a><button type=\"button\" class=\"icon-button\" aria-label=\"Show notices\"");
    try expectContains(bar, "</button></div></nav>");
    try expectLacks(bar, "nav-indicator");

    // With no row to stand in it is a layer of its own again, keeping
    // the shared pane's corner — the branch is `indicatorRidesNavGroup`,
    // asked once and answered for both editions.
    var bare_app = try test_app.init(400, 600);
    defer bare_app.deinit();
    try bare_app.notify("Saved", "", "");
    bare_app.minimizeNotices();
    const bare = try renderChrome(&bare_app);
    defer testing.allocator.free(bare);
    try expectContains(bare, "<div class=\"nav-indicator\">");
}

test "an off-roster screen names itself, and the marker is not a link" {
    const Screens = struct {
        fn build(_: ?*anyopaque, app: *App) anyerror!void {
            _ = try app.tree.append(app.tree.rootId(), .{ .text = .{ .content = "A note" } });
        }
    };
    var app = try App.init(testing.allocator, .{
        .viewport = .{ .w = 900, .h = 600 },
        .services = .mocks(),
        .routes = &.{
            .{ .name = "library", .title = "Library", .build = Screens.build },
            .{ .name = "settings", .title = "Settings", .build = Screens.build },
            .{ .name = "note", .title = "Note", .build = Screens.build },
        },
    });
    defer app.deinit();
    try app.setNav(&.{
        .{ .route = "library", .icon = .library },
        .{ .route = "settings", .icon = .settings },
    });
    try app.navigate("note");

    const bar = try renderChrome(&app);
    defer testing.allocator.free(bar);
    // It goes where you already are, so it is a label and answers no
    // press — static_text to assistive tech, named "Current screen"
    // with the title as its value.
    try expectContains(bar, "<span class=\"chip current here\">");
    try expectContains(bar, "Current screen: ");
    try expectContains(bar, "Note</span>");
    try expectLacks(bar, "href=\"#note\"");
}

test "an open sheet is a modal dialog named by its title" {
    var app = try test_app.init(500, 700);
    defer app.deinit();
    const sheet = try app.presentSheet("Move note");
    _ = try app.tree.append(sheet, .{ .text = .{ .content = "Pick a notebook." } });

    const html = try render(&app);
    defer testing.allocator.free(html);
    try expectLacks(html, "role=\"dialog\"");

    const layers = try renderChrome(&app);
    defer testing.allocator.free(layers);
    // One name, said once: the visible header carries it and the
    // dialog points at it.
    try expectContains(layers, "role=\"dialog\" aria-modal=\"true\" aria-labelledby=\"pane-title-");
    try expectContains(layers, "<h2 class=\"pane-title\" id=\"pane-title-");
    try expectContains(layers, ">Move note</h2>");
    try expectLacks(layers, "aria-label=\"Move note\"");
    try expectContains(layers, "<div class=\"scrim\"></div>");
    // The close control the framework installs is named, and named in
    // framework English — no consumer's string can name it.
    try expectContains(layers, "aria-label=\"Close\"");
}

// -------------------------------------------------------- stylesheet

test "the stylesheet is generated from the library, not transcribed" {
    var css: std.ArrayList(u8) = .empty;
    defer css.deinit(testing.allocator);
    try stylesheet.write(testing.allocator, &css, .{});

    const color = @import("../../core/color.zig");
    const layout = @import("../../core/layout.zig");
    const text_mod = @import("../../core/text.zig");

    // Both ramps, at the bytes color.zig decided.
    var expected: [64]u8 = undefined;
    try expectContains(css.items, try std.fmt.bufPrint(&expected, "--g2: #{x:0>2}{x:0>2}{x:0>2};", .{
        color.Gray.ink.byte(.light),
        color.Gray.ink.byte(.light),
        color.Gray.ink.byte(.light),
    }));
    try expectContains(css.items, try std.fmt.bufPrint(&expected, "--g12: #{x:0>2}{x:0>2}{x:0>2};", .{
        color.Gray.paper.byte(.dark),
        color.Gray.paper.byte(.dark),
        color.Gray.paper.byte(.dark),
    }));
    // The type scale, and the metrics.
    try expectContains(css.items, try std.fmt.bufPrint(&expected, "--px-h1: {d}px;", .{text_mod.Scale.h1.px()}));
    try expectContains(css.items, try std.fmt.bufPrint(&expected, "--lh-body: {d}px;", .{text_mod.Scale.body.lineHeight()}));
    try expectContains(css.items, try std.fmt.bufPrint(&expected, "--touch: {d}px;", .{layout.metrics.touch_target}));
    try expectContains(css.items, try std.fmt.bufPrint(&expected, "--focus: {d}px;", .{layout.metrics.focus_stroke}));

    // The refusals, kept: no hover rule, and no motion to disable.
    try expectLacks(css.items, ":hover {");
    try expectContains(css.items, "transition: none !important;");
}

test "the appearance is core's, and the system query only stands in for it" {
    var css: std.ArrayList(u8) = .empty;
    defer css.deinit(testing.allocator);
    try stylesheet.write(testing.allocator, &css, .{});

    // A page with no app behind it — a screen serialized to a file —
    // has the desktop's preference and nothing else. A page with one
    // has `App.appearance()`, which already contains that preference
    // because `Scheme.auto` resolves through it — so the query stands
    // down rather than overruling a reader who chose light.
    try expectContains(css.items, "@media (prefers-color-scheme: dark) {\n  :root:not([data-appearance]) {");
    try expectContains(css.items, ":root[data-appearance=\"dark\"] {\n  color-scheme: dark;");
    try expectContains(css.items, ":root[data-appearance=\"light\"] { color-scheme: light; }");

    // One ramp under two selectors, byte for byte: written by one loop,
    // so a hand-copied second thirteen cannot drift from the first.
    const color = @import("../../core/color.zig");
    var expected: [64]u8 = undefined;
    const paper_dark = try std.fmt.bufPrint(&expected, "--g12: #{x:0>2}{x:0>2}{x:0>2};", .{
        color.Gray.paper.byte(.dark),
        color.Gray.paper.byte(.dark),
        color.Gray.paper.byte(.dark),
    });
    try testing.expectEqual(@as(usize, 2), std.mem.count(u8, css.items, paper_dark));
}

test "text takes its own direction; only the chrome takes the app's" {
    var css: std.ArrayList(u8) = .empty;
    defer css.deinit(testing.allocator);
    try stylesheet.write(testing.allocator, &css, .{});

    // `plaintext` is UAX #9 P2/P3 — `bidi.paragraphDirection`'s rule, the
    // one every text path in the reference runs through — so a Persian
    // paragraph reads right to left in a left-to-right screen without
    // the app being told anything.
    try expectContains(css.items, "unicode-bidi: plaintext;");
    // And the mirroring is the chrome's alone, scoped to nokre's own
    // surfaces: an edition mounted in someone else's document does not
    // turn the page around it.
    try expectContains(css.items, ":root[data-direction=\"rtl\"] :is(.nokre,");
    try expectContains(css.items, "  direction: rtl;\n}");
}

test "the faces are the bundled ones, and the font block is optional" {
    var with: std.ArrayList(u8) = .empty;
    defer with.deinit(testing.allocator);
    try stylesheet.write(testing.allocator, &with, .{ .fonts = "/f" });
    try expectContains(with.items, "src: url(/f/prose-bolditalic.woff2)");
    // The Arabic-script companion arrives by unicode-range, which is a
    // browser doing what the shim's substitution does.
    try expectContains(with.items, "url(/f/arabic.woff2) format(\"woff2\"); unicode-range: U+0600-06FF");

    var without: std.ArrayList(u8) = .empty;
    defer without.deinit(testing.allocator);
    try stylesheet.write(testing.allocator, &without, .{ .font_faces = false });
    try expectLacks(without.items, "@font-face");
}
