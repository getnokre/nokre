// Android half of the oauth service (docs/services.md; design in
// docs/internals/oauth.md): launch the authorize URL in a Custom Tab and
// notice when the user comes back without one.
//
// No androidx.browser dependency. The Custom Tabs protocol is not a
// library — it is a set of extras on a plain ACTION_VIEW intent, and the
// browser reads them or ignores them. Naming them by their string
// constants costs six lines and keeps nokre's Android build free of a
// Maven coordinate, which matters more here than elsewhere: nokre has
// no dependency manager of its own, so every third-party artifact would
// become the consumer's problem to add. A browser that ignores the
// extras opens a normal tab, which still satisfies RFC 8252.
//
// One service does have to take a coordinate, and naming it here keeps
// the rule above from reading as a promise nokre quietly broke: iap.
// Google requires the Play Billing Library and killed the AIDL interface
// that was once a protocol, so there is nothing to reimplement. Its Java
// half therefore lives outside this source set entirely
// (src/services/iap/java) and an app that links it adds both the source
// directory and the coordinate to its own build.gradle. Nothing in this
// file, or in the shell, changes.
//
// The cancel signal is the awkward part of this platform and it is worth
// naming. Nothing tells an app "the user dismissed the tab": the tab is
// another process, and backing out of it simply resumes this activity.
// So a resume that arrives while a flow is still live *is* the cancel.
// Launching the tab pauses this activity rather than resuming it, so
// there is no spurious first resume to filter out; and a redirect
// arrives as onNewIntent, which the system delivers before onResume, so
// a completed flow has already cleared itself by the time the resume
// runs.
package dev.nokre.shell;

import android.app.Activity;
import android.content.Intent;
import android.net.Uri;
import android.os.Bundle;

public final class NokreOAuth {
    private NokreOAuth() {}

    // Mirrors NOKRE_OAUTH_* in src/services/oauth/oauth.h.
    private static final int CALLBACK = 0;
    private static final int CANCELLED = 1;

    /** The Custom Tabs extras, by name. `SESSION` with a null binder is
     *  what actually switches a browser from "open a tab" to "open a
     *  Custom Tab"; the other two say the app owns the chrome around it. */
    private static final String EXTRA_SESSION = "android.support.customtabs.extra.SESSION";
    private static final String EXTRA_TITLE_VISIBILITY =
            "android.support.customtabs.extra.TITLE_VISIBILITY";
    private static final int SHOW_PAGE_TITLE = 1;

    /** The activity that launches the tab and the view that carries
     *  results back down. Single-app anchor, like the shell's own
     *  statics: an Android process hosts one nokre app. */
    private static Activity activity;
    private static NokreView view;
    /** True between `start` and the result. */
    private static boolean live;

    static void attach(Activity a, NokreView v) {
        activity = a;
        view = v;
    }

    /** Called from android.c. Returns false when no browser could be
     *  launched at all — a real state on a device with every browser
     *  disabled, and one the app should see as a named failure rather
     *  than a flow that never returns. */
    static boolean start(String url) {
        Activity a = activity;
        if (a == null || url == null) return false;
        Intent intent = new Intent(Intent.ACTION_VIEW, Uri.parse(url));
        Bundle extras = new Bundle();
        extras.putBinder(EXTRA_SESSION, null);
        intent.putExtras(extras);
        intent.putExtra(EXTRA_TITLE_VISIBILITY, SHOW_PAGE_TITLE);
        // NEW_TASK deliberately absent: the tab belongs to this task, so
        // backing out of it lands on this activity and the resume below
        // is the cancel signal. In its own task there would be nothing
        // to come back to.
        try {
            a.startActivity(intent);
        } catch (android.content.ActivityNotFoundException e) {
            return false;
        }
        live = true;
        return true;
    }

    /** The app cancelled the flow itself; stop watching for a resume. */
    static void forget() {
        live = false;
    }

    /** An inbound intent the activity received. Returns true when it was
     *  this flow's redirect — the activity then knows not to treat it as
     *  a deep link as well. */
    static boolean redirect(String url) {
        if (!live || url == null || view == null) return false;
        live = false;
        view.authResult(CALLBACK, url.getBytes(java.nio.charset.StandardCharsets.UTF_8));
        return true;
    }

    /** The activity resumed with a flow still live: the user came back
     *  from the tab without finishing. */
    static void resumed() {
        if (!live || view == null) return;
        live = false;
        view.authResult(CANCELLED, new byte[0]);
    }
}
