// Android activity half of the nokre shell: loads the native library,
// hosts one NokreView, and forwards what only an Activity can see —
// appearance, window focus, and window insets. The consumer's manifest
// declares this activity directly (the shell owns the app lifecycle,
// like the app delegate in ios/shell.m); the native library name comes
// from a `dev.nokre.lib` meta-data entry, defaulting to "nokre_app".
package dev.nokre.shell;

import android.app.Activity;
import android.content.ComponentName;
import android.content.Intent;
import android.content.pm.ActivityInfo;
import android.content.pm.PackageManager;
import android.content.res.Configuration;
import android.graphics.Insets;
import android.net.Uri;
import android.os.Build;
import android.os.Bundle;
import android.window.OnBackInvokedDispatcher;
import android.view.WindowInsets;
import android.widget.FrameLayout;

public final class NokreActivity extends Activity {
    private NokreView view;

    /** The one live activity. A single-app anchor, like NokreOAuth's own
     *  statics: an Android process hosts one nokre app. It exists for
     *  the services the shell cannot hand itself to — iap's NokreBilling
     *  lives outside this source set (it needs a Maven coordinate the
     *  consumer adds), so nothing here may name it, and it reaches back
     *  through this instead. */
    private static Activity live;

    public static Activity current() {
        return live;
    }

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        live = this;
        System.loadLibrary(nativeLibName());

        // secure_store's Keystore backend needs a context, and a boot
        // read happens inside the view's construction below (nativeBoot →
        // the app's build), so hand it the process-global application
        // context first. Harmless when the app links no secure_store —
        // the store is touched only if the C verbs are called.
        NokreSecureStore.attach(getApplicationContext());

        view = new NokreView(this);
        // oauth launches its Custom Tab from this activity and reports
        // results back through the view (docs/services.md). Harmless
        // when the app links no oauth — nothing calls NokreOAuth then.
        NokreOAuth.attach(this, view);
        FrameLayout root = new FrameLayout(this);
        root.addView(view);
        setContentView(root);

        if (Build.VERSION.SDK_INT >= 30) {
            // Edge-to-edge: the view runs under the gesture-nav bar and
            // reports its height as safe_bottom — core keeps layout
            // above the band while pane fills paint through it, the iOS
            // home-indicator treatment. Top and sides stay out of the
            // status bar via margins. The IME inset shrinks the view
            // instead (adjustResize's job pre-30, see the manifest).
            getWindow().setDecorFitsSystemWindows(false);
            root.setOnApplyWindowInsetsListener((v, insets) -> {
                Insets bars = insets.getInsets(WindowInsets.Type.systemBars());
                Insets ime = insets.getInsets(WindowInsets.Type.ime());
                FrameLayout.LayoutParams lp = (FrameLayout.LayoutParams) view.getLayoutParams();
                lp.topMargin = bars.top;
                lp.leftMargin = bars.left;
                lp.rightMargin = bars.right;
                lp.bottomMargin = Math.max(ime.bottom - bars.bottom, 0);
                view.setLayoutParams(lp);
                view.setSafeBottomPx(ime.bottom > 0 ? 0 : bars.bottom);
                return WindowInsets.CONSUMED;
            });
        }

        reportAppearance();

        // deep_link: the URL that launched the app, if any. Delivered
        // before the surface boots, so the native side buffers it until
        // the app registers its handler (docs/services.md). onNewIntent
        // handles links that arrive while the app is already running —
        // the manifest's singleTask launchMode (added when deep_link is
        // claimed) routes them to this one instance rather than a new one.
        deliverLink(getIntent());

        // The system back, which on Android is the *whole* back gesture:
        // gesture navigation owns both screen edges, so the app never
        // sees the drag the iOS shell reports — the OS runs its own
        // threshold and hands over a decision. Both routes are wired
        // because which one is live is the consumer manifest's choice
        // (android:enableOnBackInvokedCallback) and, from API 36,
        // the platform's default for apps that target it: with the
        // dispatcher live onBackPressed is never called, and without it
        // the registered callback is ignored. Never both.
        if (Build.VERSION.SDK_INT >= 33) {
            getOnBackInvokedDispatcher().registerOnBackInvokedCallback(
                    OnBackInvokedDispatcher.PRIORITY_DEFAULT,
                    () -> {
                        if (!view.handleBack()) finish();
                    });
        }
    }

    /** Pre-33, and post-33 without the manifest opt-in. Deprecated by
     *  the dispatcher above, and kept for exactly as long as a nokre
     *  app may run without it. */
    @Override
    @SuppressWarnings("deprecation")
    public void onBackPressed() {
        if (view != null && view.handleBack()) return;
        super.onBackPressed();
    }

    @Override
    protected void onNewIntent(Intent intent) {
        super.onNewIntent(intent);
        setIntent(intent);
        deliverLink(intent);
    }

    @Override
    protected void onResume() {
        super.onResume();
        // A live oauth flow plus a resume means the user backed out of
        // the Custom Tab: nothing else reports that, because the tab is
        // another process (NokreOAuth). A redirect arrives as onNewIntent,
        // which the system delivers before this, so a completed flow has
        // already cleared itself.
        NokreOAuth.resumed();
    }

    private void deliverLink(Intent intent) {
        if (view == null || intent == null) return;
        if (!Intent.ACTION_VIEW.equals(intent.getAction())) return;
        Uri data = intent.getData();
        if (data == null) return;
        // An oauth redirect first: it arrives as a VIEW intent on the
        // app's custom scheme, and it belongs to the flow that asked for
        // it, not to the app's router. A URL no live flow claims falls
        // through to deep_link, which is what an App Link is.
        if (NokreOAuth.redirect(data.toString())) return;
        view.deepLink(data.toString());
    }

    private String nativeLibName() {
        try {
            ComponentName component = getComponentName();
            ActivityInfo info = getPackageManager()
                    .getActivityInfo(component, PackageManager.GET_META_DATA);
            if (info.metaData != null) {
                String lib = info.metaData.getString("dev.nokre.lib");
                if (lib != null) return lib;
            }
        } catch (PackageManager.NameNotFoundException ignored) {
        }
        return "nokre_app";
    }

    private void reportAppearance() {
        int night = getResources().getConfiguration().uiMode
                & Configuration.UI_MODE_NIGHT_MASK;
        view.reportAppearance(night == Configuration.UI_MODE_NIGHT_YES);
    }

    @Override
    public void onConfigurationChanged(Configuration newConfig) {
        // The manifest keeps uiMode (and size changes) out of the
        // recreate path — the app lives once per process, like the web
        // shell's module — so appearance flips arrive here.
        super.onConfigurationChanged(newConfig);
        reportAppearance();
        // Locale is *not* in that configChanges list, so a language
        // change recreates this activity instead of landing here — the
        // view's construction re-reports the tag for exactly that path.
        // This line is for a consumer manifest that does claim locale,
        // and for the region/format flips Android sends without a
        // recreate; a report that finds the tag unchanged is dropped
        // natively.
        view.reportLocale();
    }

    @Override
    public void onWindowFocusChanged(boolean hasFocus) {
        super.onWindowFocusChanged(hasFocus);
        if (view != null) view.windowFocus(hasFocus);
    }

    @Override
    protected void onDestroy() {
        // Only if this is still the live one: a recreate constructs the
        // replacement before tearing this down, and clearing then would
        // strand `current()` at null for whoever asks next.
        if (live == this) live = null;
        super.onDestroy();
    }
}
