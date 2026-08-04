//! The other gate `zig test` cannot be: a real executable driving two
//! real apps at a real socket, hard enough and for long enough that the
//! native transport's *threads* are the subject.
//!
//! Under `zig test` the http service is its mock, so the unit suite
//! never opens a socket; native_test.zig opens one, but drives
//! `perform` directly and says so — "`send`'s threads" is the half it
//! deliberately leaves uncovered. This program is the half. It is built
//! the way a consumer's driver binary is (Debug, desktop, no mock in
//! the binary at all), and it is the only place where nokre's own
//! delivery pump, its detached transfer and watchdog threads, and
//! std.http.Client's connect machinery all run at once, from two `App`s
//! in one process — the shape a driver has when it drives two devices.
//!
//! What it holds, and why it is this big: the transport's `Io` runs
//! with no async pool, because a pool makes std's happy-eyeballs cancel
//! signals land on the wrong `connect` and the process dies with
//! "programmer bug caused syscall error: ISCONN"
//! (src/services/http/native.zig says it in full). That is a race, so
//! the gate is sized by measurement rather than by taste: at this load
//! a transport with the pool back crashed on 20 runs out of 20, and
//! this one costs about a third of a second. Every request goes to
//! "localhost", which resolves to both loopback families — that is what
//! puts two addresses in the race on every single request.
//!
//! The App is built into the caller's storage rather than returned by
//! value, for the reason docs/testing.md gives: the press handlers hold
//! a `*App`, and an App that moves after `build` leaves them aimed at a
//! dead frame.

const std = @import("std");
const nok = @import("nokre");

const http = nok.services.http;
const driver = nok.testing.driver;
const queries = nok.testing.queries;
const audit = nok.testing.audit;

/// Two apps, eight requests in flight each, a hundred and twenty
/// rounds — 1920 requests. See the note above for where the numbers
/// come from.
const app_count = 2;
const in_flight = 8;
const rounds = 120;
const total = app_count * in_flight * rounds;

const body_text = "ok";

// A program that links the library owes the hooks a shell owes
// (docs/testing.md's "where the harness stops": the driver *is* the
// shell's half of the line). Naming the shipped shell is the whole
// install (src/testing/shell.zig).
comptime {
    _ = nok.testing.shell;
}

/// A loopback origin on both families at one port, so the name
/// "localhost" resolves to two addresses and every request runs std's
/// happy-eyeballs race between them. Hand-written rather than
/// std.http.Server for native_test.zig's reason: the wire is small and
/// the subject is what surrounds it.
const Origin = struct {
    gpa: std.mem.Allocator,
    backend: std.Io.Threaded,
    io: std.Io = undefined,
    v4: std.Io.net.Server = undefined,
    /// Absent on a host with IPv6 switched off, where "localhost" is
    /// one address and the race narrows. The gate still runs; it just
    /// asks less of the transport, and says so at the end.
    v6: ?std.Io.net.Server = null,
    port: u16 = 0,

    fn start(gpa: std.mem.Allocator) !*Origin {
        const self = try gpa.create(Origin);
        self.* = .{ .gpa = gpa, .backend = .init(gpa, .{}) };
        self.io = self.backend.io();

        const v4_address: std.Io.net.IpAddress = .{ .ip4 = .loopback(0) };
        self.v4 = try v4_address.listen(self.io, .{});
        self.port = self.v4.socket.address.getPort();

        const v6_address: std.Io.net.IpAddress = .{ .ip6 = .{
            .bytes = .{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1 },
            .port = self.port,
        } };
        self.v6 = v6_address.listen(self.io, .{}) catch null;

        (try std.Thread.spawn(.{}, acceptLoop, .{ self, &self.v4 })).detach();
        if (self.v6) |*server| (try std.Thread.spawn(.{}, acceptLoop, .{ self, server })).detach();
        return self;
    }

    /// One connection at a time per family, served on the accepting
    /// thread and closed after — `keep_alive = false` is the
    /// transport's rule, so every request is its own connection anyway.
    /// The loop is never asked to stop: the process exits under it, the
    /// same clock the transport's own detached threads end on.
    fn acceptLoop(self: *Origin, server: *std.Io.net.Server) void {
        while (true) {
            const stream = server.accept(self.io) catch return;
            defer stream.close(self.io);
            serve(self, stream) catch {};
        }
    }

    fn serve(self: *Origin, stream: std.Io.net.Stream) !void {
        var read_buffer: [4096]u8 = undefined;
        var reader = stream.reader(self.io, &read_buffer);
        while (true) {
            const line = try reader.interface.takeDelimiterInclusive('\n');
            if (std.mem.trimEnd(u8, line, "\r\n").len == 0) break;
        }
        var write_buffer: [256]u8 = undefined;
        var writer = stream.writer(self.io, &write_buffer);
        try writer.interface.writeAll("HTTP/1.1 200 OK\r\ncontent-length: " ++
            std.fmt.comptimePrint("{d}", .{body_text.len}) ++
            "\r\nconnection: close\r\n\r\n" ++ body_text);
        try writer.interface.flush();
    }
};

/// The per-app state a press handler reads. `url` is the origin's,
/// borrowed for the whole run.
const State = struct {
    app: *nok.App = undefined,
    url: []const u8 = "",
    status: nok.NodeId = .invalid,
    /// Results delivered to *this* app, so the run can prove each app's
    /// pump delivered its own.
    delivered: u32 = 0,
    /// Requests this app could not issue at all — see `onFetch`.
    refused: u32 = 0,
};

var wrong_status: u32 = 0;
var wrong_body: u32 = 0;
var transport_failures: u32 = 0;
/// Failures the *machine* produced, not the transport: on loopback,
/// nearly four thousand short-lived connections a run is enough to run
/// a tight `zig build test` loop out of ephemeral ports, and connect
/// then answers EADDRNOTAVAIL. Counted and reported, never failed on —
/// a port supply is not a defect, and the panic this gate holds off
/// takes the process down whatever the port supply is.
var starved: u32 = 0;
/// Requests no round could issue, summed across rounds — the per-app
/// counter resets with the app.
var refused: u32 = 0;
/// The first few unexpected failure names, so a real regression names
/// itself instead of arriving as a number.
var first_failures: [4][]const u8 = @splat("");

/// The UI thread, between events — every delivery lands here, so these
/// counters need no atomics.
fn onResult(ctx: ?*anyopaque, result: http.Result) void {
    const state: *State = @ptrCast(@alignCast(ctx.?));
    state.delivered += 1;
    // A delivery may write the tree, which is the point of arriving on
    // the UI thread rather than on the transport's.
    state.app.tree.setContent(state.status, "Fetched") catch {};
    state.app.invalidate();
    switch (result) {
        .response => |response| {
            if (response.status != 200) wrong_status += 1;
            if (!std.mem.eql(u8, response.body.view(), body_text)) wrong_body += 1;
        },
        .failure => |failure| {
            if (std.mem.eql(u8, failure.name, "AddressUnavailable")) {
                starved += 1;
            } else {
                if (transport_failures < first_failures.len) first_failures[transport_failures] = failure.name;
                transport_failures += 1;
            }
        },
    }
}

fn onFetch(ctx: ?*anyopaque) void {
    const state: *State = @ptrCast(@alignCast(ctx.?));
    _ = http.request(.{
        .app = state.app,
        .url = state.url,
        .ctx = state,
        .on_result = onResult,
    }) catch {
        // A machine that will not give this process another thread is
        // not a transport defect: the gate records it, keeps its
        // arithmetic honest, and goes on with a lighter load rather
        // than reporting a failure it did not observe.
        state.refused += 1;
    };
}

fn buildHome(ctx: ?*anyopaque, app: *nok.App) !void {
    const state: *State = @ptrCast(@alignCast(ctx.?));
    state.app = app;
    const root = app.tree.rootId();
    try app.tree.append(root, .{ .heading = .{ .content = "Stress", .level = .h1 } });
    state.status = try app.tree.appendId(root, .{ .text = .{ .content = "Idle" } });
    try app.tree.append(root, .{ .button = .{
        .label = "Fetch",
        .on_press = .{ .ctx = state, .call = onFetch },
    } });
}

fn launch(gpa: std.mem.Allocator, state: *State, app: *nok.App) !void {
    app.* = try nok.App.init(gpa, .{ .viewport = .{ .w = 480, .h = 640 }, .ctx = state });
    errdefer app.deinit();
    try buildHome(state, app);
    try audit.audit(app);
}

/// A request leaves the way one leaves a real app: a tap on a real
/// button through the real event pipeline.
fn tapFetch(app: *nok.App) !void {
    const id = queries.queryByLabel(&app.tree, "Fetch") orelse return error.NoFetchButton;
    try driver.tap(app, id);
}

pub fn main() !void {
    // The page allocator, not a leak-checking one: the watchdog thread
    // of every request holds its job for the transport deadline
    // (thirty seconds), so at the end of a run that takes a fraction of
    // a second nearly two thousand of them are still asleep with memory
    // this process legitimately owes them. Leak checking is the unit
    // suite's job; threads are this one's.
    const gpa = std.heap.page_allocator;

    const origin = try Origin.start(gpa);
    var url_buffer: [64]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buffer, "http://localhost:{d}/", .{origin.port});

    var states: [app_count]State = undefined;
    var apps: [app_count]nok.App = undefined;

    var issued: u32 = 0;
    var round: u32 = 0;
    while (round < rounds) : (round += 1) {
        for (&states, &apps) |*state, *app| {
            state.* = .{ .url = url };
            try launch(gpa, state, app);
        }

        // Every app's requests go out before any of them is pumped:
        // in flight together is the whole point.
        var i: u32 = 0;
        while (i < in_flight) : (i += 1) {
            for (&apps) |*app| {
                try tapFetch(app);
                issued += 1;
            }
        }

        // Pump to quiescence. Deliveries arrive on this thread only
        // here, which is the contract being exercised.
        while (true) {
            var outstanding: u32 = 0;
            for (&states, &apps) |*state, *app| {
                app.runtime.pumpAll();
                outstanding += in_flight - state.delivered - state.refused;
            }
            if (outstanding == 0) break;
            std.Thread.yield() catch {};
        }

        for (&states, &apps) |*state, *app| {
            refused += state.refused;
            app.deinit();
        }
    }

    if (wrong_status != 0 or wrong_body != 0 or transport_failures != 0) {
        std.debug.print(
            "http stress: {d} bad statuses, {d} bad bodies, {d} transport failures\n",
            .{ wrong_status, wrong_body, transport_failures },
        );
        for (first_failures) |name| {
            if (name.len != 0) std.debug.print("http stress:   failure {s}\n", .{name});
        }
        return error.BadResults;
    }
    if (issued != total) {
        std.debug.print("http stress: issued {d} of {d}\n", .{ issued, total });
        return error.WrongCount;
    }

    // stderr, and one line, so the run step can assert the last thing
    // this program says — which asserts every step before it ran.
    std.debug.print(
        "http stress: {d} requests, 2 apps, {s} loopback families, {d} refused, {d} port-starved — all ok\n",
        .{ total, if (origin.v6 != null) "two" else "one", refused, starved },
    );
}
