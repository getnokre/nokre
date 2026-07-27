//! iap service tests: the consumer surface driven through the per-app
//! mock — the only store under `zig test`, so what holds here is the
//! whole contract. docs/services.md is the contract; the design behind
//! it is docs/internals/iap.md.

const std = @import("std");
const iap = @import("iap.zig");
const app_mod = @import("../../core/app.zig");
const tree_mod = @import("../../core/tree.zig");
const harness_mod = @import("../../testing/harness.zig");

const App = app_mod.App;
const Harness = harness_mod.Harness;

/// Prices are strings the store formatted, so a test writes down exactly
/// what a paywall would draw — and the same bytes every run.
const shelf = [_]iap.Product{
    .{
        .id = "coins.100",
        .title = "100 coins",
        .description = "A hundred coins.",
        .price = "$4.99",
        .currency = "USD",
        .offer = "",
        .price_micros = 4_990_000,
        .kind = .consumable,
    },
    .{
        .id = "pro.month",
        .title = "Pro, monthly",
        .description = "Everything, every month.",
        .price = "$9.99",
        .currency = "USD",
        .offer = "offer-token-1",
        .price_micros = 9_990_000,
        .kind = .subscription,
    },
};

fn testApp(gpa: std.mem.Allocator) !App {
    return App.init(gpa, .{ .viewport = .{ .w = 320, .h = 240 }, .services = .mocks() });
}

fn stockedApp(gpa: std.mem.Allocator, config: iap.Mock.Config) !App {
    return App.init(gpa, .{
        .viewport = .{ .w = 320, .h = 240 },
        .services = .{ .iap = .mock(config) },
    });
}

/// The catalog's landing pad.
const Shopper = struct {
    calls: u32 = 0,
    failed: bool = false,
    rows: usize = 0,
    buf: [128]u8 = undefined,
    len: usize = 0,

    fn onCatalog(ctx: ?*anyopaque, catalog: iap.Catalog) void {
        const self: *Shopper = @ptrCast(@alignCast(ctx.?));
        self.calls += 1;
        switch (catalog) {
            .products => |rows| {
                self.rows = rows.len;
                // The first row's price, copied: the slices die with the
                // call, which is the contract a test should prove it
                // respects rather than assume.
                if (rows.len != 0) self.take(rows[0].price);
            },
            .failure => |f| {
                self.failed = true;
                self.take(f.name);
            },
        }
    }

    fn take(self: *Shopper, bytes: []const u8) void {
        self.len = @min(bytes.len, self.buf.len);
        @memcpy(self.buf[0..self.len], bytes[0..self.len]);
    }

    fn text(self: *const Shopper) []const u8 {
        return self.buf[0..self.len];
    }
};

/// The purchase stream's landing pad: every update, in order.
const Wallet = struct {
    updates: u32 = 0,
    cancels: u32 = 0,
    failures: u32 = 0,
    last_state: ?iap.State = null,
    id_buf: [64]u8 = undefined,
    id_len: usize = 0,
    product_buf: [64]u8 = undefined,
    product_len: usize = 0,

    fn onUpdate(ctx: ?*anyopaque, update: iap.Update) void {
        const self: *Wallet = @ptrCast(@alignCast(ctx.?));
        self.updates += 1;
        switch (update) {
            .purchase => |p| {
                self.last_state = p.state;
                self.id_len = @min(p.id.len, self.id_buf.len);
                @memcpy(self.id_buf[0..self.id_len], p.id[0..self.id_len]);
                self.product_len = @min(p.product.len, self.product_buf.len);
                @memcpy(self.product_buf[0..self.product_len], p.product[0..self.product_len]);
            },
            .cancelled => self.cancels += 1,
            .failure => self.failures += 1,
        }
    }

    fn id(self: *const Wallet) []const u8 {
        return self.id_buf[0..self.id_len];
    }

    fn product(self: *const Wallet) []const u8 {
        return self.product_buf[0..self.product_len];
    }
};

// ---- available: the answer three platforms give, and every verb after ----

test "a storeless platform answers false and refuses every verb" {
    var app = try stockedApp(std.testing.allocator, .{ .available = false });
    defer app.deinit();

    // Windows, Linux, the web, and a restricted device all land here.
    try std.testing.expect(!iap.available(&app));

    var shopper: Shopper = .{};
    try std.testing.expectError(error.Unavailable, iap.products(.{
        .app = &app,
        .ids = &.{"coins.100"},
        .ctx = &shopper,
        .on_result = Shopper.onCatalog,
    }));
    try std.testing.expectError(error.Unavailable, iap.purchase(.{
        .app = &app,
        .product = "coins.100",
    }));
    try std.testing.expectError(error.Unavailable, iap.restore(&app));
}

test "available is true wherever a store answered at boot" {
    var app = try testApp(std.testing.allocator);
    defer app.deinit();
    try std.testing.expect(iap.available(&app));
}

// ---- the catalog ----

test "a seeded catalog answers the ids asked for, at the pump" {
    var app = try stockedApp(std.testing.allocator, .{ .catalog = &shelf });
    defer app.deinit();

    var shopper: Shopper = .{};
    _ = try iap.products(.{
        .app = &app,
        .ids = &.{ "coins.100", "pro.month" },
        .ctx = &shopper,
        .on_result = Shopper.onCatalog,
    });
    // Queued like every delivery: nothing runs inside `products`.
    try std.testing.expectEqual(@as(u32, 0), shopper.calls);
    app.runtime.pumpAll();

    try std.testing.expectEqual(@as(u32, 1), shopper.calls);
    try std.testing.expectEqual(@as(usize, 2), shopper.rows);
    // The price is the store's string, verbatim — nokre formats no money.
    try std.testing.expectEqualStrings("$4.99", shopper.text());
}

test "an id the store does not sell is simply absent, not a failure" {
    var app = try stockedApp(std.testing.allocator, .{ .catalog = &shelf });
    defer app.deinit();

    var shopper: Shopper = .{};
    _ = try iap.products(.{
        .app = &app,
        .ids = &.{ "coins.100", "coins.500" },
        .ctx = &shopper,
        .on_result = Shopper.onCatalog,
    });
    app.runtime.pumpAll();

    try std.testing.expect(!shopper.failed);
    try std.testing.expectEqual(@as(usize, 1), shopper.rows);
}

test "an unseeded catalog parks until the test answers" {
    var app = try testApp(std.testing.allocator);
    defer app.deinit();

    var shopper: Shopper = .{};
    _ = try iap.products(.{
        .app = &app,
        .ids = &.{"coins.100"},
        .ctx = &shopper,
        .on_result = Shopper.onCatalog,
    });
    app.runtime.pumpAll();
    try std.testing.expectEqual(@as(u32, 0), shopper.calls);
    try std.testing.expect(app.services.iap.queryParked());

    app.services.iap.deliverProducts(&shelf);
    app.runtime.pumpAll();
    try std.testing.expectEqual(@as(u32, 1), shopper.calls);
    try std.testing.expectEqual(@as(usize, 2), shopper.rows);
}

test "a failed query arrives as a stable name, http's posture" {
    var app = try testApp(std.testing.allocator);
    defer app.deinit();

    var shopper: Shopper = .{};
    _ = try iap.products(.{
        .app = &app,
        .ids = &.{"coins.100"},
        .ctx = &shopper,
        .on_result = Shopper.onCatalog,
    });
    app.services.iap.failProducts("StoreUnavailable");
    app.runtime.pumpAll();

    try std.testing.expect(shopper.failed);
    try std.testing.expectEqualStrings("StoreUnavailable", shopper.text());
}

test "one query at a time; the next one starts once the first lands" {
    var app = try testApp(std.testing.allocator);
    defer app.deinit();

    var shopper: Shopper = .{};
    const opts: iap.ProductsOptions = .{
        .app = &app,
        .ids = &.{"coins.100"},
        .ctx = &shopper,
        .on_result = Shopper.onCatalog,
    };
    _ = try iap.products(opts);
    try std.testing.expectError(error.QueryInFlight, iap.products(opts));

    // The slot is spent when the store answers, not when the app's
    // callback runs — so the next query may be issued from inside the
    // handler, which is where a paywall's second page would issue it.
    app.services.iap.deliverProducts(&shelf);
    _ = try iap.products(opts);
    app.services.iap.deliverProducts(&shelf);
    app.runtime.pumpAll();
    try std.testing.expectEqual(@as(u32, 2), shopper.calls);
}

test "cancelling a query means no callback at all" {
    var app = try stockedApp(std.testing.allocator, .{ .catalog = &shelf });
    defer app.deinit();

    var shopper: Shopper = .{};
    const handle = try iap.products(.{
        .app = &app,
        .ids = &.{"coins.100"},
        .ctx = &shopper,
        .on_result = Shopper.onCatalog,
    });
    handle.cancel();
    app.runtime.pumpAll();
    try std.testing.expectEqual(@as(u32, 0), shopper.calls);
}

// ---- the caps and the charset: pure functions of the argument ----

test "the id charset is the two stores' intersection, checked before any call" {
    var app = try testApp(std.testing.allocator);
    defer app.deinit();
    var shopper: Shopper = .{};

    const cases = [_][]const u8{
        "Coins.100", // uppercase: legal on Apple, rejected by the Play console
        "-coins", // must start with a letter or digit
        "coins/100", // no path characters
        "", // empty
    };
    for (cases) |bad| {
        try std.testing.expectError(error.InvalidProductId, iap.products(.{
            .app = &app,
            .ids = &.{bad},
            .ctx = &shopper,
            .on_result = Shopper.onCatalog,
        }));
        try std.testing.expectError(error.InvalidProductId, iap.purchase(.{
            .app = &app,
            .product = bad,
        }));
    }
    // A refused query never reached the store.
    try std.testing.expectEqual(@as(usize, 0), app.services.iap.queries().len);
}

test "the query cap is Play's, enforced on every platform" {
    var app = try testApp(std.testing.allocator);
    defer app.deinit();
    var shopper: Shopper = .{};

    var many: [iap.max_products + 1][]const u8 = undefined;
    for (&many) |*slot| slot.* = "coins.100";
    try std.testing.expectError(error.TooManyProducts, iap.products(.{
        .app = &app,
        .ids = &many,
        .ctx = &shopper,
        .on_result = Shopper.onCatalog,
    }));
    try std.testing.expectError(error.NoProducts, iap.products(.{
        .app = &app,
        .ids = &.{},
        .ctx = &shopper,
        .on_result = Shopper.onCatalog,
    }));
}

// ---- the purchase stream ----

test "a seeded purchase lands on the stream, not on the purchase call" {
    var app = try stockedApp(std.testing.allocator, .{ .auto = .purchased });
    defer app.deinit();

    var wallet: Wallet = .{};
    iap.setHandler(&app, &wallet, Wallet.onUpdate);
    try iap.purchase(.{ .app = &app, .product = "coins.100" });
    try std.testing.expectEqual(@as(u32, 0), wallet.updates);
    app.runtime.pumpAll();

    try std.testing.expectEqual(@as(u32, 1), wallet.updates);
    try std.testing.expectEqual(iap.State.purchased, wallet.last_state.?);
    try std.testing.expectEqualStrings("coins.100", wallet.product());
    // Seeded, not random: the same transaction id every run.
    try std.testing.expectEqualStrings("nokre-test-txn-1", wallet.id());
}

test "cancelling is a value on the stream, not an error at the call" {
    var app = try stockedApp(std.testing.allocator, .{ .auto = .cancelled });
    defer app.deinit();

    var wallet: Wallet = .{};
    iap.setHandler(&app, &wallet, Wallet.onUpdate);
    try iap.purchase(.{ .app = &app, .product = "coins.100" });
    app.runtime.pumpAll();

    try std.testing.expectEqual(@as(u32, 1), wallet.cancels);
}

test "pending is first class: the money has not moved and the app is told so" {
    var app = try stockedApp(std.testing.allocator, .{ .auto = .pending });
    defer app.deinit();

    var wallet: Wallet = .{};
    iap.setHandler(&app, &wallet, Wallet.onUpdate);
    try iap.purchase(.{ .app = &app, .product = "coins.100" });
    app.runtime.pumpAll();
    try std.testing.expectEqual(iap.State.pending, wallet.last_state.?);

    // The approval arrives later — a different day, in the real world,
    // and with no call from the app to trigger it.
    app.services.iap.deliverPurchase(.{
        .id = "txn-77",
        .product = "coins.100",
        .token = "opaque",
        .state = .purchased,
    });
    app.runtime.pumpAll();
    try std.testing.expectEqual(@as(u32, 2), wallet.updates);
    try std.testing.expectEqual(iap.State.purchased, wallet.last_state.?);
}

test "an unsolicited purchase reaches the handler with nothing asked for" {
    var app = try testApp(std.testing.allocator);
    defer app.deinit();

    var wallet: Wallet = .{};
    iap.setHandler(&app, &wallet, Wallet.onUpdate);
    // The launch flush: a purchase from a previous run that was never
    // finished, redelivered by the store the moment the observer exists.
    app.services.iap.deliverPurchase(.{
        .id = "txn-earlier",
        .product = "pro.month",
        .token = "opaque",
        .state = .purchased,
    });
    app.runtime.pumpAll();

    try std.testing.expectEqual(@as(u32, 1), wallet.updates);
    try std.testing.expectEqualStrings("txn-earlier", wallet.id());
    try std.testing.expectEqual(@as(usize, 0), app.services.iap.purchases().len);
}

test "one payment sheet at a time; the next opens once the first resolves" {
    var app = try testApp(std.testing.allocator);
    defer app.deinit();

    var wallet: Wallet = .{};
    iap.setHandler(&app, &wallet, Wallet.onUpdate);
    try iap.purchase(.{ .app = &app, .product = "coins.100" });
    try std.testing.expectError(error.PurchaseInFlight, iap.purchase(.{
        .app = &app,
        .product = "coins.100",
    }));

    app.services.iap.cancelPurchase();
    app.runtime.pumpAll();
    try iap.purchase(.{ .app = &app, .product = "pro.month", .offer = "offer-token-1" });

    const attempts = app.services.iap.purchases();
    try std.testing.expectEqual(@as(usize, 2), attempts.len);
    try std.testing.expectEqualStrings("pro.month", attempts[1].product);
    try std.testing.expectEqualStrings("offer-token-1", attempts[1].offer);
}

test "a restore replay never clears a live payment sheet" {
    var app = try testApp(std.testing.allocator);
    defer app.deinit();

    var wallet: Wallet = .{};
    iap.setHandler(&app, &wallet, Wallet.onUpdate);
    try iap.purchase(.{ .app = &app, .product = "coins.100" });
    // Restored purchases were never a sheet, so one arriving mid-flow
    // must not make the app think its own sheet is gone.
    app.services.iap.deliverPurchase(.{
        .id = "txn-old",
        .product = "pro.month",
        .token = "opaque",
        .state = .restored,
    });
    app.runtime.pumpAll();
    try std.testing.expectError(error.PurchaseInFlight, iap.purchase(.{
        .app = &app,
        .product = "coins.100",
    }));
}

test "updates before a handler exists are dropped, never queued forever" {
    var app = try testApp(std.testing.allocator);
    defer app.deinit();

    // No setHandler: the app has not wired the stream yet. The update
    // still travels the lane and lands nowhere, which is data — the app
    // simply has not registered.
    app.services.iap.cancelPurchase();
    app.runtime.pumpAll();

    var wallet: Wallet = .{};
    iap.setHandler(&app, &wallet, Wallet.onUpdate);
    app.services.iap.cancelPurchase();
    app.runtime.pumpAll();
    try std.testing.expectEqual(@as(u32, 1), wallet.updates);
}

// ---- finish and restore ----

test "finish journals the disposition, because Play's two halves differ" {
    var app = try testApp(std.testing.allocator);
    defer app.deinit();

    iap.finish(&app, "txn-1", .consumed);
    iap.finish(&app, "txn-2", .kept);

    const done = app.services.iap.completions();
    try std.testing.expectEqual(@as(usize, 2), done.len);
    try std.testing.expectEqualStrings("txn-1", done[0].transaction);
    try std.testing.expectEqual(iap.Disposition.consumed, done[0].disposition);
    try std.testing.expectEqual(iap.Disposition.kept, done[1].disposition);
}

test "restore is counted, so a missing Restore control is a finding" {
    var app = try testApp(std.testing.allocator);
    defer app.deinit();

    try std.testing.expectEqual(@as(usize, 0), app.services.iap.restores());
    try iap.restore(&app);
    try std.testing.expectEqual(@as(usize, 1), app.services.iap.restores());
}

// ---- the harness: the same story, at the level a screen test reads ----

const Screen = struct {
    app: *App = undefined,
    price_node: tree_mod.NodeId = undefined,
    wallet: Wallet = .{},
    price: [32]u8 = undefined,
    price_len: usize = 0,

    fn build(ctx: ?*anyopaque, app: *App) anyerror!void {
        const self: *Screen = @ptrCast(@alignCast(ctx.?));
        iap.setHandler(app, self, Screen.onUpdate);
        self.price_node = try app.tree.append(app.tree.rootId(), .{ .text = .{
            .content = "Loading…",
        } });
        _ = try app.tree.append(app.tree.rootId(), .{ .button = .{
            .label = "Buy coins",
            .on_press = .{ .ctx = self, .call = Screen.buy },
        } });
    }

    fn onCatalog(ctx: ?*anyopaque, catalog: iap.Catalog) void {
        const self: *Screen = @ptrCast(@alignCast(ctx.?));
        switch (catalog) {
            // Copied, because the row dies with the callback — the
            // borrowed-slices rule this test exists partly to prove.
            .products => |rows| if (rows.len != 0) {
                self.price_len = @min(rows[0].price.len, self.price.len);
                @memcpy(self.price[0..self.price_len], rows[0].price[0..self.price_len]);
                if (self.app.tree.get(self.price_node)) |el|
                    el.text.content = self.price[0..self.price_len];
            },
            .failure => {},
        }
        self.app.invalidate();
    }

    fn onUpdate(ctx: ?*anyopaque, update: iap.Update) void {
        const self: *Screen = @ptrCast(@alignCast(ctx.?));
        Wallet.onUpdate(&self.wallet, update);
        // The goods are delivered the moment the app hears about them;
        // a real app would wait for its backend first.
        if (update == .purchase) iap.finish(self.app, update.purchase.id, .consumed);
        self.app.invalidate();
    }

    fn buy(ctx: ?*anyopaque) void {
        const self: *Screen = @ptrCast(@alignCast(ctx.?));
        // A real app shows the error; a test asserts the journal.
        iap.purchase(.{ .app = self.app, .product = "coins.100" }) catch {};
    }
};

test "harness: a paywall prices itself, buys, and finishes the transaction" {
    var screen: Screen = .{};
    var t = try Harness.initWith(std.testing.allocator, .{ .w = 320, .h = 480 }, .{
        .ctx = &screen,
        .build = Screen.build,
        .iap = .{ .auto = .purchased },
    });
    defer t.deinit();
    // After init, never inside `build`: the Harness is returned by
    // value, so an address taken during construction is not this one.
    screen.app = &t.app;

    _ = try iap.products(.{
        .app = &t.app,
        .ids = &.{"coins.100"},
        .ctx = &screen,
        .on_result = Screen.onCatalog,
    });
    try t.deliverProducts(&shelf);
    // The price the store formatted is the price on screen — a screen
    // reader sees the same bytes, which is what the assertion reads.
    _ = try t.getByLabel("$4.99");

    try t.tapLabel("Buy coins");
    try t.settleWorkers();
    try std.testing.expectEqual(iap.State.purchased, screen.wallet.last_state.?);
    try t.expectFinished("nokre-test-txn-1", .consumed);
    try std.testing.expectEqualStrings("coins.100", t.purchases()[0].product);
    try std.testing.expectEqual(@as(usize, 1), t.productQueries().len);
}

test "harness: a cancelled purchase leaves the screen alive" {
    var screen: Screen = .{};
    var t = try Harness.initWith(std.testing.allocator, .{ .w = 320, .h = 480 }, .{
        .ctx = &screen,
        .build = Screen.build,
    });
    defer t.deinit();
    screen.app = &t.app;

    try t.tapLabel("Buy coins");
    try t.cancelPurchase();
    try std.testing.expectEqual(@as(u32, 1), screen.wallet.cancels);
    // The button is still there and still actionable: a cancelled
    // purchase must not strand the user on a dead screen.
    try t.tapLabel("Buy coins");
}
