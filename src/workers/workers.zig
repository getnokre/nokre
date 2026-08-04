//! Workers — long-lived compute actors off the UI thread. The contract
//! is docs/internals/workers.md; this module is its pure heart: worker
//! validation, the registry, framing, queues, the ask FIFO, and
//! UI-thread delivery.
//! Threads live in thread.zig (native), the Web Worker hop in post.zig
//! (wasm) — and tests run the inline transport in this file: the same
//! init/handle/deinit, no threads, delivery on an explicit pump, so a
//! test chooses exactly when async work lands.
//!
//! App code never takes a lock and never runs off the UI thread: `send`
//! copies, `handle` runs alone against its own state, and every
//! `on_reply` fires here, on the thread that owns the App. The one
//! cross-thread structure is the delivery queue below — a lock-free
//! push stack the UI thread drains in FIFO order; everything else is
//! confined by construction.

const std = @import("std");
const builtin = @import("builtin");
const app_mod = @import("../core/app.zig");
const codec = @import("codec.zig");

const App = app_mod.App;
const is_wasm = builtin.cpu.arch == .wasm32;

const thread_transport = if (is_wasm) struct {} else @import("thread.zig");
const post_transport = if (is_wasm) @import("post.zig") else struct {};
const ThreadPtr = if (is_wasm) void else *thread_transport.ThreadWorker;

// Frames are one kind byte + payload; the transports ferry them
// verbatim, so all meaning stays in this module (and JS stays dumb).
// app → worker:
pub const msg_frame: u8 = 0;
pub const retire_frame: u8 = 1;
pub const msg_attach_frame: u8 = 2; // web envelope: msg + attachments
// worker → app:
pub const reply_frame: u8 = 0;
pub const fault_frame: u8 = 1; // payload: error name bytes
pub const retired_frame: u8 = 2;
pub const died_frame: u8 = 3;
pub const reply_attach_frame: u8 = 4; // web envelope: reply + attachments

/// A fault's error name is truncated to this on the wire: a name is a
/// symbol, not a message, and 64 bytes outlasts any Zig identifier a
/// handler would switch on.
pub const max_fault_name = 64;
pub const FaultBuf = [1 + max_fault_name]u8;

/// Encode a fault frame — the one encoding all three transports send,
/// so the truncation rule cannot drift between them.
pub fn faultFrame(buf: *FaultBuf, e: anyerror) []const u8 {
    const name = @errorName(e);
    const n = @min(name.len, max_fault_name);
    buf[0] = fault_frame;
    @memcpy(buf[1 .. 1 + n], name[0..n]);
    return buf[0 .. 1 + n];
}

/// The transferable blob — see codec.Bytes for the whole contract.
pub const Bytes = codec.Bytes;

/// What actually moves through a transport: the encoded bytes plus the
/// out-of-band `Bytes` buffers, in encode order. On native the
/// attachment pointers move whole — the zero-copy handoff; a null
/// entry is a blob a handler kept via `take`.
pub const Frame = struct {
    bytes: []u8,
    attachments: []?[]u8 = &.{},

    pub fn free(self: Frame, g: std.mem.Allocator) void {
        g.free(self.bytes);
        for (self.attachments) |a| if (a) |buf| g.free(buf);
        if (self.attachments.len > 0) g.free(self.attachments);
    }
};

/// Failure delivered as a message, never an exception across threads.
pub const Fault = union(enum) {
    /// `handle` returned this error; the message was dropped, the
    /// worker lives on.
    err: []const u8,
    /// The worker died (init failed, or a web trap/OOM); the handle is
    /// retired.
    died,
};

// ---- worker-side surface ----

/// The type-erased sink a transport hands to `handle`; consumers see
/// only the typed `Outbox` below.
pub const RawOutbox = struct {
    arena: std.mem.Allocator,
    ctx: ?*anyopaque,
    send_fn: *const fn (ctx: ?*anyopaque, frame: []const u8) anyerror!void,
    interrupted_fn: *const fn (ctx: ?*anyopaque) bool,
    /// The worker instance's own allocator: what moved reply frames
    /// encode into, and what a consumed `Bytes` is freed with on the
    /// borrowing transport. Every transport sets it.
    gpa: ?std.mem.Allocator = null,
    /// Set where the delivery queue can take ownership of an encoded
    /// reply (thread, inline): `send` encodes into `gpa` and the frame
    /// moves whole — no dupe at the queue. Web stays on the borrowing
    /// send_fn: its bytes must cross wasm memories anyway.
    send_owned_fn: ?*const fn (ctx: ?*anyopaque, frame: Frame) void = null,
};

/// The worker's whole capability surface: replies out, a cooperative
/// cancellation probe, and per-message scratch. No App, no clock, no IO.
pub fn Outbox(comptime Reply: type) type {
    return struct {
        raw: *RawOutbox,
        /// Freed after `handle` returns — the place to assemble reply
        /// slices.
        arena: std.mem.Allocator,

        /// Serialize and post now; call any number of times per
        /// message — progress is just more replies. A `Bytes` in the
        /// reply moves: on success its ownership is gone, on error it
        /// is untouched and still the caller's.
        pub fn send(self: *@This(), reply: Reply) !void {
            if (self.raw.send_owned_fn) |send_owned| {
                const frame = try encodeFrame(Reply, reply_frame, self.raw.gpa.?, reply);
                send_owned(self.raw.ctx, frame);
                return;
            }
            var frame: std.ArrayList(u8) = .empty;
            defer frame.deinit(self.arena);
            var atts: std.ArrayList([]u8) = .empty;
            defer atts.deinit(self.arena);
            try frame.append(self.arena, reply_frame);
            try codec.encode(Reply, self.arena, &frame, &atts, reply);
            if (atts.items.len == 0) {
                try self.raw.send_fn(self.raw.ctx, frame.items);
            } else {
                // The web floor: blobs concatenate into one envelope
                // buffer for the postMessage transfer.
                const optional = try self.arena.alloc(?[]u8, atts.items.len);
                for (atts.items, optional) |a, *o| o.* = a;
                const env = try buildEnvelope(self.arena, reply_attach_frame, frame.items[1..], optional);
                try self.raw.send_fn(self.raw.ctx, env);
                // Sent — the move completed; the blobs' free lands here.
                const g = self.raw.gpa.?;
                for (atts.items) |a| g.free(a);
            }
        }

        /// True when a newer message is waiting or retirement was
        /// requested. Best-effort: on the web it updates only between
        /// messages (a synchronous wasm frame cannot observe arrivals
        /// mid-flight); on native it is live.
        pub fn interrupted(self: *const @This()) bool {
            return self.raw.interrupted_fn(self.raw.ctx);
        }
    };
}

/// Type-erased worker role, shared by every transport: create the
/// instance, feed it one decoded message, destroy it.
pub const Vt = struct {
    create: *const fn (gpa: std.mem.Allocator) anyerror!*anyopaque,
    handle: *const fn (inst: *anyopaque, payload: []const u8, attachments: []?[]u8, raw: *RawOutbox) anyerror!void,
    destroy: *const fn (inst: *anyopaque, gpa: std.mem.Allocator) void,
};

pub fn vtFor(comptime T: type) *const Vt {
    comptime validateWorker(T);
    const Shim = struct {
        fn create(gpa: std.mem.Allocator) anyerror!*anyopaque {
            const inst = try gpa.create(T);
            errdefer gpa.destroy(inst);
            inst.* = try T.init(gpa);
            return inst;
        }
        fn handle(p: *anyopaque, payload: []const u8, attachments: []?[]u8, raw: *RawOutbox) anyerror!void {
            const inst: *T = @ptrCast(@alignCast(p));
            const msg = try codec.decode(T.Msg, raw.arena, payload, attachments);
            var out: Outbox(T.Reply) = .{ .raw = raw, .arena = raw.arena };
            try T.handle(inst, msg, &out);
        }
        fn destroy(p: *anyopaque, gpa: std.mem.Allocator) void {
            const inst: *T = @ptrCast(@alignCast(p));
            inst.deinit();
            gpa.destroy(inst);
        }
    };
    const vt = Vt{ .create = Shim.create, .handle = Shim.handle, .destroy = Shim.destroy };
    return &vt;
}

fn validateWorker(comptime T: type) void {
    comptime {
        if (!@hasDecl(T, "Msg") or !@hasDecl(T, "Reply"))
            @compileError(@typeName(T) ++ ": a worker declares `pub const Msg` and `pub const Reply` message types (docs/internals/workers.md)");
        codec.assertMessage(T.Msg);
        codec.assertMessage(T.Reply);
        if (!@hasDecl(T, "init") or !@hasDecl(T, "deinit") or !@hasDecl(T, "handle"))
            @compileError(@typeName(T) ++ ": a worker implements `init(gpa) !T`, `deinit(*T) void`, and `handle(*T, Msg, *Outbox(Reply)) !void` (docs/internals/workers.md)");
    }
}

/// Position in the root module's `nokreWorkers` tuple — the wire id a
/// spawned wasm instance uses to find the code in its own copy of the
/// artifact. Null when the root declares no registry (native-only apps,
/// unit tests); once a registry exists, membership is enforced on every
/// platform so the set stays closed.
fn registryIndex(comptime T: type) ?u32 {
    const root = @import("root");
    if (!@hasDecl(root, "nokreWorkers")) return null;
    inline for (root.nokreWorkers, 0..) |W, i| {
        if (W == T) return @intCast(i);
    }
    @compileError("worker type " ++ @typeName(T) ++ " is not in the root module's nokreWorkers — add it there (docs/internals/workers.md)");
}

// ---- app-side state ----
// Service state lives on the App: each App owns one heap-pinned Runtime
// (created at App.init), so two apps in one process — two tests in one
// binary, apps driven from separate threads — have disjoint slot
// tables, delivery queues, and wakes by construction, not by the test
// runner's serialization. Only the UI thread touches the slot table;
// worker threads reach only their own transport struct and the delivery
// stack.

const Slot = struct {
    gen: u32 = 1,
    state: enum { free, live, retiring } = .free,
    ctx: ?*anyopaque = null,
    /// The typed on_reply, erased for storage; `deliver` casts it back.
    on_reply: *const anyopaque = undefined,
    on_fault: ?*const fn (ctx: ?*anyopaque, fault: Fault) void = null,
    deliver: *const fn (ctx: ?*anyopaque, on_reply: *const anyopaque, payload: []const u8, attachments: []?[]u8, arena: std.mem.Allocator) codec.DecodeError!void = undefined,
    transport: Transport = .none,
    /// Non-null makes this an asker slot: replies answer the FIFO below
    /// instead of the spawn-time stream (`dispatchAsk`).
    asks: ?*AskState = null,
};

const AskEntry = struct {
    /// The encoded question, until it routes to the worker. The front
    /// entry's frame is always gone — routed the moment it reached the
    /// front — so only queued entries still own one.
    frame: ?Frame,
    ctx: ?*anyopaque,
    /// The typed on_answer, erased for storage; the shims cast it back.
    on_answer: *const anyopaque,
};

/// An asker slot's pending questions. Heap-pinned beside the slot table
/// (the table's ArrayList moves when a callback spawns; this must not),
/// and UI-thread only like the table itself — the one-loop model is
/// what lets a queue exist here without a lock.
const AskState = struct {
    head: usize = 0,
    len: usize = 0,
    entries: [max_pending_asks]AskEntry = undefined,
    deliver_reply: *const fn (ctx: ?*anyopaque, on_answer: *const anyopaque, payload: []const u8, attachments: []?[]u8, arena: std.mem.Allocator) codec.DecodeError!void,
    deliver_fault: *const fn (ctx: ?*anyopaque, on_answer: *const anyopaque, fault: Fault) void,

    fn push(self: *AskState, entry: AskEntry) void {
        self.entries[(self.head + self.len) % max_pending_asks] = entry;
        self.len += 1;
    }

    fn pop(self: *AskState) ?AskEntry {
        if (self.len == 0) return null;
        const entry = self.entries[self.head];
        self.head = (self.head + 1) % max_pending_asks;
        self.len -= 1;
        return entry;
    }
};

const Transport = union(enum) {
    none,
    inl: InlineWorker,
    thread: ThreadPtr,
    post,
};

const InlineWorker = struct {
    vt: *const Vt,
    inst: ?*anyopaque,
    inbox: std.ArrayList(Frame) = .empty,
};

// The delivery queue: a lock-free multi-producer stack (worker threads
// push) whose single consumer (the UI thread) grabs the whole chain and
// reverses it, restoring FIFO. No locks, no Io instance — and on wasm,
// where the app instance is its only thread, the atomics are free.
const Delivery = struct {
    next: ?*Delivery = null,
    index: u32,
    gen: u32,
    bytes: []u8,
    attachments: []?[]u8 = &.{},
};

/// The platform's main-thread hop, installed by the shell before its
/// event loop (c_shell.zig on Apple; other shells with their event
/// loops). Called from worker threads after a delivery is queued; the
/// hook must get the runtime's `pump()` called on the UI thread soon.
pub const Wake = struct {
    ctx: ?*anyopaque = null,
    call: ?*const fn (ctx: ?*anyopaque) void = null,
};

/// One app's whole worker service: slot table, delivery queue, wake,
/// and transport mode. Heap-pinned and owned by the App (`app.runtime`)
/// so the pointers embedded in handles and tickets survive the by-value
/// moves a stack App makes.
pub const Runtime = struct {
    gpa: std.mem.Allocator,
    slots: std.ArrayList(Slot) = .empty,
    delivery_head: std.atomic.Value(?*Delivery) = .init(null),
    /// Consumer-side FIFO remainder of the last grab. UI thread only.
    delivery_ready: ?*Delivery = null,
    wake: Wake = .{},
    /// Tests run workers inline by default: the harness's settleWorkers
    /// drives delivery deterministically. A test that wants real
    /// threads flips its own app to `.platform` — per-app state, so it
    /// is not a cross-test hazard.
    mode: Mode = if (builtin.is_test) .inline_pump else .platform,
    /// Keeps the Runtime's memory alive past `shutdown` while a
    /// detached producer (a native http request thread) still holds a
    /// ticket into it. The App holds the founding reference; deliveries
    /// enqueued after shutdown are dropped, and the memory falls with
    /// the last reference.
    refs: std.atomic.Value(u32) = .init(1),
    down: std.atomic.Value(bool) = .init(false),

    pub const Mode = enum { inline_pump, platform };

    pub fn create(gpa: std.mem.Allocator) !*Runtime {
        const rt = try gpa.create(Runtime);
        rt.* = .{ .gpa = gpa };
        return rt;
    }

    /// App.deinit's teardown: stop everything, then drop the App's
    /// reference. The struct frees now unless a detached producer is
    /// still holding on.
    pub fn destroy(self: *Runtime) void {
        self.shutdown();
        self.unref();
    }

    pub fn ref(self: *Runtime) void {
        _ = self.refs.fetchAdd(1, .monotonic);
    }

    pub fn unref(self: *Runtime) void {
        if (self.refs.fetchSub(1, .release) != 1) return;
        _ = self.refs.load(.acquire);
        // Nobody else can touch the queue now; free what raced in
        // between shutdown's drain and the last release.
        while (self.takeDelivery()) |node| self.freeDelivery(node);
        self.gpa.destroy(self);
    }

    pub fn installWake(self: *Runtime, ctx: ?*anyopaque, call: *const fn (ctx: ?*anyopaque) void) void {
        self.wake = .{ .ctx = ctx, .call = call };
    }

    // ---- delivery (worker → UI thread) ----

    /// Queue a worker→app frame for the UI thread, duplicating it — for
    /// frames whose backing store is transient (stack fault buffers, the
    /// web's reusable scratch). Worker threads land here; the wasm app
    /// instance calls it from its own (only) thread.
    pub fn enqueueDelivery(self: *Runtime, index: u32, gen: u32, frame: []const u8) void {
        const bytes = self.gpa.dupe(u8, frame) catch return; // dropped delivery, not a crash
        self.enqueueDeliveryOwned(index, gen, .{ .bytes = bytes });
    }

    /// Queue a worker→app frame the queue takes ownership of — the reply
    /// path on transports that can move an encoded buffer whole (thread,
    /// inline). `frame` must come from this runtime's gpa: thread
    /// workers allocate from the app's gpa, the very allocator `spawn`
    /// recorded, so freeDelivery's free matches without per-frame
    /// allocator plumbing.
    pub fn enqueueDeliveryOwned(self: *Runtime, index: u32, gen: u32, frame: Frame) void {
        if (self.down.load(.acquire)) {
            frame.free(self.gpa);
            return; // dropped delivery: the app is gone
        }
        const node = self.gpa.create(Delivery) catch {
            frame.free(self.gpa);
            return; // dropped delivery, not a crash
        };
        node.* = .{ .index = index, .gen = gen, .bytes = frame.bytes, .attachments = frame.attachments };
        self.enqueueDeliveryPrepared(node);
    }

    /// Queue a node whose storage was claimed up front — the one-shot
    /// retirement, which must not be droppable for OOM: once the reply
    /// ahead of it has moved, a dropped retired frame would strand the
    /// slot live forever.
    fn enqueueDeliveryPrepared(self: *Runtime, node: *Delivery) void {
        if (self.down.load(.acquire)) {
            (Frame{ .bytes = node.bytes, .attachments = node.attachments }).free(self.gpa);
            self.gpa.destroy(node);
            return; // dropped delivery: the app is gone
        }
        var head = self.delivery_head.load(.monotonic);
        while (true) {
            node.next = head;
            head = self.delivery_head.cmpxchgWeak(head, node, .release, .monotonic) orelse break;
        }
        if (self.wake.call) |call| call(self.wake.ctx);
    }

    fn takeDelivery(self: *Runtime) ?*Delivery {
        if (self.delivery_ready == null) {
            var grabbed = self.delivery_head.swap(null, .acquire);
            while (grabbed) |node| { // newest-first; reverse into FIFO
                grabbed = node.next;
                node.next = self.delivery_ready;
                self.delivery_ready = node;
            }
        }
        const node = self.delivery_ready orelse return null;
        self.delivery_ready = node.next;
        return node;
    }

    fn freeDelivery(self: *Runtime, node: *Delivery) void {
        (Frame{ .bytes = node.bytes, .attachments = node.attachments }).free(self.gpa);
        self.gpa.destroy(node);
    }

    /// Drain every queued delivery into its handler, on the calling (UI)
    /// thread. Platform wakes call this; the harness reaches it through
    /// pumpAll. Returns whether anything was delivered.
    pub fn pump(self: *Runtime) bool {
        var delivered = false;
        while (self.takeDelivery()) |node| {
            delivered = true;
            defer self.freeDelivery(node);
            if (node.index >= self.slots.items.len) continue;
            const slot = &self.slots.items[node.index];
            if (slot.gen != node.gen or slot.state == .free) continue;
            self.dispatchFrame(node.index, slot, node.bytes, node.attachments);
        }
        return delivered;
    }

    fn dispatchFrame(self: *Runtime, index: u32, slot: *Slot, frame: []const u8, attachments: []?[]u8) void {
        if (frame.len == 0) return;
        if (slot.asks != null) return self.dispatchAsk(index, slot, frame, attachments);
        // Read before the callback: a handler may spawn and move the table.
        const ctx = slot.ctx;
        const on_reply = slot.on_reply;
        const on_fault = slot.on_fault;
        const deliver = slot.deliver;
        switch (frame[0]) {
            reply_frame => {
                var arena_state = std.heap.ArenaAllocator.init(self.gpa);
                defer arena_state.deinit();
                deliver(ctx, on_reply, frame[1..], attachments, arena_state.allocator()) catch |e| {
                    if (on_fault) |f| f(ctx, .{ .err = @errorName(e) });
                };
            },
            fault_frame => if (on_fault) |f| f(ctx, .{ .err = frame[1..] }),
            retired_frame => self.finalizeSlot(index),
            died_frame => {
                if (on_fault) |f| f(ctx, .died);
                self.finalizeSlot(index);
            },
            else => {},
        }
    }

    /// The asker's arm of `dispatchFrame`: answers pop the FIFO in ask
    /// order. Slot access happens before each consumer callback — a
    /// callback may spawn (moving the slot table) or ask again
    /// (mutating the heap-pinned AskState, which survives both).
    fn dispatchAsk(self: *Runtime, index: u32, slot: *Slot, frame: []const u8, attachments: []?[]u8) void {
        const asks = slot.asks.?;
        switch (frame[0]) {
            reply_frame => {
                // A worker on the ask surface answers exactly once per
                // message; a reply with no question left drops here.
                const entry = asks.pop() orelse return;
                var arena_state = std.heap.ArenaAllocator.init(self.gpa);
                defer arena_state.deinit();
                asks.deliver_reply(entry.ctx, entry.on_answer, frame[1..], attachments, arena_state.allocator()) catch |e|
                    asks.deliver_fault(entry.ctx, entry.on_answer, .{ .err = @errorName(e) });
                self.askAdvance(index);
            },
            fault_frame => {
                const entry = asks.pop() orelse return;
                asks.deliver_fault(entry.ctx, entry.on_answer, .{ .err = frame[1..] });
                self.askAdvance(index);
            },
            retired_frame => self.finalizeSlot(index),
            died_frame => {
                // The death answers every pending question, oldest
                // first, then the slot falls with the ask state. The
                // state flip lands before any callback so a re-entrant
                // ask refuses instead of queueing into a corpse.
                slot.state = .retiring;
                while (asks.pop()) |entry| {
                    if (entry.frame) |f| f.free(self.gpa);
                    asks.deliver_fault(entry.ctx, entry.on_answer, .died);
                }
                self.finalizeSlot(index);
            },
            else => {},
        }
    }

    /// Route the next queued question, if the FIFO's front still holds
    /// one. Re-derives the slot each pass: the answer callback that
    /// just ran may have grown the table.
    fn askAdvance(self: *Runtime, index: u32) void {
        while (true) {
            if (index >= self.slots.items.len) return;
            const slot = &self.slots.items[index];
            if (slot.state == .free) return;
            const asks = slot.asks orelse return;
            if (asks.len == 0) return;
            const entry = &asks.entries[asks.head];
            const frame = entry.frame orelse return; // already routed (a flush)
            entry.frame = null;
            if (routeToWorker(self, index, slot, frame)) |_| {
                return;
            } else |e| {
                // This question can no longer reach the worker: the
                // failure is its answer, and the next gets its turn.
                frame.free(self.gpa);
                const dead = asks.pop().?;
                asks.deliver_fault(dead.ctx, dead.on_answer, .{ .err = @errorName(e) });
            }
        }
    }

    /// Free an asker slot's FIFO. On the normal paths (retired, died)
    /// the queue drained first; anything still here — shutdown — frees
    /// without answering, because there is nobody left to answer on.
    fn freeAskState(self: *Runtime, slot: *Slot) void {
        const asks = slot.asks orelse return;
        while (asks.pop()) |entry| if (entry.frame) |f| f.free(self.gpa);
        self.gpa.destroy(asks);
        slot.asks = null;
    }

    fn allocSlot(self: *Runtime) !u32 {
        for (self.slots.items, 0..) |*s, i| {
            if (s.state == .free) return @intCast(i);
        }
        try self.slots.append(self.gpa, .{});
        return @intCast(self.slots.items.len - 1);
    }

    fn liveSlot(self: *Runtime, index: u32, gen: u32) ?*Slot {
        if (index >= self.slots.items.len) return null;
        const slot = &self.slots.items[index];
        if (slot.gen != gen or slot.state != .live) return null;
        return slot;
    }

    fn finalizeSlot(self: *Runtime, index: u32) void {
        const slot = &self.slots.items[index];
        self.freeAskState(slot);
        switch (slot.transport) {
            .inl => |*iw| {
                for (iw.inbox.items) |f| f.free(self.gpa);
                iw.inbox.deinit(self.gpa);
            },
            .thread => |w| joinThread(w, self.gpa),
            .post => postDrop(index),
            .none => {},
        }
        slot.transport = .none;
        slot.state = .free;
        slot.gen += 1;
    }

    // ---- the inline transport ----
    // Same vtable, no threads: messages sit in the slot until a pump, so
    // a test decides exactly when the "background" work runs.

    fn pumpInline(self: *Runtime) bool {
        const g = self.gpa;
        var worked = false;
        var i: usize = 0;
        while (i < self.slots.items.len) : (i += 1) {
            const slot = &self.slots.items[i];
            if (slot.state == .free) continue;
            const iw = switch (slot.transport) {
                .inl => |*w| w,
                else => continue,
            };
            while (iw.inbox.items.len > 0) {
                worked = true;
                const frame = iw.inbox.orderedRemove(0);
                defer frame.free(g);
                if (frame.bytes.len == 0 or frame.bytes[0] != msg_frame or iw.inst == null) continue;
                var arena_state = std.heap.ArenaAllocator.init(g);
                defer arena_state.deinit();
                var c: InlineCtx = .{ .rt = self, .index = @intCast(i), .slot = slot, .iw = iw };
                var raw: RawOutbox = .{
                    .arena = arena_state.allocator(),
                    .ctx = &c,
                    .send_fn = inlineSend,
                    .interrupted_fn = inlineInterrupted,
                    .gpa = g,
                    .send_owned_fn = inlineSendOwned,
                };
                iw.vt.handle(iw.inst.?, frame.bytes[1..], frame.attachments, &raw) catch |e| {
                    var buf: FaultBuf = undefined;
                    self.enqueueDelivery(@intCast(i), slot.gen, faultFrame(&buf, e));
                };
            }
            if (slot.state == .retiring and iw.inst != null) {
                worked = true;
                iw.vt.destroy(iw.inst.?, g);
                iw.inst = null;
                self.enqueueDelivery(@intCast(i), slot.gen, &[1]u8{retired_frame});
            }
        }
        return worked;
    }

    /// Run every queued worker message and deliver every queued reply,
    /// to quiescence — the harness's settleWorkers. On platforms the
    /// workers run themselves; only the deliveries drain here.
    pub fn pumpAll(self: *Runtime) void {
        while (true) {
            const worked = self.pumpInline();
            const delivered = self.pump();
            if (!worked and !delivered) break;
        }
    }

    /// Tear down every live worker without running handlers: native
    /// joins threads (draining their inboxes first — the retire
    /// contract), the web terminates, pending deliveries are dropped.
    /// App.deinit lands here through `destroy`.
    pub fn shutdown(self: *Runtime) void {
        const g = self.gpa;
        // Producers that outlive the app (detached request threads) see
        // this and drop their deliveries instead of queueing into a
        // table that is about to go away.
        self.down.store(true, .release);
        for (self.slots.items, 0..) |*slot, i| {
            if (slot.state == .free) continue;
            self.freeAskState(slot);
            switch (slot.transport) {
                .inl => |*iw| {
                    for (iw.inbox.items) |f| f.free(g);
                    iw.inbox.deinit(g);
                    if (iw.inst) |inst| iw.vt.destroy(inst, g);
                },
                .thread => |w| {
                    requestThreadRetire(w);
                    joinThread(w, g);
                },
                .post => postDrop(@intCast(i)),
                .none => {},
            }
            slot.* = .{};
        }
        self.slots.deinit(g);
        self.slots = .empty;
        while (self.takeDelivery()) |node| self.freeDelivery(node);
        self.wake = .{};
    }

    // ---- wasm app-instance entry points (called from web.zig) ----

    /// A reply frame arrived from a spawned Worker; the attribution is
    /// the slot's current generation — the slot cannot be reused while
    /// its retirement is still in flight, so the attribution is exact.
    pub fn deliverFromPost(self: *Runtime, index: u32, frame: []const u8) void {
        if (index >= self.slots.items.len) return;
        const slot = &self.slots.items[index];
        if (slot.state == .free) return;
        if (frame.len > 0 and frame[0] == reply_attach_frame) {
            const owned = frameFromEnvelope(self.gpa, reply_frame, frame) orelse return;
            self.enqueueDeliveryOwned(index, slot.gen, owned);
        } else {
            self.enqueueDelivery(index, slot.gen, frame);
        }
        _ = self.pump();
    }

    /// The spawned Worker crashed (onerror / failed boot).
    pub fn postWorkerDied(self: *Runtime, index: u32) void {
        self.deliverFromPost(index, &[1]u8{died_frame});
    }
};

// ---- spawn / send / retire ----

pub fn SpawnOptions(comptime T: type) type {
    return struct {
        app: *App,
        ctx: ?*anyopaque = null,
        on_reply: *const fn (ctx: ?*anyopaque, reply: T.Reply) void,
        on_fault: ?*const fn (ctx: ?*anyopaque, fault: Fault) void = null,
    };
}

/// A generation-checked id, like NodeId: a stale handle is
/// `error.WorkerRetired`, never a dangling pointer. Carries its app's
/// runtime, so handles from two apps never cross wires.
pub fn Handle(comptime T: type) type {
    return struct {
        runtime: *Runtime,
        index: u32,
        gen: u32,

        /// Serialize-and-copy happens inside the call; `msg`'s slices
        /// are borrowed only for its duration. A `Bytes` in the message
        /// moves instead: on success its ownership is gone, on error it
        /// is untouched and still the caller's.
        pub fn send(self: @This(), msg: T.Msg) !void {
            const rt = self.runtime;
            const slot = rt.liveSlot(self.index, self.gen) orelse return error.WorkerRetired;
            const g = rt.gpa;
            const frame = try encodeFrame(T.Msg, msg_frame, g, msg);
            routeToWorker(rt, self.index, slot, frame) catch |e| {
                // The encode's borrows still hold: the bytes and the
                // attachment table free, the blobs stay the caller's.
                g.free(frame.bytes);
                if (frame.attachments.len > 0) g.free(frame.attachments);
                return e;
            };
        }

        /// No more sends; queued messages drain, `deinit` runs, the
        /// thread joins / the Worker closes. Replies already sent still
        /// arrive. Idempotent, and never allocates.
        pub fn retire(self: @This()) void {
            const rt = self.runtime;
            const slot = rt.liveSlot(self.index, self.gen) orelse return;
            slot.state = .retiring;
            switch (slot.transport) {
                .inl => {}, // the pump drains, then destroys
                .thread => |w| requestThreadRetire(w),
                .post => postSend(self.index, &[1]u8{retire_frame}),
                .none => {},
            }
        }
    };
}

pub fn spawn(comptime T: type, opts: SpawnOptions(T)) !Handle(T) {
    const rt = opts.app.runtime;
    const index = try rt.allocSlot();
    const slot = &rt.slots.items[index];
    const gen = slot.gen;
    slot.* = .{
        .gen = gen,
        .state = .live,
        .ctx = opts.ctx,
        .on_reply = @ptrCast(opts.on_reply),
        .on_fault = opts.on_fault,
        .deliver = deliverShim(T.Reply),
    };
    // A failed transport must not leave the slot `.live` with nothing
    // behind it: liveSlot would keep resolving it, and the next spawn
    // could be handed a slot that still answers for this one. The gen
    // bump spends any index that leaked before the error.
    errdefer {
        slot.state = .free;
        slot.gen +%= 1;
    }
    try startTransport(T, rt, slot, index, gen);
    return .{ .runtime = rt, .index = index, .gen = gen };
}

/// The transport half of a spawn, shared by `spawn` and `spawnAsker`.
/// On error nothing started; the caller unwinds its slot.
fn startTransport(comptime T: type, rt: *Runtime, slot: *Slot, index: u32, gen: u32) !void {
    const vt = comptime vtFor(T);
    const reg = comptime registryIndex(T);
    if (comptime is_wasm and reg == null) @compileError(
        \\workers on the web need the registry: declare
        \\`pub const nokreWorkers = .{ ... };` in the root module and
        \\include this worker type. docs/internals/workers.md.
    );
    if (rt.mode == .inline_pump) {
        // Inline creation is eager, so a failing `init` surfaces at the
        // spawn (a test wants the error now, not a died fault later).
        const inst = try vt.create(rt.gpa);
        slot.transport = .{ .inl = .{ .vt = vt, .inst = inst } };
    } else if (comptime is_wasm) {
        post_transport.spawn(reg.?, index);
        slot.transport = .post;
    } else {
        slot.transport = .{ .thread = try spawnThread(rt.gpa, rt, vt, index, gen) };
    }
}

// ---- the ask surface ----
// Request/response over a worker: `spawnAsker` opens the same worker
// struct behind a different contract — every message is a question,
// and every question is answered exactly once, in ask order. The
// pending questions are a small bounded FIFO on the slot, and only the
// front one is ever in the worker's inbox — the next routes when the
// front answers — so a worker mid-answer sees `interrupted()` only for
// retirement, and an unrelated ask can never make in-flight work
// stale. What used to force every consumer to hand-roll a
// pending-callback queue is the library's own bookkeeping now.

/// Questions an asker holds open at once, counting the one in flight —
/// one per screen or client that can keep a request pending, with room
/// to spare. Past it `ask` refuses with `error.TooManyAsks`: the bound
/// is the contract, a queue that bounds latency instead of hiding an
/// unbounded backlog.
pub const max_pending_asks = 32;

/// What an ask resolves to: the worker's one reply, or the fault that
/// took its place (a `handle` error, a route failure, `.died`).
pub fn Answer(comptime T: type) type {
    return union(enum) {
        reply: T.Reply,
        fault: Fault,
    };
}

/// A generation-checked asker — `Handle`'s request/response sibling.
/// Same staleness contract (`error.WorkerRetired`, never a dangling
/// pointer); the difference is the answer's address: each ask carries
/// its own callback, and answers arrive in ask order, exactly one per
/// accepted ask. That order is load-bearing: a consumer whose per-ask
/// context is wider than one pointer can keep it in a plain FIFO of
/// its own and pop in lockstep.
pub fn Asker(comptime T: type) type {
    return struct {
        runtime: *Runtime,
        index: u32,
        gen: u32,

        /// Queue a question. Serialize-and-copy happens inside the
        /// call — `msg`'s slices are borrowed only for its duration,
        /// and a `Bytes` moves on success, stays the caller's on
        /// error. A full queue refuses with `error.TooManyAsks` and
        /// nothing is queued.
        pub fn ask(self: @This(), msg: T.Msg, ctx: ?*anyopaque, on_answer: *const fn (ctx: ?*anyopaque, answer: Answer(T)) void) !void {
            const rt = self.runtime;
            const slot = rt.liveSlot(self.index, self.gen) orelse return error.WorkerRetired;
            const asks = slot.asks.?;
            if (asks.len == max_pending_asks) return error.TooManyAsks;
            const g = rt.gpa;
            const frame = try encodeFrame(T.Msg, msg_frame, g, msg);
            if (asks.len == 0) {
                routeToWorker(rt, self.index, slot, frame) catch |e| {
                    // The encode's borrows still hold: the bytes and
                    // the attachment table free, the blobs stay the
                    // caller's.
                    g.free(frame.bytes);
                    if (frame.attachments.len > 0) g.free(frame.attachments);
                    return e;
                };
                asks.push(.{ .frame = null, .ctx = ctx, .on_answer = @ptrCast(on_answer) });
            } else {
                asks.push(.{ .frame = frame, .ctx = ctx, .on_answer = @ptrCast(on_answer) });
            }
        }

        /// Questions still awaiting answers, counting the one in
        /// flight — the e2e idle probe: settled when zero. Zero once
        /// the asker is stale.
        pub fn pending(self: @This()) usize {
            const rt = self.runtime;
            if (self.index >= rt.slots.items.len) return 0;
            const slot = &rt.slots.items[self.index];
            if (slot.gen != self.gen or slot.state == .free) return 0;
            const asks = slot.asks orelse return 0;
            return asks.len;
        }

        /// No more asks; every queued question still reaches the
        /// worker — the flush below — so each is answered before
        /// `deinit` runs and the transport falls. Mid-retirement the
        /// worker sees `interrupted()` and may answer cheap, but it
        /// answers. Idempotent. Unlike `Handle.retire` this may
        /// allocate: the flush routes real frames.
        pub fn retire(self: @This()) void {
            const rt = self.runtime;
            const slot = rt.liveSlot(self.index, self.gen) orelse return;
            const asks = slot.asks.?;
            // Flush the queue into the worker's inbox so the drain
            // contract covers every question. If a route fails (OOM),
            // that question and everything behind it are answered by
            // the failure instead — routing past a hole would answer
            // later asks with earlier replies.
            var dropped: [max_pending_asks]AskEntry = undefined;
            var dropped_n: usize = 0;
            var fault_name: []const u8 = undefined;
            var i: usize = 0;
            while (i < asks.len) : (i += 1) {
                const entry = &asks.entries[(asks.head + i) % max_pending_asks];
                const frame = entry.frame orelse continue;
                entry.frame = null;
                if (dropped_n > 0) {
                    frame.free(rt.gpa);
                    dropped[dropped_n] = entry.*;
                    dropped_n += 1;
                    continue;
                }
                routeToWorker(rt, self.index, slot, frame) catch |e| {
                    fault_name = @errorName(e);
                    frame.free(rt.gpa);
                    dropped[0] = entry.*;
                    dropped_n = 1;
                };
            }
            asks.len -= dropped_n;
            slot.state = .retiring;
            switch (slot.transport) {
                .inl => {}, // the pump drains, then destroys
                .thread => |w| requestThreadRetire(w),
                .post => postSend(self.index, &[1]u8{retire_frame}),
                .none => {},
            }
            // Callbacks last: the state flip above already refuses a
            // re-entrant ask, and the AskState is heap-pinned.
            for (dropped[0..dropped_n]) |entry|
                asks.deliver_fault(entry.ctx, entry.on_answer, .{ .err = fault_name });
        }
    };
}

/// `spawn`'s request/response sibling. No spawn-time callbacks — each
/// ask carries its own — so the options collapse to the app.
pub fn spawnAsker(comptime T: type, app: *App) !Asker(T) {
    const rt = app.runtime;
    const g = rt.gpa;
    const asks = try g.create(AskState);
    errdefer g.destroy(asks);
    asks.* = .{
        .deliver_reply = askReplyShim(T),
        .deliver_fault = askFaultShim(T),
    };
    const index = try rt.allocSlot();
    const slot = &rt.slots.items[index];
    const gen = slot.gen;
    slot.* = .{ .gen = gen, .state = .live, .asks = asks };
    // Same unwind as spawn's, plus the ask state: a failed transport
    // must not leave a live slot, and the freed AskState must not leak
    // a dangling pointer behind it.
    errdefer {
        slot.asks = null;
        slot.state = .free;
        slot.gen +%= 1;
    }
    try startTransport(T, rt, slot, index, gen);
    return .{ .runtime = rt, .index = index, .gen = gen };
}

fn askReplyShim(comptime T: type) *const fn (?*anyopaque, *const anyopaque, []const u8, []?[]u8, std.mem.Allocator) codec.DecodeError!void {
    return struct {
        fn deliver(ctx: ?*anyopaque, on_answer: *const anyopaque, payload: []const u8, attachments: []?[]u8, arena: std.mem.Allocator) codec.DecodeError!void {
            const cb: *const fn (ctx: ?*anyopaque, answer: Answer(T)) void = @ptrCast(@alignCast(on_answer));
            cb(ctx, .{ .reply = try codec.decode(T.Reply, arena, payload, attachments) });
        }
    }.deliver;
}

fn askFaultShim(comptime T: type) *const fn (?*anyopaque, *const anyopaque, Fault) void {
    return struct {
        fn deliver(ctx: ?*anyopaque, on_answer: *const anyopaque, fault: Fault) void {
            const cb: *const fn (ctx: ?*anyopaque, answer: Answer(T)) void = @ptrCast(@alignCast(on_answer));
            cb(ctx, .{ .fault = fault });
        }
    }.deliver;
}

fn deliverShim(comptime Reply: type) *const fn (?*anyopaque, *const anyopaque, []const u8, []?[]u8, std.mem.Allocator) codec.DecodeError!void {
    return struct {
        fn deliver(ctx: ?*anyopaque, on_reply: *const anyopaque, payload: []const u8, attachments: []?[]u8, arena: std.mem.Allocator) codec.DecodeError!void {
            const cb: *const fn (ctx: ?*anyopaque, reply: Reply) void = @ptrCast(@alignCast(on_reply));
            cb(ctx, try codec.decode(Reply, arena, payload, attachments));
        }
    }.deliver;
}

/// Encode a value into a routable frame — the owned-buffer shape
/// `routeToWorker` consumes and `enqueueDeliveryOwned` moves whole.
/// `g` must be the allocator the receiving end frees with (the
/// runtime's gpa; on a worker thread, its own gpa, which spawn made
/// the same one). On error nothing moved: a `Bytes` in the value is
/// still the caller's.
fn encodeFrame(comptime M: type, kind: u8, g: std.mem.Allocator, value: M) codec.EncodeError!Frame {
    var frame: std.ArrayList(u8) = .empty;
    errdefer frame.deinit(g);
    // Until the hand-off below, the list holds borrows.
    var atts: std.ArrayList([]u8) = .empty;
    errdefer atts.deinit(g);
    try frame.append(g, kind);
    try codec.encode(M, g, &frame, &atts, value);
    const bytes = try frame.toOwnedSlice(g);
    errdefer g.free(bytes);
    const attachments = try sealAttachments(g, &atts);
    return .{ .bytes = bytes, .attachments = attachments };
}

// ---- one-shot delivery slots ----
// The delivery queue's second consumer family: a service that is not a
// worker (the http service, docs/internals/http.md) parks a typed
// callback, and exactly one reply later crosses from any thread. The
// slot rides the same table, generation checks, pump, wake, and
// shutdown — a service adds no second cross-thread structure. The
// reply frame is chased by a retired frame, so the slot frees itself
// right behind its one delivery; cancellation finalizes early and the
// generation bump drops anything still in flight.

/// A one-shot slot's claim ticket — same shape as a worker handle, but
/// single-delivery: after the reply (or a cancel) it is spent. Carries
/// its app's runtime so any thread can deliver against it.
pub const Ticket = struct { runtime: *Runtime, index: u32, gen: u32 };

/// Park `on_reply` and get a ticket any thread can deliver against.
/// `Reply` passes the same comptime codec gate as a worker reply.
/// UI thread only.
pub fn openOneShot(
    comptime Reply: type,
    app: *App,
    ctx: ?*anyopaque,
    on_reply: *const fn (ctx: ?*anyopaque, reply: Reply) void,
) !Ticket {
    return openOneShotOn(Reply, app.runtime, ctx, on_reply);
}

/// The same, for a caller holding the runtime rather than the `*App` —
/// a service delivering something nobody requested. `iap`'s purchase
/// stream opens a slot from inside a store callback, where there is no
/// app pointer in hand and the app's own handler must still run at a
/// pump rather than inside a platform delegate frame
/// (docs/internals/iap.md). UI thread only, like its wrapper.
pub fn openOneShotOn(
    comptime Reply: type,
    rt: *Runtime,
    ctx: ?*anyopaque,
    on_reply: *const fn (ctx: ?*anyopaque, reply: Reply) void,
) !Ticket {
    comptime codec.assertMessage(Reply);
    const index = try rt.allocSlot();
    const slot = &rt.slots.items[index];
    const gen = slot.gen;
    slot.* = .{
        .gen = gen,
        .state = .live,
        .ctx = ctx,
        .on_reply = @ptrCast(on_reply),
        .deliver = deliverShim(Reply),
        .transport = .none,
    };
    return .{ .runtime = rt, .index = index, .gen = gen };
}

/// Encode and queue the one reply, from any thread. On success the
/// frame (and any `Bytes` in it) has moved; on error nothing did and
/// the value is still the caller's. The retired frame queued behind it
/// frees the slot once the callback has run — push order is FIFO
/// order, per producer, by the queue's contract.
pub fn deliverOneShot(comptime Reply: type, ticket: Ticket, g: std.mem.Allocator, reply: Reply) codec.EncodeError!void {
    const rt = ticket.runtime;
    // The retirement's storage is claimed before the reply moves: an
    // OOM after that would have to drop the retired frame — stranding
    // the slot live forever — where failing here keeps the
    // nothing-moved-on-error contract intact.
    const node = try rt.gpa.create(Delivery);
    errdefer rt.gpa.destroy(node);
    const bytes = try rt.gpa.dupe(u8, &[1]u8{retired_frame});
    errdefer rt.gpa.free(bytes);
    const frame = try encodeFrame(Reply, reply_frame, g, reply);
    rt.enqueueDeliveryOwned(ticket.index, ticket.gen, frame);
    node.* = .{ .index = ticket.index, .gen = ticket.gen, .bytes = bytes };
    rt.enqueueDeliveryPrepared(node);
}

/// The callback will never run after this: the slot finalizes now and
/// the generation bump drops any delivery still in flight. Idempotent.
/// UI thread only.
pub fn cancelOneShot(ticket: Ticket) void {
    if (ticket.runtime.liveSlot(ticket.index, ticket.gen) == null) return;
    ticket.runtime.finalizeSlot(ticket.index);
}

/// Consumes `frame` on success; on error frees nothing, so the
/// caller's errdefers can hand `Bytes` ownership back untouched.
fn routeToWorker(rt: *Runtime, index: u32, slot: *Slot, frame: Frame) !void {
    const g = rt.gpa;
    switch (slot.transport) {
        .inl => |*iw| try iw.inbox.append(g, frame),
        .thread => |w| try enqueueThread(w, frame),
        .post => {
            if (frame.attachments.len == 0) {
                postSend(index, frame.bytes);
            } else {
                const env = try buildEnvelope(g, msg_attach_frame, frame.bytes[1..], frame.attachments);
                defer g.free(env);
                postSend(index, env);
            }
            frame.free(g);
        },
        .none => frame.free(g),
    }
}

/// Move an encode's attachment list into a frame's nullable table (the
/// shape `Bytes.take` needs on the receive side). Empties the list.
fn sealAttachments(g: std.mem.Allocator, atts: *std.ArrayList([]u8)) ![]?[]u8 {
    if (atts.items.len == 0) return &.{};
    const out = try g.alloc(?[]u8, atts.items.len);
    for (atts.items, out) |a, *o| o.* = a;
    atts.deinit(g);
    atts.* = .empty;
    return out;
}

// ---- the web envelope ----
// Attachments must cross postMessage inside the one transferred buffer,
// so they concatenate behind the frame: [kind][u32 n][n × u32 len]
// [payload][blobs]. Frames without attachments never take this shape —
// live-worker.js's ferry stays byte-compatible and dumb. This is the web
// floor the zero-copy handoff cannot go below; native never builds one.

/// Caller frees the returned buffer with `g`.
pub fn buildEnvelope(g: std.mem.Allocator, kind: u8, payload: []const u8, attachments: []const ?[]u8) ![]u8 {
    const empty: []const u8 = &.{};
    var total: usize = 1 + 4 + 4 * attachments.len + payload.len;
    for (attachments) |a| total += (a orelse empty).len;
    const buf = try g.alloc(u8, total);
    buf[0] = kind;
    std.mem.writeInt(u32, buf[1..5], @intCast(attachments.len), .little);
    var off: usize = 5;
    for (attachments) |a| {
        std.mem.writeInt(u32, buf[off..][0..4], @intCast((a orelse empty).len), .little);
        off += 4;
    }
    @memcpy(buf[off..][0..payload.len], payload);
    off += payload.len;
    for (attachments) |a| {
        const blob = a orelse empty;
        @memcpy(buf[off..][0..blob.len], blob);
        off += blob.len;
    }
    return buf;
}

/// Rebuild an owned Frame from an envelope, with the kind byte restored
/// to `plain_kind`: payload and blobs dupe out of the transport scratch
/// (the landing copy) so the receive-side ownership contract matches
/// native. Null on a malformed envelope or OOM — a dropped frame, not
/// a crash; our own ferry never produces one.
pub fn frameFromEnvelope(g: std.mem.Allocator, plain_kind: u8, envelope: []const u8) ?Frame {
    if (envelope.len < 5) return null;
    const n: usize = std.mem.readInt(u32, envelope[1..5], .little);
    var off: usize = 5;
    if ((envelope.len - off) / 4 < n) return null;
    var blobs_total: usize = 0;
    for (0..n) |i| {
        const len: usize = std.mem.readInt(u32, envelope[off + 4 * i ..][0..4], .little);
        // Checked: on wasm32 a sum of u32 lengths can wrap the 32-bit
        // usize and slip under the bound check below — malformed input
        // rejects ("never a crash"), it does not wrap.
        blobs_total = std.math.add(usize, blobs_total, len) catch return null;
    }
    off += 4 * n;
    if (envelope.len - off < blobs_total) return null;
    const payload = envelope[off .. envelope.len - blobs_total];

    const bytes = g.alloc(u8, 1 + payload.len) catch return null;
    bytes[0] = plain_kind;
    @memcpy(bytes[1..], payload);
    if (n == 0) return .{ .bytes = bytes };
    const atts = g.alloc(?[]u8, n) catch {
        g.free(bytes);
        return null;
    };
    var pos = envelope.len - blobs_total;
    for (0..n) |i| {
        const len = std.mem.readInt(u32, envelope[5 + 4 * i ..][0..4], .little);
        const blob = g.dupe(u8, envelope[pos..][0..len]) catch {
            for (atts[0..i]) |a| if (a) |b| g.free(b);
            g.free(atts);
            g.free(bytes);
            return null;
        };
        atts[i] = blob;
        pos += len;
    }
    return .{ .bytes = bytes, .attachments = atts };
}

// Comptime-cut wrappers: the dead transport's module is an empty struct
// on the other platform, so its calls must never be analyzed there.
fn spawnThread(g: std.mem.Allocator, rt: *Runtime, vt: *const Vt, index: u32, gen: u32) !ThreadPtr {
    if (comptime is_wasm) unreachable else return thread_transport.spawn(g, rt, vt, index, gen);
}
fn enqueueThread(w: ThreadPtr, frame: Frame) !void {
    if (comptime is_wasm) unreachable else try thread_transport.enqueue(w, frame);
}
fn requestThreadRetire(w: ThreadPtr) void {
    if (comptime is_wasm) unreachable else thread_transport.requestRetire(w);
}
fn joinThread(w: ThreadPtr, g: std.mem.Allocator) void {
    if (comptime is_wasm) unreachable else thread_transport.join(w, g);
}
fn postSend(index: u32, frame: []const u8) void {
    if (comptime is_wasm) post_transport.send(index, frame) else unreachable;
}
fn postDrop(index: u32) void {
    if (comptime is_wasm) post_transport.drop(index) else unreachable;
}

// ---- inline transport callbacks (file scope: fn-pointer targets) ----

const InlineCtx = struct { rt: *Runtime, index: u32, slot: *Slot, iw: *InlineWorker };

fn inlineSend(ctx: ?*anyopaque, frame: []const u8) anyerror!void {
    const c: *InlineCtx = @ptrCast(@alignCast(ctx.?));
    c.rt.enqueueDelivery(c.index, c.slot.gen, frame);
}

fn inlineSendOwned(ctx: ?*anyopaque, frame: Frame) void {
    const c: *InlineCtx = @ptrCast(@alignCast(ctx.?));
    c.rt.enqueueDeliveryOwned(c.index, c.slot.gen, frame);
}

fn inlineInterrupted(ctx: ?*anyopaque) bool {
    const c: *InlineCtx = @ptrCast(@alignCast(ctx.?));
    return c.iw.inbox.items.len > 0 or c.slot.state == .retiring;
}
