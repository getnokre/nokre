// The site's service worker — the notification service's web half that a
// page cannot provide for itself (docs/internals/notifications.md).
//
// Two things need a worker rather than a page. Chrome on Android refuses
// `new Notification()` outright and serves only
// ServiceWorkerRegistration.showNotification, so without this file the
// web leg would work on desktop and silently not on the platform where
// notifications matter most. And a push arrives with no page open at all,
// which is what push *is*: the worker is the only thing there to draw it.
//
// It carries no app logic and never routes: a tap is forwarded to whatever
// nokre client is open, or opens one, and the route reference rides along
// untouched — routing is the app's, exactly as it is for a deep link.
const NOKRE_ROUTE_PARAM = "nokre.route";

self.addEventListener("install", () => {
  // No precache and no offline story: this worker exists for
  // notifications, and a caching layer would be a second, unasked-for
  // behaviour with its own invalidation bugs. Take over immediately so
  // the first load can already subscribe.
  self.skipWaiting();
});

self.addEventListener("activate", (event) => {
  event.waitUntil(self.clients.claim());
});

// A push from the app's own backend. Display-only by contract: nokre
// refuses the silent data push, so a payload either shows something or is
// not ours. The shape is the app's to send — id and title are required,
// route and body optional — and it mirrors what the FCM leg reads from
// its data map, so one backend payload serves both.
self.addEventListener("push", (event) => {
  let data = {};
  try {
    data = event.data ? event.data.json() : {};
  } catch {
    return; // not JSON, so not ours to draw
  }
  const id = data["nokre.id"];
  const title = data["nokre.title"];
  if (!id || !title) return;
  event.waitUntil(
    (async () => {
      // A client already open takes the arrival as an event instead: a
      // banner over the app someone is looking at is the browser
      // interrupting on nokre's behalf, which is the same split apple.m
      // makes in willPresentNotification.
      const open = await self.clients.matchAll({ type: "window", includeUncontrolled: true });
      const visible = open.find((c) => c.visibilityState === "visible");
      if (visible) {
        visible.postMessage({ nokre: "received", id, route: data["nokre.route"] || "" });
        return;
      }
      await self.registration.showNotification(title, {
        body: data["nokre.body"] || "",
        tag: id,
        data: { id, route: data["nokre.route"] || "" },
        requireInteraction: data["nokre.important"] === "1",
      });
    })(),
  );
});

self.addEventListener("notificationclick", (event) => {
  event.notification.close();
  const payload = event.notification.data || {};
  event.waitUntil(
    (async () => {
      const open = await self.clients.matchAll({ type: "window", includeUncontrolled: true });
      for (const client of open) {
        // Focus the app that is already running rather than opening a
        // second copy — the deep-link posture every native shell takes
        // (singleTask on Android, WM_COPYDATA on Windows).
        await client.focus();
        client.postMessage({ nokre: "opened", id: payload.id || "", route: payload.route || "" });
        return;
      }
      // Nothing open: this is the web's cold-start tap. The route rides
      // as a query parameter because the page has to be loaded before it
      // can be told anything, and live.js hands it straight back to the
      // service as a tap once the app has booted.
      const url = new URL(self.registration.scope);
      if (payload.id) url.searchParams.set("nokre.id", payload.id);
      if (payload.route) url.searchParams.set(NOKRE_ROUTE_PARAM, payload.route);
      await self.clients.openWindow(url.toString());
    })(),
  );
});
