// C contract between the iap native side and Zig (docs/services.md;
// design in docs/internals/iap.md). Two shapes at once, which is what
// makes this service the roster's largest: an outbound query that
// answers once (`nokre_iap_products`, http's shape) and a permanently
// installed inbound stream (`nokre_iap_install`, deep_link's shape) that
// the store pushes to — an interrupted purchase redelivered at launch,
// an Ask-to-Buy approval days later, a renewal, every restore result.
//
// The native side holds no table and no per-purchase state. It observes
// the store's own queue and forwards; everything about what a purchase
// means, when it is finished, and what the app is told lives in Zig.
//
// Only ONE payment sheet and ONE catalog query are live per app at a
// time (the Zig side enforces both — error.PurchaseInFlight,
// error.QueryInFlight). A payment sheet is modal and a person can only
// be buying one thing at once; a paywall asks for its whole catalog in
// one call because the id set is a parameter. That is what lets this
// contract carry a bare ctx instead of a request id.
#ifndef NOKRE_SVC_IAP_H
#define NOKRE_SVC_IAP_H

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

// Update status codes. Mirrored by `status_*` in iap.zig.
#define NOKRE_IAP_PURCHASED 0 // money moved (or the store says it will)
#define NOKRE_IAP_PENDING 1   // committed, unpaid: Play's cash flow, Apple's Ask to Buy
#define NOKRE_IAP_RESTORED 2  // a past purchase, replayed by restore or at launch
#define NOKRE_IAP_CANCELLED 3 // the user dismissed the payment sheet
#define NOKRE_IAP_FAILURE 4   // `err` is a stable failure name, may be empty

// Product kinds, as the store reports them. Mirrored by `Kind` in
// iap.zig. `NOKRE_IAP_KIND_UNKNOWN` is honest: a store that declines to
// say must not be guessed for, because the guess decides whether the
// app consumes or keeps the purchase.
#define NOKRE_IAP_KIND_UNKNOWN 0
#define NOKRE_IAP_KIND_CONSUMABLE 1
#define NOKRE_IAP_KIND_NON_CONSUMABLE 2
#define NOKRE_IAP_KIND_SUBSCRIPTION 3

// One row of the catalog. Every string is UTF-8, not NUL-terminated,
// and borrowed for the callback only — Zig copies before returning.
//
// `price` is the store's OWN formatted string ("$4.99", "4,99 €") and
// the only field an app draws: formatting money is a function of locale
// and currency and the store's regional rounding, all three of which the
// store already applied. `price_micros` + `currency` are for reporting a
// number to the app's backend without parsing the display string.
typedef struct {
    const char *id;
    size_t id_len;
    const char *title;
    size_t title_len;
    const char *description;
    size_t description_len;
    const char *price;
    size_t price_len;
    const char *currency; // ISO 4217, e.g. "USD"
    size_t currency_len;
    const char *offer; // Play's subscription offer token; empty elsewhere
    size_t offer_len;
    unsigned long long price_micros; // 4.99 USD -> 4990000
    int kind;                        // NOKRE_IAP_KIND_*
} nokre_iap_product;

// The catalog answer, exactly once per `nokre_iap_products` call, ALWAYS
// on the main thread. `count` is 0 with a non-empty `err` for a failed
// query, and 0 with an empty `err` when the store simply knows none of
// the ids — an empty catalog is data, not an error, the way a
// secure_store miss is data.
typedef void (*nokre_iap_products_cb)(void *ctx, const nokre_iap_product *items, size_t count,
                                    const char *err, size_t err_len);

// One purchase update. `status` is one of the NOKRE_IAP_* codes above.
// `txn` is the store's transaction id (the app's backend deduplicates on
// it), `token` the opaque bytes that backend verifies with — Apple's JWS
// or receipt, Play's purchase token. All borrowed for the call; ALWAYS
// on the main thread.
typedef void (*nokre_iap_update_cb)(void *ctx, int status, const char *txn, size_t txn_len,
                                  const char *product, size_t product_len, const char *token,
                                  size_t token_len, const char *err, size_t err_len);

// Can this device transact at all? Synchronous, cheap, and asked once
// during App.init — the answer is cached so `build` can branch on it
// without an OS call per frame (locale's boot-tag pattern). Returns 0
// under parental restriction on Apple and where the Play Store is absent
// on Android. Platforms with no store never compile a call to this.
int nokre_iap_available(void);

// Install the purchase stream. Called at most once per app, from the
// first `setHandler`. `ctx` is the app's per-service state, passed
// straight back; the native side stores it and the callback and forwards
// every update. Installing is what makes the store flush transactions it
// has been holding — including ones from a previous launch — so those
// arrive as ordinary updates immediately after this returns.
void nokre_iap_install(void *ctx, nokre_iap_update_cb cb);

// Forget the installed ctx + callback (and any pending catalog query's).
// Called from App.deinit: the store observer itself lives for the
// process, but the ctx it holds is per-app state the app is about to
// free, so a late update must find no callback rather than a dangling
// pointer. A later install re-arms the same observer.
void nokre_iap_uninstall(void);

// Ask the store what it sells. `ids` is `count` pointers with `id_lens`
// lengths, borrowed for the call. Exactly one callback follows, on the
// main thread, and `ctx` comes back with it untouched.
void nokre_iap_products(void *ctx, nokre_iap_products_cb cb, const char *const *ids,
                      const size_t *id_lens, size_t count);

// Why a purchase must be priced first, on both stores: neither takes a
// product id. Apple's `SKPayment` is built from an `SKProduct` object
// and Play's `launchBillingFlow` from a `ProductDetails` object, and
// both objects come only from a catalog query. So each leg keeps the
// rows its last `nokre_iap_products` returned — the one piece of native
// state this service has, made explicit here rather than hidden in a
// static — and an id that was never priced is NOKRE_IAP_ERR_NO_PRODUCT.
// That is not a limitation worth working around: an app that has not
// shown a price has no business charging for anything.
#define NOKRE_IAP_ERR_NO_PRODUCT 1 // never came back from a catalog query
#define NOKRE_IAP_ERR_NO_SHEET 2   // the store refused to present at all

// Put the payment sheet on screen. `offer` is Play's subscription offer
// token (empty on every other platform and for every other kind).
// Returns 0 on success, otherwise one of the two codes above, which Zig
// turns into one named failure on the stream — so an app has exactly one
// path to handle. Everything else — the user cancelling, the card
// declining — arrives on the stream.
int nokre_iap_purchase(const char *product, size_t product_len, const char *offer,
                     size_t offer_len);

// Tell the store the goods were delivered. Until this is called the
// store redelivers the transaction on every launch, which is the
// crash-safety mechanism, not a bug. `consume` is 1 when the purchase is
// spent (Play: consumeAsync) and 0 when it is kept (Play:
// acknowledgePurchase); Apple finishes both the same way, because it
// already knows the product type. Play auto-refunds a purchase that goes
// three days unacknowledged.
void nokre_iap_finish(const char *txn, size_t txn_len, int consume);

// Replay what this account already owns; each one arrives on the stream
// as NOKRE_IAP_RESTORED. Apple requires an app to offer a visible control
// for this, which is why it is a verb and not something the service does
// on its own.
void nokre_iap_restore(void);

#ifdef __cplusplus
}
#endif

#endif // NOKRE_SVC_IAP_H
