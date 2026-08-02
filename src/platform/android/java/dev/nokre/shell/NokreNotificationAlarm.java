// The receiver a scheduled notification fires into
// (docs/internals/notifications.md). Android is the one platform where a
// fire date is not something the notification system itself holds: the
// alarm is the OS's, but what it wakes is the app's, so this is the
// smallest possible thing to wake.
//
// It is also where the foreground rule is decided on this platform. With
// the app on screen the notification is *not* posted — a shade card drawn
// over the app the user is already looking at is the OS interrupting on
// nokre's behalf — and the arrival is reported to the app instead, which
// is the same split apple.m makes in willPresentNotification.
package dev.nokre.shell;

import android.app.NotificationManager;
import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;

public final class NokreNotificationAlarm extends BroadcastReceiver {
    @Override
    public void onReceive(Context context, Intent intent) {
        String id = intent.getStringExtra(NokreNotifications.EXTRA_ID);
        if (id == null) return;
        String route = intent.getStringExtra(NokreNotifications.EXTRA_ROUTE);
        if (NokreNotifications.foreground()) {
            NokreNotifications.deliverArrival(id, route);
            return;
        }
        // The process may have been started by this broadcast, in which
        // case NokreNotifications was never attached and has no context
        // of its own — so the receiver's is what builds the notification.
        NotificationManager nm =
                (NotificationManager) context.getSystemService(Context.NOTIFICATION_SERVICE);
        if (nm == null) return;
        String title = intent.getStringExtra(NokreNotifications.EXTRA_TITLE);
        if (title == null) return;
        String body = intent.getStringExtra(NokreNotifications.EXTRA_BODY);
        boolean important = intent.getBooleanExtra(NokreNotifications.EXTRA_IMPORTANT, false);
        nm.notify(id, 0, NokreNotifications.buildIn(context, id, title, body, route, important));
    }
}
