//! The Windows and Linux leg: the default browser plus a loopback
//! listener (RFC 8252 §7.3). Neither desktop has an auth-session API
//! worth binding — the xdg desktop portal has none, and Windows'
//! WebAuthenticationBroker is a WinRT/UWP surface a Win32 app cannot use
//! — so both share this one implementation, and their whole native
//! surface shrinks to `nokre_oauth_open_url`.
//!
//! One detached thread per flow, blocked on `accept` until the browser
//! redirects: the same bargain as the http service's native transport
//! (a thread you can see, one-shot), delivering through the same
//! one-shot ticket. That is the plan's "the listener is a worker, not a
//! shell thread" in substance — off the UI thread, result as a callback
//! — without making oauth the first service to compose the worker
//! registry, which would drag `nokreWorkers` membership into every
//! consumer that signs in.
//!
//! Ownership is a two-count refcount, because the listener outlives
//! neither side reliably: the app may cancel while the thread is blocked
//! in `accept`, and the thread may finish while the app is mid-teardown.
//! The UI thread holds one reference from `bind`, the thread holds the
//! second from `run`, and whichever drops last closes the socket.
//! Cancellation wakes the blocked `accept` by connecting to the port
//! itself — the socket is ours and nobody else's, so the self-connect is
//! exact where closing an fd another thread is sitting in would race.

const std = @import("std");
const workers = @import("../../workers/workers.zig");
const oauth = @import("oauth.zig");

const net = std.Io.net;

// The Io backend, refcounted like workers/thread.zig's: each listener
// holds one reference from `bind` to its final `unref`, so the backend
// outlives both sides of the two-count ownership below — including the
// detached thread — and the last release tears it down, so a
// leak-checked binary ends clean without a process atexit. A listener
// whose accept the self-connect failed to wake keeps its reference to
// process end, the same clock its thread already ends on.
// Deliberately a second copy of http/native.zig's — the two services do
// not depend on each other, and sharing ten lines through a third module
// would make them.
var io_lock: std.atomic.Value(bool) = .init(false);
var io_backend: ?std.Io.Threaded = null;
var io: std.Io = undefined;
var io_refs: usize = 0;

fn lockIo() void {
    while (io_lock.cmpxchgWeak(false, true, .acquire, .monotonic) != null) {
        std.atomic.spinLoopHint();
    }
}

fn unlockIo() void {
    io_lock.store(false, .release);
}

fn acquireIo(gpa: std.mem.Allocator) std.Io {
    lockIo();
    defer unlockIo();
    if (io_backend == null) {
        io_backend = std.Io.Threaded.init(gpa, .{});
        io = io_backend.?.io();
    }
    io_refs += 1;
    return io;
}

fn releaseIo() void {
    lockIo();
    defer unlockIo();
    io_refs -= 1;
    if (io_refs == 0) {
        io_backend.?.deinit();
        io_backend = null;
    }
}

/// The request line cap. A callback URL carries an authorization code
/// and a `state`, both short; 8 KiB is the same head budget the http
/// client uses for redirects, and anything past it is not a browser
/// following our redirect.
const max_request_line = 8 * 1024;

/// What the browser lands on. Plain text and self-explanatory: the user
/// is looking at it, and the app has already been told.
const page =
    "HTTP/1.1 200 OK\r\n" ++
    "Content-Type: text/plain; charset=utf-8\r\n" ++
    "Content-Length: 40\r\n" ++
    "Connection: close\r\n" ++
    "\r\n" ++
    "Signed in. You can close this window.\r\n\r\n";

/// What anything that is not the redirect lands on — a favicon fetch, a
/// probe. The listener answers and keeps waiting for the real one.
const not_found =
    "HTTP/1.1 404 Not Found\r\n" ++
    "Content-Type: text/plain; charset=utf-8\r\n" ++
    "Content-Length: 10\r\n" ++
    "Connection: close\r\n" ++
    "\r\n" ++
    "Not found\n";

pub const Listener = struct {
    gpa: std.mem.Allocator,
    server: net.Server,
    port: u16,
    /// One for the UI thread (from `bind`), one for the listening thread
    /// (from `run`).
    refs: std.atomic.Value(u32) = .init(1),
    /// Set by `release(cancelling)`; the thread reads it after the
    /// accept the self-connect woke.
    stopping: std.atomic.Value(bool) = .init(false),
    ticket: workers.Ticket = undefined,

    fn unref(self: *Listener) void {
        if (self.refs.fetchSub(1, .release) != 1) return;
        _ = self.refs.load(.acquire);
        self.server.deinit(io);
        const gpa = self.gpa;
        gpa.destroy(self);
        // The listener's Io reference, held since `bind` — released
        // only after the socket that needed the backend is closed.
        releaseIo();
    }
};

/// Bind an ephemeral loopback port. Called from `redirectUri`, strictly
/// before the app writes the port into its authorize URL — which is the
/// whole reason `redirectUri` exists as a separate call.
pub fn bind(gpa: std.mem.Allocator) !*Listener {
    _ = acquireIo(gpa);
    errdefer releaseIo();
    const self = try gpa.create(Listener);
    errdefer gpa.destroy(self);
    // 127.0.0.1, never 0.0.0.0 and never `localhost`: the listener must
    // be unreachable from the network, and RFC 8252 §8.3 prefers the
    // literal address because a hosts file can point `localhost`
    // somewhere else.
    const address: net.IpAddress = .{ .ip4 = .loopback(0) };
    // reuse_address deliberately off: SO_REUSEADDR on an ephemeral port
    // would let a second process bind the port this flow is waiting on,
    // and the redirect carries an authorization code.
    var server = try address.listen(io, .{ .reuse_address = false });
    errdefer server.deinit(io);
    self.* = .{ .gpa = gpa, .server = server, .port = server.socket.address.getPort() };
    return self;
}

pub fn portOf(self: *Listener) u16 {
    return self.port;
}

/// Start listening. The thread takes the second reference; from here the
/// listener frees itself once both sides are done with it.
pub fn run(self: *Listener, ticket: workers.Ticket) !void {
    self.ticket = ticket;
    // A detached thread can outlive the app: hold a runtime reference so
    // the ticket's memory stays valid until the job releases it —
    // deliveries after shutdown are dropped, not dangling (http's rule).
    ticket.runtime.ref();
    errdefer ticket.runtime.unref();
    _ = self.refs.fetchAdd(1, .monotonic);
    errdefer _ = self.refs.fetchSub(1, .monotonic);
    const thread = try std.Thread.spawn(.{}, serve, .{self});
    thread.detach();
}

/// The UI thread is done with this listener. `cancelling` wakes a
/// blocked accept; on the settle path the thread has already returned
/// on its own.
pub fn release(self: *Listener, cancelling: bool) void {
    if (cancelling) {
        self.stopping.store(true, .release);
        // Wake the accept by being the connection it is waiting for.
        // Best-effort: if it fails, the thread stays blocked until the
        // user's browser lands or the process ends, and its delivery is
        // dropped by the ticket's generation check either way.
        const address: net.IpAddress = .{ .ip4 = .loopback(self.port) };
        if (net.IpAddress.connect(&address, io, .{ .mode = .stream })) |stream| {
            stream.close(io);
        } else |_| {}
    }
    self.unref();
}

fn serve(self: *Listener) void {
    defer self.unref();
    defer self.ticket.runtime.unref();

    // Loop until the redirect: browsers open speculative connections
    // they never write to, and fetch /favicon.ico beside the page — a
    // listener that treated its first connection as the redirect would
    // let either of those kill the flow. A connection that carries no
    // parseable GET is closed and forgotten; a GET for anything but
    // `callback_path` gets a 404 and the listener keeps waiting. Only
    // the matching request is delivered.
    while (true) {
        var stream = self.server.accept(io) catch {
            deliver(self, .{ .failure = .{ .name = "ListenFailed" } });
            return;
        };
        if (self.stopping.load(.acquire)) {
            stream.close(io);
            return; // the app cancelled; the app knows
        }

        var read_buf: [max_request_line]u8 = undefined;
        var reader = stream.reader(io, &read_buf);
        const line = reader.interface.takeDelimiterExclusive('\n') catch {
            stream.close(io);
            continue;
        };
        const target = requestTarget(std.mem.trimEnd(u8, line, "\r")) orelse {
            stream.close(io);
            continue;
        };
        const matched = isCallback(target);

        // Answer the browser before delivering: the user is staring at a
        // loading tab, and the app's handler may take a token exchange's
        // worth of time.
        var write_buf: [@max(page.len, not_found.len)]u8 = undefined;
        var writer = stream.writer(io, &write_buf);
        writer.interface.writeAll(if (matched) page else not_found) catch {};
        writer.interface.flush() catch {};
        stream.close(io);
        if (!matched) continue;

        // The app gets the whole URL, exactly as every other leg reports
        // it, so one parse serves all six platforms.
        var url_buf: [max_request_line + 64]u8 = undefined;
        const url = std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}{s}", .{ self.port, target }) catch {
            deliver(self, .{ .failure = .{ .name = "BadRedirect" } });
            return;
        };
        deliver(self, .{ .callback = url });
        return;
    }
}

/// Whether the request target's path — the bytes before any query or
/// fragment — is the one path this listener registered. Anything else is
/// not the redirect, however well-formed.
fn isCallback(target: []const u8) bool {
    const end = std.mem.indexOfAny(u8, target, "?#") orelse target.len;
    const path = target[0..end];
    return path.len == 1 + oauth.callback_path.len and
        path[0] == '/' and
        std.mem.eql(u8, path[1..], oauth.callback_path);
}

/// `GET /callback?code=… HTTP/1.1` → `/callback?code=…`. Only GET: a
/// browser following a redirect issues nothing else, and accepting more
/// would be accepting requests this listener has no business answering.
fn requestTarget(line: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, line, "GET ")) return null;
    const rest = line[4..];
    const sp = std.mem.indexOfScalar(u8, rest, ' ') orelse return null;
    if (sp == 0) return null;
    return rest[0..sp];
}

fn deliver(self: *Listener, result: oauth.Result) void {
    workers.deliverOneShot(oauth.Result, self.ticket, self.gpa, result) catch {};
}
