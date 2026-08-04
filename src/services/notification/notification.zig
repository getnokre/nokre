//! notification — the OS's own notification surface: a message shown
//! outside the app, now or at a fire date, raised here or pushed from a
//! server (docs/services.md).
//!
//! nokre asks; the OS draws. Not one pixel of a notification belongs to
//! nokre, which is why a service that puts a message on someone's lock
//! screen costs the pixel model nothing — the share sheet's bargain — and
//! why there is no styling surface here to refuse.
//!
//! **nokre still schedules nothing.** `schedule` hands a fire date to the
//! OS and returns; the countdown is the OS's, and on every platform the
//! process is usually not alive when it fires. That is the whole of the
//! reconciliation with the no-ticker rule (the decision is recorded in
//! docs/internals/notifications.md): an app at rest still costs zero CPU,
//! because nothing in nokre waits.
//!
//! **The interrupt decision is the app's, and it gets made twice.**
//! `notices.notify` interrupts inside the app; this interrupts outside
//! it. Neither derives from the other, deliberately: a framework that
//! turned every in-app notice into a lock-screen banner would be
//! deciding, on the app's behalf, to reach someone who had put the app
//! down.
//!
//! **One handler, one lane** — deep_link's shape carrying iap's argument.
//! A tap on a notification this launch never posted, a push token minted
//! before the first `build`, a token the OS rotates on its own schedule,
//! an authorization the user revoked in Settings: none of those was
//! requested by a call that could own the callback, so there is one
//! `setHandler` and an app writes one path.
//!
//! Push stops where oauth stops. The device token comes back and the app
//! ships it to its own backend over `http`; nokre speaks to no push
//! service and holds no credential. Silent (`content-available`) payloads
//! are refused: a push that wakes an app to run code with no UI is
//! background execution, a different contract with a different owner.

const std = @import("std");
const builtin = @import("builtin");
const options = @import("nokre_notification_options");
const app_mod = @import("../../core/app.zig");
const clock = @import("../clock/clock.zig");

const App = app_mod.App;
const is_wasm = builtin.cpu.arch == .wasm32;

// The web leg owns the single-app receiver anchor and the
// `nokre_notification_receive` export; native legs implement
// `nokre_notification_install` in the shell. Under `zig test` neither is
// referenced — the mock is the only path — so tests stay dependency-free.
const web = if (is_wasm and !builtin.is_test) @import("web.zig") else struct {};

/// Whether this target's shell provides the hooks. Referenced only where
/// true, so a target without a leg never names the externs. Unlike
/// share's switch, `.linux` is blanket-true: the Wayland desktop has
/// org.freedesktop.Notifications on the bus this shell already polls, and
/// Android has NotificationManager, so both halves of `.linux` answer.
const has_shell_hook = is_wasm or switch (builtin.os.tag) {
    .macos, .ios, .windows, .linux => true,
    else => false,
};

/// The id's charset and cap, secure_store's rule for secure_store's
/// reason: this string survives verbatim as a `UNNotificationRequest`
/// identifier, an Android tag, a toast tag, and a key the mock's journal
/// is asserted against — one namespace rule, zero escaping. Lowercase
/// because two ids differing only in case would be one notification on a
/// platform that folds and two everywhere else.
pub const max_id_bytes = 64;
/// A notification is glanced at, and every platform truncates in display
/// long before these numbers. They are here for share's reason rather
/// than any platform's: past them the payload is a document, and a
/// document belongs behind the tap, not on the lock screen.
pub const max_title_bytes = 128;
pub const max_body_bytes = 512;
/// A route reference is a screen name plus identifier arguments
/// (docs/routing.md), which is short by construction.
pub const max_route_bytes = 256;
/// The largest device token any platform hands back. APNs is 32 bytes
/// rendered hex, an FCM token is a few hundred, and the web's is a JSON
/// subscription with two base64 keys in it — this clears the largest of
/// the three with room, and a token past it is a platform that changed
/// its mind, not a value to truncate.
pub const max_token_bytes = 4096;

/// Whether the user has allowed notifications. Three states, not a bool:
/// `not_determined` is a fresh install where asking is still legal,
/// `denied` is a decision the app must draw around and cannot re-prompt
/// its way out of on any platform, and only `granted` posts anything.
/// Collapsing the first two would make "ask again" the app's most
/// tempting bug.
pub const Status = enum(i32) {
    not_determined = 0,
    granted = 1,
    denied = 2,
};

/// What a notification says. `id` is the identity: posting the same id
/// twice replaces rather than stacks, `cancel` takes it, and the tap
/// reports it — so a notification the app can raise is a notification the
/// app can take back.
pub const Notification = struct {
    id: []const u8,
    title: []const u8,
    body: []const u8 = "",
    /// The route reference the tap delivers back — nokre's own reference
    /// (`note~42`), never a URL. deep_link carries URLs precisely because
    /// nokre does not interpret them; this end of the wire is nokre's on
    /// both sides, so the reference the router already speaks is what
    /// crosses. Routing stays the app's, as it is there.
    route: []const u8 = "",
    /// Whether this one is allowed to interrupt — `notices.Notify`'s
    /// field, aimed outside the app. On Android it selects between the
    /// two derived channels; elsewhere it drives the platform's own
    /// interruption level. Quiet by default, for the reason the in-app
    /// notice is quiet by default: interrupting is the thing a message
    /// has to ask for.
    important: bool = false,
};

/// Which notification, and the route reference it carried — the payload
/// of both a tap and a foreground arrival. Both borrowed for the call.
pub const Payload = struct {
    id: []const u8,
    route: []const u8,
};

/// Everything that arrives on the one lane. Slices are borrowed for the
/// call — copy what must outlive it, the worker-reply rule.
pub const Event = union(enum) {
    /// The authorization state settled: the prompt was answered, or the
    /// user changed their mind in Settings while the app ran. `status`
    /// is already updated when this fires.
    authorized: Status,
    /// The user tapped a notification. May be the first thing that
    /// happens in a launch — the tap is what started the process.
    opened: Payload,
    /// A notification came due while the app was on screen. The OS
    /// banner is suppressed for it, deliberately: drawing a lock-screen
    /// card over the app the user is already looking at is the OS
    /// interrupting someone on nokre's behalf, and the screen that would
    /// carry the news is right there. What to do with it — raise an
    /// in-app notice (`app.notify`), refresh a list, ignore it — is the
    /// app's, which is the same line `deep_link` draws at routing.
    ///
    /// Without this arm a reminder that fires while the app is open, and
    /// every push that arrives during a session, would be silently
    /// nothing. That is the only reason the union has a fourth case.
    received: Payload,
    /// The push transport minted (or rotated) this device's token. An
    /// opaque UTF-8 string in whatever shape the platform speaks: hex for
    /// APNs, the FCM token on Android, a JSON subscription on the web.
    /// nokre does not parse it; the app ships it to its own backend.
    push_token: []const u8,
};

/// What `setHandler` registers. `ctx` is the app's. Called on the UI
/// thread, interleaved with input like a worker reply.
pub const Handler = *const fn (ctx: ?*anyopaque, event: Event) void;

/// The C ABI the shell (or services.js) fires. One callback for every
/// event kind: the native side stays stateless and carries no union.
const CCallback = *const fn (
    ctx: ?*anyopaque,
    kind: i32,
    status_code: i32,
    a: [*]const u8,
    a_len: usize,
    b: [*]const u8,
    b_len: usize,
) callconv(.c) void;

const kind_authorized: i32 = 0;
const kind_opened: i32 = 1;
const kind_push_token: i32 = 2;
const kind_received: i32 = 3;

extern fn nokre_notification_install(ctx: ?*anyopaque, cb: CCallback) void;
extern fn nokre_notification_uninstall() void;
extern fn nokre_notification_available() i32;
extern fn nokre_notification_push_available() i32;
extern fn nokre_notification_schedule_available() i32;
extern fn nokre_notification_status() i32;
extern fn nokre_notification_authorize() void;
extern fn nokre_notification_post(
    id: [*]const u8,
    id_len: usize,
    title: [*]const u8,
    title_len: usize,
    body: [*]const u8,
    body_len: usize,
    route: [*]const u8,
    route_len: usize,
    important: i32,
    at_millis: i64,
) void;
extern fn nokre_notification_cancel(id: [*]const u8, id_len: usize) void;
extern fn nokre_notification_request_push(key: [*]const u8, key_len: usize) void;

/// Closed and per-operation, secure_store's rule: `cancel` can never
/// return `EmptyTitle`, and every argument check is a pure function of
/// the argument, run before any OS call, so each name means one thing on
/// all six platforms.
pub const PostError = error{
    InvalidId,
    EmptyTitle,
    TitleTooLarge,
    BodyTooLarge,
    RouteTooLarge,
    NotAuthorized,
    Unavailable,
};
/// `post`'s errors plus the one only a fire date can produce. A past
/// date is refused rather than fired immediately because the platforms
/// disagree about it — iOS rejects a non-positive interval outright while
/// Android's alarm fires at once — and "one thing on every platform" is
/// worth more here than a convenience that would hide a clock bug.
pub const ScheduleError = PostError || error{FireDateInPast};
pub const CancelError = error{ InvalidId, Unavailable };
pub const AuthError = error{Unavailable};
/// `NotAuthorized` and not a silent no-op: a push token minted for an app
/// the user has denied would arrive at a backend that then sends into a
/// void, and nothing downstream could tell that from a delivery bug.
pub const PushError = error{ Unavailable, NotAuthorized };

/// Is there a notification system here at all? Cached at `App.init` —
/// locale's boot-tag pattern: synchronous, no OS call, no error — so it
/// is legal inside `build` and an app can decide not to draw a
/// notifications toggle before it draws anything. False on a Linux
/// session with no notification daemon on the bus, and on a browser
/// without the Notification API.
pub fn available(app: *const App) bool {
    checkLinked();
    return app.services.notification.state.?.can_notify;
}

/// Is there a *push* transport here? Separate from `available` because
/// four of the six have one and two do not: the Linux desktop has no push
/// service, and Windows' WNS needs the packaged Store identity nokre does
/// not emit — iap's answer, one row over. An app that draws a "notify me
/// on this device" switch reads this; one that only reminds locally reads
/// `available`.
pub fn pushAvailable(app: *const App) bool {
    checkLinked();
    return app.services.notification.state.?.can_push;
}

/// Can a fire date be handed over here? Four of the six say yes. The
/// Linux desktop and the web say no, and the refusal is the honest
/// answer rather than a gap: neither has a system that will hold a date
/// for an app that is not running — org.freedesktop.Notifications posts
/// and nothing more, and the browser's scheduling trigger never shipped.
/// nokre will not fill that in with a timer of its own, because a
/// schedule nokre keeps is the thing `schedule` exists not to be: it
/// would die with the tab or the process, which is precisely when a
/// reminder matters.
///
/// So an app that reminds reads this like `share.available` — post now
/// where the answer is false, or keep the date on a server and push it.
pub fn scheduleAvailable(app: *const App) bool {
    checkLinked();
    return app.services.notification.state.?.can_schedule;
}

/// The authorization state, cached like the locale tag and updated the
/// moment an `authorized` event lands — so `build` reads it
/// synchronously and never renders a "may we notify you?" row the OS
/// already answered.
pub fn status(app: *const App) Status {
    checkLinked();
    return app.services.notification.state.?.status;
}

/// Register the one handler. Call it once, inside `build`: a tap that
/// launched the app, and a push token the OS minted before boot finished,
/// are both buffered until this call and flushed here in arrival order —
/// deep_link's launch-URL bargain, for the same reason. Registering again
/// replaces (a rebuild re-registering the same handler is a no-op).
pub fn setHandler(app: *App, ctx: ?*anyopaque, handler: Handler) void {
    checkLinked();
    const state = app.services.notification.state.?;
    state.handler = handler;
    state.handler_ctx = ctx;
    // The mock keeps no buffer: a test delivers events itself, in the
    // order it chooses, so "arrived before the handler" is something it
    // writes rather than something it has to be handed back.
    if (comptime builtin.is_test) return;
    state.flush();
}

/// Ask for permission. Fire-and-forget: the answer arrives as an
/// `authorized` event, never as a return value, because the same answer
/// can arrive without anyone asking — the user revoking notifications in
/// Settings is the OS reporting on a decision this app did not make, and
/// a result callback would leave that nowhere to land.
///
/// Asking when the state is already `denied` is legal here and does
/// nothing on every platform: none of them re-prompt, and refusing it in
/// Zig would only move the no-op earlier. Ask once, from a control the
/// user pressed — an app that asks at boot gets the reflexive "no" that
/// cannot be taken back.
pub fn authorize(app: *App) AuthError!void {
    checkLinked();
    if (!available(app)) return error.Unavailable;
    if (comptime builtin.is_test) {
        app.services.notification.state.?.record(.{ .authorize = {} });
    } else if (comptime has_shell_hook) {
        nokre_notification_authorize();
    }
}

/// Post a notification now.
pub fn post(app: *App, n: Notification) PostError!void {
    checkLinked();
    try check(app, n);
    deliver(app, n, 0);
}

/// Post a notification when the wall clock reaches `at_millis` — the
/// `clock` service's unit, milliseconds since the Unix epoch, UTC. The OS
/// owns the countdown from here; nokre holds nothing and waits on
/// nothing, and the app may be closed (or the device rebooted, on the
/// platforms that persist alarms) when it fires.
pub fn schedule(app: *App, n: Notification, at_millis: i64) ScheduleError!void {
    checkLinked();
    try check(app, n);
    if (!scheduleAvailable(app)) return error.Unavailable;
    // Read the clock rather than take a duration: an app computing "in
    // ten minutes" has to read it anyway, and an absolute instant is the
    // one form that survives the process dying in between.
    if (at_millis <= clock.now(app)) return error.FireDateInPast;
    deliver(app, n, at_millis);
}

/// Take a notification back: removes it from the shade if it is showing
/// and cancels it if it is scheduled and has not fired. Idempotent —
/// cancelling an id that was never posted is success, secure_store's
/// `delete` rule, because "already gone" is the state the caller asked
/// for.
pub fn cancel(app: *App, id: []const u8) CancelError!void {
    checkLinked();
    if (!validId(id)) return error.InvalidId;
    if (!available(app)) return error.Unavailable;
    if (comptime builtin.is_test) {
        app.services.notification.state.?.record(.{ .cancel = id });
    } else if (comptime has_shell_hook) {
        nokre_notification_cancel(id.ptr, id.len);
    }
}

/// Ask the push transport for this device's token. The token arrives as a
/// `push_token` event — this launch and every later one, since the
/// platforms re-report it, and again whenever the OS rotates it. Call it
/// after authorization is `granted`; ship what comes back to your own
/// backend over `http`, which is where nokre's involvement in push ends.
pub fn requestPushToken(app: *App) PushError!void {
    checkLinked();
    if (!pushAvailable(app)) return error.Unavailable;
    if (status(app) != .granted) return error.NotAuthorized;
    if (comptime builtin.is_test) {
        app.services.notification.state.?.record(.{ .push_request = {} });
    } else if (comptime has_shell_hook) {
        // The VAPID application server key, and the web's alone: a
        // browser refuses `pushManager.subscribe` without one, while APNs
        // and FCM identify the sender by the app's own registration. It
        // is a build declaration rather than a call argument because it
        // is a property of the app, not of the moment — package_info's
        // declare-once rule.
        nokre_notification_request_push(options.push_key.ptr, options.push_key.len);
    }
}

/// The shared argument gate for `post` and `schedule`. Pure checks first,
/// in declaration order, then the two posture answers — so a malformed
/// payload fails identically on a platform that would have refused it and
/// one that would have shown it truncated.
fn check(app: *App, n: Notification) PostError!void {
    if (!validId(n.id)) return error.InvalidId;
    if (n.title.len == 0) return error.EmptyTitle;
    if (n.title.len > max_title_bytes) return error.TitleTooLarge;
    if (n.body.len > max_body_bytes) return error.BodyTooLarge;
    if (n.route.len > max_route_bytes) return error.RouteTooLarge;
    if (!available(app)) return error.Unavailable;
    // Last, and deliberately: a payload that is malformed is malformed
    // whether or not the user ever answered the prompt, so the argument
    // errors stay reachable in a test that never granted anything.
    if (status(app) != .granted) return error.NotAuthorized;
}

fn deliver(app: *App, n: Notification, at_millis: i64) void {
    if (comptime builtin.is_test) {
        app.services.notification.state.?.record(.{ .posted = .{ .n = n, .at_millis = at_millis } });
    } else if (comptime has_shell_hook) {
        nokre_notification_post(
            n.id.ptr,
            n.id.len,
            n.title.ptr,
            n.title.len,
            n.body.ptr,
            n.body.len,
            n.route.ptr,
            n.route.len,
            @intFromBool(n.important),
            at_millis,
        );
    }
}

/// The id charset: 1–64 bytes of `[a-z0-9._-]`. A pure function of the
/// argument, so `InvalidId` is producible everywhere by passing one.
pub fn validId(id: []const u8) bool {
    if (id.len == 0 or id.len > max_id_bytes) return false;
    for (id) |c| switch (c) {
        'a'...'z', '0'...'9', '.', '_', '-' => {},
        else => return false,
    };
    return true;
}

/// The single installed C trampoline: `ctx` is the per-app state, so no
/// global is consulted. Runs on the UI thread (the shell's promise).
fn receiveC(
    ctx: ?*anyopaque,
    kind: i32,
    status_code: i32,
    a: [*]const u8,
    a_len: usize,
    b: [*]const u8,
    b_len: usize,
) callconv(.c) void {
    const state: *PlatformState = @ptrCast(@alignCast(ctx.?));
    switch (kind) {
        kind_authorized => state.dispatch(.{ .authorized = statusOf(status_code) }),
        kind_opened => state.dispatch(.{ .opened = .{ .id = a[0..a_len], .route = b[0..b_len] } }),
        kind_received => state.dispatch(.{ .received = .{ .id = a[0..a_len], .route = b[0..b_len] } }),
        kind_push_token => {
            // A token past the cap is a platform that changed its mind,
            // and half a token is worse than none: drop it rather than
            // hand the app a value its backend would register and never
            // be able to send to.
            if (a_len <= max_token_bytes) state.dispatch(.{ .push_token = a[0..a_len] });
        },
        // A kind this build does not know is a shell ahead of its Zig
        // side; dropping it beats dispatching a union arm at random.
        else => {},
    }
}

fn statusOf(code: i32) Status {
    return switch (code) {
        1 => .granted,
        2 => .denied,
        else => .not_determined,
    };
}

fn checkLinked() void {
    // Mocks satisfy tests, a release build cannot ship unlinked —
    // secure_store's checkLinked states why.
    comptime if (!options.linked and !builtin.is_test) @compileError(
        \\the notification service is not linked. Pass .notification = true
        \\(plus .pkg_id — the channel, the AUMID and the entitlement are all
        \\keyed to the app's identity) to the nokre dependency in build.zig.
        \\Add .notification_push = true for remote push. docs/services.md.
    );
}

/// What the App carries for this service: the journaling mock under
/// `zig test`, the handler-holding platform state in release. Both keep
/// per-app state, so both heap-allocate it in `init` — the address must
/// survive the by-value moves a stack App makes, because the native
/// install hands that pointer to the shell.
pub const Service = if (builtin.is_test) Mock else PlatformService;

/// How many events are held for a handler that has not registered yet.
/// The window is App.init to the first `setHandler` inside the first
/// `build` — microseconds — and the launch tap is the first thing in it,
/// so the overflow rule drops the *newest*: a shell firing five events
/// before the app has drawn once is a loop, and the tap that started the
/// launch is the one that must survive it.
const max_pending = 8;

/// Release-side per-app state. `dispatch` is what the shell's callback
/// reaches — the mock's `emit` is its test-time twin.
const PlatformState = struct {
    gpa: std.mem.Allocator,
    can_notify: bool = false,
    can_push: bool = false,
    can_schedule: bool = false,
    status: Status = .not_determined,
    handler: ?Handler = null,
    handler_ctx: ?*anyopaque = null,
    installed: bool = false,
    pending: std.ArrayList(OwnedEvent) = .empty,

    fn dispatch(self: *PlatformState, event: Event) void {
        // The cache updates whether or not anyone is listening: an app
        // that registers no handler at all still reads `status` inside
        // `build`, and the OS's answer is not the handler's to gate.
        if (event == .authorized) self.status = event.authorized;
        if (self.handler) |h| {
            h(self.handler_ctx, event);
            return;
        }
        if (self.pending.items.len >= max_pending) return;
        const owned = OwnedEvent.dupe(self.gpa, event) catch return;
        self.pending.append(self.gpa, owned) catch {
            owned.deinit(self.gpa);
            return;
        };
    }

    fn flush(self: *PlatformState) void {
        const h = self.handler orelse return;
        // Drained by index and freed as it goes: a handler that calls
        // back into the service (a tap that posts a notification) must
        // not find this list mid-iteration.
        while (self.pending.items.len != 0) {
            const owned = self.pending.orderedRemove(0);
            h(self.handler_ctx, owned.event());
            owned.deinit(self.gpa);
        }
    }
};

/// A buffered event with its bytes copied: the shell borrows its strings
/// for the callback only, and the whole point of the buffer is outliving
/// that call.
const OwnedEvent = struct {
    kind: std.meta.Tag(Event),
    status: Status = .not_determined,
    a: []u8 = &.{},
    b: []u8 = &.{},

    fn dupe(gpa: std.mem.Allocator, ev: Event) !OwnedEvent {
        return switch (ev) {
            .authorized => |s| .{ .kind = .authorized, .status = s },
            .opened, .received => |p| blk: {
                const id = try gpa.dupe(u8, p.id);
                errdefer gpa.free(id);
                break :blk .{ .kind = std.meta.activeTag(ev), .a = id, .b = try gpa.dupe(u8, p.route) };
            },
            .push_token => |t| .{ .kind = .push_token, .a = try gpa.dupe(u8, t) },
        };
    }

    fn event(self: OwnedEvent) Event {
        return switch (self.kind) {
            .authorized => .{ .authorized = self.status },
            .opened => .{ .opened = .{ .id = self.a, .route = self.b } },
            .received => .{ .received = .{ .id = self.a, .route = self.b } },
            .push_token => .{ .push_token = self.a },
        };
    }

    fn deinit(self: OwnedEvent, gpa: std.mem.Allocator) void {
        if (self.a.len != 0) gpa.free(self.a);
        if (self.b.len != 0) gpa.free(self.b);
    }
};

const PlatformService = struct {
    state: ?*PlatformState = null,

    /// Installs in `App.init` rather than at the first `setHandler` —
    /// locale's placement, not deep_link's, and for locale's reason
    /// inverted: the boot answers (`available`, `pushAvailable`,
    /// `status`) must be readable inside the first `build`, and a tap
    /// that launched the app must have somewhere to land before that
    /// build runs. The shell buffers only what arrives before this call;
    /// everything after is held here, where one implementation serves all
    /// six platforms.
    pub fn init(self: *PlatformService, gpa: std.mem.Allocator) !void {
        const state = try gpa.create(PlatformState);
        state.* = .{ .gpa = gpa };
        self.state = state;
        if (comptime options.linked and has_shell_hook) {
            state.can_notify = nokre_notification_available() != 0;
            // On the web a push transport with no application server
            // key cannot subscribe at all, so the honest boot answer is
            // false — the app draws no "notify me" switch rather than
            // offering one that silently fails.
            const keyed = !is_wasm or options.push_key.len != 0;
            state.can_push = options.push and keyed and nokre_notification_push_available() != 0;
            state.can_schedule = nokre_notification_schedule_available() != 0;
            state.status = statusOf(nokre_notification_status());
            if (comptime is_wasm) {
                web.install(state, receiveC);
            } else {
                nokre_notification_install(state, receiveC);
            }
            state.installed = true;
        }
    }

    pub fn deinit(self: *PlatformService) void {
        const state = self.state orelse return;
        // The shell holds this state as the installed ctx; a tap landing
        // after teardown — or into a second App lifetime — must find no
        // callback, not freed memory. deep_link's release-on-deinit rule.
        if (comptime options.linked and has_shell_hook) {
            if (state.installed) {
                if (comptime is_wasm) web.uninstall() else nokre_notification_uninstall();
            }
        }
        for (state.pending.items) |p| p.deinit(state.gpa);
        state.pending.deinit(state.gpa);
        state.gpa.destroy(state);
        self.state = null;
    }
};

// ---- the deterministic test surface (docs/testing.md) ----
// One app's fake notification centre. Every call the app makes is
// journaled in order, and nothing the *user* does happens until the test
// says so: `grant`/`deny` answer the prompt, `open` is the tap,
// `deliverToken` is the transport minting one. The test is the OS.

/// One thing the app asked the OS to do. Owned copies, so an assertion
/// can read them after the call's borrowed slices are gone.
pub const Entry = union(enum) {
    authorize,
    push_request,
    posted: Posted,
    cancel: []u8,

    pub const Posted = struct {
        id: []u8,
        title: []u8,
        body: []u8,
        route: []u8,
        important: bool,
        /// 0 for `post`, the requested instant for `schedule` — so "the
        /// app scheduled instead of posting" is one comparison.
        at_millis: i64,
    };
};

const PendingRecord = union(enum) {
    authorize,
    push_request,
    posted: struct { n: Notification, at_millis: i64 },
    cancel: []const u8,
};

pub const MockState = struct {
    gpa: std.mem.Allocator,
    can_notify: bool,
    can_push: bool,
    can_schedule: bool,
    status: Status,
    handler: ?Handler = null,
    handler_ctx: ?*anyopaque = null,
    journal: std.ArrayList(Entry) = .empty,
    asked: bool = false,

    fn record(self: *MockState, rec: PendingRecord) void {
        // A test allocator giving out is a crash, not an outcome (the
        // clipboard mock's rule).
        const entry: Entry = switch (rec) {
            .authorize => blk: {
                self.asked = true;
                break :blk .authorize;
            },
            .push_request => .push_request,
            .cancel => |id| .{ .cancel = self.dupe(id) },
            .posted => |p| .{ .posted = .{
                .id = self.dupe(p.n.id),
                .title = self.dupe(p.n.title),
                .body = self.dupe(p.n.body),
                .route = self.dupe(p.n.route),
                .important = p.n.important,
                .at_millis = p.at_millis,
            } },
        };
        self.journal.append(self.gpa, entry) catch @panic("notification mock: allocator failed");
    }

    fn dupe(self: *MockState, s: []const u8) []u8 {
        return self.gpa.dupe(u8, s) catch @panic("notification mock: allocator failed");
    }

    fn emit(self: *MockState, event: Event) void {
        if (event == .authorized) self.status = event.authorized;
        if (self.handler) |h| h(self.handler_ctx, event);
    }

    fn free(self: *MockState, entry: Entry) void {
        switch (entry) {
            .authorize, .push_request => {},
            .cancel => |id| self.gpa.free(id),
            .posted => |p| {
                self.gpa.free(p.id);
                self.gpa.free(p.title);
                self.gpa.free(p.body);
                self.gpa.free(p.route);
            },
        }
    }
};

pub const Mock = struct {
    /// The heap half; null only before App.init.
    state: ?*MockState = null,
    /// The seeds `mock()` took, applied by `init` — iap's split.
    boot: Config = .{},

    pub const Config = struct {
        /// False boots a device with no notification system: the Linux
        /// session with no daemon, the browser without the API. Every
        /// verb is then `error.Unavailable`.
        available: bool = true,
        /// False boots a device that notifies but cannot receive push —
        /// the Linux desktop, Windows without a Store identity.
        push_available: bool = true,
        /// False boots a device that notifies but will not hold a fire
        /// date: the Linux desktop and the web, where nothing outlives
        /// the process to fire it.
        schedule_available: bool = true,
        /// The authorization state at boot. `not_determined` is the fresh
        /// install; `granted` is the relaunch that most tests are really
        /// written against, and naming it skips a prompt the test is not
        /// about.
        status: Status = .not_determined,
    };

    pub fn mock(config: Config) Mock {
        return .{ .boot = config };
    }

    pub fn init(self: *Mock, gpa: std.mem.Allocator) !void {
        const state = try gpa.create(MockState);
        state.* = .{
            .gpa = gpa,
            .can_notify = self.boot.available,
            .can_push = self.boot.push_available,
            .can_schedule = self.boot.schedule_available,
            .status = self.boot.status,
        };
        self.state = state;
    }

    pub fn deinit(self: *Mock) void {
        const state = self.state orelse return;
        for (state.journal.items) |e| state.free(e);
        state.journal.deinit(state.gpa);
        state.gpa.destroy(state);
        self.state = null;
    }

    /// The user allowed notifications — by answering a prompt the app
    /// raised, or by turning them on in Settings with the app running.
    /// Deliberately legal without a prior `authorize`: the second is a
    /// real thing devices do, and a mock that refused it would make the
    /// unrequested path untestable.
    pub fn grant(self: Mock) void {
        self.state.?.emit(.{ .authorized = .granted });
    }

    /// The user refused, or revoked in Settings.
    pub fn deny(self: Mock) void {
        self.state.?.emit(.{ .authorized = .denied });
    }

    /// The user tapped a notification. Routes to the handler on this
    /// thread, now — synchronous, like the deep_link mock; the test is
    /// the interleaving. Takes `Payload`, the type the handler receives,
    /// so id and route cannot be swapped into a plausible wrong test.
    pub fn open(self: Mock, payload: Payload) void {
        self.state.?.emit(.{ .opened = payload });
    }

    /// A notification came due with the app on screen — a scheduled one
    /// firing during a session, or a push arriving mid-use. No OS banner
    /// is drawn for it on any platform; the event is the whole delivery.
    pub fn arrive(self: Mock, payload: Payload) void {
        self.state.?.emit(.{ .received = payload });
    }

    /// The push transport minted (or rotated) a token.
    pub fn deliverToken(self: Mock, token: []const u8) void {
        self.state.?.emit(.{ .push_token = token });
    }

    /// Everything the app asked the OS to do, in order. A refused call
    /// journals nothing, because the OS was never asked.
    pub fn entries(self: Mock) []const Entry {
        return self.state.?.journal.items;
    }

    /// Whether the app ever raised the permission prompt — the assertion
    /// behind "this screen posted without asking".
    pub fn askedForAuthorization(self: Mock) bool {
        return self.state.?.asked;
    }

    /// Whether the app has registered a handler yet: a tap delivered
    /// before this is true reached nothing.
    pub fn hasHandler(self: Mock) bool {
        return self.state.?.handler != null;
    }
};

// Force the linked paths to compile per target (the deep_link forcing,
// src/nokre.zig): under check-targets' compile-only objects nothing on
// the consumer side calls these, so their references to the native
// externs would go unanalyzed, and nothing references the web export
// either — which lazy analysis would then drop from the wasm module.
// Guarded on `options.linked` so an unlinked build never trips the
// curated @compileError.
comptime {
    if (options.linked) {
        _ = &setHandler;
        _ = &post;
        _ = &schedule;
        _ = &cancel;
        _ = &authorize;
        _ = &scheduleAvailable;
        _ = &requestPushToken;
        // The install path itself — locale's forcing: nothing in a
        // compile-only object references App.init, so without these the
        // shell externs (and the wasm install) would go unanalyzed. Only
        // where the release half compiles: under `zig test` the mock is
        // the Service and the web module is never imported.
        if (!builtin.is_test) {
            _ = &PlatformService.init;
            _ = &PlatformService.deinit;
        }
        if (is_wasm and !builtin.is_test) _ = &web.nokre_notification_receive;
    }
}
