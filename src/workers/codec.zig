//! The worker message codec (docs/internals/workers.md). Both ends of
//! every channel are compiled from the same artifact, so the wire format
//! is an internal detail — little-endian, u32 tags and lengths, no
//! versioning; this codec never meets bytes from another version of
//! itself. What it guards instead is the type: `assertMessage` walks a
//! message type at comptime and names the exact field that cannot cross
//! a thread boundary, so the error lands on the declaration, not the
//! call site.
//!
//! Decoded values point into a caller-supplied arena *or the input
//! bytes* (`[]const u8` decodes as a view into the frame) — both scoped
//! to the handler call; nothing here retains memory. Decode still
//! bounds-checks every read — the bytes are trusted in origin, not in
//! transit.

const std = @import("std");

pub const EncodeError = error{ OutOfMemory, MessageTooLong };
pub const DecodeError = error{ Corrupt, OutOfMemory };

/// The transferable blob (docs/internals/workers.md): an owned buffer
/// whose *ownership* crosses the boundary — a move, not sharing. The
/// frame carries only length + attachment index; the buffer itself
/// rides out-of-band, so on native it is never copied at all.
///
/// Send side: `adopt` a buffer allocated from the gpa nokre gave you
/// (the app's allocator in app code, the worker's in `handle`). A
/// successful send consumes it — touching the buffer afterwards is
/// use-after-move, the same class of bug as using a freed slice; on a
/// failed send nothing moved and the caller still owns it.
///
/// Receive side: the decoded blob owns its buffer. `view` reads it for
/// the call like any decoded slice; `take` keeps it past the call and
/// the free becomes the caller's; an untaken blob is freed with its
/// delivery.
pub const Bytes = struct {
    data: []u8,
    /// Receive side only: the frame's attachment slot, emptied by
    /// `take` so the frame's cleanup skips what the handler kept.
    slot: ?*?[]u8 = null,

    pub fn adopt(data: []u8) Bytes {
        return .{ .data = data };
    }

    pub fn view(self: Bytes) []const u8 {
        return self.data;
    }

    pub fn take(self: Bytes) []u8 {
        if (self.slot) |s| s.* = null;
        return self.data;
    }
};

/// Comptime gate: every `Msg`/`Reply` passes through here once.
pub fn assertMessage(comptime T: type) void {
    comptime assertField(T, @typeName(T));
}

fn assertField(comptime T: type, comptime path: []const u8) void {
    // Before the walk: Bytes carries a pointer field on purpose (its
    // receive-side slot) and is the codec's own special case.
    if (T == Bytes) return;
    switch (@typeInfo(T)) {
        .void, .bool => {},
        .int => |i| if (i.bits > 64) @compileError(path ++ ": integers wider than 64 bits cannot cross a worker boundary (docs/internals/workers.md)"),
        .float => |f| if (f.bits != 32 and f.bits != 64) @compileError(path ++ ": only f32 and f64 cross a worker boundary"),
        .@"enum" => |e| assertField(e.tag_type, path),
        .optional => |o| assertField(o.child, path ++ ".?"),
        .array => |a| assertField(a.child, path ++ "[]"),
        .@"struct" => |s| {
            if (s.layout == .@"packed") {
                assertField(s.backing_integer.?, path);
            } else {
                for (s.fields) |f| {
                    if (f.is_comptime) @compileError(path ++ "." ++ f.name ++ ": comptime fields cannot cross a worker boundary");
                    assertField(f.type, path ++ "." ++ f.name);
                }
            }
        },
        .@"union" => |u| {
            if (u.tag_type == null) @compileError(path ++ ": untagged unions cannot cross a worker boundary — use union(enum)");
            for (u.fields) |f| assertField(f.type, path ++ "." ++ f.name);
        },
        .pointer => |p| {
            if (p.size != .slice or p.sentinel_ptr != null)
                @compileError(path ++ ": pointers cannot cross a worker boundary — messages are values; use a slice (docs/internals/workers.md)");
            assertField(p.child, path ++ "[]");
        },
        else => @compileError(path ++ ": " ++ @typeName(T) ++ " cannot cross a worker boundary (docs/internals/workers.md)"),
    }
}

/// Bit width rounded up to whole bytes, so `u7` travels as one byte and
/// round-trips through a range check on decode.
fn Container(comptime I: type) type {
    const info = @typeInfo(I).int;
    return std.meta.Int(info.signedness, ((info.bits + 7) / 8) * 8);
}

/// `attachments` collects the buffers of every `Bytes` in the value, in
/// traversal order — moved in as pointers, never copied. On error the
/// list holds only borrows: the caller deinits it without freeing items
/// and ownership stays where it was.
pub fn encode(comptime T: type, gpa: std.mem.Allocator, out: *std.ArrayList(u8), attachments: *std.ArrayList([]u8), value: T) EncodeError!void {
    if (T == Bytes) {
        const len = std.math.cast(u32, value.data.len) orelse return error.MessageTooLong;
        const idx = std.math.cast(u32, attachments.items.len) orelse return error.MessageTooLong;
        try encode(u32, gpa, out, attachments, len);
        try encode(u32, gpa, out, attachments, idx);
        try attachments.append(gpa, value.data);
        return;
    }
    switch (@typeInfo(T)) {
        .void => {},
        .bool => try out.append(gpa, @intFromBool(value)),
        .int => |i| {
            if (i.bits == 0) return;
            const C = Container(T);
            var buf: [@divExact(@typeInfo(C).int.bits, 8)]u8 = undefined;
            std.mem.writeInt(C, &buf, value, .little);
            try out.appendSlice(gpa, &buf);
        },
        .float => |f| try encode(std.meta.Int(.unsigned, f.bits), gpa, out, attachments, @bitCast(value)),
        .@"enum" => |e| try encode(e.tag_type, gpa, out, attachments, @intFromEnum(value)),
        .optional => |o| {
            try out.append(gpa, @intFromBool(value != null));
            if (value) |v| try encode(o.child, gpa, out, attachments, v);
        },
        .array => |a| for (value) |elem| try encode(a.child, gpa, out, attachments, elem),
        .@"struct" => |s| {
            if (s.layout == .@"packed") {
                try encode(s.backing_integer.?, gpa, out, attachments, @bitCast(value));
            } else {
                inline for (s.fields) |f| try encode(f.type, gpa, out, attachments, @field(value, f.name));
            }
        },
        .@"union" => |u| {
            try encode(u.tag_type.?, gpa, out, attachments, std.meta.activeTag(value));
            switch (value) {
                inline else => |payload| try encode(@TypeOf(payload), gpa, out, attachments, payload),
            }
        },
        .pointer => |p| {
            const len = std.math.cast(u32, value.len) orelse return error.MessageTooLong;
            try encode(u32, gpa, out, attachments, len);
            if (p.child == u8) {
                try out.appendSlice(gpa, value);
            } else {
                for (value) |elem| try encode(p.child, gpa, out, attachments, elem);
            }
        },
        else => comptime unreachable, // assertMessage ran first
    }
}

/// `attachments` are the frame's out-of-band buffers, consumed in
/// encode order exactly once each — an index out of step (or left
/// over) is corrupt, and no two blobs can alias one buffer. Decoded
/// `Bytes` point their `slot` into this array so `take` can empty it.
pub fn decode(comptime T: type, arena: std.mem.Allocator, bytes: []const u8, attachments: []?[]u8) DecodeError!T {
    var r: Reader = .{ .bytes = bytes, .attachments = attachments };
    const value = try decodeValue(T, arena, &r);
    if (r.pos != bytes.len) return error.Corrupt;
    if (r.attachments_used != attachments.len) return error.Corrupt;
    return value;
}

const Reader = struct {
    bytes: []const u8,
    pos: usize = 0,
    attachments: []?[]u8 = &.{},
    attachments_used: usize = 0,

    fn take(self: *Reader, n: usize) DecodeError![]const u8 {
        if (self.bytes.len - self.pos < n) return error.Corrupt;
        defer self.pos += n;
        return self.bytes[self.pos..][0..n];
    }
};

fn decodeValue(comptime T: type, arena: std.mem.Allocator, r: *Reader) DecodeError!T {
    if (T == Bytes) {
        const len = try decodeValue(u32, arena, r);
        const idx = try decodeValue(u32, arena, r);
        if (idx != r.attachments_used or idx >= r.attachments.len) return error.Corrupt;
        const slot = &r.attachments[idx];
        const buf = slot.* orelse return error.Corrupt;
        if (buf.len != len) return error.Corrupt;
        r.attachments_used += 1;
        return .{ .data = buf, .slot = slot };
    }
    switch (@typeInfo(T)) {
        .void => return {},
        .bool => return switch ((try r.take(1))[0]) {
            0 => false,
            1 => true,
            else => error.Corrupt,
        },
        .int => |i| {
            if (i.bits == 0) return 0;
            const C = Container(T);
            const raw = std.mem.readInt(C, (try r.take(@divExact(@typeInfo(C).int.bits, 8)))[0..@divExact(@typeInfo(C).int.bits, 8)], .little);
            return std.math.cast(T, raw) orelse error.Corrupt;
        },
        .float => |f| return @bitCast(try decodeValue(std.meta.Int(.unsigned, f.bits), arena, r)),
        .@"enum" => |e| return std.enums.fromInt(T, try decodeValue(e.tag_type, arena, r)) orelse error.Corrupt,
        .optional => |o| {
            return switch ((try r.take(1))[0]) {
                0 => null,
                1 => try decodeValue(o.child, arena, r),
                else => error.Corrupt,
            };
        },
        .array => |a| {
            var out: T = undefined;
            for (&out) |*elem| elem.* = try decodeValue(a.child, arena, r);
            return out;
        },
        .@"struct" => |s| {
            if (s.layout == .@"packed") {
                return @bitCast(try decodeValue(s.backing_integer.?, arena, r));
            }
            var out: T = undefined;
            inline for (s.fields) |f| @field(out, f.name) = try decodeValue(f.type, arena, r);
            return out;
        },
        .@"union" => |u| {
            const tag = try decodeValue(u.tag_type.?, arena, r);
            switch (tag) {
                inline else => |t| return @unionInit(T, @tagName(t), try decodeValue(@FieldType(T, @tagName(t)), arena, r)),
            }
        },
        .pointer => |p| {
            const len = try decodeValue(u32, arena, r);
            if (p.child == u8) {
                const raw = try r.take(len);
                // Every frame outlives the handler call it is decoded
                // for, so a const byte slice is a view, not a copy; a
                // mutable []u8 must not alias the frame and still dupes.
                if (p.is_const) return raw;
                return try arena.dupe(u8, raw);
            }
            const out = try arena.alloc(p.child, len);
            for (out) |*elem| elem.* = try decodeValue(p.child, arena, r);
            return out;
        },
        else => comptime unreachable,
    }
}
