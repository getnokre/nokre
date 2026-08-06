//! What the document writer must get right, which is mostly what a
//! driver used to get wrong.
//!
//! The screen inside the file is [serialize_test.zig](serialize_test.zig)'s
//! subject and is not re-asserted here. These are about the file: the
//! two locale attributes, the seams landing where their names say, the
//! ids and the module name reaching the boot script, and the escapes on
//! the two paths whose bytes are not markup.

const std = @import("std");

const app_mod = @import("../../core/app.zig");
const class_names = @import("class_names.zig");
const color = @import("../../core/color.zig");
const document = @import("document.zig");
const driver_files = @import("driver_files.zig");
const element_mod = @import("../../core/element.zig");
const serialize = @import("serialize.zig");
const stylesheet = @import("stylesheet.zig");
const test_app = @import("../../core/test_app.zig");

const App = app_mod.App;
const testing = std.testing;

fn write(app: *App, doc: document.Document) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(testing.allocator);
    var em: serialize.Emitter = .{ .gpa = testing.allocator, .app = app, .out = &out };
    defer em.deinit();
    try document.document(&em, doc);
    return out.toOwnedSlice(testing.allocator);
}

/// The smallest document any of these needs: the two required fields
/// and the two mount points, so a test names only what it is about.
fn plain(title: []const u8) document.Document {
    return .{
        .title = title,
        .stylesheet = "/style.css",
        .chrome_id = "chrome",
        .content_id = "content",
    };
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

// ------------------------------------------------------- lang and dir

test "an app that never chose a locale still says which language it is in" {
    var app = try test_app.init(400, 400);
    defer app.deinit();
    // The precondition the fallback exists for, asserted rather than
    // assumed: `App.locale()` is "" until `setLocale`, and "" is not a
    // language attribute any browser can act on.
    try testing.expectEqualStrings("", app.locale());

    const html = try write(&app, plain("Hello"));
    defer testing.allocator.free(html);
    try expectContains(html, "<html lang=\"en\" dir=\"ltr\" data-direction=\"ltr\">");
    // …and it is the language nokre's own words are in on that page,
    // not a literal typed here.
    try testing.expectEqualStrings("en", element_mod.default_chrome_tag);
}

test "the chosen locale is the document's, and it is the app's answer not the device's" {
    var app = try test_app.init(400, 400);
    defer app.deinit();
    try app.setLocale("fa-IR");
    const html = try write(&app, plain("سلام"));
    defer testing.allocator.free(html);
    try expectContains(html, "lang=\"fa-IR\"");
}

test "direction is two attributes, because one of them styles nothing" {
    var app = try test_app.mirrored(400, 400);
    defer app.deinit();
    const html = try write(&app, plain("Hello"));
    defer testing.allocator.free(html);
    // `dir` is what a browser and assistive tech read; `data-direction`
    // is the only thing the sheet's mirroring rule matches. A page with
    // one of them is announced right and laid out backwards, or the
    // reverse — which is why this asserts the pair and then asserts the
    // sheet still selects on the half it selects on.
    try expectContains(html, "dir=\"rtl\" data-direction=\"rtl\"");

    var css: std.ArrayList(u8) = .empty;
    defer css.deinit(testing.allocator);
    try stylesheet.write(testing.allocator, &css, .{});
    try expectContains(css.items, ":root[data-direction=\"rtl\"]");
}

test "an auto scheme stamps no appearance, because the media query is the design there" {
    var app = try test_app.init(400, 400);
    defer app.deinit();
    try testing.expectEqual(color.Scheme.auto, app.scheme);
    const html = try write(&app, plain("Hello"));
    defer testing.allocator.free(html);
    try expectLacks(html, "data-appearance");

    // …and the sheet's fallback is still whole, which is the half this
    // branch exists to protect: the dark ramp stands down only when the
    // attribute is there.
    var css: std.ArrayList(u8) = .empty;
    defer css.deinit(testing.allocator);
    try stylesheet.write(testing.allocator, &css, .{});
    try expectContains(css.items, ":root:not([data-appearance])");
}

test "a pinned scheme is stamped, and it is the app's answer not the desktop's" {
    var app = try App.init(testing.allocator, .{
        .viewport = .{ .w = 400, .h = 400 },
        .services = .mocks(),
        .scheme = .dark,
    });
    defer app.deinit();
    // The desktop says the opposite. A serialized page that let the
    // media query decide would go light here, on an app pinned dark.
    app.setSystemAppearance(.light);
    const html = try write(&app, plain("Hello"));
    defer testing.allocator.free(html);
    try expectContains(html, "data-appearance=\"dark\"");

    // The attribute's spelling is the sheet's selector, not a literal
    // that only agrees with itself.
    var css: std.ArrayList(u8) = .empty;
    defer css.deinit(testing.allocator);
    try stylesheet.write(testing.allocator, &css, .{});
    try expectContains(css.items, ":root[data-appearance=\"dark\"]");
}

test "a pin the other way is stamped the other way" {
    var app = try App.init(testing.allocator, .{
        .viewport = .{ .w = 400, .h = 400 },
        .services = .mocks(),
        .scheme = .light,
    });
    defer app.deinit();
    app.setSystemAppearance(.dark);
    const html = try write(&app, plain("Hello"));
    defer testing.allocator.free(html);
    try expectContains(html, "data-appearance=\"light\"");
}

// ----------------------------------------------------------- the head

test "the charset is in the first bytes, and the seam is after everything nokre writes" {
    var app = try test_app.init(400, 400);
    defer app.deinit();
    var doc = plain("Hello");
    doc.description = "A page";
    doc.head = "<link rel=\"canonical\" href=\"https://example.com/\">\n";
    const html = try write(&app, doc);
    defer testing.allocator.free(html);

    // A browser stops looking for the charset after the first 1024
    // bytes; the seam is unbounded, so it cannot come first.
    const charset = std.mem.indexOf(u8, html, "<meta charset=\"utf-8\">").?;
    try testing.expect(charset < 1024);
    const canonical = std.mem.indexOf(u8, html, "rel=\"canonical\"").?;
    const head_end = std.mem.indexOf(u8, html, "</head>").?;
    try testing.expect(charset < canonical);
    try testing.expect(canonical < head_end);
    try expectContains(html, "<title>Hello</title>");
    try expectContains(html, "<meta name=\"description\" content=\"A page\">");
    try expectContains(html, "<link rel=\"stylesheet\" href=\"/style.css\">");
}

test "theme-color is the sheet's paper in both ramps, not a pair typed beside it" {
    var app = try test_app.init(400, 400);
    defer app.deinit();
    const html = try write(&app, plain("Hello"));
    defer testing.allocator.free(html);
    const light = try std.fmt.allocPrint(testing.allocator, "(prefers-color-scheme: light)\" content=\"#{x:0>2}{x:0>2}{x:0>2}\"", .{
        color.Gray.paper.byte(.light), color.Gray.paper.byte(.light), color.Gray.paper.byte(.light),
    });
    defer testing.allocator.free(light);
    try expectContains(html, light);
    const dark = try std.fmt.allocPrint(testing.allocator, "(prefers-color-scheme: dark)\" content=\"#{x:0>2}{x:0>2}{x:0>2}\"", .{
        color.Gray.paper.byte(.dark), color.Gray.paper.byte(.dark), color.Gray.paper.byte(.dark),
    });
    defer testing.allocator.free(dark);
    try expectContains(html, dark);
}

test "a title with markup in it is escaped, and so is every id" {
    var app = try test_app.init(400, 400);
    defer app.deinit();
    var doc = plain("<script>&\"");
    doc.content_id = "a\"b";
    const html = try write(&app, doc);
    defer testing.allocator.free(html);
    try expectContains(html, "<title>&lt;script&gt;&amp;&quot;</title>");
    try expectContains(html, "<main id=\"a&quot;b\"");
    // One `<script` in the file, and it is not the title's.
    try testing.expectEqual(@as(usize, 0), std.mem.count(u8, html, "<script>"));
}

// ----------------------------------------------------------- the body

test "the skip link names the content mount, and the sheet has a rule for it" {
    var app = try test_app.init(400, 400);
    defer app.deinit();
    var doc = plain("Hello");
    doc.skip = "Skip to content";
    doc.content_id = "main";
    const html = try write(&app, doc);
    defer testing.allocator.free(html);
    const link = try std.fmt.allocPrint(
        testing.allocator,
        "<a class=\"{s}\" href=\"#main\">Skip to content</a>",
        .{class_names.skip},
    );
    defer testing.allocator.free(link);
    try expectContains(html, link);

    // The half a driver used to forget: an anchor with no rule behind it
    // is a permanent link across the top of every page.
    var css: std.ArrayList(u8) = .empty;
    defer css.deinit(testing.allocator);
    try stylesheet.write(testing.allocator, &css, .{});
    const rule = try std.fmt.allocPrint(testing.allocator, "\n.{s} {{\n", .{class_names.skip});
    defer testing.allocator.free(rule);
    try expectContains(css.items, rule);
}

test "no skip link without words for it" {
    var app = try test_app.init(400, 400);
    defer app.deinit();
    const html = try write(&app, plain("Hello"));
    defer testing.allocator.free(html);
    try expectLacks(html, class_names.skip);
}

test "the content mount carries nokre's class list and the driver's beside it" {
    var app = try test_app.init(400, 400);
    defer app.deinit();
    var doc = plain("Hello");
    doc.content_class = "page";
    const html = try write(&app, doc);
    defer testing.allocator.free(html);
    var em: serialize.Emitter = .{ .gpa = testing.allocator, .app = &app, .out = undefined };
    const expected = try std.fmt.allocPrint(
        testing.allocator,
        "<main id=\"content\" class=\"{s} page\">",
        .{serialize.rootClass(&em)},
    );
    defer testing.allocator.free(expected);
    try expectContains(html, expected);
}

test "chrome comes before content, because the nav leads the focus order" {
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

    var doc = plain("Library");
    doc.body_end = "<footer>MIT</footer>\n";
    const html = try write(&app, doc);
    defer testing.allocator.free(html);

    const chrome_div = std.mem.indexOf(u8, html, "<div id=\"chrome\">").?;
    const nav = std.mem.indexOf(u8, html, "<nav class=\"nav\"").?;
    const main = std.mem.indexOf(u8, html, "<main id=\"content\"").?;
    const h1 = std.mem.indexOf(u8, html, "<h1 id=\"library\">").?;
    const footer = std.mem.indexOf(u8, html, "<footer>").?;
    const body_close = std.mem.indexOf(u8, html, "</body>").?;
    try testing.expect(chrome_div < nav);
    try testing.expect(nav < main);
    try testing.expect(main < h1);
    try testing.expect(h1 < footer);
    try testing.expect(footer < body_close);
}

// ------------------------------------------------------- the boot half

test "a document with no boot is a whole document" {
    var app = try test_app.init(400, 400);
    defer app.deinit();
    const html = try write(&app, plain("Hello"));
    defer testing.allocator.free(html);
    try expectLacks(html, "<script");
    try expectContains(html, "</body>\n</html>\n");
}

test "the boot script names the mount points, the route, and the module the edition ships" {
    const Screens = struct {
        fn build(_: ?*anyopaque, app: *App) anyerror!void {
            try app.tree.append(app.tree.rootId(), .{ .heading = .{ .content = "Docs", .level = .h1 } });
        }
    };
    var app = try App.init(testing.allocator, .{
        .viewport = .{ .w = 900, .h = 600 },
        .services = .mocks(),
        .routes = &.{.{ .name = "docs", .title = .{ .fixed = "Docs" }, .build = Screens.build }},
    });
    defer app.deinit();
    try app.navigate("docs");

    var doc = plain("Docs");
    doc.chrome_id = "chrome";
    doc.content_id = "content";
    doc.boot = .{ .wasm = "/app.wasm", .addressing = .documents, .seed = "/md/docs.md" };
    const html = try write(&app, doc);
    defer testing.allocator.free(html);

    const import = try std.fmt.allocPrint(
        testing.allocator,
        "import {{ mount }} from \"/{s}\";",
        .{driver_files.entry},
    );
    defer testing.allocator.free(import);
    try expectContains(html, import);
    try expectContains(html, "wasm: \"/app.wasm\"");
    try expectContains(html, "into: document.getElementById(\"chrome\")");
    try expectContains(html, "content: document.getElementById(\"content\")");
    try expectContains(html, "addressing: \"documents\"");
    // The route is the router's answer, never a second copy of it: a
    // boot argument naming some other screen builds and paints that one
    // on the way past.
    try expectContains(html, "route: \"docs\"");
    try expectContains(html, "seed: \"/md/docs.md\"");
}

test "the default addressing is mount's own, and says nothing" {
    var app = try test_app.init(400, 400);
    defer app.deinit();
    var doc = plain("Hello");
    doc.boot = .{ .wasm = "/app.wasm" };
    const html = try write(&app, doc);
    defer testing.allocator.free(html);
    try expectLacks(html, "addressing");
    // No route table, so no route: the app is on no screen and the
    // boot argument would be a lie rather than a default.
    try expectLacks(html, "route:");
    try expectLacks(html, "seed:");
}

test "a boot script cannot be closed by a string a driver put in it" {
    var app = try test_app.init(400, 400);
    defer app.deinit();
    var doc = plain("Hello");
    doc.chrome_id = "</script><script>alert(1)</script>";
    doc.boot = .{ .wasm = "a\"b\\c" };
    const html = try write(&app, doc);
    defer testing.allocator.free(html);
    // The block ends exactly once, where the writer ended it. `<` goes
    // out as a hex escape, which closes `</script>`, `<!--` and
    // `<script` in one rule — and HTML escaping would have been the
    // wrong answer here, since a `<script>`'s contents are raw text and
    // `&lt;` there is four characters of nothing.
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, html, "</script>"));
    const script = html[std.mem.indexOf(u8, html, "<script type=\"module\">").?..];
    try expectLacks(script, "&lt;");
    try expectContains(script, "\\x3C/script>");
    try expectContains(html, "wasm: \"a\\\"b\\\\c\"");
    // …and the same id in the markup took the markup escape instead.
    try expectContains(html, "<div id=\"&lt;/script&gt;");
}

// ------------------------------------------------------ the whole file

test "two runs over one tree are byte-identical" {
    var app = try test_app.init(400, 400);
    defer app.deinit();
    try app.tree.append(app.tree.rootId(), .{ .heading = .{ .content = "Docs", .level = .h1 } });
    var doc = plain("Docs");
    doc.skip = "Skip to content";
    doc.boot = .{ .wasm = "/app.wasm", .addressing = .documents };
    const a = try write(&app, doc);
    defer testing.allocator.free(a);
    const b = try write(&app, doc);
    defer testing.allocator.free(b);
    try testing.expectEqualStrings(a, b);
}
