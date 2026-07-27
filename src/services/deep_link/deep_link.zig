//! deep_link — inbound URLs at launch and while running (docs/services.md).
//!
//! An App Link (Android) / Universal Link (iOS) / URL-fragment (web)
//! arrives, and the app decides what screen it means. nokre delivers
//! the URL and stops there: routing is the app's job — the same split as
//! the router, which owns *where* a route goes while deep_link owns *that
//! a URL came in*. One `setHandler`, one delivery lane: the launch URL (if
//! the app was opened by a link) is the first callback after boot, then
//! every runtime link, each on the UI thread, interleaved with shell
//! events like a worker reply.
//!
//! Inbound, so the shape inverts secure_store's: there the app calls the
//! OS, here the OS calls the app. The service hands the shell a ctx + a
//! callback (`nokre_deep_link_install`, the worker-wake shape); the shell
//! stores them and fires the callback on the main thread for the launch
//! URL (buffered until install) and each URL after. The state the
//! callback reaches is heap-pinned on the App, never a module-global —
//! the injected-services rule (docs/internals/architecture.md).
//!
//! Web parity is the fragment: live.js delivers `location.href` after
//! boot (when the page loaded with a fragment) and on every `hashchange`
//! through `nokre_deep_link_receive` (docs/internals/platform-shells.md)
//! — alongside the router's own reading of the fragment as navigation,
//! deliberately: the two answer different questions, and an app that
//! both links this service and routes on the fragment sees it twice
//! (docs/routing.md says to route on one or the other).
//! The packaging half — the iOS
//! entitlement + apple-app-site-association and the Android intent-filter
//! + assetlinks.json that make the OS route a public https URL here — is
//! derived from the claimed domains (src/packaging/packaging.zig).

const std = @import("std");
const builtin = @import("builtin");
const options = @import("nokre_deep_link_options");
const app_mod = @import("../../core/app.zig");

const App = app_mod.App;
const is_wasm = builtin.cpu.arch == .wasm32;

// The web leg owns the single-app receiver anchor and the
// `nokre_deep_link_receive` export; native legs implement
// `nokre_deep_link_install` in the shell. Under `zig test` neither is
// referenced — the mock is the only path — so tests stay dependency-free.
const web = if (is_wasm and !builtin.is_test) @import("web.zig") else struct {};

/// What `setHandler` registers. `ctx` is the app's — cast it back to
/// whatever routing needs (commonly the app state that holds `*App`).
/// `url` is the whole inbound URL, borrowed only for the call; copy it to
/// keep it. Called on the UI thread, exactly once per inbound URL.
pub const Handler = *const fn (ctx: ?*anyopaque, url: []const u8) void;

/// The C ABI the shell (or live.js) fires. `receiveC` is the one instance,
/// installed once with the app's per-service state as `ctx`.
const CCallback = *const fn (ctx: ?*anyopaque, url: [*]const u8, len: usize) callconv(.c) void;

// Implemented natively by each C-contract shell (macOS/iOS/Windows/Android
// app delegate), never on web: it stores ctx + cb and invokes cb on the
// main thread for the launch URL and every URL after. Referenced only
// from the linked, non-test, non-wasm path, so unlinked and test builds
// never name the symbol.
extern fn nokre_deep_link_install(ctx: ?*anyopaque, cb: CCallback) void;
// The shell forgets the stored ctx + cb; URLs after this buffer for the
// next install instead of being delivered. Same reference rules as the
// install.
extern fn nokre_deep_link_uninstall() void;

/// Register the inbound-URL handler. Call it once, inside `build` — the
/// launch URL then lands as the first callback, and every runtime link
/// after. Registering again replaces the handler (a rebuild re-registers
/// the same one; idempotent). The first registration installs the native
/// hook, which flushes any launch URL the shell buffered before boot
/// finished.
pub fn setHandler(app: *App, ctx: ?*anyopaque, handler: Handler) void {
    checkLinked();
    const state = app.services.deep_link.state.?;
    state.handler = handler;
    state.handler_ctx = ctx;
    if (comptime builtin.is_test) return;
    if (state.installed) return;
    state.installed = true;
    if (comptime is_wasm) {
        web.install(state, receiveC);
    } else {
        nokre_deep_link_install(state, receiveC);
    }
}

/// The bytes after the first `#`, or null if the URL has no fragment.
/// Pure and allocation-free — the web deep link *is* the fragment, and
/// an app routing by fragment on every platform reads it the same way.
/// The `#` is not included; an empty fragment ("…#") is a present, empty
/// slice, distinct from null, the way secure_store separates an empty
/// value from absence.
pub fn fragment(url: []const u8) ?[]const u8 {
    const hash = std.mem.indexOfScalar(u8, url, '#') orelse return null;
    return url[hash + 1 ..];
}

/// The single installed C trampoline: `ctx` is the per-service state, so
/// no global is consulted. Runs on the UI thread (the shell's promise).
fn receiveC(ctx: ?*anyopaque, url: [*]const u8, len: usize) callconv(.c) void {
    const state: *PlatformState = @ptrCast(@alignCast(ctx.?));
    state.dispatch(url[0..len]);
}

fn checkLinked() void {
    // Tests always run against the per-app mock (the only path compiled
    // under `zig test`), so linking is not required there. A release build
    // that skipped linking still cannot ship: the curated error names the
    // one-line fix — secure_store's rule.
    comptime if (!options.linked and !builtin.is_test) @compileError(
        \\the deep_link service is not linked. Pass .deep_link with the app's
        \\domains (plus .pkg_id — the entitlement and assetlinks are keyed to
        \\the app's identity) to the nokre dependency in build.zig.
        \\docs/services.md.
    );
}

/// What the App carries for this service: the journaling mock under
/// `zig test`, the handler-holding platform state in release. Both keep
/// per-app state (the registered handler), so both heap-allocate it in
/// `init` — the address must survive the by-value moves a stack App makes,
/// because the native install hands that pointer to the shell.
pub const Service = if (builtin.is_test) Mock else PlatformService;

/// Release-side per-app state: the registered handler and whether the
/// native hook is installed. `dispatch` is what the shell's callback
/// reaches — the mock's `deliver` is its test-time twin.
const PlatformState = struct {
    handler: ?Handler = null,
    handler_ctx: ?*anyopaque = null,
    installed: bool = false,

    fn dispatch(self: *PlatformState, url: []const u8) void {
        if (self.handler) |h| h(self.handler_ctx, url);
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
    }

    pub fn deinit(self: *PlatformService) void {
        const state = self.state orelse return;
        // The shell holds this state as the installed ctx; a URL landing
        // after teardown — or into a second App lifetime — must find no
        // callback, not freed memory. oauth's release-on-deinit rule.
        // Guarded on `linked` at comptime so an unlinked build (where
        // `installed` can never be true) names no extern.
        if (comptime options.linked) {
            if (state.installed) {
                if (comptime is_wasm) web.uninstall() else nokre_deep_link_uninstall();
            }
        }
        self.gpa.destroy(state);
        self.state = null;
    }
};

// ---- the deterministic test surface (docs/testing.md) ----
// One app's fake link source: `deliver` is the launch URL and every
// runtime link the test injects, journaled in order and routed to the
// registered handler synchronously — the test *is* the interleaving, the
// same bargain as the http mock.

/// The mock's heap half, allocated by App.init so its address is stable
/// across the by-value moves a stack App makes.
pub const MockState = struct {
    gpa: std.mem.Allocator,
    handler: ?Handler = null,
    handler_ctx: ?*anyopaque = null,
    received: std.ArrayList([]u8) = .empty,

    fn deliver(self: *MockState, url: []const u8) void {
        // Every delivered URL is journaled — even one that arrives before
        // a handler is registered (a launch URL the app hasn't wired yet),
        // so "the link came in but nothing handled it" is assertable. A
        // test allocator giving out is a crash, not an outcome.
        const owned = self.gpa.dupe(u8, url) catch @panic("deep_link mock: allocator failed");
        self.received.append(self.gpa, owned) catch @panic("deep_link mock: allocator failed");
        if (self.handler) |h| h(self.handler_ctx, url);
    }
};

pub const Mock = struct {
    /// The heap half; null only before App.init.
    state: ?*MockState = null,

    pub const Config = struct {};

    pub fn mock(config: Config) Mock {
        _ = config;
        return .{};
    }

    pub fn init(self: *Mock, gpa: std.mem.Allocator) !void {
        const state = try gpa.create(MockState);
        state.* = .{ .gpa = gpa };
        self.state = state;
    }

    pub fn deinit(self: *Mock) void {
        const state = self.state orelse return;
        for (state.received.items) |u| state.gpa.free(u);
        state.received.deinit(state.gpa);
        state.gpa.destroy(state);
        self.state = null;
    }

    /// Inject an inbound URL: the launch URL as the first call, then any
    /// runtime link. Journals it and routes it to the registered handler
    /// on this thread, now — synchronous, like the store; there is
    /// nothing to settle.
    pub fn deliver(self: Mock, url: []const u8) void {
        self.state.?.deliver(url);
    }

    /// Every URL delivered, in order — borrowed views. For asserting what
    /// arrived, including a URL that landed before the app registered a
    /// handler.
    pub fn received(self: Mock) []const []u8 {
        return self.state.?.received.items;
    }

    /// Whether the app has registered a handler yet — a launch URL
    /// delivered before this is true went unhandled.
    pub fn hasHandler(self: Mock) bool {
        return self.state.?.handler != null;
    }
};

// Force the linked install path to compile per target (the secure_store
// forcing, src/nokre.zig): under check-targets' compile-only objects
// nothing on the consumer side calls setHandler, so its reference to the
// native `nokre_deep_link_install` (or `web.install` on wasm) would go
// unanalyzed; and nothing references the web export `nokre_deep_link_receive`
// either, which lazy analysis would then drop from the wasm module.
// Guarded on `options.linked` so an unlinked build never trips
// setHandler's curated @compileError.
comptime {
    if (options.linked) {
        _ = &setHandler;
        if (is_wasm and !builtin.is_test) _ = &web.nokre_deep_link_receive;
    }
}
