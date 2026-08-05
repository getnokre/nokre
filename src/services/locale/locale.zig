//! locale — the device's BCP 47 tag at boot, and its changes
//! (docs/services.md).
//!
//! Inbound like deep_link, installed the same way, but it answers a
//! question the app asks *during* `build`: which of the bundle's
//! locales to speak. So the tag is cached in the app's own state rather
//! than read from the OS on demand — `tag(app)` is allocation-free,
//! infallible, and not a syscall, because `build` runs on every frame
//! and a per-frame CFLocaleCopyCurrent / getResources().getConfiguration()
//! is not what a frame budget is for. Freshness is the shell's job, not
//! a poll's: it fires the callback on every OS locale change, so the
//! cache is stale only between a change and the callback the shell
//! already had to send.
//!
//! Install happens in `init` (App.init), not lazily at `setHandler`,
//! because the boot read must be warm before the first `build` runs:
//! nokre has no ticker to retire a loading frame an async boot read
//! would strand (secure_store's argument), and a first-use install
//! would fire the boot callback in the middle of the `build` that
//! triggered it — reentrancy the app never asked for. `setHandler` is
//! therefore only the change lane, and stays optional: an app that
//! reads the tag once at boot registers nothing at all.
//!
//! Unknown or absent is the empty tag, never an invented "en". Empty is
//! what a bundle already handles: `Bundle.resolve("")` matches no tag
//! and no bare language, so it returns the template locale
//! (src/l10n/l10n.zig) — the app's own source language, the only
//! defensible guess. Inventing "en" would instead resolve to the
//! *English* catalog of a bundle whose template is Persian, silently
//! choosing a language nobody asked for. `l10n.directionOfTag("")` is
//! `.ltr` on the same grounds, and is what `App.setDirection` takes
//! (docs/localization.md).
//!
//! Nothing links: no framework, no entitlement, no permission, no
//! identity. The tag rides the shell the way the clipboard does
//! (docs/services.md), so there is no build flag, no options module,
//! and no curated unlinked error — a target whose shell has no hook
//! simply reports the empty tag. Web parity is `navigator.language`,
//! seeded into wasm strictly before boot and pushed again on
//! `languagechange` (docs/internals/platform-shells.md).

const std = @import("std");
const builtin = @import("builtin");
const app_mod = @import("../../core/app.zig");
const services = @import("../services.zig");

const App = app_mod.App;
const is_wasm = builtin.cpu.arch == .wasm32;

// The web leg owns the seed/receive exports live.js drives; native legs
// implement `nokre_locale_install` in the shell itself
// (src/platform/<plat>/shell.{m,c}). Under `zig test` neither is
// referenced — the mock is the only path — so tests stay
// dependency-free, deep_link's rule.
const web = if (is_wasm and !builtin.is_test) @import("web.zig") else struct {};

/// Whether this target's shell provides the install hook. Referenced
/// only where true, so stub targets never name the extern — clipboard's
/// posture, and the reason locale needs no build flag to stay optional.
const has_shell_hook = switch (builtin.os.tag) {
    // .linux covers both the Android JNI shell and the desktop Wayland
    // shell; both export nokre_locale_install.
    .macos, .ios, .windows, .linux => true,
    else => false,
};

/// The cached tag's cap. RFC 5646 puts no useful bound on a tag —
/// extensions and private use can run on — but a *device* tag is a
/// language, an optional script, and a region ("zh-Hant-TW",
/// "ca-ES-valencia" is already an outlier), so 64 bytes is slack of
/// roughly four times. Over the cap the tag is stored as empty rather
/// than truncated: a truncated tag still resolves, and resolves to the
/// wrong locale, whereas empty resolves to the template — the failure
/// that is legible instead of the one that ships in the wrong language.
pub const max_tag_bytes = 64;

/// What `setHandler` registers. `ctx` is the app's — cast it back to
/// whatever holds the app state. `tag` is the new device tag, borrowed
/// only for the call and identical to what `tag(app)` returns from here
/// on; copy it to keep it. Called on the UI thread, once per change.
pub const Handler = *const fn (ctx: ?*anyopaque, tag: []const u8) void;

/// The C ABI the shell (or the web leg) fires. `receiveC` is the one
/// instance, installed once with the app's per-service state as `ctx`.
const CCallback = *const fn (ctx: ?*anyopaque, tag: [*]const u8, len: usize) callconv(.c) void;

// Implemented natively by each C-contract shell (src/services/locale/
// locale.h): it stores ctx + cb, fires cb synchronously with the
// current tag during this call, then fires it on the main thread for
// every OS locale change. Named only from the linked, non-test,
// non-wasm path, so test and hookless builds never reference it.
extern fn nokre_locale_install(ctx: ?*anyopaque, cb: CCallback) void;
// The shell forgets the stored ctx + cb; change notifications after this
// are dropped, not delivered. Same reference rules as the install.
extern fn nokre_locale_uninstall() void;

/// The device locale as a BCP 47 tag, or "" when the platform has none
/// to give. Read it inside `build` and hand it straight to the bundle:
/// `const L = Strings.resolve(locale.tag(app))`. Cached, so this is a
/// slice of app state — no allocation, no OS call, no error, and stable
/// until the next change callback.
pub fn tag(app: *const App) []const u8 {
    return app.services.locale.state.?.slice();
}

/// Register the locale-change handler — the *change* lane only; the
/// boot tag is already warm by the time any `build` could call this
/// (the install runs in App.init). Call it once, inside `build`;
/// registering again replaces the handler, so a rebuild re-registering
/// the same one is idempotent. The service does not invalidate for you:
/// what a new locale changes is the app's business (re-resolving the
/// bundle, `App.setDirection`), and the shell has already asked for the
/// frame — deep_link's split.
pub fn setHandler(app: *App, ctx: ?*anyopaque, handler: Handler) void {
    const state = app.services.locale.state.?;
    state.handler = handler;
    state.handler_ctx = ctx;
}

/// The single installed C trampoline: `ctx` is the per-service state, so
/// no global is consulted. Runs on the UI thread (the shell's promise),
/// and once *during* install, before App.init returns.
fn receiveC(ctx: ?*anyopaque, t: [*]const u8, len: usize) callconv(.c) void {
    const state: *PlatformState = @ptrCast(@alignCast(ctx.?));
    state.receive(t[0..len]);
}

/// What the App carries for this service: the journaling mock under
/// `zig test`, the tag-caching platform state in release. Both
/// heap-allocate that state in `init`, because the native install hands
/// its address to the shell and it must survive the by-value moves a
/// stack App makes.
pub const Service = if (builtin.is_test) Mock else PlatformService;

/// Release-side per-app state: the cached tag and the registered
/// handler. `receive` is what the shell's callback reaches — the mock's
/// twin of it is the same function under a different roof.
const PlatformState = struct {
    buf: [max_tag_bytes]u8 = undefined,
    len: usize = 0,
    handler: ?Handler = null,
    handler_ctx: ?*anyopaque = null,

    fn slice(self: *const PlatformState) []const u8 {
        return self.buf[0..self.len];
    }

    fn receive(self: *PlatformState, t: []const u8) void {
        self.len = store(&self.buf, t);
        // The boot fire lands here with no handler registered — that is
        // the point: the cache is warm, and nobody is called back for a
        // value that was never a change.
        if (self.handler) |h| h(self.handler_ctx, self.slice());
    }
};

const PlatformService = struct {
    state: ?*PlatformState = null,
    gpa: std.mem.Allocator = undefined,

    pub fn init(self: *PlatformService, gpa: std.mem.Allocator) !void {
        const state = try gpa.create(PlatformState);
        state.* = .{};
        self.state = state;
        self.gpa = gpa;
        // Installing here, inside App.init, is what makes the boot tag
        // synchronous: the callback fires before this returns. A target
        // with no hook keeps the empty tag, which resolves to the
        // template — an absent locale source is not an error.
        if (comptime is_wasm) {
            web.install(state, receiveC);
        } else if (comptime has_shell_hook) {
            nokre_locale_install(state, receiveC);
        }
    }

    pub fn deinit(self: *PlatformService) void {
        const state = self.state orelse return;
        // The shell holds this state as the installed ctx and fires it
        // on every OS locale change; a change landing after teardown —
        // or into a second App lifetime — must find no callback, not
        // freed memory. oauth's release-on-deinit rule.
        if (comptime is_wasm) {
            web.uninstall();
        } else if (comptime has_shell_hook) {
            nokre_locale_uninstall();
        }
        self.gpa.destroy(state);
        self.state = null;
    }
};

/// The cap rule in one place, so the mock truncates exactly as the
/// platform does: over `max_tag_bytes` stores nothing (see the constant).
fn store(buf: *[max_tag_bytes]u8, t: []const u8) usize {
    if (t.len > max_tag_bytes) return 0;
    @memcpy(buf[0..t.len], t);
    return t.len;
}

// ---- the deterministic test surface (docs/testing.md) ----
// One app's fake locale source: the config seeds the tag the OS reports
// at boot (fired inside App.init, exactly where a shell's install fires
// it), `change` is every OS locale change after, and the journal is
// every tag the device ever reported, in order — so "the app rendered
// before the boot locale arrived" is not a state a test can be fooled
// by, and "the app ignored the change" is assertable.

/// The mock's heap half, allocated by App.init so its address is stable
/// across the by-value moves a stack App makes.
pub const MockState = struct {
    gpa: std.mem.Allocator,
    buf: [max_tag_bytes]u8 = undefined,
    len: usize = 0,
    handler: ?Handler = null,
    handler_ctx: ?*anyopaque = null,
    seen: std.ArrayList([]u8) = .empty,

    fn slice(self: *const MockState) []const u8 {
        return self.buf[0..self.len];
    }

    fn receive(self: *MockState, t: []const u8) void {
        self.len = store(&self.buf, t);
        // The journal records the *effective* tag — after the cap — so
        // it always shows what the app could have read, never a value
        // that only existed in the test's argument list. A test
        // allocator giving out is a crash, not an outcome.
        const owned = self.gpa.dupe(u8, self.slice()) catch @panic("locale mock: allocator failed");
        self.seen.append(self.gpa, owned) catch @panic("locale mock: allocator failed");
        if (self.handler) |h| h(self.handler_ctx, self.slice());
    }
};

pub const Mock = struct {
    boot: Config = .{},
    /// The heap half; null only before App.init.
    state: ?*MockState = null,

    /// The device locale at app boot. The default is the empty tag —
    /// the honest "this platform told us nothing", which resolves to
    /// the bundle's template — so a test that cares about a language
    /// must name it.
    pub const Config = struct {
        tag: []const u8 = "",
    };

    pub fn mock(config: Config) Mock {
        return .{ .boot = config };
    }

    pub fn init(self: *Mock, gpa: std.mem.Allocator) !void {
        const state = try gpa.create(MockState);
        state.* = .{ .gpa = gpa };
        self.state = state;
        // Boot state, applied inside App.init: the seeded tag is
        // readable by the first `build`, and journaled, exactly as a
        // shell's synchronous install-time fire would be.
        state.receive(self.boot.tag);
    }

    pub fn deinit(self: *Mock) void {
        const state = self.state orelse return;
        for (state.seen.items) |t| state.gpa.free(t);
        state.seen.deinit(state.gpa);
        state.gpa.destroy(state);
        self.state = null;
    }

    /// The OS changed the device locale. Updates the cached tag and
    /// routes it to the registered handler on this thread, now —
    /// synchronous, like the store; there is nothing to settle.
    pub fn change(self: Mock, t: []const u8) void {
        self.state.?.receive(t);
    }

    /// The tag `locale.tag(app)` currently returns.
    pub fn tag(self: Mock) []const u8 {
        return self.state.?.slice();
    }

    /// Every tag the device reported, in order, starting with the boot
    /// tag — borrowed views. The boot entry is always present, so "the
    /// app never saw a locale" and "the app saw the empty tag" stay
    /// distinguishable.
    pub fn seen(self: Mock) []const []const u8 {
        return services.borrowed(self.state.?.seen.items);
    }

    /// Whether the app registered a change handler — a `change` before
    /// this is true went unnoticed by the app.
    pub fn hasHandler(self: Mock) bool {
        return self.state.?.handler != null;
    }
};

// Force the install path to compile per target (the secure_store
// forcing, src/nokre.zig): under check-targets' compile-only objects
// nothing references App.init, so PlatformService.init — and with it
// the native `nokre_locale_install` or the wasm `web.install` — would go
// unanalyzed, and nothing references the web seed/receive exports
// either, which lazy analysis would then drop from the wasm module.
// Guarded on `!is_test` only (locale has no linked/unlinked split), so
// test binaries never name a symbol they would have to link.
comptime {
    if (!builtin.is_test) {
        _ = &PlatformService.init;
        _ = &PlatformService.deinit;
        if (is_wasm) {
            _ = &web.nokre_locale_scratch;
            _ = &web.nokre_locale_seed;
            _ = &web.nokre_locale_receive;
        }
    }
}
