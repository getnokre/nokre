//! iap — the platform stores, as four verbs and one stream
//! (docs/services.md; the design argument is docs/internals/iap.md).
//!
//! The roster's last row, and the only service that genuinely needs a
//! per-platform SDK: StoreKit on Apple, the Play Billing Library on
//! Android, and nothing at all on Windows, Linux, and the web, where
//! `available` answers false and an app draws no paywall.
//!
//! Two shapes at once, which is what makes it the largest. `products` is
//! request/response — http's shape, one `Catalog` on the UI thread
//! through the same one-shot slot. The purchase stream is deep_link's —
//! one handler, registered inside `build`, receiving every update the
//! store pushes: the purchase this app just asked for, an interrupted
//! one redelivered at launch, an Ask-to-Buy approval days later, a
//! renewal, every result of `restore`. A purchase that arrived through
//! `purchase`'s own callback would leave those five with nowhere to
//! land, so there is one lane and the app writes one path.
//!
//! Money is never nokre's arithmetic. `Product.price` is the string the
//! store formatted, and it is the only field an app draws; `price_micros`
//! and `currency` are integers and a code, for reporting to a backend
//! rather than for display. Core is integer-only with no floats, and a
//! framework that reformatted a price would print one the payment sheet
//! is about to contradict.
//!
//! Where the service stops is oauth's line: no receipt verification (the
//! `token` goes to the app's backend, which owns the provider's server
//! API), no entitlement or expiry model (renewal windows need a clock,
//! and a timer is a ticker — nokre has none), no catalog, no paywall
//! layout, no route table.

const std = @import("std");
const builtin = @import("builtin");
const options = @import("nokre_iap_options");
const app_mod = @import("../../core/app.zig");
const workers = @import("../../workers/workers.zig");

const App = app_mod.App;
const is_wasm = builtin.cpu.arch == .wasm32;

/// Which implementation this target compiles. Named rather than
/// switched at each use, because several call sites have to agree on it.
pub const Leg = enum {
    /// `zig test`, an unlinked build, and — unlike every other service —
    /// three shipping platforms: Windows and Linux have no store nokre
    /// can reach (Microsoft's needs MSIX packaging with a Store identity,
    /// which nokre does not emit), and the web was committed to
    /// "absent on web" by the service checklist. `available` is false
    /// here and no extern is ever named.
    none,
    /// macOS + iOS: StoreKit 1, in Objective-C. StoreKit 2 is Swift-only
    /// and zig cannot compile Swift, so it would mean two Apple
    /// implementations (docs/internals/iap.md).
    apple,
    /// The Play Billing Library, through NokreBilling.java and a JNI leg.
    android,
};

pub const leg: Leg = if (builtin.is_test or !options.linked or is_wasm)
    .none
else switch (builtin.os.tag) {
    .macos, .ios => .apple,
    // .linux is both the Android JNI shell and desktop Wayland; only the
    // first has a store.
    .linux => if (builtin.abi.isAndroid()) .android else .none,
    else => .none,
};

// Referenced only where a leg exists, so a storeless target never names
// a symbol its build never compiled — oauth's forcing rule, per leg.
const native = if (leg == .none) struct {} else @import("native.zig");

// Mirrors NOKRE_IAP_ERR_* in iap.h: why a sheet never appeared.
const err_no_product: c_int = 1;

// Mirrors NOKRE_IAP_* in iap.h.
const status_purchased: c_int = 0;
const status_pending: c_int = 1;
const status_restored: c_int = 2;
const status_cancelled: c_int = 3;
const status_failure: c_int = 4;

/// What the store sells a product as. `unknown` is honest rather than
/// convenient: the kind decides whether the app consumes or keeps the
/// purchase, and a guess there is a refund or a permanently unspendable
/// coin. A store that declines to say gets to say nothing.
pub const Kind = enum(u8) {
    unknown = 0,
    consumable = 1,
    non_consumable = 2,
    subscription = 3,
};

/// One row of the catalog, as the store describes it. Every slice is
/// borrowed for the callback; copy what outlives it.
pub const Product = struct {
    id: []const u8,
    title: []const u8,
    description: []const u8,
    /// The store's own formatted string — "$4.99", "4,99 €". The only
    /// field an app draws, and never parsed: formatting money is a
    /// function of locale, currency, and the store's regional rounding,
    /// all three already applied on the other side of this call.
    price: []const u8,
    /// ISO 4217, e.g. "USD". Reported, not drawn.
    currency: []const u8,
    /// Play's subscription offer token; empty everywhere else and for
    /// every other kind. Opaque — pass it back to `purchase` unread.
    offer: []const u8,
    /// 4.99 USD is 4_990_000. An integer, so nothing here is a float:
    /// this exists so an app reports a number to its backend instead of
    /// parsing `price`, which is the failure mode the pair prevents.
    price_micros: u64,
    kind: Kind,
};

/// A transport or store failure, as a stable name — http's `.failure`
/// posture. "StoreUnavailable" when the platform refused the request
/// outright, otherwise whatever the store called it.
pub const Failure = struct { name: []const u8 };

/// What a `products` query answers with, exactly once. An empty
/// `products` slice is data, not an error: it means the store knows none
/// of the requested ids, the way a secure_store miss is `null`.
pub const Catalog = union(enum) {
    products: []const Product,
    failure: Failure,
};

/// Where a purchase is. `pending` is Play's cash-at-a-kiosk flow and
/// Apple's Ask to Buy: the user committed and the money has not moved,
/// and the real purchase arrives on the stream later — possibly days
/// later, in a different process launch. An app that treats it as a
/// failure has shipped a bug for the customers least able to work
/// around it.
pub const State = enum { purchased, pending, restored };

pub const Purchase = struct {
    /// The store's transaction id — stable, and the key the app's
    /// backend deduplicates on.
    id: []const u8,
    product: []const u8,
    /// What the backend verifies with: Apple's JWS or receipt, Play's
    /// purchase token. Opaque bytes nokre never reads — verifying on
    /// the device is verifying with the attacker's copy of the key.
    token: []const u8,
    state: State,
};

/// One event on the purchase stream. `cancelled` is the user dismissing
/// the payment sheet: a first-class value, not an error, for the same
/// reason cancelling a login is.
pub const Update = union(enum) {
    purchase: Purchase,
    cancelled,
    failure: Failure,
};

/// What `setHandler` registers. Called on the UI thread, between events,
/// once per update.
pub const Handler = *const fn (ctx: ?*anyopaque, update: Update) void;

/// Which half of Play's split `finish` means. Apple finishes both the
/// same way — it already knows the product type — so this exists for the
/// store that does not, and the app, which declared the product in the
/// console, is the one that knows.
pub const Disposition = enum {
    /// Spent: coins added, the credit consumed. Play: `consumeAsync`.
    consumed,
    /// Kept: an unlock, a subscription. Play: `acknowledgePurchase`.
    kept,
};

/// Play caps a query at 20 ids; Apple documents no cap. The tighter
/// bound is enforced on the Zig side everywhere, so `TooManyProducts`
/// means one thing on every platform — secure_store's rule for its value
/// cap.
pub const max_products = 20;

/// Both stores stay well inside this, and an id is a console-authored
/// constant rather than user data.
pub const max_id_bytes = 128;

pub const Error = error{
    /// There is no store on this platform, or the device cannot transact
    /// (parental restriction on Apple, no Play Store on Android). Ask
    /// `available` before drawing a paywall and this never appears.
    Unavailable,
    /// A payment sheet is already up. One at a time by design: the sheet
    /// is modal and a person can only be buying one thing at once —
    /// oauth's `AuthInFlight` argument.
    PurchaseInFlight,
    /// A catalog query is already out. One at a time for a softer
    /// reason: a paywall asks for its whole catalog in one call, because
    /// the id set is a parameter.
    QueryInFlight,
    /// More than `max_products` ids in one query.
    TooManyProducts,
    /// A query with no ids at all — a caller bug, refused loudly rather
    /// than answered with an empty catalog that looks like a store
    /// outage.
    NoProducts,
    /// Empty, over `max_id_bytes`, or outside `[a-z0-9._]` starting with
    /// `[a-z0-9]`. That charset is the intersection of the two stores'
    /// rules (Play's is the narrower, and lowercase-only), checked before
    /// any OS call — package_info's argument for the app id, applied to
    /// the products it sells.
    InvalidProductId,
} || std.mem.Allocator.Error;

/// Can this device transact at all? Cached at `App.init` — synchronous,
/// no OS call, no error — so it is legal inside `build`, where a
/// per-frame store query would not be, and an app can decide not to draw
/// a paywall before it draws anything. locale's boot-tag pattern.
///
/// False on Windows, Linux, and the web always; false on Apple under
/// parental restriction and on Android without the Play Store. Every
/// other verb answers `error.Unavailable` when this is false, so the
/// check is a courtesy to the user rather than a guard the app must not
/// forget.
pub fn available(app: *App) bool {
    checkLinked();
    return app.services.iap.state.?.can_buy;
}

/// Register the purchase-stream handler. Call it once, inside `build`.
/// Registering again replaces it (a rebuild re-registers the same one;
/// idempotent). The first registration installs the native observer,
/// which is what makes the store flush transactions it has been
/// holding — an interrupted purchase from a previous launch arrives as
/// an ordinary update immediately after, queued like every other, so it
/// lands at the next pump rather than inside the `build` that installed
/// it.
pub fn setHandler(app: *App, ctx: ?*anyopaque, handler: Handler) void {
    checkLinked();
    const st = app.services.iap.state.?;
    st.handler = handler;
    st.handler_ctx = ctx;
    st.install();
}

pub const ProductsOptions = struct {
    app: *App,
    /// The ids to price, borrowed for the call. Ask for the whole
    /// paywall at once: the store batches, and one query at a time is
    /// the contract.
    ids: []const []const u8,
    ctx: ?*anyopaque = null,
    on_result: *const fn (ctx: ?*anyopaque, catalog: Catalog) void,
};

/// Ask the store what it sells. One `Catalog` comes back on the UI
/// thread, exactly once. Under `zig test` a seeded catalog answers the
/// matching ids and an unseeded one parks for the harness
/// (docs/testing.md).
pub fn products(opts: ProductsOptions) Error!Handle {
    checkLinked();
    const st = opts.app.services.iap.state.?;
    if (!st.can_buy) return error.Unavailable;
    if (st.query != null) return error.QueryInFlight;
    if (opts.ids.len == 0) return error.NoProducts;
    if (opts.ids.len > max_products) return error.TooManyProducts;
    for (opts.ids) |id| try validateId(id);

    st.on_catalog = opts.on_result;
    st.catalog_ctx = opts.ctx;
    const ticket = try workers.openOneShot(Catalog, opts.app, st, dispatchCatalog);
    errdefer workers.cancelOneShot(ticket);
    st.query = ticket;
    errdefer st.query = null;
    try st.queryProducts(opts.ids);
    return .{ .ticket = ticket, .state = st };
}

/// Generation-checked, like a worker handle: after the catalog (or a
/// cancel) it is spent and every use is a no-op.
pub const Handle = struct {
    ticket: workers.Ticket,
    state: *ServiceState,

    /// `on_result` will never run after this. The store may still finish
    /// answering where the platform cannot abort a request — its
    /// delivery is dropped. UI thread only, idempotent.
    pub fn cancel(self: @This()) void {
        self.state.query = null;
        workers.cancelOneShot(self.ticket);
    }
};

pub const PurchaseOptions = struct {
    app: *App,
    /// The product id, as the store console spells it.
    product: []const u8,
    /// Play's subscription offer token, straight from `Product.offer`.
    /// Ignored everywhere else.
    offer: []const u8 = "",
};

/// Put the payment sheet on screen. The outcome arrives on the stream,
/// not here — including the user cancelling, which is `Update.cancelled`.
pub fn purchase(opts: PurchaseOptions) Error!void {
    checkLinked();
    const st = opts.app.services.iap.state.?;
    if (!st.can_buy) return error.Unavailable;
    if (st.buying) return error.PurchaseInFlight;
    try validateId(opts.product);
    st.buying = true;
    errdefer st.buying = false;
    try st.beginPurchase(opts.product, opts.offer);
}

/// Tell the store the goods were delivered. **Until this is called the
/// store redelivers the transaction on every launch** — that is the
/// crash-safety mechanism, not a bug, and it is why finishing is the
/// app's call: only the app knows when its backend has written the
/// entitlement. Play auto-refunds a purchase left unacknowledged for
/// three days.
///
/// Idempotent and unconditional: finishing a transaction the store has
/// forgotten is a no-op everywhere, so there is nothing here to fail and
/// nothing to check first.
pub fn finish(app: *App, transaction: []const u8, disposition: Disposition) void {
    checkLinked();
    app.services.iap.state.?.finishTransaction(transaction, disposition);
}

/// Replay what this account already owns; each one arrives on the stream
/// as `.restored`. Apple requires a visible control for it, which is why
/// it is a verb rather than something the service does on its own.
pub fn restore(app: *App) Error!void {
    checkLinked();
    const st = app.services.iap.state.?;
    if (!st.can_buy) return error.Unavailable;
    try st.restoreOwned();
}

/// Play's rules are the narrower of the two stores': a leading
/// `[a-z0-9]`, then `[a-z0-9._]`. Lowercase-only for secure_store's
/// reason — an id that is legal on the developer's Apple device and
/// rejected by the Play console is the failure this prevents, and it
/// should fail on the machine that typed it.
fn validateId(id: []const u8) Error!void {
    if (id.len == 0 or id.len > max_id_bytes) return error.InvalidProductId;
    if (!(std.ascii.isLower(id[0]) or std.ascii.isDigit(id[0]))) return error.InvalidProductId;
    for (id[1..]) |c| {
        if (!(std.ascii.isLower(c) or std.ascii.isDigit(c) or c == '.' or c == '_'))
            return error.InvalidProductId;
    }
}

/// Every catalog lands here first, on the UI thread: clear the query,
/// then hand the app what it asked for. Cleared before the callback so
/// the app may start the next query from inside its own handler.
fn dispatchCatalog(ctx: ?*anyopaque, catalog: Catalog) void {
    const st: *ServiceState = @ptrCast(@alignCast(ctx.?));
    const cb = st.on_catalog orelse return;
    const cb_ctx = st.catalog_ctx;
    st.query = null;
    cb(cb_ctx, catalog);
}

/// Every update lands here first. Anything but a `.restored` purchase
/// means the sheet is gone — a cancel, a decline, an approval, a
/// deferral — so the app may buy again; a restore replay never was a
/// sheet and must not clear one that is up.
fn dispatchUpdate(ctx: ?*anyopaque, update: Update) void {
    const st: *ServiceState = @ptrCast(@alignCast(ctx.?));
    const from_sheet = switch (update) {
        .purchase => |p| p.state != .restored,
        .cancelled, .failure => true,
    };
    if (from_sheet) st.buying = false;
    const h = st.handler orelse return;
    h(st.handler_ctx, update);
}

fn checkLinked() void {
    // Tests always run against the per-app mock (the only path compiled
    // under `zig test`), so linking is not required there. A release
    // build that skipped linking still cannot ship: the curated error
    // names the one-line fix — secure_store's rule.
    comptime if (!options.linked and !builtin.is_test) @compileError(
        \\the iap service is not linked. Pass .iap = true (plus .pkg_id — the
        \\stores resolve products against the app's identity) to the nokre
        \\dependency in build.zig. On Android the Play Billing Library is one
        \\line the consumer adds to their own app/build.gradle; nokre has no
        \\dependency manager to add it for them. docs/services.md.
    );
}

/// What the App carries for this service: the journaling mock under
/// `zig test`, the store-facing platform state in release. Both keep
/// per-app state, so both heap-allocate it in `init` — the address must
/// survive the by-value moves a stack App makes, because the native
/// install hands that pointer to the platform.
pub const Service = if (builtin.is_test) Mock else PlatformService;

/// The heap half either way, so `Handle` names one type. Not called
/// `State`: the consumer enum above owns that name, and a purchase's
/// state is what an app reads far more often than this.
pub const ServiceState = if (builtin.is_test) MockState else PlatformState;

// ---- the release-side state ----

const PlatformState = struct {
    gpa: std.mem.Allocator,
    runtime: *workers.Runtime,
    /// The boot answer, read once and cached (see `available`).
    can_buy: bool = false,
    handler: ?Handler = null,
    handler_ctx: ?*anyopaque = null,
    installed: bool = false,
    /// The live catalog query's delivery slot, spent by the trampoline
    /// that reaches it — the guard that keeps a store answering twice
    /// from becoming two catalogs.
    query: ?workers.Ticket = null,
    on_catalog: ?*const fn (ctx: ?*anyopaque, catalog: Catalog) void = null,
    catalog_ctx: ?*anyopaque = null,
    /// True from `purchase` until the sheet resolves.
    buying: bool = false,

    // Every native call sits behind a `switch (leg)` rather than an
    // early return: `leg` is comptime-known, so only the matching prong
    // is analyzed, and a storeless target therefore never names an
    // extern its build did not compile. `.none` cannot actually be
    // reached at runtime — `can_buy` is false there and every verb stops
    // at `error.Unavailable` — but the switch is what keeps the compiler
    // from looking.

    fn install(self: *PlatformState) void {
        if (self.installed) return;
        switch (leg) {
            .none => {},
            else => {
                self.installed = true;
                native.nokre_iap_install(self, updateC);
            },
        }
    }

    fn queryProducts(self: *PlatformState, ids: []const []const u8) Error!void {
        switch (leg) {
            .none => return error.Unavailable,
            else => {
                // Stack arrays, no allocation: the cap is what makes
                // that possible, and the caps are contract
                // (secure_store's rule).
                var ptrs: [max_products][*]const u8 = undefined;
                var lens: [max_products]usize = undefined;
                for (ids, 0..) |id, i| {
                    ptrs[i] = id.ptr;
                    lens[i] = id.len;
                }
                native.nokre_iap_products(self, productsC, &ptrs, &lens, ids.len);
            },
        }
    }

    fn beginPurchase(self: *PlatformState, product: []const u8, offer: []const u8) Error!void {
        switch (leg) {
            .none => return error.Unavailable,
            else => {
                const rc = native.nokre_iap_purchase(product.ptr, product.len, offer.ptr, offer.len);
                // A sheet that could not be shown still owes exactly one
                // update, and owes it the same way every other arrives:
                // queued, on the UI thread, after `purchase` returned.
                if (rc != 0) self.postUpdate(.{
                    .failure = .{
                        // "UnknownProduct" is the one an app can act on: it
                        // means this id was never priced, and neither store
                        // will sell what it has not described.
                        .name = if (rc == err_no_product) "UnknownProduct" else "SheetUnavailable",
                    },
                });
            },
        }
    }

    fn finishTransaction(self: *PlatformState, txn: []const u8, disposition: Disposition) void {
        _ = self;
        switch (leg) {
            .none => {},
            else => native.nokre_iap_finish(txn.ptr, txn.len, @intFromBool(disposition == .consumed)),
        }
    }

    fn restoreOwned(self: *PlatformState) Error!void {
        _ = self;
        switch (leg) {
            .none => return error.Unavailable,
            else => native.nokre_iap_restore(),
        }
    }

    /// The stream has no parked slot to spend, so each update opens its
    /// own and delivers immediately. Queued rather than called inline
    /// because this runs inside a StoreKit delegate or a Billing
    /// listener frame, and app code only ever runs between events — the
    /// same reason oauth's results do not call back from the platform's
    /// own stack. An update that cannot be queued is dropped rather than
    /// reordered: the store will redeliver an unfinished purchase at the
    /// next launch, which is exactly the situation `finish` exists for.
    fn postUpdate(self: *PlatformState, update: Update) void {
        // A dropped sheet-level update must still release the one-sheet
        // guard dispatchUpdate would have cleared, or `buying` refuses
        // every purchase for the rest of the run.
        const from_sheet = switch (update) {
            .purchase => |p| p.state != .restored,
            .cancelled, .failure => true,
        };
        const ticket = workers.openOneShotOn(Update, self.runtime, self, dispatchUpdate) catch {
            if (from_sheet) self.buying = false;
            return;
        };
        workers.deliverOneShot(Update, ticket, self.gpa, update) catch {
            workers.cancelOneShot(ticket);
            if (from_sheet) self.buying = false;
        };
    }

    fn deliverCatalog(self: *PlatformState, catalog: Catalog) void {
        const ticket = self.query orelse return;
        self.query = null;
        workers.deliverOneShot(Catalog, ticket, self.gpa, catalog) catch {
            workers.deliverOneShot(Catalog, ticket, self.gpa, .{
                .failure = .{ .name = "OutOfMemory" },
            }) catch {};
        };
    }
};

/// The catalog trampoline: `ctx` is the per-service state, so no global
/// is consulted. Runs on the main thread (the platform's promise),
/// exactly once per query.
fn productsC(
    ctx: ?*anyopaque,
    items: ?[*]const native.Product,
    count: usize,
    err: [*]const u8,
    err_len: usize,
) callconv(.c) void {
    const st: *PlatformState = @ptrCast(@alignCast(ctx.?));
    if (err_len != 0) return st.deliverCatalog(.{ .failure = .{ .name = err[0..err_len] } });

    // Translated onto the stack, not the heap: the cap bounds the row
    // count, `deliverOneShot` copies every byte into the frame, and the
    // native rows die when this returns. A row past the cap is dropped
    // rather than truncating the strings inside it — the app asked for
    // at most `max_products` ids, so a store answering with more is
    // answering something nobody asked.
    var rows: [max_products]Product = undefined;
    var n: usize = 0;
    if (items) |src| {
        for (src[0..@min(count, max_products)]) |p| {
            rows[n] = .{
                .id = p.id[0..p.id_len],
                .title = p.title[0..p.title_len],
                .description = p.description[0..p.description_len],
                .price = p.price[0..p.price_len],
                .currency = p.currency[0..p.currency_len],
                .offer = p.offer[0..p.offer_len],
                .price_micros = @intCast(p.price_micros),
                // A kind this build does not know maps to `unknown`
                // rather than trapping: the enum's job is to carry what
                // the store said, and a newer store saying something
                // newer must not crash an older binary.
                .kind = std.enums.fromInt(Kind, p.kind) orelse .unknown,
            };
            n += 1;
        }
    }
    st.deliverCatalog(.{ .products = rows[0..n] });
}

/// The stream trampoline. Same footing, and no session pointer to drop:
/// the observer stays installed for the app's whole life.
fn updateC(
    ctx: ?*anyopaque,
    status: c_int,
    txn: [*]const u8,
    txn_len: usize,
    product: [*]const u8,
    product_len: usize,
    token: [*]const u8,
    token_len: usize,
    err: [*]const u8,
    err_len: usize,
) callconv(.c) void {
    const st: *PlatformState = @ptrCast(@alignCast(ctx.?));
    st.postUpdate(switch (status) {
        status_purchased, status_pending, status_restored => .{ .purchase = .{
            .id = txn[0..txn_len],
            .product = product[0..product_len],
            .token = token[0..token_len],
            .state = switch (status) {
                status_pending => .pending,
                status_restored => .restored,
                else => .purchased,
            },
        } },
        status_cancelled => .cancelled,
        else => .{ .failure = .{ .name = if (err_len == 0) "PurchaseFailed" else err[0..err_len] } },
    });
}

const PlatformService = struct {
    state: ?*PlatformState = null,
    gpa: std.mem.Allocator = undefined,

    pub fn init(self: *PlatformService, gpa: std.mem.Allocator, runtime: *workers.Runtime) !void {
        const state = try gpa.create(PlatformState);
        state.* = .{
            .gpa = gpa,
            .runtime = runtime,
            // The one OS call at boot, and the reason `available` needs
            // none later. A storeless target never names the extern.
            .can_buy = switch (leg) {
                .none => false,
                else => native.nokre_iap_available() != 0,
            },
        };
        self.state = state;
        self.gpa = gpa;
    }

    pub fn deinit(self: *PlatformService) void {
        const state = self.state orelse return;
        // The observer lives for the process, but the ctx it holds is
        // this state, freed two lines down — a transaction update after
        // deinit (or into a second App lifetime) must find no callback,
        // not freed memory. oauth's release-on-deinit rule, applied to
        // an install-once stream.
        if (state.installed) {
            switch (leg) {
                .none => {},
                else => native.nokre_iap_uninstall(),
            }
        }
        if (state.query) |t| workers.cancelOneShot(t);
        self.gpa.destroy(state);
        self.state = null;
    }
};

// ---- the deterministic test surface (docs/testing.md) ----
// One app's fake store: queries and purchases are journaled with exactly
// what the app asked for, and nothing moves until the test — or a seeded
// catalog — answers. So "the app charged for the wrong SKU", "the app
// never finished the transaction", and "the app has no Restore control"
// are assertions rather than hopes.

/// A catalog query the app made, as owned copies.
pub const Query = struct { ids: []const []const u8 };

/// A `purchase` call the app made, as owned copies.
pub const Attempt = struct { product: []const u8, offer: []const u8 };

/// A `finish` call the app made, as owned copies.
pub const Completion = struct { transaction: []const u8, disposition: Disposition };

/// The mock's heap half, allocated by App.init so its address is stable
/// across the by-value moves a stack App makes.
pub const MockState = struct {
    gpa: std.mem.Allocator,
    runtime: *workers.Runtime,
    can_buy: bool = true,
    handler: ?Handler = null,
    handler_ctx: ?*anyopaque = null,
    installed: bool = false,
    query: ?workers.Ticket = null,
    on_catalog: ?*const fn (ctx: ?*anyopaque, catalog: Catalog) void = null,
    catalog_ctx: ?*anyopaque = null,
    buying: bool = false,
    /// Seeds, applied at App.init and never mutated after.
    catalog: []const Product = &.{},
    auto: ?Outcome = null,
    /// Journals.
    queries: std.ArrayList(Query) = .empty,
    attempts: std.ArrayList(Attempt) = .empty,
    completions: std.ArrayList(Completion) = .empty,
    restores: usize = 0,
    /// Synthesized transaction ids, so an auto outcome is byte-stable
    /// across runs and still distinct across purchases.
    minted: std.ArrayList([]u8) = .empty,

    fn install(self: *MockState) void {
        self.installed = true;
    }

    fn queryProducts(self: *MockState, ids: []const []const u8) Error!void {
        try self.record(ids);
        // A seeded catalog answers the ids it knows and drops the rest,
        // which is what a store does; an unseeded one parks for the
        // harness's deliverProducts / failProducts — the http mock's
        // split between a fake server and answering by hand.
        if (self.catalog.len == 0) return;
        var rows: [max_products]Product = undefined;
        var n: usize = 0;
        for (ids) |want| {
            for (self.catalog) |p| {
                if (std.mem.eql(u8, p.id, want)) {
                    rows[n] = p;
                    n += 1;
                    break;
                }
            }
        }
        self.deliverCatalog(.{ .products = rows[0..n] });
    }

    fn record(self: *MockState, ids: []const []const u8) Error!void {
        const g = self.gpa;
        const owned = try g.alloc([]const u8, ids.len);
        errdefer g.free(owned);
        var filled: usize = 0;
        errdefer for (owned[0..filled]) |s| g.free(s);
        for (ids, 0..) |id, i| {
            owned[i] = try g.dupe(u8, id);
            filled = i + 1;
        }
        try self.queries.append(g, .{ .ids = owned });
    }

    fn beginPurchase(self: *MockState, product: []const u8, offer: []const u8) Error!void {
        const g = self.gpa;
        const p = try g.dupe(u8, product);
        errdefer g.free(p);
        const o = try g.dupe(u8, offer);
        errdefer g.free(o);
        try self.attempts.append(g, .{ .product = p, .offer = o });
        // A seeded outcome answers immediately — queued, so it still
        // lands at a pump like every other delivery, never inside
        // `purchase`. Without one the sheet stays up for the harness's
        // deliverPurchase / cancelPurchase / failPurchase.
        if (self.auto) |outcome| self.answer(product, outcome);
    }

    fn finishTransaction(self: *MockState, txn: []const u8, disposition: Disposition) void {
        const g = self.gpa;
        const owned = g.dupe(u8, txn) catch @panic("iap mock: allocator failed");
        self.completions.append(g, .{
            .transaction = owned,
            .disposition = disposition,
        }) catch @panic("iap mock: allocator failed");
    }

    fn restoreOwned(self: *MockState) Error!void {
        self.restores += 1;
    }

    fn postUpdate(self: *MockState, update: Update) void {
        const ticket = workers.openOneShotOn(Update, self.runtime, self, dispatchUpdate) catch return;
        workers.deliverOneShot(Update, ticket, self.gpa, update) catch workers.cancelOneShot(ticket);
    }

    fn deliverCatalog(self: *MockState, catalog: Catalog) void {
        const ticket = self.query orelse return;
        self.query = null;
        workers.deliverOneShot(Catalog, ticket, self.gpa, catalog) catch
            @panic("iap mock: allocator failed");
    }

    /// The store answering a live sheet. `product` is what the app asked
    /// for, so a synthesized purchase names the right SKU.
    fn answer(self: *MockState, product: []const u8, outcome: Outcome) void {
        switch (outcome) {
            .cancelled => self.postUpdate(.cancelled),
            .failure => |name| self.postUpdate(.{ .failure = .{ .name = name } }),
            .purchased => self.mint(product, .purchased),
            .pending => self.mint(product, .pending),
        }
    }

    /// A transaction the mock invented: numbered, so two purchases in
    /// one test are distinguishable, and prefixed, so a failure message
    /// says where the value came from. A test allocator giving out is a
    /// crash, not an outcome (deep_link's mock rule).
    fn mint(self: *MockState, product: []const u8, state: State) void {
        const g = self.gpa;
        const n = self.minted.items.len / 2 + 1;
        const id = std.fmt.allocPrint(g, "{s}{d}", .{ Mock.txn_prefix, n }) catch
            @panic("iap mock: allocator failed");
        self.minted.append(g, id) catch @panic("iap mock: allocator failed");
        const token = std.fmt.allocPrint(g, "{s}{d}", .{ Mock.token_prefix, n }) catch
            @panic("iap mock: allocator failed");
        self.minted.append(g, token) catch @panic("iap mock: allocator failed");
        self.postUpdate(.{ .purchase = .{
            .id = id,
            .product = product,
            .token = token,
            .state = state,
        } });
    }
};

/// What the payment sheet does, seeded. The purchased and pending arms
/// synthesize a deterministic transaction id and token; a test that
/// needs exact values uses the harness's `deliverPurchase` instead.
pub const Outcome = union(enum) {
    purchased,
    pending,
    cancelled,
    failure: []const u8,
};

pub const Mock = struct {
    boot: Config = .{},
    /// The heap half; null only before App.init.
    state: ?*MockState = null,

    /// Seeded, not random, and seeded with something that reads as a
    /// test value in a failure message. A purchase flow rendered in a
    /// golden must stay byte-stable across runs.
    pub const txn_prefix = "nokre-test-txn-";
    pub const token_prefix = "nokre-test-token-";

    pub const Config = struct {
        /// False boots the app onto a storeless platform — Windows,
        /// Linux, the web, or a restricted device — where `available` is
        /// false and every verb is `error.Unavailable`.
        available: bool = true,
        /// The store's shelf. A query answers with the rows whose ids it
        /// asked for; an empty catalog parks every query for the harness
        /// to answer by hand. Slices are borrowed for the app's life, so
        /// a `const` table in the test file is the natural shape.
        catalog: []const Product = &.{},
        /// What the payment sheet does. Null leaves it up.
        auto: ?Outcome = null,
    };

    pub fn mock(config: Config) Mock {
        return .{ .boot = config };
    }

    pub fn init(self: *Mock, gpa: std.mem.Allocator, runtime: *workers.Runtime) !void {
        const state = try gpa.create(MockState);
        state.* = .{
            .gpa = gpa,
            .runtime = runtime,
            .can_buy = self.boot.available,
            .catalog = self.boot.catalog,
            .auto = self.boot.auto,
        };
        self.state = state;
    }

    pub fn deinit(self: *Mock) void {
        const state = self.state orelse return;
        const g = state.gpa;
        for (state.queries.items) |q| {
            for (q.ids) |id| g.free(id);
            g.free(q.ids);
        }
        state.queries.deinit(g);
        for (state.attempts.items) |a| {
            g.free(a.product);
            g.free(a.offer);
        }
        state.attempts.deinit(g);
        for (state.completions.items) |c| g.free(c.transaction);
        state.completions.deinit(g);
        for (state.minted.items) |m| g.free(m);
        state.minted.deinit(g);
        if (state.query) |t| workers.cancelOneShot(t);
        g.destroy(state);
        self.state = null;
    }

    /// Every catalog query this app made, in order — the assertion
    /// surface for "did the paywall ask for the right SKUs".
    pub fn queries(self: Mock) []const Query {
        return self.state.?.queries.items;
    }

    /// Every `purchase` call this app made, in order.
    pub fn purchases(self: Mock) []const Attempt {
        return self.state.?.attempts.items;
    }

    /// Every `finish` call, with its disposition — so "the app never
    /// finished the transaction" and "the app consumed an unlock" are
    /// both assertions.
    pub fn completions(self: Mock) []const Completion {
        return self.state.?.completions.items;
    }

    /// How many times the app offered to restore. Apple requires a
    /// visible control, so zero is a finding.
    pub fn restores(self: Mock) usize {
        return self.state.?.restores;
    }

    /// Whether a payment sheet is up, waiting for the test to answer.
    pub fn sheetUp(self: Mock) bool {
        return self.state.?.buying;
    }

    /// Whether a catalog query is parked.
    pub fn queryParked(self: Mock) bool {
        return self.state.?.query != null;
    }

    /// The store answered the parked query. Queued like every delivery —
    /// the harness's `deliverProducts` adds the pump and the re-audit.
    pub fn deliverProducts(self: Mock, rows: []const Product) void {
        self.state.?.deliverCatalog(.{ .products = rows });
    }

    /// The query failed by name — `failHttp`'s twin for the catalog.
    pub fn failProducts(self: Mock, name: []const u8) void {
        self.state.?.deliverCatalog(.{ .failure = .{ .name = name } });
    }

    /// A purchase arrived on the stream: the answer to a live sheet, or
    /// an unsolicited one — a restore replay, an Ask-to-Buy approval, a
    /// renewal. The mock does not care which, because neither does the
    /// app's handler.
    pub fn deliverPurchase(self: Mock, p: Purchase) void {
        self.state.?.postUpdate(.{ .purchase = p });
    }

    /// The user dismissed the payment sheet.
    pub fn cancelPurchase(self: Mock) void {
        self.state.?.postUpdate(.cancelled);
    }

    /// The purchase failed by name — the declined-card case, one call.
    pub fn failPurchase(self: Mock, name: []const u8) void {
        self.state.?.postUpdate(.{ .failure = .{ .name = name } });
    }
};

// Force the linked paths to compile per target (the secure_store
// forcing, src/nokre.zig): under check-targets' compile-only objects
// nothing on the consumer side calls these, so their references to the
// native externs would go unanalyzed. Guarded on `options.linked` so an
// unlinked build never trips the curated @compileError.
comptime {
    if (options.linked and !builtin.is_test) {
        _ = &available;
        _ = &setHandler;
        _ = &products;
        _ = &purchase;
        _ = &finish;
        _ = &restore;
    }
}
