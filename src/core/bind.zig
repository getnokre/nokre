//! One trampoline generator, for every context+function pair in reach.
//!
//! nokre allocates no closures, so a callback is a `{ ctx, call }` pair
//! with the context erased to `?*anyopaque`. Synthesizing that pair from
//! a typed method was `Action.bind`'s trick (core/element.zig) and it
//! was *private*: the four action types had it and nothing else did, so
//! every other pair-shaped type in reach — a consumer's own signals, a
//! domain package's ports — wrote the cast, the null unwrap and the
//! forward by hand, once per callback. `bindAs` is that generator with
//! the door open, and the four `bind` methods are now its callers rather
//! than four copies of it.
//!
//! **Why a free function over a type, and not a method.** The types that
//! need this most are declared in packages that do not import nokre and
//! must not start: a domain library is `{ ctx, call }` by *shape*, not by
//! inheritance. So the door is duck-typed at comptime. The app — which
//! does import nokre — binds a callback whose type nokre has never seen
//! and will never see again, and the library stays framework-free. That
//! asymmetry is the whole reason this is not `Callback.bind`.
//!
//! The shape is `ctx: ?*anyopaque` plus `call`, a (possibly optional)
//! pointer to a function taking `?*anyopaque` first. The two field names
//! are the contract, not a guess: a survey of the 202 callback structs in
//! the two domain packages this was built for found `ctx` and `call` in
//! 202 of 202. A pair that spells them differently is a pair with a
//! different convention, and inventing a field-name argument would make
//! every one of the other 202 call sites spell the convention it already
//! follows.
//!
//! **The one counterexample, and why it stays one.** `render/dom`'s
//! `Refs` is a `{ ctx, resolve }` pair, so `bindAs` cannot reach it. That
//! is decided, not overlooked (owner, 2026-08-05). `resolve` is the right
//! name at a door with one job — it says what the function does, where
//! `call` only says that it is one — and renaming a contract field to fit
//! a helper is the tail wagging the dog. The alternative, exporting the
//! field-named `bindField` below, widens the public surface permanently
//! to reach **two** call sites in one consumer tree, which is exactly the
//! trade this round exists to refuse. The site keeps its two casts. Do
//! not re-open this without a third pair asking for it.
//!
//! What this is *not* is a way to reach a callback field that rides on a
//! larger struct — a request carrying a URL, a builder carrying a tag.
//! Binding fills a whole value, so every field it does not fill must have
//! a default; anything else is constructed by its owner, who has the rest
//! of the fields anyway.

const std = @import("std");

/// Binds `f` into `Callback`'s `ctx`+`call` pair: `state` becomes the
/// context, and `call` becomes a generated function that unwraps it back
/// to `f`'s first parameter type and forwards the rest untouched.
///
/// ```zig
/// port.load(.{ .id = id }, nokre.bindAs(Port.RowsCallback, Screen.onRows, screen));
///
/// // in Screen:
/// fn onRows(self: *Screen, result: Port.RowsResult) void { ... }
/// ```
///
/// `f`'s signature is checked against `call`'s here, so a handler that
/// does not fit fails at this line with both signatures printed rather
/// than inside the generated body. Everything past `ctx` is forwarded by
/// position and by value, whatever it is; the return value goes back the
/// same way, so a `call` that answers a `bool` or a struct binds like one
/// that answers nothing.
///
/// The context is a pointer the caller keeps alive. That is the standing
/// rule for every pair nokre holds and it is unchanged here: binding
/// erases the type, not the lifetime.
pub fn bindAs(comptime Callback: type, comptime f: anytype, state: anytype) Callback {
    return bindField(Callback, "call", f, state);
}

/// `bindAs` with the function field named. Not re-exported from
/// `nokre.zig`: `Action` carries a second pair (`call_indexed`) and so is
/// the one type in reach with two, which is a fact about the element set
/// rather than a generality worth putting in the public surface (see the
/// module doc).
pub fn bindField(
    comptime Callback: type,
    comptime call_field: []const u8,
    comptime f: anytype,
    state: anytype,
) Callback {
    const fields = comptime structFields(Callback);
    const trampoline = Trampoline(Callback, call_field, f, @TypeOf(state)).call;
    // Field-by-field rather than a struct literal: `call` has no default
    // on several of the types this binds (a sheet builder must name its
    // function), so `.{ .ctx = …, .call = … }` would be the only legal
    // literal and would break the moment a pair grew a third field with a
    // default. Everything not bound is restored to what it declares.
    var out: Callback = undefined;
    out.ctx = state;
    @field(out, call_field) = trampoline;
    inline for (fields) |fld| {
        if (comptime std.mem.eql(u8, fld.name, "ctx")) continue;
        if (comptime std.mem.eql(u8, fld.name, call_field)) continue;
        const default = comptime fld.default_value_ptr orelse @compileError(std.fmt.comptimePrint(
            "bindAs: `{s}` requires field `{s}`, which a binding has no way to supply. " ++
                "bindAs fills a whole callback pair, so every field beside `ctx` and `{s}` must have a default.",
            .{ @typeName(Callback), fld.name, call_field },
        ));
        @field(out, fld.name) = @as(*const fld.type, @ptrCast(@alignCast(default))).*;
    }
    return out;
}

fn structFields(comptime Callback: type) []const std.builtin.Type.StructField {
    return switch (@typeInfo(Callback)) {
        .@"struct" => |s| s.fields,
        else => @compileError(std.fmt.comptimePrint(
            "bindAs: `{s}` is not a struct, so it has no `ctx`+`call` pair to fill.",
            .{@typeName(Callback)},
        )),
    };
}

/// The generated function, in a struct so it has somewhere to live.
///
/// Zig cannot declare a function whose parameter list is computed, so the
/// generator is a switch over arity rather than one expansion over
/// `params`. The ceiling is where it is because a callback that carries
/// five separate values past its context is carrying a struct it has not
/// named yet; going over it is a compile error that says so.
fn Trampoline(
    comptime Callback: type,
    comptime call_field: []const u8,
    comptime f: anytype,
    comptime StateArg: type,
) type {
    const CallFn = callFnType(Callback, call_field);
    const info = @typeInfo(CallFn).@"fn";
    const R = info.return_type.?;
    const params = info.params;
    if (params.len == 0 or params[0].type != ?*anyopaque) @compileError(std.fmt.comptimePrint(
        "bindAs: `{s}.{s}` is `{s}`, which does not take the erased context first. " ++
            "A bindable pair's function starts `fn (ctx: ?*anyopaque, …)`.",
        .{ @typeName(Callback), call_field, @typeName(CallFn) },
    ));

    const StatePtr = statePointer(Callback, call_field, f, StateArg);
    checkSignature(Callback, call_field, CallFn, f, StatePtr);

    return switch (params.len) {
        1 => struct {
            fn call(c: ?*anyopaque) R {
                return f(restore(StatePtr, c));
            }
        },
        2 => struct {
            fn call(c: ?*anyopaque, a0: params[1].type.?) R {
                return f(restore(StatePtr, c), a0);
            }
        },
        3 => struct {
            fn call(c: ?*anyopaque, a0: params[1].type.?, a1: params[2].type.?) R {
                return f(restore(StatePtr, c), a0, a1);
            }
        },
        4 => struct {
            fn call(c: ?*anyopaque, a0: params[1].type.?, a1: params[2].type.?, a2: params[3].type.?) R {
                return f(restore(StatePtr, c), a0, a1, a2);
            }
        },
        5 => struct {
            fn call(c: ?*anyopaque, a0: params[1].type.?, a1: params[2].type.?, a2: params[3].type.?, a3: params[4].type.?) R {
                return f(restore(StatePtr, c), a0, a1, a2, a3);
            }
        },
        else => @compileError(std.fmt.comptimePrint(
            "bindAs: `{s}.{s}` takes {d} values past its context, and the generator stops at four. " ++
                "Give the callback one named struct instead.",
            .{ @typeName(Callback), call_field, params.len - 1 },
        )),
    };
}

/// The cast the consumer no longer writes, with its loud null unwrap: a
/// pair whose function was set and whose context was not is a wiring bug,
/// and it panics here rather than at whatever the null becomes later.
inline fn restore(comptime StatePtr: type, c: ?*anyopaque) StatePtr {
    return @ptrCast(@alignCast(c.?));
}

fn callFnType(comptime Callback: type, comptime call_field: []const u8) type {
    const fields = structFields(Callback);
    inline for (fields) |fld| {
        if (!std.mem.eql(u8, fld.name, "ctx")) continue;
        if (fld.type != ?*anyopaque) @compileError(std.fmt.comptimePrint(
            "bindAs: `{s}.ctx` is `{s}`, not `?*anyopaque`. Binding erases a state " ++
                "pointer into the context, and that is the type it erases to.",
            .{ @typeName(Callback), @typeName(fld.type) },
        ));
        break;
    } else @compileError(std.fmt.comptimePrint(
        "bindAs: `{s}` has no `ctx` field, so there is nowhere to put the state pointer.",
        .{@typeName(Callback)},
    ));

    inline for (fields) |fld| {
        if (!std.mem.eql(u8, fld.name, call_field)) continue;
        // Optional or not: a pair whose function may be absent (`Action`,
        // a progress meter nobody watches) still binds to the same
        // signature, and null is what it means to bind nothing.
        const Ptr = switch (@typeInfo(fld.type)) {
            .optional => |o| o.child,
            else => fld.type,
        };
        const p = switch (@typeInfo(Ptr)) {
            .pointer => |ptr| ptr,
            else => @compileError(std.fmt.comptimePrint(
                "bindAs: `{s}.{s}` is `{s}`, not a function pointer.",
                .{ @typeName(Callback), call_field, @typeName(fld.type) },
            )),
        };
        return p.child;
    }
    @compileError(std.fmt.comptimePrint(
        "bindAs: `{s}` has no `{s}` field. A bindable pair is `{{ ctx: ?*anyopaque, {s}: *const fn (?*anyopaque, …) R }}`.",
        .{ @typeName(Callback), call_field, call_field },
    ));
}

/// What the trampoline casts the context back to: `f`'s own first
/// parameter, so the restored pointer is exactly the type the handler was
/// written against and never a coercion away from it. A handler with an
/// `anytype` state (legal, and the apps have several) has no declared
/// type to read, so the argument's own type stands in.
fn statePointer(
    comptime Callback: type,
    comptime call_field: []const u8,
    comptime f: anytype,
    comptime StateArg: type,
) type {
    const declared = fnInfo(Callback, call_field, f).params[0].type orelse StateArg;
    const want = pointee(Callback, call_field, declared, "the handler's first parameter");
    const got = pointee(Callback, call_field, StateArg, "`state`");
    if (want != got) @compileError(std.fmt.comptimePrint(
        "bindAs: the handler takes `{s}` but `state` is `{s}`. " ++
            "Bind a handler to the state it was written against.",
        .{ @typeName(declared), @typeName(StateArg) },
    ));
    return declared;
}

fn pointee(
    comptime Callback: type,
    comptime call_field: []const u8,
    comptime P: type,
    comptime what: []const u8,
) type {
    const p = switch (@typeInfo(P)) {
        .pointer => |ptr| ptr,
        else => @compileError(shapeError(Callback, call_field, P, what)),
    };
    if (p.size != .one) @compileError(shapeError(Callback, call_field, P, what));
    return p.child;
}

fn shapeError(
    comptime Callback: type,
    comptime call_field: []const u8,
    comptime P: type,
    comptime what: []const u8,
) []const u8 {
    return std.fmt.comptimePrint(
        "bindAs: binding `{s}.{s}` needs a single-item pointer to state; {s} is `{s}`. " ++
            "Pass `&state`, and write the handler as `fn (self: *State, …)`.",
        .{ @typeName(Callback), call_field, what, @typeName(P) },
    );
}

fn fnInfo(
    comptime Callback: type,
    comptime call_field: []const u8,
    comptime f: anytype,
) std.builtin.Type.Fn {
    const F = @TypeOf(f);
    // A comptime function *value* is as bindable as a declaration.
    const Unwrapped = switch (@typeInfo(F)) {
        .pointer => |p| p.child,
        else => F,
    };
    return switch (@typeInfo(Unwrapped)) {
        .@"fn" => |fi| fi,
        else => @compileError(std.fmt.comptimePrint(
            "bindAs: `f` is `{s}`, not a function. `{s}.{s}` needs one to point at.",
            .{ @typeName(F), @typeName(Callback), call_field },
        )),
    };
}

/// The curated failure. Zig would report a bad handler from inside the
/// generated body — a line the consumer did not write, about a cast it
/// did not make — so the two signatures are compared here and printed
/// side by side instead. What cannot be compared is skipped rather than
/// guessed: an `anytype` parameter has no declared type, and a handler
/// that narrows its error set is right, not wrong.
fn checkSignature(
    comptime Callback: type,
    comptime call_field: []const u8,
    comptime CallFn: type,
    comptime f: anytype,
    comptime StatePtr: type,
) void {
    const want = @typeInfo(CallFn).@"fn";
    const got = fnInfo(Callback, call_field, f);
    var ok = got.params.len == want.params.len;
    if (ok) for (got.params[1..], want.params[1..]) |g, w| {
        if (g.type) |t| ok = ok and t == w.type.?;
    };
    if (ok) if (got.return_type) |ret| {
        ok = returnFits(ret, want.return_type.?);
    };
    if (ok) return;
    @compileError(std.fmt.comptimePrint(
        "bindAs: this handler does not fit `{s}.{s}`.\n" ++
            "  expected: {s}\n" ++
            "  found:    {s}",
        .{ @typeName(Callback), call_field, wantedSignature(want, StatePtr), @typeName(@TypeOf(f)) },
    ));
}

/// What the handler should have been written as: the callback's own
/// signature with the erased context replaced by the typed state.
fn wantedSignature(comptime want: std.builtin.Type.Fn, comptime StatePtr: type) []const u8 {
    comptime var sig: []const u8 = "fn (" ++ @typeName(StatePtr);
    inline for (want.params[1..]) |p| sig = sig ++ ", " ++ @typeName(p.type.?);
    return sig ++ ") " ++ @typeName(want.return_type.?);
}

/// Equal types, or a handler whose error set is narrower than the one the
/// callback declares — including none at all, which is a handler that
/// cannot fail bound into a slot that tolerates failure.
fn returnFits(comptime Got: type, comptime Want: type) bool {
    if (Got == Want) return true;
    const w = switch (@typeInfo(Want)) {
        .error_union => |u| u,
        else => return false,
    };
    if (Got == w.payload) return true;
    return switch (@typeInfo(Got)) {
        .error_union => |g| g.payload == w.payload,
        else => false,
    };
}

const testing = std.testing;

test "bindAs fills a pair a nokre-free package could have declared" {
    // Declared here exactly as a domain port declares it: two fields, no
    // import, no knowledge that a framework exists.
    const Callback = struct {
        ctx: ?*anyopaque,
        call: *const fn (ctx: ?*anyopaque, result: u32) void,
    };
    const Screen = struct {
        seen: u32 = 0,
        fn onResult(self: *@This(), result: u32) void {
            self.seen += result;
        }
    };
    var screen: Screen = .{};
    const cb = bindAs(Callback, Screen.onResult, &screen);
    cb.call(cb.ctx, 7);
    cb.call(cb.ctx, 35);
    try testing.expectEqual(@as(u32, 42), screen.seen);
}

test "bindAs forwards two values and a non-void answer" {
    const Progress = struct {
        ctx: ?*anyopaque = null,
        call: ?*const fn (ctx: ?*anyopaque, done: u32, total: u32) bool = null,
    };
    const Meter = struct {
        last: u32 = 0,
        stop_at: u32 = 0,
        fn tick(self: *@This(), done: u32, total: u32) bool {
            self.last = done;
            return done < total and done < self.stop_at;
        }
    };
    var meter: Meter = .{ .stop_at = 3 };
    const p = bindAs(Progress, Meter.tick, &meter);
    try testing.expect(p.call.?(p.ctx, 1, 10));
    try testing.expect(!p.call.?(p.ctx, 4, 10));
    try testing.expectEqual(@as(u32, 4), meter.last);
}

test "a pair with no values past its context binds too" {
    const UserId = struct {
        ctx: ?*anyopaque = null,
        call: *const fn (ctx: ?*anyopaque) []const u8,
    };
    const Session = struct {
        id: []const u8,
        fn userId(self: *@This()) []const u8 {
            return self.id;
        }
    };
    var session: Session = .{ .id = "u_7" };
    const uid = bindAs(UserId, Session.userId, &session);
    try testing.expectEqualStrings("u_7", uid.call(uid.ctx));
}

test "fields beside the pair keep their declared defaults" {
    const Callback = struct {
        ctx: ?*anyopaque = null,
        call: ?*const fn (ctx: ?*anyopaque) void = null,
        tag: u32 = 9,
    };
    const S = struct {
        fn go(_: *@This()) void {}
    };
    var s: S = .{};
    const cb = bindAs(Callback, S.go, &s);
    try testing.expectEqual(@as(u32, 9), cb.tag);
}

test "a handler that cannot fail binds into a slot that tolerates failure" {
    const Builder = struct {
        ctx: ?*anyopaque = null,
        call: *const fn (ctx: ?*anyopaque, n: u32) anyerror!void,
    };
    const S = struct {
        got: u32 = 0,
        fn take(self: *@This(), n: u32) void {
            self.got = n;
        }
        fn refuse(_: *@This(), _: u32) error{Nope}!void {
            return error.Nope;
        }
    };
    var s: S = .{};
    const plain = bindAs(Builder, S.take, &s);
    try plain.call(plain.ctx, 5);
    try testing.expectEqual(@as(u32, 5), s.got);
    const narrow = bindAs(Builder, S.refuse, &s);
    try testing.expectError(error.Nope, narrow.call(narrow.ctx, 5));
}

test "the state pointer is the handler's own, so a const handler binds" {
    const Callback = struct {
        ctx: ?*anyopaque,
        call: *const fn (ctx: ?*anyopaque) u32,
    };
    const S = struct {
        n: u32,
        fn read(self: *const @This()) u32 {
            return self.n;
        }
    };
    var s: S = .{ .n = 11 };
    const cb = bindAs(Callback, S.read, &s);
    try testing.expectEqual(@as(u32, 11), cb.call(cb.ctx));
}

// The curated refusals cannot be asserted from a test — a `@compileError`
// is not catchable and `@compileError` inside a comptime branch still
// fires when the branch is analyzed. What *is* pinnable is that the
// checks are reachable and their text is built from real type names, so
// the messages stay in step with the types they name:
test "the wanted signature is printed against the typed state" {
    const Callback = struct {
        ctx: ?*anyopaque,
        call: *const fn (ctx: ?*anyopaque, value: []const u8) void,
    };
    const S = struct { n: u32 };
    const want = @typeInfo(callFnType(Callback, "call")).@"fn";
    const sig = comptime wantedSignature(want, *S);
    try testing.expect(std.mem.startsWith(u8, sig, "fn (*"));
    try testing.expect(std.mem.endsWith(u8, sig, ".S, []const u8) void"));
}

test "returnFits accepts narrowing and refuses a different answer" {
    try testing.expect(returnFits(void, void));
    try testing.expect(returnFits(void, anyerror!void));
    try testing.expect(returnFits(error{A}!void, anyerror!void));
    try testing.expect(!returnFits(u32, void));
    try testing.expect(!returnFits(error{A}!u32, anyerror!void));
    try testing.expect(!returnFits(anyerror!void, void));
}
