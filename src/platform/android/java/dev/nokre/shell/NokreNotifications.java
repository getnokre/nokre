// Android side of the notification service (docs/internals/notifications.md):
// channels, the runtime permission, posting, scheduling, and the tap.
//
// It lives in the shell's source set rather than beside iap's Java
// because the local half needs no Maven coordinate — everything here is
// framework API. The push half does need one, so it lives outside, in
// src/services/notification/java (NokrePushService), and nothing in this
// file may name it: an app that links notifications without push must
// still compile.
//
// Policy stays in Zig, as everywhere: the id charset, the byte caps, the
// authorization gate and the refusal of a past fire date all ran before
// any call reaches here. This file maps a checked payload onto the
// framework's own shapes.
package dev.nokre.shell;

import android.app.Activity;
import android.app.AlarmManager;
import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.PendingIntent;
import android.content.Context;
import android.content.Intent;
import android.content.SharedPreferences;
import android.content.pm.PackageManager;
import android.os.Build;
import java.nio.charset.StandardCharsets;

public final class NokreNotifications {
    /** The tap's payload, carried on the Intent that reopens the app. */
    static final String EXTRA_ID = "dev.nokre.notification.id";
    static final String EXTRA_ROUTE = "dev.nokre.notification.route";
    static final String EXTRA_TITLE = "dev.nokre.notification.title";
    static final String EXTRA_BODY = "dev.nokre.notification.body";
    static final String EXTRA_IMPORTANT = "dev.nokre.notification.important";

    /** Two channels, derived, with no configuration surface. A channel's
     *  importance is user-visible and immutable after creation, so it
     *  cannot be a knob an app turns per notification — and the semantic
     *  that decides it already exists: `important` is notices.Notify's
     *  own field, aimed outside the app. Quiet is the default because
     *  interrupting is the thing a message has to ask for. */
    private static final String CHANNEL_QUIET = "nokre.quiet";
    private static final String CHANNEL_IMPORTANT = "nokre.important";

    /** The permission request's own code. Any int does; this one spells
     *  "no" so a stray result in a log is identifiable. */
    private static final int PERMISSION_REQUEST = 0x6e6f;

    // Event kinds, mirroring notification.h — the C side passes them
    // through untouched, so they are stated once there and copied here
    // the way the a11y role table is.
    private static final int KIND_AUTHORIZED = 0;
    private static final int KIND_OPENED = 1;
    private static final int KIND_RECEIVED = 3;

    private static final int STATUS_NOT_DETERMINED = 0;
    private static final int STATUS_GRANTED = 1;
    private static final int STATUS_DENIED = 2;

    private static Activity activity;
    private static NokreView view;
    private static Context context;
    private static int lastStatus = STATUS_NOT_DETERMINED;

    private NokreNotifications() {}

    /** NokreActivity hands itself over at onCreate, NokreOAuth's shape.
     *  Harmless when the app links no notification service: nothing calls
     *  the verbs, and creating the channels is what makes them exist for
     *  the first post — Android refuses a notification whose channel was
     *  never registered, and registering twice is a no-op. */
    static void attach(Activity a, NokreView v) {
        activity = a;
        view = v;
        context = a.getApplicationContext();
        createChannels();
        lastStatus = status();
    }

    private static NotificationManager manager() {
        if (context == null) return null;
        return (NotificationManager) context.getSystemService(Context.NOTIFICATION_SERVICE);
    }

    private static void createChannels() {
        ensureChannels(context);
    }

    /** Takes the context rather than reading the static one: a scheduled
     *  alarm can start the process, and then nothing has attached yet.
     *  Registering a channel twice is a no-op, so the receiver calling
     *  this on every fire costs nothing. */
    static void ensureChannels(Context ctx) {
        if (Build.VERSION.SDK_INT < 26 || ctx == null) return; // channels arrived with O
        NotificationManager nm = (NotificationManager) ctx.getSystemService(Context.NOTIFICATION_SERVICE);
        if (nm == null) return;
        CharSequence label = ctx.getApplicationInfo().loadLabel(ctx.getPackageManager());
        // The names are what a user sees in the app's notification
        // settings, so they say what the split means rather than naming
        // nokre: the framework already shows the app's own label above
        // them.
        NotificationChannel quiet =
                new NotificationChannel(CHANNEL_QUIET, "Updates", NotificationManager.IMPORTANCE_DEFAULT);
        quiet.setDescription(label + " posts these quietly.");
        NotificationChannel important =
                new NotificationChannel(CHANNEL_IMPORTANT, "Alerts", NotificationManager.IMPORTANCE_HIGH);
        important.setDescription(label + " interrupts with these.");
        nm.createNotificationChannel(quiet);
        nm.createNotificationChannel(important);
    }

    /** Is there a notification system at all — always yes on Android; the
     *  question of whether it will *show* anything is `status`. */
    static boolean available() {
        return manager() != null;
    }

    /** The tri-state. Below API 33 there is no runtime permission and no
     *  "not determined" to report: notifications are on unless the user
     *  turned them off, which is exactly granted-or-denied. From 33 the
     *  permission exists, and the distinction that matters is whether we
     *  have ever asked — a denial the user has not been shown yet must
     *  not read as one they made. */
    static int status() {
        if (context == null) return STATUS_NOT_DETERMINED;
        NotificationManager nm = manager();
        if (Build.VERSION.SDK_INT < 33) {
            return nm != null && nm.areNotificationsEnabled() ? STATUS_GRANTED : STATUS_DENIED;
        }
        if (context.checkSelfPermission(android.Manifest.permission.POST_NOTIFICATIONS)
                == PackageManager.PERMISSION_GRANTED) {
            // The permission is granted and the user can still have
            // turned the app's notifications off wholesale in Settings.
            return nm != null && nm.areNotificationsEnabled() ? STATUS_GRANTED : STATUS_DENIED;
        }
        return asked() ? STATUS_DENIED : STATUS_NOT_DETERMINED;
    }

    private static SharedPreferences prefs() {
        return context.getSharedPreferences("dev.nokre.notification", Context.MODE_PRIVATE);
    }

    private static boolean asked() {
        return prefs().getBoolean("asked", false);
    }

    /** Raise the permission prompt. Below 33 there is nothing to raise,
     *  so the answer the OS already has is reported straight back — the
     *  app writes one path either way, which is the point of the event
     *  lane. */
    static void authorize() {
        if (Build.VERSION.SDK_INT < 33 || activity == null) {
            report();
            return;
        }
        prefs().edit().putBoolean("asked", true).apply();
        activity.requestPermissions(
                new String[] {android.Manifest.permission.POST_NOTIFICATIONS}, PERMISSION_REQUEST);
    }

    /** The prompt was answered (NokreActivity.onRequestPermissionsResult),
     *  or the app came forward and the user may have changed the setting
     *  in Settings meanwhile. Only a change is an event. */
    static void report() {
        int now = status();
        if (now == lastStatus) return;
        lastStatus = now;
        emit(KIND_AUTHORIZED, now, null, null);
    }

    static void post(byte[] id, byte[] title, byte[] body, byte[] route, boolean important,
            long atMillis) {
        if (context == null) return;
        String ident = str(id);
        if (atMillis != 0) {
            schedule(ident, title, body, route, important, atMillis);
            return;
        }
        NotificationManager nm = manager();
        if (nm == null) return;
        // The tag is the contract's id and the numeric id is always 0:
        // posting the same id replaces rather than stacks, which is the
        // rule the service states, and a (tag, 0) pair gives string
        // identity where the framework offers only an int.
        nm.notify(ident, 0, build(ident, str(title), str(body), str(route), important));
    }

    /** Built here rather than in the receiver so a scheduled fire and an
     *  immediate one produce the same notification, byte for byte. */
    static Notification build(String ident, String title, String body, String route,
            boolean important) {
        return buildIn(context, ident, title, body, route, important);
    }

    /** The builder proper, on a context the caller supplies: an alarm can
     *  start the process, and the receiver's context is then the only one
     *  there is. */
    static Notification buildIn(Context ctx, String ident, String title, String body, String route,
            boolean important) {
        ensureChannels(ctx);
        Intent open = new Intent(ctx, NokreActivity.class);
        // The tap must reach the running instance rather than stack a
        // second one, the deep-link posture — and CLEAR_TOP without
        // SINGLE_TOP would recreate it.
        open.setFlags(Intent.FLAG_ACTIVITY_NEW_TASK | Intent.FLAG_ACTIVITY_SINGLE_TOP);
        open.putExtra(EXTRA_ID, ident);
        if (route != null) open.putExtra(EXTRA_ROUTE, route);
        // IMMUTABLE is required from API 31 and correct everywhere: the
        // extras are nokre's own reference, and nothing outside the app
        // has any business rewriting them.
        PendingIntent tap = PendingIntent.getActivity(ctx, ident.hashCode(), open,
                PendingIntent.FLAG_UPDATE_CURRENT | PendingIntent.FLAG_IMMUTABLE);

        Notification.Builder b;
        if (Build.VERSION.SDK_INT >= 26) {
            b = new Notification.Builder(ctx, important ? CHANNEL_IMPORTANT : CHANNEL_QUIET);
        } else {
            b = new Notification.Builder(ctx);
            b.setPriority(important ? Notification.PRIORITY_HIGH : Notification.PRIORITY_DEFAULT);
        }
        b.setContentTitle(title);
        if (body != null && !body.isEmpty()) b.setContentText(body);
        // The launcher icon, because nokre draws no notification art and
        // has none to draw: the mark packaging derives is the app's whole
        // visual identity (docs/services.md), and a framework-supplied
        // glyph here would be one nobody chose.
        b.setSmallIcon(ctx.getApplicationInfo().icon);
        b.setContentIntent(tap);
        b.setAutoCancel(true);
        return b.build();
    }

    private static void schedule(String ident, byte[] title, byte[] body, byte[] route,
            boolean important, long atMillis) {
        AlarmManager am = (AlarmManager) context.getSystemService(Context.ALARM_SERVICE);
        if (am == null) return;
        Intent fire = new Intent(context, NokreNotificationAlarm.class);
        fire.putExtra(EXTRA_ID, ident);
        fire.putExtra(EXTRA_TITLE, str(title));
        fire.putExtra(EXTRA_BODY, str(body));
        fire.putExtra(EXTRA_ROUTE, str(route));
        fire.putExtra(EXTRA_IMPORTANT, important);
        PendingIntent pi = alarmIntent(ident, fire);
        // The inexact alarm, deliberately: the exact one is rationed
        // behind USE_EXACT_ALARM (which Play polices) or the revocable
        // SCHEDULE_EXACT_ALARM, and a fire date that reads "remind me in
        // the morning" does not need to be justified to Google. `set`
        // fires inside the OS's batching window, and while-idle keeps
        // Doze from parking it indefinitely.
        if (Build.VERSION.SDK_INT >= 23) {
            am.setAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, atMillis, pi);
        } else {
            am.set(AlarmManager.RTC_WAKEUP, atMillis, pi);
        }
    }

    private static PendingIntent alarmIntent(String ident, Intent fire) {
        // The request code is the id's hash so distinct ids get distinct
        // alarms and `cancel` can rebuild the same PendingIntent to find
        // one. A hash collision would replace another id's alarm; the
        // ids are app-authored and short, and the alternative is nokre
        // keeping a durable id table, which is the schedule-of-its-own
        // the design refuses.
        return PendingIntent.getBroadcast(context, ident.hashCode(), fire,
                PendingIntent.FLAG_UPDATE_CURRENT | PendingIntent.FLAG_IMMUTABLE);
    }

    static void cancel(byte[] id) {
        if (context == null) return;
        String ident = str(id);
        NotificationManager nm = manager();
        if (nm != null) nm.cancel(ident, 0);
        AlarmManager am = (AlarmManager) context.getSystemService(Context.ALARM_SERVICE);
        if (am != null) {
            // Both halves, because cancel is one verb: the shown one
            // above, and the scheduled one that has not fired.
            am.cancel(alarmIntent(ident, new Intent(context, NokreNotificationAlarm.class)));
        }
    }

    /** The Activity found notification extras on its intent — a tap that
     *  launched the app, or one delivered to the running instance. */
    static void deliverTap(String ident, String route) {
        emit(KIND_OPENED, lastStatus, ident, route);
    }

    /** A scheduled notification came due while the app was on screen, or
     *  a push arrived mid-session. The receiver posts nothing in that
     *  case: drawing a shade card over the app the user is looking at is
     *  the OS interrupting on nokre's behalf. */
    static void deliverArrival(String ident, String route) {
        emit(KIND_RECEIVED, lastStatus, ident, route);
    }

    /** NokrePushService's one call in, by reflection from the C side —
     *  named here so the token crosses on the same lane as everything
     *  else. */
    static void deliverToken(String token) {
        emit(2 /* KIND_PUSH_TOKEN */, lastStatus, token, null);
    }

    /** Whether the app is on screen, which is what decides between
     *  posting a scheduled notification and reporting its arrival. */
    static boolean foreground() {
        return view != null && view.isAttachedToWindow() && activity != null
                && !activity.isFinishing();
    }

    private static void emit(int kind, int status, String a, String b) {
        if (view == null) return;
        view.notificationEvent(kind, status, bytes(a), bytes(b));
    }

    private static byte[] bytes(String s) {
        // Standard UTF-8 through byte[], never GetStringUTFChars' modified
        // form — the text path's rule, and a notification body carries
        // emoji as readily as a message does.
        return s == null ? new byte[0] : s.getBytes(StandardCharsets.UTF_8);
    }

    private static String str(byte[] b) {
        return b == null ? "" : new String(b, StandardCharsets.UTF_8);
    }
}
