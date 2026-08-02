//! The smallest complete nokre app: a heading, a paragraph, a counter,
//! and one notification — the identity-carrying example, so it is where
//! the services that need identity are shown.
const std = @import("std");
const h = @import("nokre");

const State = struct {
    count: u32 = 0,
    app: *h.App = undefined,
    label_id: h.NodeId = .invalid,
    note_id: h.NodeId = .invalid,
};

const N = h.services.notification;

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

/// The whole notification flow, in the order a real app runs it: ask
/// only when the user pressed something, and post only once the answer
/// is yes. The prompt has one answer per install, so an app that asks at
/// boot gets the reflexive no it can never take back.
fn onNotify(ctx: ?*anyopaque) void {
    const state: *State = @ptrCast(@alignCast(ctx.?));
    switch (N.status(state.app)) {
        .not_determined => {
            N.authorize(state.app) catch return;
            note(state, "Asked. The answer arrives on the handler.");
        },
        // No platform re-prompts, so this is the app's to draw around —
        // the same posture `share.available` false asks for.
        .denied => note(state, "Notifications are off in system settings."),
        .granted => post(state),
    }
    state.app.invalidate();
}

fn post(state: *State) void {
    N.post(state.app, .{
        .id = "hello.pressed",
        .title = "Hello, nokre",
        .body = "This came from the OS, not from the app's own chrome.",
        // The tap hands this back — nokre's own route reference, never a
        // URL (docs/routing.md).
        .route = "home",
    }) catch |err| {
        note(state, switch (err) {
            error.Unavailable => "This device has no notification system.",
            else => "Could not post.",
        });
        return;
    };
    note(state, "Posted. Switch away to see it.");
}

/// The one lane: the prompt's answer, a tap, an arrival while the app is
/// on screen, and a push token all land here (docs/services.md).
fn onNotification(ctx: ?*anyopaque, event: N.Event) void {
    const state: *State = @ptrCast(@alignCast(ctx.?));
    switch (event) {
        .authorized => |status| if (status == .granted) post(state) else note(state, "Notifications declined."),
        // A tap can be the first thing that happens in a launch — the
        // tap is what started the process — so this runs before anything
        // the user does in this session.
        .opened => |p| {
            state.app.navigate(p.route) catch {};
            note(state, "Opened from a notification.");
        },
        // No OS banner is drawn over an app that is on screen, so this
        // event is the whole delivery.
        .received => note(state, "One came due while you were here."),
        .push_token => note(state, "A push token arrived; a real app ships it to its backend."),
    }
    state.app.invalidate();
}

fn note(state: *State, text: []const u8) void {
    state.app.tree.setContent(state.note_id, text) catch {};
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

    // notification service: three synchronous boot answers, so the row
    // is drawn (or not) before anything is asked of the user. Registering
    // the handler inside `build` is what makes a tap that launched the
    // app land at all — it is buffered until this call.
    _ = try app.tree.append(root, .{ .divider = .{} });
    if (N.available(app)) {
        N.setHandler(app, state, onNotification);
        state.note_id = try app.tree.append(root, .{ .text = .{
            .content = "Post a notification the OS draws, outside this window.",
        } });
        _ = try app.tree.append(root, .{ .button = .{
            .label = "Notify me",
            .on_press = .{ .ctx = state, .call = onNotify },
        } });
    } else {
        // The honest degrade: a Linux session with no daemon on the bus,
        // or a browser without the API. Draw no affordance rather than
        // one that fails.
        _ = try app.tree.append(root, .{ .text = .{
            .content = "This device has no notification system.",
        } });
    }

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
