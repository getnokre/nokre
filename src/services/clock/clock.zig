//! clock — the wall clock, read when the app asks (docs/services.md).
//!
//! One verb: `now`, milliseconds since the Unix epoch, UTC. That is the
//! entire surface, and its shape is locale's — a small ambient platform
//! fact the app reads and folds into its own state.
//!
//! **Core stays clockless, and this does not change that.** A frame is a
//! function of state (docs/internals/pixel-model.md); a screen that
//! changed because time passed changed for a reason no golden can hold
//! still and no test can reproduce. So nothing in src/core or src/render
//! calls this, ever — that rule is what keeps "same viewport, same
//! bytes" true, and it is why the refusals that name a clock (no
//! animation, no fading scrollbar, no auto-clearing copy mark, no
//! velocity on the back gesture) are unmoved by this file's existence.
//! It is pkce's carve-out restated: a service is not core. What an app
//! does with a timestamp — stamp a note, compare two of them, decide a
//! token is stale — is app state, and the frame that renders it is a
//! frame that renders state, like every other.
//!
//! Read on demand, not cached at boot, which is where it parts company
//! with locale. A cached tag stays right until the shell says otherwise;
//! a cached instant is wrong immediately, and no callback could refresh
//! it because there is no ticker to run one. The read is a syscall the
//! OS has already made cheap (a vDSO read on Linux, the commpage on
//! Apple) — no allocation, no error path, nothing to settle — so it is
//! legal anywhere app code runs. Legal in `build` is not advisable in
//! `build`, though: a screen built from the clock differs on every
//! frame, which is a golden that cannot hold still and a diff nobody
//! can review. Read it in the action, keep what you read.
//!
//! What it refuses, and each refusal is somebody's feature elsewhere:
//! no monotonic clock (there is nothing to time — an app with no
//! animation and no ticker measures no durations for the framework's
//! sake, and a second clock is a second thing to explain), no timers,
//! no scheduling, no "call me in 30s" — a timer is a ticker, and a
//! nokre app at rest costs zero CPU; no time zone and no formatting —
//! the OS's zone database and date formatter are the platform locale
//! library docs/localization.md refuses for producing different bytes
//! on different OS versions. UTC in, an integer out; a human-readable
//! date is the app's to write, from a value that is the same number on
//! every platform.
//!
//! Nothing links, and nothing in a shell answers this: clipboard's
//! posture without even clipboard's C hook. The OS call is Zig's own on
//! every native family, so there is no header, no shell export, and no
//! `has_shell_hook` switch — a platform without a clock is not one of
//! the six. The web is the single import below.

const std = @import("std");
const builtin = @import("builtin");
const app_mod = @import("../../core/app.zig");
const services = @import("../services.zig");

const App = app_mod.App;
const is_wasm = builtin.cpu.arch == .wasm32;

// The web's whole leg: `Date.now()` through services.js, implemented by
// *both* instances the driver runs — a compute actor is the app's code
// and may stamp a reply, which is pkce's random import exactly
// (docs/internals/dom-edition.md). An f64 because that is what
// `Date.now()` is: a wasm i64 would arrive as a BigInt and make the
// glue carry a second number type to say the same thing.
//
// Named only from the read path below, so a module that never asks the
// time never names the import: there is no install at App.init and no
// export for glue to call, so an app calling `now` is the only thing
// that can pull it in. The comptime block at the foot of this file is
// what keeps that true while still compiling the leg.
extern fn nokre_clock_js_now() f64;

/// FILETIME as `GetSystemTimePreciseAsFileTime` fills it: 100-nanosecond
/// ticks since 1601-01-01 UTC, in two halves because the API predates a
/// 64-bit integer in this ABI. Declared here rather than imported, so
/// this file names its own OS call — pkce's `SystemFunction036` posture.
const FileTime = extern struct { low: u32, high: u32 };

/// The *precise* form, not `GetSystemTimeAsFileTime`: the plain one is
/// quantized to the ~15.6 ms scheduler tick, so two stamps taken either
/// side of real work can read as the same instant. Windows 8 and up,
/// which the shell already requires (`_WIN32_WINNT 0x0A00`), and
/// kernel32 is on every Windows link already — the shell calls into it
/// for `MultiByteToWideChar` alone.
extern "kernel32" fn GetSystemTimePreciseAsFileTime(out: *FileTime) callconv(.winapi) void;

/// Milliseconds since 1970-01-01T00:00:00Z, UTC. Never fails, never
/// allocates, and is never cached — the module doc says why reading it
/// inside `build` is legal and still a mistake.
///
/// Milliseconds because that is the resolution a person's events happen
/// at and the coarsest one a stamp can be written in without losing an
/// ordering: an i64 of them spans ±292 million years, where an i64 of
/// nanoseconds runs out in 2262 and buys precision no app that draws
/// text can spend. And the value can move *backwards* between two
/// calls — an NTP correction, a user setting the date — which is a fact
/// of wall clocks, not a bug to paper over with a monotonic twin.
pub fn now(app: *const App) i64 {
    if (comptime builtin.is_test) {
        return app.services.clock.state.?.read();
    } else if (comptime is_wasm) {
        // A lossy cast rather than a bare @intFromFloat: the host owns
        // this number, and NaN or an out-of-range answer from a broken
        // (or hostile) page would otherwise be undefined behavior. Both
        // land on a value instead — 0 for NaN, saturation for the rest.
        return std.math.lossyCast(i64, nokre_clock_js_now());
    } else if (comptime builtin.os.tag == .windows) {
        var ft: FileTime = undefined;
        GetSystemTimePreciseAsFileTime(&ft);
        const ticks = (@as(u64, ft.high) << 32) | @as(u64, ft.low);
        // Ticks to milliseconds, then 1601 to 1970 — std's own name for
        // the 369-year offset, never a hand-typed constant.
        return @as(i64, @intCast(ticks / 10_000)) + std.time.epoch.windows * std.time.ms_per_s;
    } else {
        // Zig 0.16 removed `std.time.milliTimestamp`, so each native
        // family names the OS call it already links — pkce's entropy
        // split. One call covers all four: clock_gettime is Apple,
        // Android and glibc/BSD alike, and `std.posix.system` is
        // whichever half of it this target actually has (libc's
        // declaration where libc is linked, the bare Linux syscall
        // where it is not — which is what check-targets' libc-less
        // objects compile).
        var ts: std.posix.timespec = undefined;
        // POSIX gives this two errors and neither is reachable here:
        // EINVAL is an unsupported clock id (REALTIME is mandatory
        // everywhere this compiles for) and EFAULT is a bad pointer.
        // Should one arrive anyway the answer is 0 — the epoch itself,
        // a value no device's clock reports and so recognizable in a
        // failure — never an invented plausible instant. locale's
        // empty-tag rule, applied to time.
        if (std.posix.errno(std.posix.system.clock_gettime(.REALTIME, &ts)) != .SUCCESS) return 0;
        return @as(i64, @intCast(ts.sec)) * std.time.ms_per_s +
            @divFloor(@as(i64, @intCast(ts.nsec)), std.time.ns_per_ms);
    }
}

/// What the App carries for this service: the mock under `zig test`,
/// nothing in release — the OS call keeps no handle, so this is
/// clipboard's `Stateless` rather than locale's cached half. There is
/// nothing to install and nothing to release: a clock is not a
/// subscription.
pub const Service = if (builtin.is_test) Mock else services.Stateless;

// ---- the deterministic test surface (docs/testing.md) ----
// Under `zig test` the mock is the only clock that exists, on every
// platform — the machine's real time is unreachable — which is what
// lets a screen that stamps an instant golden byte-for-byte. Time moves
// when the test says so and never otherwise.

/// The instant a test boots at unless it says otherwise:
/// 2020-01-01T00:00:00Z. Sane, so app-side date arithmetic behaves as it
/// would on a device, and obviously fake, because it is midnight on a
/// New Year to the millisecond — a reading no real device's clock has
/// ever produced, so a stamp that leaks into an assertion names itself.
pub const default_millis: i64 = 1_577_836_800_000;

/// The mock's heap half — allocated by App.init so its address survives
/// the by-value moves a stack App makes, the shape every mock here has.
pub const MockState = struct {
    gpa: std.mem.Allocator,
    millis: i64,
    read_count: usize = 0,

    fn read(self: *MockState) i64 {
        self.read_count += 1;
        return self.millis;
    }
};

/// One app's fake wall clock.
pub const Mock = struct {
    /// The heap half; null only before App.init.
    state: ?*MockState = null,
    /// The seed `mock()` took, applied by `init` — share's split.
    boot: Config = .{},

    pub const Config = struct {
        /// The wall clock at boot, in milliseconds since the Unix epoch.
        /// The default is a fixed, obviously fake instant
        /// (`default_millis`), so a test that cares about a date names
        /// one and a test that does not still gets the same number every
        /// run.
        millis: i64 = default_millis,
    };

    pub fn mock(config: Config) Mock {
        return .{ .boot = config };
    }

    pub fn init(self: *Mock, gpa: std.mem.Allocator) !void {
        const state = try gpa.create(MockState);
        state.* = .{ .gpa = gpa, .millis = self.boot.millis };
        self.state = state;
    }

    pub fn deinit(self: *Mock) void {
        const state = self.state orelse return;
        state.gpa.destroy(state);
        self.state = null;
    }

    /// Move the clock. Signed, because wall time is not monotonic: an
    /// NTP correction, a user setting the date, a laptop waking up in
    /// another country all move it, and backwards is one of the
    /// directions. An app that subtracts two stamps has to survive a
    /// negative difference, and a negative `ms` is how a test proves it
    /// does — which is the same reason there is no monotonic clock here
    /// to hide behind.
    pub fn advance(self: Mock, ms: i64) void {
        self.state.?.millis += ms;
    }

    /// What `clock.now(app)` answers right now. Looking does not count:
    /// a test reading the clock is not the app asking for it, and a
    /// reader that moved `reads` would make the count meaningless the
    /// moment a test asserted on it.
    pub fn now(self: Mock) i64 {
        return self.state.?.millis;
    }

    /// How many times the app has asked the time. A count, not a
    /// journal: every read of a stopped clock returns the same value, so
    /// the only thing an order could add is noise. What it makes
    /// assertable is the interesting half — that a screen read the clock
    /// once per action, or that a `build` never read it at all, which is
    /// the app-side spelling of core's own clocklessness.
    pub fn reads(self: Mock) usize {
        return self.state.?.read_count;
    }
};

// Force the read path to compile per target, and only where that is
// free (the secure_store/locale forcing, src/nokre.zig, with one extra
// condition). Nothing in this service is reached from App.init, so a
// build that does not read the clock leaves every leg below
// unanalyzed — and check-targets' objects are exactly such builds, so
// without this the six-target compile check would cover this file's
// externs not at all.
//
// The extra condition is the wasm import's. Forcing unconditionally
// would put `nokre_clock_js_now` in the import table of every module
// ever built, including every one that never asks the time, which is
// the property the extern's comment above exists to keep. A
// compile-only object is the one artifact that never ships and never
// instantiates, so forcing there costs nothing and buys the check on
// all six targets — including the web leg, which has no other.
comptime {
    if (!builtin.is_test and builtin.output_mode == .Obj) _ = &now;
}
