//! The web transport: the browser is the HTTP client. `send` ferries
//! the request out through the nokre_http_js_* imports (implemented in
//! render/dom/services.js, where fetch runs on the main thread beside
//! the wasm instance).
//! The response lands back through the scratch + deliver exports in
//! render/dom/live.zig: the same three beats as a worker reply —
//! ask wasm for a buffer, copy in, call the export — then the shared
//! delivery queue and an inline pump, exactly deliverFromPost's shape.

const std = @import("std");
const workers = @import("../../workers/workers.zig");
const http = @import("http.zig");

// Implemented by render/dom/services.js on the import object.
extern fn nokre_http_js_send(index: u32, gen: u32, method_ptr: [*]const u8, method_len: usize, url_ptr: [*]const u8, url_len: usize, headers_ptr: [*]const u8, headers_len: usize, body_ptr: [*]const u8, body_len: usize, max_body: u32) void;
extern fn nokre_http_js_cancel(index: u32, gen: u32) void;

// Single-app by platform fact (the wasm instance is one app), so the
// landing side keys off these instead of per-request plumbing — the
// documented exemption from the state-lives-on-the-App rule.
var gpa: ?std.mem.Allocator = null;
var runtime: ?*workers.Runtime = null;

/// Hand the request to fetch. JS copies every slice synchronously
/// inside the call (services.js slices, never views), so the borrows
/// end when this returns — the same contract as a worker send.
pub fn send(g: std.mem.Allocator, ticket: workers.Ticket, opts: http.RequestOptions) !void {
    gpa = g;
    runtime = ticket.runtime;
    // Headers flatten as name\nvalue\n… — a '\n' in either would move
    // the frame boundaries and smuggle one header into another, so it is
    // asserted away here, the same invariant std.http.Client asserts on
    // the native leg.
    var flat: std.ArrayList(u8) = .empty;
    defer flat.deinit(g);
    for (opts.headers) |h| {
        std.debug.assert(std.mem.indexOfScalar(u8, h.name, '\n') == null);
        std.debug.assert(std.mem.indexOfScalar(u8, h.value, '\n') == null);
        try flat.appendSlice(g, h.name);
        try flat.append(g, '\n');
        try flat.appendSlice(g, h.value);
        try flat.append(g, '\n');
    }
    const method = @tagName(opts.method);
    nokre_http_js_send(
        ticket.index,
        ticket.gen,
        method.ptr,
        method.len,
        opts.url.ptr,
        opts.url.len,
        flat.items.ptr,
        flat.items.len,
        opts.body.ptr,
        opts.body.len,
        opts.max_body,
    );
}

/// Abort the browser-side fetch. The rejection this triggers lands
/// after the ticket is already cancelled, so nothing is delivered —
/// the abort is a courtesy to the network, not the correctness story.
pub fn cancel(ticket: workers.Ticket) void {
    nokre_http_js_cancel(ticket.index, ticket.gen);
}

// ---- the landing side (called from render/dom/live.zig exports) ----

var scratch: std.ArrayList(u8) = .empty;

/// JS never allocates in the wasm heap: it asks for a buffer, writes
/// [headers block][body] (or a failure name), and calls deliver/fail
/// with the split. Reused across responses, like nokre_worker_scratch.
pub fn scratchAlloc(len: usize) ?[*]u8 {
    const g = gpa orelse return null;
    scratch.resize(g, len) catch return null;
    return scratch.items.ptr;
}

pub fn deliver(index: u32, gen: u32, status: u16, headers_len: usize, body_len: usize) void {
    const g = gpa orelse return;
    const rt = runtime orelse return;
    if (headers_len + body_len > scratch.items.len) return; // never our ferry's
    const ticket: workers.Ticket = .{ .runtime = rt, .index = index, .gen = gen };
    const headers_block = scratch.items[0..headers_len];
    const body = scratch.items[headers_len..][0..body_len];

    var arena_state = std.heap.ArenaAllocator.init(g);
    defer arena_state.deinit();
    const headers = parseHeaders(arena_state.allocator(), headers_block) catch {
        failTicket(ticket, "OutOfMemory");
        return;
    };
    const buf = g.dupe(u8, body) catch {
        failTicket(ticket, "OutOfMemory");
        return;
    };
    workers.deliverOneShot(http.Result, ticket, g, .{ .response = .{
        .status = status,
        .headers = headers,
        .body = http.Bytes.adopt(buf),
    } }) catch g.free(buf);
    _ = rt.pump();
}

pub fn fail(index: u32, gen: u32, name_len: usize) void {
    const rt = runtime orelse return;
    if (name_len > scratch.items.len) return;
    failTicket(.{ .runtime = rt, .index = index, .gen = gen }, scratch.items[0..name_len]);
}

fn failTicket(ticket: workers.Ticket, name: []const u8) void {
    const g = gpa orelse return;
    workers.deliverOneShot(http.Result, ticket, g, .{ .failure = .{ .name = name } }) catch {};
    _ = ticket.runtime.pump();
}

fn parseHeaders(arena: std.mem.Allocator, block: []const u8) ![]http.Header {
    const lines = std.mem.count(u8, block, "\n");
    const out = try arena.alloc(http.Header, lines / 2);
    var it = std.mem.splitScalar(u8, block, '\n');
    for (out) |*h| {
        h.* = .{ .name = it.next().?, .value = it.next().? };
    }
    return out;
}
