// The web edition's own gate: the three service legs that exist only in
// a browser, executed — `node tests/web_services.mjs <site>`, which is
// what `zig build test` runs (build.zig's addWebServicesCheck).
//
// The three are deep_link, oauth and secure_store. Each is half Zig and
// half JavaScript, the halves talk through the wasm boundary, and until
// this file nothing ran either half: under `zig test` a service is its
// mock, `check-targets` compiles the web legs into objects it never
// links, and the parse step reads the JavaScript without executing a
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

import { makeBrowser, Storage } from "./web_browser.mjs";

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

async function page(env = {}) {
  const browser = makeBrowser({ site, ...env });
  const { mount } = await import(live + `?load=${++loads}`);
  const into = browser.mountPoint();
  const nk = await mount({ wasm: "app.wasm", into });
  return { browser, into, nk, app: nk && probes(nk) };
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
console.error("web services: deep_link, oauth, secure_store — all ok");
