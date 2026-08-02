//! Serves a built site over http, so the browser will load it at all.
//!
//! Neither a wasm module nor an ES module loads from a `file://` URL, so
//! a directory the build just wrote cannot be opened — it has to be
//! served, and this is the whole of that. Build-time only, like
//! emit_css.zig beside it: `zig build serve` here and
//! `nokre.addWebServe` in a consumer's build.zig both run this binary
//! over the directory the web build produced.
//!
//!     ./serve <site-dir> [port]
//!
//! Not a general static server and not a host: it binds the loopback
//! address only (a dev server is not a publish), answers GET and HEAD,
//! and holds nothing between requests.

const std = @import("std");
const Io = std.Io;

/// One connection's read and write buffers. The read half must hold a
/// whole request head or `receiveHead` refuses it; the write half is
/// just a socket buffer, since a response body is handed over whole.
const buffer_len = 16 * 1024;

/// A dev server serves what a build wrote, and nokre's largest artifact
/// is a wasm module in the low megabytes. The cap is here so a stray
/// request for something enormous fails as a request rather than as an
/// allocation.
const max_file_bytes = 64 * 1024 * 1024;

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;
    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, gpa);
    _ = args.next(); // argv0

    const site_path = args.next() orelse std.process.fatal("usage: serve <site-dir> [port]", .{});
    const port: u16 = if (args.next()) |text|
        std.fmt.parseInt(u16, text, 10) catch std.process.fatal("port must be a number, not \"{s}\"", .{text})
    else
        8000;

    var site = Io.Dir.cwd().openDir(io, site_path, .{}) catch |err|
        std.process.fatal("cannot open {s}: {t}", .{ site_path, err });
    defer site.close(io);

    // Loopback, never 0.0.0.0: the site is being *developed*, and a
    // build step that opened a port to the local network would be
    // publishing it on the developer's behalf.
    const address = Io.net.IpAddress.parseIp4("127.0.0.1", port) catch unreachable;
    var server = address.listen(io, .{ .reuse_address = true }) catch |err| switch (err) {
        error.AddressInUse => std.process.fatal("port {d} is already in use — serve on another one (nokre.ServeOptions.port, or -Dport here)", .{port}),
        else => return err,
    };
    defer server.deinit(io);
    // The URL first, because it is the one thing the reader has to act
    // on; the directory after it, because a page that looks stale is
    // usually a site being served from somewhere else.
    std.debug.print("nokre: http://localhost:{d}/ — serving {s}, ctrl-c to stop\n", .{ port, site_path });

    // One task per connection, because a browser opens several at once
    // and may leave one of them idle: a server that read them in turn
    // would sit on the silent socket while the page waits for its wasm.
    // The group is long-lived on purpose — a concurrent task releases
    // its own resources when it returns (std.Io.Group states it) — and
    // an implementation with no concurrency to give answers the
    // connection in line rather than dropping it.
    var group: Io.Group = .init;
    defer group.cancel(io);
    while (true) {
        const stream = server.accept(io) catch |err| switch (err) {
            error.ConnectionAborted, error.ProtocolFailure, error.BlockedByFirewall => continue,
            else => return err,
        };
        group.concurrent(io, connection, .{ io, gpa, site, stream }) catch
            connection(io, gpa, site, stream);
    }
}

/// One connection, served until the peer stops asking. Every failure
/// here is the peer's business and none of the server's: a request that
/// cannot be parsed or a socket that goes away ends this connection and
/// touches no other.
fn connection(io: Io, gpa: std.mem.Allocator, site: Io.Dir, stream: Io.net.Stream) void {
    defer stream.close(io);
    const buffers = gpa.alloc(u8, 2 * buffer_len) catch return;
    defer gpa.free(buffers);
    var reader = stream.reader(io, buffers[0..buffer_len]);
    var writer = stream.writer(io, buffers[buffer_len..]);
    var http_server: std.http.Server = .init(&reader.interface, &writer.interface);
    while (true) {
        var request = http_server.receiveHead() catch return;
        respond(io, gpa, site, &request) catch return;
    }
}

fn respond(io: Io, gpa: std.mem.Allocator, site: Io.Dir, request: *std.http.Server.Request) !void {
    switch (request.head.method) {
        // HEAD needs no branch of its own: `respond` omits the body for
        // it, and every header stays the one GET would have sent.
        .GET, .HEAD => {},
        else => return request.respond("", .{ .status = .method_not_allowed }),
    }
    var index_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const sub_path = resolve(request.head.target, &index_buffer) orelse
        return request.respond("", .{ .status = .not_found });

    const bytes = site.readFileAlloc(io, sub_path, gpa, .limited(max_file_bytes)) catch |err| switch (err) {
        error.FileNotFound, error.IsDir, error.AccessDenied, error.NotDir => return request.respond("", .{ .status = .not_found }),
        else => return request.respond("", .{ .status = .internal_server_error }),
    };
    defer gpa.free(bytes);
    try request.respond(bytes, .{
        .extra_headers = &.{
            .{ .name = "content-type", .value = mimeFor(sub_path) },
            // The reason this server exists is a rebuild being one refresh
            // away; a cached wasm module would make it two, the second one
            // being a hard reload the developer has to know about.
            .{ .name = "cache-control", .value = "no-store" },
            // The generated page carries the rest of the policy itself
            // (packaging.webIndexHtml); this is the part it cannot.
            // `frame-ancestors` is ignored inside a meta tag by spec, so
            // it belongs to whoever serves the site — and while this
            // server is developing rather than publishing, it is the one
            // server nokre owns, so it sends what it tells a consumer's
            // edge to send. Not a claim that a dev server is a
            // deployment: docs/getting-started.md lists what else an edge
            // still owes.
            .{ .name = "content-security-policy", .value = "frame-ancestors 'none'" },
        },
    });
}

/// The request target as a path inside the site, or null when it names
/// something this server will not answer for.
///
/// No percent-decoding, which is a refusal rather than an omission:
/// every name here was written by the build and every one of them is
/// ASCII, and a decoder is exactly how `%2e%2e` becomes a way out of
/// the site.
fn resolve(target: []const u8, index_buffer: []u8) ?[]const u8 {
    if (target.len == 0 or target[0] != '/') return null;
    var rest = target[1..];
    if (std.mem.indexOfAny(u8, rest, "?#")) |cut| rest = rest[0..cut];
    if (std.mem.indexOfScalar(u8, rest, 0) != null) return null;
    // An absolute path would be resolved against the filesystem root
    // rather than the site directory — `openat` ignores the directory
    // handle when handed one — so "//etc/passwd" is a way out and this
    // is where it stops. Windows separators travel with it: a path this
    // server splits by '/' would hand a '\' through whole.
    if (std.fs.path.isAbsolute(rest) or std.mem.indexOfScalar(u8, rest, '\\') != null) return null;
    var segments = std.mem.splitScalar(u8, rest, '/');
    while (segments.next()) |segment| {
        if (std.mem.eql(u8, segment, "..") or std.mem.eql(u8, segment, ".")) return null;
    }
    // A directory is its index, and the empty target is the site
    // root's — which is the request a reader's first visit makes.
    if (rest.len != 0 and rest[rest.len - 1] != '/') return rest;
    return std.fmt.bufPrint(index_buffer, "{s}index.html", .{rest}) catch null;
}

/// The content type a browser needs to be told, per extension. This is
/// the half of a static server nokre cannot leave to chance:
/// `WebAssembly.instantiateStreaming` refuses a module that did not
/// arrive as `application/wasm`, and an ES module import refuses
/// anything that is not a JavaScript type — both fail as a blank page
/// rather than as a message about a header. The rest of the table is
/// the set the site actually contains.
fn mimeFor(sub_path: []const u8) []const u8 {
    const table = .{
        .{ ".wasm", "application/wasm" },
        .{ ".js", "text/javascript; charset=utf-8" },
        .{ ".html", "text/html; charset=utf-8" },
        .{ ".css", "text/css; charset=utf-8" },
        .{ ".json", "application/json" },
        .{ ".webmanifest", "application/manifest+json" },
        .{ ".ttf", "font/ttf" },
        .{ ".png", "image/png" },
        .{ ".svg", "image/svg+xml" },
        .{ ".txt", "text/plain; charset=utf-8" },
    };
    inline for (table) |row| {
        if (std.mem.endsWith(u8, sub_path, row[0])) return row[1];
    }
    return "application/octet-stream";
}

test "the server itself is analyzed" {
    // Nothing in a test build reaches `main`, and nothing in `zig build`
    // compiles this tool until someone asks for the site to be served —
    // so without this line a broken server waits for a developer who
    // wanted to look at their app, which is the worst moment to find it.
    _ = &main;
}

test "a target resolves to a path inside the site, or to nothing" {
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    try std.testing.expectEqualStrings("index.html", resolve("/", &buffer).?);
    try std.testing.expectEqualStrings("app.wasm", resolve("/app.wasm", &buffer).?);
    try std.testing.expectEqualStrings("fonts/prose.ttf", resolve("/fonts/prose.ttf", &buffer).?);
    // The query and the fragment are the browser's, never a filename.
    try std.testing.expectEqualStrings("index.html", resolve("/?v=2", &buffer).?);
    try std.testing.expectEqualStrings("index.html", resolve("/#note~42", &buffer).?);
    try std.testing.expectEqualStrings("sub/index.html", resolve("/sub/", &buffer).?);

    // Nothing climbs out of the site, by any of the three roads.
    try std.testing.expectEqual(null, resolve("/../secrets", &buffer));
    try std.testing.expectEqual(null, resolve("/fonts/../../secrets", &buffer));
    try std.testing.expectEqual(null, resolve("//etc/passwd", &buffer));
    try std.testing.expectEqual(null, resolve("/..\\secrets", &buffer));
    // An undecoded escape is a filename that does not exist, which is a
    // 404 — not a second spelling of "..".
    try std.testing.expectEqualStrings("%2e%2e/secrets", resolve("/%2e%2e/secrets", &buffer).?);
    // An absolute-form target (a proxy's shape) names no file here.
    try std.testing.expectEqual(null, resolve("http://localhost/app.wasm", &buffer));
}

test "the two types a browser refuses to guess are stated" {
    try std.testing.expectEqualStrings("application/wasm", mimeFor("app.wasm"));
    try std.testing.expectEqualStrings("text/javascript; charset=utf-8", mimeFor("live-worker.js"));
    try std.testing.expectEqualStrings("text/html; charset=utf-8", mimeFor("index.html"));
    try std.testing.expectEqualStrings("application/manifest+json", mimeFor("manifest.webmanifest"));
    try std.testing.expectEqualStrings("font/ttf", mimeFor("fonts/prose.ttf"));
    try std.testing.expectEqualStrings("application/octet-stream", mimeFor("LICENSE"));
}
