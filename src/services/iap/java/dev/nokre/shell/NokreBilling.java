// Android half of the iap service (docs/services.md; design in
// docs/internals/iap.md): the Play Billing Library, behind the same four
// verbs and one stream every platform answers.
//
// THIS FILE IS NOT PART OF THE SHELL'S SOURCE SET, and that placement is
// the point. NokreOAuth.java refuses a Maven coordinate on the grounds
// that nokre has no dependency manager, so every third-party artifact
// becomes the consumer's problem to add — and Custom Tabs let it keep
// that promise, because the protocol is a set of extras on a plain
// intent. Play Billing has no such escape: the old IInAppBillingService
// AIDL interface is gone and Google requires the library. So this file
// lives with its service rather than with the shell, and a consumer that
// links `.iap` adds two lines to their own app/build.gradle:
//
//     android { sourceSets { main { java.srcDirs += '<nokre>/src/services/iap/java' } } }
//     dependencies { implementation 'com.android.billingclient:billing:7.1.1' }
//
// An app that links no iap adds neither, and the kitchen sink's
// zero-services contract survives unchanged.
//
// Two mappings this platform forces, both stated where a reader meets
// them rather than buried:
//
//   * The transaction id IS the purchase token. `getOrderId()` is absent
//     for pending and test purchases, and Google's own Developer API is
//     keyed by token — so the token is what the backend verifies with,
//     what it deduplicates on, and what `finish` needs. One value, named
//     honestly, instead of a nullable one that would break exactly when
//     a purchase is most interesting.
//   * A catalog query is per product type, so every query runs twice —
//     once for one-time products, once for subscriptions — and reports
//     one merged answer. Play will not say which type an id is, so
//     asking both is the only way to answer the question the app asked.
package dev.nokre.shell;

import android.app.Activity;
import android.content.Context;

import com.android.billingclient.api.AcknowledgePurchaseParams;
import com.android.billingclient.api.BillingClient;
import com.android.billingclient.api.BillingClientStateListener;
import com.android.billingclient.api.BillingFlowParams;
import com.android.billingclient.api.BillingResult;
import com.android.billingclient.api.ConsumeParams;
import com.android.billingclient.api.PendingPurchasesParams;
import com.android.billingclient.api.ProductDetails;
import com.android.billingclient.api.Purchase;
import com.android.billingclient.api.QueryProductDetailsParams;
import com.android.billingclient.api.QueryPurchasesParams;

import java.util.ArrayList;
import java.util.Collections;
import java.util.HashMap;
import java.util.List;
import java.util.Map;

public final class NokreBilling {
    private NokreBilling() {}

    // Mirrors NOKRE_IAP_* in src/services/iap/iap.h.
    private static final int PURCHASED = 0;
    private static final int PENDING = 1;
    private static final int RESTORED = 2;
    private static final int CANCELLED = 3;
    private static final int FAILURE = 4;

    private static final int KIND_UNKNOWN = 0;
    private static final int KIND_SUBSCRIPTION = 3;

    private static final int ERR_NO_PRODUCT = 1;
    private static final int ERR_NO_SHEET = 2;

    /** Single-app anchor, like the shell's own statics: an Android
     *  process hosts one nokre app. */
    private static BillingClient client;
    private static boolean connected;
    /** The rows the last query returned. Unavoidable: launchBillingFlow
     *  takes a ProductDetails object, never an id (iap.h). */
    private static final Map<String, ProductDetails> priced = new HashMap<>();
    /** True while a restore is running, so its results report as
     *  RESTORED rather than as fresh purchases. */
    private static boolean restoring;

    // ---- C -> Java (src/services/iap/android.c) ----

    /** Whether this device can transact at all. The Play Store's absence
     *  is the honest false — a sideloaded or Play-less device — and the
     *  answer is read once, at App.init. */
    static boolean available() {
        Activity a = NokreActivity.current();
        if (a == null) return false;
        try {
            a.getPackageManager().getPackageInfo("com.android.vending", 0);
        } catch (Exception e) {
            return false;
        }
        return true;
    }

    /** Start the connection and begin observing. Called once, from the
     *  app's first setHandler — and like StoreKit's observer, connecting
     *  is what makes Play replay purchases this app never finished,
     *  including ones from a previous launch. */
    static void install() {
        if (client != null) return;
        Context ctx = NokreActivity.current();
        if (ctx == null) return;
        client = BillingClient.newBuilder(ctx)
                .setListener(NokreBilling::onPurchasesUpdated)
                // Pending transactions are a first-class state in this
                // service (docs/services.md), so they are enabled rather
                // than refused: Play's cash-at-a-kiosk flow is exactly
                // the customer least able to work around a refusal.
                .enablePendingPurchases(
                        PendingPurchasesParams.newBuilder().enableOneTimeProducts().build())
                .build();
        connect();
    }

    private static void connect() {
        if (client == null || connected) return;
        client.startConnection(new BillingClientStateListener() {
            @Override
            public void onBillingSetupFinished(BillingResult result) {
                connected = result.getResponseCode() == BillingClient.BillingResponseCode.OK;
                // The launch flush: everything this account owns and this
                // app never finished, replayed as ordinary updates.
                if (connected) replayUnfinished();
            }

            @Override
            public void onBillingServiceDisconnected() {
                // Deliberately silent, and deliberately not retried on a
                // timer: nokre has no ticker, and an app cannot act on
                // "the store blinked". The next verb reconnects.
                connected = false;
            }
        });
    }

    /** Every id, asked twice — once per product type, because Play will
     *  not say which an id is — and answered once, merged. */
    static void queryProducts(String[] ids) {
        if (client == null || ids == null) {
            nativeProductsDone("StoreUnavailable");
            return;
        }
        if (!connected) {
            connect();
            nativeProductsDone("StoreUnavailable");
            return;
        }
        // One shared latch for the two type queries; Play answers on the
        // main thread, so a plain int needs no synchronization.
        final int[] outstanding = {2};
        final String[] failure = {null};
        for (String type : new String[] {
                BillingClient.ProductType.INAPP, BillingClient.ProductType.SUBS }) {
            List<QueryProductDetailsParams.Product> want = new ArrayList<>(ids.length);
            for (String id : ids) {
                want.add(QueryProductDetailsParams.Product.newBuilder()
                        .setProductId(id)
                        .setProductType(type)
                        .build());
            }
            client.queryProductDetailsAsync(
                    QueryProductDetailsParams.newBuilder().setProductList(want).build(),
                    (result, details) -> {
                        if (result.getResponseCode() == BillingClient.BillingResponseCode.OK) {
                            emitRows(details);
                        } else if (failure[0] == null) {
                            failure[0] = responseName(result);
                        }
                        if (--outstanding[0] == 0) {
                            // A type that simply has none of these ids
                            // answers OK with an empty list, so a failure
                            // here is a real one — but only if *neither*
                            // type answered, which is what the null check
                            // on rows below means: an id found as INAPP
                            // must not be lost to a SUBS error.
                            nativeProductsDone(failure[0] != null && priced.isEmpty()
                                    ? failure[0]
                                    : "");
                        }
                    });
        }
    }

    private static void emitRows(List<ProductDetails> details) {
        if (details == null) return;
        for (ProductDetails d : details) {
            priced.put(d.getProductId(), d);
            String price = "";
            String currency = "";
            long micros = 0;
            String offer = "";
            int kind = KIND_UNKNOWN;

            ProductDetails.OneTimePurchaseOfferDetails once = d.getOneTimePurchaseOfferDetails();
            if (once != null) {
                price = once.getFormattedPrice();
                currency = once.getPriceCurrencyCode();
                micros = once.getPriceAmountMicros();
            } else {
                List<ProductDetails.SubscriptionOfferDetails> offers =
                        d.getSubscriptionOfferDetails();
                if (offers != null && !offers.isEmpty()) {
                    kind = KIND_SUBSCRIPTION;
                    // The first offer's first phase: what the store shows
                    // on a paywall, and what the app draws. A free trial
                    // or intro price is a later phase and is deliberately
                    // not modelled — nokre has no clock to reason about
                    // when a phase ends (docs/internals/iap.md).
                    ProductDetails.SubscriptionOfferDetails first = offers.get(0);
                    offer = first.getOfferToken();
                    List<ProductDetails.PricingPhase> phases =
                            first.getPricingPhases().getPricingPhaseList();
                    if (!phases.isEmpty()) {
                        price = phases.get(0).getFormattedPrice();
                        currency = phases.get(0).getPriceCurrencyCode();
                        micros = phases.get(0).getPriceAmountMicros();
                    }
                }
            }
            nativeProductRow(d.getProductId(), d.getTitle(), d.getDescription(), price, currency,
                    offer, micros, kind);
        }
    }

    static int purchase(String product, String offer) {
        ProductDetails d = priced.get(product);
        if (d == null) return ERR_NO_PRODUCT;
        Activity a = NokreActivity.current();
        if (a == null || client == null || !connected) return ERR_NO_SHEET;

        BillingFlowParams.ProductDetailsParams.Builder p =
                BillingFlowParams.ProductDetailsParams.newBuilder().setProductDetails(d);
        // The offer token is required for a subscription and rejected for
        // anything else, so it is passed exactly when the app supplied
        // one — which is exactly when the row carried one.
        if (offer != null && !offer.isEmpty()) p.setOfferToken(offer);
        BillingResult result = client.launchBillingFlow(a,
                BillingFlowParams.newBuilder()
                        .setProductDetailsParamsList(Collections.singletonList(p.build()))
                        .build());
        return result.getResponseCode() == BillingClient.BillingResponseCode.OK ? 0 : ERR_NO_SHEET;
    }

    /** `token` is the purchase token — which is also the transaction id
     *  this leg reports, for the reason at the top of this file. */
    static void finish(String token, boolean consume) {
        if (client == null || token == null || token.isEmpty()) return;
        if (consume) {
            client.consumeAsync(
                    ConsumeParams.newBuilder().setPurchaseToken(token).build(),
                    (result, t) -> {});
        } else {
            client.acknowledgePurchase(
                    AcknowledgePurchaseParams.newBuilder().setPurchaseToken(token).build(),
                    result -> {});
        }
    }

    static void restore() {
        restoring = true;
        replayUnfinished();
    }

    /** What this account owns right now, both types — the restore path
     *  and the launch flush, which are the same query on this platform.
     *  No dates and no expiry arithmetic: what Play says is owned is the
     *  whole answer (docs/internals/iap.md). */
    private static void replayUnfinished() {
        if (client == null) return;
        for (String type : new String[] {
                BillingClient.ProductType.INAPP, BillingClient.ProductType.SUBS }) {
            client.queryPurchasesAsync(
                    QueryPurchasesParams.newBuilder().setProductType(type).build(),
                    (result, purchases) -> {
                        if (purchases == null) return;
                        for (Purchase p : purchases) report(p, RESTORED);
                    });
        }
        restoring = false;
    }

    // ---- Java -> C ----

    private static void onPurchasesUpdated(BillingResult result, List<Purchase> purchases) {
        int code = result.getResponseCode();
        if (code == BillingClient.BillingResponseCode.USER_CANCELED) {
            nativeUpdate(CANCELLED, "", "", "", "");
            return;
        }
        if (code != BillingClient.BillingResponseCode.OK || purchases == null) {
            nativeUpdate(FAILURE, "", "", "", responseName(result));
            return;
        }
        for (Purchase p : purchases) report(p, PURCHASED);
    }

    private static void report(Purchase p, int fresh) {
        int status = fresh;
        if (p.getPurchaseState() == Purchase.PurchaseState.PENDING) {
            // Pending outranks restored: the money has not moved, and
            // that is what the app must act on.
            status = PENDING;
        } else if (restoring || fresh == RESTORED) {
            status = RESTORED;
        }
        String token = p.getPurchaseToken();
        List<String> products = p.getProducts();
        String product = products.isEmpty() ? "" : products.get(0);
        nativeUpdate(status, token, product, token, "");
    }

    /** A stable name rather than a number: http's `.failure` posture,
     *  and a number in a log tells nobody anything. */
    private static String responseName(BillingResult result) {
        switch (result.getResponseCode()) {
            case BillingClient.BillingResponseCode.SERVICE_DISCONNECTED:
                return "ServiceDisconnected";
            case BillingClient.BillingResponseCode.SERVICE_UNAVAILABLE:
                return "ServiceUnavailable";
            case BillingClient.BillingResponseCode.BILLING_UNAVAILABLE:
                return "BillingUnavailable";
            case BillingClient.BillingResponseCode.ITEM_UNAVAILABLE:
                return "ItemUnavailable";
            case BillingClient.BillingResponseCode.ITEM_ALREADY_OWNED:
                return "AlreadyOwned";
            case BillingClient.BillingResponseCode.ITEM_NOT_OWNED:
                return "NotOwned";
            case BillingClient.BillingResponseCode.DEVELOPER_ERROR:
                return "DeveloperError";
            case BillingClient.BillingResponseCode.NETWORK_ERROR:
                return "NetworkError";
            default:
                return "PurchaseFailed";
        }
    }

    // Resolved by name from the app's own .so — the shell registers
    // nothing for billing, and never learns what a purchase is.
    private static native void nativeProductRow(String id, String title, String description,
            String price, String currency, String offer, long priceMicros, int kind);

    private static native void nativeProductsDone(String err);

    private static native void nativeUpdate(int status, String txn, String product, String token,
            String err);
}
