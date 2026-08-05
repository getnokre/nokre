//! Tests for audit.zig: the automated accessibility checks.

const std = @import("std");
const app_mod = @import("../core/app.zig");
const audit_mod = @import("audit.zig");
const diag = @import("diag.zig");
const layout = @import("../core/layout.zig");
const router_mod = @import("../core/router.zig");
const test_app = @import("../core/test_app.zig");

const testing = std.testing;
const App = app_mod.App;
const Violation = audit_mod.Violation;
const audit = audit_mod.audit;
const collect = audit_mod.collect;

fn buildAuditScreen(_: ?*anyopaque, app: *App) anyerror!void {
    try app.tree.append(app.tree.rootId(), .{ .heading = .{ .content = "Screen" } });
}

const nav_routes = [_]router_mod.RouteDef{
    .{ .name = "home", .title = .{ .fixed = "Home" }, .build = buildAuditScreen },
    .{ .name = "settings", .title = .{ .fixed = "Settings" }, .build = buildAuditScreen },
    .{ .name = "docs", .title = .{ .fixed = "Docs" }, .build = buildAuditScreen },
    .{ .name = "roadmap", .title = .{ .fixed = "Roadmap" }, .build = buildAuditScreen },
};

/// A `w` x `h` app over `nav_routes` — a nav's destinations are routes
/// now, so a nav needs a route table to be named from (`App.setNav`),
/// and every route a fixture writes on a control must resolve
/// (`unresolvable_route`), so a test whose elements go anywhere needs
/// the table its references answer to.
fn navApp(w: i32, h: i32) !App {
    return App.init(testing.allocator, .{
        .viewport = .{ .w = w, .h = h },
        .routes = &nav_routes,
        .services = .mocks(),
    });
}

test "audit passes a well-formed screen" {
    var app = try test_app.init(400, 400);
    defer app.deinit();
    try app.tree.append(app.tree.rootId(), .{ .heading = .{ .content = "Home", .level = .h1 } });
    try app.tree.append(app.tree.rootId(), .{ .heading = .{ .content = "Section", .level = .h2 } });
    try app.tree.append(app.tree.rootId(), .{ .button = .{ .label = "Act" } });
    try audit(&app);
}

test "audit flags labels emptied after construction" {
    var app = try test_app.init(400, 400);
    defer app.deinit();
    const btn = try app.tree.appendId(app.tree.rootId(), .{ .button = .{ .label = "Act" } });
    app.tree.get(btn).?.button.label = "";

    var violations: std.ArrayList(Violation) = .empty;
    defer violations.deinit(testing.allocator);
    try collect(&app, &violations, .{});
    try testing.expectEqual(@as(usize, 1), violations.items.len);
    try testing.expectEqual(Violation.Rule.unlabeled_interactive, violations.items[0].rule);
}

test "audit flags copyable values emptied after construction" {
    var app = try test_app.init(400, 400);
    defer app.deinit();
    const c = try app.tree.appendId(app.tree.rootId(), .{ .copyable = .{ .label = "Recovery code", .value = "XKCD-1234" } });
    app.tree.get(c).?.copyable.value = "";

    var violations: std.ArrayList(Violation) = .empty;
    defer violations.deinit(testing.allocator);
    try collect(&app, &violations, .{});
    try testing.expectEqual(@as(usize, 1), violations.items.len);
    try testing.expectEqual(Violation.Rule.empty_copyable, violations.items[0].rule);
}

test "audit flags a field marked invalid with nothing to say" {
    var app = try test_app.init(400, 400);
    defer app.deinit();
    // A problem formatted from a catalog entry that came back blank:
    // the bytes exist, so the field is invalid to every AT, and they
    // draw and announce nothing.
    try app.tree.append(app.tree.rootId(), .{ .text_input = .{ .label = "Email", .problem = "   " } });

    var violations: std.ArrayList(Violation) = .empty;
    defer violations.deinit(testing.allocator);
    try collect(&app, &violations, .{});
    try testing.expectEqual(@as(usize, 1), violations.items.len);
    try testing.expectEqual(Violation.Rule.wordless_problem, violations.items[0].rule);
}

test "audit leaves a field with no problem, and one with real words, alone" {
    var app = try test_app.init(400, 400);
    defer app.deinit();
    try app.tree.append(app.tree.rootId(), .{ .text_input = .{ .label = "Email" } });
    try app.tree.append(app.tree.rootId(), .{ .text_area = .{
        .label = "Notes",
        .problem = "Say a little more than that.",
    } });

    var violations: std.ArrayList(Violation) = .empty;
    defer violations.deinit(testing.allocator);
    try collect(&app, &violations, .{});
    try testing.expectEqual(@as(usize, 0), violations.items.len);
}

test "audit flags a qr label emptied after construction" {
    var app = try test_app.init(400, 400);
    defer app.deinit();
    const qr = try app.tree.appendId(app.tree.rootId(), .{ .qr = .{ .label = "Invite link", .value = "https://example.com" } });
    app.tree.get(qr).?.qr.label = "";

    var violations: std.ArrayList(Violation) = .empty;
    defer violations.deinit(testing.allocator);
    try collect(&app, &violations, .{});
    try testing.expectEqual(@as(usize, 1), violations.items.len);
    try testing.expectEqual(Violation.Rule.malformed_qr, violations.items[0].rule);
}

test "audit flags text ink faded after construction" {
    var app = try test_app.init(400, 400);
    defer app.deinit();
    const txt = try app.tree.appendId(app.tree.rootId(), .{ .text = .{ .content = "caption" } });
    app.tree.get(txt).?.text.style.ink = .g8;

    var violations: std.ArrayList(Violation) = .empty;
    defer violations.deinit(testing.allocator);
    try collect(&app, &violations, .{});
    try testing.expectEqual(@as(usize, 1), violations.items.len);
    try testing.expectEqual(Violation.Rule.insufficient_text_contrast, violations.items[0].rule);
}

test "audit flags skipped heading levels" {
    var app = try test_app.init(400, 400);
    defer app.deinit();
    try app.tree.append(app.tree.rootId(), .{ .heading = .{ .content = "Deep", .level = .h3 } });

    var violations: std.ArrayList(Violation) = .empty;
    defer violations.deinit(testing.allocator);
    try collect(&app, &violations, .{});
    try testing.expectEqual(@as(usize, 1), violations.items.len);
    try testing.expectEqual(Violation.Rule.heading_level_skipped, violations.items[0].rule);
}

test "audit tracks the previous heading, not the deepest ever seen" {
    var app = try test_app.init(400, 400);
    defer app.deinit();
    // h1,h2,h3 walks down legally; the second h1 resets the outline, so
    // its h3 skips h2 even though an h3 already appeared.
    try app.tree.append(app.tree.rootId(), .{ .heading = .{ .content = "A", .level = .h1 } });
    try app.tree.append(app.tree.rootId(), .{ .heading = .{ .content = "B", .level = .h2 } });
    try app.tree.append(app.tree.rootId(), .{ .heading = .{ .content = "C", .level = .h3 } });
    try app.tree.append(app.tree.rootId(), .{ .heading = .{ .content = "D", .level = .h1 } });
    const skipped = try app.tree.appendId(app.tree.rootId(), .{ .heading = .{ .content = "E", .level = .h3 } });

    var violations: std.ArrayList(Violation) = .empty;
    defer violations.deinit(testing.allocator);
    try collect(&app, &violations, .{});
    try testing.expectEqual(@as(usize, 1), violations.items.len);
    try testing.expectEqual(Violation.Rule.heading_level_skipped, violations.items[0].rule);
    try testing.expectEqual(skipped, violations.items[0].id);
}

test "audit allows ascending any distance between headings" {
    var app = try test_app.init(400, 400);
    defer app.deinit();
    try app.tree.append(app.tree.rootId(), .{ .heading = .{ .content = "A", .level = .h1 } });
    try app.tree.append(app.tree.rootId(), .{ .heading = .{ .content = "B", .level = .h2 } });
    try app.tree.append(app.tree.rootId(), .{ .heading = .{ .content = "C", .level = .h3 } });
    try app.tree.append(app.tree.rootId(), .{ .heading = .{ .content = "D", .level = .h1 } });
    try app.tree.append(app.tree.rootId(), .{ .heading = .{ .content = "E", .level = .h2 } });

    var violations: std.ArrayList(Violation) = .empty;
    defer violations.deinit(testing.allocator);
    try collect(&app, &violations, .{});
    try testing.expectEqual(@as(usize, 0), violations.items.len);
}

test "audit flags duplicate interactive labels" {
    var app = try test_app.init(400, 400);
    defer app.deinit();
    try app.tree.append(app.tree.rootId(), .{ .button = .{ .label = "Delete" } });
    try app.tree.append(app.tree.rootId(), .{ .button = .{ .label = "Delete" } });
    try app.tree.append(app.tree.rootId(), .{ .text = .{ .content = "Delete" } });

    var violations: std.ArrayList(Violation) = .empty;
    defer violations.deinit(testing.allocator);
    try collect(&app, &violations, .{});
    try testing.expectEqual(@as(usize, 1), violations.items.len);
    try testing.expectEqual(Violation.Rule.duplicate_interactive_label, violations.items[0].rule);
}

test "two tiles naming different destinations may not share a label" {
    var app = try navApp(400, 400);
    defer app.deinit();
    const group = try app.tree.appendId(app.tree.rootId(), .{ .tile_group = .{} });
    try app.tree.append(group, .{ .tile = .{ .label = "Docs", .route = "docs" } });
    try app.tree.append(group, .{ .tile = .{ .label = "Docs", .route = "roadmap" } });

    var violations: std.ArrayList(Violation) = .empty;
    defer violations.deinit(testing.allocator);
    try collect(&app, &violations, .{});
    try testing.expectEqual(@as(usize, 1), violations.items.len);
    try testing.expectEqual(Violation.Rule.duplicate_interactive_label, violations.items[0].rule);
}

test "two doors to the same route are repetition, not ambiguity" {
    var app = try navApp(400, 400);
    defer app.deinit();
    // The site's own shape: a routed link and a tile both saying "Docs"
    // about the docs route. Whichever is invoked lands the same place,
    // so no ambiguity exists to flag — across element kinds included.
    try app.tree.append(app.tree.rootId(), .{ .link = .{ .label = "Docs", .route = "docs" } });
    const group = try app.tree.appendId(app.tree.rootId(), .{ .tile_group = .{} });
    try app.tree.append(group, .{ .tile = .{ .label = "Docs", .route = "docs" } });
    try app.tree.append(group, .{ .tile = .{ .label = "Docs", .route = "docs" } });
    try audit(&app);
}

fn noopPress(_: ?*anyopaque) void {}

test "duplicate labels over actions stay flagged, same function or not" {
    var app = try test_app.init(400, 400);
    defer app.deinit();
    const group = try app.tree.appendId(app.tree.rootId(), .{ .tile_group = .{} });
    // One function pointer, but each tile closes over its own context —
    // sameness cannot be read off the tree, so the exemption never
    // applies to actions.
    try app.tree.append(group, .{ .tile = .{ .label = "Reset", .on_press = .{ .call = noopPress } } });
    try app.tree.append(group, .{ .tile = .{ .label = "Reset", .on_press = .{ .call = noopPress } } });

    var violations: std.ArrayList(Violation) = .empty;
    defer violations.deinit(testing.allocator);
    try collect(&app, &violations, .{});
    try testing.expectEqual(@as(usize, 1), violations.items.len);
    try testing.expectEqual(Violation.Rule.duplicate_interactive_label, violations.items[0].rule);
}

test "audit flags a tile label emptied after construction" {
    var app = try navApp(400, 400);
    defer app.deinit();
    const group = try app.tree.appendId(app.tree.rootId(), .{ .tile_group = .{} });
    const tile = try app.tree.appendId(group, .{ .tile = .{ .label = "Docs", .route = "docs" } });
    app.tree.get(tile).?.tile.label = "";

    var violations: std.ArrayList(Violation) = .empty;
    defer violations.deinit(testing.allocator);
    try collect(&app, &violations, .{});
    try testing.expectEqual(@as(usize, 1), violations.items.len);
    try testing.expectEqual(Violation.Rule.unlabeled_interactive, violations.items[0].rule);
}

test "a duplicate behind an open sheet is inert, not ambiguous" {
    var app = try test_app.init(400, 600);
    defer app.deinit();
    try app.tree.append(app.tree.rootId(), .{ .button = .{ .label = "Save" } });
    // The sheet's "Save" shares a label with the base layer's, but the
    // base layer is under the scrim: nothing there can be tapped or
    // spoken to, so only the sheet's copy is live — no ambiguity.
    const sheet = try app.presentSheet("Options");
    try app.tree.append(sheet, .{ .button = .{ .label = "Save" } });
    try audit(&app);
}

test "two duplicates within the open sheet still fail" {
    var app = try test_app.init(400, 600);
    defer app.deinit();
    const sheet = try app.presentSheet("Options");
    try app.tree.append(sheet, .{ .button = .{ .label = "Save" } });
    try app.tree.append(sheet, .{ .button = .{ .label = "Save" } });

    var violations: std.ArrayList(Violation) = .empty;
    defer violations.deinit(testing.allocator);
    try collect(&app, &violations, .{});
    try testing.expectEqual(@as(usize, 1), violations.items.len);
    try testing.expectEqual(Violation.Rule.duplicate_interactive_label, violations.items[0].rule);
}

test "a disabled duplicate is not ambiguous" {
    var app = try test_app.init(400, 400);
    defer app.deinit();
    try app.tree.append(app.tree.rootId(), .{ .button = .{ .label = "Retry" } });
    try app.tree.append(app.tree.rootId(), .{ .button = .{ .label = "Retry", .disabled = true } });
    try audit(&app);
}

test "audit passes a well-formed nav and segmented control" {
    var app = try navApp(400, 400);
    defer app.deinit();
    try app.setNav(&.{
        .{ .route = "home", .icon = .house },
        .{ .route = "settings", .icon = .settings },
    });
    try app.tree.append(app.tree.rootId(), .{ .segmented = .{
        .label = "View",
        .options = &.{ "List", "Grid" },
    } });
    try audit(&app);
}

test "audit flags a nav degraded below two items by removal" {
    var app = try navApp(400, 400);
    defer app.deinit();
    try app.setNav(&.{
        .{ .route = "home", .icon = .house },
        .{ .route = "settings", .icon = .settings },
    });
    var root_children = app.tree.children(app.tree.rootId());
    const nav = root_children.next().?;
    var nav_children = app.tree.children(nav);
    const first_item = nav_children.next().?;
    try app.tree.remove(first_item);

    var violations: std.ArrayList(Violation) = .empty;
    defer violations.deinit(testing.allocator);
    try collect(&app, &violations, .{});
    try testing.expectEqual(@as(usize, 1), violations.items.len);
    try testing.expectEqual(Violation.Rule.nav_item_count, violations.items[0].rule);
}

test "the off-roster marker is not a destination the nav count sees" {
    var app = try App.init(testing.allocator, .{
        .viewport = .{ .w = 900, .h = 400 },
        .routes = &.{
            .{ .name = "home", .title = .{ .fixed = "Home" }, .build = buildAuditScreen },
            .{ .name = "settings", .title = .{ .fixed = "Settings" }, .build = buildAuditScreen },
            .{ .name = "terms", .title = .{ .fixed = "Terms" }, .build = buildAuditScreen },
        },
        .services = .mocks(),
    });
    defer app.deinit();
    try app.setNav(&.{
        .{ .route = "home", .icon = .house },
        .{ .route = "settings", .icon = .settings },
    });
    // Three children, two destinations: counting the marker as one
    // would report every off-roster screen as a roster gone wrong.
    try app.navigate("terms");
    try audit(&app);

    // Emptied afterwards, it is a plate saying you are nowhere.
    const here = blk: {
        var it = app.tree.dfs();
        while (it.next()) |id| {
            if (app.tree.getConst(id).?.role() == .nav_here) break :blk id;
        }
        unreachable;
    };
    app.tree.get(here).?.nav_here.value = "";
    var violations: std.ArrayList(Violation) = .empty;
    defer violations.deinit(testing.allocator);
    try collect(&app, &violations, .{});
    try testing.expectEqual(@as(usize, 1), violations.items.len);
    try testing.expectEqual(Violation.Rule.empty_nav_here, violations.items[0].rule);
}

test "audit flags a segmented selection mutated out of range" {
    var app = try test_app.init(400, 400);
    defer app.deinit();
    const seg = try app.tree.appendId(app.tree.rootId(), .{ .segmented = .{
        .label = "View",
        .options = &.{ "List", "Grid" },
    } });
    app.tree.get(seg).?.segmented.selected = 7;

    var violations: std.ArrayList(Violation) = .empty;
    defer violations.deinit(testing.allocator);
    try collect(&app, &violations, .{});
    try testing.expectEqual(@as(usize, 1), violations.items.len);
    try testing.expectEqual(Violation.Rule.malformed_segmented, violations.items[0].rule);
}

test "audit flags a radio group selection mutated out of range" {
    var app = try test_app.init(400, 400);
    defer app.deinit();
    const rg = try app.tree.appendId(app.tree.rootId(), .{ .radio_group = .{
        .label = "Delivery",
        .options = &.{ "Email", "SMS" },
    } });
    app.tree.get(rg).?.radio_group.selected = 7;

    var violations: std.ArrayList(Violation) = .empty;
    defer violations.deinit(testing.allocator);
    try collect(&app, &violations, .{});
    try testing.expectEqual(@as(usize, 1), violations.items.len);
    try testing.expectEqual(Violation.Rule.malformed_radio_group, violations.items[0].rule);
}

test "audit flags a select selection mutated out of range" {
    var app = try test_app.init(400, 400);
    defer app.deinit();
    const sel = try app.tree.appendId(app.tree.rootId(), .{ .select = .{
        .label = "Language",
        .options = &.{ "English", "Deutsch" },
    } });
    app.tree.get(sel).?.select.selected = 7;

    var violations: std.ArrayList(Violation) = .empty;
    defer violations.deinit(testing.allocator);
    try collect(&app, &violations, .{});
    try testing.expectEqual(@as(usize, 1), violations.items.len);
    try testing.expectEqual(Violation.Rule.malformed_select, violations.items[0].rule);
}

test "audit passes a framework-built sheet and notice" {
    var app = try navApp(400, 600);
    defer app.deinit();
    _ = try app.presentSheet("Options");
    app.notify(.{ .title = "Saved", .route = "home", .important = true });

    var violations: std.ArrayList(Violation) = .empty;
    defer violations.deinit(testing.allocator);
    try collect(&app, &violations, .{});
    try testing.expectEqual(@as(usize, 0), violations.items.len);
}

test "audit passes the framework-built notices pane" {
    var app = try navApp(400, 600);
    defer app.deinit();
    app.notify(.{ .title = "Saved", .route = "home" });
    app.notify(.{ .title = "Sync failed", .route = "home", .important = true });
    try app.openNoticesPane();

    var violations: std.ArrayList(Violation) = .empty;
    defer violations.deinit(testing.allocator);
    try collect(&app, &violations, .{});
    try testing.expectEqual(@as(usize, 0), violations.items.len);
}

test "audit flags a sheet whose close control was removed" {
    var app = try test_app.init(400, 600);
    defer app.deinit();
    const sheet = try app.presentSheet("Options");
    var children = app.tree.children(sheet);
    const close = children.next().?;
    try app.tree.remove(close);

    var violations: std.ArrayList(Violation) = .empty;
    defer violations.deinit(testing.allocator);
    try collect(&app, &violations, .{});
    try testing.expectEqual(@as(usize, 1), violations.items.len);
    try testing.expectEqual(Violation.Rule.sheet_missing_dismiss, violations.items[0].rule);
}

test "audit flags a sheet whose only way out has work in progress" {
    var app = try test_app.init(400, 600);
    defer app.deinit();
    const sheet = try app.presentSheet("Options");
    var children = app.tree.children(sheet);
    const close = children.next().?;
    try app.tree.remove(close);
    // A button that cannot be pressed until the work lands is no exit —
    // and the work landing is exactly when the user wants one.
    const btn = try app.tree.appendId(sheet, .{ .button = .{ .label = "Apply", .in_progress = true } });

    var violations: std.ArrayList(Violation) = .empty;
    defer violations.deinit(testing.allocator);
    try collect(&app, &violations, .{});
    try testing.expectEqual(@as(usize, 1), violations.items.len);
    try testing.expectEqual(Violation.Rule.sheet_missing_dismiss, violations.items[0].rule);

    // The same button once the work is done is a way out.
    app.tree.get(btn).?.button.in_progress = false;
    violations.clearRetainingCapacity();
    try collect(&app, &violations, .{});
    try testing.expectEqual(@as(usize, 0), violations.items.len);
}

test "audit flags a button progress mutated into nonsense" {
    var app = try test_app.init(400, 400);
    defer app.deinit();
    const btn = try app.tree.appendId(app.tree.rootId(), .{ .button = .{ .label = "Save", .in_progress = true, .progress_percent = 40 } });

    var violations: std.ArrayList(Violation) = .empty;
    defer violations.deinit(testing.allocator);
    try collect(&app, &violations, .{});
    try testing.expectEqual(@as(usize, 0), violations.items.len);

    // A percentage climbing past 100 measures nothing.
    app.tree.get(btn).?.button.progress_percent = 140;
    violations.clearRetainingCapacity();
    try collect(&app, &violations, .{});
    try testing.expectEqual(@as(usize, 1), violations.items.len);
    try testing.expectEqual(Violation.Rule.malformed_progress, violations.items[0].rule);

    // Neither does one left behind when the work ended.
    app.tree.get(btn).?.button.progress_percent = 40;
    app.tree.get(btn).?.button.in_progress = false;
    violations.clearRetainingCapacity();
    try collect(&app, &violations, .{});
    try testing.expectEqual(@as(usize, 1), violations.items.len);
    try testing.expectEqual(Violation.Rule.malformed_progress, violations.items[0].rule);
}

test "audit flags a meter mutated out of range" {
    var app = try test_app.init(400, 400);
    defer app.deinit();
    const meter = try app.tree.appendId(app.tree.rootId(), .{ .meter = .{ .label = "12 of 30 days", .value = 12, .max = 30 } });
    app.tree.get(meter).?.meter.value = 45;

    var violations: std.ArrayList(Violation) = .empty;
    defer violations.deinit(testing.allocator);
    try collect(&app, &violations, .{});
    try testing.expectEqual(@as(usize, 1), violations.items.len);
    try testing.expectEqual(Violation.Rule.malformed_meter, violations.items[0].rule);
}

test "audit flags a badge label emptied after construction" {
    var app = try test_app.init(400, 400);
    defer app.deinit();
    const badge = try app.tree.appendId(app.tree.rootId(), .{ .badge = .{ .label = "Active" } });
    app.tree.get(badge).?.badge.label = "";

    var violations: std.ArrayList(Violation) = .empty;
    defer violations.deinit(testing.allocator);
    try collect(&app, &violations, .{});
    try testing.expectEqual(@as(usize, 1), violations.items.len);
    try testing.expectEqual(Violation.Rule.empty_badge, violations.items[0].rule);
}

test "audit flags a notice title emptied after construction" {
    var app = try navApp(400, 600);
    defer app.deinit();
    app.notify(.{ .title = "Saved", .route = "home", .important = true });
    const notice = layout.findNotice(&app.tree).?;
    app.tree.get(notice).?.notice.title = "";

    var violations: std.ArrayList(Violation) = .empty;
    defer violations.deinit(testing.allocator);
    try collect(&app, &violations, .{});
    try testing.expectEqual(@as(usize, 1), violations.items.len);
    try testing.expectEqual(Violation.Rule.empty_notice, violations.items[0].rule);
}

test "audit flags a list with nothing in it" {
    var app = try test_app.init(400, 400);
    defer app.deinit();
    // `append` cannot catch this: a list is built before its items
    // exist, so the whole-tree pass is the only place the rule can live.
    const list = try app.tree.appendId(app.tree.rootId(), .{ .list = .{} });

    var violations: std.ArrayList(Violation) = .empty;
    defer violations.deinit(testing.allocator);
    try collect(&app, &violations, .{});
    try testing.expectEqual(@as(usize, 1), violations.items.len);
    try testing.expectEqual(Violation.Rule.empty_list, violations.items[0].rule);

    const item = try app.tree.appendId(list, .{ .list_item = .{} });
    try app.tree.append(item, .{ .text = .{ .content = "One thing" } });
    try audit(&app);
}

test "audit flags a document whose label was emptied after construction" {
    var app = try test_app.init(400, 400);
    defer app.deinit();
    const doc = try app.tree.appendId(app.tree.rootId(), .{ .document = .{
        .label = "Terms",
        .source = "# Terms\n\nSome words.",
    } });
    try audit(&app);
    app.tree.get(doc).?.document.label = "";

    var violations: std.ArrayList(Violation) = .empty;
    defer violations.deinit(testing.allocator);
    try collect(&app, &violations, .{});
    try testing.expectEqual(@as(usize, 1), violations.items.len);
    try testing.expectEqual(Violation.Rule.untitled_document, violations.items[0].rule);
}

test "audit flags a code block emptied after construction" {
    var app = try test_app.init(400, 400);
    defer app.deinit();
    const cb = try app.tree.appendId(app.tree.rootId(), .{ .code_block = .{ .content = "fn main() !void {}" } });
    try audit(&app);
    app.tree.get(cb).?.code_block.content = "";

    var violations: std.ArrayList(Violation) = .empty;
    defer violations.deinit(testing.allocator);
    try collect(&app, &violations, .{});
    try testing.expectEqual(@as(usize, 1), violations.items.len);
    try testing.expectEqual(Violation.Rule.empty_code_block, violations.items[0].rule);
}

// Scroll clipping fixtures: single-line body texts flow at a 32px
// rhythm (24px line + 8px gap), so child i spans content y 32i..32i+24
// and the glyph band inside each line is (4, 20).
fn buildScrollFixture(app: *App, height: ?i32, lines: usize) !void {
    const sr = try app.tree.appendId(app.tree.rootId(), .{ .scroll_region = .{ .height = height } });
    for (0..lines) |_| {
        try app.tree.append(sr, .{ .text = .{ .content = "line" } });
    }
}

test "audit flags an overflowing region whose edge lands in a flow gap" {
    var app = try test_app.init(400, 400);
    defer app.deinit();
    // Edge at 90: the 88..96 gap between lines 2 and 3 — a clean cut.
    try buildScrollFixture(&app, 90, 6);

    var violations: std.ArrayList(Violation) = .empty;
    defer violations.deinit(testing.allocator);
    try collect(&app, &violations, .{});
    try testing.expectEqual(@as(usize, 1), violations.items.len);
    try testing.expectEqual(Violation.Rule.cleanly_clipped_scroll_region, violations.items[0].rule);
}

test "audit flags an edge exactly on an element boundary" {
    var app = try test_app.init(400, 400);
    defer app.deinit();
    // Edge at 120: flush with line 3's bottom — nothing straddles it.
    try buildScrollFixture(&app, 120, 6);

    var violations: std.ArrayList(Violation) = .empty;
    defer violations.deinit(testing.allocator);
    try collect(&app, &violations, .{});
    try testing.expectEqual(@as(usize, 1), violations.items.len);
    try testing.expectEqual(Violation.Rule.cleanly_clipped_scroll_region, violations.items[0].rule);
}

test "audit flags an edge that only slices a text line's leading" {
    var app = try test_app.init(400, 400);
    defer app.deinit();
    // Edge at 98: 2px into line 3's box, above the glyph band at 4 —
    // whole letters on both sides, so the cut is invisible.
    try buildScrollFixture(&app, 98, 6);

    var violations: std.ArrayList(Violation) = .empty;
    defer violations.deinit(testing.allocator);
    try collect(&app, &violations, .{});
    try testing.expectEqual(@as(usize, 1), violations.items.len);
    try testing.expectEqual(Violation.Rule.cleanly_clipped_scroll_region, violations.items[0].rule);
}

test "audit passes an edge cutting mid-glyph, and offset does not fool it" {
    var app = try test_app.init(400, 400);
    defer app.deinit();
    // Edge at 108: 12px into line 3's box, through the glyph band.
    try buildScrollFixture(&app, 108, 6);

    var violations: std.ArrayList(Violation) = .empty;
    defer violations.deinit(testing.allocator);
    try collect(&app, &violations, .{});
    try testing.expectEqual(@as(usize, 0), violations.items.len);

    // The rule judges the offset-0 edge; a live scroll must not
    // change the verdict in either direction.
    var it = app.tree.dfs();
    while (it.next()) |id| {
        const el = app.tree.get(id).?;
        if (el.role() != .scroll_region) continue;
        el.scroll_region.offset = 40;
        app.invalidate();
    }
    try collect(&app, &violations, .{});
    try testing.expectEqual(@as(usize, 0), violations.items.len);
}

test "audit passes a straddling bordered box regardless of its interior" {
    var app = try test_app.init(400, 400);
    defer app.deinit();
    const sr = try app.tree.appendId(app.tree.rootId(), .{ .scroll_region = .{ .height = 40 } });
    // Box (border + 12px padding around a 24px line: 50 tall) straddles
    // the edge at 40: its side borders visibly run off the clip.
    const box = try app.tree.appendId(sr, .{ .box = .{} });
    try app.tree.append(box, .{ .text = .{ .content = "boxed" } });
    for (0..4) |_| {
        try app.tree.append(sr, .{ .text = .{ .content = "line" } });
    }

    var violations: std.ArrayList(Violation) = .empty;
    defer violations.deinit(testing.allocator);
    try collect(&app, &violations, .{});
    try testing.expectEqual(@as(usize, 0), violations.items.len);
}

test "audit exempts fill-height regions and content that fits" {
    var app = try test_app.init(400, 120);
    defer app.deinit();
    // A null height resolves against the viewport, which the consumer
    // cannot portably control; wherever this edge lands, no violation.
    try buildScrollFixture(&app, null, 8);

    var violations: std.ArrayList(Violation) = .empty;
    defer violations.deinit(testing.allocator);
    try collect(&app, &violations, .{});
    try testing.expectEqual(@as(usize, 0), violations.items.len);

    var fits = try test_app.init(400, 400);
    defer fits.deinit();
    // Boundary-flush edge, but nothing overflows: nothing to announce.
    try buildScrollFixture(&fits, 120, 3);
    try collect(&fits, &violations, .{});
    try testing.expectEqual(@as(usize, 0), violations.items.len);
}

test "audit flags span inks dimmed after construction" {
    var app = try test_app.init(400, 400);
    defer app.deinit();
    const id = try app.tree.appendId(app.tree.rootId(), .{ .text = .{ .spans = &.{
        .{ .text = "plain " },
        .{ .text = "loud", .strong = true },
    } } });
    try audit(&app);

    // Mutation can dim a run below AA just like the element's own ink.
    const spans = app.tree.get(id).?.text.spans;
    @constCast(&spans[1]).ink = .g9;

    var violations: std.ArrayList(Violation) = .empty;
    defer violations.deinit(testing.allocator);
    try collect(&app, &violations, .{});
    try testing.expectEqual(@as(usize, 1), violations.items.len);
    try testing.expectEqual(Violation.Rule.insufficient_text_contrast, violations.items[0].rule);
}

test "audit flags a route destination the router cannot honor" {
    var app = try navApp(400, 400);
    defer app.deinit();
    // One of each pure route destination (`routeDestination`), all
    // resolving — and one link whose reference names no route: a dead
    // end wearing an interactive face.
    try app.tree.append(app.tree.rootId(), .{ .link = .{ .label = "Docs", .route = "docs" } });
    const group = try app.tree.appendId(app.tree.rootId(), .{ .tile_group = .{} });
    try app.tree.append(group, .{ .tile = .{ .label = "Roadmap", .route = "roadmap" } });
    const dead = try app.tree.appendId(app.tree.rootId(), .{ .link = .{ .label = "Gone", .route = "nowhere" } });

    var violations: std.ArrayList(Violation) = .empty;
    defer violations.deinit(testing.allocator);
    try collect(&app, &violations, .{});
    try testing.expectEqual(@as(usize, 1), violations.items.len);
    try testing.expectEqual(Violation.Rule.unresolvable_route, violations.items[0].rule);
    try testing.expectEqual(dead, violations.items[0].id);
}

test "a span's destination faces the same audit as a link's" {
    var app = try navApp(400, 400);
    defer app.deinit();
    // The wrong arity is as unresolvable as the wrong name: `docs`
    // declares no arguments.
    const id = try app.tree.appendId(app.tree.rootId(), .{ .text = .{ .spans = &.{
        .{ .text = "read ", .route = "docs~42" },
        .{ .text = "this." },
    } } });

    var violations: std.ArrayList(Violation) = .empty;
    defer violations.deinit(testing.allocator);
    try collect(&app, &violations, .{});
    try testing.expectEqual(@as(usize, 1), violations.items.len);
    try testing.expectEqual(Violation.Rule.unresolvable_route, violations.items[0].rule);
    try testing.expectEqual(id, violations.items[0].id);
}

test "audit fails the test a refused navigation left behind" {
    var app = try navApp(400, 400);
    defer app.deinit();
    try app.navigate("home");
    try audit(&app);

    // The verb returned clean and the stack did not move (router.zig);
    // the record is how the mistake still fails the first test that
    // makes it.
    try app.navigate("nowhere");
    diag.quiet = true;
    defer diag.quiet = false;
    try testing.expectError(error.NavigationRefused, audit(&app));
}

fn buildAndReload(_: ?*anyopaque, app: *App) anyerror!void {
    try app.tree.append(app.tree.rootId(), .{ .heading = .{ .content = "Loader" } });
    // A callback landing mid-build reaching for the screen — the
    // re-entrant reload router.zig refuses (`reload_in_build`).
    app.reload() catch {};
}

test "audit fails the test a reload-during-build left behind" {
    var app = try App.init(testing.allocator, .{
        .viewport = .{ .w = 400, .h = 400 },
        .routes = &.{.{ .name = "loader", .title = .{ .fixed = "Loader" }, .build = buildAndReload }},
        .services = .mocks(),
    });
    defer app.deinit();
    // Same footing as a refused reference: the verb returned clean and
    // the screen stands whole (router_test.zig proves the no-op); the
    // record is how the mistake still surfaces, here.
    try app.navigate("loader");
    diag.quiet = true;
    defer diag.quiet = false;
    try testing.expectError(error.NavigationRefused, audit(&app));
}

test "a notice routing nowhere is caught before its pane ever opens" {
    var app = try navApp(400, 600);
    defer app.deinit();
    // Quiet, so no banner: the route sits in app state with no node to
    // hang a violation on, which is why the gate reads the notices
    // directly.
    app.notify(.{ .title = "Sync failed", .route = "nowhere" });
    diag.quiet = true;
    defer diag.quiet = false;
    try testing.expectError(error.NavigationRefused, audit(&app));
}

test "a document's destinations answer to their own lane, not the table" {
    var app = try navApp(400, 400);
    defer app.deinit();
    // The site generator's shape: a parsed document whose links name
    // files its own resolver honors — no route table governs them.
    try app.tree.append(app.tree.rootId(), .{ .document = .{
        .label = "Introduction",
        .source = "See [the elements](elements.md) for the closed set.",
    } });

    var violations: std.ArrayList(Violation) = .empty;
    defer violations.deinit(testing.allocator);
    try collect(&app, &violations, .{});
    try testing.expectEqual(@as(usize, 0), violations.items.len);
}

test "a skipped rule is dropped and every other rule stays fatal-grade" {
    var app = try navApp(400, 400);
    defer app.deinit();
    // One finding under the skipped rule, one under another — the site
    // generator's exact posture: its own resolver replaces the route
    // table's authority, and nothing else's.
    try app.tree.append(app.tree.rootId(), .{ .link = .{ .label = "Gone", .route = "nowhere" } });
    const btn = try app.tree.appendId(app.tree.rootId(), .{ .button = .{ .label = "Act" } });
    app.tree.get(btn).?.button.label = "";

    var violations: std.ArrayList(Violation) = .empty;
    defer violations.deinit(testing.allocator);
    try collect(&app, &violations, .{ .skip = &.{.unresolvable_route} });
    try testing.expectEqual(@as(usize, 1), violations.items.len);
    try testing.expectEqual(Violation.Rule.unlabeled_interactive, violations.items[0].rule);

    // Findings a caller already holds are not this call's to filter.
    var held: std.ArrayList(Violation) = .empty;
    defer held.deinit(testing.allocator);
    try held.append(testing.allocator, .{ .id = btn, .rule = .unresolvable_route });
    try collect(&app, &held, .{ .skip = &.{ .unresolvable_route, .unlabeled_interactive } });
    try testing.expectEqual(@as(usize, 1), held.items.len);
    try testing.expectEqual(Violation.Rule.unresolvable_route, held.items[0].rule);
}
