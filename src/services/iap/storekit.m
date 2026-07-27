// Apple half of the iap service (docs/services.md; design in
// docs/internals/iap.md): StoreKit 1, shared by macOS and iOS.
//
// StoreKit 2 is Swift-only and zig cannot compile Swift, so taking it
// would mean two Apple implementations — one for the macOS build zig
// drives and one for the iOS build Xcode drives. StoreKit 1 is
// deprecated as of iOS 18 and still transacts; the exit, if Apple ever
// withdraws it, is written down in the internals doc rather than
// improvised here.
//
// Three things the platform decides and this file only reports:
//
//   * Consumable versus non-consumable is not in the API. `SKProduct`
//     carries no product type — only `subscriptionPeriod`, which is
//     non-nil for a subscription — so everything else reports
//     NOKRE_IAP_KIND_UNKNOWN. That is exactly what the honest kind exists
//     for, and why `finish` takes the disposition from the app.
//   * The verification token is the *app receipt*, not a per-transaction
//     one: StoreKit 1 has no JWS. One receipt covers every purchase, and
//     the app's backend sends it to Apple's verifyReceipt. It can be
//     briefly absent in a fresh sandbox install, which arrives as an
//     empty token rather than as a fabricated one.
//   * `finishTransaction` ignores the disposition. Apple already knows
//     the product type; Play does not, which is the whole reason the
//     argument exists (iap.h).
#import <Foundation/Foundation.h>
#import <StoreKit/StoreKit.h>

#include "iap.h"

// One observer per process — an Apple process hosts one nokre app, the
// same single-app anchor the shell's own statics take. The per-app state
// still lives in Zig: `ctx` is what came in from `nokre_iap_install`, and
// nothing here is consulted to decide anything.
static void *g_ctx;
static nokre_iap_update_cb g_cb;
// The rows the last catalog query returned, keyed by product id.
// Unavoidable native state: SKPayment is built from an SKProduct object,
// never from a string (iap.h says so where a reader meets it first).
static NSMutableDictionary<NSString *, SKProduct *> *g_priced;

/// Everything Zig sees must arrive on the main thread — it opens a
/// delivery slot, which is UI-thread only. StoreKit usually calls back
/// there already; a `dispatch_async` from a background call keeps the
/// promise the header makes rather than hoping.
static void nokre_iap_on_main(dispatch_block_t block) {
    if ([NSThread isMainThread]) {
        block();
    } else {
        dispatch_async(dispatch_get_main_queue(), block);
    }
}

/// The app receipt, base64 as Apple's own verifyReceipt wants it. Empty
/// when the file is not on disk yet — a real state in a fresh sandbox
/// install, and one the app's backend will see as "no receipt" rather
/// than as garbage.
static NSString *nokre_iap_receipt(void) {
    NSURL *url = [[NSBundle mainBundle] appStoreReceiptURL];
    if (url == nil) return @"";
    NSData *data = [NSData dataWithContentsOfURL:url];
    if (data == nil) return @"";
    return [data base64EncodedStringWithOptions:0];
}

static void nokre_iap_emit(int status, NSString *txn, NSString *product, NSString *token,
                         NSString *err) {
    nokre_iap_update_cb cb = g_cb;
    if (cb == NULL) return;
    const char *txn_s = txn ? txn.UTF8String : "";
    const char *product_s = product ? product.UTF8String : "";
    const char *token_s = token ? token.UTF8String : "";
    const char *err_s = err ? err.UTF8String : "";
    cb(g_ctx, status, txn_s, strlen(txn_s), product_s, strlen(product_s), token_s, strlen(token_s),
       err_s, strlen(err_s));
}

@interface NokreIapObserver : NSObject <SKPaymentTransactionObserver>
@end

@implementation NokreIapObserver

- (void)paymentQueue:(SKPaymentQueue *)queue updatedTransactions:(NSArray<SKPaymentTransaction *> *)transactions {
    for (SKPaymentTransaction *t in transactions) {
        // `purchasing` is the sheet being up, which the app already
        // knows: it asked. Reporting it would be an update carrying no
        // decision.
        if (t.transactionState == SKPaymentTransactionStatePurchasing) continue;

        int status = NOKRE_IAP_FAILURE;
        NSString *err = nil;
        switch (t.transactionState) {
            case SKPaymentTransactionStatePurchased:
                status = NOKRE_IAP_PURCHASED;
                break;
            case SKPaymentTransactionStateRestored:
                status = NOKRE_IAP_RESTORED;
                break;
            // Ask to Buy: the child committed, the parent has not
            // approved, and the approval arrives here days later — in a
            // different launch, with nothing asked for.
            case SKPaymentTransactionStateDeferred:
                status = NOKRE_IAP_PENDING;
                break;
            case SKPaymentTransactionStateFailed:
            default:
                // A cancel is not a failure, and Apple reports it as
                // one — the one place this file translates rather than
                // forwards.
                if (t.error != nil && t.error.code == SKErrorPaymentCancelled) {
                    status = NOKRE_IAP_CANCELLED;
                } else {
                    err = t.error != nil ? t.error.localizedDescription : @"PurchaseFailed";
                }
                break;
        }

        // A failed or cancelled transaction has no goods to deliver, so
        // nothing will ever call `finish` for it — StoreKit still
        // requires it off the queue, and leaving it on would replay the
        // same failure at every launch.
        if (status == NOKRE_IAP_CANCELLED || status == NOKRE_IAP_FAILURE)
            [queue finishTransaction:t];

        // Restored transactions carry the original id in
        // `originalTransaction`; the app's backend deduplicates on the
        // id it was first told, so that is the one to report.
        SKPaymentTransaction *identity =
            (t.transactionState == SKPaymentTransactionStateRestored && t.originalTransaction != nil)
                ? t.originalTransaction
                : t;
        NSString *txn = identity.transactionIdentifier ?: @"";
        NSString *product = t.payment.productIdentifier ?: @"";
        NSString *token = (status == NOKRE_IAP_PURCHASED || status == NOKRE_IAP_RESTORED)
                              ? nokre_iap_receipt()
                              : @"";
        int captured = status;
        nokre_iap_on_main(^{
          nokre_iap_emit(captured, txn, product, token, err);
        });
    }
}

- (void)paymentQueue:(SKPaymentQueue *)queue restoreCompletedTransactionsFailedWithError:(NSError *)error {
    NSString *err = error != nil ? error.localizedDescription : @"RestoreFailed";
    nokre_iap_on_main(^{
      nokre_iap_emit(NOKRE_IAP_FAILURE, @"", @"", @"", err);
    });
}

@end

/// One query, one delegate object, retained by itself until StoreKit
/// answers — SKProductsRequest holds its delegate weakly, so a stack or
/// autoreleased object would be gone by the time the network is.
@interface NokreIapQuery : NSObject <SKProductsRequestDelegate>
@property(nonatomic, assign) void *ctx;
@property(nonatomic, assign) nokre_iap_products_cb cb;
@property(nonatomic, strong) NokreIapQuery *self_ref;
@end

@implementation NokreIapQuery

- (void)productsRequest:(SKProductsRequest *)request didReceiveResponse:(SKProductsResponse *)response {
    NSArray<SKProduct *> *found = response.products;
    NSMutableArray<NSString *> *held = [NSMutableArray array];
    nokre_iap_product *rows = calloc(found.count > 0 ? found.count : 1, sizeof(nokre_iap_product));
    if (rows == NULL) {
        [self answer:NULL count:0 err:@"OutOfMemory"];
        return;
    }

    NSNumberFormatter *fmt = [[NSNumberFormatter alloc] init];
    fmt.numberStyle = NSNumberFormatterCurrencyStyle;

    NSUInteger n = 0;
    for (SKProduct *p in found) {
        g_priced[p.productIdentifier] = p;

        // The price is the *store's* formatting, in the product's own
        // locale — not the device's, and not nokre's: a US product
        // shown in Tehran is still priced in dollars, and only Apple
        // knows which. nokre never computes or reformats money.
        fmt.locale = p.priceLocale;
        NSString *price = [fmt stringFromNumber:p.price] ?: @"";
        NSString *currency = [p.priceLocale objectForKey:NSLocaleCurrencyCode] ?: @"";
        // Micros as an integer, never a float: NSDecimalNumber scales
        // exactly, and 4.99 becomes 4990000 with no rounding to argue
        // about.
        NSDecimalNumber *micros = [p.price decimalNumberByMultiplyingByPowerOf10:6];

        // StoreKit 1 reports no product type. A subscription is
        // recognizable by its period; consumable versus non-consumable
        // is not in the API at all, which is what `unknown` is for.
        int kind = NOKRE_IAP_KIND_UNKNOWN;
        if (@available(iOS 11.2, macOS 10.13.2, *)) {
            if (p.subscriptionPeriod != nil) kind = NOKRE_IAP_KIND_SUBSCRIPTION;
        }

        // Held so every UTF8String outlives the callback: the strings
        // are autoreleased views into these objects.
        [held addObject:p.productIdentifier];
        [held addObject:p.localizedTitle ?: @""];
        [held addObject:p.localizedDescription ?: @""];
        [held addObject:price];
        [held addObject:currency];

        rows[n].id = p.productIdentifier.UTF8String;
        rows[n].id_len = strlen(rows[n].id);
        rows[n].title = (p.localizedTitle ?: @"").UTF8String;
        rows[n].title_len = strlen(rows[n].title);
        rows[n].description = (p.localizedDescription ?: @"").UTF8String;
        rows[n].description_len = strlen(rows[n].description);
        rows[n].price = price.UTF8String;
        rows[n].price_len = strlen(rows[n].price);
        rows[n].currency = currency.UTF8String;
        rows[n].currency_len = strlen(rows[n].currency);
        // Apple has no offer token; Play does, and one shape beats an
        // arm five platforms never carry.
        rows[n].offer = "";
        rows[n].offer_len = 0;
        rows[n].price_micros = micros.unsignedLongLongValue;
        rows[n].kind = kind;
        n++;
    }

    // `invalidProductIdentifiers` is deliberately not an error: an id
    // the store does not sell is absence, and absence is data (the
    // secure_store miss rule).
    [self answer:rows count:n err:nil];
    free(rows);
    [held removeAllObjects];
}

- (void)request:(SKRequest *)request didFailWithError:(NSError *)error {
    NSString *err = error != nil ? error.localizedDescription : @"CatalogFailed";
    [self answer:NULL count:0 err:err];
}

- (void)answer:(nokre_iap_product *)rows count:(NSUInteger)count err:(NSString *)err {
    nokre_iap_products_cb cb = self.cb;
    void *ctx = self.ctx;
    const char *err_s = err ? err.UTF8String : "";
    size_t err_len = err ? strlen(err_s) : 0;
    if (cb != NULL) {
        if ([NSThread isMainThread]) {
            cb(ctx, rows, count, err_s, err_len);
        } else {
            // Copy, because the rows die when this returns and the block
            // runs later. Only the failure path realistically lands off
            // the main thread, so the copy is a correctness backstop
            // rather than the normal cost.
            NSString *held = err ?: @"";
            dispatch_sync(dispatch_get_main_queue(), ^{
              const char *e = held.UTF8String;
              cb(ctx, rows, count, e, err ? strlen(e) : 0);
            });
        }
    }
    // Answered exactly once: drop the self-reference and the object goes.
    self.cb = NULL;
    self.self_ref = nil;
}

@end

static NokreIapObserver *g_observer;

int nokre_iap_available(void) { return [SKPaymentQueue canMakePayments] ? 1 : 0; }

void nokre_iap_uninstall(void) {
    // The observer stays on the queue (one per process); with the
    // callback gone, nokre_iap_emit drops every update on the floor
    // instead of calling into an app that no longer exists.
    g_ctx = NULL;
    g_cb = NULL;
}

void nokre_iap_install(void *ctx, nokre_iap_update_cb cb) {
    g_ctx = ctx;
    g_cb = cb;
    if (g_priced == nil) g_priced = [NSMutableDictionary dictionary];
    if (g_observer != nil) return;
    g_observer = [[NokreIapObserver alloc] init];
    // Adding the observer is what makes StoreKit replay every unfinished
    // transaction — including ones from a previous launch — so this line
    // is the launch flush the service contract promises.
    [[SKPaymentQueue defaultQueue] addTransactionObserver:g_observer];
}

void nokre_iap_products(void *ctx, nokre_iap_products_cb cb, const char *const *ids,
                      const size_t *id_lens, size_t count) {
    if (g_priced == nil) g_priced = [NSMutableDictionary dictionary];
    NSMutableSet<NSString *> *set = [NSMutableSet setWithCapacity:count];
    for (size_t i = 0; i < count; i++) {
        NSString *s = [[NSString alloc] initWithBytes:ids[i]
                                               length:id_lens[i]
                                             encoding:NSUTF8StringEncoding];
        if (s != nil) [set addObject:s];
    }
    NokreIapQuery *q = [[NokreIapQuery alloc] init];
    q.ctx = ctx;
    q.cb = cb;
    q.self_ref = q;
    SKProductsRequest *req = [[SKProductsRequest alloc] initWithProductIdentifiers:set];
    req.delegate = q;
    [req start];
}

int nokre_iap_purchase(const char *product, size_t product_len, const char *offer,
                     size_t offer_len) {
    (void)offer;
    (void)offer_len; // Play's; Apple has no offer token
    NSString *id_ = [[NSString alloc] initWithBytes:product
                                             length:product_len
                                           encoding:NSUTF8StringEncoding];
    if (id_ == nil) return NOKRE_IAP_ERR_NO_PRODUCT;
    SKProduct *p = g_priced[id_];
    if (p == nil) return NOKRE_IAP_ERR_NO_PRODUCT;
    if (![SKPaymentQueue canMakePayments]) return NOKRE_IAP_ERR_NO_SHEET;
    [[SKPaymentQueue defaultQueue] addPayment:[SKPayment paymentWithProduct:p]];
    return 0;
}

void nokre_iap_finish(const char *txn, size_t txn_len, int consume) {
    // Apple decides consumable versus not from the product type it
    // already knows, so both dispositions finish the same way. The
    // argument is Play's (iap.h), and pretending otherwise here would be
    // a second source of truth for a fact Apple owns.
    (void)consume;
    NSString *want = [[NSString alloc] initWithBytes:txn
                                              length:txn_len
                                            encoding:NSUTF8StringEncoding];
    if (want == nil) return;
    SKPaymentQueue *queue = [SKPaymentQueue defaultQueue];
    for (SKPaymentTransaction *t in queue.transactions) {
        NSString *identity = (t.originalTransaction != nil && t.transactionState == SKPaymentTransactionStateRestored)
                                 ? t.originalTransaction.transactionIdentifier
                                 : t.transactionIdentifier;
        if (identity != nil && [identity isEqualToString:want]) {
            [queue finishTransaction:t];
            return;
        }
    }
    // Not on the queue: already finished, or from a launch that ended.
    // Idempotent by contract, so silence is the right answer.
}

void nokre_iap_restore(void) { [[SKPaymentQueue defaultQueue] restoreCompletedTransactions]; }
