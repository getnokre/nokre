// The DOM edition's live driver, browser half.
//
// It owns three things and nothing else: which element the reader
// meant, the bytes going into the document, and the address bar. Every
// question of *meaning* — what a press does, what a key does to a
// field, which subtree a route rebuilds — is answered in wasm by the
// same core every other nokre platform runs.
//
// There is no framework here and no dependency. What it does depend on
// is the shell hooks a linked service calls out through — the clipboard
// write, the compute-worker ferry, the fetch leg — and those are
// services.js, shared with the compute instance that live-worker.js
// runs.
//
//   import { mount } from "./live.js";
//   await mount({ wasm: "/app.wasm", into: document.body });
//
// The other shape it mounts in is a page the *static* driver already
// wrote (dom-edition.md). There the document is not this driver's to
// invent: it has its own <main>, it is already showing the screen, it
// is already in a language, and every route on the site is a file with
// a URL of its own. So five options say which page this is and who owns
// what —
//
//   await mount({
//     wasm: "/app.wasm",
//     into: document.getElementById("chrome"),   // the framework's layers
//     content: document.getElementById("content"), // the host's own <main>
//     route: "routing",                          // the screen this file is
//     locale: "fa",                              // the language it is in
//     seed: "/md/routing.md",                    // what it was built from
//     addressing: "documents",                   // a screen is a file here
//   });
//
// — and everything below them is the same driver, doing the same thing.

import { appHooks, registerServiceWorker, reportAuthToOpener, seedSecureStore } from "./services.js";

// core/event.zig's `Key`, by the browser's name for each, in that
// enum's order. Anything not here is not a key nokre has — the set is
// closed there too, so this table is the whole map.
const KEY_BY_CODE = {
  Tab: 0, Enter: 1, " ": 2, Escape: 3, Backspace: 4, Delete: 5,
  ArrowLeft: 6, ArrowRight: 7, ArrowUp: 8, ArrowDown: 9,
  Home: 10, End: 11, PageUp: 12, PageDown: 13,
};

// The inputTypes a composition session emits: the first pair during it
// (every engine), the second at its edges (WebKit). None are this
// driver's to forward — the composition events are the one lane — but
// the WebKit pair *is* cancelable and must be refused, because core
// applies the commit itself and the browser inserting it too would
// type it twice. preventDefault on the non-cancelable pair is inert.
const COMPOSITION_INPUTS = new Set([
  "insertCompositionText", "deleteCompositionText",
  "insertFromComposition", "deleteByComposition",
]);

export async function mount({ wasm, into, worker, content, route, locale, seed, addressing }) {
  // The oauth popup lands on the app's own page (services.js states
  // the design): a popup carrying an auth response reports its URL to
  // its opener and closes, instead of booting a second app nobody will
  // ever see.
  if (reportAuthToOpener()) return null;
  const utf8 = new TextDecoder();
  const bytes = new TextEncoder();
  let nk = null;

  // Where a screen is a document, the browser is already the router.
  // It owns every link — the reader's middle click, their copy, their
  // Back — and it owns the address bar, because the address bar is
  // *the file being served*. What is left for this driver is the half
  // a file cannot do: measuring, folding, focus, and every control that
  // is not a link.
  const documents = addressing === "documents";
  // The screen goes where the host put it, or into a <main> of the
  // driver's own beside the chrome. One walk writes both halves either
  // way; only the seam moves.
  const screen = content ?? into;
  const wrap = content ? 0 : 1;

  // Started before the module is fetched, awaited just before boot: a
  // seed is read *inside* the first build, so it has to be in hand by
  // then, and two round trips in sequence would be one too many.
  const seeding = seed === undefined ? null : fetch(seed).then((r) => r.text());
  // Re-read, never cached: a wasm call may grow the heap and detach
  // whatever view was taken before it (services.js says it at length).
  const memory = () => new Uint8Array(nk.memory.buffer);
  const read = (ptr, len) => utf8.decode(memory().subarray(ptr, ptr + len));

  // A driver is a shell here as much as AppKit is one there, and it
  // owes the same free functions. `onWork` is how anything that lands
  // asynchronously — a worker reply, a response — gets a frame: core
  // invalidates on its own, and this is the signal that it may have.
  const env = appHooks({
    nk: () => nk,
    memory,
    wasmUrl: new URL(wasm, location.href).href,
    workerUrl: worker ? new URL(worker, location.href) : new URL("./live-worker.js", import.meta.url),
    onWork: () => frame(),
    // A width core was told is a width core decided from, so answers
    // that changed are not repainted, they are re-asked. `setViewport`
    // is the way in: it reshapes the nav and marks layout dirty, which
    // is the whole of what a new set of advances can affect.
    onMetrics: () => remeasure(),
  });

  const source = await WebAssembly.instantiateStreaming(fetch(wasm), { env });
  nk = source.instance.exports;

  // Strings in: one scratch buffer, filled then consumed by the export
  // that was waiting for it.
  function put(text) {
    const encoded = bytes.encode(text);
    const ptr = nk.nokre_dom_scratch(encoded.length);
    // Null is wasm-side OOM (the locale scratch's contract): hand over
    // the empty string rather than writing at address 0.
    if (!ptr) return 0;
    memory().set(encoded, ptr);
    return encoded.length;
  }

  // ---- frame ------------------------------------------------------

  // A frame renders when state changes, and otherwise nothing runs:
  // there is no ticker here either. The string compare is what makes an
  // event that changed nothing cost nothing.
  let painted = "";
  let painted_screen = "";
  const staging = document.createElement("template");

  function paint(target, html, last) {
    if (html === last) return last;
    staging.innerHTML = html;
    patch(target, staging.content);
    return html;
  }

  function frame() {
    const ptr = nk.nokre_dom_render(wrap);
    const len = nk.nokre_dom_render_len();
    // Two regions, one walk. The host document decided where the
    // framework's layers sit and where the screen sits — the nav leads
    // the focus order, and the <main> is what the skip link names — so
    // the split is read at the seam wasm wrote it at. In *bytes*: a
    // string index would put the cut somewhere else the moment a screen
    // holds a character that is not ASCII, which most of them do.
    const cut = content ? nk.nokre_dom_chrome_len() : len;
    painted = paint(into, read(ptr, cut), painted);
    if (content) {
      painted_screen = paint(content, read(ptr + cut, len - cut), painted_screen);
      // The class is layout's answer and not the page's: whether a
      // screen owes the clear space bottom chrome needs depends on what
      // chrome it has, which the pass that just ran decided. `toggle`,
      // not an assignment — the rest of that class list is the
      // document's own.
      content.classList.toggle("has-chrome", !!nk.nokre_dom_chromed());
    }
    restoreFocus();
    syncAddressBar();
    syncRoot();
  }

  // The two page-level facts core owns and no markup carries: which
  // ramp the page paints in, and which way its chrome is mirrored.
  //
  // Neither is a media query's to answer. `App.scheme` may pin light or
  // dark and only `auto` defers to the desktop — so the OS preference
  // goes *in*, the same report a native shell makes, and what comes
  // back out is the resolved appearance. Direction is `setDirection`,
  // which a localized app pairs with its locale.
  //
  // They land as attributes on the document root, where the generated
  // sheet already puts the palette, and that sheet spends them on
  // nokre's own surfaces only — an edition mounted in someone else's
  // document has no business restyling the page around it. Without the
  // appearance attribute the sheet falls back to the media query, which
  // is all a page with no app behind it has.
  const root = into.ownerDocument.documentElement;
  const dark = matchMedia("(prefers-color-scheme: dark)");

  function syncRoot() {
    const appearance = nk.nokre_dom_appearance() ? "dark" : "light";
    if (root.dataset.appearance !== appearance) root.dataset.appearance = appearance;
    const direction = nk.nokre_dom_direction() ? "rtl" : "ltr";
    if (root.dataset.direction !== direction) root.dataset.direction = direction;
  }

  dark.addEventListener("change", () => {
    nk.nokre_dom_system_appearance(dark.matches ? 1 : 0);
    frame();
  });

  // Why this is not `innerHTML = html`.
  //
  // The markup is a projection of the tree and the tree is rebuilt
  // whole, so replacing the document wholesale *renders* correctly —
  // and destroys everything the browser was keeping on the side of it.
  // A scroll offset is the clearest case: a `segmented` track scrolled
  // halfway, a `scroll_region` mid-list, the page itself. Those live on
  // the element, and an element that is replaced rather than updated
  // starts over at zero. Selection, the caret, and `:focus` go the same
  // way.
  //
  // nokre has an answer the browser does not: every focus stop carries
  // its `NodeId` as `data-n`, so identity across frames is *stated*
  // rather than guessed at. Two nodes are the same node when they are
  // the same kind of thing and carry the same id; a node whose id
  // changed is a different node and is replaced outright.
  function sameNode(a, b) {
    if (a.nodeType !== b.nodeType) return false;
    if (a.nodeType === Node.TEXT_NODE) return true;
    if (a.nodeName !== b.nodeName) return false;
    return (a.dataset?.n ?? null) === (b.dataset?.n ?? null);
  }

  function patch(cur, next) {
    let a = cur.firstChild;
    let b = next.firstChild;
    while (a || b) {
      if (!b) {
        const gone = a;
        a = a.nextSibling;
        cur.removeChild(gone);
      } else if (!a) {
        const add = b;
        b = b.nextSibling;
        cur.appendChild(document.importNode(add, true));
      } else if (sameNode(a, b)) {
        const [na, nb] = [a.nextSibling, b.nextSibling];
        patchNode(a, b);
        [a, b] = [na, nb];
      } else {
        const fresh = document.importNode(b, true);
        b = b.nextSibling;
        const old = a;
        a = a.nextSibling;
        cur.replaceChild(fresh, old);
      }
    }
  }

  function patchNode(a, b) {
    if (a.nodeType === Node.TEXT_NODE) {
      if (a.data !== b.data) a.data = b.data;
      return;
    }
    for (const attr of [...a.attributes]) {
      if (!b.hasAttribute(attr.name)) a.removeAttribute(attr.name);
    }
    for (const attr of b.attributes) {
      if (a.getAttribute(attr.name) !== attr.value) a.setAttribute(attr.name, attr.value);
    }
    // Attributes are the markup's idea of a field; the property is the
    // browser's, and only the second one shows. The tree owns both —
    // except mid-composition, when the focused field is the IME's:
    // the preedit lives in its value, the markup carries the value
    // *without* it, and writing that out from under an open session
    // aborts it in every engine. The frame after the session resolves
    // puts the tree's answer back.
    if ((a.nodeName === "INPUT" || a.nodeName === "TEXTAREA") && !(composing && a === document.activeElement)) {
      const value = a.nodeName === "INPUT" ? (b.getAttribute("value") ?? "") : b.textContent;
      if (a.type !== "checkbox" && a.type !== "radio" && a.value !== value) a.value = value;
      // Assigned every time, not only when it looks wrong: the tree's
      // answer is the answer, and a control the browser has been
      // touching can disagree with its own attribute.
      a.checked = b.hasAttribute("checked");
    }
    patch(a, b);
  }

  // The regions this driver writes into, in document order. One where
  // it owns the whole mount, two where the host kept its own <main> —
  // and a focus stop, a press or a keystroke may land in either, so
  // nothing below asks `into` alone.
  const roots = content ? [into, content] : [into];

  function find(selector) {
    for (const root of roots) {
      const el = root.querySelector(selector);
      if (el) return el;
    }
    return null;
  }

  function listen(type, handler) {
    for (const root of roots) root.addEventListener(type, handler);
  }

  // Focus and the caret live on the tree, not in the DOM — `focus.zig`
  // moves one and `editing.zig` the other — so after the document is
  // rewritten they are put back from there rather than guessed at.
  function restoreFocus() {
    const node = nk.nokre_dom_focused_node();
    const span = nk.nokre_dom_focused_span();
    const selector = span < 0
      ? `[data-n="${node}"]:not([data-s])`
      : `[data-n="${node}"][data-s="${span}"]`;
    const el =
      find(`${selector}:is(a,button,input,select,textarea,[tabindex])`) ?? find(selector);
    if (!el) return;
    if (el !== document.activeElement) el.focus({ preventScroll: true });

    // The caret is restored on every frame, not only when focus moved.
    // `editing.zig` owns where it sits, and writing a field's value
    // puts the DOM's own back at one end — so the frame after a
    // keystroke would leave it there, which is a cursor that jumps to
    // the start of what you are typing.
    //
    // Not mid-composition, though: the caret is the IME's then — core's
    // own points before the preedit — and poking a field's selection
    // under an open session aborts it, the patchNode rule.
    if (composing) return;
    const caret = nk.nokre_dom_caret();
    if (caret < 0 || !el.setSelectionRange) return;
    // The cursor is a byte offset; a field's own is in UTF-16 units.
    const at = utf8.decode(bytes.encode(el.value).subarray(0, caret)).length;
    if (el.selectionStart !== at || el.selectionEnd !== at) el.setSelectionRange(at, at);
  }

  // The fragment names the screen the app is on, in both directions
  // and without configuration. It is a reference, unencoded: every byte
  // a name or an argument may carry is one encodeURIComponent leaves
  // alone, so what the app writes is what a reader copies.
  // core/router.zig's `Change`, in that enum's order.
  const MOTION = ["push", "pop", "replace", "switch_to"];

  let bar = "";
  function syncAddressBar() {
    const ref = read(nk.nokre_dom_route(), nk.nokre_dom_route_len());
    if (ref === bar) return;
    const first = bar === "";
    bar = ref;
    // Where a screen is a document, a route change *is* a navigation:
    // the reader is owed the file for that screen, not this file
    // wearing its name. Nothing to do on the first frame — the screen
    // the router just landed on is the one this document already is —
    // and the href comes from the app's own Refs, so the bar and the
    // links in the page cannot disagree about where a screen lives.
    if (documents) {
      if (first) return;
      location.assign(read(nk.nokre_dom_href(put(ref)), nk.nokre_dom_href_len()));
      return;
    }
    // A pushed screen adds a history entry and nothing else does: a
    // section switch and a `replace` are the router saying *this is the
    // same place*. Which of those it was is the router's answer, not a
    // guess from here — browser Back and the in-app Back control are
    // the same motion, deliberately, and they only stay the same if the
    // entries match.
    const push = MOTION[nk.nokre_dom_route_motion()] === "push";
    history[push ? "pushState" : "replaceState"](null, "", "#" + ref);
  }

  // ---- events -----------------------------------------------------

  // Nothing activates on the way down. The press is recorded, focus
  // moves to what is under it, and the release decides — which is
  // core's rule (WCAG 2.5.2) and also, conveniently, what `click`
  // already means in a browser.
  listen("click", (e) => {
    // The scrim is the layer saying the rest of the tree is inert, and
    // pressing it means what Esc means: dismiss the layer. It carries
    // no node of its own, so it is the one press resolved by class
    // rather than by id — and it goes through the same key core
    // already handles rather than a second way to close things.
    if (e.target.classList.contains("scrim")) {
      nk.nokre_dom_key(KEY_BY_CODE.Escape, 0);
      frame();
      return;
    }
    // Where a screen is a document, a link is the browser's: it has a
    // file behind it, and letting the router answer instead would take
    // the one navigation a reader can middle-click, copy, open in a tab
    // and come Back from, and turn it into a redraw. It also settles
    // the destinations core has no opinion about — a heading on this
    // page, a source file on someone else's host — which are legal
    // hrefs and not routes at all, so nothing would have happened.
    if (documents && e.target.closest("a[href]")) return;
    // An external link is the browser's on every driver, for the same
    // reasons: it carries a real href (target _blank, noopener —
    // serialize.zig), and re-opening it through the open_url service
    // would drop the reader's modifier keys — their middle click, their
    // "open in new window". Route links keep their fragment hrefs and
    // stay the router's; keyboard activation of an external link still
    // crosses into core and reaches the service (services.js).
    {
      const anchor = e.target.closest("a[href]");
      if (anchor && !anchor.getAttribute("href").startsWith("#")) return;
    }
    // An exclusive choice is resolved on the chip, which is the whole
    // label — checked *first*, because the label is an ancestor of the
    // control and `closest` would otherwise find the control and let
    // the browser act on the label before this ever ran.
    const chip = e.target.closest("[data-i]");
    if (chip) {
      // And cancelled here, not later: the tree owns the selection, so
      // the browser must not also apply one. Cancelling a radio's
      // activation after the fact reverts it, which is how a control
      // ends up showing one answer while the tree holds another.
      e.preventDefault();
      nk.nokre_dom_select(Number(chip.dataset.n), Number(chip.dataset.i));
      frame();
      return;
    }
    const stop = e.target.closest("[data-n]");
    if (!stop) return;
    // A link is a real link: it has an href a reader can copy, and the
    // navigation belongs to the router rather than to a page load.
    e.preventDefault();
    // One call. A press moves focus *and* activates, and both are one
    // input — two calls would be two inputs, and every rule an input
    // carries would run twice.
    nk.nokre_dom_press(Number(stop.dataset.n), stop.dataset.s === undefined ? -1 : Number(stop.dataset.s));
    frame();
  });

  // Tabbing is the browser's: the markup is the tree, so document
  // order already *is* focus order. What crosses back into wasm is
  // where it landed.
  listen("focusin", (e) => {
    const stop = e.target.closest("[data-n]");
    if (!stop) return;
    if (stop.dataset.i !== undefined && stop !== e.target) return; // the chip, not its control
    nk.nokre_dom_focus(
      Number(stop.dataset.n),
      stop.dataset.s === undefined ? -1 : Number(stop.dataset.s),
    );
  });

  // Tab included, deliberately. Leaving it to the browser looks like
  // delegation and is really a rule going missing: core's traversal
  // knows the focus *scope* — an open sheet or picker holds focus
  // inside it, and the page behind a scrim is inert — and it knows to
  // skip the nav while a banner owns the bottom pane. A browser knows
  // neither, and would tab straight out of a modal layer.
  listen("keydown", (e) => {
    // Mid-composition every key is the IME's — Enter takes a candidate,
    // Escape dismisses the preedit — and forwarding one would run it
    // twice, once in the IME and once in core. The old canvas glue kept
    // this same silence.
    if (composing || e.isComposing) return;
    const key = KEY_BY_CODE[e.key];
    if (key === undefined) return;
    const editable = e.target.matches("input[type=text], input[type=password], textarea");
    // Inside a field the arrows and Home/End are the caret's, and
    // `editing.zig` is what moves it — so they go through like any
    // other key. Space in a field is text, not activation.
    if (editable && e.key === " ") return;
    e.preventDefault();
    nk.nokre_dom_key(key, mods(e));
    frame();
  });

  // Typing edits the tree, and the tree is what the field then shows.
  // `beforeinput` is where that is possible: the DOM's own edit is
  // refused, the bytes go to core, and the re-render puts back a value
  // core decided on.
  listen("beforeinput", (e) => {
    if (!e.target.matches("input, textarea")) return;
    // A composition's own edits ride the IME lane below, never this
    // one. COMPOSITION_INPUTS says why the refusal still applies.
    if (COMPOSITION_INPUTS.has(e.inputType)) {
      e.preventDefault();
      return;
    }
    if (composing || e.isComposing) return;
    e.preventDefault();
    if (e.inputType === "insertText" && e.data) {
      nk.nokre_dom_text(put(e.data));
    } else if (e.inputType === "insertFromPaste" || e.inputType === "insertFromDrop") {
      // Paste carries its text on `data` in some engines and on the
      // dataTransfer in others; a drop always on the dataTransfer.
      // Either way it enters the tree as typed text — core owns what a
      // field holds, however the bytes arrived.
      const data = e.data ?? e.dataTransfer?.getData("text/plain");
      if (!data) return;
      nk.nokre_dom_text(put(data));
    } else if (e.inputType === "deleteContentBackward" || e.inputType === "deleteByCut") {
      // A cut's clipboard write already happened on the `cut` event;
      // what is owed here is the deletion. core's editing model is a
      // caret, not a range, so it deletes what one Backspace deletes.
      nk.nokre_dom_key(KEY_BY_CODE.Backspace, 0);
    } else if (e.inputType === "deleteContentForward") {
      nk.nokre_dom_key(KEY_BY_CODE.Delete, 0);
    } else {
      // Deliberately unhandled: history undo/redo has no tree-side
      // meaning (the tree is the history), and formatting inputs cannot
      // apply to a plain field. preventDefault above has already
      // refused the DOM's own edit.
      return;
    }
    frame();
  });

  // ---- IME --------------------------------------------------------

  // Composition is the browser's while it lasts and the tree's when it
  // resolves. The preedit lives in the real field — the native IME a
  // real field buys is on the list of what this edition traded pixel
  // goldens for — so an open session owns that field outright: its keys
  // are not forwarded, its edits are not refused, and a frame that
  // lands mid-session leaves its value and caret alone (the patchNode
  // and restoreFocus guards). What crosses into core is the same three
  // legs every shell sends: the preedit streams as updates so the
  // tree's `composition` is true on this platform too, and the session
  // ends as a commit or — empty, the reading every shell gives the
  // same silence — a cancel.
  let composing = false;

  listen("compositionstart", (e) => {
    if (!e.target.matches("input, textarea")) return;
    composing = true;
  });

  listen("compositionupdate", (e) => {
    if (!composing) return;
    // The cursor rides at the preedit's end. Core draws the caret
    // wherever this says (platform-shells.md, "IME"), and every native
    // shell reports its engine's own offset — but `compositionupdate`
    // carries no caret, and the field composing the preedit is the
    // browser's own, so the end is both the only answer available here
    // and the right one for a caret nobody moved.
    const len = put(e.data || "");
    nk.nokre_dom_ime_update(len, len);
    // The frame is nearly free — the markup carries the value without
    // the preedit, so its bytes usually have not moved — and it keeps
    // the invariant that every event lands one.
    frame();
  });

  listen("compositionend", (e) => {
    if (!composing) return;
    composing = false;
    const text = e.data || "";
    if (text) nk.nokre_dom_ime_commit(put(text));
    else nk.nokre_dom_ime_cancel();
    frame();
  });

  function mods(e) {
    return (e.shiftKey ? 1 : 0) | (e.ctrlKey ? 2 : 0) | (e.altKey ? 4 : 0) | (e.metaKey ? 8 : 0);
  }

  // deep_link's lane (services/deep_link/web.zig): the web deep link
  // is the fragment, delivered as the whole URL — the service's
  // `fragment` helper extracts it, so the app reads a link the same
  // way on every platform. The export exists only when the app linked
  // the service; a page that never claims a deep link pays nothing.
  // This runs *alongside* the router's own reading of the fragment
  // below, deliberately: the two answer different questions — a URL
  // arrived, versus which screen is showing — and an app that routes
  // on both sees the fragment twice by that contract (docs/routing.md
  // says to route on one or the other). A handler that navigates to
  // the reference the router already switched to is idempotent.
  function deliverDeepLink() {
    if (!nk.nokre_deep_link_receive) return;
    const b = bytes.encode(location.href);
    const ptr = nk.nokre_dom_scratch(b.length);
    if (!ptr) return;
    memory().set(b, ptr);
    nk.nokre_deep_link_receive(ptr, b.length);
    frame();
  }

  addEventListener("hashchange", deliverDeepLink);

  // The browser's Back and the in-app Back are the same motion,
  // deliberately. A fragment the router cannot honor leaves the app
  // where it is, and the bar goes back to what it was — so it never
  // describes a screen nobody is on.
  addEventListener("hashchange", () => {
    // Not this lane's, where a screen is a document: a fragment there
    // names a heading on the page the reader is already on, and the
    // browser is the only thing that should act on it.
    if (documents) return;
    const ref = location.hash.slice(1);
    if (!ref || ref === bar) return;
    if (!nk.nokre_dom_navigate(put(ref))) {
      history.replaceState(null, "", "#" + bar);
      return;
    }
    frame();
  });

  // Layout is core's, so a resize is a relayout — and on this edition
  // it is also what re-asks every measured decision, the nav's shape
  // among them.
  //
  // The width is the container's, not the window's. A host page may
  // hold the screen to a readable column (the one nokre ships does),
  // and core measuring against the window instead would decide against
  // a width nobody is looking at: prose wrapped somewhere else, a row
  // of actions that had room to spare and so never folded its tail,
  // a track that fitted in a column it overflows. The height stays the
  // window's, because that is what "how much is visible" means and
  // what a scroll region resolves against.
  // Measured on the element the *screen* is in, which is the column
  // prose wraps in and the width a row of actions folds against; where
  // the host owns that element, the chrome's own container is not it.
  function remeasure() {
    if (!nk) return; // the faces beat the module; boot reports it itself
    nk.nokre_dom_resize(screen.clientWidth, innerHeight);
    frame();
  }

  addEventListener("resize", remeasure);

  // ---- boot -------------------------------------------------------

  // The tag, strictly before boot: a locale read inside the first
  // build has to answer synchronously (services/locale/web.zig owns the
  // seed exports; this is the shell half that calls them).
  //
  // Two sources, and the *page's* outranks the device's.
  // `navigator.language` is the only evidence an app booting into an
  // empty body has, and it stays the answer there. It is the wrong
  // answer over a page a generator already wrote: that page is the
  // app's first frame and it is in one language, while hydration
  // matches nodes by tag and `data-n` and never by text — so an app
  // that boots in another language swaps every string, mirrors the
  // layout back, and reports nothing at all (dom-edition.md, "The
  // page's locale, not the reader's").
  if (nk.nokre_locale_seed) {
    // A page that pins the *empty* tag is a real page and not an absent
    // option: it is the document of an app that chose no locale, whose
    // catalog therefore resolved to its own template, and reproducing
    // that is exactly the job. `undefined` is the only "nobody said".
    const pinned = typeof locale === "string";
    const tag = bytes.encode(pinned ? locale : navigator.language || "");
    const ptr = nk.nokre_locale_scratch(tag.length);
    if (ptr) {
      memory().set(tag, ptr);
      nk.nokre_locale_seed(tag.length);
    }
    // Every change after boot, on the same lane — and only where the
    // device is what the app was following. A pinned page keeps its
    // language when the reader changes their browser's: the URL is the
    // language there, and one URL that shows two languages is the thing
    // per-locale pages exist to prevent.
    if (!pinned) {
      addEventListener("languagechange", () => {
        const t = bytes.encode(navigator.language || "");
        const p = nk.nokre_locale_scratch(t.length);
        if (!p) return;
        memory().set(t, p);
        nk.nokre_locale_receive(p, t.length);
        frame();
      });
    }
  }

  // The stored secrets, strictly before boot for the locale's reason:
  // a boot-time `get` inside the first build answers synchronously
  // (services/secure_store/web.zig owns the seed exports; services.js
  // owns the sessionStorage schema, so the scan lives beside the
  // mirror it feeds).
  seedSecureStore(nk, memory);

  // The oauth redirect: this page's own address, without query or
  // fragment — the provider appends its own. Seeded before boot like
  // the locale, because `oauth.redirectUri` is called inside an action
  // and answers synchronously. A null scratch is an over-cap URL,
  // seeded as nothing so the first sign-in fails loudly rather than
  // sending a truncated redirect (services/oauth/web.zig).
  if (nk.nokre_oauth_seed_scratch) {
    const rb = bytes.encode(location.origin + location.pathname);
    const ptr = nk.nokre_oauth_seed_scratch(rb.length);
    if (ptr) {
      memory().set(rb, ptr);
      nk.nokre_oauth_seed_redirect(rb.length);
    }
  }

  // The host page's own bytes, on the locale's lane and for the locale's
  // reason: whatever the app makes of them, it makes inside the first
  // `build`, so they cannot arrive after it. A page generated from a
  // document hands over that document.
  if (seeding) nk.nokre_dom_seed(put(await seeding));

  // The screen this document is, as a boot argument rather than a
  // navigation after the fact: the file already shows it, and switching
  // afterwards would build and paint some other screen on the way past.
  if (!nk.nokre_dom_boot(screen.clientWidth, innerHeight, route ? put(route) : 0)) {
    throw new Error("nokre: the module exports no nokreWebBuild");
  }
  // After boot rather than before it, unlike the locale: an appearance
  // is read at paint and the first frame has not run yet, while a
  // locale is read inside the first `build` (services/locale/web.zig
  // says so at length).
  nk.nokre_dom_system_appearance(dark.matches ? 1 : 0);
  // The notification service's worker, and the cold-start tap it may
  // have carried. Registration is after boot deliberately — it is
  // asynchronous either way, and nothing in the first `build` can wait
  // on it: the boot probes read `Notification.permission`, which the
  // page answers without a worker (docs/internals/notifications.md).
  registerServiceWorker();
  {
    // A tap with no page open opens one, and the only thing sw.js can
    // hand a page that does not exist yet is its URL. Delivered as a tap
    // once, then stripped from the address bar so a reload is not a
    // second tap — the route the app navigates to is what stays there.
    const q = new URLSearchParams(location.search);
    const tapped = q.get("nokre.id");
    if (tapped && nk.nokre_notification_scratch) {
      const ib = bytes.encode(tapped);
      const rb = bytes.encode(q.get("nokre.route") || "");
      const ptr = nk.nokre_notification_scratch(ib.length + rb.length);
      if (ptr) {
        memory().set(ib, ptr);
        memory().set(rb, ptr + ib.length);
        nk.nokre_notification_receive(1, 1, ib.length, rb.length);
      }
      q.delete("nokre.id");
      q.delete("nokre.route");
      const rest = q.toString();
      history.replaceState(null, "", location.pathname + (rest ? "?" + rest : "") + location.hash);
    }
  }

  if (!documents) {
    const inbound = location.hash.slice(1);
    if (inbound) nk.nokre_dom_navigate(put(inbound));
  }
  // The launch deep link: a fragment present at load is delivered
  // after boot, so the handler the app registered inside its first
  // build is already installed — the "first callback after boot"
  // contract (docs/services.md).
  if (location.hash) deliverDeepLink();
  frame();
  return nk;
}
