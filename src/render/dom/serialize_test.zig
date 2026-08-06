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
const overlays = @import("../../core/overlays.zig");
const semantics = @import("../../a11y/semantics.zig");
const serialize = @import("serialize.zig");
const stylesheet = @import("stylesheet.zig");
const test_app = @import("../../core/test_app.zig");
const tree_mod = @import("../../core/tree.zig");

const App = app_mod.App;
const NodeId = tree_mod.NodeId;
const testing = std.testing;

fn noopPress(_: ?*anyopaque) void {}

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

/// A chrome word as it must reach the markup, assembled from whatever
/// the app's catalog says rather than from a literal here — an
/// assertion spelled in English would pass against a serializer that
/// only speaks English, which is the drift these two guard.
fn expectAriaLabel(haystack: []const u8, word: []const u8) !void {
    const needle = try std.fmt.allocPrint(testing.allocator, "aria-label=\"{s}\"", .{word});
    defer testing.allocator.free(needle);
    try expectContains(haystack, needle);
}

fn expectHiddenName(haystack: []const u8, word: []const u8) !void {
    const needle = try std.fmt.allocPrint(
        testing.allocator,
        "<span class=\"visually-hidden\">{s}: </span>",
        .{word},
    );
    defer testing.allocator.free(needle);
    try expectContains(haystack, needle);
}

// ---------------------------------------------------------- the shape

test "the root's children come through in tree order" {
    var app = try test_app.init(400, 400);
    defer app.deinit();
    const root = app.tree.rootId();
    try app.tree.append(root, .{ .heading = .{ .content = "Notes", .level = .h1 } });
    try app.tree.append(root, .{ .text = .{ .content = "One" } });
    try app.tree.append(root, .{ .divider = .{} });

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
    try app.tree.append(root, .{ .heading = .{ .content = "Same", .level = .h1 } });
    try app.tree.append(root, .{ .heading = .{ .content = "Same", .level = .h2 } });
    try app.tree.append(root, .{ .button = .{ .label = "Go" } });

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
    try app.tree.append(root, .{ .heading = .{ .content = "معرفی نکته", .level = .h1 } });
    try app.tree.append(root, .{ .heading = .{ .content = "مقدمة", .level = .h2 } });
    // …but Unicode PUNCTUATION goes the way "&" does: GitHub slugs the
    // em dash out, and every TOC written against its anchors says so.
    try app.tree.append(root, .{ .heading = .{ .content = "Part 1 — A project", .level = .h2 } });

    const html = try render(&app);
    defer testing.allocator.free(html);
    try expectContains(html, "<h1 id=\"معرفی-نکته\">");
    try expectContains(html, "<h2 id=\"مقدمة\">");
    try expectContains(html, "<h2 id=\"part-1--a-project\">");
    try expectLacks(html, "id=\"section\"");
}

test "a spanned heading slugs its words, not \"section\"" {
    // A formatted heading arrives with its words in `spans` —
    // consumers leave `content` empty and `append` writes the
    // concatenation — so the anchor must come from those words, the
    // same id GitHub gives the unformatted heading.
    var app = try test_app.init(400, 400);
    defer app.deinit();
    try app.tree.append(app.tree.rootId(), .{ .heading = .{
        .level = .h2,
        .spans = &.{
            .{ .text = "Fast " },
            .{ .text = "and correct", .emphasis = true },
        },
    } });

    const html = try render(&app);
    defer testing.allocator.free(html);
    try expectContains(html, "<h2 id=\"fast-and-correct\">");
    try expectLacks(html, "id=\"section\"");
}

test "two same-labeled choice groups get distinct radio names" {
    var app = try test_app.init(400, 400);
    defer app.deinit();
    const root = app.tree.rootId();
    const a = try app.tree.appendId(root, .{ .segmented = .{
        .label = "View",
        .options = &.{ "All", "Starred" },
    } });
    const b = try app.tree.appendId(root, .{ .segmented = .{
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
    try app.tree.append(app.tree.rootId(), .{ .text = .{
        .content = "<script>alert(\"x\")</script> & 'more'",
    } });

    const html = try render(&app);
    defer testing.allocator.free(html);
    try expectLacks(html, "<script>");
    try expectContains(html, "&lt;script&gt;alert(&quot;x&quot;)&lt;/script&gt; &amp; &#39;more&#39;");
}

test "no byte a consumer supplies can end a script block" {
    // The same question the CSP sweep asks, at a different destination
    // (packaging_test.zig, "no byte a consumer supplies can smuggle a
    // directive"): not "which bytes did someone think of" but "what does
    // every byte there is do". A `<script>` block's contents are raw
    // text, so neither `text` above nor `std.json` is the escape it
    // needs, and structured data is user-adjacent content by the page.
    var app = try test_app.init(400, 400);
    defer app.deinit();
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    var em: serialize.Emitter = .{ .gpa = testing.allocator, .app = &app, .out = &out };
    defer em.deinit();

    // The three ways out of the data state, all of them bytes a
    // statement's own words can carry. The middle one is why the rule is
    // `<` and not `</`: it opens the escaped state, where the
    // `</script>` *the driver itself wrote* stops ending the element —
    // so two innocent strings on one page swallow the rest of the
    // document between them.
    for ([_][]const u8{ "</script>", "<!--", "<script" }) |hazard| {
        const doc = try std.json.Stringify.valueAlloc(
            testing.allocator,
            .{ .statement = hazard },
            .{},
        );
        defer testing.allocator.free(doc);
        // The receipt for why this function exists at all: std.json
        // writes the hazard straight through, because it is legal JSON.
        try expectContains(doc, hazard);

        out.clearRetainingCapacity();
        try em.json(doc);
        try expectLacks(out.items, "<");
    }

    // The sweep those three are examples of: every codepoint the low 256
    // hold, in the middle of a string value rather than alone, because
    // that is where a smuggled byte would hide. Two properties per byte,
    // and the second is the one that makes the first worth having — the
    // document that comes out parses back to the value that went in, so
    // the escape is value-preserving and not merely safe.
    for (0..256) |cp| {
        var utf8: [4]u8 = undefined;
        const n = std.unicode.utf8Encode(@intCast(cp), &utf8) catch unreachable;
        var buf: [6]u8 = undefined;
        buf[0] = 'x';
        @memcpy(buf[1..][0..n], utf8[0..n]);
        buf[1 + n] = 'y';
        const statement = buf[0 .. n + 2];

        const doc = try std.json.Stringify.valueAlloc(
            testing.allocator,
            .{ .statement = statement },
            .{},
        );
        defer testing.allocator.free(doc);
        out.clearRetainingCapacity();
        try em.json(doc);
        try testing.expect(std.mem.indexOfScalar(u8, out.items, '<') == null);

        const parsed = try std.json.parseFromSlice(
            struct { statement: []const u8 },
            testing.allocator,
            out.items,
            .{},
        );
        defer parsed.deinit();
        try testing.expectEqualStrings(statement, parsed.value.statement);
    }

    // A key is a string too, and the pass is over the finished document
    // rather than over one value, so wherever a `<` came from it leaves
    // the same way.
    out.clearRetainingCapacity();
    try em.json("{\"a</script>b\":1}");
    try testing.expectEqualStrings("{\"a\\u003C/script>b\":1}", out.items);

    // Everything else is left exactly as std.json wrote it, and the two
    // absences are deliberate. `&` would have become `&amp;` under
    // `text` — five characters of a statement nobody wrote, because raw
    // text decodes no character reference. U+2028 breaks JavaScript
    // *source*, and a data block is never parsed as source.
    out.clearRetainingCapacity();
    try em.json("{\"k\":\"a & b\\u2028c\"}");
    try testing.expectEqualStrings("{\"k\":\"a & b\\u2028c\"}", out.items);
}

// --------------------------------------------------- per-element contract

test "static elements: the words are what is conveyed" {
    var app = try test_app.init(400, 400);
    defer app.deinit();
    const root = app.tree.rootId();
    try app.tree.append(root, .{ .badge = .{ .label = "3 pending" } });
    try app.tree.append(root, .{ .meter = .{ .label = "12 of 30 days", .value = 12, .max = 30 } });

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

test "sign-in buttons carry the vendor mark, and the markup carries no color" {
    var app = try test_app.init(400, 400);
    defer app.deinit();
    const root = app.tree.rootId();
    try app.tree.append(root, .{ .button = .{ .label = "Sign in with Apple", .form = .{ .provider = .apple } } });
    try app.tree.append(root, .{ .button = .{ .label = "Sign in with Google", .form = .{ .provider = .google } } });

    const html = try render(&app);
    defer testing.allocator.free(html);
    // The mark is decorative beside the real label, standing down from
    // assistive tech exactly like a lead icon.
    try expectContains(html, "class=\"btn auth\"");
    try expectContains(html, "<span class=\"brand-mark\" aria-hidden=\"true\">&#xE900;</span>Sign in with Apple");
    // Google's G: four arc glyphs the stylesheet overlays and colors —
    // the markup itself is colorless, here and everywhere; the class is
    // the whole hook, and only the stylesheet (infrastructure) knows
    // what it means.
    try expectContains(html, "class=\"btn auth google\"");
    try expectContains(html, "<span class=\"brand-mark g\" aria-hidden=\"true\">" ++
        "<span>&#xE901;</span><span>&#xE902;</span><span>&#xE903;</span><span>&#xE904;</span></span>Sign in with Google");
    try expectLacks(html, "color:");
    try expectLacks(html, "#4285");
}

test "an icon with no label is decorative, and a named one is an image" {
    var app = try test_app.init(400, 400);
    defer app.deinit();
    const root = app.tree.rootId();
    try app.tree.append(root, .{ .icon = .{ .name = .house } });
    try app.tree.append(root, .{ .icon = .{ .name = .house, .label = "Home" } });

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
    try app.tree.append(app.tree.rootId(), .{ .text = .{ .spans = &.{
        .{ .text = "Read the " },
        .{ .text = "terms", .strong = true, .route = "" },
        .{ .text = ", or the " },
        .{ .text = "policy", .route = "privacy" },
        .{ .text = "." },
    } } });

    // The strong run spells its routelessness out (`.route = ""`, the
    // one spelling of "no route" — `Span.route`): styling, no anchor.
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
    try app.tree.append(app.tree.rootId(), .{ .text = .{ .spans = &.{
        .{ .text = "Read the " },
        .{ .text = "full terms", .external = "https://example.com/terms?v=2&lang=en" },
        .{ .text = "." },
    } } });
    try app.tree.append(app.tree.rootId(), .{ .link = .{
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
    try app.tree.append(app.tree.rootId(), .{ .link = .{ .label = "Note", .route = "note~42" } });

    const html = try render(&app);
    defer testing.allocator.free(html);
    // Every byte a reference may carry is one encodeURIComponent leaves
    // alone, so what the router writes is what the markup carries.
    try expectContains(html, "href=\"#note~42\"");
}

test "a driver resolves references to destinations; the emitter writes both forms" {
    // The static-site shape: a route is a file of the site's own, or a
    // source file on another host. The hook only *answers* — every byte
    // of both attributes below is the emitter's, which is the contract:
    // no driver holds a half-open quote to splice its own into.
    const Site = struct {
        fn resolve(_: ?*anyopaque, _: *serialize.Emitter, route: []const u8) anyerror!serialize.Dest {
            if (std.mem.eql(u8, route, "docs")) return .{ .internal = "/docs/" };
            return .{ .external = "https://example.com/src/a.zig?v=1&x=2" };
        }
    };
    var app = try test_app.init(400, 400);
    defer app.deinit();
    try app.tree.append(app.tree.rootId(), .{ .link = .{ .label = "Docs", .route = "docs" } });
    try app.tree.append(app.tree.rootId(), .{ .link = .{ .label = "Source", .route = "src" } });

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    var em: serialize.Emitter = .{
        .gpa = testing.allocator,
        .app = &app,
        .out = &out,
        .options = .{ .refs = .{ .resolve = Site.resolve } },
    };
    defer em.deinit();
    try serialize.content(&em);
    // Internal: a plain href, nothing else on the anchor.
    try expectContains(out.items, "<a class=\"link block\" href=\"/docs/\">Docs</a>");
    // External: the emitter's own new-tab pair, and the URL through the
    // one attribute escape — the resolver returned a raw `&`.
    try expectContains(out.items, "<a class=\"link block\" href=\"https://example.com/src/a.zig?v=1&amp;x=2\"" ++
        " target=\"_blank\" rel=\"noopener noreferrer\">Source</a>");
}

test "a tile with a route is a link; one with an action is a button" {
    var app = try test_app.init(400, 400);
    defer app.deinit();
    const group = try app.tree.appendId(app.tree.rootId(), .{ .tile_group = .{} });
    try app.tree.append(group, .{ .tile = .{ .label = "Open", .route = "settings" } });
    try app.tree.append(group, .{ .tile = .{ .label = "Act", .on_press = .{ .call = noopPress } } });

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
        semantics.roleOf(.{ .tile = .{ .label = "Act", .on_press = .{ .call = noopPress } } }),
    );
}

test "a tile's leading mark is a hidden square; its chevron stays a mark" {
    var app = try test_app.init(400, 400);
    defer app.deinit();
    const group = try app.tree.appendId(app.tree.rootId(), .{ .tile_group = .{} });
    try app.tree.append(group, .{ .tile = .{ .label = "Members", .route = "members", .icon = .users } });

    const html = try render(&app);
    defer testing.allocator.free(html);
    // The band a column of rows shares takes the `lineHeight` box; the
    // chevron inside the same row is a mark and takes its own advance.
    try expectContains(html, "<a class=\"tile\" href=\"#members\">" ++
        "<span class=\"icon square\" aria-hidden=\"true\">&#xE1A4;</span>" ++
        "<span class=\"tile-text\"><span class=\"tile-label\">Members</span></span>");
    try expectContains(html, "<span class=\"icon\" aria-hidden=\"true\">&#xE06F;</span></a>");
    // Decorative, so the row keeps saying its name once.
    try testing.expect(std.mem.indexOf(u8, html, "aria-label=\"Members\"") == null);
}

test "a chip's mark is a hidden small mark, and the words still carry it" {
    var app = try test_app.init(400, 400);
    defer app.deinit();
    try app.tree.append(app.tree.rootId(), .{ .badge = .{ .label = "Istanbul", .icon = .map_pin } });

    const html = try render(&app);
    defer testing.allocator.free(html);
    // `mark`, not `square`: a chip hugs its content. `s-small`, because
    // the glyph is the chip's own text made a glyph.
    try expectContains(html, "<span class=\"badge\">" ++
        "<span class=\"icon s-small\" aria-hidden=\"true\">&#xE111;</span>Istanbul</span>");
    // Decorative: nothing announces the family, only the words.
    try testing.expect(std.mem.indexOf(u8, html, "role=\"img\"") == null);
}

test "stateful controls carry their state, not just their label" {
    var app = try test_app.init(400, 400);
    defer app.deinit();
    const root = app.tree.rootId();
    try app.tree.append(root, .{ .toggle = .{ .label = "Sync", .on = true } });
    try app.tree.append(root, .{ .checkbox = .{ .label = "Remember" } });
    const seg = try app.tree.appendId(root, .{ .segmented = .{
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

test "a busy switch says so on the control, keeping its role and its value" {
    var app = try test_app.init(400, 400);
    defer app.deinit();
    const root = app.tree.rootId();
    try app.tree.append(root, .{ .toggle = .{ .label = "Sync", .on = true, .in_progress = true } });
    try app.tree.append(root, .{ .checkbox = .{ .label = "Remember", .in_progress = true } });

    const html = try render(&app);
    defer testing.allocator.free(html);
    // What a pixel golden cannot check for this edition: the input is
    // still the control — role and value intact — and `aria-busy` is
    // what a screen reader hears while the work runs. The `busy` class
    // on the row is what stands the drawing down (stylesheet.zig); the
    // markup carries no ellipsis of its own, because the mark is a
    // rendering and the reader is owed the state instead.
    try expectContains(html, "class=\"ctl busy\"");
    try expectContains(html, "class=\"toggle\" role=\"switch\" checked aria-busy=\"true\">");
    try expectContains(html, "class=\"check\" aria-busy=\"true\">");
    // The name is never replaced by the state.
    try expectContains(html, "<span class=\"ctl-label\">Sync</span>");
}

test "a track that overflows bleeds to the edge; one that fits does not" {
    var app = try test_app.init(400, 400);
    defer app.deinit();
    const root = app.tree.rootId();
    try app.tree.append(root, .{ .segmented = .{
        .label = "View",
        .options = &.{ "All", "Starred" },
    } });
    try app.tree.append(root, .{ .segmented = .{
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
    try app.tree.append(app.tree.rootId(), .{ .text_input = .{
        .label = "Passphrase",
        .value = "hunter2",
        .obscured = true,
    } });

    const html = try render(&app);
    defer testing.allocator.free(html);
    try expectContains(html, "<input type=\"password\"");
    try expectContains(html, "<span class=\"field-label\">Passphrase</span>");
}

test "a field's problem is announced as a description, never as part of the name" {
    // What a pixel golden cannot check for this edition: the *relation*.
    // The words are drawn either way; what makes them a field error is
    // `aria-invalid` on the control plus a reference to where they are.
    var app = try test_app.init(400, 400);
    defer app.deinit();
    const email = try app.tree.appendId(app.tree.rootId(), .{ .text_input = .{
        .label = "Email",
        .value = "not-an-address",
        .problem = "That is not an email address.",
    } });

    const html = try render(&app);
    defer testing.allocator.free(html);

    var buf: [96]u8 = undefined;
    const ref = try std.fmt.bufPrint(&buf, "problem-{d}", .{@as(u32, @bitCast(email))});
    var attr: [128]u8 = undefined;
    try expectContains(html, try std.fmt.bufPrint(
        &attr,
        " aria-invalid=\"true\" aria-describedby=\"{s}\"",
        .{ref},
    ));
    var para: [160]u8 = undefined;
    try expectContains(html, try std.fmt.bufPrint(
        &para,
        "</label><p class=\"field-problem\" id=\"{s}\">That is not an email address.</p></div>",
        .{ref},
    ));
    // Outside the `<label>`, and that is the whole point: an implicit
    // label's subtree text *is* the field's accessible name, so words
    // left inside it would be read as part of the name rather than as
    // a reason it was refused.
    try expectContains(html, "<div class=\"field-group\"><label class=\"field\">");
}

test "a field with no problem carries no invalid state and no wrapper" {
    var app = try test_app.init(400, 400);
    defer app.deinit();
    try app.tree.append(app.tree.rootId(), .{ .text_area = .{ .label = "Notes" } });

    const html = try render(&app);
    defer testing.allocator.free(html);
    try testing.expect(std.mem.indexOf(u8, html, "aria-invalid") == null);
    try testing.expect(std.mem.indexOf(u8, html, "field-group") == null);
}

test "a disabled field says so in the platform's own word, on both fields" {
    // What a pixel golden cannot check for this edition: the *focus
    // order*. The reference drops a disabled field's stop; the markup
    // has to drop it too, and only the native attribute does that —
    // `aria-disabled` would announce the state and leave the field
    // Tab-reachable, so the two editions would disagree about where Tab
    // goes, which is the one thing a second edition may never do.
    var app = try test_app.init(400, 400);
    defer app.deinit();
    try app.tree.append(app.tree.rootId(), .{ .text_input = .{
        .label = "Verification code",
        .value = "481923",
        .disabled = true,
    } });
    try app.tree.append(app.tree.rootId(), .{ .text_area = .{
        .label = "Why you are joining",
        .disabled = true,
    } });
    try app.tree.append(app.tree.rootId(), .{ .text_input = .{ .label = "City" } });

    const html = try render(&app);
    defer testing.allocator.free(html);
    try expectContains(html, "<input type=\"text\" value=\"481923\" placeholder=\"\" disabled");
    try expectContains(html, "<textarea rows=\"3\" placeholder=\"\" disabled");
    // The name and the value stay in the markup: a disabled field is
    // announced, not removed.
    try expectContains(html, "<span class=\"field-label\">Verification code</span>");
    // `aria-disabled` is deliberately absent — the native attribute is
    // the whole statement, and a second spelling could disagree with it.
    try testing.expect(std.mem.indexOf(u8, html, "aria-disabled") == null);
    // The live field beside them takes no attribute at all.
    try expectContains(html, "<span class=\"field-label\">City</span><span class=\"field-box\">" ++
        "<input type=\"text\" value=\"\" placeholder=\"\"></span>");
}

test "a text area value that starts with a newline keeps it" {
    // The HTML parser drops one newline immediately after the
    // <textarea> tag, so the serializer emits a sacrificial extra — a
    // value must round-trip through the page byte-for-byte.
    var app = try test_app.init(400, 400);
    defer app.deinit();
    try app.tree.append(app.tree.rootId(), .{ .text_area = .{
        .label = "Notes",
        .value = "\nfirst line",
    } });

    const html = try render(&app);
    defer testing.allocator.free(html);
    try expectContains(html, ">\n\nfirst line</textarea>");
}

test "rtl: the back and tile chevrons mirror with the chrome" {
    // The reference flips both marks under a mirrored chrome
    // (`back_chevron_rtl`, `tile_chevron_rtl`); this edition points
    // them the same way. Each mark is read next to its closing tag —
    // the two swap glyphs, so containment alone could not tell the
    // mirrored page from the unmirrored one.
    var app = try test_app.mirrored(400, 400);
    defer app.deinit();
    try app.tree.append(app.tree.rootId(), .{ .back = .{} });
    const group = try app.tree.appendId(app.tree.rootId(), .{ .tile_group = .{} });
    try app.tree.append(group, .{ .tile = .{ .label = "تنظیمات", .route = "settings" } });

    const html = try render(&app);
    defer testing.allocator.free(html);
    try expectContains(html, "&#xE06F;</span></button>"); // back: chevron-right
    try expectContains(html, "&#xE06E;</span></a>"); // tile: chevron-left
}

test "a folded action is not on the row; the more control stands there" {
    var app = try test_app.init(400, 400);
    defer app.deinit();
    const row = try app.tree.appendId(app.tree.rootId(), .{ .stack = .{ .axis = .horizontal } });
    try app.tree.append(row, .{ .button = .{ .label = "Kept" } });
    // Folded is layout's write, made after the append the way layout
    // makes it — the literal form is refused (error.LayoutOwnedField).
    const folded = try app.tree.appendId(row, .{ .button = .{ .label = "Folded" } });
    app.tree.get(folded).?.setFolded(true);
    try app.tree.append(row, .{ .more = .{} });

    const html = try render(&app);
    defer testing.allocator.free(html);
    try expectContains(html, ">Kept</button>");
    try expectLacks(html, "Folded");
    try expectContains(html, ">More</button>");

    // The control's words are the app's chrome like every other
    // framework string, and the second edition writes what the node
    // carries rather than the English nokre ships.
    app.setChrome(.{ .more = "Daha fazla" });
    const tr = try render(&app);
    defer testing.allocator.free(tr);
    try expectContains(tr, ">Daha fazla</button>");
    try expectLacks(tr, ">More</button>");
}

test "which of the two things a row does is carried into the markup" {
    var app = try test_app.init(400, 400);
    defer app.deinit();
    // A row of actions folds and stays on one line; a row of chips wraps.
    // The class is `layout.rowOverflow`'s answer, not a selector's guess,
    // so the browser breaks exactly the rows core breaks.
    const actions = try app.tree.appendId(app.tree.rootId(), .{ .stack = .{ .axis = .horizontal } });
    try app.tree.append(actions, .{ .button = .{ .label = "Save" } });
    try app.tree.append(actions, .{ .link = .{ .label = "Details", .route = "d" } });
    const chips = try app.tree.appendId(app.tree.rootId(), .{ .stack = .{ .axis = .horizontal } });
    try app.tree.append(chips, .{ .badge = .{ .label = "Admin" } });
    try app.tree.append(chips, .{ .badge = .{ .label = "Held for review" } });

    const html = try render(&app);
    defer testing.allocator.free(html);
    try expectContains(html, "<div class=\"stack row\">");
    try expectContains(html, "<div class=\"stack row wrap\">");
    // And the stylesheet has the rule the class names.
    var css: std.ArrayList(u8) = .empty;
    defer css.deinit(testing.allocator);
    try stylesheet.write(testing.allocator, &css, .{});
    try expectContains(css.items, ".stack.row.wrap { flex-wrap: wrap;");
}

test "a list's marker is derived, so the markup carries none" {
    var app = try test_app.init(400, 400);
    defer app.deinit();
    const list = try app.tree.appendId(app.tree.rootId(), .{ .list = .{ .ordered = true, .start = 3 } });
    const item = try app.tree.appendId(list, .{ .list_item = .{} });
    try app.tree.append(item, .{ .text = .{ .content = "Third" } });

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
    const table = try app.tree.appendId(app.tree.rootId(), .{ .table = .{} });
    const head = try app.tree.appendId(table, .{ .row = .{ .header = true } });
    const hc = try app.tree.appendId(head, .{ .cell = .{} });
    try app.tree.append(hc, .{ .text = .{ .content = "Platform" } });
    const body = try app.tree.appendId(table, .{ .row = .{} });
    const bc = try app.tree.appendId(body, .{ .cell = .{} });
    try app.tree.append(bc, .{ .text = .{ .content = "macOS" } });

    const html = try render(&app);
    defer testing.allocator.free(html);
    try expectContains(html, "<th><p>Platform</p></th>");
    try expectContains(html, "<td><p>macOS</p></td>");
}

test "a code block is focusable, because it scrolls" {
    var app = try test_app.init(400, 400);
    defer app.deinit();
    try app.tree.append(app.tree.rootId(), .{ .code_block = .{ .content = "const x = 1;" } });

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
    try app.tree.append(root, .{ .stack = .{} });
    try app.tree.append(root, .{ .stack = .{ .gap = 16, .padding = 4 } });
    try app.tree.append(root, .{ .box = .{ .fill = .g11, .border = false } });

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
            try app.tree.append(app.tree.rootId(), .{ .heading = .{ .content = "Library", .level = .h1 } });
        }
    };
    var app = try App.init(testing.allocator, .{
        .viewport = .{ .w = 900, .h = 600 },
        .services = .mocks(),
        .routes = &.{
            .{ .name = "library", .title = .{ .fixed = "Library" }, .build = Screens.build },
            .{ .name = "settings", .title = .{ .fixed = "Settings" }, .build = Screens.build },
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
    try app.tree.append(root, .{ .icon = .{ .name = .settings, .label = "Settings" } });
    try app.tree.append(root, .{ .button = .{ .label = "Save", .form = .{ .filled = .check } } });

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
            try app.tree.append(app.tree.rootId(), .{ .heading = .{ .content = "Library", .level = .h1 } });
        }
    };
    var app = try App.init(testing.allocator, .{
        .viewport = .{ .w = 900, .h = 600 },
        .services = .mocks(),
        .routes = &.{
            .{ .name = "library", .title = .{ .fixed = "Library" }, .build = Screens.build },
            .{ .name = "settings", .title = .{ .fixed = "Settings" }, .build = Screens.build },
        },
    });
    defer app.deinit();
    try app.setNav(&.{
        .{ .route = "library", .icon = .library },
        .{ .route = "settings", .icon = .settings },
    });
    try app.navigate("library");
    app.notify(.{ .title = "Saved", .route = "library" });
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
    bare_app.notify(.{ .title = "Saved" });
    bare_app.minimizeNotices();
    const bare = try renderChrome(&bare_app);
    defer testing.allocator.free(bare);
    try expectContains(bare, "<div class=\"nav-indicator\">");
}

test "a notice's icon is a decorative square between the controls and the words" {
    var app = try test_app.init(400, 600);
    defer app.deinit();
    app.notify(.{
        .title = "Sync failed",
        .description = "Changes are kept locally.",
        .route = "home",
        .icon = .cloud_off,
        .important = true,
    });

    const banner = try renderChrome(&app);
    defer testing.allocator.free(banner);
    // Decorative (`aria-hidden`): the title stays the accessible name.
    // A `square` box, matching the `lineHeight` slot layout charged the
    // words' column (`noticeTextBand`) — a mark's measured advance would
    // be a different number than the one core laid out with.
    try expectContains(banner, "<span class=\"icon square\" aria-hidden=\"true\">&#xE08D;</span><div class=\"notice-words\">");

    // Mixed importance groups the pane, each group under its label.
    app.notify(.{ .title = "Export ready", .route = "home" });
    try app.openNoticesPane();
    const pane = try renderChrome(&app);
    defer testing.allocator.free(pane);
    try expectContains(pane, "Important");
    try expectContains(pane, "Sync failed");
    try expectContains(pane, "Other");
    try expectContains(pane, "Export ready");
}

test "a routeless notice reaches the page without an open button" {
    var app = try test_app.init(400, 600);
    defer app.deinit();
    // The leading flank is a census of the controls core installed
    // (`noticeControls`), so a notice with nowhere to go emits its
    // words straight after the row opens — nothing announces a press
    // this edition would answer with a refused navigation either.
    app.notify(.{ .title = "Draft saved", .important = true });
    const banner = try renderChrome(&app);
    defer testing.allocator.free(banner);
    try expectContains(banner, "role=\"status\"><div class=\"notice-words\">");
    try expectLacks(banner, "Open: ");
    try expectContains(banner, "aria-label=\"Dismiss: Draft saved\"");

    // The pane keeps the distinction per row.
    app.notify(.{ .title = "Sync failed", .route = "home" });
    try app.openNoticesPane();
    const pane = try renderChrome(&app);
    defer testing.allocator.free(pane);
    try expectContains(pane, "aria-label=\"Open: Sync failed\"");
    try expectLacks(pane, "Open: Draft saved");
}

test "an off-roster screen names itself, and the marker is not a link" {
    const Screens = struct {
        fn build(_: ?*anyopaque, app: *App) anyerror!void {
            try app.tree.append(app.tree.rootId(), .{ .text = .{ .content = "A note" } });
        }
    };
    var app = try App.init(testing.allocator, .{
        .viewport = .{ .w = 900, .h = 600 },
        .services = .mocks(),
        .routes = &.{
            .{ .name = "library", .title = .{ .fixed = "Library" }, .build = Screens.build },
            .{ .name = "settings", .title = .{ .fixed = "Settings" }, .build = Screens.build },
            .{ .name = "note", .title = .{ .fixed = "Note" }, .build = Screens.build },
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
    // press — static_text to assistive tech, named by the chrome word
    // with the title as its value.
    try expectContains(bar, "<span class=\"chip current here\">");
    try expectHiddenName(bar, app.chrome.current_screen);
    try expectContains(bar, "Note</span>");
    try expectLacks(bar, "href=\"#note\"");
}

test "the four framework-chrome names are said in the app's language, not the serializer's" {
    const Screens = struct {
        fn build(_: ?*anyopaque, app: *App) anyerror!void {
            try app.tree.append(app.tree.rootId(), .{ .text = .{ .content = "A note" } });
        }
    };
    // Every other test here runs English, where a hard-coded literal and
    // a catalog read are the same bytes. This one is the difference: the
    // words below are what `setChrome` put on the elements, and the
    // markup must carry them because `label()` does — the guarantee is
    // that both editions consult one catalog.
    const tr: element_mod.Chrome = .{
        .back = "Geri",
        .close = "Kapat",
        .section = "Bölüm",
        .current_screen = "Bu ekran",
        .sections = "Bölümler",
    };

    // Phone width and a crowded roster, so the row folds to the chip.
    var narrow = try App.init(testing.allocator, .{
        .viewport = .{ .w = 375, .h = 600 },
        .services = .mocks(),
        .routes = &.{
            .{ .name = "library", .title = .{ .fixed = "Library" }, .build = Screens.build },
            .{ .name = "settings", .title = .{ .fixed = "Settings" }, .build = Screens.build },
            .{ .name = "explore", .title = .{ .fixed = "Explore" }, .build = Screens.build },
            .{ .name = "subs", .title = .{ .fixed = "Subscriptions" }, .build = Screens.build },
        },
    });
    defer narrow.deinit();
    try narrow.setNav(&.{
        .{ .route = "library", .icon = .library },
        .{ .route = "settings", .icon = .settings },
        .{ .route = "explore", .icon = .compass },
        .{ .route = "subs", .icon = .circle },
    });
    try narrow.navigate("library");
    try narrow.navigate("settings"); // depth 2, so a back control exists
    _ = try narrow.presentSheet("Bir sayfa");
    narrow.setChrome(tr);

    const screen = try render(&narrow);
    defer testing.allocator.free(screen);
    try expectAriaLabel(screen, tr.back);
    try expectLacks(screen, "aria-label=\"Back\"");

    const layers = try renderChrome(&narrow);
    defer testing.allocator.free(layers);
    try expectAriaLabel(layers, tr.close);
    try expectLacks(layers, "aria-label=\"Close\"");
    try expectHiddenName(layers, tr.section);
    try expectLacks(layers, "Section: ");

    // The off-roster marker is the fourth, and it only stands in a row
    // that did not fold — so it needs a viewport the roster fits in.
    var wide = try App.init(testing.allocator, .{
        .viewport = .{ .w = 900, .h = 600 },
        .services = .mocks(),
        .routes = &.{
            .{ .name = "library", .title = .{ .fixed = "Library" }, .build = Screens.build },
            .{ .name = "settings", .title = .{ .fixed = "Settings" }, .build = Screens.build },
            .{ .name = "note", .title = .{ .fixed = "Note" }, .build = Screens.build },
        },
    });
    defer wide.deinit();
    try wide.setNav(&.{
        .{ .route = "library", .icon = .library },
        .{ .route = "settings", .icon = .settings },
    });
    try wide.navigate("note");
    wide.setChrome(tr);

    const bar = try renderChrome(&wide);
    defer testing.allocator.free(bar);
    try expectHiddenName(bar, tr.current_screen);
    try expectLacks(bar, "Current screen: ");
}

test "a chrome word takes the same escape every other string does" {
    var app = try test_app.init(500, 700);
    defer app.deinit();
    _ = try app.presentSheet("Move note");
    // A catalog is a consumer's file, so a chrome word is a consumer's
    // bytes: written raw into an attribute, a quote in one would close
    // the attribute and the rest would be markup.
    app.setChrome(.{ .close = "Close \"x\" & go" });

    const layers = try renderChrome(&app);
    defer testing.allocator.free(layers);
    try expectContains(layers, "aria-label=\"Close &quot;x&quot; &amp; go\"");
}

test "an open sheet is a modal dialog named by its title" {
    var app = try test_app.init(500, 700);
    defer app.deinit();
    const sheet = try app.presentSheet("Move note");
    try app.tree.append(sheet, .{ .text = .{ .content = "Pick a notebook." } });

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
    // The close control the framework installs is named by the
    // framework's own word — no consumer's string can name it, and the
    // word is the app's chrome, not a literal in the serializer.
    try expectAriaLabel(layers, app.chrome.close);
}

test "a picker over a sheet: each layer arrives over a scrim of its own, in paint order" {
    var app = try test_app.init(500, 700);
    defer app.deinit();
    const sheet = try app.presentSheet("Move note");
    const select = try app.tree.appendId(sheet, .{ .select = .{
        .label = "Notebook",
        .options = &.{ "Inbox", "Archive" },
    } });
    try overlays.openPicker(&app, select);

    const layers = try renderChrome(&app);
    defer testing.allocator.free(layers);
    // Document order is the stacking: the generated sheet keeps every
    // modal surface at the scrims' own z-index (its `.scrim` comment
    // says why), so the emission order here *is* the paint order the
    // reference draws in (`render`, `drawOverScrim` per layer) — and
    // the scrim emitted after the sheet, the picker's, is what dims
    // the sheet.
    const scrim = "<div class=\"scrim\"></div>";
    const sheet_at = std.mem.indexOf(u8, layers, "<div class=\"sheet\"").?;
    const picker_at = std.mem.indexOf(u8, layers, "<div class=\"picker\"").?;
    const first_scrim = std.mem.indexOf(u8, layers, scrim).?;
    const second_scrim = std.mem.indexOfPos(u8, layers, sheet_at, scrim).?;
    try testing.expect(first_scrim < sheet_at);
    try testing.expect(sheet_at < second_scrim);
    try testing.expect(second_scrim < picker_at);
}

// -------------------------------------------------------- stylesheet

test "the root class list is the sheet's own, and the reserve is layout's answer" {
    var app = try test_app.init(400, 600);
    defer app.deinit();
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    var em: serialize.Emitter = .{ .gpa = testing.allocator, .app = &app, .out = &out };
    defer em.deinit();

    // A bare screen owes no bottom reserve. A host document that wrote
    // the modifier unconditionally — which is all a host could do while
    // the list was a string it typed — ends every plain page in 96px of
    // nothing.
    const plain = serialize.rootClass(&em);
    try testing.expectEqualStrings("nokre", plain);
    app.notify(.{ .title = "Sync failed", .important = true });
    const chromed = serialize.rootClass(&em);
    try testing.expectEqualStrings("nokre has-chrome", chromed);

    // And what the sheet selects on is what a host is handed, derived
    // here rather than typed so the two cannot drift. The compound
    // selector wants both classes on the one element, which is the
    // shape a hand-assembled list gets wrong: the modifier alone
    // matches nothing at all.
    var css: std.ArrayList(u8) = .empty;
    defer css.deinit(testing.allocator);
    try stylesheet.write(testing.allocator, &css, .{});
    for ([_][]const u8{ plain, chromed }) |list| {
        const selector = try std.mem.replaceOwned(u8, testing.allocator, list, " ", ".");
        defer testing.allocator.free(selector);
        const rule = try std.fmt.allocPrint(testing.allocator, "\n.{s} {{", .{selector});
        defer testing.allocator.free(rule);
        try expectContains(css.items, rule);
    }
}

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

test "the modal surfaces share the scrims' z-index, so document order is the stacking" {
    var css: std.ArrayList(u8) = .empty;
    defer css.deinit(testing.allocator);
    try stylesheet.write(testing.allocator, &css, .{});

    // The per-layer scrims only work if neither half of a pair can be
    // hoisted over the other: with one z for both, the serializer's
    // emission order — scrim, then surface, layer by layer — is the
    // paint order, exactly as the reference's `render` sequences its
    // `drawOverScrim` calls. Two z levels was the bug this pins: every
    // scrim sat under every surface, and a picker opened from a sheet
    // never dimmed it.
    const zOf = struct {
        fn zOf(sheet_css: []const u8, selector: []const u8) ![]const u8 {
            const rule = std.mem.indexOf(u8, sheet_css, selector) orelse return error.SelectorMissing;
            const close = std.mem.indexOfScalarPos(u8, sheet_css, rule, '}') orelse return error.UnclosedRule;
            const block = sheet_css[rule..close];
            const z = std.mem.indexOf(u8, block, "z-index:") orelse return error.NoZIndex;
            const end = std.mem.indexOfScalarPos(u8, block, z, ';') orelse return error.UnterminatedZ;
            return std.mem.trim(u8, block[z + "z-index:".len .. end], " ");
        }
    }.zOf;
    try testing.expectEqualStrings(
        try zOf(css.items, ".scrim {"),
        try zOf(css.items, ".sheet, .notices-pane, .picker {"),
    );
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

test "the driver set carries its own bytes, and the two statements agree" {
    // `driver_files` says which files; `driver_sources` says what is in
    // them, so a generator publishing the driver never has to know that
    // this directory is where they live. Nothing else in the library
    // names `driver_sources` — a `pub const` nobody references is never
    // analyzed — so this test is also the only thing that compiles it.
    const dom = @import("dom.zig");
    try std.testing.expectEqual(dom.driver_files.len, dom.driver_sources.len);
    for (dom.driver_files, dom.driver_sources) |name, src| {
        try std.testing.expectEqualStrings(name, src.name);
        // Every one of the four is a real module, not an empty
        // placeholder: an empty live.js is a blank page at run time.
        try std.testing.expect(src.bytes.len > 0);
    }
}
