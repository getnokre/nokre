// The web edition's own gate: the three service legs that exist only in
// a browser, executed — `node tests/web_services.mjs <site>`, which is
// what `zig build test` runs (build.zig's addWebServicesCheck).
//
// The four are deep_link, oauth, secure_store and locale. Each is half
// Zig and half JavaScript, the halves talk through the wasm boundary,
// and until this file nothing ran either half: under `zig test` a
// service is its mock, `check-targets` compiles the web legs into
// objects it never links, and the parse step reads the JavaScript
// without executing a
// line. So the assertions here are all of one shape — the shipped
// `live.js` is driven the way a browser drives it, and what the *wasm
// app* recorded is read back through its probes (tests/web_services.zig).
// Nothing asserts that a function was called; everything asserts that
// the value arrived.
//
// The browser is tests/web_browser.mjs and knows nothing about nokre.
// Every fault a scenario needs — a blocked popup, a storage that
// throws, a message from the wrong origin, a page too long to be a
// redirect — is a property of that stub, so no code under test is
// modified, stubbed, or asked to be testable.

import assert from "node:assert/strict";
import fs from "node:fs/promises";
import path from "node:path";
import { pathToFileURL } from "node:url";

import { makeBrowser, PageEvent, Storage } from "./web_browser.mjs";

const site = process.argv[2];
if (!site) {
  console.error("usage: node tests/web_services.mjs <site directory>");
  process.exit(2);
}

const live = pathToFileURL(site + "/live.js").href;
const namespace = "nokre.ss.dev.nokre.webcheck/";

// A fresh module instance per scenario. live.js holds the app it
// mounted in a closure, but a second mount in one module would share
// whatever it keeps at module scope — and a browser that loads the page
// again gets neither. The query string is what makes node's module
// cache agree.
let loads = 0;

/// `env` is the browser this page loads in; `options` is what the page
/// itself hands `mount` — the two are separate because the whole of the
/// locale question is what happens when they disagree. `width` is the
/// mount element's, which is what core lays out against and so the only
/// thing about this page that is not furniture.
async function page(env = {}, options = {}, width = undefined) {
  const browser = makeBrowser({ site, ...env });
  const { mount } = await import(live + `?load=${++loads}`);
  const into = width === undefined ? browser.mountPoint() : browser.mountPoint(width);
  const nk = await mount({ wasm: "app.wasm", into, ...options });
  return { browser, into, nk, app: nk && probes(nk) };
}

/// The reader dragging the corner of their window. Both halves move,
/// because the driver answers the event by re-measuring the *container*
/// — a test that only fired the event would be asserting against the
/// width it started at (live.js's `remeasure`).
function resize(into, width) {
  into.clientWidth = width;
  dispatchEvent(new PageEvent("resize"));
}

/// The wasm app's probes, as calls that speak strings. Every view of
/// the heap is taken *after* the last call into the module and dropped
/// before the next: a call may grow the memory and detach it, which is
/// the same rule services.js keeps.
function probes(nk) {
  const utf8 = new TextDecoder();
  const bytes = new TextEncoder();
  const memory = () => new Uint8Array(nk.memory.buffer);

  const arg = (...parts) => {
    const ptr = nk.nokre_probe_arg();
    const lengths = [];
    let off = 0;
    for (const part of parts) {
      const raw = typeof part === "string" ? bytes.encode(part) : part;
      memory().set(raw, ptr + off);
      off += raw.length;
      lengths.push(raw.length);
    }
    return lengths;
  };
  const raw = (len) => {
    const ptr = nk.nokre_probe_result();
    return memory().slice(ptr, ptr + len);
  };
  const text = (len) => utf8.decode(raw(len));
  const failure = () => new Error(`the app's verb returned error.${text(nk.nokre_probe_error())}`);

  return {
    links: () => nk.nokre_probe_links(),
    link: () => text(nk.nokre_probe_link()),

    /// The whole file `dom.document` writes for the screen this app is
    /// on — the static half of the pair, asked of the same module the
    /// live half runs in.
    document() {
      const len = nk.nokre_probe_document();
      if (len === -2) throw failure();
      return text(len);
    },
    /// The same file with no boot on it — the page of a static site
    /// that nothing will ever mount over. `-2` here is the writer
    /// refusing rather than a buffer overrun, so the error name comes
    /// back with the throw: a page that needs a runtime is not
    /// publishable without one, and which is which is the assertion.
    documentUnbooted() {
      const len = nk.nokre_probe_document_unbooted();
      if (len === -2) throw failure();
      return text(len);
    },
    /// Which chip the app believes is chosen.
    view: () => nk.nokre_probe_view(),

    /// Arrive at a screen the way a generator does, one page at a time
    /// — never a push, which would hang a Back control over the file.
    switchTo(name) {
      const [n] = arg(name);
      if (!nk.nokre_probe_switch_to(n)) throw failure();
    },
    /// Re-declare the roster as six long-named destinations: the set
    /// whose row is a real question in a desktop window.
    wideNav() {
      if (!nk.nokre_probe_wide_nav()) throw failure();
    },

    bootValue() {
      const len = nk.nokre_probe_boot_value();
      return len < 0 ? null : text(len);
    },
    get(key) {
      const [k] = arg(key);
      const len = nk.nokre_probe_store_get(k);
      if (len === -1) return null;
      if (len === -2) throw failure();
      return text(len);
    },
    getBytes(key) {
      const [k] = arg(key);
      const len = nk.nokre_probe_store_get(k);
      if (len === -1) return null;
      if (len === -2) throw failure();
      return raw(len);
    },
    set(key, value) {
      const [k, v] = arg(key, value);
      if (nk.nokre_probe_store_set(k, v) === -2) throw failure();
    },
    delete(key) {
      const [k] = arg(key);
      if (nk.nokre_probe_store_delete(k) === -2) throw failure();
    },
    list() {
      const len = nk.nokre_probe_store_list();
      if (len === -2) throw failure();
      return len === 0 ? [] : text(len).split("\n");
    },

    redirect() {
      const len = nk.nokre_probe_redirect();
      return len < 0 ? null : text(len);
    },
    deviceTag: () => text(nk.nokre_probe_device_tag()),
    locale: () => text(nk.nokre_probe_locale()),
    rtl: () => nk.nokre_probe_rtl() === 1,
    localeChanges: () => nk.nokre_probe_locale_changes(),

    results: () => nk.nokre_probe_oauth_results(),
    status: () => ["none", "callback", "cancelled", "failure"][nk.nokre_probe_oauth_status()],
    authText: () => text(nk.nokre_probe_oauth_text()),
    cancelAuth: () => nk.nokre_probe_oauth_cancel(),
    error: () => text(nk.nokre_probe_error()),
  };
}

const b64 = (s) => Buffer.from(s, "utf8").toString("base64");

function done(line) {
  console.error("web services: " + line);
}

// ---- deep_link ---------------------------------------------------

/// The lane is `deliverDeepLink` → `nokre_deep_link_receive` → the
/// handler the app registered inside its first `build`. A launch
/// fragment is the first callback after boot (docs/services.md), and
/// every `hashchange` after it is another one.
async function deepLink() {
  const launch = "https://app.example/#/invite?token=abc%20def&who=caf%C3%A9";
  const { browser, app } = await page({ href: launch });

  // Delivered once — not zero times, and not twice because live.js
  // registers two hashchange listeners and only one of them is this
  // service's.
  assert.equal(app.links(), 1);
  assert.equal(app.link(), launch);

  // The address bar now names the screen the router is on, so a
  // fragment that arrives later is a different URL by construction.
  const second = browser.hashChange("#/order/42");
  assert.equal(app.links(), 2);
  assert.equal(app.link(), second);

  // The payload is bytes, not a string the driver may normalize: a
  // percent-encoded slash, a percent-encoded space, and a multi-byte
  // character all have to reach the app exactly as the address bar
  // held them — an app parses this itself, and a URL that arrived
  // half-decoded is a token that no longer matches.
  const encoded = browser.hashChange("#/r?u=https%3A%2F%2Fx.test%2Fa%2Bb&n=%E2%9C%93%20%E2%82%AC");
  assert.equal(app.links(), 3);
  assert.equal(app.link(), encoded);
  assert.ok(encoded.includes("%3A%2F%2F"));

  done("deep_link — launch fragment, hashchange, an encoded payload byte for byte");
}

/// A page whose fragment is empty delivers nothing: the service's
/// contract is "a URL came in", and no URL came in.
async function deepLinkQuiet() {
  const { app, browser } = await page({ href: "https://app.example/" });
  assert.equal(app.links(), 0);
  // …and the handler is installed all the same, so the first fragment
  // after boot still lands.
  const arrived = browser.hashChange("#/late");
  assert.equal(app.links(), 1);
  assert.equal(app.link(), arrived);
  done("deep_link — a page with no fragment delivers nothing, and still receives the next one");
}

// ---- oauth -------------------------------------------------------

/// The popup's half: the provider redirected back to the app's own
/// page, in the popup, and that page must report to its opener and
/// close rather than boot a second app.
async function oauthPopupReports() {
  const received = [];
  const href = "https://app.example/?code=abc123&state=xyz";
  const { browser, nk } = await page({
    href,
    opener: { postMessage: (data, origin) => received.push({ data, origin }) },
  });

  // `mount` returned null: live.js:62 recognised the popup and stopped
  // before instantiating anything.
  assert.equal(nk, null);
  assert.equal(browser.fetches.length, 0);
  assert.deepEqual(received, [{ data: { t: "nokre.oauth", href }, origin: "https://app.example" }]);
  // The target origin is exact, never "*": the message carries an
  // authorization code.
  assert.notEqual(received[0].origin, "*");
  assert.equal(browser.closes, 1);

  done("oauth — the popup reports its URL to its opener at an exact origin, then closes");
}

/// The same page with an opener and no auth response is an ordinary
/// tab: it boots the app. The narrow test is the whole reason a
/// consumer needs no second HTML file.
async function oauthPopupIgnoresOrdinaryPage() {
  const received = [];
  const { browser, nk } = await page({
    href: "https://app.example/#home",
    opener: { postMessage: (data, origin) => received.push({ data, origin }) },
  });
  assert.notEqual(nk, null);
  assert.equal(received.length, 0);
  assert.equal(browser.closes, 0);
  done("oauth — an opened window that carries no auth response boots the app instead");
}

/// The opener's half, whole: a press opens the popup, the popup's
/// message ends the flow, and the callback URL reaches the app's
/// handler byte for byte.
async function oauthFlow() {
  const { browser, app } = await page();

  browser.press("Sign in");
  // The redirect is the page's own address — no custom scheme, because
  // in a browser the origin is the registration.
  assert.equal(app.redirect(), "https://app.example/");
  assert.equal(app.error(), "");
  assert.equal(browser.popups.length, 1);
  const popup = browser.popups[0];
  assert.ok(popup.url.includes("redirect_uri=https://app.example/"));
  // Named, so a second sign-in reuses the window rather than stacking.
  assert.equal(popup.name, "nokre-oauth");
  assert.equal(app.results(), 0);

  const landed = "https://app.example/?code=the-code&state=xyz";
  browser.postToPage({ data: { t: "nokre.oauth", href: landed }, source: popup });

  assert.equal(app.results(), 1);
  assert.equal(app.status(), "callback");
  assert.equal(app.authText(), landed);

  // The popup closed itself; the poll that would have called this a
  // cancel was cleared by the result.
  popup.closed = true;
  browser.clock.advance(5000);
  assert.equal(app.results(), 1);
  assert.equal(app.status(), "callback");

  done("oauth — a press opens the popup, its postMessage ends the flow, the callback URL lands whole");
}

/// The security property, and the reason this file exists at all: the
/// message carries an authorization code, so only the window this flow
/// opened, posting from this origin, may end it.
async function oauthRefusesForgeries() {
  const { browser, app } = await page();
  browser.press("Sign in");
  const popup = browser.popups[0];
  const landed = "https://app.example/?code=stolen&state=xyz";

  // Another origin entirely — the provider's own page, an ad frame,
  // anything that got a handle on this window.
  browser.postToPage({
    data: { t: "nokre.oauth", href: landed },
    origin: "https://evil.example",
    source: popup,
  });
  assert.equal(app.results(), 0);

  // Same origin, wrong window: any frame on this origin could post a
  // forged callback, and same-origin alone would accept it.
  browser.postToPage({ data: { t: "nokre.oauth", href: landed }, source: new (class {})() });
  assert.equal(app.results(), 0);

  // The right window, saying something else.
  browser.postToPage({ data: { t: "other" }, source: popup });
  browser.postToPage({ data: null, source: popup });
  assert.equal(app.results(), 0);

  // And the genuine one, which the refusals above must not have
  // consumed: a flow that survived three forgeries is still live.
  const real = "https://app.example/?code=the-code&state=xyz";
  browser.postToPage({ data: { t: "nokre.oauth", href: real }, source: popup });
  assert.equal(app.results(), 1);
  assert.equal(app.status(), "callback");
  assert.equal(app.authText(), real);

  done("oauth — a foreign origin, a foreign window and a foreign message are all refused");
}

/// The three ways a flow ends without a callback.
async function oauthEndings() {
  // Blocked. The one failure a user can fix, so it has its own name —
  // and it arrives a task later, never inside `start`, because a result
  // must not land before the app holds the handle.
  {
    const { browser, app } = await page({ popupBlocked: true });
    browser.press("Sign in");
    assert.equal(browser.popups.length, 0);
    assert.equal(app.results(), 0); // synchronously: nothing yet
    await browser.settle();
    assert.equal(app.results(), 1);
    assert.equal(app.status(), "failure");
    assert.equal(app.authText(), "PopupBlocked");
  }

  // The user closes the popup. No browser fires an event for that, so
  // the poll is the only report — and its 100 ms grace is what keeps a
  // popup that posted and then closed from being read as a cancel.
  {
    const { browser, app } = await page();
    browser.press("Sign in");
    browser.popups[0].closed = true;
    browser.clock.advance(400);
    assert.equal(app.results(), 0); // the grace beat, not yet a cancel
    browser.clock.advance(100);
    assert.equal(app.results(), 1);
    assert.equal(app.status(), "cancelled");
  }

  // The app dismisses its own session: the popup closes and the
  // handler never runs — which is not the same as the user cancelling.
  {
    const { browser, app } = await page();
    browser.press("Sign in");
    app.cancelAuth();
    assert.equal(browser.popups[0].closed, true);
    browser.clock.advance(5000);
    assert.equal(app.results(), 0);
  }

  done("oauth — blocked, cancelled by the user, and dismissed by the app");
}

/// A page whose URL will not fit the redirect cap seeds nothing, and
/// the first sign-in fails loudly instead of sending a truncated URI
/// the provider would reject at the token exchange.
async function oauthRedirectTooLong() {
  const { browser, app } = await page({ href: "https://app.example/" + "p".repeat(2100) });
  browser.press("Sign in");
  assert.equal(app.redirect(), null);
  assert.equal(app.error(), "RedirectTooLong");
  assert.equal(browser.popups.length, 0);
  done("oauth — a page too long to be a redirect seeds nothing and fails loudly");
}

// ---- secure_store ------------------------------------------------

/// The seed's contract is an ordering: the snapshot is poured into the
/// in-wasm table strictly before `nokre_dom_boot`, so a `get` inside
/// the app's first `build` answers synchronously. The app records that
/// read and nothing else can produce it.
async function storeSeed() {
  const storage = new Storage({
    [namespace + "token"]: b64("secret-token"),
    [namespace + "user.id"]: b64("42"),
    // sessionStorage is same-origin-writable, so every one of these is
    // something a page could really find there — and each is dropped by
    // a different guard.
    "nokre.ss.other.app/token": b64("someone else's"), // another app's namespace
    [namespace + "BAD KEY"]: b64("out of contract"), // not a storable key
    [namespace + "junk"]: "not base64 !!", // does not decode
    "unrelated.key": "left alone",
  });

  const { app } = await page({ storage });
  assert.equal(app.bootValue(), "secret-token");
  assert.deepEqual(app.list(), ["token", "user.id"]);
  assert.equal(app.get("user.id"), "42");
  // Untouched: this file's scan takes only what carries the prefix.
  assert.equal(storage.getItem("unrelated.key"), "left alone");

  done("secure_store — the boot snapshot lands before the first build, and only in-contract entries do");
}

/// Writes mutate the table synchronously and mirror out best-effort;
/// the shadow's schema is one prefix and base64, both directions.
async function storeMirror() {
  const storage = new Storage();
  const { app } = await page({ storage });

  app.set("token", "t0ken");
  assert.equal(storage.getItem(namespace + "token"), b64("t0ken"));

  // A secret is bytes. base64 is the bridge because sessionStorage
  // holds UTF-16 strings, and a value with a zero byte in it is the
  // case that says whether the bridge is lossless.
  const blob = new Uint8Array([0, 1, 0x80, 0xff, 0x7f, 0]);
  app.set("blob", blob);
  assert.deepEqual(app.getBytes("blob"), blob);
  assert.equal(storage.getItem(namespace + "blob"), Buffer.from(blob).toString("base64"));

  // An empty value is a value, distinct from absence, on both sides.
  app.set("empty", "");
  assert.equal(storage.getItem(namespace + "empty"), "");
  assert.equal(app.get("empty"), "");

  app.delete("blob");
  assert.equal(storage.getItem(namespace + "blob"), null);
  // Deleting what was never there is the postcondition already met —
  // and it still mirrors, so a boot snapshot can never resurrect it.
  app.delete("never-set");
  assert.equal(app.get("never-set"), null);
  assert.deepEqual(app.list(), ["empty", "token"]);

  done("secure_store — set and delete mirror out, base64 carries bytes, list stays sorted");
}

/// The whole point of the shadow: a reload is a new wasm instance with
/// an empty table, and what it starts with is whatever the last one
/// left in sessionStorage.
async function storeSurvivesReload() {
  const storage = new Storage();
  {
    const { app } = await page({ storage });
    assert.equal(app.bootValue(), null);
    app.set("token", "carried-over");
    app.set("scratch", "dropped later");
    app.delete("scratch");
  }
  {
    const { app } = await page({ storage });
    assert.equal(app.bootValue(), "carried-over");
    assert.deepEqual(app.list(), ["token"]);
  }
  done("secure_store — a value survives a reload, and a deleted one does not come back");
}

/// Private mode, storage disabled by policy, a quota the host page
/// already burned: the table is the truth and keeps answering. The web
/// leg has no `Unavailable` — a stated posture, and this is where it is
/// worth something.
async function storeWithoutStorage() {
  {
    const { app, browser } = await page({ storageBlocked: true });
    assert.equal(app.bootValue(), null);
    app.set("token", "session only");
    assert.equal(app.get("token"), "session only");
    assert.deepEqual(app.list(), ["token"]);
    app.delete("token");
    assert.equal(app.get("token"), null);
    // One warning for the dropped write, and none for the delete: only
    // reload-survival was lost, and it was never in the sync contract.
    assert.equal(browser.warnings.length, 1);
    assert.match(browser.warnings[0], /secure_store mirror dropped a write/);
  }

  // A storage that reads but cannot be written — the quota case.
  {
    const storage = new Storage();
    const { app, browser } = await page({ storage });
    storage.full = true;
    app.set("token", "session only");
    assert.equal(app.get("token"), "session only");
    assert.equal(storage.getItem(namespace + "token"), null);
    assert.equal(browser.warnings.length, 1);
  }

  done("secure_store — a blocked or full storage costs reload-survival and nothing else");
}

// ---- locale ------------------------------------------------------

// The seed lane is `nokre_locale_scratch` / `nokre_locale_seed`, poured
// strictly before `nokre_dom_boot` so the tag is in hand inside the
// first `build` (services/locale/web.zig). What the assertions below
// are about is *which* tag, because there are two answers and the wrong
// one is invisible: hydration matches nodes by tag and `data-n`, never
// by text, so an app that boots in the reader's language over a page
// written in another swaps every string and reports nothing.
//
// The app resolves what it is given through its own bundle
// (tests/web_services.zig: `L.resolve` → `setLocale` → `setDirection`,
// the three lines docs/localization.md prescribes), so every scenario
// reads back three things — the tag the shell reported, the locale the
// app is in, and the words that reached the document.

/// No page said anything, so the device is the answer — the lane that
/// existed before the page could speak, unchanged.
async function localeFollowsTheDevice() {
  const { app, into, browser } = await page({ language: "fa-IR" });
  assert.equal(app.deviceTag(), "fa-IR");
  // Resolved, not echoed: "fa-IR" is not a locale this bundle has.
  assert.equal(app.locale(), "fa");
  assert.equal(app.rtl(), true);
  assert.ok(into.textContent.includes("سرویس‌های وب"));
  assert.equal(browser.document.documentElement.dataset.direction, "rtl");
  done("locale — a page that says nothing boots in the device's language");
}

/// The item: a page generated in one language, opened in a browser set
/// to another. Everything the reader sees has to be the page's.
async function localeOfThePageWins() {
  const { app, into, browser } = await page({ language: "en-US" }, { locale: "fa" });
  assert.equal(app.deviceTag(), "fa");
  assert.equal(app.locale(), "fa");
  assert.ok(into.textContent.includes("سرویس‌های وب"));
  assert.ok(!into.textContent.includes("web services"));
  // The direction rides the same channel, and it is the half a static
  // page cannot recover on its own: there is no media query for
  // direction, so a boot that resolved `en` here would flip
  // `data-direction` to ltr under a document still announcing `dir=rtl`.
  assert.equal(app.rtl(), true);
  assert.equal(browser.document.documentElement.dataset.direction, "rtl");
  done("locale — the page's language beats the browser's, and the direction with it");
}

/// The other direction, which is the rule that keeps a shared URL
/// showing one thing: an `en` page in a Persian browser stays English.
async function localePinnedPageIsNeverRedirected() {
  const { app, into, browser } = await page({ language: "fa-IR" }, { locale: "en" });
  assert.equal(app.locale(), "en");
  assert.equal(app.rtl(), false);
  assert.ok(into.textContent.includes("web services"));
  assert.equal(browser.document.documentElement.dataset.direction, "ltr");
  done("locale — a pinned page keeps its language in a browser set to another");
}

/// The empty tag is a value here, not an absent option: it is the
/// document of an app that chose no locale, whose catalog resolved to
/// its own template — and that is what a boot has to reproduce.
async function localeEmptyPinIsTheTemplate() {
  const { app, into } = await page({ language: "fa-IR" }, { locale: "" });
  assert.equal(app.deviceTag(), "");
  assert.equal(app.locale(), "en");
  assert.ok(into.textContent.includes("web services"));
  done("locale — the empty tag pins the catalog's template, it does not mean 'ask the device'");
}

/// One resolution policy and not two: a tag the bundle does not carry
/// lands exactly where the same tag lands on the device lane, because
/// both are `L.resolve` inside the app and nothing resolves anything in
/// the driver.
async function localeUnbundledPinResolvesLikeTheDevice() {
  const device = await page({ language: "de-DE" });
  assert.equal(device.app.locale(), "en");
  const pinned = await page({ language: "fa-IR" }, { locale: "de-DE" });
  assert.equal(pinned.app.deviceTag(), "de-DE");
  assert.equal(pinned.app.locale(), device.app.locale());
  done("locale — an unbundled tag falls back the same way on both lanes");
}

/// After boot the device lane still moves a page that was following the
/// device, and never moves one that pinned: the reader changing their
/// browser's language is not a reason for /fa/ to become English.
async function localeChangeAfterBoot() {
  const following = await page({ language: "en-US" });
  assert.equal(following.app.locale(), "en");
  following.browser.languageChange("fa-IR");
  assert.equal(following.app.localeChanges(), 1);
  assert.equal(following.app.locale(), "fa");
  assert.ok(following.into.textContent.includes("سرویس‌های وب"));

  const pinned = await page({ language: "en-US" }, { locale: "fa" });
  pinned.browser.languageChange("de-DE");
  assert.equal(pinned.app.localeChanges(), 0);
  assert.equal(pinned.app.locale(), "fa");
  assert.ok(pinned.into.textContent.includes("سرویس‌های وب"));
  done("locale — a change reaches a page following the device and no pinned page");
}

// ---- the service worker's registration ---------------------------

/// The registration URL must be the worker's own address, resolved
/// against services.js itself — never a page-relative name. Under the
/// static site's documents addressing every page but the root lives at
/// /route/, so a page-relative "sw.js" would ask for /route/sw.js: a
/// 404 on every page load. The stub records the URL exactly as handed
/// over, so a page-relative registration shows up here as the bare
/// string a browser would misresolve.
async function serviceWorkerRooted() {
  const { browser } = await page();
  assert.deepEqual(browser.serviceWorkers, [
    new URL("./sw.js", pathToFileURL(site + "/services.js")).href,
  ]);
  done("service worker — registered beside the driver, not beside the page");
}

// ---- the site's own manifest -------------------------------------

// The one non-service scenario, and it rides this gate because this is
// the one place a built site sits on disk during `zig build test`.
// `site.manifest` (build.zig's addWebSite) is the site's file list
// published as data — what a consumer's deploy tooling verifies a
// copied site against instead of re-typing nokre's contract — so it
// must agree with the directory it ships in, both ways: a file the
// manifest names but the site lacks is a verifier that would pass a
// broken deploy, and a file the site carries but the manifest misses is
// the drift the manifest exists to end.
async function siteManifest() {
  const listed = (await fs.readFile(path.join(site, "site.manifest"), "utf8"))
    .split("\n")
    .filter(Boolean);
  const actual = [];
  const walk = async (dir, prefix) => {
    for (const entry of await fs.readdir(dir, { withFileTypes: true })) {
      if (entry.isDirectory()) {
        await walk(path.join(dir, entry.name), prefix + entry.name + "/");
      } else {
        actual.push(prefix + entry.name);
      }
    }
  };
  await walk(site, "");
  const expected = actual.filter((f) => f !== "site.manifest").sort();
  assert.deepEqual(listed, expected);
}

// ---- the driver's own doors --------------------------------------

/// Not a service: the seven exports that take a string take a *length*
/// with it, and a web build is ReleaseSmall, so nothing behind the
/// slice checks that length against the buffer the glue filled. The
/// clamp is `scratchSlice` (live.zig) and `nokre_dom_href` is the door
/// that hands its answer straight back out, so it is the one a harness
/// can ask. This is the only gate where those exports run at all.
async function scratchIsClamped() {
  const { nk } = await page({ href: "https://app.example/" });
  const ref = new TextEncoder().encode("home");
  const ptr = nk.nokre_dom_scratch(ref.length);
  new Uint8Array(nk.memory.buffer).set(ref, ptr);

  // The default resolver answers "#" + the reference verbatim, so the
  // href is one byte longer than the reference — for the bytes the glue
  // actually wrote, however many it claims.
  nk.nokre_dom_href(ref.length);
  assert.equal(nk.nokre_dom_href_len(), ref.length + 1);
  nk.nokre_dom_href(ref.length + 64);
  assert.equal(nk.nokre_dom_href_len(), ref.length + 1);
  done("dom driver — a length past the scratch is cut to what the glue wrote");
}

// ---- the two-mount page ------------------------------------------

/// The arrangement `dom.document` writes, and the one the reference
/// site and every static consumer boot in: two mount points,
/// `addressing: "documents"`, and a page that is *already showing the
/// screen* when the module lands on it.
///
/// It is the shape nothing else here has. Every scenario above boots
/// into a bare div, which is an app shell's page and the one case where
/// hydration has nothing to hydrate — so the handover itself, the claim
/// that "boot is a patch rather than a repaint" (dom-edition.md), was
/// never executed anywhere.
///
/// Two module instances, deliberately. The first writes the file, with
/// the library, out of the app's own tree; the second is the browser's,
/// booting over the parsed result. That is the pair the two drivers
/// were split for, and running it as a pair is the only way a
/// disagreement between them shows up as anything but a page that looks
/// right.
async function documentsPage() {
  const generator = await page({}, { route: "home", locale: "", addressing: "documents" });
  const file = generator.app.document();

  const browser = makeBrowser({ site });
  browser.openPage(file);
  const chrome = document.body.querySelector("#chrome");
  const content = document.body.querySelector("#content");
  assert.ok(chrome, "the file has a chrome mount");
  assert.ok(content, "the file has a content mount");
  // The roster is what puts anything in the chrome mount at all: a page
  // whose first mount is empty would assert nothing about it.
  const bar = chrome.querySelector("nav");
  assert.ok(bar, "the file's chrome mount holds the nav");
  assert.ok(content.querySelector("[data-n]"), "the file states node ids");

  // Which shape the roster wears is the reader's window's, decided by
  // the sheet over one markup — so this file carries the same class
  // list the frame below will rebuild, and the reader's window is free
  // to change its mind afterwards without anything re-rendering. It
  // carries the same list as a file with no boot on it, too: nothing
  // about who will or will not mount over a page is a term in a
  // question about the window it is read in.
  assert.equal(bar.getAttribute("class"), "nav", "a page that boots states a shape");

  // The nodes the reader is looking at, held from before the mount.
  // Identity is the whole assertion: nokre states every focus stop's
  // `NodeId` in both drivers' output precisely so the handover can keep
  // the node rather than build a new one that looks like it — and a
  // replaced node is a lost scroll offset, a lost selection and a lost
  // caret, none of which the markup afterwards would show.
  const before = { chrome: [...chrome.childNodes], content: [...content.childNodes] };

  const { mount } = await import(live + `?load=${++loads}`);
  const nk = await mount({
    wasm: "app.wasm",
    into: chrome,
    content,
    route: "home",
    locale: "",
    addressing: "documents",
  });
  const app = probes(nk);

  const kept = (was, is) => is.filter((n) => was.includes(n)).length;
  assert.equal(
    kept(before.content, [...content.childNodes]),
    before.content.length,
    "hydration replaced the content mount's nodes instead of patching them",
  );
  assert.equal(
    kept(before.chrome, [...chrome.childNodes]),
    before.chrome.length,
    "hydration replaced the chrome mount's nodes instead of patching them",
  );

  // And the page is live: a press on the second chip reaches the app,
  // and the sentence the *builder* writes under the control moves with
  // it. A chip that moved alone would only prove the browser resolved a
  // hit.
  const chip = document.body
    .querySelectorAll("[data-i]")
    .find((el) => el.textContent.includes("Grid"));
  assert.ok(chip, "the file carries the segmented control");
  chip.dispatchEvent(new PageEvent("click"));
  assert.equal(app.view(), 1);
  assert.ok(
    content.textContent.includes("Showing a grid."),
    "the repaint after the press never landed",
  );

  done("the document — two mounts hydrate node for node, and a press repaints");
}

/// The same page, booted by **the file the page asks for** instead of by
/// a `mount` call this harness typed.
///
/// It is the scenario the whole shape exists for. `dom.document` used to
/// write the boot as an inline `<script>` block, which is precisely what
/// `script-src 'self'` refuses — and a static site cannot hash its way
/// out, because every page's block carries that page's route and locale.
/// The first migration to publish one turned its entire `script-src`
/// over to `'unsafe-inline'` for 1,132 blocks the library had written
/// itself. So the code is a file the site serves and the per-page bytes
/// are an `application/json` data block, which a browser never executes.
///
/// Nothing below asserts that arrangement by reading the markup, which
/// `document_test.zig` already does. It *runs* it: the page's own
/// `<script src>` is resolved to the site's own file, the module is
/// imported with nothing handed to it, and it finds its data, resolves
/// its two mounts and mounts — after which a real press has to reach the
/// app and the repaint has to land. Every earlier scenario here passes a
/// hand-written option object to `mount`, so until this one the page's
/// half of the boot was the half nothing executed.
async function theBootIsAFileThePageNames() {
  const generator = await page({}, { route: "home", locale: "", addressing: "documents" });
  const file = generator.app.document();

  // Not one executable byte in the file. Asserted here rather than only
  // in Zig because this is the run that proves the page still boots
  // *with* that being true — the two halves of one claim.
  for (const [, tag] of file.matchAll(/<script([^>]*)>/g)) {
    assert.ok(
      / src="/.test(tag) || /type="application\/json"/.test(tag),
      `the document carries an inline script: <script${tag}>`,
    );
  }

  const named = /<script type="module" src="([^"]*)"><\/script>/.exec(file);
  assert.ok(named, "the document names no boot module");
  // The site really serves what the page asks for. `site.manifest` and
  // the directory agree by another scenario; what is checked here is
  // that the *page* names a member of that set, which is the failure
  // mode a re-typed file name has — a page that renders and never boots.
  const boot = path.join(site, path.basename(named[1]));
  assert.equal((await fs.stat(boot)).isFile(), true, `the site serves no ${named[1]}`);

  const browser = makeBrowser({ site });
  browser.openPage(file);
  const content = document.body.querySelector("#content");
  assert.ok(content, "the file has a content mount");

  // The import *is* the boot: live-boot.js reads the block, resolves
  // the mounts by the ids the markup used, and awaits `mount` at the top
  // level — so when this resolves the app is running over the page.
  // Nothing is passed in, because a page passes nothing in.
  await import(pathToFileURL(boot).href);

  const chip = document.body
    .querySelectorAll("[data-i]")
    .find((el) => el.textContent.includes("Grid"));
  assert.ok(chip, "the file carries the segmented control");
  chip.dispatchEvent(new PageEvent("click"));
  assert.ok(
    content.textContent.includes("Showing a grid."),
    "a page booted by its own file never answered a press",
  );

  done("the boot — a page names a file, the file finds its data, and the press lands");
}

// ---- the nav's two shapes ----------------------------------------
//
// Three releases in a row shipped a nav that passed its tests and was
// wrong in a browser, and every one of them was the same kind of
// mistake: the *tree* said one shape and the *sheet* drew another, and
// nothing anywhere held the two against each other. Neither half can
// catch it alone — a Zig test sees the tree the sheet never reads, and
// a substring check on the sheet sees rules no tree ever met.
//
// So this section runs both. The stylesheet the build just wrote is
// parsed and resolved at a width, the way a browser resolves it; the
// app is booted at the same width through the shipped live.js; and the
// assertion is that they agree about what a reader is looking at.

/// The sheet as rules: a selector, the `max-width` it is behind (null
/// for the unconditional ones), its declarations, and its place in the
/// file — which is the cascade's last tiebreak and the one this sheet
/// leans on, `writeDerived` coming after the static block precisely so
/// each derived rule is the last word on its property.
function parseCss(text) {
  const src = text.replace(/\/\*[\s\S]*?\*\//g, "");
  const rules = [];
  let order = 0;

  const collect = (body, media) => {
    let k = 0;
    while (k < body.length) {
      const open = body.indexOf("{", k);
      if (open < 0) break;
      const prelude = body.slice(k, open).trim();
      let depth = 0;
      let close = open;
      for (; close < body.length; close++) {
        if (body[close] === "{") depth++;
        else if (body[close] === "}" && --depth === 0) break;
      }
      const inner = body.slice(open + 1, close);
      const at = /^@media\s*\(max-width:\s*(\d+)px\)$/.exec(prelude);
      if (at) collect(inner, Number(at[1]));
      else if (!prelude.startsWith("@")) {
        const decls = {};
        for (const part of inner.split(";")) {
          const colon = part.indexOf(":");
          if (colon > 0 && !part.slice(0, colon).includes("{")) {
            decls[part.slice(0, colon).trim()] = part.slice(colon + 1).trim();
          }
        }
        for (const sel of prelude.split(",")) {
          rules.push({ sel: sel.trim(), media, decls, order: order++ });
        }
      }
      k = close + 1;
    }
  };

  collect(src, null);
  return rules;
}

/// What a browser would compute for an element carrying `classes`, in a
/// window `width` wide. Only the selectors that are a bare compound of
/// classes are considered — `.nav`, `.nav-row`, `.chip.current` — which
/// is every rule these shapes are made of, and the ones with
/// combinators or pseudo-elements are somebody else's assertion.
function computed(rules, classes, width) {
  const hits = [];
  for (const rule of rules) {
    if (rule.media !== null && width > rule.media) continue;
    if (!/^(\.[A-Za-z0-9_-]+)+$/.test(rule.sel)) continue;
    const need = rule.sel.slice(1).split(".");
    if (need.every((c) => classes.includes(c))) hits.push({ rule, spec: need.length });
  }
  hits.sort((a, b) => a.spec - b.spec || a.rule.order - b.rule.order);
  const out = {};
  for (const { rule } of hits) Object.assign(out, rule.decls);
  return out;
}

/// The `:root` block's custom properties as numbers, resolved the way a
/// browser resolves them — `var()` followed, `calc()` evaluated,
/// `max()` taken, and `env()` standing down to its fallback, which is
/// what a device with no inset reports and what node has.
///
/// It exists because the reserve is arithmetic and the failure was
/// arithmetic: a substring check sees `padding-bottom:
/// var(--chrome-reserve)` and is satisfied by a sum that does not cover
/// the band. Nothing here reads a literal — every number is the
/// library's own, so a metric that moves moves both sides at once.
function rootLengths(rules) {
  const decls = {};
  for (const rule of rules) if (rule.sel === ":root" && rule.media === null) Object.assign(decls, rule.decls);

  const open = new Set();
  const value = (name) => {
    if (!(name in decls)) throw new Error(`the sheet has no ${name}`);
    if (open.has(name)) throw new Error(`${name} resolves through itself`);
    open.add(name);
    try {
      return read(decls[name]);
    } finally {
      open.delete(name);
    }
  };

  const read = (src) => {
    let i = 0;
    const ws = () => {
      while (i < src.length && /\s/.test(src[i])) i++;
    };
    const closing = (from) => {
      let depth = 0;
      for (let k = from; k < src.length; k++) {
        if (src[k] === "(") depth++;
        else if (src[k] === ")" && --depth === 0) return k;
      }
      throw new Error(`unclosed group in ${src}`);
    };
    const args = () => {
      const out = [];
      i++;
      for (;;) {
        out.push(expr());
        ws();
        if (src[i] === ",") {
          i++;
          continue;
        }
        if (src[i] === ")") {
          i++;
          return out;
        }
        throw new Error(`unreadable argument list in ${src}`);
      }
    };
    const atom = () => {
      ws();
      if (src[i] === "(") {
        i++;
        const v = expr();
        ws();
        i++;
        return v;
      }
      const fn = /^([a-zA-Z-]+)\(/.exec(src.slice(i));
      if (fn) {
        i += fn[0].length - 1;
        const name = fn[1];
        if (name === "var") {
          const close = closing(i);
          const ref = src.slice(i + 1, close).trim();
          i = close + 1;
          return value(ref);
        }
        if (name === "env") {
          // The inset a device reports is not a length this file can
          // know, and the fallback is what the sheet wrote for exactly
          // that reason.
          const close = closing(i);
          const comma = src.indexOf(",", i);
          const fallback = comma > 0 && comma < close ? src.slice(comma + 1, close) : "0";
          i = close + 1;
          return read(fallback);
        }
        const a = args();
        if (name === "calc") return a[0];
        if (name === "max") return Math.max(...a);
        if (name === "min") return Math.min(...a);
        throw new Error(`the sheet grew a function this check cannot read: ${name}()`);
      }
      const num = /^-?\d+(?:\.\d+)?(?:px)?/.exec(src.slice(i));
      if (!num) throw new Error(`unreadable length at ${i} in ${src}`);
      i += num[0].length;
      return Number.parseFloat(num[0]);
    };
    const term = () => {
      let v = atom();
      for (;;) {
        ws();
        const op = src[i];
        if (op !== "*" && op !== "/") return v;
        i++;
        const rhs = atom();
        v = op === "*" ? v * rhs : v / rhs;
      }
    };
    const expr = () => {
      let v = term();
      for (;;) {
        ws();
        const op = src[i];
        if (op !== "+" && op !== "-") return v;
        i++;
        const rhs = term();
        v = op === "+" ? v + rhs : v - rhs;
      }
    };
    const v = expr();
    ws();
    if (i !== src.length) throw new Error(`trailing bytes in ${src}`);
    return v;
  };

  return value;
}

/// The bottom chrome's clear space at a width, on the one box that ever
/// carries it: the screen. There was a second — `body`, keyed on a class
/// written from `Document.body_end`'s bytes — for as long as a footer
/// could stand outside the screen; a footer is content now, so the
/// reserve is back to one rule and this reads it.
///
/// `computed` above cannot read these — every one of them is a
/// descendant selector qualified on `:root` — and the shape is stated
/// here rather than matched loosely, so a rule the sheet stops writing
/// is an `undefined` and not a silent pass.
function reserveAt(rules, { nav, width }) {
  const shape = /^:root(:has\(\.nav\))? \.nokre\.has-chrome$/;
  const hits = [];
  for (const rule of rules) {
    if (rule.media !== null && width > rule.media) continue;
    const m = shape.exec(rule.sel);
    if (!m) continue;
    if (m[1] && !nav) continue;
    hits.push({ spec: m[1] ? 1 : 0, order: rule.order, value: rule.decls["padding-bottom"] });
  }
  hits.sort((a, b) => a.spec - b.spec || a.order - b.order);
  let screen;
  for (const hit of hits) screen = hit.value;
  return screen;
}

/// Which shape the *sheet* draws at this width, in the two words the
/// rest of the library uses for them.
function sheetShape(rules, width) {
  const nav = computed(rules, ["nav"], width);
  const row = computed(rules, ["nav-row"], width);
  if (nav.position === "fixed") {
    assert.equal(row["flex-wrap"], "nowrap", "the band's row is one line by construction");
    return "band";
  }
  assert.notEqual(nav.position, "fixed");
  assert.equal(row["flex-wrap"], "wrap", "the header wraps, which is why it cannot fail to fit");
  return "header";
}

/// Which shape the *tree* is in, read off the markup the driver just
/// wrote into the page — a row of links, or the one combobox that
/// stands in for all of them.
function treeShape(into) {
  const bar = into.querySelector("nav");
  assert.ok(bar, "the page has no nav at all");
  const chip = bar.querySelectorAll("[role=\"combobox\"]");
  const links = bar.querySelectorAll("a");
  if (chip.length) {
    assert.equal(chip.length, 1);
    assert.equal(links.length, 0, "a collapsed roster is one control, not a control beside a row");
    return "chip";
  }
  return `row of ${links.length}`;
}

/// The finding this section exists for: at a width where the sheet
/// wraps the header, core was still measuring the roster against one
/// line and swapping the row for a chip — so a 900px browser window got
/// a single plated capsule where a site's sections should be.
///
/// The sweep is the assertion rather than one width, because the bug
/// lived in a band of widths between the breakpoint and wherever the
/// row happened to fit again, and any single number could have missed
/// it. Every width above the pane cap must be a row, and the same roster
/// below the cap must be the chip — which is the other half of the
/// claim, that nothing here turned collapse off.
async function navShapeFollowsTheWindow() {
  const css = parseCss(await fs.readFile(path.join(site, "style.css"), "utf8"));
  const { into, app } = await page({}, { route: "home", locale: "" }, 900);
  app.wideNav();

  for (const width of [561, 600, 700, 900, 1050, 1400]) {
    resize(into, width);
    assert.equal(sheetShape(css, width), "header", `the sheet at ${width}`);
    assert.equal(treeShape(into), "row of 6", `the tree at ${width}`);
  }

  for (const width of [560, 480, 375, 320]) {
    resize(into, width);
    assert.equal(sheetShape(css, width), "band", `the sheet at ${width}`);
    assert.equal(treeShape(into), "chip", `the tree at ${width}`);
  }

  // And back, because the failure a reader hits is a drag rather than a
  // load: the row has to come back, not merely have been there once.
  resize(into, 900);
  assert.equal(treeShape(into), "row of 6");
  done("the nav — a header wraps, so no width above the cap collapses it");
}

/// The band's own half. Every roster is in it, and the row that will
/// not fit inside it scrolls rather than hanging past both screen
/// edges — which is the answer that needs nothing running, and so the
/// answer a published file can rely on.
///
/// Reachability is asserted from both sides, because neither is enough.
/// The sheet has to make the row a scroll container: a nowrap row in a
/// fixed layer with no overflow rule is the *clipping* this replaced,
/// and the ends of it are past the screen with no gesture that reaches
/// them. And the markup has to hold every destination as a real link
/// with an address of its own, so the reader who never scrolls — a
/// crawler, a screen reader walking the landmark, a keyboard tabbing
/// through it, all three of which the browser scrolls into view — gets
/// all six whatever the pointer finds.
async function navBandCarriesEveryDestination() {
  const css = parseCss(await fs.readFile(path.join(site, "style.css"), "utf8"));
  const { into, app } = await page({}, { route: "home", locale: "" }, 375);
  app.wideNav();
  resize(into, 375);

  assert.equal(sheetShape(css, 375), "band");
  const row = computed(css, ["nav-row"], 375);
  assert.equal(row["overflow-x"], "auto", "the band's row clips instead of scrolling");
  assert.equal(row["overscroll-behavior-inline"], "contain");
  assert.equal(row["scrollbar-width"], "none", "a scrollbar in the band is height the reserve cannot see");
  // Centring is the layer's, not the row's: a centred scroll container
  // overflows both ends and the leading one cannot be scrolled to.
  assert.equal(row["justify-content"], undefined);
  assert.equal(computed(css, ["nav"], 375)["justify-content"], "center");

  // The band applies to a nav with nothing else on it, which is the
  // whole of the second finding: for one release the rule read
  // `.nav:not(.no-boot)` and a published page never got a bottom bar.
  assert.equal(into.querySelector("nav").getAttribute("class"), "nav");

  // Now the file a reader of that band would actually have opened. A
  // generator runs wide — the roster has to make a row in the window it
  // was measured in, or the page it publishes is a chip, and a chip is
  // a control nothing on the page can work (`PageNeedsBoot`, the
  // scenario below). The file is then read at every width, and 375 is
  // one of them: this is the case the band exists for and the one a
  // modifier on the nav used to take it away from.
  resize(into, 1200);
  app.switchTo("second");
  const file = app.documentUnbooted();
  const served = makeBrowser({ site });
  served.openPage(file);
  const bar = document.body.querySelector("nav");
  assert.equal(bar.getAttribute("class"), "nav", "a published page is held out of the band again");
  const hrefs = bar.querySelectorAll("a").map((a) => a.getAttribute("href"));
  assert.equal(hrefs.length, 6, "the file lost destinations the app had");
  assert.equal(new Set(hrefs).size, 6, "two destinations share an address");
  for (const href of hrefs) assert.ok(href && href !== "#", `a destination with nowhere to go: ${href}`);
  done("the nav — every page takes the band, and the band reaches every destination");
}

/// Whether a page needs a runtime is read off the page. It was a
/// driver's declaration for one release, and a declaration is a thing
/// to forget in the direction nobody notices: a file that renders,
/// shows its controls, and does nothing when they are pressed.
async function bootIsDerivedFromWhatIsOnThePage() {
  const { app } = await page({}, { route: "home", locale: "" });

  // The home screen holds a button and a segmented control, and both
  // are answered by the app. Publishing it with no module is refused
  // before a byte.
  assert.throws(
    () => app.documentUnbooted(),
    /PageNeedsBoot/,
    "a page of dead controls was published instead of refused",
  );

  // The second screen is its title, its roster and nothing else — the
  // page a static site mostly is. A link is answered by the browser, so
  // nothing on it needs a runtime and it publishes whole.
  app.switchTo("second");
  const file = app.documentUnbooted();
  assert.ok(file.includes("<nav class=\"nav\""), "the published page lost its roster");
  assert.ok(!file.includes("<script"), "a page that needs nothing was given a module anyway");

  // And the same screen with a module on it is the other direction,
  // which is never refused: a driver may publish a runtime for a need
  // no tree can show.
  assert.ok(app.document().includes("app.wasm"));
  done("the nav — a page's need for a runtime is derived, and only the absent one is refused");
}

/// The derivation's own input, which was the coarser of the two facts
/// on the page for as long as it existed. `Element.needsRuntime` asked
/// the *role*, where a tile is a control unconditionally — and a tile is
/// not one thing: it is the row-shaped form of `link` and `button`, and
/// the serializer beside it had always written an anchor when it
/// navigates and a button when it acts.
///
/// So a hub of navigating rows — a site's home page, a section index —
/// derived a need it did not have and published a module its readers
/// never ran, with no way to decline it, because a derivation is a
/// floor. Both halves are asserted here because either alone is the
/// wrong fix: turning `.tile` off outright would publish a page of dead
/// rows, which is the failure the derivation exists to close.
async function tilesAreAnchorsOrButtons() {
  const { app } = await page({}, { route: "home", locale: "" }, 1200);

  // Three rows, every one of them a route: three anchors, no button,
  // and nothing on the page for a runtime to answer.
  app.switchTo("hub");
  const hub = app.documentUnbooted();
  assert.equal((hub.match(/<a class="tile"/g) ?? []).length, 3, "a navigating row came out as something else");
  assert.ok(!hub.includes("<button type=\"button\" class=\"tile\""));
  assert.ok(!hub.includes("<script"), "a page of navigating rows was given a module anyway");
  // Every one of them reaches somewhere, which is what makes the page
  // whole without a runtime rather than merely quiet.
  const served = makeBrowser({ site });
  served.openPage(hub);
  const hrefs = document.body.querySelectorAll("a").map((a) => a.getAttribute("href"));
  for (const name of ["second", "explore", "collections"]) {
    assert.ok(hrefs.some((href) => href.includes(name)), `the hub lost ${name}`);
  }

  // The same group with one row that acts. One button in row clothing
  // is the whole difference, and it is refused before a byte.
  app.switchTo("actions");
  assert.throws(
    () => app.documentUnbooted(),
    /PageNeedsBoot/,
    "a row that answers a press was published with nothing to answer it",
  );
  const booted = app.document();
  assert.ok(booted.includes("<button type=\"button\" class=\"tile\""), "the acting row is not a button");
  assert.ok(booted.includes("<a class=\"tile\""), "the navigating row beside it stopped being an anchor");
  done("the tile — a row that navigates is an anchor, and only the row that acts needs an app");
}

/// A footer is content, and this is the whole of what that buys.
///
/// It was a byte seam for three revisions — `Document.body_end`, spliced
/// after `</main>` — and every consumer that ever used it put a footer
/// through: a stack of links and a line of text, which is content
/// wearing markup's clothes. The library paid for the disguise twice. A
/// footer outside `.nokre` rendered in the browser's default serif,
/// because bytes outside the screen are styled by nobody. Then the
/// bottom chrome's clear space, which is `padding-bottom` on the screen,
/// reserved the band *above* the footer instead of below it: 73px of
/// copyright and links under a fixed band at 375px, on every page, in
/// every locale.
///
/// So the seam is gone and a footer is a `stack` of `link`s the page
/// builder appends last. Four claims, and the point is that no rule in
/// the library grants any of them — they are what being in the tree
/// already means: the sheet styles it, the reserve clears it, the routes
/// resolve through `Refs`, and the document ends at `</main>`.
async function theFooterIsContent() {
  const style = await fs.readFile(path.join(site, "style.css"), "utf8");
  const css = parseCss(style);
  const px = rootLengths(css);

  // Nothing left anywhere asks whether the document has bytes below the
  // screen.
  assert.ok(!style.includes("has-seam"), "the sheet still branches on a seam that cannot exist");

  // What a reader on a phone is actually looking at, from the sheet's
  // own numbers: the bar's top pad, one slot, and the clear space below
  // it with the OS band inside `--bar-bottom`. A rule naming
  // `--chrome-reserve` says nothing about how tall the thing it clears
  // is, which is how a check on the sum once passed while a reader saw a
  // covered footer.
  const band = px("--nav-bar-pad") + px("--nav-slot") + px("--bar-bottom") + px("--safe-b");
  assert.ok(band > 0, "the band has no height, so this proves nothing");
  assert.equal(
    px("--chrome-reserve") - band,
    px("--nav-content-gap"),
    "the reserve is no longer the band plus the gap nothing may rest inside",
  );

  const { app } = await page({}, { route: "home", locale: "" }, 1200);
  app.wideNav();
  app.switchTo("footed");

  // The file a site publishes: a hub of rows, then its footer. Nothing
  // on it needs a runtime, so it goes out with no module — a footer of
  // links costs a page nothing it was not already paying.
  const file = app.documentUnbooted();
  const served = makeBrowser({ site });
  served.openPage(file);

  // The document ends at the screen. Three elements in the body and no
  // class on it: there is no longer anything that could put a fourth
  // one there, and nothing infers a shape from a string's length.
  assert.deepEqual(
    document.body.childNodes.filter((n) => n.nodeType === 1).map((n) => n.nodeName),
    ["A", "DIV", "MAIN"],
    "something stands outside the screen in a page nokre wrote whole",
  );
  assert.equal(document.body.getAttribute("class"), null, "the body still claims something below the screen");

  // The footer is the last thing *inside* the screen, which is the box
  // the reserve is on.
  const screen = document.body.querySelector("main");
  assert.ok(screen.getAttribute("class").split(" ").includes("has-chrome"));
  const stack = screen.querySelectorAll(".stack").at(-1);
  assert.ok(stack, "the footer is not in the tree");
  assert.equal(screen.childNodes.filter((n) => n.nodeType === 1).at(-1), stack, "the footer is not last");

  // Styling: every anchor in it carries nokre's own classes, so every
  // rule in the sheet that reaches a link reaches these. A seam's
  // anchor carried none and kept the UA's underline and colour.
  const links = stack.querySelectorAll("a");
  assert.equal(links.length, 6, "the footer lost links");
  for (const a of links) {
    assert.equal(a.getAttribute("class"), "link block", "a footer link is not one of nokre's");
  }

  // Resolution: the two internal destinations went through `Refs` like
  // every other route on the page, and the external one took the
  // new-tab posture every external anchor here takes.
  const hrefs = links.map((a) => a.getAttribute("href"));
  assert.deepEqual(hrefs.slice(0, 2), ["#terms", "#privacy"], "a footer route did not resolve");
  assert.equal(links[2].getAttribute("rel"), "noopener noreferrer");

  // The audit reads it, which is the claim bytes could never answer:
  // every node in there is a node the tree has, with a role and a
  // reachable name. A footer in a seam had none of that, and nothing
  // anywhere said so.
  for (const a of links) {
    assert.ok(a.getAttribute("data-n"), "a footer link is not a node the tree knows");
    assert.ok(a.textContent.trim().length > 0, "a footer link has no accessible name");
  }

  // The language row, which is what a footer on a multi-locale site has
  // on it and the one thing the seam's deletion actually cost (WCAG
  // 3.1.2, Language of Parts). Each anchor names its language *in* that
  // language, and each says which language that is — the tag arrives on
  // the anchor itself, so a screen reader switches voice on the one
  // word a reader who cannot read this page is looking for.
  const chooser = links.slice(3);
  assert.deepEqual(
    chooser.map((a) => [a.getAttribute("lang"), a.textContent]),
    [
      ["en", "English"],
      ["fa", "فارسی"],
      ["tr", "Türkçe"],
    ],
    "the language row does not say which language each of its words is in",
  );

  // The document's own language is still the document's, written from
  // the app and not from any of these — which is what makes the three
  // above *parts*. Two writers of one fact was the failure the seam's
  // deletion was about; this is the same fact with one writer each.
  assert.equal(document.documentElement.getAttribute("lang"), "en");

  // And the residue: a link that is not part of the set states nothing.
  // `lang=""` is a claim in HTML — "unknown language" — so the honest
  // way to say "the page's own" is to say nothing at all.
  for (const a of links.slice(0, 3)) {
    assert.equal(a.getAttribute("lang"), null, "a footer link claims a language it was never given");
  }

  // And the reserve. At a phone's width the bar is a fixed band over the
  // page, and the clear space for it is on the box the footer is inside
  // — which it now is, without the library being told anything.
  assert.equal(
    reserveAt(css, { nav: true, width: 375 }),
    "var(--chrome-reserve)",
    "the screen the footer is in reserves nothing for the band",
  );
  assert.ok(px("--chrome-reserve") >= band, "the reserve is shorter than the band is tall");

  // Above the cap the bar is a header in flow: it took its space where
  // it stands, and a reserve there is an inch of nothing.
  assert.equal(reserveAt(css, { nav: true, width: 900 }), "var(--pad)");
  done("the footer — content in the tree is styled, cleared, resolved and audited, with no seam");
}

/// The keyboard's half of "a link is the browser's", which was missing
/// for as long as the addressing existed.
///
/// Under `addressing: "documents"` the click handler hands any `a[href]`
/// to the browser and the keydown handler did not: it cancelled the
/// keystroke and passed Enter to core, which refuses a destination the
/// route table cannot spell. The footer's language row is exactly that
/// destination on every real site — a locale's copy of a page is not a
/// route, because a reference has no slot a locale could ride in — so
/// the chooser switched language under a pointer and did nothing at all
/// under a keyboard or a switch. That is WCAG 2.1.1 Keyboard, level A,
/// and it shipped on six pages of the first site to adopt this.
///
/// It is a scenario here rather than a unit test because there is no
/// unit under it. The defect is two handlers in one shipped file
/// disagreeing about the same question, and the only place either of
/// them runs is a booted page being driven by real events — which is
/// this gate's whole reason for existing (docs/testing.md).
async function documentsHandLinksToTheKeyboard() {
  const { browser, into } = await page({}, { route: "footed", locale: "", addressing: "documents" });
  const key = (name) => Object.assign(new PageEvent("keydown"), { key: name });
  // Tab is the browser's on this edition, and where it landed is what
  // crosses back into wasm — so a keystroke without this is a keystroke
  // from nobody, and core would answer for whatever else held the tree's
  // focus. The whole scenario is about the reader who arrived by Tab.
  const tabTo = (el) => el.dispatchEvent(new PageEvent("focusin"));

  const chooser = into.querySelectorAll("a").find((a) => a.getAttribute("lang") === "fa");
  assert.ok(chooser, "the page carries no language row to press");
  tabTo(chooser);
  assert.equal(
    chooser.getAttribute("href"),
    "#lang:fa",
    "the chooser's destination is a route after all, so this proves nothing",
  );

  // `dispatchEvent` answers "nobody cancelled it", which here is the
  // whole assertion: an uncancelled keydown on an anchor is the browser
  // following the link, and it is the only way this destination is ever
  // reached. Both of these were false before the branch existed.
  assert.equal(chooser.dispatchEvent(key("Enter")), true, "Enter over a link is still cancelled");
  assert.equal(
    chooser.dispatchEvent(new PageEvent("click")),
    true,
    "the press stopped being the browser's",
  );
  // And the driver did not re-address the page behind the browser's
  // back: the href on the anchor is the whole navigation.
  assert.deepEqual(browser.location.assigned, [], "the driver navigated instead of the anchor");

  // Space is not an anchor's key in any browser, so it stays core's. The
  // carve-out is about a destination core cannot reach, not about the
  // keyboard: returning here too would take the activation away from
  // every link core *can* honor and hand the browser a key it does
  // nothing with.
  assert.equal(chooser.dispatchEvent(key(" ")), false, "Space over a link stopped crossing into core");

  // And it is scoped to this addressing. The same screen as an app shell
  // — where a route is a redraw and the router owns the address bar —
  // still cancels Enter and still navigates, because there the
  // destination is core's to reach.
  const shell = await page({}, { route: "footed", locale: "" });
  const terms = shell.into.querySelectorAll("a").find((a) => a.getAttribute("href") === "#terms");
  assert.ok(terms, "the footer lost the one link the router can spell");
  tabTo(terms);
  assert.equal(terms.dispatchEvent(key("Enter")), false, "an app shell stopped taking Enter into core");
  assert.equal(shell.browser.location.hash, "#terms", "Enter never reached the router");

  done("the document — a link takes Enter from the browser, and Space from core");
}

// ---- the run -----------------------------------------------------

const scenarios = [
  siteManifest,
  serviceWorkerRooted,
  deepLink,
  deepLinkQuiet,
  oauthPopupReports,
  oauthPopupIgnoresOrdinaryPage,
  oauthFlow,
  oauthRefusesForgeries,
  oauthEndings,
  oauthRedirectTooLong,
  storeSeed,
  storeMirror,
  storeSurvivesReload,
  storeWithoutStorage,
  localeFollowsTheDevice,
  localeOfThePageWins,
  localePinnedPageIsNeverRedirected,
  localeEmptyPinIsTheTemplate,
  localeUnbundledPinResolvesLikeTheDevice,
  localeChangeAfterBoot,
  scratchIsClamped,
  documentsPage,
  theBootIsAFileThePageNames,
  navShapeFollowsTheWindow,
  navBandCarriesEveryDestination,
  bootIsDerivedFromWhatIsOnThePage,
  tilesAreAnchorsOrButtons,
  theFooterIsContent,
  documentsHandLinksToTheKeyboard,
];

for (const scenario of scenarios) {
  try {
    await scenario();
  } catch (err) {
    console.error(`web services: ${scenario.name} failed`);
    console.error(err);
    process.exit(1);
  }
}

// stdout stays empty and the transcript is one stream, the dev store's
// arrangement: asserting this line asserts every scenario above it ran.
console.error("web services: deep_link, oauth, secure_store, locale — all ok");
