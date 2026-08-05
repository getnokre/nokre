//! The native transport: one detached std.Thread per request, blocked
//! on std.http.Client until the response lands — a thread you can see,
//! the worker bargain, but one-shot. Detached rather than joined: a
//! socket mid-read cannot be interrupted (the no-forced-kill rule), so
//! cancellation and shutdown drop the *delivery* instead — the
//! generation check at the pump — and the thread ends on its own
//! clock, invisibly.
//!
//! The transport deadline (http.deadline_seconds) is a second thread
//! you can see: a watchdog that sleeps the deadline out and then
//! claims the one delivery if the transfer has not — a cancel the
//! transport performs itself. No socket is touched (the no-forced-kill
//! rule again): the transfer may still finish on its own clock, and
//! its late delivery loses the claim exactly the way a cancelled one
//! loses the generation check.
//!
//! Requests allocate from the app's gpa, from their own thread, the
//! way worker threads do. The std.Io.Threaded backend is refcounted
//! like workers/thread.zig's: each request thread holds a reference
//! until it exits — so the backend always outlives the detached
//! threads that use it — and the last release tears it down, so a
//! leak-checked test binary ends clean without a process atexit.
//!
//! The backend runs with no async pool at all (`async_limit = .nothing`),
//! which is what makes the paragraph above literally true: the request
//! thread is the only thread the transfer touches. That is not a tuning
//! choice — it is the one thing standing between this transport and a
//! crash. `std.Io.Threaded` implements cancellation by sending SIGIO to
//! the pool thread blocked in a syscall, and `std.http.Client` reaches
//! `HostName.connect`, whose happy-eyeballs race *cancels the losing
//! connect on every multi-address host*. A signal aimed at one attempt
//! can land after that thread has moved on to another request's
//! `connect`, where std retries the interrupted call — which POSIX does
//! not allow, because after EINTR the connection completes
//! asynchronously and the retry answers EISCONN, an errno std treats as
//! a programmer bug and panics on. With no pool, `Io.async` runs the
//! task on the caller (std's documented fallback), no thread is ever a
//! `pthread_kill` target, and that whole class of stray interrupt is
//! gone. See tests/http_stress.zig, the gate that holds it.
//!
//! What it costs, said plainly: one host's addresses are now tried in
//! sequence rather than in parallel, so a silently black-holed address
//! ahead of a good one delays the request instead of losing a race to
//! it. Refused addresses — the common shape of broken IPv6 — still
//! answer at once, and the deadline above is what bounds the rest: the
//! app sees "TimedOut", never a hang. The other edge is std's queues,
//! 32 entries each: a host resolving to more than 32 addresses would
//! fill one with no consumer running, and that request reaches the app
//! as the same "TimedOut". Both are a slow request; the pool's price
//! was a dead process.

const std = @import("std");
const builtin = @import("builtin");
const workers = @import("../../workers/workers.zig");
const http = @import("http.zig");

// CAS spin-guard (see workers/thread.zig for why not std.Io.Mutex):
// two apps may issue their first requests from two threads, and the
// guarded section is a few instructions of lazy init.
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

/// Each request holds two references — one per thread, transfer and
/// watchdog — released on each thread's way out, never sooner, so the
/// backend outlives every blocking call made on it. First acquire
/// creates, last release destroys (thread.zig's bargain). While any
/// reference lives, the module-level `io` is pinned and any thread may
/// read it — the refcounted-backend exemption in
/// docs/internals/architecture.md.
pub fn acquireIo(gpa: std.mem.Allocator) std.Io {
    lockIo();
    defer unlockIo();
    if (io_backend == null) {
        // No pool: every `Io.async` under std.http.Client runs on the
        // calling thread, which is this request's own (the module note).
        io_backend = std.Io.Threaded.init(gpa, .{ .async_limit = .nothing });
        io = if (comptime builtin.abi.isAndroid())
            android_lookup.wrap(io_backend.?.io())
        else
            io_backend.?.io();
    }
    io_refs += 1;
    return io;
}

pub fn releaseIo() void {
    lockIo();
    defer unlockIo();
    io_refs -= 1;
    if (io_refs == 0) {
        io_backend.?.deinit();
        io_backend = null;
    }
}

// ---- Android name lookup ----
// Bionic has no /etc/resolv.conf — DNS lives behind netd, reachable
// only through getaddrinfo — so std.Io.Threaded's Linux resolver
// reports NameServerFailure for every hostname. The fix is a vtable
// veneer: every operation stays on the Threaded implementation except
// netLookup, which blocks on libc's resolver instead (a blocking call
// is this transport's whole design — the request already owns a
// visible thread).
const android_lookup = struct {
    const HostName = std.Io.net.HostName;
    const IpAddress = std.Io.net.IpAddress;

    var vtable: std.Io.VTable = undefined;

    fn wrap(threaded_io: std.Io) std.Io {
        vtable = threaded_io.vtable.*;
        vtable.netLookup = netLookup;
        return .{ .userdata = threaded_io.userdata, .vtable = &vtable };
    }

    fn netLookup(
        userdata: ?*anyopaque,
        host_name: HostName,
        resolved: *std.Io.Queue(HostName.LookupResult),
        options: HostName.LookupOptions,
    ) HostName.LookupError!void {
        const wrapped: std.Io = .{ .userdata = userdata, .vtable = &vtable };
        // The contract (HostName.lookup): the queue closes before
        // return, even on error, and never earlier.
        defer resolved.close(wrapped);
        lookupFallible(wrapped, host_name, resolved, options) catch |err| switch (err) {
            error.Closed => unreachable, // consumer keeps the queue open until we return
            else => |e| return e,
        };
    }

    fn lookupFallible(
        wrapped: std.Io,
        host_name: HostName,
        resolved: *std.Io.Queue(HostName.LookupResult),
        options: HostName.LookupOptions,
    ) (HostName.LookupError || std.Io.QueueClosedError)!void {
        var name_z: [HostName.max_len + 1]u8 = undefined;
        @memcpy(name_z[0..host_name.bytes.len], host_name.bytes);
        name_z[host_name.bytes.len] = 0;

        const hints: std.c.addrinfo = .{
            .flags = .{ .CANONNAME = options.canonical_name_buffer != null },
            .family = switch (options.family orelse .ip4) {
                .ip4 => if (options.family == null) std.c.AF.UNSPEC else std.c.AF.INET,
                .ip6 => std.c.AF.INET6,
            },
            .socktype = std.c.SOCK.STREAM,
            .protocol = 0,
            .addrlen = 0,
            .canonname = null,
            .addr = null,
            .next = null,
        };
        var res: ?*std.c.addrinfo = null;
        switch (std.c.getaddrinfo(name_z[0..host_name.bytes.len :0], null, &hints, &res)) {
            @as(std.c.EAI, @enumFromInt(0)) => {}, // bionic's EAI enum names no success value
            .AGAIN => return error.NameServerFailure,
            .NODATA => return error.NoAddressReturned,
            else => return error.UnknownHostName,
        }
        defer if (res) |r| std.c.freeaddrinfo(r);

        var any = false;
        var it = res;
        while (it) |ai| : (it = ai.next) {
            const sa = ai.addr orelse continue;
            switch (sa.family) {
                std.c.AF.INET => {
                    const sin: *align(1) const std.c.sockaddr.in = @ptrCast(sa);
                    try resolved.putOne(wrapped, .{ .address = .{ .ip4 = .{
                        .bytes = @bitCast(sin.addr),
                        .port = options.port,
                    } } });
                    any = true;
                },
                std.c.AF.INET6 => {
                    const sin6: *align(1) const std.c.sockaddr.in6 = @ptrCast(sa);
                    try resolved.putOne(wrapped, .{ .address = .{ .ip6 = .{
                        .port = options.port,
                        .bytes = sin6.addr,
                    } } });
                    any = true;
                },
                else => {},
            }
        }
        if (options.canonical_name_buffer) |buf| {
            // The resolver's canonical name when it offered one, the
            // queried name otherwise — a canon result is part of the
            // lookup contract once the caller supplied the buffer.
            const canon: []const u8 = blk: {
                if (res) |r| if (r.canonname) |cn| {
                    const s = std.mem.span(cn);
                    if (s.len <= buf.len) break :blk s;
                };
                break :blk host_name.bytes;
            };
            @memcpy(buf[0..canon.len], canon);
            try resolved.putOne(wrapped, .{ .canonical_name = .{ .bytes = buf[0..canon.len] } });
        }
        if (!any) return error.NoAddressReturned;
    }
};

// ---- iOS trust anchors ----
// iOS ships neither a PEM bundle under /etc/ssl nor the keychain that
// std's rescanMac reads, so Certificate.Bundle.rescan has no case for
// it — the `else => {}` leg — and every app starts with an empty trust
// store, which turns every https handshake into TlsInitializationFailed.
// The roots are on disk all the same: one DER file per anchor, in the
// asset the trust daemon itself reads. Loading them keeps iOS on the
// same footing as every other native platform (the OS's roots, not a
// bundled set of ours) and keeps one transport instead of two.
//
// Process-global, and — unlike the refcounted Io backend — never torn
// down: no per-app state lives here, the set is immutable once read
// and identical for every app, and freeing it on the last request
// would only re-read the same files on the next. No test binary takes
// this path, so nothing leak-checked ever sees it.
const is_ios = builtin.os.tag == .ios;

const ios_anchors = struct {
    // Apple's own asset layout, not a public API. If it ever moves, the
    // failure is the one we already have — an empty bundle — not a
    // crash, and `attempted` keeps it from costing a directory walk per
    // request.
    const dir_path = "/System/Library/Security/Certificates.bundle/Anchors";

    var mutex: std.Io.Mutex = .init;
    var attempted = false;
    var bundle: std.crypto.Certificate.Bundle = .empty;

    /// The shared bundle, read on the first https request of the
    /// process. Borrowed, never owned by the caller: `perform` puts the
    /// client's field back to empty before `deinit` so nothing frees it.
    fn shared(gpa: std.mem.Allocator) std.crypto.Certificate.Bundle {
        mutex.lockUncancelable(io);
        defer mutex.unlock(io);
        if (!attempted) {
            attempted = true;
            // An unreadable store leaves the bundle empty, which is
            // exactly the state this whole block exists to improve on —
            // a failure to load is not a failure to request.
            load(gpa) catch {};
        }
        return bundle;
    }

    fn load(gpa: std.mem.Allocator) !void {
        // An absolute path inside a simulator process resolves against
        // the *host's* filesystem, where this one either does not exist
        // or is a macOS-shaped bundle with a Contents/ wrapper. Apple's
        // own way into the guest system is this variable; honoring it is
        // what keeps the simulator from being the one iOS with no trust
        // store — the case a developer hits first.
        var path_buf: [std.fs.max_path_bytes]u8 = undefined;
        const path = if (std.c.getenv("IPHONE_SIMULATOR_ROOT")) |root|
            try std.fmt.bufPrint(&path_buf, "{s}{s}", .{ std.mem.span(root), dir_path })
        else
            dir_path;
        var dir = try std.Io.Dir.openDirAbsolute(io, path, .{ .iterate = true });
        defer dir.close(io);
        const now_sec = std.Io.Clock.real.now(io).toSeconds();
        var it = dir.iterate();
        while (try it.next(io)) |entry| {
            switch (entry.kind) {
                .file, .sym_link => {},
                else => continue,
            }
            // One anchor that will not read is one anchor short, not a
            // broken store: the rest still stand.
            addDer(gpa, dir, entry.name, now_sec) catch continue;
        }
    }

    /// The DER twin of Bundle.addCertsFromFile, which reads PEM only:
    /// append the file whole, then let `parseCert` index it.
    fn addDer(gpa: std.mem.Allocator, dir: std.Io.Dir, name: []const u8, now_sec: i64) !void {
        var file = try dir.openFile(io, name, .{});
        defer file.close(io);
        var file_reader = file.reader(io, &.{});
        const size = std.math.cast(u32, try file_reader.getSize()) orelse
            return error.CertificateTooBig;
        const start: u32 = @intCast(bundle.bytes.items.len);
        try bundle.bytes.ensureUnusedCapacity(gpa, size);
        const dest = bundle.bytes.allocatedSlice()[start..][0..size];
        const read = file_reader.interface.readSliceShort(dest) catch |e| switch (e) {
            error.ReadFailed => return file_reader.err.?,
        };
        bundle.bytes.items.len = start + read;
        // parseCert rewinds `bytes` itself on anything it will not take
        // (expired, duplicate, unrecognized object id), so a rejected
        // file leaves no partial anchor behind.
        try bundle.parseCert(gpa, start, now_sec);
    }
};

/// Everything that goes on the wire — owned copies, values not
/// references; the app's slices were borrowed only for the call.
/// Separate from the delivery half so `perform` can be driven with one
/// directly, which is what native_test.zig's loopback origin does.
pub const Wire = struct {
    method: std.http.Method,
    url: []const u8,
    headers: []std.http.Header,
    body: []const u8,
    max_body: u32,
};

/// A wire request plus its one delivery. Shared by the transfer thread
/// and the deadline watchdog, so ownership is a two-count refcount
/// (loopback.zig's bargain): whichever thread exits last frees the job.
const Job = struct {
    gpa: std.mem.Allocator,
    ticket: workers.Ticket,
    wire: Wire,
    /// One for the transfer thread, one for the watchdog.
    refs: std.atomic.Value(u32) = .init(2),
    /// Whether some side already owns the one delivery. The one-shot
    /// slot alone cannot arbitrate two racing producers — two replies
    /// could both pass the generation check before either retire frame
    /// lands — so the race is settled here, before anything enqueues.
    settled: std.atomic.Value(bool) = .init(false),

    /// Take the one delivery. The loser frees its own work and walks
    /// away — the cancel semantics, applied by the transport to
    /// itself.
    fn claim(self: *Job) bool {
        return self.settled.cmpxchgStrong(false, true, .acq_rel, .acquire) == null;
    }
};

fn unrefJob(job: *Job) void {
    if (job.refs.fetchSub(1, .release) != 1) return;
    _ = job.refs.load(.acquire);
    freeJob(job);
}

/// Copy the request and hand it to a fresh thread. UI thread only.
pub fn send(g: std.mem.Allocator, ticket: workers.Ticket, opts: http.RequestOptions) http.RequestError!void {
    // Two Io references and two runtime references — one per thread,
    // each released on that thread's way out. The runtime ones keep
    // the ticket's memory valid past any app shutdown: deliveries
    // after teardown are dropped, not dangling.
    _ = acquireIo(g);
    errdefer releaseIo();
    _ = acquireIo(g);
    errdefer releaseIo();
    ticket.runtime.ref();
    errdefer ticket.runtime.unref();
    ticket.runtime.ref();
    errdefer ticket.runtime.unref();
    const url = try g.dupe(u8, opts.url);
    errdefer g.free(url);
    const body = try g.dupe(u8, opts.body);
    errdefer g.free(body);
    const headers = try g.alloc(std.http.Header, opts.headers.len);
    errdefer g.free(headers);
    var copied: usize = 0;
    errdefer for (headers[0..copied]) |h| {
        g.free(h.name);
        g.free(h.value);
    };
    for (opts.headers, headers) |src, *dst| {
        const name = try g.dupe(u8, src.name);
        errdefer g.free(name);
        dst.* = .{ .name = name, .value = try g.dupe(u8, src.value) };
        copied += 1;
    }
    const job = try g.create(Job);
    errdefer g.destroy(job);
    job.* = .{
        .gpa = g,
        .ticket = ticket,
        .wire = .{
            .method = opts.method.asStd(),
            .url = url,
            .headers = headers,
            .body = body,
            .max_body = opts.max_body,
        },
    };
    // The transfer thread *is* the transport here, so a refused spawn
    // is a refused request. Every way `spawn` fails is resource
    // exhaustion at the OS edge — a thread quota, a locked-memory
    // limit — which a caller can only report, so the five std members
    // arrive as the one word the service's set has for it
    // (`http.RequestError`). The watchdog below is the opposite case
    // and says why.
    const thread = std.Thread.spawn(.{}, run, .{job}) catch return error.Unavailable;
    thread.detach();
    // From here the job is shared property and send may not fail: the
    // errdefers above would free what the transfer thread now owns.
    // If the watchdog cannot get its thread — a spawn succeeded three
    // lines up, so this is resource exhaustion at its edge — the
    // request proceeds without its deadline rather than dying on the
    // wire; the app still holds cancel.
    if (std.Thread.spawn(.{}, watchdog, .{job})) |wd| {
        wd.detach();
    } else |_| {
        releaseIo();
        ticket.runtime.unref();
        unrefJob(job);
    }
}

/// The deadline half: sleep it out, then claim the delivery if the
/// transfer has not. Sleeps on the awake clock — a machine asleep in a
/// drawer is not thirty seconds of a server not answering.
fn watchdog(job: *Job) void {
    // Same defer discipline as `run`: the runtime pointer is read
    // before the frees, the reference outlives every use of it, and
    // the Io reference outlives the sleep that needs the backend.
    const runtime = job.ticket.runtime;
    defer releaseIo();
    defer runtime.unref();
    const ticket = job.ticket;
    const g = job.gpa;
    io.sleep(.fromSeconds(http.deadline_seconds), .awake) catch {};
    if (job.claim()) {
        workers.deliverOneShot(http.Result, ticket, g, .{ .failure = .{ .name = "TimedOut" } }) catch {};
    }
    unrefJob(job);
}

fn freeJob(job: *Job) void {
    const g = job.gpa;
    g.free(job.wire.url);
    g.free(job.wire.body);
    for (job.wire.headers) |h| {
        g.free(h.name);
        g.free(h.value);
    }
    g.free(job.wire.headers);
    g.destroy(job);
}

fn run(job: *Job) void {
    // Read the runtime out of the ticket now, not from the defer:
    // defers run in reverse, so `unrefJob` may destroy the Job first,
    // and `job.ticket.runtime` would be a read of freed memory. The
    // reference must still outlive the free — it is what keeps the
    // runtime alive while this detached thread is winding down.
    const runtime = job.ticket.runtime;
    defer releaseIo();
    defer runtime.unref();
    defer unrefJob(job);
    var arena_state = std.heap.ArenaAllocator.init(job.gpa);
    defer arena_state.deinit();
    if (perform(job.gpa, job.wire, arena_state.allocator())) |response| {
        if (!job.claim()) {
            // The deadline got there first: the transfer finished on
            // its own clock, and its delivery is the one dropped.
            job.gpa.free(response.body.data);
            return;
        }
        workers.deliverOneShot(http.Result, job.ticket, job.gpa, .{ .response = response }) catch |e| {
            // Nothing moved on an encode failure — the body is still
            // this thread's to free.
            job.gpa.free(response.body.data);
            deliverFailure(job, @errorName(e));
        };
    } else |e| {
        if (!job.claim()) return;
        deliverFailure(job, switch (e) {
            error.StreamTooLong => "BodyTooLarge",
            else => @errorName(e),
        });
    }
}

fn deliverFailure(job: *Job, name: []const u8) void {
    workers.deliverOneShot(http.Result, job.ticket, job.gpa, .{ .failure = .{ .name = name } }) catch {};
}

/// One blocking transfer on the calling thread — `run`'s middle, and
/// the whole of what a test can drive against a real socket. The
/// caller holds an `acquireIo` reference: the client runs on the
/// module's refcounted backend.
pub fn perform(gpa: std.mem.Allocator, wire: Wire, arena: std.mem.Allocator) !http.Response {
    var client: std.http.Client = .{ .allocator = gpa, .io = io };
    // iOS lends the client the process-global anchor set: a non-null
    // `now` is what tells the client its bundle is already good (the
    // rescan that would clear it is gated on that field), and putting
    // the field back to empty before `deinit` is what keeps the client
    // from freeing memory it only borrowed. Every other platform lets
    // the client rescan for itself, unchanged.
    if (comptime is_ios) {
        client.ca_bundle = ios_anchors.shared(gpa);
        client.now = std.Io.Clock.real.now(io);
    }
    defer {
        if (comptime is_ios) client.ca_bundle = .empty;
        client.deinit();
    }

    const uri = try std.Uri.parse(wire.url);
    var req = try client.request(wire.method, uri, .{
        .extra_headers = wire.headers,
        // One request, one connection: nothing pools across a
        // detached thread's lifetime.
        .keep_alive = false,
    });
    defer req.deinit();

    // The send path is the method's, never the body's length: each
    // path asserts that the method agrees with it, so a POST whose
    // fields are all defaults still goes out as a body request with
    // `content-length: 0`, and a GET never takes that path at all.
    if (wire.method.requestHasBody()) {
        req.transfer_encoding = .{ .content_length = wire.body.len };
        var body_writer = try req.sendBodyUnflushed(&.{});
        try body_writer.writer.writeAll(wire.body);
        try body_writer.end();
        try req.connection.?.flush();
    } else {
        try req.sendBodiless();
    }

    var redirect_buffer: [8 * 1024]u8 = undefined;
    var response = try req.receiveHead(&redirect_buffer);

    // Copy the head before touching the body: the body reader
    // invalidates the head's strings.
    const status: u16 = @intFromEnum(response.head.status);
    const headers = try copyHeaders(arena, response.head.bytes);

    // Decompress like the browser does — both platforms hand the app
    // the decoded body, one outcome.
    const decompress_buffer: []u8 = switch (response.head.content_encoding) {
        .identity => &.{},
        .zstd => try arena.alloc(u8, std.compress.zstd.default_window_len),
        .deflate, .gzip => try arena.alloc(u8, std.compress.flate.max_window_len),
        .compress => return error.UnsupportedCompressionMethod,
    };
    var transfer_buffer: [64]u8 = undefined;
    var decompress: std.http.Decompress = undefined;
    const reader = response.readerDecompressing(&transfer_buffer, &decompress, decompress_buffer);

    // One past the cap so a body of exactly max_body is not rejected
    // at the limit boundary; the explicit check below is the contract.
    const body = try reader.allocRemaining(gpa, .limited(@as(usize, wire.max_body) + 1));
    if (body.len > wire.max_body) {
        gpa.free(body);
        return error.StreamTooLong;
    }
    return .{ .status = status, .headers = headers, .body = http.Bytes.adopt(body) };
}

fn copyHeaders(arena: std.mem.Allocator, head_bytes: []const u8) ![]http.Header {
    var count: usize = 0;
    var it = std.http.HeaderIterator.init(head_bytes);
    while (it.next()) |_| count += 1;
    const out = try arena.alloc(http.Header, count);
    it = std.http.HeaderIterator.init(head_bytes);
    for (out) |*h| {
        const src = it.next().?;
        h.* = .{
            .name = try arena.dupe(u8, src.name),
            .value = try arena.dupe(u8, src.value),
        };
    }
    return out;
}
