// FCM's half of the notification service — the one file in nokre that
// names a third-party library, and the second time the framework has
// asked a consumer for a Maven coordinate (docs/internals/notifications.md).
//
// It lives outside the shell's source set for iap's reason, restated: a
// consumer who links push adds the source directory and the coordinate to
// their own app/build.gradle, so the dependency's cost is in the open
// rather than smuggled into the shell. An app that links notifications
// without push never compiles this file, and NokreNotifications — which
// does compile always — deliberately names nothing here.
//
// The bar the contributing checklist sets for taking a dependency is met
// the way iap met it: Google's push path has no protocol left to speak.
// The device-token endpoint, the registration handshake and the message
// framing are all inside the library, and there is no documented wire
// format to reimplement.
package dev.nokre.shell;

import com.google.firebase.messaging.FirebaseMessaging;
import com.google.firebase.messaging.FirebaseMessagingService;
import com.google.firebase.messaging.RemoteMessage;
import java.util.Map;

public final class NokrePushService extends FirebaseMessagingService {
    /** The service's `requestPushToken`, reached from android.c by class
     *  lookup — the presence of this class is also what answers
     *  `pushAvailable` on Android, since it exists only when the consumer
     *  added the coordinate. */
    public static void requestToken() {
        FirebaseMessaging.getInstance().getToken().addOnCompleteListener(task -> {
            if (!task.isSuccessful()) return; // one token lane, no failure lane
            String token = task.getResult();
            if (token != null) NokreNotifications.deliverToken(token);
        });
    }

    /** FCM rotated the token. Reported on the same lane as the requested
     *  one, because an app writes one path: this is precisely the event
     *  nobody asked for that made the lane a lane. */
    @Override
    public void onNewToken(String token) {
        NokreNotifications.deliverToken(token);
    }

    /** A push arrived. Display-only by contract: nokre refuses the silent
     *  data push, so what a message may do is show something or, when the
     *  app is on screen, tell it that something showed up.
     *
     *  A payload carrying FCM's own `notification` block is drawn by the
     *  library before this runs and never reaches here at all while the
     *  app is backgrounded — which is the behaviour a display-only design
     *  wants. What this handles is the foreground case and the data-only
     *  payload an app's backend sends to reach the tap lane with a route. */
    @Override
    public void onMessageReceived(RemoteMessage message) {
        Map<String, String> data = message.getData();
        String id = data.get("nokre.id");
        if (id == null) return; // not ours to draw
        String route = data.get("nokre.route");
        if (NokreNotifications.foreground()) {
            NokreNotifications.deliverArrival(id, route);
            return;
        }
        String title = data.get("nokre.title");
        if (title == null) return;
        // Same builder as a local notification, so a pushed message and a
        // scheduled one are the same object by the time the OS sees them
        // — including the tap that carries the route back.
        android.app.NotificationManager nm = (android.app.NotificationManager)
                getSystemService(android.content.Context.NOTIFICATION_SERVICE);
        if (nm == null) return;
        nm.notify(id, 0, NokreNotifications.buildIn(getApplicationContext(), id, title,
                data.get("nokre.body"), route, "1".equals(data.get("nokre.important"))));
    }
}
