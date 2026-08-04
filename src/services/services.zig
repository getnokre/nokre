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
const clock = @import("clock/clock.zig");
const deep_link = @import("deep_link/deep_link.zig");
const haptic = @import("haptic/haptic.zig");
const http = @import("http/http.zig");
const iap = @import("iap/iap.zig");
const locale = @import("locale/locale.zig");
const notification = @import("notification/notification.zig");
const oauth = @import("oauth/oauth.zig");
const open_url = @import("open_url/open_url.zig");
const secure_store = @import("secure_store/secure_store.zig");
const share = @import("share/share.zig");
const workers = @import("../workers/workers.zig");

/// The release half of a service that keeps nothing: the platform call
/// is an extern with no handle to hold, so these two exist only to
/// satisfy the injection contract every service answers to. `clipboard`,
/// `haptic`, `open_url`, and `clock` name this instead of restating it —
/// a service that *does* hold state writes its own pair (secure_store
/// carries its `CountCache`), and the difference is then visible at a
/// glance.
pub const Stateless = struct {
    pub fn init(self: *Stateless, gpa: std.mem.Allocator) !void {
        _ = self;
        _ = gpa;
    }

    pub fn deinit(self: *Stateless) void {
        _ = self;
    }
};

/// Whether the target's shell exports the hook for a service every
/// shell answers (`.linux` covering both the Android JNI shell and the
/// desktop Wayland shell). Referenced only where true, so stub targets
/// never name the extern. One home so the next stateless service copies
/// a fact, not a switch — a service some shell genuinely lacks (share's
/// sheetless Wayland desktop, haptic's iOS-only threshold, locale's
/// native-only install) states its own roster instead.
pub const every_shell_hooks = builtin.cpu.arch == .wasm32 or switch (builtin.os.tag) {
    .macos, .ios, .windows, .linux => true,
    else => false,
};

// Mock conventions, stated once for the roster: every mock answers
// `mock(Config)` even where Config is empty (clipboard, haptic,
// open_url, deep_link) — the construction site reads uniformly, and a
// service that later grows a knob grows it without changing the
// consumer's shape.

/// The journaling mock's ledger: everything the app asked the OS to do,
/// in order, owned here — dead with the app. One shape for the
/// fire-and-forget services, whose calls have no error to surface, so
/// the journal has none either: a test allocator giving out is a crash,
/// not an outcome. `[]u8` entries are copied in; anything else is held
/// by value.
pub fn Journal(comptime Entry: type, comptime name: []const u8) type {
    return struct {
        const Self = @This();
        const owns_bytes = Entry == []u8;

        gpa: std.mem.Allocator,
        entries: std.ArrayList(Entry) = .empty,

        pub fn record(self: *Self, entry: if (owns_bytes) []const u8 else Entry) void {
            const owned: Entry = if (comptime owns_bytes)
                self.gpa.dupe(u8, entry) catch @panic(name ++ ": allocator failed")
            else
                entry;
            self.entries.append(self.gpa, owned) catch @panic(name ++ ": allocator failed");
        }

        /// The whole ledger, in call order. Borrowed views.
        pub fn view(self: *const Self) []const Entry {
            return self.entries.items;
        }

        /// Drop the ledger — the per-phase reset (http's `clearJournal`
        /// rule), so a test can assert "and *that* action asked exactly
        /// these" without arithmetic over everything before it.
        pub fn clear(self: *Self) void {
            if (comptime owns_bytes) for (self.entries.items) |e| self.gpa.free(e);
            self.entries.clearRetainingCapacity();
        }

        pub fn deinit(self: *Self) void {
            if (comptime owns_bytes) for (self.entries.items) |e| self.gpa.free(e);
            self.entries.deinit(self.gpa);
        }
    };
}

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
    /// Packaging footprint: nothing, anywhere — stated rather than
    /// implied. The sheet is an outbound handoff wherever it exists
    /// (ACTION_SEND names no permission, UIActivityViewController no
    /// entitlement, the WinRT share pane no manifest entry), and the
    /// platform without one — the Linux desktop — answers `available`
    /// false at runtime rather than deriving anything.
    share: share.Service = .{},
    /// Packaging footprint, and the only service so far whose derivation
    /// a *user* can see: Android's `POST_NOTIFICATIONS`, which unlike
    /// every permission derived before it is dangerous — prompted at
    /// runtime, refusable, revocable — so the derivation is documented in
    /// the consumer section rather than left to the emitter's silence
    /// (the BILLING row states the rule this one is the exception to).
    /// Push adds Apple's `aps-environment` entitlement and, on Android,
    /// the FCM service declaration; local adds neither. Windows and Linux
    /// derive nothing into a manifest — Windows instead registers its
    /// AppUserModelID and activator CLSID at first run, which is a
    /// narrowly scoped reversal of deep_link's registry refusal recorded
    /// in docs/internals/notifications.md — and the web derives only the
    /// service worker the site already emits.
    notification: notification.Service = .{},
    /// Packaging footprint: nothing, anywhere — stated rather than
    /// implied. Reading the wall clock is a call every platform hands
    /// out unasked: no manifest entry, no permission (Android's
    /// SET_TIME is for *writing* it, which nokre never does), no
    /// entitlement, and `Date.now()` needs neither a secure context nor
    /// an origin trial. The odd one out of the roster in a second way:
    /// no shell answers it either — the OS call is Zig's own, so this
    /// is the only service with no C header at all.
    clock: clock.Service = .{},

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
        try self.share.init(gpa);
        errdefer self.share.deinit();
        // Takes the runtime, like http: the purchase stream delivers
        // updates nobody requested, so it opens delivery slots with no
        // `*App` in hand (docs/internals/iap.md).
        try self.iap.init(gpa, runtime);
        errdefer self.iap.deinit();
        try self.clock.init(gpa);
        errdefer self.clock.deinit();
        // Second to last: notification's init reads its three boot
        // probes and installs the inbound receiver, so like locale it
        // calls out to the shell before it returns — and a shell may
        // flush the tap that launched the process during that install.
        // It buffers rather than dispatching (no handler exists until
        // the first build), but it still runs with everything else
        // standing, for locale's reason.
        try self.notification.init(gpa);
        errdefer self.notification.deinit();
        // Last, and deliberately: locale's init is the only one that
        // calls out to the shell and gets a value back *and delivers it*
        // before it returns (the boot tag fires the handler inside the
        // install), so it runs with every other service already standing
        // — nothing it fires into can be half-built.
        try self.locale.init(gpa);
    }

    /// `init`, exactly mirrored: locale and notification came up last
    /// because their installs call out to the shell and can fire
    /// handlers into the other services, so they come down first —
    /// nothing they can still fire into is ever half-torn-down.
    pub fn deinit(self: *Services) void {
        self.locale.deinit();
        self.notification.deinit();
        self.clock.deinit();
        self.iap.deinit();
        self.share.deinit();
        self.oauth.deinit();
        self.open_url.deinit();
        self.haptic.deinit();
        self.deep_link.deinit();
        self.clipboard.deinit();
        self.secure_store.deinit();
        self.http.deinit();
    }
};
