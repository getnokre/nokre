//! The smallest complete nokre app: a heading, a paragraph, a counter.
const std = @import("std");
const h = @import("nokre");

const State = struct {
    count: u32 = 0,
    app: *h.App = undefined,
    label_id: h.NodeId = .invalid,
};

fn onIncrement(ctx: ?*anyopaque) void {
    const state: *State = @ptrCast(@alignCast(ctx.?));
    state.count += 1;
    var buf: [32]u8 = undefined;
    const label = std.fmt.bufPrint(&buf, "Pressed {d} times", .{state.count}) catch return;
    state.app.tree.setContent(state.label_id, label) catch return;
    state.app.invalidate();
    // secure_store service: the count survives relaunch (buildHome
    // restores it). A failed write — locked keychain, Linux stub —
    // degrades silently: the store never gates the UI, and the count
    // on screen is still right for this run.
    var digits_buf: [10]u8 = undefined;
    const digits = std.fmt.bufPrint(&digits_buf, "{d}", .{state.count}) catch return;
    h.services.secure_store.set(state.app, "count", digits) catch {};
}

fn buildHome(ctx: ?*anyopaque, app: *h.App) !void {
    const state: *State = @ptrCast(@alignCast(ctx.?));
    const root = app.tree.rootId();
    _ = try app.tree.append(root, .{ .heading = .{ .content = "Hello, nokre", .level = .h1 } });
    _ = try app.tree.append(root, .{ .text = .{ .content = "Two bundled text fonts. One proportional, one mono. Press Tab, then Enter." } });
    _ = try app.tree.append(root, .{ .divider = .{} });

    _ = try app.tree.append(root, .{ .heading = .{ .content = "prose — IBM Plex Sans", .level = .h2 } });
    _ = try app.tree.append(root, .{ .text = .{ .content = "The quick brown fox jumps over the lazy dog. 0123456789", .style = .{ .family = .prose } } });

    _ = try app.tree.append(root, .{ .heading = .{ .content = "mono — JetBrains Mono", .level = .h2 } });
    _ = try app.tree.append(root, .{ .text = .{ .content = "const answer = 42; // mono", .style = .{ .family = .mono } } });

    _ = try app.tree.append(root, .{ .divider = .{} });
    // secure_store service: a boot read is synchronous — one call,
    // inside build, no loading frame (docs/services.md). Absence and an
    // unavailable store both read as zero: a fresh launch and a locked
    // keychain look identical, which is the degrade posture the service
    // asks of every consumer.
    var stored_buf: h.services.secure_store.ValueBuf = undefined;
    if (h.services.secure_store.get(app, "count", &stored_buf) catch null) |stored| {
        state.count = std.fmt.parseInt(u32, stored, 10) catch 0;
    }
    var count_buf: [32]u8 = undefined;
    const count_label = try std.fmt.bufPrint(&count_buf, "Pressed {d} times", .{state.count});
    state.label_id = try app.tree.append(root, .{ .text = .{ .content = count_label } });
    _ = try app.tree.append(root, .{ .button = .{
        .label = "Increment",
        .on_press = .{ .ctx = state, .call = onIncrement },
    } });

    // package_info service: identity is declared once in build.zig (see
    // the examples table there); only the installer field is asked of
    // the OS — "dev" when run bare via zig build run-hello.
    const pkg = h.services.package_info.get();
    var pkg_buf: [96]u8 = undefined;
    const pkg_line = try std.fmt.bufPrint(&pkg_buf, "{s} {s} ({d}) — {s}", .{
        pkg.id, pkg.version, pkg.build, @tagName(pkg.installer),
    });
    _ = try app.tree.append(root, .{ .divider = .{} });
    _ = try app.tree.append(root, .{ .text = .{ .content = pkg_line, .style = .{ .family = .mono } } });
}

pub fn main() !void {
    var gpa_state: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();

    var state = State{};
    var app = try h.App.init(gpa, .{
        .viewport = .{ .w = 480, .h = 520 },
        .routes = &.{.{ .name = "home", .title = "Home", .build = buildHome }},
        .ctx = &state,
    });
    defer app.deinit();
    state.app = &app;
    try app.navigate("home");

    try h.platform.run(&app, .{ .title = "nokre — hello" });
}
