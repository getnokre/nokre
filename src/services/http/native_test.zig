//! The native transport against a real socket. Everything else about
//! the http service is asserted through the mock (http_test.zig), and
//! that is exactly why the send path shipped broken: a fake network
//! answers whatever it is asked, so the one thing std.http.Client
//! insists on — that the path and the method agree — was never put to
//! a client at all. So this file runs the transport, over loopback,
//! against an origin in this process, and asserts the bytes that went
//! out.
//!
//! Two halves it deliberately does not cover, said plainly rather than
//! left to be discovered. `send`'s threads: the deadline watchdog
//! sleeps `deadline_seconds` out before it drops its reference, and a
//! gate can neither wait thirty seconds nor join a thread the design
//! refuses to join (native.zig's no-forced-kill rule) — the delivery
//! contract those threads serve is the mock's, and asserted there. And
//! TLS: a certificate this build could offer is a certificate authority
//! this build would have to become, and the send path is chosen before
//! the scheme matters.

const std = @import("std");
const http = @import("http.zig");
const native = @import("native.zig");

/// A one-request HTTP origin on loopback: an ephemeral port, exactly
/// one connection served on its own thread, and the bytes it was sent
/// kept for the assertions. Hand-written rather than std.http.Server
/// because the wire is the subject here, not a parse of it.
const Origin = struct {
    gpa: std.mem.Allocator,
    backend: std.Io.Threaded,
    io: std.Io = undefined,
    server: std.Io.net.Server = undefined,
    thread: std.Thread = undefined,
    port: u16 = 0,
    /// The request head as read: one field per line, '\r' stripped,
    /// ending in the blank line.
    head: std.ArrayList(u8) = .empty,
    body: std.ArrayList(u8) = .empty,
    err: ?anyerror = null,

    fn start(gpa: std.mem.Allocator) !*Origin {
        const self = try gpa.create(Origin);
        errdefer gpa.destroy(self);
        self.* = .{ .gpa = gpa, .backend = .init(gpa, .{}) };
        self.io = self.backend.io();
        const address: std.Io.net.IpAddress = .{ .ip4 = .loopback(0) };
        self.server = try address.listen(self.io, .{});
        self.port = self.server.socket.address.getPort();
        self.thread = try std.Thread.spawn(.{}, serve, .{self});
        return self;
    }

    /// Wait for the connection to be served, and re-raise whatever the
    /// origin's thread hit — a server that failed silently would read
    /// as a client that sent nothing.
    fn finish(self: *Origin) !void {
        self.thread.join();
        if (self.err) |e| return e;
    }

    fn deinit(self: *Origin) void {
        self.head.deinit(self.gpa);
        self.body.deinit(self.gpa);
        self.server.deinit(self.io);
        self.backend.deinit();
        self.gpa.destroy(self);
    }

    fn serve(self: *Origin) void {
        self.serveOne() catch |e| {
            self.err = e;
        };
    }

    fn serveOne(self: *Origin) !void {
        const stream = try self.server.accept(self.io);
        defer stream.close(self.io);

        var read_buf: [4096]u8 = undefined;
        var reader = stream.reader(self.io, &read_buf);
        var content_length: usize = 0;
        while (true) {
            const line = try reader.interface.takeDelimiterInclusive('\n');
            const field = std.mem.trimEnd(u8, line, "\r\n");
            try self.head.appendSlice(self.gpa, field);
            try self.head.append(self.gpa, '\n');
            if (field.len == 0) break;
            if (std.ascii.startsWithIgnoreCase(field, content_length_name)) {
                const value = std.mem.trim(u8, field[content_length_name.len..], " ");
                content_length = try std.fmt.parseInt(usize, value, 10);
            }
        }
        try self.body.resize(self.gpa, content_length);
        try reader.interface.readSliceAll(self.body.items);

        var write_buf: [128]u8 = undefined;
        var writer = stream.writer(self.io, &write_buf);
        // A HEAD response carries no body; every other verb gets two
        // bytes, so a response that never arrived cannot pass for one
        // that did.
        try writer.interface.writeAll(if (std.mem.startsWith(u8, self.head.items, "HEAD "))
            "HTTP/1.1 200 OK\r\ncontent-length: 0\r\n\r\n"
        else
            "HTTP/1.1 200 OK\r\ncontent-length: 2\r\n\r\nok");
        try writer.interface.flush();
    }

    fn requestLine(self: *const Origin) []const u8 {
        const end = std.mem.indexOfScalar(u8, self.head.items, '\n') orelse self.head.items.len;
        return self.head.items[0..end];
    }

    fn hasField(self: *const Origin, field: []const u8) bool {
        var it = std.mem.splitScalar(u8, self.head.items, '\n');
        while (it.next()) |line| if (std.ascii.eqlIgnoreCase(line, field)) return true;
        return false;
    }

    fn hasContentLength(self: *const Origin) bool {
        var it = std.mem.splitScalar(u8, self.head.items, '\n');
        while (it.next()) |line| {
            if (std.ascii.startsWithIgnoreCase(line, content_length_name)) return true;
        }
        return false;
    }

    const content_length_name = "content-length:";
};

/// One request through the real transport to a fresh origin: what the
/// server read is `origin`, what came back is `status`/`body`.
const Exchange = struct {
    origin: *Origin,
    status: u16,
    body: []u8,

    fn deinit(self: *Exchange, gpa: std.mem.Allocator) void {
        gpa.free(self.body);
        self.origin.deinit();
    }
};

fn exchange(gpa: std.mem.Allocator, method: http.Method, body: []const u8) !Exchange {
    const origin = try Origin.start(gpa);
    errdefer origin.deinit();

    var url_buf: [64]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}/r", .{origin.port});

    // The Io reference is what `send` takes per thread; `perform` is
    // the transfer it wraps, run here on the test's own thread.
    _ = native.acquireIo(gpa);
    defer native.releaseIo();

    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const response = try native.perform(gpa, .{
        .method = method.asStd(),
        .url = url,
        .headers = &.{},
        .body = body,
        .max_body = 1 << 20,
    }, arena_state.allocator());
    const returned = response.body.take();
    errdefer gpa.free(returned);
    try origin.finish();
    return .{ .origin = origin, .status = response.status, .body = returned };
}

fn expectRequestLine(method: http.Method, origin: *const Origin) !void {
    var buf: [32]u8 = undefined;
    const expected = try std.fmt.bufPrint(&buf, "{s} /r HTTP/1.1", .{@tagName(method)});
    try std.testing.expectEqualStrings(expected, origin.requestLine());
}

test "a mutation with no fields still goes out as a body request" {
    // The defect: the send path was chosen by measuring the body, so a
    // POST, PUT or PATCH with nothing to say took the bodiless path —
    // whose assertion is that the method carries no body, and whose
    // failure is a panicked process on the app's first such call.
    const gpa = std.testing.allocator;
    for ([_]http.Method{ .POST, .PUT, .PATCH }) |method| {
        var ex = try exchange(gpa, method, "");
        defer ex.deinit(gpa);
        try expectRequestLine(method, ex.origin);
        try std.testing.expect(ex.origin.hasField("content-length: 0"));
        try std.testing.expectEqualStrings("", ex.origin.body.items);
        try std.testing.expectEqual(200, ex.status);
        try std.testing.expectEqualStrings("ok", ex.body);
    }
}

test "a body rides the verbs that carry one, whole" {
    const gpa = std.testing.allocator;
    const payload = "{\"a\":1}";
    for ([_]http.Method{ .POST, .PUT, .PATCH }) |method| {
        var ex = try exchange(gpa, method, payload);
        defer ex.deinit(gpa);
        try expectRequestLine(method, ex.origin);
        try std.testing.expect(ex.origin.hasField("content-length: 7"));
        try std.testing.expectEqualStrings(payload, ex.origin.body.items);
        try std.testing.expectEqual(200, ex.status);
        try std.testing.expectEqualStrings("ok", ex.body);
    }
}

test "GET, HEAD and DELETE keep the bodiless path" {
    // The assertion that runs the other way: the bodiless path demands
    // a method that carries none, so a branch that satisfied the
    // mutations by always writing a body would break here instead.
    const gpa = std.testing.allocator;
    for ([_]http.Method{ .GET, .HEAD, .DELETE }) |method| {
        var ex = try exchange(gpa, method, "");
        defer ex.deinit(gpa);
        try expectRequestLine(method, ex.origin);
        try std.testing.expect(!ex.origin.hasContentLength());
        try std.testing.expectEqualStrings("", ex.origin.body.items);
        try std.testing.expectEqual(200, ex.status);
        try std.testing.expectEqualStrings(if (method == .HEAD) "" else "ok", ex.body);
    }
}

test "the closed verb set's body table is std's" {
    // The branch condition in isolation — cheap, and it pins the one
    // mapping the wire tests above depend on, so a verb can never pick
    // its send path by accident.
    inline for (.{ .GET, .HEAD, .DELETE }) |method| {
        try std.testing.expect(!http.Method.asStd(method).requestHasBody());
    }
    inline for (.{ .POST, .PUT, .PATCH }) |method| {
        try std.testing.expect(http.Method.asStd(method).requestHasBody());
    }
}
