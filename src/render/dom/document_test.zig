//! What the document writer must get right, which is mostly what a
//! driver used to get wrong.
//!
//! The screen inside the file is [serialize_test.zig](serialize_test.zig)'s
//! subject and is not re-asserted here. These are about the file: the
//! two locale attributes, the head seam landing where its name says, the
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
    try expectContains(html, "<html lang=\"en\" dir=\"ltr\" data-direction=\"ltr\" data-nokre=\"document\">");
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

test "a site's header is a roster, and a roster is above the page's own title" {
    const Screens = struct {
        fn build(_: ?*anyopaque, app: *App) anyerror!void {
            try app.tree.setTitle("Pricing");
        }
    };
    var app = try App.init(testing.allocator, .{
        .viewport = .{ .w = 1200, .h = 800 },
        .services = .mocks(),
        .routes = &.{
            .{ .name = "pricing", .title = .{ .fixed = "Pricing" }, .build = Screens.build },
            .{ .name = "docs", .title = .{ .fixed = "Docs" }, .build = Screens.build },
        },
    });
    defer app.deinit();
    try app.setNav(&.{
        .{ .route = "pricing" },
        .{ .route = "docs" },
    });
    try app.navigate("pricing");

    const html = try write(&app, plain("Pricing"));
    defer testing.allocator.free(html);
    // The whole of what a byte seam above the body could not have
    // given: the destinations are a navigation landmark, they are in
    // the chrome mount, and the chrome mount is written before the
    // content mount — so they lead the `h1` in document order and in
    // the focus order both, without a line of CSS reordering anything.
    const bar = std.mem.indexOf(u8, html, "<nav class=\"nav").?;
    const main = std.mem.indexOf(u8, html, "<main id=\"content\"").?;
    const title = std.mem.indexOf(u8, html, "<h1").?;
    try testing.expect(bar < main);
    try testing.expect(main < title);
    try expectContains(html, "aria-current=\"page\">Pricing</a>");
    // And the roster carries no modifier at all, on a page (`plain`)
    // that will never boot. Which shape a reader gets is their window's
    // to decide and the sheet decides it, so a fact about the file has
    // no business in the class list: this page takes the bottom band on
    // a phone exactly as an app shell does.
    try expectContains(html, "<nav class=\"nav\" aria-label=");
}

test "one markup, whether or not anything will ever mount over it" {
    const Screens = struct {
        fn build(_: ?*anyopaque, app: *App) anyerror!void {
            try app.tree.setTitle("Pricing");
        }
    };
    var app = try App.init(testing.allocator, .{
        .viewport = .{ .w = 1200, .h = 800 },
        .services = .mocks(),
        .routes = &.{
            .{ .name = "pricing", .title = .{ .fixed = "Pricing" }, .build = Screens.build },
            .{ .name = "docs", .title = .{ .fixed = "Docs" }, .build = Screens.build },
        },
    });
    defer app.deinit();
    try app.setNav(&.{
        .{ .route = "pricing" },
        .{ .route = "docs" },
    });
    try app.navigate("pricing");

    var doc = plain("Pricing");
    doc.boot = .{ .wasm = "/app.wasm" };
    const booted = try write(&app, doc);
    defer testing.allocator.free(booted);
    const unbooted = try write(&app, plain("Pricing"));
    defer testing.allocator.free(unbooted);

    // The two files differ by the boot script and by nothing else. That
    // is the property a modifier on the nav broke for one release, and
    // breaking it is what took the bottom bar away from a reader who
    // narrowed their window on a published page: the shape is the
    // reader's window's question, the sheet asks it over these bytes,
    // and no fact about the file is a term in it.
    const script = std.mem.indexOf(u8, booted, "<script").?;
    try testing.expectEqualStrings(unbooted[0..script], booted[0..script]);
    try expectContains(booted, "<nav class=\"nav\" aria-label=");
    try expectContains(unbooted, "<nav class=\"nav\" aria-label=");
}

test "a page whose need for a runtime is on the page is refused without one" {
    const Screens = struct {
        fn build(_: ?*anyopaque, app: *App) anyerror!void {
            try app.tree.setTitle("Explore");
        }
    };
    // Narrow enough that the roster cannot make a row, which is the one
    // way a document comes by the collapsed chip: `navCollapses` asked
    // of the viewport the *generator* was run at.
    var app = try App.init(testing.allocator, .{
        .viewport = .{ .w = 320, .h = 640 },
        .services = .mocks(),
        .routes = &.{
            .{ .name = "explore", .title = .{ .fixed = "Explore everything" }, .build = Screens.build },
            .{ .name = "collections", .title = .{ .fixed = "Saved collections" }, .build = Screens.build },
            .{ .name = "account", .title = .{ .fixed = "Your account" }, .build = Screens.build },
        },
    });
    defer app.deinit();
    try app.setNav(&.{
        .{ .route = "explore" },
        .{ .route = "collections" },
        .{ .route = "account" },
    });
    try app.navigate("explore");

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    var em: serialize.Emitter = .{ .gpa = testing.allocator, .app = &app, .out = &out };
    defer em.deinit();
    // The chip opens a list, and a list is opened by an app. With no
    // boot on the page there is none, so the file would publish a
    // control that cannot answer and a crawler would read one button
    // where the site's sections are.
    //
    // It is no longer a rule about the nav, though, and the derivation
    // is what says so: the chip is a `nav_current`, `nav_current` needs
    // a runtime like every other combobox, and this is the tree being
    // read rather than a special case being remembered.
    try testing.expectEqual(
        @as(?element_mod.Role, .nav_current),
        document.needsRuntime(&app),
    );
    try testing.expectError(error.PageNeedsBoot, document.document(&em, plain("Explore")));
    // Before a byte, like every other check this writer makes.
    try testing.expectEqual(@as(usize, 0), out.items.len);

    // The same tree with a module on the page is a working control.
    var booted = plain("Explore");
    booted.boot = .{ .wasm = "/app.wasm" };
    try document.document(&em, booted);
    try expectContains(out.items, "role=\"combobox\"");
}

test "the runtime a page needs is read off the page, not declared beside it" {
    const Screens = struct {
        fn prose(_: ?*anyopaque, app: *App) anyerror!void {
            try app.tree.setTitle("Guide");
            try app.tree.append(app.tree.rootId(), .{ .text = .{ .content = "Words and a link." } });
            try app.tree.append(app.tree.rootId(), .{ .link = .{ .label = "Reference", .route = "guide" } });
            try app.tree.append(app.tree.rootId(), .{ .code_block = .{ .content = "zig build" } });
            try app.tree.append(app.tree.rootId(), .{ .qr = .{ .value = "https://example.com", .label = "This page" } });
        }
        fn control(_: ?*anyopaque, app: *App) anyerror!void {
            try app.tree.setTitle("Guide");
            try app.tree.append(app.tree.rootId(), .{ .copyable = .{ .label = "Key", .value = "abc123" } });
        }
    };
    // Wide enough that the roster is a row, so nothing about the *nav*
    // is answering here: what is under test is the page's own content.
    var app = try App.init(testing.allocator, .{
        .viewport = .{ .w = 1200, .h = 800 },
        .services = .mocks(),
        .routes = &.{
            .{ .name = "guide", .title = .{ .fixed = "Guide" }, .build = Screens.prose },
            .{ .name = "keys", .title = .{ .fixed = "Keys" }, .build = Screens.control },
        },
    });
    defer app.deinit();
    try app.setNav(&.{ .{ .route = "guide" }, .{ .route = "keys" } });
    try app.navigate("guide");

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    var em: serialize.Emitter = .{ .gpa = testing.allocator, .app = &app, .out = &out };
    defer em.deinit();
    // Prose, a link, a code block, a QR and a roster of links: a page
    // that is whole with nothing running, and the browser answers every
    // affordance on it. This is what a static site mostly is, and the
    // refusal must not reach it.
    try testing.expectEqual(@as(?element_mod.Role, null), document.needsRuntime(&app));
    try document.document(&em, plain("Guide"));
    try expectContains(out.items, "Words and a link.");

    // A generator that *pushes* its way from page to page has already
    // failed, and the derivation is what says so rather than a note in
    // a document: a pushed screen wears the framework's Back control,
    // and Back pops a stack no published file has. A site's pages are
    // each their own arrival — `switchTo`, which is also what the live
    // driver boots a generated document with (live.zig).
    try app.navigate("keys");
    try testing.expectEqual(@as(?element_mod.Role, .back), document.needsRuntime(&app));

    // Arrived at properly, the same screen needs a runtime for its own
    // reason and one element: a `copyable` renders as a line of text
    // with a glyph beside it, and every affordance on it — the
    // clipboard write, the acknowledgement mark — is an app's.
    try app.switchTo("keys");
    try testing.expectEqual(@as(?element_mod.Role, .copyable), document.needsRuntime(&app));
    out.clearRetainingCapacity();
    try testing.expectError(error.PageNeedsBoot, document.document(&em, plain("Keys")));

    // A driver may still publish a runtime the tree cannot ask for —
    // the page whose static shape is deliberately inert because what it
    // will show has not been fetched. The derivation is a floor, and
    // this direction is the one that is never refused.
    try app.switchTo("guide");
    var seeded = plain("Guide");
    seeded.boot = .{ .wasm = "/app.wasm" };
    out.clearRetainingCapacity();
    try document.document(&em, seeded);
    try expectContains(out.items, "app.wasm");
}

test "a tile that navigates needs nothing, and the one beside it that acts needs everything" {
    const Screens = struct {
        fn press(_: ?*anyopaque) void {}
        fn hub(_: ?*anyopaque, app: *App) anyerror!void {
            const group = try app.tree.appendId(app.tree.rootId(), .{ .tile_group = .{} });
            try app.tree.append(group, .{ .tile = .{ .label = "Guide", .route = "guide" } });
            try app.tree.append(group, .{ .tile = .{ .label = "Things", .route = "things" } });
        }
        fn things(_: ?*anyopaque, app: *App) anyerror!void {
            const group = try app.tree.appendId(app.tree.rootId(), .{ .tile_group = .{} });
            try app.tree.append(group, .{ .tile = .{ .label = "Guide", .route = "guide" } });
            try app.tree.append(group, .{ .tile = .{ .label = "Sign out", .on_press = .{ .call = press } } });
        }
        fn bare(_: ?*anyopaque, _: *App) anyerror!void {}
    };
    var app = try App.init(testing.allocator, .{
        .viewport = .{ .w = 1200, .h = 800 },
        .services = .mocks(),
        .routes = &.{
            .{ .name = "hub", .title = .{ .fixed = "Hub" }, .build = Screens.hub },
            .{ .name = "things", .title = .{ .fixed = "Things" }, .build = Screens.things },
            .{ .name = "guide", .title = .{ .fixed = "Guide" }, .build = Screens.bare },
        },
    });
    defer app.deinit();
    try app.navigate("hub");

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    var em: serialize.Emitter = .{ .gpa = testing.allocator, .app = &app, .out = &out };
    defer em.deinit();

    // Rows that navigate are anchors — the serializer has always said so
    // — and an anchor is answered by the browser. A census over the
    // *role* could not see that, so a hub of pure navigation carried a
    // module its readers would never run, and a floor cannot be
    // declined.
    try testing.expectEqual(@as(?element_mod.Role, null), document.needsRuntime(&app));
    try document.document(&em, plain("Hub"));
    try expectContains(out.items, "<a class=\"tile\"");
    try expectLacks(out.items, "<script");

    // One row that acts is a button in row clothing, and the page it is
    // on is refused. The two screens differ by that row and nothing
    // else.
    try app.switchTo("things");
    try testing.expectEqual(@as(?element_mod.Role, .tile), document.needsRuntime(&app));
    out.clearRetainingCapacity();
    try testing.expectError(error.PageNeedsBoot, document.document(&em, plain("Things")));
}

test "a footer is content, so the body carries nothing and the screen is still last" {
    var app = try test_app.init(400, 400);
    defer app.deinit();
    // The shape a footer takes now: a stack of links and a line, the
    // last thing the page builder appends. It is *in the screen*, which
    // is the whole of the change — `Document.body_end` used to splice
    // the same footer after `</main>`, and `<body>` grew a class saying
    // so, because the reserve had to find the box the footer was in.
    const root = app.tree.rootId();
    const stack = try app.tree.appendId(root, .{ .stack = .{} });
    try app.tree.append(stack, .{ .link = .{ .label = "Colophon", .route = "colophon" } });
    try app.tree.append(stack, .{ .link = .{
        .label = "Source",
        .external = "https://github.com/getnokre/nokre",
    } });
    try app.tree.append(stack, .{ .text = .{ .content = "© nokre" } });

    const html = try write(&app, plain("Hello"));
    defer testing.allocator.free(html);

    // No class on the body, on any page: there is nothing left that
    // could put anything below the screen.
    try expectContains(html, "\n<body>\n");
    // And the footer is inside the screen's own element, which is the
    // box the reserve has always been on.
    const screen_end = std.mem.indexOf(u8, html, "</main>").?;
    const link = std.mem.indexOf(u8, html, "Colophon").?;
    const line = std.mem.indexOf(u8, html, "© nokre").?;
    try testing.expect(link < screen_end);
    try testing.expect(line < screen_end);
    // Nothing at all stands between the screen and the document's end.
    try expectContains(html, "</main>\n</body>\n</html>\n");
    // The links are nokre's own, which is the styling half: a seam's
    // anchor kept the UA's underline and colour because no scoped rule
    // reached it. This one carries the class the sheet selects on, and
    // its route went through `Refs`.
    try expectContains(html, "<a class=\"link block\" href=\"#colophon\">Colophon</a>");
    try expectContains(html, "rel=\"noopener noreferrer\"");
}

test "a document nokre wrote whole says so, and the sheet paints the page for it" {
    var app = try test_app.init(400, 400);
    defer app.deinit();
    const html = try write(&app, plain("Hello"));
    defer testing.allocator.free(html);
    try expectContains(html, "data-nokre=\"document\"");

    var css: std.ArrayList(u8) = .empty;
    defer css.deinit(testing.allocator);
    try stylesheet.write(testing.allocator, &css, .{});
    // The block, and the fact that it is the *body* it reaches. Two
    // things in a generated page are outside both mounts: the skip link,
    // which would otherwise render in the browser's default serif, and
    // the band of page beside a screen a driver centred in a column of
    // its own, which would otherwise be the UA canvas.
    const at = std.mem.indexOf(u8, css.items, ":root[data-nokre=\"document\"] body {").?;
    const block_end = std.mem.indexOfPos(u8, css.items, at, "\n}").?;
    try expectContains(css.items[at..block_end], "font-family: prose");
    try expectContains(css.items[at..block_end], "background: var(--paper)");
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

// ------------------------------------------- canonical, OG, the card

/// A `Meta` with the two required halves and nothing else, so each test
/// below names only what it is about.
fn sited(path: ?[]const u8) document.Meta {
    return .{ .origin = "https://example.com", .path = path };
}

test "og:url is the canonical URL because there is one field behind both" {
    var app = try test_app.init(400, 400);
    defer app.deinit();
    var doc = plain("Accessibility — nokre");
    doc.description = "The a11y contract.";
    doc.meta = sited("/accessibility/");
    const html = try write(&app, doc);
    defer testing.allocator.free(html);

    try expectContains(html, "<link rel=\"canonical\" href=\"https://example.com/accessibility/\">");
    try expectContains(html, "<meta property=\"og:url\" content=\"https://example.com/accessibility/\">");
    // Both absolute, and both the same URL — asserted as the property
    // rather than as two literals, since the whole claim is that no
    // second field exists to drift.
    const canonical = html[std.mem.indexOf(u8, html, "rel=\"canonical\" href=\"").? + "rel=\"canonical\" href=\"".len ..];
    const c_url = canonical[0..std.mem.indexOfScalar(u8, canonical, '"').?];
    const og = html[std.mem.indexOf(u8, html, "og:url\" content=\"").? + "og:url\" content=\"".len ..];
    const o_url = og[0..std.mem.indexOfScalar(u8, og, '"').?];
    try testing.expectEqualStrings(c_url, o_url);
    try testing.expect(std.mem.startsWith(u8, c_url, "https://"));

    // The description falls through from the document rather than being
    // stated twice, and the title likewise.
    try expectContains(html, "<meta property=\"og:description\" content=\"The a11y contract.\">");
    try expectContains(html, "<meta property=\"og:title\" content=\"Accessibility — nokre\">");
}

test "a page with no URL of its own claims none, and cannot be made to" {
    var app = try test_app.init(400, 400);
    defer app.deinit();
    var doc = plain("Not found — nokre");
    doc.description = "No page here.";
    doc.meta = sited(null);
    const html = try write(&app, doc);
    defer testing.allocator.free(html);

    // The 404 body is served at whatever address missed. A canonical or
    // an `og:url` here would name a URL nobody is meant to arrive at,
    // and `null` is the only way to say it — the string and the flag
    // that would let a driver keep one is not a shape this type has.
    try expectLacks(html, "canonical");
    try expectLacks(html, "og:url");
    // Everything that is *about the page* rather than about where it
    // lives still goes out: a shared 404 is still a preview.
    try expectContains(html, "<meta property=\"og:title\" content=\"Not found — nokre\">");
    try expectContains(html, "<meta property=\"og:description\" content=\"No page here.\">");
    try expectContains(html, "twitter:card");
}

test "the preview headline may differ from the tab's, and the site name is beside it" {
    var app = try test_app.init(400, 400);
    defer app.deinit();
    var doc = plain("Accessibility — nokre");
    doc.description = "The tab sentence.";
    var m = sited("/accessibility/");
    m.site_name = "nokre";
    m.title = "Accessibility";
    m.description = "The card sentence.";
    m.kind = "article";
    doc.meta = m;
    const html = try write(&app, doc);
    defer testing.allocator.free(html);

    // The card already shows the site's name, so the `<title>` suffix
    // there would be the site named twice.
    try expectContains(html, "<meta property=\"og:site_name\" content=\"nokre\">");
    try expectContains(html, "<meta property=\"og:title\" content=\"Accessibility\">");
    try expectContains(html, "<meta property=\"og:description\" content=\"The card sentence.\">");
    try expectContains(html, "<meta property=\"og:type\" content=\"article\">");
    // …and the `<title>` and the description meta are untouched by it.
    try expectContains(html, "<title>Accessibility — nokre</title>");
    try expectContains(html, "<meta name=\"description\" content=\"The tab sentence.\">");
}

test "no description anywhere writes no empty tag" {
    var app = try test_app.init(400, 400);
    defer app.deinit();
    var doc = plain("Hello");
    doc.meta = sited("/");
    const html = try write(&app, doc);
    defer testing.allocator.free(html);
    try expectLacks(html, "og:description");
    try expectLacks(html, "og:site_name");
    // The type has a default because `website` is Open Graph's own, not
    // a preference of this library's.
    try expectContains(html, "<meta property=\"og:type\" content=\"website\">");
}

test "a site with no artwork gets a text card, which is the only card it can get" {
    var app = try test_app.init(400, 400);
    defer app.deinit();
    var doc = plain("Hello");
    doc.meta = sited("/");
    const html = try write(&app, doc);
    defer testing.allocator.free(html);
    try expectLacks(html, "og:image");
    // `summary_large_image` with no image is a card with a blank frame.
    // It is unstatable here: the shape lives on the picture.
    try expectContains(html, "<meta name=\"twitter:card\" content=\"summary\">");
    try expectLacks(html, "twitter:image");
}

test "the image is a URL in a tag, absolute against the same origin" {
    var app = try test_app.init(400, 400);
    defer app.deinit();
    var doc = plain("Hello");
    var m = sited("/");
    m.image = .{
        .path = "/og-image.png",
        .alt = "Rokovski — anonymous feedback that matters.",
        .shape = .banner,
        .size = .{ .w = 1200, .h = 630 },
    };
    doc.meta = m;
    const html = try write(&app, doc);
    defer testing.allocator.free(html);

    try expectContains(html, "<meta property=\"og:image\" content=\"https://example.com/og-image.png\">");
    try expectContains(html, "<meta property=\"og:image:alt\" content=\"Rokovski — anonymous feedback that matters.\">");
    try expectContains(html, "<meta property=\"og:image:width\" content=\"1200\">");
    try expectContains(html, "<meta property=\"og:image:height\" content=\"630\">");
    // A banner is the one thing `twitter:card` says that Open Graph
    // does not.
    try expectContains(html, "<meta name=\"twitter:card\" content=\"summary_large_image\">");
    // The alt is written twice on purpose: Twitter documents an `og:`
    // fallback for the title, the description and the image, and none
    // for the alternative text.
    try expectContains(html, "<meta name=\"twitter:image:alt\" content=\"Rokovski — anonymous feedback that matters.\">");
    // …and nothing else of Twitter's, because every one of those four
    // is a second copy of a string already on this page.
    try expectLacks(html, "twitter:title");
    try expectLacks(html, "twitter:description");
    try expectLacks(html, "<meta name=\"twitter:image\" ");
}

test "a square mark is a thumbnail, and says so" {
    var app = try test_app.init(400, 400);
    defer app.deinit();
    var doc = plain("Hello");
    var m = sited("/");
    m.image = .{ .path = "/mark.png", .shape = .thumbnail };
    doc.meta = m;
    const html = try write(&app, doc);
    defer testing.allocator.free(html);
    try expectContains(html, "<meta property=\"og:image\" content=\"https://example.com/mark.png\">");
    try expectContains(html, "<meta name=\"twitter:card\" content=\"summary\">");
    // No dimensions stated is no dimensions written, rather than zeros.
    try expectLacks(html, "og:image:width");
    try expectLacks(html, "og:image:alt");
}

test "Open Graph is property and Twitter is name, which is the pair a head gets wrong" {
    var app = try test_app.init(400, 400);
    defer app.deinit();
    var doc = plain("Hello");
    var m = sited("/");
    m.site_name = "nokre";
    m.image = .{ .path = "/og.png", .shape = .banner };
    doc.meta = m;
    const html = try write(&app, doc);
    defer testing.allocator.free(html);
    // Every `og:` is RDFa's `property`; every `twitter:` is a plain
    // `name`. Asserted as a sweep rather than tag by tag, so a tag added
    // later cannot arrive with the wrong one.
    var it = std.mem.splitScalar(u8, html, '\n');
    var og: usize = 0;
    var tw: usize = 0;
    while (it.next()) |line| {
        if (std.mem.indexOf(u8, line, "\"og:") != null) {
            og += 1;
            try testing.expect(std.mem.startsWith(u8, line, "<meta property=\"og:"));
        }
        if (std.mem.indexOf(u8, line, "\"twitter:") != null) {
            tw += 1;
            try testing.expect(std.mem.startsWith(u8, line, "<meta name=\"twitter:"));
        }
    }
    try testing.expect(og >= 5);
    try testing.expect(tw >= 1);
}

test "no meta is a document that is not a page on a site" {
    var app = try test_app.init(400, 400);
    defer app.deinit();
    var doc = plain("Hello");
    doc.description = "A page";
    const html = try write(&app, doc);
    defer testing.allocator.free(html);
    // An app shell booting into an empty body has no URL, no card and
    // nothing to preview. The description meta is the document's own and
    // stays.
    try expectLacks(html, "canonical");
    try expectLacks(html, "og:");
    try expectLacks(html, "twitter:");
    try expectContains(html, "<meta name=\"description\" content=\"A page\">");
}

test "a relative origin or an unrooted path fails the build, before a byte is written" {
    var app = try test_app.init(400, 400);
    defer app.deinit();

    const cases = [_]struct { m: document.Meta, want: anyerror }{
        .{ .m = .{ .origin = "example.com", .path = "/" }, .want = error.OriginNotAbsolute },
        .{ .m = .{ .origin = "", .path = "/" }, .want = error.OriginNotAbsolute },
        .{ .m = .{ .origin = "https://example.com/", .path = "/" }, .want = error.OriginEndsInSlash },
        .{ .m = .{ .origin = "https://example.com", .path = "accessibility/" }, .want = error.PathNotRooted },
        // The empty path is the same mistake: it would name the origin
        // itself, which is a real URL and the wrong one.
        .{ .m = .{ .origin = "https://example.com", .path = "" }, .want = error.PathNotRooted },
        .{
            .m = .{ .origin = "https://example.com", .image = .{ .path = "og.png", .shape = .banner } },
            .want = error.PathNotRooted,
        },
    };
    for (cases) |c| {
        var doc = plain("Hello");
        doc.meta = c.m;
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(testing.allocator);
        var em: serialize.Emitter = .{ .gpa = testing.allocator, .app = &app, .out = &out };
        defer em.deinit();
        try testing.expectError(c.want, document.document(&em, doc));
        // Nothing on disk and nothing in the buffer: the check runs
        // before the doctype, so a failed build leaves no half-file.
        try testing.expectEqual(@as(usize, 0), out.items.len);
    }
}

test "every string in the head takes the attribute escape, destinations included" {
    var app = try test_app.init(400, 400);
    defer app.deinit();
    var doc = plain("Hello");
    var m: document.Meta = .{
        .origin = "https://example.com",
        .path = "/a\"b/",
        .site_name = "a<b",
        .kind = "we\"bsite",
        .title = "a&b",
        .description = "x<y",
    };
    m.image = .{ .path = "/o\"g.png", .alt = "a\"lt", .shape = .banner };
    doc.meta = m;
    const html = try write(&app, doc);
    defer testing.allocator.free(html);
    // A quote in any of these would close the attribute and leave the
    // rest of the URL as markup — the injection a `print` with `{s}`
    // ships, which is why every one of them goes through `text`.
    try expectContains(html, "href=\"https://example.com/a&quot;b/\"");
    try expectContains(html, "og:url\" content=\"https://example.com/a&quot;b/\"");
    try expectContains(html, "og:site_name\" content=\"a&lt;b\"");
    try expectContains(html, "og:type\" content=\"we&quot;bsite\"");
    try expectContains(html, "og:title\" content=\"a&amp;b\"");
    try expectContains(html, "og:description\" content=\"x&lt;y\"");
    try expectContains(html, "og:image\" content=\"https://example.com/o&quot;g.png\"");
    try expectContains(html, "og:image:alt\" content=\"a&quot;lt\"");
    try expectContains(html, "twitter:image:alt\" content=\"a&quot;lt\"");
}

test "the meta block is nokre's, so it precedes the driver's seam" {
    var app = try test_app.init(400, 400);
    defer app.deinit();
    var doc = plain("Hello");
    doc.meta = sited("/");
    doc.head = "<link rel=\"icon\" href=\"/favicon.svg\">\n";
    const html = try write(&app, doc);
    defer testing.allocator.free(html);
    const charset = std.mem.indexOf(u8, html, "<meta charset=").?;
    const canonical = std.mem.indexOf(u8, html, "rel=\"canonical\"").?;
    const seam = std.mem.indexOf(u8, html, "rel=\"icon\"").?;
    const head_end = std.mem.indexOf(u8, html, "</head>").?;
    try testing.expect(charset < canonical);
    try testing.expect(canonical < seam);
    try testing.expect(seam < head_end);
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

test "a mount holds the frame's bytes and no whitespace of the file's own" {
    const Screens = struct {
        fn build(_: ?*anyopaque, app: *App) anyerror!void {
            try app.tree.setTitle("Library");
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
    // A roster, so the chrome mount is not empty and has something to
    // be wrong about.
    try app.setNav(&.{
        .{ .route = "library", .icon = .library },
        .{ .route = "settings", .icon = .settings },
    });
    try app.navigate("library");

    // With a boot on it, because that is the only kind of page a live
    // frame ever lands on — and because the file and the frame have to
    // be the same bytes, which is what puts `no_boot` on the file rather
    // than on the shape: a class the file carried and the frame did not
    // would be this assertion failing at the nav's own open tag.
    var doc = plain("Library");
    doc.boot = .{ .wasm = "/app.wasm" };
    const html = try write(&app, doc);
    defer testing.allocator.free(html);

    // The live driver's frame is `chrome` followed by `content` with
    // nothing between or around them, and its first frame is diffed
    // against these two mounts' children node for node. One newline
    // after an open tag is a text node the frame does not have: the
    // walk then pairs the file's first child against the frame's
    // second, disagrees, and replaces it — and every sibling after it.
    // That is a boot that repaints instead of patching, which costs the
    // reader's scroll offset, their selection and their caret (live.js's
    // `patch`). So the seam is asserted as bytes rather than as a
    // substring: what follows the open tag is the region, exactly.
    var region: std.ArrayList(u8) = .empty;
    defer region.deinit(testing.allocator);

    {
        var em: serialize.Emitter = .{ .gpa = testing.allocator, .app = &app, .out = &region };
        defer em.deinit();
        try serialize.chrome(&em);
    }
    const chrome_open = "<div id=\"chrome\">";
    const chrome_at = std.mem.indexOf(u8, html, chrome_open).? + chrome_open.len;
    try testing.expectEqualStrings(region.items, html[chrome_at..][0..region.items.len]);
    try expectContains(html, "</div>\n<main id=\"content\"");

    region.clearRetainingCapacity();
    {
        var em: serialize.Emitter = .{ .gpa = testing.allocator, .app = &app, .out = &region };
        defer em.deinit();
        try serialize.content(&em);
    }
    const main_at = std.mem.indexOf(u8, html, "<main id=\"content\"").?;
    const content_at = main_at + std.mem.indexOf(u8, html[main_at..], "\">").? + 2;
    try testing.expectEqualStrings(region.items, html[content_at..][0..region.items.len]);
    try expectContains(html, "</main>\n");
}

test "chrome comes before content, because the nav leads the focus order" {
    const Screens = struct {
        fn build(_: ?*anyopaque, app: *App) anyerror!void {
            try app.tree.setTitle("Library");
            // The last thing the builder appends, which is where a
            // footer goes: the destinations lead the title in the
            // markup and the footer trails everything, all four inside
            // one document order rather than three plus a seam.
            try app.tree.append(app.tree.rootId(), .{ .text = .{ .content = "MIT" } });
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

    const html = try write(&app, plain("Library"));
    defer testing.allocator.free(html);

    const chrome_div = std.mem.indexOf(u8, html, "<div id=\"chrome\">").?;
    const nav = std.mem.indexOf(u8, html, "<nav class=\"nav").?;
    const main = std.mem.indexOf(u8, html, "<main id=\"content\"").?;
    const h1 = std.mem.indexOf(u8, html, "<h1 id=\"library\">").?;
    const footer = std.mem.indexOf(u8, html, "MIT").?;
    const main_close = std.mem.indexOf(u8, html, "</main>").?;
    const body_close = std.mem.indexOf(u8, html, "</body>").?;
    try testing.expect(chrome_div < nav);
    try testing.expect(nav < main);
    try testing.expect(main < h1);
    try testing.expect(h1 < footer);
    try testing.expect(footer < main_close);
    try testing.expect(main_close < body_close);
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
            try app.tree.setTitle("Docs");
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

    // The module is a file the site serves, named out of the set that
    // is data precisely so nobody types it twice — and the tag is
    // `src`, not a block, which is what a page under
    // `script-src 'self'` can carry at all.
    const tag = try std.fmt.allocPrint(
        testing.allocator,
        "<script type=\"module\" src=\"/{s}\"></script>",
        .{driver_files.boot_entry},
    );
    defer testing.allocator.free(tag);
    try expectContains(html, tag);

    // And the whole of what differs from page to page is one JSON
    // block, whose keys are `mount`'s own option names because
    // live-boot.js spreads it straight in. The route is the router's
    // answer, never a second copy of it: a boot argument naming some
    // other screen builds and paints that one on the way past.
    try expectContains(html,
        \\<script type="application/json" data-nokre="boot">{"wasm":"/app.wasm","into":"chrome","content":"content","addressing":"documents","route":"docs","locale":"","seed":"/md/docs.md"}</script>
    );
    // The data leads the code: a module is deferred so the order does
    // not decide this one, but the two blocks are one arrangement with
    // the stub's, where it does.
    try testing.expect(std.mem.indexOf(u8, html, "application/json").? <
        std.mem.indexOf(u8, html, "type=\"module\"").?);
}

test "a booting page carries no executable byte of its own" {
    var app = try test_app.init(400, 400);
    defer app.deinit();
    var doc = plain("Hello");
    doc.boot = .{ .wasm = "/app.wasm", .seed = "/seed.json" };
    const html = try write(&app, doc);
    defer testing.allocator.free(html);

    // The claim the whole shape exists for, read out of the output: a
    // policy of `script-src 'self'` admits a `src` and never has to
    // look at a data block, so every `<script` here is one or the
    // other. An inline one would put a site's whole directive back on
    // `'unsafe-inline'`, which is what the first migration had to do
    // for 1,132 blocks the library wrote itself.
    var at: usize = 0;
    var seen: usize = 0;
    while (std.mem.indexOfPos(u8, html, at, "<script")) |i| {
        const close = std.mem.indexOfScalarPos(u8, html, i, '>').?;
        const open_tag = html[i .. close + 1];
        try testing.expect(std.mem.indexOf(u8, open_tag, " src=\"") != null or
            std.mem.indexOf(u8, open_tag, "type=\"application/json\"") != null);
        at = close + 1;
        seen += 1;
    }
    try testing.expectEqual(@as(usize, 2), seen);
}

test "the boot call carries the language the file was written in" {
    var app = try test_app.mirrored(400, 400);
    defer app.deinit();
    try app.setLocale("fa-IR");
    var doc = plain("سلام");
    doc.boot = .{ .wasm = "/app.wasm", .addressing = .documents };
    const html = try write(&app, doc);
    defer testing.allocator.free(html);

    // The markup on this page is Persian and the module about to land
    // on it must rebuild it in Persian. It would not: `mount` seeds
    // `navigator.language` where a page says nothing, and hydration
    // matches nodes by tag and position — never by text — so an English
    // boot over this file swaps every string, flips the direction back,
    // keeps the reader's scroll offset, and reports nothing at all.
    try expectContains(html, "lang=\"fa-IR\"");
    try expectContains(html, "\"locale\":\"fa-IR\"");
    // Both from one read of `App.locale()`: there is no `Boot` field
    // beside `lang` for a driver to set differently.
    try expectLacks(html, "\"locale\":\"en\"");
}

test "an app that chose no locale pins the empty tag, not the attribute's fallback" {
    var app = try test_app.init(400, 400);
    defer app.deinit();
    var doc = plain("Hello");
    doc.boot = .{ .wasm = "/app.wasm" };
    const html = try write(&app, doc);
    defer testing.allocator.free(html);

    // The two spellings of one fact, and the place they legitimately
    // differ. `lang` cannot be empty — no browser, screen reader or
    // hyphenation table can act on "" — so it falls back to the
    // language nokre's own words are in. The boot must not: this file
    // was rendered from the app's catalog *template*, whatever language
    // that is, and "" is the tag that resolves back to it (`L.resolve`).
    // Pinning "en" here would boot an English catalog over a page a
    // Persian-template app wrote — the defect, re-introduced by the
    // fallback.
    try expectContains(html, "<html lang=\"en\"");
    try expectContains(html, "\"locale\":\"\"");
    // …and it is written even though it is empty, because an *absent*
    // `locale` is `mount`'s "follow the device", which is the answer for
    // an app shell booting into an empty body and not for a page that
    // already has a screen in it. The other three optionals are absent
    // here and mean it, which is why an empty string cannot be spelled
    // by leaving the key off.
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, html, "\"locale\""));
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
    try expectLacks(html, "\"route\"");
    try expectLacks(html, "\"seed\"");
}

test "both scripts are loaded out of the directory the driver published the set under" {
    var app = try test_app.init(400, 400);
    defer app.deinit();

    var doc = plain("Hello");
    doc.boot = .{ .wasm = "/app.wasm", .driver_dir = "/nokre/" };
    const html = try write(&app, doc);
    defer testing.allocator.free(html);
    const boot = try std.fmt.allocPrint(
        testing.allocator,
        "src=\"/nokre/{s}\"",
        .{driver_files.boot_entry},
    );
    defer testing.allocator.free(boot);
    try expectContains(html, boot);

    // The stub takes the same field for the same reason: it loads a
    // file too, and nokre does not know where a site put one.
    var stub = plainStub();
    stub.driver_dir = "/nokre/";
    const page = try writeStub(&app, stub);
    defer testing.allocator.free(page);
    const chooser = try std.fmt.allocPrint(
        testing.allocator,
        "src=\"/nokre/{s}\"",
        .{driver_files.stub_entry},
    );
    defer testing.allocator.free(chooser);
    try expectContains(page, chooser);
}

test "a boot script cannot be closed by a string a driver put in it" {
    var app = try test_app.init(400, 400);
    defer app.deinit();
    var doc = plain("Hello");
    doc.chrome_id = "</script><script>alert(1)</script>";
    doc.boot = .{ .wasm = "a\"b\\c" };
    // Not only the driver's strings: the locale tag reaches the same
    // block, and `setLocale` takes the bytes an app hands it.
    try app.setLocale("</script>");
    const html = try write(&app, doc);
    defer testing.allocator.free(html);
    // The data block ends exactly once, where the writer ended it — the
    // module tag beside it is self-closing markup with no raw text in
    // it at all, so the two `</script>` in the file are the two the
    // writer wrote. `<` goes out of the block as `\u003C`, which is
    // JSON's own escape and closes `</script`, `<!--` and `<script`
    // together; HTML escaping would have been the wrong answer, since a
    // `<script>`'s contents are raw text and `&lt;` there is four
    // characters of nothing.
    try testing.expectEqual(@as(usize, 2), std.mem.count(u8, html, "</script>"));
    const block = html[std.mem.indexOf(u8, html, "application/json").?..];
    const ends = std.mem.indexOf(u8, block, "</script>").?;
    try expectLacks(block[0..ends], "&lt;");
    try expectContains(block[0..ends], "\\u003C/script>");
    try expectContains(html, "\"wasm\":\"a\\\"b\\\\c\"");
    try expectContains(html, "\"locale\":\"\\u003C/script>\"");
    // …and the same id in the markup took the markup escape instead.
    try expectContains(html, "<div id=\"&lt;/script&gt;");
}

// ------------------------------------------------------ the whole file

test "two runs over one tree are byte-identical" {
    var app = try test_app.init(400, 400);
    defer app.deinit();
    try app.tree.setTitle("Docs");
    var doc = plain("Docs");
    doc.skip = "Skip to content";
    doc.boot = .{ .wasm = "/app.wasm", .addressing = .documents };
    const a = try write(&app, doc);
    defer testing.allocator.free(a);
    const b = try write(&app, doc);
    defer testing.allocator.free(b);
    try testing.expectEqualStrings(a, b);
}

// ------------------------------------------------------- the locale stub

/// A real `l10n.Bundle`, because the stub's whole shape rests on what
/// `Bundle` generates: `Locale` is built with `@Enum`, and `choices` is
/// an `EnumFieldStruct` over it. A hand-written stand-in with a plain
/// enum would prove the duck typing and not the thing under test. This
/// is the one place under `render/` that names l10n at all, and it is a
/// test — the writer itself takes the bundle as an anonymous comptime
/// type and imports nothing.
const l10n = @import("../../l10n/l10n.zig");

const stub_en_arb =
    \\{ "@@locale": "en", "hello": "Hello" }
;
const stub_fa_arb =
    \\{ "@@locale": "fa", "hello": "سلام" }
;
const L = l10n.Bundle(&.{ stub_en_arb, stub_fa_arb });

fn writeStub(app: *App, stub: document.LocaleStub(L)) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(testing.allocator);
    var em: serialize.Emitter = .{ .gpa = testing.allocator, .app = app, .out = &out };
    defer em.deinit();
    try document.localeStub(&em, L, stub);
    return out.toOwnedSlice(testing.allocator);
}

fn plainStub() document.LocaleStub(L) {
    return .{
        .title = "Choose a language",
        .stylesheet = "/style.css",
        .choices = .{
            .en = .{ .href = "/en/docs/", .label = "English" },
            .fa = .{ .href = "/fa/docs/", .label = "فارسی" },
        },
    };
}

test "every bundled locale gets a link, in the bundle's order" {
    var app = try test_app.init(400, 400);
    defer app.deinit();
    const html = try writeStub(&app, plainStub());
    defer testing.allocator.free(html);

    const en = "<a class=\"link\" href=\"/en/docs/\" hreflang=\"en\" lang=\"en\" dir=\"ltr\">English</a>";
    // The direction is the bundle's answer for the locale, not the
    // app's for the page: this document is in neither.
    const fa = "<a class=\"link\" href=\"/fa/docs/\" hreflang=\"fa\" lang=\"fa\" dir=\"rtl\">فارسی</a>";
    try expectContains(html, en);
    try expectContains(html, fa);
    try testing.expect(std.mem.indexOf(u8, html, en).? < std.mem.indexOf(u8, html, fa).?);
    // Two locales in the bundle, two links on the page. The count is
    // the completeness invariant read out of the output — the type
    // enforces it, and this is what enforcement looks like from here.
    try testing.expectEqual(@as(usize, 2), std.mem.count(u8, html, "<a class=\"link\""));
}

test "the stub is in the template's language, whatever the app is in" {
    var app = try test_app.init(400, 400);
    defer app.deinit();
    // A generation loop leaves the app in whichever locale it wrote
    // last. The stub is not that page and must not claim to be.
    try app.setLocale("fa");
    app.setDirection(.rtl);
    const html = try writeStub(&app, plainStub());
    defer testing.allocator.free(html);
    try expectContains(html, "<html lang=\"en\" dir=\"ltr\" data-direction=\"ltr\" data-nokre=\"document\">");
    // …and it is the same locale the script falls back to, so the
    // document a reader passes through claims the language they are
    // about to be sent to.
    try expectContains(html, "\"fallback\":0");
}

test "the script's data is the bundle's tags and the driver's destinations" {
    var app = try test_app.init(400, 400);
    defer app.deinit();
    const html = try writeStub(&app, plainStub());
    defer testing.allocator.free(html);
    try expectContains(html,
        \\<script type="application/json" data-nokre="locale">{"tags":["en","fa"],"hrefs":["/en/docs/","/fa/docs/"],"fallback":0}</script>
    );
    // The whole resolution, once, in the library's own *file* — a
    // driver states no part of it, cannot state it differently, and
    // does not carry a byte of it in the page. The data leads the
    // script here and has to: a classic script runs where it stands.
    const tag = try std.fmt.allocPrint(
        testing.allocator,
        "<script src=\"/{s}\"></script>",
        .{driver_files.stub_entry},
    );
    defer testing.allocator.free(tag);
    try expectContains(html, tag);
    try testing.expect(std.mem.indexOf(u8, html, "application/json").? <
        std.mem.indexOf(u8, html, tag).?);
    // Nothing else names a script, and nothing on this page is one a
    // policy would have to admit.
    try testing.expectEqual(@as(usize, 2), std.mem.count(u8, html, "<script"));
}

test "the stub carries no screen, no boot and no ids" {
    var app = try test_app.init(400, 400);
    defer app.deinit();
    try app.tree.setTitle("Docs");
    const html = try writeStub(&app, plainStub());
    defer testing.allocator.free(html);
    try expectLacks(html, "Docs");
    try expectLacks(html, "mount(");
    // Spelled with its `=`: the focus-stop id is what has to be absent,
    // and `data-n` alone is also the first seven bytes of the attribute
    // saying who wrote the page (`class_names.document_attr`).
    try expectLacks(html, "data-n=");
    // No mount points either: there is nothing to boot into, so there
    // are no ids for a driver to have invented.
    try expectLacks(html, "id=\"");
}

test "a label cannot end the script block, and takes the other escape in the markup" {
    var app = try test_app.init(400, 400);
    defer app.deinit();
    var stub = plainStub();
    stub.choices.fa = .{ .href = "/fa/</script>/", .label = "</script><script>alert(1)</script>" };
    const html = try writeStub(&app, stub);
    defer testing.allocator.free(html);
    // The stub's data block ends exactly once, where the writer ended
    // it; the second `</script>` is the chooser's own empty tag. Inside
    // the block the driver's bytes went through `Emitter.json`, which
    // is the escape a JSON document in raw text needs; in the anchor
    // the same bytes went through `Emitter.text`, which is the one
    // markup needs. Neither would do the other's job.
    try testing.expectEqual(@as(usize, 2), std.mem.count(u8, html, "</script>"));
    try expectContains(html, "\\u003C/script>");
    try expectContains(html, "&lt;/script&gt;");
}

test "a stub cannot be written with a choice that goes nowhere" {
    var app = try test_app.init(400, 400);
    defer app.deinit();

    var empty_href = plainStub();
    empty_href.choices.fa.href = "";
    try testing.expectError(error.ChoiceHrefEmpty, writeStub(&app, empty_href));

    var empty_label = plainStub();
    empty_label.choices.fa.label = "";
    try testing.expectError(error.ChoiceLabelEmpty, writeStub(&app, empty_label));

    // Two locales at one address: the second language is then
    // unreachable from here and its readers are handed the first's,
    // which is the exact failure the stub exists to prevent.
    var collide = plainStub();
    collide.choices.fa.href = collide.choices.en.href;
    try testing.expectError(error.ChoiceHrefsCollide, writeStub(&app, collide));
}

test "a refused stub leaves no bytes behind" {
    var app = try test_app.init(400, 400);
    defer app.deinit();
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    var em: serialize.Emitter = .{ .gpa = testing.allocator, .app = &app, .out = &out };
    defer em.deinit();
    var bad = plainStub();
    bad.choices.en.href = "";
    try testing.expectError(error.ChoiceHrefEmpty, document.localeStub(&em, L, bad));
    // Checked before the doctype, `checkMeta`'s reason: a half-written
    // file published is worse than a build that failed.
    try testing.expectEqual(@as(usize, 0), out.items.len);
}

test "the stub's head keeps the charset in the first bytes and the seam last" {
    var app = try test_app.init(400, 400);
    defer app.deinit();
    var stub = plainStub();
    stub.head = "<meta name=\"robots\" content=\"noindex\">\n";
    stub.heading = "Choose a language";
    const html = try writeStub(&app, stub);
    defer testing.allocator.free(html);
    const charset = std.mem.indexOf(u8, html, "<meta charset=\"utf-8\">").?;
    const script = std.mem.indexOf(u8, html, "<script").?;
    const seam = std.mem.indexOf(u8, html, "robots").?;
    const head_end = std.mem.indexOf(u8, html, "</head>").?;
    try testing.expect(charset < script);
    try testing.expect(script < seam);
    try testing.expect(seam < head_end);
    // The script is in the head and blocking: everything below it is a
    // page the reader is not meant to see.
    try testing.expect(head_end < std.mem.indexOf(u8, html, "<h1 class=\"s-h1\">Choose a language</h1>").?);
}

// -------------------------------------------------- the alternate set

const alternates = @import("alternates.zig");

/// The set every test below spends: one path per bundled locale, and
/// the stub's unprefixed path beside them. Written once because that is
/// the design — every locale's copy of one page is handed *this* value,
/// which is what makes the annotations reciprocal without a check.
const docs_set = (alternates.Alternates(L){
    .stub = "/docs/",
    .paths = .{ .en = "/en/docs/", .fa = "/fa/docs/" },
}).set();

fn sitedWith(path: []const u8, set: []const alternates.Alternate) document.Meta {
    return .{ .origin = "https://example.com", .path = path, .alternates = set };
}

test "the tags come out of the catalog, and the set is closed by the type" {
    // Three entries for a two-locale bundle: the count is the
    // completeness invariant read out of the derivation. A locale in
    // the bundle and missing from `paths` does not fail here — it fails
    // to compile.
    try testing.expectEqual(@as(usize, 3), docs_set.len);
    try testing.expectEqualStrings("en", docs_set[0].hreflang);
    try testing.expectEqualStrings("/en/docs/", docs_set[0].path);
    try testing.expectEqualStrings("fa", docs_set[1].hreflang);
    try testing.expectEqualStrings("/fa/docs/", docs_set[1].path);
    // The bundle's order, and the two tags are `L.tag`'s answers rather
    // than strings this test typed beside them.
    try testing.expectEqualStrings(L.tag(.en), docs_set[0].hreflang);
    try testing.expectEqualStrings(L.tag(.fa), docs_set[1].hreflang);
}

test "x-default is the stub's address, not the default locale's" {
    const x = docs_set[docs_set.len - 1];
    try testing.expectEqualStrings("x-default", x.hreflang);
    try testing.expectEqualStrings("/docs/", x.path);
    // The one thing that would be indistinguishable if `stub` had a
    // default instead of being required: the template locale is a
    // locale, with a prefixed path of its own like every other, and
    // `x-default` is not it.
    try testing.expectEqual(L.default_locale, .en);
    try testing.expectEqualStrings("/en/docs/", docs_set[0].path);
    try testing.expect(!std.mem.eql(u8, x.path, docs_set[0].path));
}

test "every copy of one page carries the same block, and each is in it" {
    var app = try test_app.init(400, 400);
    defer app.deinit();

    var en_doc = plain("Docs");
    en_doc.meta = sitedWith("/en/docs/", &docs_set);
    const en = try write(&app, en_doc);
    defer testing.allocator.free(en);

    var fa_doc = plain("Docs");
    fa_doc.meta = sitedWith("/fa/docs/", &docs_set);
    const fa = try write(&app, fa_doc);
    defer testing.allocator.free(fa);

    const block =
        \\<link rel="alternate" hreflang="en" href="https://example.com/en/docs/">
        \\<link rel="alternate" hreflang="fa" href="https://example.com/fa/docs/">
        \\<link rel="alternate" hreflang="x-default" href="https://example.com/docs/">
        \\
    ;
    // Reciprocity is not checked, it is the same bytes: one value, two
    // documents. A block that differed between two copies of a page is
    // the failure a search console reports months later, and there is
    // no second derivation here to differ.
    try expectContains(en, block);
    try expectContains(fa, block);
    // Self-inclusion read out of the output: each page's canonical is
    // one of the hrefs above it.
    try expectContains(en, "<link rel=\"canonical\" href=\"https://example.com/en/docs/\">");
    try expectContains(fa, "<link rel=\"canonical\" href=\"https://example.com/fa/docs/\">");
    // And beside the canonical rather than off in the driver's seam.
    try testing.expect(std.mem.indexOf(u8, en, "rel=\"canonical\"").? <
        std.mem.indexOf(u8, en, "rel=\"alternate\"").?);
    try testing.expect(std.mem.indexOf(u8, en, "rel=\"alternate\"").? <
        std.mem.indexOf(u8, en, "og:type").?);
}

test "a page that is not among its own alternates is refused before a byte" {
    var app = try test_app.init(400, 400);
    defer app.deinit();
    var doc = plain("Docs");
    // The Turkish copy of a page whose set never heard of Turkish —
    // which reads to a crawler as "this document is a copy of something
    // else", and is the shape a fourth locale arrives in.
    doc.meta = sitedWith("/tr/docs/", &docs_set);

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    var em: serialize.Emitter = .{ .gpa = testing.allocator, .app = &app, .out = &out };
    defer em.deinit();
    try testing.expectError(error.AlternatesOmitThisPage, document.document(&em, doc));
    try testing.expectEqual(@as(usize, 0), out.items.len);
}

test "a page with no URL of its own cannot be a member of a set" {
    var app = try test_app.init(400, 400);
    defer app.deinit();
    var doc = plain("Not found");
    var m = sited(null);
    m.alternates = &docs_set;
    doc.meta = m;

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    var em: serialize.Emitter = .{ .gpa = testing.allocator, .app = &app, .out = &out };
    defer em.deinit();
    // The 404 is served at whatever address missed. It has no URL, so
    // it is not one of the URLs anything exists at — and the same error
    // says so, because it is the same rule.
    try testing.expectError(error.AlternatesOmitThisPage, document.document(&em, doc));
}

test "a hand-built set gets the checks the derived one cannot need" {
    var app = try test_app.init(400, 400);
    defer app.deinit();

    // Two languages at one address: one of them is unreachable and its
    // readers are handed the other's — `LocaleStub`'s
    // `ChoiceHrefsCollide` on the other page.
    var doc = plain("Docs");
    doc.meta = sitedWith("/en/docs/", &.{
        .{ .hreflang = "en", .path = "/en/docs/" },
        .{ .hreflang = "fa", .path = "/en/docs/" },
    });
    try testing.expectError(error.AlternatePathRepeated, write(&app, doc));

    // Two `x-default`s, which is a driver wanting two default pages.
    doc.meta = sitedWith("/en/docs/", &.{
        .{ .hreflang = "en", .path = "/en/docs/" },
        .{ .hreflang = "x-default", .path = "/docs/" },
        .{ .hreflang = "x-default", .path = "/" },
    });
    try testing.expectError(error.AlternateHreflangRepeated, write(&app, doc));

    // And an unrooted path, which would join to the origin as garbage.
    doc.meta = sitedWith("/en/docs/", &.{
        .{ .hreflang = "en", .path = "/en/docs/" },
        .{ .hreflang = "fa", .path = "fa/docs/" },
    });
    try testing.expectError(error.PathNotRooted, write(&app, doc));
}

test "a page in one language annotates nothing, and that is the default" {
    var app = try test_app.init(400, 400);
    defer app.deinit();
    var doc = plain("Docs");
    doc.meta = sited("/docs/");
    const html = try write(&app, doc);
    defer testing.allocator.free(html);
    // One URL is not a choice between URLs, and the canonical above
    // already said where the page lives.
    try expectLacks(html, "rel=\"alternate\"");
}

test "the stub carries the same block, derived from the choices it already has" {
    var app = try test_app.init(400, 400);
    defer app.deinit();
    var stub = plainStub();
    stub.published = .{ .origin = "https://example.com", .path = "/docs/" };
    const html = try writeStub(&app, stub);
    defer testing.allocator.free(html);

    // Byte-identical to what every locale's copy carries — one writer
    // over one shape, so the annotation is two-sided by construction
    // and the driver restated neither the paths nor the tags.
    try expectContains(html,
        \\<link rel="alternate" hreflang="en" href="https://example.com/en/docs/">
        \\<link rel="alternate" hreflang="fa" href="https://example.com/fa/docs/">
        \\<link rel="alternate" hreflang="x-default" href="https://example.com/docs/">
        \\
    );
    // x-default is this page. That is what a stub is.
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, html, "hreflang=\"x-default\""));
}

test "a stub that does not say where it is says nothing about the set" {
    var app = try test_app.init(400, 400);
    defer app.deinit();
    const html = try writeStub(&app, plainStub());
    defer testing.allocator.free(html);
    // `published` is one optional rather than an origin and a path with
    // nothing binding them, so half of an alternate block is unstatable.
    try expectLacks(html, "rel=\"alternate\"");
}

test "a stub claiming an address owes the rules every other URL here owes" {
    var app = try test_app.init(400, 400);
    defer app.deinit();

    var stub = plainStub();
    stub.published = .{ .origin = "example.com", .path = "/docs/" };
    try testing.expectError(error.OriginNotAbsolute, writeStub(&app, stub));

    // The hrefs are free to be relative until this page claims an
    // address: an `hreflang` is absolute or it is nothing.
    stub = plainStub();
    stub.choices.fa.href = "fa/docs/";
    testing.allocator.free(try writeStub(&app, stub));
    stub.published = .{ .origin = "https://example.com", .path = "/docs/" };
    try testing.expectError(error.PathNotRooted, writeStub(&app, stub));
}

// ------------------------------------------------------------ the policy
//
// The directive set itself is csp.zig's subject and is not re-asserted
// here — that file owns the inventory and both writers spend it. These
// are about the two pages: which powers each one derives from what it
// contains, where the tag lands, and what a driver is refused for.

/// The policy as a browser reads it: the content attribute of the one
/// meta tag carrying it, or null on a page with none.
fn policyOf(html: []const u8) ?[]const u8 {
    const open = "<meta http-equiv=\"Content-Security-Policy\" content=\"";
    const at = std.mem.indexOf(u8, html, open) orelse return null;
    const rest = html[at + open.len ..];
    return rest[0..std.mem.indexOfScalar(u8, rest, '"').?];
}

fn expectDirective(html: []const u8, directive: []const u8) !void {
    var it = std.mem.splitScalar(u8, policyOf(html).?, ';');
    while (it.next()) |raw| {
        if (std.mem.eql(u8, std.mem.trim(u8, raw, " \n"), directive)) return;
    }
    std.debug.print("expected directive:\n  {s}\nin policy:\n  {s}\n", .{ directive, policyOf(html).? });
    return error.TestExpectedDirective;
}

fn expectNoDirective(html: []const u8, name: []const u8) !void {
    var it = std.mem.splitScalar(u8, policyOf(html).?, ';');
    while (it.next()) |raw| {
        const d = std.mem.trim(u8, raw, " \n");
        if (std.mem.startsWith(u8, d, name)) {
            std.debug.print("expected no {s} in policy:\n  {s}\n", .{ name, policyOf(html).? });
            return error.TestExpectedNoDirective;
        }
    }
}

test "a page carries no policy unless a driver asks for one" {
    var app = try test_app.init(400, 400);
    defer app.deinit();
    const html = try write(&app, plain("Hello"));
    defer testing.allocator.free(html);
    // Whether a document states its policy in its own bytes or takes
    // one from the edge serving it is a fact about a deployment, so
    // absent is a real answer and the default. A stub answers the same
    // way for the same reason.
    try testing.expectEqual(@as(?[]const u8, null), policyOf(html));
    const stub = try writeStub(&app, plainStub());
    defer testing.allocator.free(stub);
    try testing.expectEqual(@as(?[]const u8, null), policyOf(stub));
}

test "a booting page grants the module, the workers and the fetch" {
    var app = try test_app.init(400, 400);
    defer app.deinit();
    var doc = plain("Hello");
    doc.boot = .{ .wasm = "/app.wasm" };
    doc.csp = .{};
    const html = try write(&app, doc);
    defer testing.allocator.free(html);

    // The three a page with a runtime on it spends, and the wasm
    // keyword beside the script source rather than instead of it: a
    // browser compiling a module calls that script execution.
    try expectDirective(html, "script-src 'self' 'wasm-unsafe-eval'");
    try expectDirective(html, "worker-src 'self'");
    try expectDirective(html, "connect-src 'self'");
    // And the floor, which is what makes the absences above mean
    // anything at all.
    try expectDirective(html, "default-src 'none'");
    // A screen is going into the body, so the serializer's inline style
    // attributes are on this page and the split pair carries them.
    try expectDirective(html, "style-src 'self' 'unsafe-inline'");
    try expectDirective(html, "style-src-elem 'self'");
    // One policy on the page: a second meta would be a second policy,
    // and the intersection of two is not what either one says.
    try testing.expectEqual(1, std.mem.count(u8, html, "Content-Security-Policy"));
}

test "a page that runs nothing grants nothing to run it with" {
    var app = try test_app.init(400, 400);
    defer app.deinit();
    // The screen a static site mostly publishes: prose and links, no
    // module. `needsRuntime` says so, `boot` is null, and every power a
    // runtime would spend is absent — which `default-src 'none'`
    // answers as a refusal rather than as a gap.
    var doc = plain("Hello");
    doc.csp = .{};
    const html = try write(&app, doc);
    defer testing.allocator.free(html);
    try expectNoDirective(html, "script-src");
    try expectNoDirective(html, "worker-src");
    try expectNoDirective(html, "connect-src");
    try expectDirective(html, "default-src 'none'");
    try expectDirective(html, "style-src-elem 'self'");
    // No page this writer produces links a manifest; only the app
    // shell's does (packaging.zig).
    try expectNoDirective(html, "manifest-src");
}

test "a stub carries its chooser's one power and none of a document's" {
    var app = try test_app.init(400, 400);
    defer app.deinit();
    var stub = plainStub();
    stub.csp = .{};
    const html = try writeStub(&app, stub);
    defer testing.allocator.free(html);

    // A classic script the site serves, and that is the whole of what
    // runs here: no module is compiled, no driver boots, and
    // `location.replace` is a navigation rather than a fetch.
    try expectDirective(html, "script-src 'self'");
    try expectNoDirective(html, "worker-src");
    try expectNoDirective(html, "connect-src");
    // The markup on this page is written by hand in document.zig and
    // carries no style attribute, so the split pair collapses to one
    // directive — which the file itself has to keep true.
    try expectDirective(html, "style-src 'self'");
    try expectNoDirective(html, "style-src-elem");
    try expectLacks(html, " style=\"");
}

test "the policy leads the head, where the seam cannot follow" {
    var app = try test_app.init(400, 400);
    defer app.deinit();
    var doc = plain("Hello");
    doc.head = "<link rel=\"icon\" href=\"/favicon.svg\">\n";
    doc.csp = .{};
    const html = try write(&app, doc);
    defer testing.allocator.free(html);

    const charset = std.mem.indexOf(u8, html, "<meta charset=\"utf-8\">").?;
    const policy = std.mem.indexOf(u8, html, "Content-Security-Policy").?;
    const sheet = std.mem.indexOf(u8, html, "<link rel=\"stylesheet\"").?;
    const seam = std.mem.indexOf(u8, html, "favicon").?;
    // The charset keeps the first bytes, because a browser stops
    // looking for it there and a policy is not a fetch.
    try testing.expect(charset < policy);
    // And this is the whole reason the policy is a field rather than
    // bytes through `head`: it governs only what the parser meets past
    // it, the stylesheet is one of those things, and the seam is
    // spliced after both.
    try testing.expect(policy < sheet);
    try testing.expect(sheet < seam);
    // What the seam does put on the page is an icon, which is why
    // `img-src` is unconditional in a policy nokre's own markup never
    // spends.
    try expectDirective(html, "img-src 'self'");
}

test "a declared host joins connect-src and no other directive" {
    var app = try test_app.init(400, 400);
    defer app.deinit();
    var doc = plain("Hello");
    doc.boot = .{ .wasm = "/app.wasm" };
    doc.csp = .{ .connect_src = &.{ "https://api.example.com", "wss://live.example.com" } };
    const html = try write(&app, doc);
    defer testing.allocator.free(html);
    try expectDirective(html, "connect-src 'self' https://api.example.com wss://live.example.com");

    // The directive count did not move: a declared host is a source,
    // never a directive.
    var plain_doc = plain("Hello");
    plain_doc.boot = .{ .wasm = "/app.wasm" };
    plain_doc.csp = .{};
    const bare = try write(&app, plain_doc);
    defer testing.allocator.free(bare);
    try testing.expectEqual(
        std.mem.count(u8, policyOf(bare).?, ";"),
        std.mem.count(u8, policyOf(html).?, ";"),
    );
}

test "a policy a driver got wrong is refused before a byte" {
    var app = try test_app.init(400, 400);
    defer app.deinit();

    // A source that could end the directive it lands in and start a
    // friendlier one — the same check the app shell's declaration
    // faces, in the seat a generated page has for it.
    var smuggled = plain("Hello");
    smuggled.boot = .{ .wasm = "/app.wasm" };
    smuggled.csp = .{ .connect_src = &.{"x.com; script-src *"} };
    try testing.expectError(error.InvalidConnectSrc, write(&app, smuggled));

    // A host on a page with no runtime: nothing on it fetches, so the
    // power would be granted to nobody, and a driver writing that has
    // one of the two facts wrong.
    var unbooted = plain("Hello");
    unbooted.csp = .{ .connect_src = &.{"https://api.example.com"} };
    try testing.expectError(error.ConnectSrcWithoutBoot, write(&app, unbooted));

    // Every source in the emitted policy but those hosts is `'self'`,
    // so an asset the page names anywhere else is one the browser
    // refuses — a blank page with a console message, which is the
    // silent direction.
    var off_sheet = plain("Hello");
    off_sheet.stylesheet = "https://cdn.example.com/style.css";
    off_sheet.csp = .{};
    try testing.expectError(error.AssetOffOrigin, write(&app, off_sheet));

    for ([_]document.Boot{
        .{ .wasm = "https://cdn.example.com/app.wasm" },
        .{ .wasm = "/app.wasm", .driver_dir = "https://cdn.example.com/nokre/" },
        .{ .wasm = "/app.wasm", .seed = "//cdn.example.com/md/docs.md" },
    }) |boot| {
        var doc = plain("Hello");
        doc.boot = boot;
        doc.csp = .{};
        try testing.expectError(error.AssetOffOrigin, write(&app, doc));
    }

    // And the same three questions on the other writer, which has two
    // of the destinations and no boot at all.
    var stub = plainStub();
    stub.csp = .{ .connect_src = &.{"https://api.example.com"} };
    try testing.expectError(error.ConnectSrcWithoutBoot, writeStub(&app, stub));
    stub = plainStub();
    stub.driver_dir = "https://cdn.example.com/nokre/";
    stub.csp = .{};
    try testing.expectError(error.AssetOffOrigin, writeStub(&app, stub));
}

test "a refused policy leaves no bytes behind" {
    var app = try test_app.init(400, 400);
    defer app.deinit();
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    var em: serialize.Emitter = .{ .gpa = testing.allocator, .app = &app, .out = &out };
    defer em.deinit();
    var doc = plain("Hello");
    doc.csp = .{ .connect_src = &.{"https://api.example.com"} };
    try testing.expectError(error.ConnectSrcWithoutBoot, document.document(&em, doc));
    // Checked beside `checkMeta` and for its reason: a half-written
    // file published is worse than a build that failed.
    try testing.expectEqual(@as(usize, 0), out.items.len);
}
