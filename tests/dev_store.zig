//! The one gate `zig test` cannot be: a real executable, unsigned,
//! driving a real app against the real secure_store — no mock anywhere
//! in the binary.
//!
//! Under `zig test` a service *is* its mock (`Service = if (is_test)
//! Mock else …`), so nothing in the unit suite proves a store the OS
//! actually answers. This program is built the way a consumer's driver
//! binary is: `.secure_store = true, .secure_store_dev = true`, Debug,
//! desktop — so `secure_store.get/set/delete/list` here are the release
//! verbs over the dev file store (docs/internals/secure_store.md), and
//! the screens are driven through `testing.driver`, the half of the
//! testing layer that carries no `builtin.is_test` at all.
//!
//! What it proves, in order: a boot read decides the first screen; a
//! tap writes a secret; the write survives the app that made it *and
//! the process's App instance*, so the next launch's boot read finds it;
//! and a sign-out really removes it. That last pair is what an unsigned
//! macOS binary on the Keychain cannot do — `SecItemAdd` answers
//! errSecMissingEntitlement — which is the whole reason this backend
//! exists.

const std = @import("std");
const nok = @import("nokre");

const ss = nok.services.secure_store;
const driver = nok.testing.driver;
const queries = nok.testing.queries;
const audit = nok.testing.audit;

const key = "auth.token";
const token = "tk-nokre-dev-store";

// A program that links the library owes the hooks a shell owes
// (docs/testing.md's "where the harness stops": the driver *is* the
// shell's half of the line). Naming the shipped shell is the whole
// install (src/testing/shell.zig).
comptime {
    _ = nok.testing.shell;
}

const State = struct {
    app: *nok.App = undefined,
    status: nok.NodeId = .invalid,
};

/// A boot read, inside build, synchronous — the shape docs/services.md
/// promises and the reason the store is not async. Absence and an
/// unavailable store both read as signed out.
fn buildHome(ctx: ?*anyopaque, app: *nok.App) !void {
    const state: *State = @ptrCast(@alignCast(ctx.?));
    state.app = app;
    const root = app.tree.rootId();
    try app.tree.append(root, .{ .heading = .{ .content = "Dev store", .level = .h1 } });

    var buf: ss.ValueBuf = undefined;
    const stored = ss.get(app, key, &buf) catch null;
    state.status = try app.tree.appendId(root, .{
        .text = .{ .content = if (stored != null) "Signed in" else "Signed out" },
    });
    try app.tree.append(root, .{ .button = .{ .label = "Sign in", .on_press = .{ .ctx = state, .call = onSignIn } } });
    try app.tree.append(root, .{ .button = .{ .label = "Sign out", .on_press = .{ .ctx = state, .call = onSignOut } } });
}

fn onSignIn(ctx: ?*anyopaque) void {
    const state: *State = @ptrCast(@alignCast(ctx.?));
    ss.set(state.app, key, token) catch |err| return fail("set", err);
    state.app.tree.setContent(state.status, "Signed in") catch {};
    state.app.invalidate();
}

fn onSignOut(ctx: ?*anyopaque) void {
    const state: *State = @ptrCast(@alignCast(ctx.?));
    ss.delete(state.app, key) catch |err| return fail("delete", err);
    state.app.tree.setContent(state.status, "Signed out") catch {};
    state.app.invalidate();
}

fn fail(verb: []const u8, err: anyerror) noreturn {
    std.debug.print("dev store: {s} failed with {s}\n", .{ verb, @errorName(err) });
    std.process.exit(1);
}

/// One launch of the app: construct it, build the first screen, audit
/// it, and leave it ready to drive. Three of these run in sequence
/// below, and the third is the point — it shares nothing with the
/// second but the store's file.
///
/// The App is built into the caller's storage rather than returned by
/// value: `state.app` is a pointer the press handlers dereference, so
/// an App that moves after `build` leaves them aimed at a dead frame.
/// (`Harness` holds the App as a field for the same reason.)
fn launch(gpa: std.mem.Allocator, state: *State, app: *nok.App) !void {
    app.* = try nok.App.init(gpa, .{ .viewport = .{ .w = 480, .h = 640 }, .ctx = state });
    errdefer app.deinit();
    try buildHome(state, app);
    try audit.audit(app);
}

fn expectStatus(app: *nok.App, expected: []const u8) !void {
    if (queries.queryByLabel(&app.tree, expected) == null) {
        std.debug.print("dev store: expected \"{s}\" on screen\n", .{expected});
        return error.WrongScreen;
    }
}

fn tapLabel(app: *nok.App, label: []const u8) !void {
    const id = queries.queryByLabel(&app.tree, label) orelse return error.NoSuchElement;
    try driver.tap(app, id);
}

pub fn main() !void {
    var debug_allocator: std.heap.DebugAllocator(.{}) = .init;
    defer _ = debug_allocator.deinit();
    const gpa = debug_allocator.allocator();

    var state: State = .{};

    // The store outlives processes, so the run starts by putting it in a
    // known state through the same release verb everything else uses.
    {
        var app: nok.App = undefined;
        try launch(gpa, &state, &app);
        defer app.deinit();
        try ss.delete(&app, key);

        var lb: ss.ListBuf = undefined;
        if ((try ss.list(&app, &lb)).len != 0) return error.StoreNotEmpty;
    }

    // Launch one: signed out, then a tap writes the secret.
    {
        var app: nok.App = undefined;
        try launch(gpa, &state, &app);
        defer app.deinit();
        try expectStatus(&app, "Signed out");

        try tapLabel(&app, "Sign in");
        try audit.audit(&app);
        try expectStatus(&app, "Signed in");

        // Read it back through the store, not off the screen: this is
        // the write an unsigned binary cannot make to the Keychain.
        var buf: ss.ValueBuf = undefined;
        const read_back = (try ss.get(&app, key, &buf)) orelse return error.WroteNothing;
        if (!std.mem.eql(u8, read_back, token)) return error.ValueMismatch;

        var lb: ss.ListBuf = undefined;
        const keys = try ss.list(&app, &lb);
        if (keys.len != 1 or !std.mem.eql(u8, keys[0], key)) return error.ListMismatch;
    }

    // Launch two: a different App, whose boot read finds the secret the
    // first one left — the store survived the app that wrote it. Then
    // sign out, and it is gone for good.
    {
        var app: nok.App = undefined;
        try launch(gpa, &state, &app);
        defer app.deinit();
        try expectStatus(&app, "Signed in");

        try tapLabel(&app, "Sign out");
        try audit.audit(&app);
        try expectStatus(&app, "Signed out");

        var buf: ss.ValueBuf = undefined;
        if ((try ss.get(&app, key, &buf)) != null) return error.StillStored;

        var lb: ss.ListBuf = undefined;
        if ((try ss.list(&app, &lb)).len != 0) return error.StoreNotEmpty;
    }

    // stderr, not stdout: the dev store already announces itself there
    // at launch, and one stream keeps the run step's transcript in order.
    std.debug.print("dev store: boot read, set, relaunch, get, list, delete — all ok\n", .{});
}
