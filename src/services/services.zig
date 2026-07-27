//! The Services struct: everything platform-flavored an App consumes,
//! injected at construction. Injection stays type-closed — comptime
//! decides which implementation compiles (test builds carry mocks and
//! never reference native externs; release builds carry the platform
//! transports) — what construction decides is where the state lives:
//! on the App, never in a module-global.
//!
//! In a release build `.{}` is the platform set, so shells and examples
//! keep their one-line init. In a test build each field is nokre's
//! canonical mock: consumers configure seeds, handlers, and canned
//! responses; they never implement transport semantics. Until the
//! enforcement flip lands, tests may also omit `.services` and get
//! default mocks — after it, omission is a compile error and
//! `.services = .mocks()` is the bare-test one-liner.

const std = @import("std");
const builtin = @import("builtin");
const clipboard = @import("clipboard/clipboard.zig");
const deep_link = @import("deep_link/deep_link.zig");
const haptic = @import("haptic/haptic.zig");
const http = @import("http/http.zig");
const iap = @import("iap/iap.zig");
const locale = @import("locale/locale.zig");
const oauth = @import("oauth/oauth.zig");
const open_url = @import("open_url/open_url.zig");
const secure_store = @import("secure_store/secure_store.zig");
const workers = @import("../workers/workers.zig");

/// The release half of a service that keeps nothing: the platform call
/// is an extern with no handle to hold, so these two exist only to
/// satisfy the injection contract every service answers to. `clipboard`
/// and `haptic` name this instead of restating it — a service that
/// *does* hold state writes its own pair (secure_store carries its
/// `CountCache`), and the difference is then visible at a glance.
pub const Stateless = struct {
    pub fn init(self: *Stateless, gpa: std.mem.Allocator) !void {
        _ = self;
        _ = gpa;
    }

    pub fn deinit(self: *Stateless) void {
        _ = self;
    }
};

pub const Services = struct {
    http: http.Service = .{},
    secure_store: secure_store.Service = .{},
    clipboard: clipboard.Service = .{},
    deep_link: deep_link.Service = .{},
    locale: locale.Service = .{},
    /// Packaging footprint (the contributing checklist's requirement
    /// that it be stated, never implied by silence): oauth is the first
    /// service to derive a *custom scheme* — a `CFBundleURLTypes` entry
    /// on Apple and a VIEW intent-filter on Android, per declared
    /// scheme, plus the `com.apple.developer.applesignin` entitlement
    /// when Sign in with Apple is declared. Windows, Linux, and the web
    /// derive nothing: a loopback listener registers nothing, and on the
    /// web the origin is the registration.
    oauth: oauth.Service = .{},
    /// Packaging footprint: Android's `com.android.vending.BILLING`
    /// permission, and nothing anywhere else. In-App Purchase is a
    /// capability on the App ID, enabled in Apple's own console — there
    /// is no plist key and no entitlement file entry — so Apple's cost
    /// is link-time only (`-framework StoreKit`). Windows, Linux, and
    /// the web derive nothing because they have no store: `available`
    /// answers false there and every verb is `error.Unavailable`.
    iap: iap.Service = .{},
    /// Packaging footprint: nothing, anywhere — stated rather than
    /// implied (see packaging.zig's row). The odd one out of the roster
    /// in a second way too: no app can call it. nokre fires it for the
    /// back gesture nokre owns, and it is a field here only because
    /// anything platform-flavored is injected and observable
    /// (docs/internals/haptics.md).
    haptic: haptic.Service = .{},
    /// Packaging footprint: nothing, anywhere — stated rather than
    /// implied. Opening a URL is an outbound intent/launch on every
    /// platform; no manifest entry, permission, or entitlement exists
    /// to derive (the VIEW *filters* oauth and deep_link derive are for
    /// URLs coming in, not going out).
    open_url: open_url.Service = .{},

    /// The bare-test one-liner: every service as its default mock.
    /// Test builds only — in a release build the same `.{}` silently
    /// means the platform set, and a call spelled "mocks" that ships
    /// real transports is exactly the misreading this error forecloses.
    pub fn mocks() Services {
        comptime if (!builtin.is_test) @compileError(
            \\Services.mocks() is the test harness's: mocks exist only under
            \\`zig test`, and in a release build `.{}` is already the platform
            \\set. Construct with `.{}` (or configure fields) instead.
        );
        return .{};
    }

    /// Allocates each service's per-app state (App.init's second half);
    /// the config values the consumer passed stay verbatim.
    pub fn init(self: *Services, gpa: std.mem.Allocator, runtime: *workers.Runtime) !void {
        try self.http.init(gpa, runtime);
        errdefer self.http.deinit();
        try self.secure_store.init(gpa);
        errdefer self.secure_store.deinit();
        try self.clipboard.init(gpa);
        errdefer self.clipboard.deinit();
        try self.deep_link.init(gpa);
        errdefer self.deep_link.deinit();
        try self.haptic.init(gpa);
        errdefer self.haptic.deinit();
        try self.open_url.init(gpa);
        errdefer self.open_url.deinit();
        try self.oauth.init(gpa);
        errdefer self.oauth.deinit();
        // Takes the runtime, like http: the purchase stream delivers
        // updates nobody requested, so it opens delivery slots with no
        // `*App` in hand (docs/internals/iap.md).
        try self.iap.init(gpa, runtime);
        errdefer self.iap.deinit();
        // Last, and deliberately: locale's init is the only one that
        // calls out to the shell and gets a value back before it
        // returns (the boot tag), so it runs with every other service
        // already standing — nothing it fires into can be half-built.
        try self.locale.init(gpa);
    }

    pub fn deinit(self: *Services) void {
        self.http.deinit();
        self.secure_store.deinit();
        self.clipboard.deinit();
        self.deep_link.deinit();
        self.haptic.deinit();
        self.open_url.deinit();
        self.oauth.deinit();
        self.iap.deinit();
        self.locale.deinit();
    }
};
