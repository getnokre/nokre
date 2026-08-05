//! secure_store — encrypted key/value for small secrets: get, set,
//! delete, list (docs/services.md; internals in
//! docs/internals/secure_store.md).
//!
//! Synchronous, like package_info: a secret is local state, and every
//! backend answers in-process — Keychain, Credential Manager, the
//! Android Keystore (a Keystore-wrapped store reached over JNI), and
//! (on web) an in-memory table seeded from sessionStorage before boot.
//! Which of them a binary carries is build.zig's to decide and this
//! file's not to know: a driver binary may declare the dev file store
//! and get dev.c behind the same four native verbs, with everything
//! below unchanged (docs/internals/secure_store.md).
//! Tokens and locale are boot reads, and nokre has no tickers to
//! retire the loading frame an async boot read would strand — so a
//! read at app boot is one call, inside build, no handshake.
//!
//! The caps below are the contract that makes outcomes equal on every
//! platform. The value ceiling is a platform's — Windows' credential
//! blob, the one native bound tighter than a keychain's — and every
//! platform enforces that same number on the Zig side, so
//! ValueTooLarge means one thing everywhere. The entry cap is nokre's
//! own: no backend counts entries, so what bounds it is the
//! caller-owned buffers a listing lands in. Both are derived, not
//! rounded (docs/services.md's per-platform table).

const std = @import("std");
const builtin = @import("builtin");
const options = @import("nokre_secure_store_options");
const app_mod = @import("../../core/app.zig");

const App = app_mod.App;
const is_wasm = builtin.cpu.arch == .wasm32;
// Under `zig test` the fake path is the only path — comptime, so test
// builds never reference the native externs and `zig build test`
// stays dependency-free.
const native = if (is_wasm or builtin.is_test) struct {} else @import("native.zig");
const web = if (is_wasm and !builtin.is_test) @import("web.zig") else struct {};

// The platforms whose backend is the native nokre_ss_* extern leg
// (native.zig): Keychain on macOS/iOS, Credential Manager on Windows,
// a Keystore-wrapped store reached over JNI on Android (android.c →
// NokreSecureStore.java), and the Secret Service on desktop Linux
// (linux.c → libsecret). Android and desktop Linux both report
// os.tag == .linux; they answer the same nokre_ss_* contract and differ
// only in which C file build.zig compiles behind it, so one tag selects
// both.
const native_os = switch (builtin.os.tag) {
    .macos, .ios, .windows, .linux => true,
    else => false,
};

pub const max_key_bytes = 128;

/// Exactly Windows' `CRED_MAX_CREDENTIAL_BLOB_SIZE` (wincred.h,
/// `5 * 512`) — the tightest bound any linked backend imposes, so it
/// sets the ceiling for all of them; windows.c `#error`s if the two
/// ever part company. Not rounded down to a power of two: a ceiling
/// that is the platform's own number says where the line honestly
/// falls, and 512 bytes of secret is 512 bytes of secret.
pub const max_value_bytes = 2560;

/// nokre's number, not any platform's — no backend counts entries (a
/// keychain is a SQLite table, CredMan a folder, SharedPreferences a
/// map), so what bounds this is the caller-owned buffers a listing
/// lands in. Sized from the first real consumer: three entries per
/// (cycle, channel) pair, and a user in a dozen circles plus a dozen
/// connections is 24 pairs — 72 entries, which is why 64 refused. 256
/// carries 85 such triples; past that the shape being stored is a
/// document store, not a pouch (docs/internals/secure_store.md).
pub const max_entries = 256;

/// One value, caller-owned: 2.5 KiB of frame, the shape every verb
/// takes.
pub const ValueBuf = [max_value_bytes]u8;

/// A whole listing, caller-owned: 36 KiB at the caps — 32 KiB of key
/// bytes plus 4 KiB of slices. Frame-sized, not a stack hazard (the
/// tightest main thread nokre ships to is 1 MiB), but big enough to be
/// worth one declaration per action rather than one per loop. It stays
/// a caller buffer: an allocator here would be the only one in the
/// service, and `list` is not where nokre starts allocating.
pub const ListBuf = struct {
    bytes: [max_entries * max_key_bytes]u8 = undefined,
    slices: [max_entries][]const u8 = undefined,
};

// Closed, per-operation error sets. InvalidKey / ValueTooLarge /
// StoreFull are pure functions of the arguments and the caps, checked
// in Zig before any OS call — producible identically on every
// platform by passing such arguments (nothing to inject). Only
// Unavailable is environmental: a locked or denying keychain, a dead
// logon session on Windows, an absent Secret Service session on Linux,
// a Keystore fault on Android. It never occurs on web — the in-memory table
// always answers; that asymmetry is stated posture, not a bug.
pub const GetError = error{ InvalidKey, Unavailable };
pub const SetError = error{ InvalidKey, ValueTooLarge, StoreFull, Unavailable };
pub const DeleteError = error{ InvalidKey, Unavailable };
pub const ListError = error{Unavailable};

/// True iff `key` is storable: 1..max_key_bytes of [a-z0-9._-].
/// Lowercase-only because Windows credential target names are
/// case-insensitive — "Token" and "token" would be one entry there
/// and two everywhere else; the charset makes that divergence
/// unrepresentable. The set also survives verbatim as a Keychain
/// account, a UTF-16 CredMan target segment, a libsecret attribute,
/// and a JS storage key — one namespace rule, zero escaping — and
/// bytewise sort order equals human sort order for list.
pub fn validKey(key: []const u8) bool {
    if (key.len == 0 or key.len > max_key_bytes) return false;
    for (key) |c| if (!validKeyByte(c)) return false;
    return true;
}

/// The per-byte half of `validKey` — exported so a consumer escaping
/// foreign ids into this charset derives the set instead of
/// transcribing it.
pub fn validKeyByte(c: u8) bool {
    return switch (c) {
        'a'...'z', '0'...'9', '.', '_', '-' => true,
        else => false,
    };
}

/// Read one value into `buf`; the returned slice aliases it (reuse
/// invalidates). `null` is absence — a missing key is data, like a
/// 404, never a failure — and an empty slice is a present, empty
/// value. `app` is the store's scope in tests (each app's mock is its
/// own store); every call site already holds it, and a `*const App` is
/// enough — reading the store changes nothing about the app, which is
/// why every read-only service verb takes one (`share.available`,
/// `clock.now`, `locale.tag`). The mock's journal still records the
/// read: it hangs off a pointer field, so the app's constness never
/// reached it.
pub fn get(app: *const App, key: []const u8, buf: *ValueBuf) GetError!?[]const u8 {
    checkLinked();
    if (!validKey(key)) return error.InvalidKey;
    if (comptime builtin.is_test) return app.services.secure_store.state.?.svcGet(key, buf);
    if (comptime is_wasm) return web.get(key, buf);
    if (comptime native_os) return native.get(key, buf);
    // No backend for this OS (bare-metal targets outside the shipping
    // set): Unavailable is the honest posture, and a consumer that
    // handles it degrades gracefully wherever a store is absent.
    return error.Unavailable;
}

/// Upsert; caps are checked before the OS is asked. Writing an
/// existing key never fails with StoreFull; the key past `max_entries`
/// does — on every platform, because the count check runs here, not
/// natively. Both slices are borrowed only for the call.
pub fn set(app: *App, key: []const u8, value: []const u8) SetError!void {
    checkLinked();
    if (!validKey(key)) return error.InvalidKey;
    if (value.len > max_value_bytes) return error.ValueTooLarge;
    if (comptime builtin.is_test) return app.services.secure_store.state.?.svcSet(key, value);
    if (comptime is_wasm) {
        if (!web.contains(key) and web.count() == max_entries) return error.StoreFull;
        return web.set(key, value);
    }
    if (comptime native_os) {
        // A targeted probe classifies the write as insert or overwrite
        // (an existing key never fails with StoreFull); only an insert
        // consults the count, so the key past `max_entries` fails on
        // the Zig side — identically on a keychain, in CredMan, in the
        // Android Keystore store, in the web table, and in the MockState.
        // The count is the app's cache (see `CountCache`), seeded by
        // one enumeration on the first insert instead of a full
        // list + sort per write.
        var probe: ValueBuf = undefined;
        const exists = (try native.get(key, &probe)) != null;
        if (!exists) {
            const cache = &app.services.secure_store.count;
            if (cache.* == null) {
                var lb: ListBuf = undefined;
                cache.* = (try native.list(&lb)).len;
            }
            const count = cache.*.?;
            if (count >= max_entries) return error.StoreFull;
            try native.set(key, value);
            cache.* = count + 1;
            return;
        }
        return native.set(key, value);
    }
    return error.Unavailable;
}

/// Idempotent: deleting an absent key succeeds. The promise is the
/// postcondition ("no such entry"), not the transition — retries and
/// sign-out-twice cost nothing to reason about.
pub fn delete(app: *App, key: []const u8) DeleteError!void {
    checkLinked();
    if (!validKey(key)) return error.InvalidKey;
    if (comptime builtin.is_test) return app.services.secure_store.state.?.svcDelete(key);
    if (comptime is_wasm) return web.delete(key);
    if (comptime native_os) {
        const cache = &app.services.secure_store.count;
        if (cache.*) |n| {
            // The count only moves when a *present* key is removed —
            // deleting an absent one is the postcondition already met.
            // A probe that itself fails leaves presence unknown, so the
            // cache is dropped (the next insert reseeds it) rather than
            // guessed at; saturating in case an outside writer drifted
            // the cache below reality.
            var probe: ValueBuf = undefined;
            const present = native.get(key, &probe) catch blk: {
                cache.* = null;
                break :blk null;
            };
            try native.delete(key);
            if (cache.* != null and present != null) cache.* = n -| 1;
            return;
        }
        return native.delete(key);
    }
    return error.Unavailable;
}

/// Every key under this app's namespace, bytewise ascending, keys
/// only (values stay behind get). Sorted on the Zig side: no OS
/// promises an enumeration order, and list must be deterministic.
/// Slices alias `buf`.
pub fn list(app: *const App, buf: *ListBuf) ListError![]const []const u8 {
    checkLinked();
    if (comptime builtin.is_test) return app.services.secure_store.state.?.svcList(buf);
    if (comptime is_wasm) return web.list(buf);
    if (comptime native_os) return native.list(buf);
    return error.Unavailable;
}

fn checkLinked() void {
    // Tests always run against the per-app MockState (the app's injected
    // mock) and the fake path is the only compiled path under
    // builtin.is_test — requiring linking there would demand frameworks
    // test code cannot reach. A release build that skipped linking
    // still cannot ship: the curated error below is unskippable and
    // names the one-line fix.
    comptime if (!options.linked and !builtin.is_test) @compileError(
        \\the secure_store service is not linked. Pass .secure_store = true
        \\(alongside .pkg_id — the store is namespaced by the app's identity)
        \\to the nokre dependency in build.zig. docs/services.md.
    );
}

// ---- the deterministic test surface (docs/testing.md) ----
// Plain unconditional code: production references none of it, so it
// dead-strips — while the four verbs above route to the app's mock
// behind `comptime builtin.is_test`, so under `zig test` the MockState is
// the only store that exists.

pub const Seed = struct { key: []const u8, value: []const u8 };

/// One recorded call, program order — for asserting what the app
/// *did* to its secrets, not just what ended up stored ("signs
/// out without rewriting the token" is a journal assertion).
/// Slices are owned copies held by the MockState.
pub const Op = union(enum) {
    get: []const u8,
    set: struct { key: []const u8, value: []const u8 },
    delete: []const u8,
    list,
};

/// What the App carries for this service: the mock under `zig test`;
/// otherwise the cached entry count behind the entry cap — the one
/// piece of per-app release state this service keeps. (The web leg
/// never reads it: its in-process table answers `count()` directly.)
pub const Service = if (builtin.is_test) Mock else CountCache;

/// The cap's bookkeeping, cached so `set` need not enumerate + sort
/// the whole namespace (72 KiB of frame in native.list, plus a
/// ListBuf) on every insert: seeded by one enumeration on the first insert,
/// adjusted on each successful insert and present-key delete. A
/// cross-process writer under the same namespace can drift it — but
/// the enumerate-then-set it replaces was not atomic against one
/// either, so the cap stays what it always was: exact for this app's
/// own writes, best-effort against outside ones.
pub const CountCache = struct {
    /// null until the first insert seeds it (or after a failed delete
    /// probe drops it — see `delete`).
    count: ?usize = null,

    pub fn init(self: *CountCache, gpa: std.mem.Allocator) !void {
        _ = self;
        _ = gpa;
    }

    pub fn deinit(self: *CountCache) void {
        _ = self;
    }
};

/// One app's fake store, constructed into `.services`: seeds and the
/// availability knob are boot state — applied inside App.init, so a
/// boot-time read inside `build` sees them synchronously. App.deinit
/// frees the MockState; nothing leaks to the next test.
pub const Mock = struct {
    boot: Config = .{},
    /// The heap half (move-safe across the by-value returns a stack
    /// App makes); null only before App.init.
    state: ?*MockState = null,

    /// The store's state at app boot — a populated keychain, or a
    /// locked one (`available = false`).
    pub const Config = struct {
        seeds: []const Seed = &.{},
        available: bool = true,
    };

    pub fn mock(config: Config) Mock {
        return .{ .boot = config };
    }

    pub fn init(self: *Mock, gpa: std.mem.Allocator) !void {
        const state = try gpa.create(MockState);
        errdefer gpa.destroy(state);
        state.* = MockState.init(gpa);
        errdefer state.deinit();
        for (self.boot.seeds) |s| try state.seed(s.key, s.value);
        state.available = self.boot.available;
        self.state = state;
    }

    pub fn deinit(self: *Mock) void {
        const state = self.state orelse return;
        const g = state.gpa;
        state.deinit();
        g.destroy(state);
        self.state = null;
    }
};

/// One app's whole store: entries, journal, and knobs — never shared,
/// never global: two concurrently-driven apps get two of these with
/// disjoint everything, by construction.
///
/// Journal semantics: every call that passes argument validation
/// is journaled — knob-failed calls and a StoreFull set included;
/// InvalidKey / ValueTooLarge never reach the store on any
/// platform, so they are never journaled either.
pub const MockState = struct {
    gpa: std.mem.Allocator,
    entries: std.ArrayList(Entry) = .empty, // kept sorted by key — list() order is the storage order
    ops: std.ArrayList(Op) = .empty,
    /// Behavior injection — only Unavailable is injectable,
    /// because the other three errors are pure functions of the
    /// arguments: produce InvalidKey by passing "Bad Key!",
    /// StoreFull by seeding `max_entries`. Closed knobs, no callbacks.
    available: bool = true, // false: every call Unavailable
    fail_writes: bool = false, // reads fine; set/delete Unavailable
    fail_next: u32 = 0, // next N calls Unavailable, then clears
    /// Contiguous view of entries' keys, maintained on mutation so
    /// keys() answers from a *const MockState without allocating.
    key_views: [max_entries][]const u8 = undefined,

    pub const Entry = struct { key: []u8, value: []u8 };

    pub fn init(gpa: std.mem.Allocator) MockState {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *MockState) void {
        for (self.entries.items) |e| {
            self.gpa.free(e.key);
            self.gpa.free(e.value);
        }
        self.entries.deinit(self.gpa);
        self.clearJournal();
        self.ops.deinit(self.gpa);
    }

    /// Test-side write: bypasses the knobs and the journal, but
    /// enforces the real caps — a test cannot seed a state no
    /// device could hold; a forbidden seed is a test bug, loudly.
    pub fn seed(self: *MockState, key: []const u8, value: []const u8) !void {
        if (!validKey(key)) return error.InvalidKey;
        if (value.len > max_value_bytes) return error.ValueTooLarge;
        if (self.find(key)) |i| {
            const fresh = try self.gpa.dupe(u8, value);
            self.gpa.free(self.entries.items[i].value);
            self.entries.items[i].value = fresh;
            return;
        }
        if (self.entries.items.len == max_entries) return error.StoreFull;
        try self.insertNew(key, value);
    }

    /// What the app persisted; null = absent. Borrowed view.
    pub fn peek(self: *const MockState, key: []const u8) ?[]const u8 {
        const i = self.find(key) orelse return null;
        return self.entries.items[i].value;
    }

    pub fn count(self: *const MockState) usize {
        return self.entries.items.len;
    }

    /// Bytewise ascending — identical to what list() shows the app.
    pub fn keys(self: *const MockState) []const []const u8 {
        return self.key_views[0..self.entries.items.len];
    }

    /// Every call the app made, in order.
    pub fn journal(self: *const MockState) []const Op {
        return self.ops.items;
    }

    pub fn clearJournal(self: *MockState) void {
        for (self.ops.items) |op| switch (op) {
            .get, .delete => |k| self.gpa.free(k),
            .set => |s| {
                self.gpa.free(s.key);
                self.gpa.free(s.value);
            },
            .list => {},
        };
        self.ops.clearRetainingCapacity();
    }

    // ---- the service side (reached only through the verbs) ----

    fn svcGet(self: *MockState, key: []const u8, buf: *ValueBuf) GetError!?[]const u8 {
        self.record(.{ .get = self.own(key) });
        if (self.knobFailed(false)) return error.Unavailable;
        const i = self.find(key) orelse return null;
        const v = self.entries.items[i].value;
        @memcpy(buf[0..v.len], v);
        return buf[0..v.len];
    }

    fn svcSet(self: *MockState, key: []const u8, value: []const u8) SetError!void {
        self.record(.{ .set = .{ .key = self.own(key), .value = self.own(value) } });
        if (self.knobFailed(true)) return error.Unavailable;
        if (self.find(key)) |i| {
            const fresh = self.gpa.dupe(u8, value) catch oom();
            self.gpa.free(self.entries.items[i].value);
            self.entries.items[i].value = fresh;
            return;
        }
        if (self.entries.items.len == max_entries) return error.StoreFull;
        self.insertNew(key, value) catch oom();
    }

    fn svcDelete(self: *MockState, key: []const u8) DeleteError!void {
        self.record(.{ .delete = self.own(key) });
        if (self.knobFailed(true)) return error.Unavailable;
        const i = self.find(key) orelse return;
        const e = self.entries.orderedRemove(i);
        self.gpa.free(e.key);
        self.gpa.free(e.value);
        self.refreshViews();
    }

    fn svcList(self: *MockState, buf: *ListBuf) ListError![]const []const u8 {
        self.record(.list);
        if (self.knobFailed(false)) return error.Unavailable;
        var off: usize = 0;
        for (self.entries.items, 0..) |e, i| {
            @memcpy(buf.bytes[off..][0..e.key.len], e.key);
            buf.slices[i] = buf.bytes[off..][0..e.key.len];
            off += e.key.len;
        }
        return buf.slices[0..self.entries.items.len];
    }

    // Knob precedence: a store that is down is down — fail_next
    // only counts calls that would otherwise have been served.
    fn knobFailed(self: *MockState, write: bool) bool {
        if (!self.available) return true;
        if (self.fail_next > 0) {
            self.fail_next -= 1;
            return true;
        }
        return write and self.fail_writes;
    }

    fn find(self: *const MockState, key: []const u8) ?usize {
        for (self.entries.items, 0..) |e, i| {
            if (std.mem.eql(u8, e.key, key)) return i;
        }
        return null;
    }

    fn insertNew(self: *MockState, key: []const u8, value: []const u8) !void {
        const k = try self.gpa.dupe(u8, key);
        errdefer self.gpa.free(k);
        const v = try self.gpa.dupe(u8, value);
        errdefer self.gpa.free(v);
        var i: usize = 0;
        while (i < self.entries.items.len and
            std.mem.lessThan(u8, self.entries.items[i].key, key)) i += 1;
        try self.entries.insert(self.gpa, i, .{ .key = k, .value = v });
        self.refreshViews();
    }

    fn refreshViews(self: *MockState) void {
        for (self.entries.items, 0..) |e, i| self.key_views[i] = e.key;
    }

    fn record(self: *MockState, op: Op) void {
        self.ops.append(self.gpa, op) catch oom();
    }

    fn own(self: *MockState, bytes: []const u8) []const u8 {
        return self.gpa.dupe(u8, bytes) catch oom();
    }

    // The verbs' error sets are the contract's, closed — a test
    // allocator giving out is not a store outcome, so it is a
    // crash, not a new error name.
    fn oom() noreturn {
        @panic("secure_store fake: allocator failed");
    }
};

// The design-proof that each linked backend actually compiles:
// check-targets' linked objects never call the verbs, and lazy
// analysis would skip bodies nothing references — taking the fns'
// addresses forces full analysis of the per-target backend on every
// OS tag (the same forcing the web shell's export block relies on,
// src/nokre.zig).
comptime {
    if (options.linked and !builtin.is_test) {
        if (is_wasm) {
            _ = &web.get;
            _ = &web.set;
            _ = &web.delete;
            _ = &web.list;
        } else if (native_os) {
            _ = &native.get;
            _ = &native.set;
            _ = &native.delete;
            _ = &native.list;
        }
    }
}
