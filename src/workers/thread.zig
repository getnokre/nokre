//! The native transport: one std.Thread per worker — a thread you can
//! see, not a pool you tune (docs/internals/workers.md). The thread
//! parks on a condition variable between messages, so a worker at rest
//! costs zero CPU; retirement drains the inbox, runs deinit, and posts
//! a retired frame the UI-thread pump uses to join and free.
//!
//! The worker allocates from the app's gpa, from its own thread — the
//! std allocators are thread-safe unless the build is single-threaded.
//! Zig's blocking primitives want an `std.Io`; one Threaded backend
//! serves every worker's futex needs. It is deliberately process-level
//! (a documented exemption from the state-lives-on-the-App rule): two
//! apps' workers share futexes fine, and the mutex + refcount below
//! keep creation and teardown safe when two apps run on two threads.

const std = @import("std");
const workers = @import("workers.zig");

// A CAS spin-guard, not std.Io.Mutex — the io instance is what this
// lock creates, and 0.16 keeps no blocking mutex outside std.Io. The
// section is a few instructions; contention needs two apps racing
// their first spawn from two threads.
var io_lock: std.atomic.Value(bool) = .init(false);
var io_backend: ?std.Io.Threaded = null;
var io_shared: std.Io = undefined;
var io_refs: usize = 0;

fn lockIo() void {
    while (io_lock.cmpxchgWeak(false, true, .acquire, .monotonic) != null) {
        std.atomic.spinLoopHint();
    }
}

fn unlockIo() void {
    io_lock.store(false, .release);
}

/// Each ThreadWorker holds one reference for its lifetime; the first
/// acquire creates the backend, the last release tears it down — so a
/// leak-checked test binary ends clean without a process atexit.
fn acquireIo(gpa: std.mem.Allocator) std.Io {
    lockIo();
    defer unlockIo();
    if (io_backend == null) {
        io_backend = std.Io.Threaded.init(gpa, .{});
        io_shared = io_backend.?.io();
    }
    io_refs += 1;
    return io_shared;
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

pub const ThreadWorker = struct {
    gpa: std.mem.Allocator,
    runtime: *workers.Runtime,
    io: std.Io,
    vt: *const workers.Vt,
    index: u32,
    gen: u32,
    mutex: std.Io.Mutex = .init,
    cond: std.Io.Condition = .init,
    inbox: std.ArrayList(workers.Frame) = .empty,
    retire: bool = false,
    thread: std.Thread = undefined,
};

pub fn spawn(gpa: std.mem.Allocator, rt: *workers.Runtime, vt: *const workers.Vt, index: u32, gen: u32) !*ThreadWorker {
    const io = acquireIo(gpa);
    errdefer releaseIo();
    const w = try gpa.create(ThreadWorker);
    errdefer gpa.destroy(w);
    w.* = .{ .gpa = gpa, .runtime = rt, .io = io, .vt = vt, .index = index, .gen = gen };
    w.thread = try std.Thread.spawn(.{}, main, .{w});
    return w;
}

/// Takes ownership of `frame` on success (attachment pointers move
/// across the thread here — the zero-copy handoff); on error frees
/// nothing, so the sender's `Bytes` stay the caller's. UI thread only.
pub fn enqueue(w: *ThreadWorker, frame: workers.Frame) !void {
    w.mutex.lockUncancelable(w.io);
    defer w.mutex.unlock(w.io);
    try w.inbox.append(w.gpa, frame);
    w.cond.signal(w.io);
}

pub fn requestRetire(w: *ThreadWorker) void {
    w.mutex.lockUncancelable(w.io);
    defer w.mutex.unlock(w.io);
    w.retire = true;
    w.cond.signal(w.io);
}

/// The thread has posted its retired (or died) frame — it is exiting or
/// gone. Join and free.
pub fn join(w: *ThreadWorker, gpa: std.mem.Allocator) void {
    w.thread.join();
    for (w.inbox.items) |f| f.free(w.gpa);
    w.inbox.deinit(w.gpa);
    releaseIo();
    gpa.destroy(w);
}

fn main(w: *ThreadWorker) void {
    const inst = w.vt.create(w.gpa) catch {
        w.runtime.enqueueDelivery(w.index, w.gen, &[1]u8{workers.died_frame});
        return;
    };
    while (nextFrame(w)) |frame| {
        defer frame.free(w.gpa);
        if (frame.bytes.len == 0 or frame.bytes[0] != workers.msg_frame) continue;
        var arena_state = std.heap.ArenaAllocator.init(w.gpa);
        defer arena_state.deinit();
        var raw: workers.RawOutbox = .{
            .arena = arena_state.allocator(),
            .ctx = w,
            .send_fn = sendReply,
            .interrupted_fn = isInterrupted,
            // w.gpa IS the runtime's gpa (spawn hands the app's
            // allocator to both sides), so the moved frame's free
            // matches.
            .gpa = w.gpa,
            .send_owned_fn = sendReplyOwned,
        };
        w.vt.handle(inst, frame.bytes[1..], frame.attachments, &raw) catch |e| postFault(w, e);
    }
    w.vt.destroy(inst, w.gpa);
    w.runtime.enqueueDelivery(w.index, w.gen, &[1]u8{workers.retired_frame});
}

/// Blocks until a message or retirement. Retirement drains first: what
/// was sent before it still runs, exactly once, in order.
fn nextFrame(w: *ThreadWorker) ?workers.Frame {
    w.mutex.lockUncancelable(w.io);
    defer w.mutex.unlock(w.io);
    while (w.inbox.items.len == 0 and !w.retire) w.cond.waitUncancelable(w.io, &w.mutex);
    if (w.inbox.items.len > 0) return w.inbox.orderedRemove(0);
    return null;
}

fn sendReply(ctx: ?*anyopaque, frame: []const u8) anyerror!void {
    const w: *ThreadWorker = @ptrCast(@alignCast(ctx.?));
    w.runtime.enqueueDelivery(w.index, w.gen, frame);
}

fn sendReplyOwned(ctx: ?*anyopaque, frame: workers.Frame) void {
    const w: *ThreadWorker = @ptrCast(@alignCast(ctx.?));
    w.runtime.enqueueDeliveryOwned(w.index, w.gen, frame);
}

fn isInterrupted(ctx: ?*anyopaque) bool {
    const w: *ThreadWorker = @ptrCast(@alignCast(ctx.?));
    w.mutex.lockUncancelable(w.io);
    defer w.mutex.unlock(w.io);
    return w.inbox.items.len > 0 or w.retire;
}

fn postFault(w: *ThreadWorker, e: anyerror) void {
    var buf: [1 + 64]u8 = undefined;
    const name = @errorName(e);
    const n = @min(name.len, buf.len - 1);
    buf[0] = workers.fault_frame;
    @memcpy(buf[1 .. 1 + n], name[0..n]);
    w.runtime.enqueueDelivery(w.index, w.gen, buf[0 .. 1 + n]);
}
