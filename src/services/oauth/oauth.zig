//! oauth — the one browser primitive a sign-in flow is missing
//! (docs/services.md; the design argument is docs/internals/oauth.md).
//!
//! Most of an OAuth flow already works: the app builds the authorize
//! URL, `http` exchanges the code, `secure_store` keeps the refresh
//! token, `deep_link` carries an inbound URL. The gap is the middle —
//! opening the authorize URL somewhere the user can *trust* (RFC 8252:
//! the system browser or an in-app browser tab, never an embedded web
//! view) and getting the callback URL back. That is this service, and
//! it is one verb.
//!
//! Outbound then inbound, so the shape is `http`'s, not `deep_link`'s:
//! `start` leaves from an action and exactly one `Result` returns on the
//! UI thread, between events, through the same one-shot delivery slot a
//! request uses (docs/internals/workers.md). Behind the comptime split
//! the platforms differ wildly — ASWebAuthenticationSession on Apple, a
//! Custom Tab on Android, a loopback listener on Windows and Linux, a
//! popup on the web, a parked request under `zig test` — and the
//! consumer contract is identical everywhere.
//!
//! Two calls, in this order, once per flow:
//!
//!     var buf: oauth.RedirectBuf = undefined;
//!     const redirect = try oauth.redirectUri(app, "com.example.notes", &buf);
//!     // …build the authorize URL with `redirect`, PKCE, scopes, state…
//!     _ = try oauth.start(.{ .app = app, .url = authorize, .redirect = redirect,
//!                            .ctx = state, .on_result = onAuth });
//!
//! `redirectUri` is not decoration. On Windows and Linux the redirect is
//! a loopback URL whose port the OS picks (RFC 8252 §7.3), so the
//! listener must bind *before* the authorize URL can be written down;
//! on the web it is the page's own address; everywhere else it is the
//! custom scheme. One call covers all three, and the token exchange
//! needs the same string back — so exposing it beats hiding it.
//!
//! Where the service stops is `deep_link`'s line: nokre hands over the
//! callback URL and stops. No token refresh policy (that is the app's
//! session model, and a timer is a ticker — nokre has none), no user
//! model, no JWT verification (the signature needs the provider's
//! rotating JWKS, a fetch with a cache policy and a clock; the server
//! does it), no route table.

const std = @import("std");
const builtin = @import("builtin");
const options = @import("nokre_oauth_options");
const app_mod = @import("../../core/app.zig");
const workers = @import("../../workers/workers.zig");

/// PKCE (RFC 7636) and the `state` guard: the two values every native-app
/// flow needs and neither provider will generate for you.
pub const pkce = @import("pkce.zig");

const App = app_mod.App;
const is_wasm = builtin.cpu.arch == .wasm32;

/// Which implementation this target compiles. Named rather than
/// switched at each use, because five call sites have to agree on it.
pub const Leg = enum {
    /// `zig test`, an unlinked build, and any target with no way to run
    /// the flow: the mock is the only path, so no extern is ever named.
    none,
    /// macOS + iOS: ASWebAuthenticationSession, plus the native
    /// ASAuthorizationController leg for `.provider = .apple`.
    apple,
    /// Custom Tab; the redirect returns as an intent through the same
    /// activity path deep_link uses.
    android,
    /// Windows + Linux: the default browser plus a loopback listener
    /// (RFC 8252 §7.3). The desktop portal has no auth-session API worth
    /// binding, so both desktops share one implementation.
    loopback,
    /// A popup on the app's own origin, which posts its landing URL back.
    web,
};

// An unlinked build has no leg, not "the leg this target would have
// used": `start` cannot be called (checkLinked's @compileError), but
// `deinit` still runs, and its release path would otherwise name a
// native extern whose .m/.c file this build never compiled — the
// macOS `_nokre_oauth_cancel` link failure. Folding "unlinked" into
// `.none` keeps that promise in the one place the five switches
// already agree on, rather than re-guarding each of them.
pub const leg: Leg = if (builtin.is_test or !options.linked)
    .none
else if (is_wasm)
    .web
else switch (builtin.os.tag) {
    .macos, .ios => .apple,
    .windows => .loopback,
    // .linux is both the Android JNI shell and desktop Wayland.
    .linux => if (builtin.abi.isAndroid()) .android else .loopback,
    else => .none,
};

// Each leg's module is referenced only where it is the chosen one, so a
// target that cannot run the flow never names a symbol it would have to
// link — clipboard's posture, applied per leg rather than per platform.
const native = if (leg == .apple or leg == .android) @import("native.zig") else struct {};
const loopback_leg = if (leg == .loopback) @import("loopback.zig") else struct {};
const web = if (leg == .web) @import("web.zig") else struct {};

// Mirrors NOKRE_OAUTH_* in oauth.h.
const status_callback: c_int = 0;
const status_cancelled: c_int = 1;
const status_failure: c_int = 2;

/// A transport or configuration failure: the flow never produced a
/// callback and the user never cancelled it. A stable name, `http`'s
/// `.failure` posture — "SessionUnavailable" when the platform refused
/// to open a session at all, "BrowserUnavailable" when no browser could
/// be launched, otherwise whatever the platform called it.
pub const Failure = struct { name: []const u8 };

/// What `on_result` receives — exactly once per `start`.
pub const Result = union(enum) {
    /// The OS handed the callback URL back. Parse it, exchange the code
    /// over `http`, store the refresh token in `secure_store`. Valid for
    /// the callback only; copy it to keep it.
    callback: []const u8,
    /// The user dismissed the sheet. A first-class value, not an error:
    /// cancelling a login is a normal thing to do.
    cancelled,
    failure: Failure,
};

/// Which implementation `start` routes to. `.web` is the browser flow —
/// Google, Microsoft, GitHub, and Apple-on-a-non-Apple-platform all use
/// it, because none of them requires an SDK. `.apple` additionally
/// routes to `ASAuthorizationController` on macOS and iOS, where Apple
/// requires it for a conforming flow; everywhere else `.apple` is the
/// browser flow through the same primitive. One consumer-facing call,
/// two implementations behind it, chosen at comptime — secure_store's
/// dispatch, not a consumer branch.
pub const Provider = enum { web, apple };

/// The redirect path every platform appends. Fixed, not a knob: the
/// path carries no information (the code and state ride the query), and
/// a knob here would be one more string the app must keep identical in
/// three places — the authorize URL, the token exchange, and the
/// provider console.
pub const callback_path = "callback";

/// Redirect URIs are short by construction on native targets: a
/// reverse-DNS scheme plus a path, or a loopback address plus a port —
/// 128 bytes is roughly four times the longest real one, and the cap
/// doubles as a validity check, because a 500-byte "custom scheme" is
/// a bug somewhere, not a deployment. The web is the one target whose
/// redirect nokre does not compose: it is the hosted page's own URL,
/// and its length belongs to the deployment — an org's pages domain
/// under a project path clears 128 bytes without trying. 2048 is the
/// whole-URL floor every mainstream browser and proxy honors, so a
/// page a browser will serve is a redirect this cap accepts. Either
/// way an over-cap URL is a loud `error.RedirectTooLong`, never a
/// silently truncated URI the provider would reject at the token
/// exchange.
pub const max_redirect_bytes = if (is_wasm) 2048 else 128;
pub const RedirectBuf = [max_redirect_bytes]u8;

/// RFC 3986 caps nothing useful, but a custom scheme is a reverse-DNS
/// app id; 64 bytes is the same slack `locale`'s tag cap takes.
pub const max_scheme_bytes = 64;

pub const Error = error{
    /// Not a legal URI scheme, or not lowercase. Schemes are
    /// case-insensitive and the OS registrations are written in
    /// lowercase, so nokre refuses the spelling that would work on one
    /// platform and quietly not on another.
    InvalidScheme,
    /// A flow is already live for this app. One at a time by design: a
    /// system browser sheet is modal and a user can only be signing in
    /// once, which is what lets the native contract carry a bare session
    /// pointer instead of a request id.
    AuthInFlight,
    /// `start` without a `redirectUri` call for this flow — the app
    /// cannot have built a URL the platform will receive.
    NoRedirect,
    /// The `redirect` passed to `start` is not the one `redirectUri`
    /// prepared. The authorize URL and the listener would disagree, and
    /// the flow would hang instead of failing, so it fails here.
    RedirectMismatch,
    /// The redirect this platform needs does not fit `max_redirect_bytes`.
    RedirectTooLong,
    /// No loopback port could be bound (Windows and Linux only).
    ListenFailed,
} || std.mem.Allocator.Error;

pub const StartOptions = struct {
    app: *App,
    /// The authorize URL, built by the app: client id, scopes, the PKCE
    /// challenge, `state`, and `redirect_uri` — all of it the app's, so
    /// nothing about a provider's parameter names lives in nokre.
    url: []const u8,
    /// What `redirectUri` returned for this flow.
    redirect: []const u8,
    provider: Provider = .web,
    /// Apple's native leg only: the raw nonce Apple hashes into the
    /// idToken's `nonce` claim. Ignored elsewhere — on the browser flow
    /// the nonce is already a parameter of `url`.
    nonce: []const u8 = "",
    /// Apple's native leg only: echoed back into the synthetic callback
    /// URL so the app's CSRF check reads the same on every platform.
    /// Ignored elsewhere, where `state` is already a parameter of `url`.
    state: []const u8 = "",
    ctx: ?*anyopaque = null,
    on_result: *const fn (ctx: ?*anyopaque, result: Result) void,
};

/// Generation-checked, like a worker handle: after the result (or a
/// cancel) it is spent and every use is a no-op — never a dangling
/// pointer.
pub const Handle = struct {
    ticket: workers.Ticket,
    state: *State,

    /// Dismiss the session: the sheet closes and `on_result` will never
    /// run. UI thread only, idempotent. Not the same as the user
    /// cancelling — that arrives as `.cancelled`, because the app did
    /// not ask for it.
    pub fn cancel(self: @This()) void {
        self.state.abort();
        workers.cancelOneShot(self.ticket);
    }
};

/// The redirect URI this platform will actually receive the callback on.
/// Call it once per flow, immediately before building the authorize URL,
/// and pass the same string to the token exchange — providers compare it
/// byte for byte.
///
/// `scheme` is the app's custom URL scheme (conventionally its
/// reverse-DNS id, or Google's reversed client id on iOS). It is what
/// the packaging registers, so it is validated on every platform even
/// where this leg ignores it — a scheme that is legal on the developer's
/// machine and rejected on the CI target is the failure mode this
/// prevents.
pub fn redirectUri(app: *App, scheme: []const u8, buf: *RedirectBuf) Error![]const u8 {
    checkLinked();
    const st = app.services.oauth.state.?;
    if (st.live) return error.AuthInFlight;
    try validateScheme(scheme);
    // An abandoned flow's listener dies here rather than at the next
    // deinit: preparing a second redirect is the app saying the first
    // one is over.
    st.releaseSession(true);
    st.redirect_len = 0;
    const uri = switch (leg) {
        .loopback => blk: {
            const listener = loopback_leg.bind(st.gpa) catch return error.ListenFailed;
            st.session = @ptrCast(listener);
            break :blk std.fmt.bufPrint(buf, "http://127.0.0.1:{d}/{s}", .{
                loopback_leg.portOf(listener),
                callback_path,
            }) catch return error.RedirectTooLong;
        },
        // The page's own address, seeded by live.js before boot: on the
        // web the origin *is* the registration, and a custom scheme has
        // no meaning in a browser.
        .web => web.redirect(buf) catch return error.RedirectTooLong,
        // Custom scheme — `scheme:/callback`, RFC 8252 §7.1. One slash:
        // the scheme is the app, so there is no authority component to
        // leave empty.
        .apple, .android, .none => std.fmt.bufPrint(buf, "{s}:/{s}", .{ scheme, callback_path }) catch
            return error.RedirectTooLong,
    };
    // Two copies on purpose. The service keeps one so `start` can check
    // that the URL the app built names the redirect this platform will
    // actually receive on; the caller gets a slice of its *own* buffer,
    // because the string outlives the flow — the token exchange sends it
    // after the callback has landed, and by then the service's copy is
    // cleared.
    @memcpy(st.redirect_buf[0..uri.len], uri);
    st.redirect_len = uri.len;
    return uri;
}

/// Open the authorize URL where the user can trust it, and deliver the
/// callback URL back. Everything in `opts` is borrowed for the call
/// only. Under `zig test` the request parks in the app's mock and the
/// test supplies the outcome — the browser becomes a test input
/// (docs/testing.md).
pub fn start(opts: StartOptions) Error!Handle {
    checkLinked();
    const st = opts.app.services.oauth.state.?;
    if (st.live) return error.AuthInFlight;
    if (st.redirect_len == 0) return error.NoRedirect;
    if (!std.mem.eql(u8, st.redirect_buf[0..st.redirect_len], opts.redirect))
        return error.RedirectMismatch;

    // The service's own trampoline is what parks, not the app's
    // callback: per-flow state must be torn down on the UI thread,
    // exactly once, before the app sees the result — and after the
    // loopback leg's delivery, which crosses from its own thread.
    st.on_result = opts.on_result;
    st.result_ctx = opts.ctx;
    const ticket = try workers.openOneShot(Result, opts.app, st, dispatch);
    errdefer workers.cancelOneShot(ticket);
    st.live = true;
    st.ticket = ticket;
    errdefer st.abort();
    try st.launch(opts);
    return .{ .ticket = ticket, .state = st };
}

/// The value of `name` in a callback URL's query or fragment, or null.
/// Pure and allocation-free, `deep_link.fragment`'s footing: every
/// provider answers with `code`, `state`, and `error` in one of the two,
/// and an app that reaches for a URL parser to read three parameters has
/// been handed the wrong shape. Percent-decoding is deliberately not
/// done here — the values that matter (`code`, `state`) are
/// unreserved-charset by every provider's construction, and a decoder
/// that silently rewrote a code would be worse than none.
pub fn param(url: []const u8, name: []const u8) ?[]const u8 {
    const start_of_query = std.mem.indexOfAny(u8, url, "?#") orelse return null;
    var rest = url[start_of_query + 1 ..];
    while (rest.len != 0) {
        const amp = std.mem.indexOfAny(u8, rest, "&#") orelse rest.len;
        const pair = rest[0..amp];
        rest = if (amp == rest.len) "" else rest[amp + 1 ..];
        const eq = std.mem.indexOfScalar(u8, pair, '=') orelse continue;
        if (std.mem.eql(u8, pair[0..eq], name)) return pair[eq + 1 ..];
    }
    return null;
}

/// A scheme is `ALPHA *( ALPHA / DIGIT / "+" / "-" / "." )` (RFC 3986
/// §3.1), narrowed to lowercase — see `Error.InvalidScheme`.
fn validateScheme(scheme: []const u8) Error!void {
    if (scheme.len == 0 or scheme.len > max_scheme_bytes) return error.InvalidScheme;
    if (!std.ascii.isLower(scheme[0])) return error.InvalidScheme;
    for (scheme[1..]) |c| {
        if (!(std.ascii.isLower(c) or std.ascii.isDigit(c) or c == '+' or c == '-' or c == '.'))
            return error.InvalidScheme;
    }
}

/// Every result lands here first, on the UI thread: tear the flow down,
/// then hand the app what it asked for. Reading the callback out before
/// the teardown is deliberate — the app is allowed to start the next
/// flow from inside its own handler.
fn dispatch(ctx: ?*anyopaque, result: Result) void {
    const st: *State = @ptrCast(@alignCast(ctx.?));
    const cb = st.on_result orelse return;
    const cb_ctx = st.result_ctx;
    st.settle();
    cb(cb_ctx, result);
}

fn checkLinked() void {
    // Tests always run against the per-app mock (the only path compiled
    // under `zig test`), so linking is not required there. A release
    // build that skipped linking still cannot ship: the curated error
    // names the one-line fix — secure_store's rule.
    comptime if (!options.linked and !builtin.is_test) @compileError(
        \\the oauth service is not linked. Pass .oauth_schemes with the app's
        \\redirect scheme (plus .pkg_id — the URL-type registration and the
        \\intent-filter are keyed to the app's identity) to the nokre
        \\dependency in build.zig. docs/services.md.
    );
}

/// What the App carries for this service: the journaling mock under
/// `zig test`, the session-holding platform state in release. Both keep
/// per-app state, so both heap-allocate it in `init` — the address must
/// survive the by-value moves a stack App makes, because the native
/// start hands that pointer to the platform.
pub const Service = if (builtin.is_test) Mock else PlatformService;

/// The heap half either way, so `Handle` names one type.
pub const State = if (builtin.is_test) MockState else PlatformState;

// ---- the release-side state ----

const PlatformState = struct {
    gpa: std.mem.Allocator,
    /// The live session: a native session pointer on Apple and Android,
    /// a `*loopback.Listener` on Windows and Linux, a sentinel on the
    /// web. Opaque here on purpose — releasing it is the leg's job.
    session: ?*anyopaque = null,
    /// True from `start` until the result lands or the app cancels.
    live: bool = false,
    on_result: ?*const fn (ctx: ?*anyopaque, result: Result) void = null,
    result_ctx: ?*anyopaque = null,
    redirect_buf: RedirectBuf = undefined,
    redirect_len: usize = 0,
    /// The parked delivery slot, spent by the first trampoline that
    /// reaches it — the guard that keeps a platform firing twice from
    /// becoming two results.
    ticket: ?workers.Ticket = null,
    /// Apple's native leg returns fields, not a URL, and the app's
    /// `state` is ours to echo back into the synthetic one. A `state`
    /// value is a CSRF nonce, so 128 bytes is eight times what a
    /// base64url'd 128-bit random needs. Over the cap it truncates
    /// rather than vanishing: a mismatch the app will reject beats a
    /// silently absent parameter it might not check.
    apple_state: [128]u8 = undefined,
    apple_state_len: usize = 0,

    fn launch(self: *PlatformState, opts: StartOptions) Error!void {
        switch (leg) {
            .apple => {
                // `options.apple` is the entitlement: without it the
                // native controller fails on a real device, so an app
                // that did not declare Sign in with Apple gets the
                // browser flow — the outcome that actually works.
                if (opts.provider == .apple and options.apple) {
                    // Kept before the call, not after: a platform is
                    // allowed to answer synchronously, and the echo must
                    // already be in hand when it does.
                    self.apple_state_len = @min(opts.state.len, self.apple_state.len);
                    @memcpy(self.apple_state[0..self.apple_state_len], opts.state[0..self.apple_state_len]);
                    self.session = native.appleStart(self, appleResultC, opts.nonce);
                } else {
                    self.session = native.start(self, resultC, opts.url, schemeOf(opts.redirect));
                }
                if (self.session == null) self.failNow("SessionUnavailable");
            },
            .android => {
                self.session = native.start(self, resultC, opts.url, schemeOf(opts.redirect));
                if (self.session == null) self.failNow("SessionUnavailable");
            },
            .loopback => {
                const listener: *loopback_leg.Listener = @ptrCast(@alignCast(self.session.?));
                // Listen first, then open the browser: a redirect that
                // beat the accept would be a connection refused, and the
                // user would see a broken page for a flow that worked.
                loopback_leg.run(listener, self.ticket.?) catch return self.failNow("ListenFailed");
                if (!native_open.openUrl(opts.url)) self.failNow("BrowserUnavailable");
            },
            .web => {
                // The runtime rides along because the web result's
                // delivery has no shell loop to pump it — the receive
                // export pumps inline (web.zig states the arrangement).
                if (web.start(self, resultC, opts.url, self.ticket.?.runtime))
                    self.session = web.sentinel()
                else
                    self.failNow("PopupBlocked");
            },
            // `.none` is the mock (tests) or an unlinked build, and
            // neither reaches `launch` — `start` is the only caller and
            // it stops at `checkLinked`.
            .none => unreachable,
        }
    }

    /// A leg that could not even begin still owes exactly one result,
    /// and owes it the same way every other result arrives: queued, on
    /// the UI thread, after `start` has returned the handle. A consumer
    /// must never see its handler run before it holds the handle.
    fn failNow(self: *PlatformState, name: []const u8) void {
        const ticket = self.ticket orelse return;
        self.ticket = null;
        // A failed encode of a two-word failure name is out of memory
        // and nothing else; the flow then ends with no callback, which
        // `cancel` and `deinit` both already tolerate.
        workers.deliverOneShot(Result, ticket, self.gpa, .{ .failure = .{ .name = name } }) catch {};
    }

    fn settle(self: *PlatformState) void {
        self.live = false;
        self.redirect_len = 0;
        self.ticket = null;
        self.releaseSession(false);
    }

    fn abort(self: *PlatformState) void {
        self.live = false;
        self.redirect_len = 0;
        self.ticket = null;
        self.releaseSession(true);
    }

    /// `cancelling` is the whole difference: on the settle path the leg
    /// has already finished with the session (the native side releases
    /// it as it invokes the callback), so cancelling it again would be a
    /// use-after-free.
    fn releaseSession(self: *PlatformState, cancelling: bool) void {
        const s = self.session orelse return;
        self.session = null;
        switch (leg) {
            .apple, .android => if (cancelling) native.cancel(s),
            .loopback => loopback_leg.release(@ptrCast(@alignCast(s)), cancelling),
            .web => if (cancelling) web.cancel(),
            .none => {},
        }
    }
};

/// The scheme half of a prepared custom-scheme redirect — what the
/// native side watches for. Derived rather than stored: `redirectUri`
/// built the string, so the scheme is exactly the bytes before the
/// first colon, and there is no second copy to drift.
fn schemeOf(redirect: []const u8) []const u8 {
    const colon = std.mem.indexOfScalar(u8, redirect, ':') orelse return redirect;
    return redirect[0..colon];
}

/// The one C trampoline for the browser legs: `ctx` is the per-service
/// state, so no global is consulted. Runs on the main thread (the
/// platform's promise), exactly once per session.
fn resultC(ctx: ?*anyopaque, status: c_int, text: [*]const u8, len: usize) callconv(.c) void {
    const st: *PlatformState = @ptrCast(@alignCast(ctx.?));
    // The native side released the session as it called us; drop the
    // pointer before anything can try to cancel it.
    st.session = null;
    const result: Result = switch (status) {
        status_callback => .{ .callback = text[0..len] },
        status_cancelled => .cancelled,
        else => .{ .failure = .{ .name = if (len == 0) "AuthFailed" else text[0..len] } },
    };
    deliverFrom(st, result);
}

/// Apple's native leg: fields in, one synthetic callback URL out, so the
/// app parses the same shape it parses everywhere else. Composed here
/// rather than natively because percent-encoding is policy.
fn appleResultC(
    ctx: ?*anyopaque,
    status: c_int,
    code: [*]const u8,
    code_len: usize,
    id_token: [*]const u8,
    id_token_len: usize,
    err: [*]const u8,
    err_len: usize,
) callconv(.c) void {
    const st: *PlatformState = @ptrCast(@alignCast(ctx.?));
    st.session = null;
    if (status != status_callback) {
        deliverFrom(st, if (status == status_cancelled)
            .cancelled
        else
            .{ .failure = .{ .name = if (err_len == 0) "AuthFailed" else err[0..err_len] } });
        return;
    }
    var url: std.ArrayList(u8) = .empty;
    defer url.deinit(st.gpa);
    composeAppleCallback(
        st.gpa,
        &url,
        st.redirect_buf[0..st.redirect_len],
        code[0..code_len],
        id_token[0..id_token_len],
        st.apple_state[0..st.apple_state_len],
    ) catch {
        deliverFrom(st, .{ .failure = .{ .name = "OutOfMemory" } });
        return;
    };
    deliverFrom(st, .{ .callback = url.items });
}

fn composeAppleCallback(
    gpa: std.mem.Allocator,
    out: *std.ArrayList(u8),
    redirect: []const u8,
    code: []const u8,
    id_token: []const u8,
    state: []const u8,
) std.mem.Allocator.Error!void {
    try out.appendSlice(gpa, redirect);
    try out.append(gpa, '?');
    try appendParam(gpa, out, "code", code, true);
    try appendParam(gpa, out, "id_token", id_token, false);
    if (state.len != 0) try appendParam(gpa, out, "state", state, false);
}

fn appendParam(
    gpa: std.mem.Allocator,
    out: *std.ArrayList(u8),
    name: []const u8,
    value: []const u8,
    first: bool,
) std.mem.Allocator.Error!void {
    if (!first) try out.append(gpa, '&');
    try out.appendSlice(gpa, name);
    try out.append(gpa, '=');
    for (value) |c| {
        if (std.ascii.isAlphanumeric(c) or c == '-' or c == '.' or c == '_' or c == '~') {
            try out.append(gpa, c);
        } else {
            try out.print(gpa, "%{X:0>2}", .{c});
        }
    }
}

/// Both trampolines end here. Delivery goes through the one-shot slot
/// rather than calling the app back inline: a callback that ran inside
/// the platform's own stack frame would reenter the app from a UIKit
/// delegate, and the whole point of the delivery queue is that app code
/// only ever runs between events.
fn deliverFrom(st: *PlatformState, result: Result) void {
    const ticket = st.ticket orelse return;
    st.ticket = null;
    workers.deliverOneShot(Result, ticket, st.gpa, result) catch {
        workers.deliverOneShot(Result, ticket, st.gpa, .{ .failure = .{ .name = "OutOfMemory" } }) catch {};
    };
}

const PlatformService = struct {
    state: ?*PlatformState = null,
    gpa: std.mem.Allocator = undefined,

    pub fn init(self: *PlatformService, gpa: std.mem.Allocator) !void {
        const state = try gpa.create(PlatformState);
        state.* = .{ .gpa = gpa };
        self.state = state;
        self.gpa = gpa;
    }

    pub fn deinit(self: *PlatformService) void {
        const state = self.state orelse return;
        // An app torn down mid-flow dismisses the sheet: the callback
        // must not outlive the state it would land in.
        state.abort();
        self.gpa.destroy(state);
        self.state = null;
    }
};

// ---- the deterministic test surface (docs/testing.md) ----
// One app's fake browser: `start` parks, journaled in order with the URL
// the app actually built, and nothing moves until the test answers — so
// "the app requested the wrong scopes" and "the app never sent a PKCE
// challenge" are assertions rather than hopes. The same bargain as the
// http mock, with one flow instead of a queue, because the service
// allows one flow.

/// What the app asked for, as owned copies.
pub const Authorization = struct {
    url: []const u8,
    redirect: []const u8,
    provider: Provider,
    nonce: []const u8,
    state: []const u8,
};

/// What the OS does with a parked session.
pub const Outcome = union(enum) {
    /// The callback URL the browser redirected to.
    callback: []const u8,
    /// The user dismissed the sheet.
    cancelled,
    /// A transport failure, by name.
    failure: []const u8,
};

/// The mock's heap half, allocated by App.init so its address is stable
/// across the by-value moves a stack App makes.
pub const MockState = struct {
    gpa: std.mem.Allocator,
    live: bool = false,
    on_result: ?*const fn (ctx: ?*anyopaque, result: Result) void = null,
    result_ctx: ?*anyopaque = null,
    redirect_buf: RedirectBuf = undefined,
    redirect_len: usize = 0,
    ticket: ?workers.Ticket = null,
    /// Seeds, applied at App.init and never mutated after.
    verifier: []const u8 = "",
    state_seed: []const u8 = "",
    auto: ?Outcome = null,
    journal: std.ArrayList(Authorization) = .empty,

    fn launch(self: *MockState, opts: StartOptions) Error!void {
        try self.record(opts);
        // A seeded outcome answers immediately — queued, so it still
        // lands at a pump like every other delivery, never inside
        // `start`. Without one the flow parks for the harness's
        // completeAuth / cancelAuth / failAuth.
        if (self.auto) |outcome| self.answer(outcome) catch {};
    }

    fn record(self: *MockState, opts: StartOptions) Error!void {
        const g = self.gpa;
        const url = try g.dupe(u8, opts.url);
        errdefer g.free(url);
        const redirect = try g.dupe(u8, opts.redirect);
        errdefer g.free(redirect);
        const nonce = try g.dupe(u8, opts.nonce);
        errdefer g.free(nonce);
        const state = try g.dupe(u8, opts.state);
        errdefer g.free(state);
        try self.journal.append(g, .{
            .url = url,
            .redirect = redirect,
            .provider = opts.provider,
            .nonce = nonce,
            .state = state,
        });
    }

    fn answer(self: *MockState, outcome: Outcome) !void {
        const ticket = self.ticket orelse return error.NoPendingAuth;
        self.ticket = null;
        try workers.deliverOneShot(Result, ticket, self.gpa, switch (outcome) {
            .callback => |url| .{ .callback = url },
            .cancelled => .cancelled,
            .failure => |name| .{ .failure = .{ .name = name } },
        });
    }

    fn settle(self: *MockState) void {
        self.live = false;
        self.redirect_len = 0;
    }

    fn abort(self: *MockState) void {
        self.live = false;
        self.redirect_len = 0;
        self.ticket = null;
    }

    /// The release side's twin, so `redirectUri` reads identically under
    /// both roofs; the mock has no session to release.
    fn releaseSession(self: *MockState, cancelling: bool) void {
        _ = self;
        _ = cancelling;
    }
};

pub const Mock = struct {
    boot: Config = .{},
    /// The heap half; null only before App.init.
    state: ?*MockState = null,

    /// The PKCE verifier the mock hands back. A fixed value, not a
    /// random one: a test that renders a login screen must stay
    /// byte-stable, and the whole point of seeding it is that the
    /// authorize URL a test asserts on is the same one every run
    /// (docs/internals/oauth.md, "PKCE, and the one determinism
    /// carve-out"). 43 unreserved characters, RFC 7636's minimum.
    pub const default_verifier = "nokre-test-verifier-0000000000000000000000";
    /// The `state` guard's seeded twin.
    pub const default_state = "nokre-test-state-0000";

    pub const Config = struct {
        verifier: []const u8 = default_verifier,
        state: []const u8 = default_state,
        /// What the browser does, seeded. Null parks the flow for the
        /// harness's `completeAuth` / `cancelAuth` / `failAuth` — the
        /// http mock's split between a fake server and answering by hand.
        auto: ?Outcome = null,
    };

    pub fn mock(config: Config) Mock {
        return .{ .boot = config };
    }

    pub fn init(self: *Mock, gpa: std.mem.Allocator) !void {
        const state = try gpa.create(MockState);
        state.* = .{
            .gpa = gpa,
            .verifier = self.boot.verifier,
            .state_seed = self.boot.state,
            .auto = self.boot.auto,
        };
        self.state = state;
    }

    pub fn deinit(self: *Mock) void {
        const state = self.state orelse return;
        for (state.journal.items) |a| {
            state.gpa.free(a.url);
            state.gpa.free(a.redirect);
            state.gpa.free(a.nonce);
            state.gpa.free(a.state);
        }
        state.journal.deinit(state.gpa);
        state.gpa.destroy(state);
        self.state = null;
    }

    /// Every `start` this app made, in order — borrowed views of what
    /// the app actually built. The assertion surface for scopes, the
    /// PKCE challenge, and the redirect.
    pub fn authorizations(self: Mock) []const Authorization {
        return self.state.?.journal.items;
    }

    /// Whether a flow is parked, waiting for the test to answer.
    pub fn inFlight(self: Mock) bool {
        return self.state.?.ticket != null;
    }

    /// The browser redirected: answer the parked flow with a callback
    /// URL. Queued like every delivery — the harness's `completeAuth`
    /// adds the pump and the re-audit.
    pub fn complete(self: Mock, url: []const u8) !void {
        return self.state.?.answer(.{ .callback = url });
    }

    /// The user dismissed the sheet.
    pub fn cancel(self: Mock) !void {
        return self.state.?.answer(.cancelled);
    }

    /// The session failed by name — the offline case, one call.
    pub fn fail(self: Mock, name: []const u8) !void {
        return self.state.?.answer(.{ .failure = name });
    }
};

// The desktop legs' one native verb, kept out of `native.zig` so the
// Apple/Android extern surface and the desktop one never compile into
// the same object.
const native_open = if (leg == .loopback) @import("open_url.zig") else struct {};

// Force the linked paths to compile per target (the secure_store
// forcing, src/nokre.zig): under check-targets' compile-only objects
// nothing on the consumer side calls `start`, so its references to the
// native externs would go unanalyzed, and nothing references the web
// exports either, which lazy analysis would then drop from the wasm
// module. Guarded on `options.linked` so an unlinked build never trips
// the curated @compileError.
comptime {
    if (options.linked and !builtin.is_test) {
        _ = &start;
        _ = &redirectUri;
        if (leg == .web) {
            _ = &web.nokre_oauth_seed_scratch;
            _ = &web.nokre_oauth_seed_redirect;
            _ = &web.nokre_oauth_scratch;
            _ = &web.nokre_oauth_receive;
        }
    }
}
