// The shell hooks a linked service calls out through, shared by the two
// instances the live driver runs: the app on the main thread, and a
// compute actor in a Worker (live-worker.js).
//
// They are the same free functions `src/platform/shell.h` names on
// the native side. A service has no more to do with markup than it has
// with a rasterizer, so what differs here is only which *instance*
// answers — the app's, or the compute actor's.
//
// One rule holds throughout: a pointer handed across is borrowed for
// the call and nothing more. Anything outliving it is copied here —
// `slice`, never `subarray` — because fetch and postMessage are async
// and a subarray drags the whole heap's ArrayBuffer with it.

/// Everything the module can import, as no-ops. An instance overrides
/// the ones it is the right answer for; the rest still have to exist,
/// because a missing import is an instantiation failure and both
/// instances share one module.
export function silentHooks() {
  return {
    nokre_shell_request_frame: () => {},
    nokre_shell_write_clipboard: () => {},
    nokre_open_url_open: () => {},
    nokre_shell_write_route: () => {},
    nokre_worker_js_spawn: () => {},
    nokre_worker_js_send: () => {},
    nokre_worker_js_drop: () => {},
    nokre_worker_js_reply: () => {},
    nokre_worker_js_pending: () => 0,
    nokre_worker_js_close: () => {},
    nokre_http_js_send: () => {},
    nokre_http_js_cancel: () => {},
    nokre_oauth_js_open: () => {},
    nokre_oauth_js_close: () => {},
    // Overridden by *both* instances (a compute actor runs the app's
    // code, so it may mint a PKCE verifier too, and a verifier of
    // zeros is not a verifier): the real hook needs the instance's
    // memory, which only the instance has. This no-op exists because a
    // missing import is an instantiation failure.
    nokre_oauth_js_random: () => {},
    nokre_ss_mirror_set: () => {},
    nokre_ss_mirror_del: () => {},
    // A compute instance lays nothing out, so it never asks.
    nokre_dom_measure: () => 0,
  };
}

// ---- the oauth popup's landing page (docs/internals/oauth.md) ----
// The web redirect is the app's own page: in a browser the origin *is*
// the registration, so the provider sends the user back here — in the
// popup. That popup loads this same module, and the first thing
// `mount` does is ask what it is: a popup carrying an auth response
// hands its URL to the opener and closes, and the consumer deploys no
// second HTML file and registers no second redirect URI.
//
// The test is deliberately narrow: an opener AND an auth-shaped
// parameter in the query or the fragment. A popup opened for anything
// else, or a normal tab with a stray `?code=`, boots the app as usual.
const OAUTH_PARAMS = /[?#].*\b(code|error|id_token)=/;

export function reportAuthToOpener() {
  if (!window.opener || window.opener === window) return false;
  if (!OAUTH_PARAMS.test(location.href)) return false;
  try {
    // Same-origin by construction — the redirect is this very page —
    // so the target origin is exact rather than "*": a wildcard would
    // post an authorization code to whatever happened to open us.
    window.opener.postMessage({ t: "nokre.oauth", href: location.href }, location.origin);
  } catch {}
  window.close();
  return true;
}

// ---- secure_store's browser shadow (docs/internals/secure_store.md) ----
// The store is a static table inside the wasm module; sessionStorage
// is only its shadow, and both directions of the shadow live in this
// file so the key schema has one home. The prefix is fixed because
// this side is namespace-agnostic by necessity — pkg_id sits inside a
// wasm that has not booted when the snapshot is taken; wasm filters to
// its own entries. sessionStorage holds UTF-16 strings and secrets are
// bytes; base64 is the lossless bridge both ways. atob/btoa speak one
// byte per code unit, and values cap at 2048 bytes, so char-at-a-time
// costs nothing.
const SS_PREFIX = "nokre.ss.";

function b64encode(raw) {
  let s = "";
  for (let i = 0; i < raw.length; i++) s += String.fromCharCode(raw[i]);
  return btoa(s);
}

function b64decode(s) {
  const bin = atob(s);
  const raw = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) raw[i] = bin.charCodeAt(i);
  return raw;
}

/// The boot snapshot, poured through the seed exports strictly before
/// `nokre_dom_boot` so a boot-time get inside the first build answers
/// synchronously — no handshake (services/secure_store/web.zig owns
/// the exports; live.js calls this pre-boot, the locale's ordering).
/// Absent exports are an unlinked build; blocked storage is an empty
/// snapshot (and a dead mirror later): a pure session cache where
/// every call still behaves identically.
export function seedSecureStore(nk, memory) {
  if (!nk.nokre_ss_seed) return;
  const encoder = new TextEncoder();
  try {
    for (let i = 0; i < sessionStorage.length; i++) {
      const key = sessionStorage.key(i);
      if (!key || !key.startsWith(SS_PREFIX)) continue;
      // sessionStorage is same-origin-writable: an entry that does not
      // decode is foreign, dropped at the door — the same refusal the
      // wasm side applies to out-of-contract keys.
      let value;
      try {
        value = b64decode(sessionStorage.getItem(key));
      } catch {
        continue;
      }
      const kb = encoder.encode(key.slice(SS_PREFIX.length));
      // A null scratch means [key][value] exceeds the in-contract
      // ferry — an entry that large cannot be this app's.
      const ptr = nk.nokre_ss_seed_scratch(kb.length + value.length);
      if (!ptr) continue;
      memory().set(kb, ptr);
      memory().set(value, ptr + kb.length);
      nk.nokre_ss_seed(kb.length, value.length);
    }
  } catch {}
}

/// The app instance's half: it spawns compute workers, runs fetch,
/// owns the oauth popup, and mirrors the secure store's table out to
/// sessionStorage.
///
/// `nk()` returns the instance's exports — a function because the
/// hooks are built before the module they call back into exists.
/// `memory()` is a function for a sharper reason: a wasm call may grow
/// the heap, and growing it *detaches* every view taken before it. Any
/// view held across a call into the module is a live grenade, so every
/// one here is taken after the last call and dropped before the next.
/// `onWork` is called after anything lands asynchronously, so the
/// driver can paint; core invalidates on its own, and this is only the
/// signal that it may have. `onMetrics` is the same courtesy for a
/// narrower event: the answers this shell has been giving core about
/// text width just changed, and every decision made from them is due
/// again.
export function appHooks({ nk, memory, workerUrl, wasmUrl, onWork, onMetrics }) {
  const utf8 = new TextDecoder();
  const bytes = new TextEncoder();
  const compute = new Map(); // slot -> Worker
  const fetches = new Map(); // "index:gen" -> AbortController

  function deliverReply(slot, frame) {
    const ptr = nk().nokre_worker_scratch(frame.length);
    if (!ptr) return;
    memory().set(frame, ptr);
    nk().nokre_worker_deliver(slot, ptr, frame.length);
    onWork();
  }

  function died(slot) {
    if (!compute.has(slot)) return;
    compute.get(slot).terminate();
    compute.delete(slot);
    nk().nokre_worker_died(slot);
    onWork();
  }

  function httpFail(index, gen, name) {
    const nb = bytes.encode(name);
    const ptr = nk().nokre_http_scratch(nb.length);
    if (!ptr) return;
    memory().set(nb, ptr);
    nk().nokre_http_fail(index, gen, nb.length);
    onWork();
  }

  // Text measurement, which is a shell's job everywhere: natively it is
  // HarfBuzz through the shim, here it is the engine that will draw the
  // run. Widths are ceiled to whole pixels the way the shim ceils them,
  // so layout never underestimates and a wrap point stays stable.
  //
  // Layout asks this thousands of times per frame — once per candidate
  // wrap — so the answers are cached by face, size and string: for one
  // set of loaded faces, the same question has the same answer.
  //
  // Which is the whole catch. The faces are bundled and fixed, but they
  // still arrive over the network, and a ruler asked before one lands
  // answers in whatever the browser fell back to — narrower stems, and
  // a tofu box where a private-use icon codepoint should be. The text
  // itself repaints when the face arrives; a cached width does not, so
  // core keeps every decision it made from the wrong number: where
  // prose wrapped, whether a row of actions folded, whether a track had
  // to bleed. The nav's row is where it showed worst — it stayed a row
  // some thirty pixels past the width it actually fitted in, so the end
  // destinations hung over both screen edges before `navCollapses`
  // agreed the roster no longer fitted.
  //
  // So the cache lives exactly as long as the font set it was measured
  // against. `loadingdone` is the browser saying a batch just became
  // available, which is precisely when these answers went stale — and
  // it fires however the faces arrive, including the ordinary case
  // where nothing requests one until a first frame paints with it.
  // ---- oauth: the popup, and the two ways it can end ----
  // A popup rather than a top-level redirect: a redirect would tear
  // down the wasm instance mid-flow, and the app would come back with
  // no memory of having started one — every piece of PKCE state gone.
  // The popup keeps the app running and the verifier in hand.

  let authPopup = null;
  let authPoll = 0;

  function closeAuthPopup() {
    if (authPoll) {
      clearInterval(authPoll);
      authPoll = 0;
    }
    if (authPopup && !authPopup.closed) authPopup.close();
    authPopup = null;
  }

  // The flow's one result: the landing URL on status 0, a failure name
  // on status 2, empty on a cancel. Scratch then receive — the http
  // transport's three beats; the receive export pumps the delivery
  // queue itself, so the app's handler has run by the time onWork
  // paints (services/oauth/web.zig).
  function endAuth(status, text) {
    if (authPoll) {
      clearInterval(authPoll);
      authPoll = 0;
    }
    authPopup = null;
    const b = bytes.encode(text);
    const ptr = nk().nokre_oauth_scratch(b.length);
    if (!ptr && b.length) return; // longer than the landing buffer
    if (b.length) memory().set(b, ptr);
    nk().nokre_oauth_receive(status, b.length);
    onWork();
  }

  addEventListener("message", (e) => {
    // Same-origin only: the redirect lands on the app's own page, so
    // anything from elsewhere is not our popup — and the message
    // carries an authorization code.
    if (e.origin !== location.origin) return;
    if (!e.data || e.data.t !== "nokre.oauth") return;
    if (!authPopup) return;
    endAuth(0, e.data.href);
  });

  const FAMILIES = ["mono", "prose", "icons", "brand"];
  const ruler = document.createElement("canvas").getContext("2d");
  const widths = new Map();

  document.fonts?.addEventListener("loadingdone", () => {
    widths.clear();
    onMetrics?.();
  });

  function measure(family, bold, italic, size, ptr, len) {
    const text = utf8.decode(memory().subarray(ptr, ptr + len));
    const font = `${italic ? "italic " : ""}${bold ? "700 " : "400 "}${size}px ${FAMILIES[family]}`;
    const key = font + "\u0000" + text;
    let w = widths.get(key);
    if (w === undefined) {
      ruler.font = font;
      w = Math.ceil(ruler.measureText(text).width);
      widths.set(key, w);
    }
    return w;
  }

  return {
    ...silentHooks(),
    nokre_dom_measure: measure,

    nokre_shell_write_clipboard: (ptr, len) => {
      const text = utf8.decode(memory().subarray(ptr, ptr + len));
      navigator.clipboard?.writeText(text).catch(() => {});
    },

    // ---- open_url (docs/services.md) ----
    // A new tab, never this one: replacing the page would tear down the
    // wasm instance the way an oauth top-level redirect would, and the
    // reader was mid-app. "noopener" severs the handle the new page
    // would otherwise hold on this window — the scheme allowlist already
    // ran in Zig, and the serialized markup's external anchors carry the
    // same posture (rel="noopener noreferrer"). This import is the
    // keyboard path; a pointer click on an external anchor never gets
    // here, because live.js leaves real anchors to the browser.
    nokre_open_url_open: (ptr, len) => {
      const url = utf8.decode(memory().subarray(ptr, ptr + len));
      window.open(url, "_blank", "noopener");
    },

    // ---- workers (docs/internals/workers.md) ----

    nokre_worker_js_spawn: (index, slot) => {
      const w = new Worker(workerUrl, { type: "module" });
      compute.set(slot, w);
      w.onmessage = (e) => {
        if (e.data.t === "reply") deliverReply(slot, new Uint8Array(e.data.buf));
        else if (e.data.t === "died") died(slot);
      };
      w.onerror = () => died(slot);
      w.postMessage({ t: "init", wasm: wasmUrl, index });
    },
    nokre_worker_js_send: (slot, ptr, len) => {
      const w = compute.get(slot);
      if (!w) return;
      const copy = memory().slice(ptr, ptr + len); // out of wasm memory before transfer
      w.postMessage({ t: "frame", buf: copy.buffer }, [copy.buffer]);
    },
    nokre_worker_js_drop: (slot) => {
      const w = compute.get(slot);
      if (!w) return;
      compute.delete(slot);
      w.terminate(); // it closes itself; belt and braces
    },

    // ---- http (docs/internals/http.md) ----

    nokre_http_js_send: (index, gen, mPtr, mLen, uPtr, uLen, hPtr, hLen, bPtr, bLen, maxBody) => {
      const key = index + ":" + gen;
      const ctrl = new AbortController();
      fetches.set(key, ctrl);
      // The fixed transport deadline — 30 s, http.zig's
      // deadline_seconds, kept in step by hand across the language
      // gap. An expiry is an abort the transport performs itself, so
      // it lands as the abort path already lands: the fetch rejects
      // and one "FetchFailed" is delivered (the browser hides reasons
      // by design; a timeout is no exception).
      const deadline = setTimeout(() => ctrl.abort(), 30_000);

      const mem = memory();
      const init = { method: utf8.decode(mem.subarray(mPtr, mPtr + mLen)), signal: ctrl.signal };
      const url = utf8.decode(mem.subarray(uPtr, uPtr + uLen));
      const flat = utf8.decode(mem.subarray(hPtr, hPtr + hLen));
      if (flat.length) {
        const parts = flat.split("\n");
        init.headers = [];
        for (let i = 0; i + 1 < parts.length; i += 2) init.headers.push([parts[i], parts[i + 1]]);
      }
      // A copy: fetch is async and the borrow ends when this returns.
      if (bLen) init.body = mem.slice(bPtr, bPtr + bLen);

      fetch(url, init)
        .then(async (res) => {
          // The cap holds as bytes arrive, not after. Awaiting the
          // whole body would let a rogue — or never-ending — response
          // balloon the JS heap before the limit ever ran, so overflow
          // aborts the fetch itself rather than just the delivery.
          const chunks = [];
          let total = 0;
          if (res.body) {
            const reader = res.body.getReader();
            for (;;) {
              const { done, value } = await reader.read();
              if (done) break;
              total += value.length;
              if (total > maxBody) {
                ctrl.abort();
                httpFail(index, gen, "BodyTooLarge");
                return;
              }
              chunks.push(value);
            }
          }
          const body = new Uint8Array(total);
          let off = 0;
          for (const c of chunks) {
            body.set(c, off);
            off += c.length;
          }
          let headers = "";
          res.headers.forEach((value, name) => {
            headers += name + "\n" + value + "\n";
          });
          const hb = bytes.encode(headers);
          // One scratch, two spans: [headers][body], with the split
          // point handed over rather than searched for.
          const ptr = nk().nokre_http_scratch(hb.length + body.length);
          if (!ptr) return;
          memory().set(hb, ptr);
          memory().set(body, ptr + hb.length);
          nk().nokre_http_deliver(index, gen, res.status, hb.length, body.length);
          onWork();
        })
        // The browser hides fetch failure reasons by design, so one
        // fixed name is the honest and deterministic answer.
        .catch(() => httpFail(index, gen, "FetchFailed"))
        .finally(() => {
          clearTimeout(deadline);
          fetches.delete(key);
        });
    },
    nokre_http_js_cancel: (index, gen) => {
      fetches.get(index + ":" + gen)?.abort();
    },

    // ---- oauth (docs/internals/oauth.md) ----

    nokre_oauth_js_open: (ptr, len) => {
      const url = utf8.decode(memory().subarray(ptr, ptr + len));
      closeAuthPopup();
      // Named, so a second sign-in reuses the window instead of
      // stacking one behind the other; sized, because a bare
      // window.open in some browsers opens a tab, and a tab is easy
      // to lose behind the app.
      authPopup = window.open(url, "nokre-oauth", "popup=yes,width=520,height=640");
      if (!authPopup) {
        // Blocked — the one failure the user can actually fix, so it
        // gets its own name rather than a generic one. Deferred a
        // task: this import runs inside `oauth.start`, and a result
        // must never land before the handle is even held (oauth.zig's
        // failNow states the rule).
        queueMicrotask(() => endAuth(2, "PopupBlocked"));
        return;
      }
      // Closing a popup fires no event anywhere: polling `closed` is
      // the only way a browser reports "the user gave up" — the web's
      // version of Android watching for a resume. 400ms is well under
      // human patience and costs nothing at rest.
      authPoll = setInterval(() => {
        if (authPopup && authPopup.closed) endAuth(1, "");
      }, 400);
    },
    nokre_oauth_js_close: () => closeAuthPopup(),
    // A verifier without cryptographic randomness is not a verifier,
    // and freestanding wasm has no getrandom to reach — so the one
    // place nokre needs entropy routes to the browser's CSPRNG.
    nokre_oauth_js_random: (ptr, len) => {
      crypto.getRandomValues(memory().subarray(ptr, ptr + len));
    },

    // ---- secure_store's write-through mirror ----
    // The wasm table already holds the truth the app reads back; this
    // buys reload-survival and nothing else, so a throw (quota burned
    // by the host page, storage blocked) drops the write with one
    // warning — reload-survival was never in the sync contract.
    nokre_ss_mirror_set: (kPtr, kLen, vPtr, vLen) => {
      const mem = memory();
      try {
        sessionStorage.setItem(
          SS_PREFIX + utf8.decode(mem.subarray(kPtr, kPtr + kLen)),
          b64encode(mem.subarray(vPtr, vPtr + vLen)),
        );
      } catch (err) {
        console.warn("nokre: secure_store mirror dropped a write", err);
      }
    },
    // Unconditional removeItem, matching the delete's postcondition
    // ("no such entry"): the boot snapshot can then never resurrect
    // what the table dropped.
    nokre_ss_mirror_del: (kPtr, kLen) => {
      try {
        sessionStorage.removeItem(SS_PREFIX + utf8.decode(memory().subarray(kPtr, kPtr + kLen)));
      } catch {}
    },
  };
}
