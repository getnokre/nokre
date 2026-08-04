//! The web transport: same artifact, another Worker
//! (docs/internals/workers.md). The app's wasm instance ferries frames
//! out through the nokre_worker_js_* imports (render/dom/services.js,
//! which spawns a Worker running live-worker.js); that Worker
//! instantiates the very same module and boots via `nokre_worker_boot`
//! with a registry index, and this file is both sides of that
//! conversation. JS carries buffers verbatim; every frame byte is
//! decided in Zig.

const std = @import("std");
const workers = @import("workers.zig");

// App-instance side (imports implemented by services.js).
extern fn nokre_worker_js_spawn(index: u32, slot: u32) void;
extern fn nokre_worker_js_send(slot: u32, ptr: [*]const u8, len: usize) void;
extern fn nokre_worker_js_drop(slot: u32) void;
// Compute-instance side.
extern fn nokre_worker_js_reply(ptr: [*]const u8, len: usize) void;
extern fn nokre_worker_js_pending() i32;
extern fn nokre_worker_js_close() void;

pub fn spawn(registry_index: u32, slot: u32) void {
    nokre_worker_js_spawn(registry_index, slot);
}

pub fn send(slot: u32, frame: []const u8) void {
    nokre_worker_js_send(slot, frame.ptr, frame.len);
}

pub fn drop(slot: u32) void {
    nokre_worker_js_drop(slot);
}

// ---- the compute-worker role ----
// One worker per instance: module state, like the shell's own globals.

var role_vt: ?*const workers.Vt = null;
var role_inst: *anyopaque = undefined;
var role_gpa: std.mem.Allocator = undefined;

/// Boot as worker `index` of the root registry. The registry is
/// comptime; the index arrived over the wire, so the dispatch is an
/// unrolled comparison chain.
pub fn bootWorker(gpa: std.mem.Allocator, index: u32) bool {
    const root = @import("root");
    if (comptime !@hasDecl(root, "nokreWorkers")) {
        // Compile-check builds and apps without a registry.
        return false;
    } else {
        inline for (root.nokreWorkers, 0..) |W, i| {
            if (index == i) {
                const vt = comptime workers.vtFor(W);
                role_inst = vt.create(gpa) catch return false;
                role_vt = vt;
                role_gpa = gpa;
                return true;
            }
        }
        return false;
    }
}

pub fn handleFrame(frame: []const u8) void {
    const vt = role_vt orelse return;
    if (frame.len == 0) return;
    switch (frame[0]) {
        workers.msg_frame => handleMsg(vt, .{ .bytes = @constCast(frame) }, false),
        workers.msg_attach_frame => {
            // Blobs land by copy out of the transport scratch — the web
            // floor — so their receive-side ownership matches native.
            const owned = workers.frameFromEnvelope(role_gpa, workers.msg_frame, frame) orelse return;
            handleMsg(vt, owned, true);
        },
        workers.retire_frame => {
            vt.destroy(role_inst, role_gpa);
            role_vt = null;
            nokre_worker_js_reply(&[1]u8{workers.retired_frame}, 1);
            nokre_worker_js_close();
        },
        else => {},
    }
}

/// `owned` says whether `frame` is ours to free (the envelope path) or
/// a borrow of the scratch (the plain path — no attachments, and the
/// @constCast above is never written through).
fn handleMsg(vt: *const workers.Vt, frame: workers.Frame, owned: bool) void {
    defer if (owned) frame.free(role_gpa);
    var arena_state = std.heap.ArenaAllocator.init(role_gpa);
    defer arena_state.deinit();
    var raw: workers.RawOutbox = .{
        .arena = arena_state.allocator(),
        .ctx = null,
        .send_fn = roleSend,
        .interrupted_fn = roleInterrupted,
        .gpa = role_gpa,
    };
    vt.handle(role_inst, frame.bytes[1..], frame.attachments, &raw) catch |e| roleFault(e);
}

fn roleSend(_: ?*anyopaque, frame: []const u8) anyerror!void {
    nokre_worker_js_reply(frame.ptr, frame.len);
}

/// Best-effort by physics: a synchronous wasm frame blocks this
/// Worker's event loop, so arrivals mid-`handle` become visible only at
/// the next message boundary — live-worker.js queues a burst behind a
/// self-posted drain task precisely so this count sees it.
fn roleInterrupted(_: ?*anyopaque) bool {
    return nokre_worker_js_pending() > 0;
}

fn roleFault(e: anyerror) void {
    var buf: workers.FaultBuf = undefined;
    const frame = workers.faultFrame(&buf, e);
    nokre_worker_js_reply(frame.ptr, frame.len);
}
