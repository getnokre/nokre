//! The http service — one client API on every platform
//! (docs/services.md; internals in docs/internals/http.md). A request
//! leaves from any action; exactly one `Result` returns on the UI
//! thread, between events — a worker reply in shape, riding the same
//! delivery queue through a one-shot slot. Behind the comptime split
//! the shells wire it very differently — native blocks one visible
//! thread per request on std.http.Client, the web hands the job to the
//! browser's fetch, tests park the request in the app's mock until the
//! test supplies the response — and the consumer contract is identical
//! everywhere: no futures, no locks, no callback off the UI thread.

const std = @import("std");
const builtin = @import("builtin");
const app_mod = @import("../../core/app.zig");
const workers = @import("../../workers/workers.zig");

const App = app_mod.App;
const is_wasm = builtin.cpu.arch == .wasm32;

const native_transport = if (is_wasm) struct {} else @import("native.zig");
const fetch_transport = if (is_wasm) @import("web.zig") else struct {};

/// Response bodies are transferable blobs (workers.Bytes): `view()`
/// reads for the callback, `take()` keeps the buffer past it.
pub const Bytes = workers.Bytes;

/// The closed verb set. OPTIONS, TRACE, and CONNECT are protocol
/// plumbing — the browser issues its own preflights and no app-level
/// semantic needs them; the set stays closed the way the element set
/// does.
pub const Method = enum { GET, HEAD, POST, PUT, PATCH, DELETE };

pub const Header = struct { name: []const u8, value: []const u8 };

/// An HTTP response, delivered whole once the body has fully arrived.
/// Slices are valid only for the callback; the body is a `Bytes` —
/// `take()` it to keep the buffer. Status codes are data: a 404 lands
/// here, not in `Failure`.
pub const Response = struct {
    status: u16,
    /// As the transport reports them: verbatim natively, normalized to
    /// lowercase by fetch on the web — where, cross-origin, only
    /// CORS-exposed headers appear at all. A stated weaker posture,
    /// like secure_store's (docs/services.md).
    headers: []const Header,
    body: Bytes,
};

/// A transport failure: the request never became a response. The name
/// is a Zig error name natively ("ConnectionRefused",
/// "UnknownHostName"); on the web it is "FetchFailed" for everything
/// the browser deliberately hides, plus "BodyTooLarge" on both.
pub const Failure = struct { name: []const u8 };

/// What `on_result` receives — exactly once per request, in completion
/// order across requests.
pub const Result = union(enum) {
    response: Response,
    failure: Failure,
};

/// The fixed transport deadline: a request that has not produced its
/// `Result` within this many seconds fails like any other transport
/// failure — "TimedOut" natively, the web's one name "FetchFailed".
/// A constant, not a knob, for the reason `max_body` has a cap rather
/// than a setting: a deadline is transport policy, not an app
/// decision — and without one, a hung server composes with an
/// `in_progress` control (docs/elements.md) into a UI state that can
/// never recover, because nothing auto-clears and the failure path
/// never runs. Deliberately not honored by the mock: parked requests
/// stay parked until the test answers, so time never becomes a hidden
/// test input.
pub const deadline_seconds: u32 = 30;

pub const RequestOptions = struct {
    app: *App,
    url: []const u8,
    method: Method = .GET,
    /// Borrowed only for the `request` call, like every message: the
    /// transport copies before returning.
    headers: []const Header = &.{},
    body: []const u8 = &.{},
    /// A response body larger than this is the failure "BodyTooLarge":
    /// a rogue server must not be able to balloon the app's memory,
    /// and on wasm the heap it would balloon is the UI's own.
    max_body: u32 = 16 * 1024 * 1024,
    ctx: ?*anyopaque = null,
    on_result: *const fn (ctx: ?*anyopaque, result: Result) void,
};

/// Generation-checked, like a worker handle: after the result (or a
/// cancel) it is spent and every use is a no-op — never a dangling
/// pointer.
pub const Handle = struct {
    ticket: workers.Ticket,
    /// Which app's mock parked the request — cancel must unpark it
    /// there. Comptime-cut: release builds carry nothing.
    mock: if (builtin.is_test) *MockState else void = if (builtin.is_test) undefined else {},

    /// `on_result` will never run after this. The wire transfer may
    /// still finish where the platform cannot abort it (a native
    /// socket mid-read; the web aborts for real) — its delivery is
    /// dropped by the generation check. UI thread only, idempotent.
    pub fn cancel(self: @This()) void {
        if (comptime builtin.is_test) self.mock.drop(self.ticket);
        if (comptime is_wasm) fetch_transport.cancel(self.ticket);
        workers.cancelOneShot(self.ticket);
    }
};

/// Issue a request. Everything in `opts` is copied at the call; the
/// result arrives on the UI thread, between events, exactly once.
/// Under `zig test` the request parks in the app's mock and the test
/// supplies the response — the network becomes a test input
/// (docs/testing.md).
pub fn request(opts: RequestOptions) !Handle {
    const ticket = try workers.openOneShot(Result, opts.app, opts.ctx, opts.on_result);
    errdefer workers.cancelOneShot(ticket);
    if (comptime builtin.is_test) {
        const state = opts.app.services.http.state.?;
        try state.park(ticket, opts);
        return .{ .ticket = ticket, .mock = state };
    } else if (comptime is_wasm) {
        try fetch_transport.send(opts.app.gpa, ticket, opts);
        return .{ .ticket = ticket };
    } else {
        try native_transport.send(opts.app.gpa, ticket, opts);
        return .{ .ticket = ticket };
    }
}

/// What the App carries for this service: the mock under `zig test`,
/// the (stateless) platform transports in release — the comptime split
/// that keeps injection type-closed.
pub const Service = if (builtin.is_test) Mock else PlatformService;

const PlatformService = struct {
    /// The transports keep no per-app state: native detaches one
    /// thread per request, the web hands the job to fetch. Nothing to
    /// allocate, nothing to tear down.
    pub fn init(self: *PlatformService, gpa: std.mem.Allocator, runtime: *workers.Runtime) !void {
        _ = self;
        _ = gpa;
        _ = runtime;
    }
    pub fn deinit(self: *PlatformService) void {
        _ = self;
    }
};

// ---- the mock ----
// nokre's canonical fake network, one per app: requests park here,
// oldest first, and nothing moves until the test answers — so the test
// *is* the interleaving, the same bargain as inline workers. The test
// either answers by hand (fulfill/fail, by index for out-of-order
// completion) or installs a handler — its fake server — and settles.
// Either way every ask lands in the journal, which outlives the answer.

/// A parked request: owned copies of what the app sent.
pub const PendingRequest = struct {
    ticket: workers.Ticket,
    method: Method,
    url: []const u8,
    headers: []const Header,
    body: []const u8,
    max_body: u32,
};

/// One journaled request: what the app asked, as owned copies that
/// survive the answer. `pending` empties as the test fulfills — the
/// journal is what keeps "these requests, in this order" assertable
/// after the answers land, the same register every journaling mock
/// keeps (secure_store's ops, iap's queries).
pub const Op = struct { method: Method, url: []const u8 };

pub const CannedResponse = struct {
    status: u16 = 200,
    headers: []const Header = &.{},
    body: []const u8 = "",
};

/// What a handler decides for one parked request: a canned response, a
/// transport failure, or null — leave it parked for the test to answer
/// by hand.
pub const Outcome = union(enum) {
    respond: CannedResponse,
    fail: []const u8,
};

/// A test's fake server: consulted by `settle` for each parked
/// request, oldest first. A function, not a route table, so it can
/// also assert on method, headers, and body — and a table is three
/// lines of switch when that's all a test needs.
pub const Handler = *const fn (ctx: ?*anyopaque, req: PendingRequest) ?Outcome;

/// The mock's heap half, allocated by App.init so its address survives
/// the by-value moves a stack App makes (handles point back here).
pub const MockState = struct {
    gpa: std.mem.Allocator,
    runtime: *workers.Runtime,
    pending: std.ArrayList(PendingRequest) = .empty,
    ops: std.ArrayList(Op) = .empty,
    handler: ?Handler = null,
    handler_ctx: ?*anyopaque = null,

    fn park(self: *MockState, ticket: workers.Ticket, opts: RequestOptions) !void {
        const g = self.gpa;
        // The journal entry and the parked request commit together:
        // capacity is reserved up front so a request the app saw fail
        // is never half-recorded.
        const journal_url = try g.dupe(u8, opts.url);
        errdefer g.free(journal_url);
        try self.ops.ensureUnusedCapacity(g, 1);
        const url = try g.dupe(u8, opts.url);
        errdefer g.free(url);
        const body = try g.dupe(u8, opts.body);
        errdefer g.free(body);
        const headers = try g.alloc(Header, opts.headers.len);
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
        try self.pending.append(g, .{
            .ticket = ticket,
            .method = opts.method,
            .url = url,
            .headers = headers,
            .body = body,
            .max_body = opts.max_body,
        });
        self.ops.appendAssumeCapacity(.{ .method = opts.method, .url = journal_url });
    }

    fn freePending(self: *MockState, p: PendingRequest) void {
        const g = self.gpa;
        g.free(p.url);
        g.free(p.body);
        for (p.headers) |h| {
            g.free(h.name);
            g.free(h.value);
        }
        g.free(p.headers);
    }

    fn drop(self: *MockState, ticket: workers.Ticket) void {
        for (self.pending.items, 0..) |p, i| {
            if (p.ticket.index == ticket.index and p.ticket.gen == ticket.gen) {
                self.freePending(self.pending.orderedRemove(i));
                return;
            }
        }
    }
};

/// One app's fake network. Constructed into `.services` (`.mock(.{})`,
/// or with a handler — the fake server defined where the app is);
/// App.init allocates the state, App.deinit frees it, and parked
/// requests die with their app — nothing leaks to the next test.
pub const Mock = struct {
    /// Construction-time config, applied to the state at App.init.
    boot_handler: ?Handler = null,
    boot_handler_ctx: ?*anyopaque = null,
    /// The heap half; null only before App.init.
    state: ?*MockState = null,

    pub const Config = struct {
        /// The app's fake server, from the first request on. Tests
        /// that answer by hand leave it null.
        handler: ?Handler = null,
        ctx: ?*anyopaque = null,
    };

    pub fn mock(config: Config) Mock {
        return .{ .boot_handler = config.handler, .boot_handler_ctx = config.ctx };
    }

    pub fn init(self: *Mock, gpa: std.mem.Allocator, runtime: *workers.Runtime) !void {
        const state = try gpa.create(MockState);
        state.* = .{
            .gpa = gpa,
            .runtime = runtime,
            .handler = self.boot_handler,
            .handler_ctx = self.boot_handler_ctx,
        };
        self.state = state;
    }

    pub fn deinit(self: *Mock) void {
        const state = self.state orelse return;
        for (state.pending.items) |p| state.freePending(p);
        state.pending.deinit(state.gpa);
        for (state.ops.items) |op| state.gpa.free(op.url);
        state.ops.deinit(state.gpa);
        state.gpa.destroy(state);
        self.state = null;
    }

    // ---- the deterministic test surface (docs/testing.md) ----
    // Pure queue: fulfill/fail enqueue the delivery; the app runtime's
    // pumpAll — or the harness's fulfillHttp/failHttp, which add the
    // pump and the audit — lands it.

    pub fn pendingCount(self: Mock) usize {
        return self.state.?.pending.items.len;
    }

    /// Borrowed view of the i-th parked request, oldest first — for
    /// asserting what the app actually sent.
    pub fn pendingAt(self: Mock, i: usize) PendingRequest {
        return self.state.?.pending.items[i];
    }

    /// Every request the app issued, in request order — including the
    /// fulfilled, failed, and cancelled ones `pending` no longer
    /// holds. Request order on purpose: the journal records asks; the
    /// answer interleaving is the test's own doing (guarantee 2).
    pub fn journal(self: Mock) []const Op {
        return self.state.?.ops.items;
    }

    /// Drop the journal — the per-phase reset, so a test can assert
    /// "and *that* action issued exactly these" without arithmetic
    /// over everything before it.
    pub fn clearJournal(self: Mock) void {
        const state = self.state.?;
        for (state.ops.items) |op| state.gpa.free(op.url);
        state.ops.clearRetainingCapacity();
    }

    /// Answer the oldest parked request. Honors max_body the way the
    /// real transports do: an oversized canned body is "BodyTooLarge".
    pub fn fulfill(self: Mock, canned: CannedResponse) !void {
        return self.fulfillAt(0, canned);
    }

    /// Answer the i-th parked request, oldest first. Answering out of
    /// order is the point: guarantee 2 (completion order, not request
    /// order) says the delivery interleaving is the test's — response
    /// B landing before response A is how the stale-response race is
    /// written down.
    pub fn fulfillAt(self: Mock, i: usize, canned: CannedResponse) !void {
        const state = self.state.?;
        if (i >= state.pending.items.len) return error.NoPendingRequest;
        const g = state.gpa;
        const p = state.pending.orderedRemove(i);
        defer state.freePending(p);
        if (canned.body.len > p.max_body) {
            try workers.deliverOneShot(Result, p.ticket, g, .{ .failure = .{ .name = "BodyTooLarge" } });
            return;
        }
        const buf = try g.dupe(u8, canned.body);
        errdefer g.free(buf);
        try workers.deliverOneShot(Result, p.ticket, g, .{ .response = .{
            .status = canned.status,
            .headers = canned.headers,
            .body = Bytes.adopt(buf),
        } });
    }

    /// Fail the oldest parked request with a transport failure name.
    pub fn fail(self: Mock, name: []const u8) !void {
        return self.failAt(0, name);
    }

    /// Fail the i-th parked request, oldest first — fulfillAt's twin.
    pub fn failAt(self: Mock, i: usize, name: []const u8) !void {
        const state = self.state.?;
        if (i >= state.pending.items.len) return error.NoPendingRequest;
        const p = state.pending.orderedRemove(i);
        defer state.freePending(p);
        try workers.deliverOneShot(Result, p.ticket, state.gpa, .{ .failure = .{ .name = name } });
    }

    /// Install (or replace) the fake server after construction — the
    /// harness's onHttp lands here.
    pub fn setHandler(self: Mock, ctx: ?*anyopaque, handler: Handler) void {
        const state = self.state.?;
        state.handler = handler;
        state.handler_ctx = ctx;
    }

    /// Run the handler over the parked requests, oldest first, landing
    /// each answer before the next ask — a callback may issue follow-up
    /// requests and the handler sees those too, to quiescence.
    /// Requests the handler declines (null) stay parked, the test's to
    /// answer by hand. Refuses to settle without a handler.
    pub fn settle(self: Mock) !void {
        const state = self.state.?;
        const handler = state.handler orelse return error.NoHttpHandler;
        outer: while (true) {
            var i: usize = 0;
            while (i < state.pending.items.len) : (i += 1) {
                const p = state.pending.items[i];
                const outcome = handler(state.handler_ctx, p) orelse continue;
                switch (outcome) {
                    .respond => |canned| try self.fulfillAt(i, canned),
                    .fail => |name| try self.failAt(i, name),
                }
                // The delivery may park new requests; rescan from the
                // oldest so the handler sees them this same settle.
                state.runtime.pumpAll();
                continue :outer;
            }
            break;
        }
    }
};
