//! The extern surface for iap.h, referenced only from the legs that
//! have one (`apple`, `android`) — a target with no store never names a
//! symbol its build never compiled, which is `oauth/native.zig`'s
//! posture applied per leg rather than per platform.

/// Mirrors `nokre_iap_product` in iap.h, field for field. Kept extern
/// rather than translated at the boundary because a catalog can carry
/// twenty rows and each row is eight strings: copying them twice to
/// change nothing would be ceremony.
pub const Product = extern struct {
    id: [*]const u8,
    id_len: usize,
    title: [*]const u8,
    title_len: usize,
    description: [*]const u8,
    description_len: usize,
    price: [*]const u8,
    price_len: usize,
    currency: [*]const u8,
    currency_len: usize,
    offer: [*]const u8,
    offer_len: usize,
    price_micros: c_ulonglong,
    kind: c_int,
};

pub const ProductsCallback = *const fn (
    ctx: ?*anyopaque,
    items: ?[*]const Product,
    count: usize,
    err: [*]const u8,
    err_len: usize,
) callconv(.c) void;

pub const UpdateCallback = *const fn (
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
) callconv(.c) void;

pub extern fn nokre_iap_available() c_int;
pub extern fn nokre_iap_install(ctx: ?*anyopaque, cb: UpdateCallback) void;
pub extern fn nokre_iap_uninstall() void;
pub extern fn nokre_iap_products(
    ctx: ?*anyopaque,
    cb: ProductsCallback,
    ids: [*]const [*]const u8,
    id_lens: [*]const usize,
    count: usize,
) void;
pub extern fn nokre_iap_purchase(
    product: [*]const u8,
    product_len: usize,
    offer: [*]const u8,
    offer_len: usize,
) c_int;
pub extern fn nokre_iap_finish(txn: [*]const u8, txn_len: usize, consume: c_int) void;
pub extern fn nokre_iap_restore() void;
