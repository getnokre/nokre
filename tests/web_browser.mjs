// The browser the web services check runs in (tests/web_services.mjs).
//
// nokre's web edition is Zig on one side of a wall and live.js +
// services.js on the other, and until this file nothing executed the
// wall: `zig build test` runs mocks, `check-targets` compiles the web
// legs into objects it never links, and `node --check` reads the
// JavaScript without running a line of it. What was missing was not a
// test — it was a *browser*, so this is one, in as much as the driver
// actually asks for.
//
// The rule it is written under: nothing here may know anything about
// nokre. It implements platform APIs — a document, a location, a
// session storage, a window that can open another window and be posted
// to — and the code under test is the shipped `live.js` and
// `services.js`, imported unmodified from the built site. A stub that
// re-implemented a line of the driver would prove that line twice and
// the real one never.
//
// No dependency, for the reason the parse step gives: node is asked one
// question through the interface every JavaScript engine has, and
// nothing here is fetched, installed, or shipped. A DOM library would
// be a nokre dependency in everything but name.
//
// What it is *not* is a browser. The parts a driver reads are here —
// parsing markup, patching a tree, matching a selector, dispatching an
// event, storing a string — and everything else a browser does is
// absent: no layout (`measureText` charges three fifths of the size per
// character, the Zig harness's own stand-in), no styling, no navigation
// that fetches, no security model beyond the two checks services.js
// makes itself. Which is exactly the split the check needs: the service
// seam is executed, and the page around it is furniture.

import { readFileSync } from "node:fs";
import { webcrypto } from "node:crypto";

// ---- markup ------------------------------------------------------

// A void element takes no closing tag; everything the serializer emits
// that is one is here, plus the rest of HTML's set, because the parser
// is the browser's half and the browser knows them all.
const VOID = new Set([
  "area", "base", "br", "col", "embed", "hr", "img",
  "input", "link", "meta", "param", "source", "track", "wbr",
]);

const NAMED = { amp: "&", lt: "<", gt: ">", quot: '"', apos: "'", nbsp: " " };

function decodeEntities(s) {
  if (!s.includes("&")) return s;
  return s.replace(/&(#[xX][0-9a-fA-F]+|#[0-9]+|[a-zA-Z]+);/g, (whole, body) => {
    if (body[0] !== "#") return NAMED[body] ?? whole;
    const code = body[1] === "x" || body[1] === "X"
      ? parseInt(body.slice(2), 16)
      : parseInt(body.slice(1), 10);
    return Number.isFinite(code) ? String.fromCodePoint(code) : whole;
  });
}

// ---- selectors ---------------------------------------------------
// Only the shapes the driver writes: a tag, a class, an attribute with
// or without a value, and the two functional pseudo-classes
// `restoreFocus` composes (`:not`, `:is`). Anything else throws rather
// than quietly matching nothing — a selector this file does not
// understand is a hole in the check, not a detail.

const SIMPLE = /^(?:([a-zA-Z][\w-]*)|\.([\w-]+)|#([\w-]+)|\[([\w-]+)(?:=(?:"([^"]*)"|([^\]]*)))?\]|:not\(([^)]*)\)|:is\(([^)]*)\))/;

function matchesCompound(el, selector) {
  let rest = selector.trim();
  if (rest === "") return false;
  while (rest.length) {
    const m = SIMPLE.exec(rest);
    if (!m) throw new Error(`web_browser.mjs: unsupported selector "${selector}"`);
    const [whole, tag, cls, id, attr, quoted, bare, not, is] = m;
    if (tag !== undefined) {
      if (el.nodeName !== tag.toUpperCase()) return false;
    } else if (cls !== undefined) {
      if (!el.classList.contains(cls)) return false;
    } else if (id !== undefined) {
      if (el.getAttribute("id") !== id) return false;
    } else if (attr !== undefined) {
      const value = el.getAttribute(attr);
      if (value === null) return false;
      const want = quoted ?? bare;
      if (want !== undefined && value !== want) return false;
    } else if (not !== undefined) {
      if (matchesList(el, not)) return false;
    } else if (is !== undefined) {
      if (!matchesList(el, is)) return false;
    }
    rest = rest.slice(whole.length);
  }
  return true;
}

// A selector list, split on the commas that are not inside `:not(…)`
// or `:is(…)`.
function matchesList(el, selector) {
  let depth = 0;
  let start = 0;
  const parts = [];
  for (let i = 0; i < selector.length; i++) {
    const c = selector[i];
    if (c === "(") depth++;
    else if (c === ")") depth--;
    else if (c === "," && depth === 0) {
      parts.push(selector.slice(start, i));
      start = i + 1;
    }
  }
  parts.push(selector.slice(start));
  return parts.some((p) => matchesCompound(el, p));
}

// ---- the tree ----------------------------------------------------

class DomNode {
  constructor(doc) {
    this.ownerDocument = doc;
    this.childNodes = [];
    this.parentNode = null;
  }

  get firstChild() {
    return this.childNodes[0] ?? null;
  }

  get nextSibling() {
    const siblings = this.parentNode?.childNodes;
    if (!siblings) return null;
    return siblings[siblings.indexOf(this) + 1] ?? null;
  }

  appendChild(node) {
    node.parentNode?.removeChild(node);
    this.childNodes.push(node);
    node.parentNode = this;
    return node;
  }

  removeChild(node) {
    const at = this.childNodes.indexOf(node);
    if (at >= 0) this.childNodes.splice(at, 1);
    node.parentNode = null;
    return node;
  }

  replaceChild(fresh, old) {
    const at = this.childNodes.indexOf(old);
    if (at < 0) throw new Error("web_browser.mjs: replaceChild on a node that is not a child");
    this.childNodes[at] = fresh;
    fresh.parentNode = this;
    old.parentNode = null;
    return old;
  }

  querySelector(selector) {
    for (const child of this.childNodes) {
      if (child.nodeType === 1 && matchesList(child, selector)) return child;
      const deeper = child.querySelector?.(selector);
      if (deeper) return deeper;
    }
    return null;
  }

  querySelectorAll(selector) {
    const found = [];
    for (const child of this.childNodes) {
      if (child.nodeType === 1 && matchesList(child, selector)) found.push(child);
      if (child.querySelectorAll) found.push(...child.querySelectorAll(selector));
    }
    return found;
  }

  get textContent() {
    return this.childNodes.map((c) => c.textContent).join("");
  }
}

class TextNode extends DomNode {
  constructor(doc, data) {
    super(doc);
    this.nodeType = 3;
    this.nodeName = "#text";
    this.data = data;
  }

  get textContent() {
    return this.data;
  }
}

class Fragment extends DomNode {
  constructor(doc) {
    super(doc);
    this.nodeType = 11;
    this.nodeName = "#document-fragment";
  }
}

class Element extends DomNode {
  constructor(doc, tag) {
    super(doc);
    this.nodeType = 1;
    this.nodeName = tag.toUpperCase();
    this.attrs = new Map();
    this.listeners = new Map();
    // A width the driver reports to core as the container's. Whatever
    // the harness sets on the mount element is what layout decides
    // against, which is the whole of what a browser's box model is to
    // this check.
    this.clientWidth = 480;
    // Only fields (INPUT / TEXTAREA) carry these, but a plain object
    // answers `a.value !== value` the way an element that has no value
    // property does not — so they exist on every element and mean
    // nothing on the rest.
    this.value = "";
    this.checked = false;
    this.type = "";
  }

  get attributes() {
    return [...this.attrs].map(([name, value]) => ({ name, value }));
  }

  getAttribute(name) {
    return this.attrs.has(name) ? this.attrs.get(name) : null;
  }

  setAttribute(name, value) {
    this.attrs.set(name, String(value));
  }

  hasAttribute(name) {
    return this.attrs.has(name);
  }

  removeAttribute(name) {
    this.attrs.delete(name);
  }

  get dataset() {
    const attrs = this.attrs;
    return new Proxy(
      {},
      {
        get: (_, key) => attrs.get("data-" + dashed(key)),
        set: (_, key, value) => {
          attrs.set("data-" + dashed(key), String(value));
          return true;
        },
        has: (_, key) => attrs.has("data-" + dashed(key)),
      },
    );
  }

  get classList() {
    const el = this;
    const classes = () => (el.getAttribute("class") ?? "").split(/\s+/).filter(Boolean);
    const write = (list) => el.setAttribute("class", list.join(" "));
    return {
      contains: (name) => classes().includes(name),
      add(name) {
        const list = classes();
        if (!list.includes(name)) write([...list, name]);
      },
      remove(name) {
        write(classes().filter((c) => c !== name));
      },
      toggle(name, on) {
        if (on ?? !classes().includes(name)) this.add(name);
        else this.remove(name);
      },
    };
  }

  set textContent(text) {
    this.childNodes = [];
    if (text !== "") this.appendChild(new TextNode(this.ownerDocument, String(text)));
  }

  get textContent() {
    return this.childNodes.map((c) => c.textContent).join("");
  }

  set innerHTML(html) {
    this.childNodes = [];
    // Over a copy: `appendChild` unparents each node, which splices the
    // list being walked and would adopt every other child.
    for (const child of [...parseHtml(this.ownerDocument, html).childNodes]) this.appendChild(child);
  }

  matches(selector) {
    return matchesList(this, selector);
  }

  closest(selector) {
    for (let node = this; node; node = node.parentNode) {
      if (node.nodeType === 1 && matchesList(node, selector)) return node;
    }
    return null;
  }

  focus() {
    this.ownerDocument.activeElement = this;
  }

  setSelectionRange(from, to) {
    this.selectionStart = from;
    this.selectionEnd = to;
  }

  addEventListener(type, handler) {
    if (!this.listeners.has(type)) this.listeners.set(type, []);
    this.listeners.get(type).push(handler);
  }

  removeEventListener(type, handler) {
    const list = this.listeners.get(type) ?? [];
    const at = list.indexOf(handler);
    if (at >= 0) list.splice(at, 1);
  }

  // Bubbling, because that is what the driver's delegation depends on:
  // it listens on the mount and reads `e.target`, so an event fired on
  // a button has to reach a handler on its ancestor.
  dispatchEvent(event) {
    event.target = this;
    for (let node = this; node; node = node.parentNode) {
      for (const handler of node.listeners?.get(event.type) ?? []) handler(event);
    }
    return !event.defaultPrevented;
  }
}

// `data-n` ↔ `dataset.n`; the driver writes no multi-word data
// attribute, but the rule is the platform's, not the driver's.
function dashed(key) {
  return String(key).replace(/[A-Z]/g, (c) => "-" + c.toLowerCase());
}

class Template extends Element {
  constructor(doc) {
    super(doc, "template");
    this.content = new Fragment(doc);
  }

  set innerHTML(html) {
    this.content = parseHtml(this.ownerDocument, html);
  }
}

function parseHtml(doc, html) {
  const frag = new Fragment(doc);
  const stack = [frag];
  const top = () => stack[stack.length - 1];
  let i = 0;
  while (i < html.length) {
    const lt = html.indexOf("<", i);
    if (lt < 0) {
      addText(html.slice(i));
      break;
    }
    if (lt > i) addText(html.slice(i, lt));
    if (html.startsWith("<!--", lt)) {
      i = html.indexOf("-->", lt) + 3;
      continue;
    }
    if (html.startsWith("<!", lt)) {
      i = html.indexOf(">", lt) + 1;
      continue;
    }
    const gt = tagEnd(html, lt);
    const raw = html.slice(lt + 1, gt);
    if (raw[0] === "/") {
      const name = raw.slice(1).trim().toUpperCase();
      // The serializer is well-formed by construction, so an unmatched
      // close is this parser being wrong about the markup rather than
      // the markup being wrong — say so instead of guessing.
      if (stack.length < 2 || top().nodeName !== name) {
        throw new Error(`web_browser.mjs: </${name}> closes ${top().nodeName}`);
      }
      stack.pop();
    } else {
      const selfClosing = raw.endsWith("/");
      const body = selfClosing ? raw.slice(0, -1) : raw;
      const name = /^[^\s/>]+/.exec(body)[0];
      const el = doc.createElement(name);
      for (const attr of body.slice(name.length).matchAll(/([^\s=/]+)(?:\s*=\s*"([^"]*)")?/g)) {
        el.setAttribute(attr[1], decodeEntities(attr[2] ?? ""));
      }
      // The two properties a browser derives from attributes at parse
      // time, and the driver then reads back as properties.
      if (el.nodeName === "INPUT") {
        el.type = el.getAttribute("type") ?? "text";
        el.value = el.getAttribute("value") ?? "";
        el.checked = el.hasAttribute("checked");
      }
      top().appendChild(el);
      if (!selfClosing && !VOID.has(name.toLowerCase())) stack.push(el);
    }
    i = gt + 1;
  }
  if (stack.length !== 1) throw new Error(`web_browser.mjs: unclosed <${top().nodeName}>`);
  return frag;

  function addText(text) {
    const parent = top();
    const decoded = decodeEntities(text);
    if (parent.nodeName === "TEXTAREA") parent.value = decoded;
    parent.appendChild(new TextNode(doc, decoded));
  }
}

// The `>` that ends a tag, skipping the one inside a quoted attribute
// value — a `style="width:calc(100% * 3 / 4)"` has neither, but an
// href to a route reference can carry anything.
function tagEnd(html, from) {
  let quoted = false;
  for (let i = from + 1; i < html.length; i++) {
    const c = html[i];
    if (c === '"') quoted = !quoted;
    else if (c === ">" && !quoted) return i;
  }
  throw new Error("web_browser.mjs: unterminated tag");
}

class Document {
  constructor() {
    this.documentElement = new Element(this, "html");
    this.body = new Element(this, "body");
    this.documentElement.appendChild(this.body);
    this.activeElement = null;
    // `document.fonts?.addEventListener` — a browser with no font
    // loading API to report from is the honest stub, and the driver
    // already guards it.
    this.fonts = undefined;
  }

  createElement(tag) {
    if (tag.toLowerCase() === "template") return new Template(this);
    if (tag.toLowerCase() === "canvas") return new Canvas(this);
    return new Element(this, tag);
  }

  importNode(node, deep) {
    if (node.nodeType === 3) return new TextNode(this, node.data);
    const copy = this.createElement(node.nodeName.toLowerCase());
    for (const { name, value } of node.attributes) copy.setAttribute(name, value);
    copy.value = node.value;
    copy.checked = node.checked;
    copy.type = node.type;
    if (deep) for (const child of node.childNodes) copy.appendChild(this.importNode(child, true));
    return copy;
  }
}

// The ruler layout asks thousands of times a frame. Three fifths of the
// size per character is the Zig harness's own stand-in: wrong for a
// page, fine for a check that asserts nothing about where text wrapped.
class Canvas extends Element {
  constructor(doc) {
    super(doc, "canvas");
    this.font = "";
  }

  getContext() {
    const self = this;
    return {
      set font(value) {
        self.font = value;
      },
      get font() {
        return self.font;
      },
      measureText(text) {
        const size = parseInt(/(\d+)px/.exec(self.font)?.[1] ?? "16", 10);
        return { width: (text.length * size * 3) / 5 };
      },
    };
  }
}

// ---- storage -----------------------------------------------------

/// sessionStorage, and the two ways a browser refuses it: `blocked`
/// throws on every access the way a disabled-storage setting does, and
/// `full` accepts reads and throws on a write the way a quota does.
class Storage {
  constructor(entries = {}) {
    this.map = new Map(Object.entries(entries));
    this.full = false;
  }

  get length() {
    return this.map.size;
  }

  key(i) {
    return [...this.map.keys()][i] ?? null;
  }

  getItem(k) {
    return this.map.has(k) ? this.map.get(k) : null;
  }

  setItem(k, v) {
    if (this.full) throw new Error("QuotaExceededError");
    this.map.set(k, String(v));
  }

  removeItem(k) {
    this.map.delete(k);
  }

  clear() {
    this.map.clear();
  }
}

// ---- time --------------------------------------------------------

/// Every timer the driver sets, under the harness's hand: the oauth
/// popup poll is a 400 ms interval and its grace is a 100 ms timeout,
/// and a check that waited them out in real seconds would be a check
/// people run less often. `advance` is what a browser's clock does,
/// stated rather than slept through.
class Clock {
  constructor() {
    this.now = 0;
    this.next = 1;
    this.timers = new Map();
  }

  set(fn, delay, repeat) {
    const id = this.next++;
    this.timers.set(id, { fn, at: this.now + (delay || 0), every: repeat ? delay || 0 : 0 });
    return id;
  }

  clear(id) {
    this.timers.delete(id);
  }

  /// Fires everything due in the window, in time order, including what
  /// a fired timer schedules inside it.
  advance(ms) {
    const until = this.now + ms;
    for (;;) {
      let soonest = null;
      for (const [id, t] of this.timers) {
        if (t.at <= until && (soonest === null || t.at < this.timers.get(soonest).at)) soonest = id;
      }
      if (soonest === null) break;
      const timer = this.timers.get(soonest);
      this.now = timer.at;
      if (timer.every) timer.at = this.now + timer.every;
      else this.timers.delete(soonest);
      timer.fn();
    }
    this.now = until;
  }

  get pending() {
    return this.timers.size;
  }
}

// ---- events, windows, and the globals --------------------------

class Listeners {
  constructor() {
    this.listeners = new Map();
  }

  addEventListener(type, handler) {
    if (!this.listeners.has(type)) this.listeners.set(type, []);
    this.listeners.get(type).push(handler);
  }

  removeEventListener(type, handler) {
    const list = this.listeners.get(type) ?? [];
    const at = list.indexOf(handler);
    if (at >= 0) list.splice(at, 1);
  }

  dispatchEvent(event) {
    for (const handler of [...(this.listeners.get(event.type) ?? [])]) handler(event);
    return true;
  }
}

/// A window this one opened. It is not a page — nothing loads in it —
/// because what the driver does with it is exactly three things: hold
/// it, compare a message's `source` against it, and close it. A popup
/// that ran the app would be a second instance of everything and would
/// prove nothing more.
class Popup extends Listeners {
  constructor(url, name) {
    super();
    this.url = url;
    this.name = name;
    this.closed = false;
  }

  close() {
    this.closed = true;
  }
}

class Location {
  constructor(href) {
    this.assigned = [];
    this.set(href);
  }

  set(href) {
    const url = new URL(href);
    this.href = url.href;
    this.origin = url.origin;
    this.protocol = url.protocol;
    this.host = url.host;
    this.hostname = url.hostname;
    this.pathname = url.pathname;
    this.search = url.search;
    this._hash = url.hash;
  }

  get hash() {
    return this._hash;
  }

  /// Assigning the fragment is what a page does to itself, and in a
  /// browser it fires `hashchange` — the harness fires it, so a test
  /// says when the reader pressed Back and when it merely re-addressed.
  set hash(value) {
    const url = new URL(this.href);
    url.hash = value;
    this.set(url.href);
  }

  assign(href) {
    this.assigned.push(href);
    this.set(new URL(href, this.href).href);
  }

  toString() {
    return this.href;
  }
}

/**
 * Install a browser on the globals and hand back its controls.
 *
 * One call is one page load. Everything a scenario can poke — the
 * clock, the storage, the window that opened this one, the popups this
 * one opened, the warnings the console took — is on the returned
 * object, so a scenario never reaches into a global to say what
 * happened.
 */
export function makeBrowser({
  site,
  href = "https://app.example/",
  storage = new Storage(),
  storageBlocked = false,
  opener = null,
  popupBlocked = false,
  language = "en-US",
} = {}) {
  const document = new Document();
  const location = new Location(href);
  const clock = new Clock();
  const target = new Listeners();
  const warnings = [];
  const popups = [];
  const closes = [];
  const fetches = [];
  const serviceWorkers = [];

  const window = new Proxy(
    {
      opener,
      closed: false,
      location,
      document,
      innerHeight: 800,
      innerWidth: 480,
      addEventListener: (t, h) => target.addEventListener(t, h),
      removeEventListener: (t, h) => target.removeEventListener(t, h),
      dispatchEvent: (e) => target.dispatchEvent(e),
      close: () => {
        closes.push(clock.now);
        window.closed = true;
      },
      open: (url, name) => {
        if (popupBlocked) return null;
        const popup = new Popup(url, name);
        popups.push(popup);
        return popup;
      },
    },
    {
      // `"PushManager" in window` and its kind: a stub window answers
      // "no such API" for everything it does not carry, which is the
      // honest report from a browser without one.
      has: (obj, key) => key in obj,
    },
  );

  const sessionStorage = storage;
  const globals = {
    window,
    document,
    location,
    history: {
      entries: [],
      pushState(state, title, url) {
        this.entries.push({ push: true, url });
        location.set(new URL(url, location.href).href);
      },
      replaceState(state, title, url) {
        this.entries.push({ push: false, url });
        location.set(new URL(url, location.href).href);
      },
    },
    navigator: {
      language,
      // Registration only: the URL is recorded exactly as handed over,
      // because *what* the driver asks for is the property under test —
      // the site publishes pages under /route/, so a page-relative name
      // here is the 404 the scenario asserts against. No worker runs;
      // `PushManager` stays absent, so the push probe still answers no.
      serviceWorker: {
        register: (url) => {
          serviceWorkers.push(String(url));
          return Promise.resolve({});
        },
        addEventListener() {},
      },
    },
    innerHeight: window.innerHeight,
    innerWidth: window.innerWidth,
    matchMedia: () => ({ matches: false, addEventListener() {}, removeEventListener() {} }),
    Node: { ELEMENT_NODE: 1, TEXT_NODE: 3, DOCUMENT_FRAGMENT_NODE: 11 },
    crypto: webcrypto,
    addEventListener: (t, h) => target.addEventListener(t, h),
    removeEventListener: (t, h) => target.removeEventListener(t, h),
    dispatchEvent: (e) => target.dispatchEvent(e),
    setTimeout: (fn, ms) => clock.set(fn, ms, false),
    setInterval: (fn, ms) => clock.set(fn, ms, true),
    clearTimeout: (id) => clock.clear(id),
    clearInterval: (id) => clock.clear(id),
    // The site's files, by the URL the page would ask for them at.
    // Nothing here is a network: a fetch is a read of the directory the
    // build just wrote.
    fetch: async (url) => {
      fetches.push(String(url));
      const path = site + new URL(url, location.href).pathname;
      const bytes = readFileSync(path);
      return {
        url: String(url),
        ok: true,
        arrayBuffer: async () => bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.length),
        text: async () => bytes.toString("utf8"),
      };
    },
  };

  // A storage a browser refuses is one whose *property access* throws,
  // which is the shape Safari's private mode and a disabled-storage
  // setting both take — and the shape services.js wraps every touch of
  // in a try. Defined rather than assigned, because a throwing getter
  // is the whole of the fault being simulated.
  if (storageBlocked) {
    Object.defineProperty(globalThis, "sessionStorage", {
      configurable: true,
      get() {
        throw new Error("SecurityError: storage is disabled");
      },
    });
  } else {
    Object.defineProperty(globalThis, "sessionStorage", {
      configurable: true,
      writable: true,
      value: sessionStorage,
    });
  }

  for (const [name, value] of Object.entries(globals)) {
    Object.defineProperty(globalThis, name, { configurable: true, writable: true, value });
  }

  // A browser compiles a module while it downloads; node has the
  // instantiation and not the streaming, so the one line that differs
  // is written here rather than worked around in the driver. Installed
  // for the life of the process, like every global above: one run of
  // this harness is a series of page loads, never a page and then
  // something else.
  WebAssembly.instantiateStreaming = async (source, imports) =>
    WebAssembly.instantiate(await (await source).arrayBuffer(), imports);

  // The one warning any of this code emits is the dropped mirror
  // write, and a scenario asserts it — so it is collected rather than
  // printed, and the transcript stays the scenario list.
  console.warn = (...args) => warnings.push(args.join(" "));

  return {
    window,
    document,
    location,
    clock,
    storage,
    warnings,
    popups,
    /// Every URL the page asked for. A popup that reports to its opener
    /// must not appear here at all — it never boots an app.
    fetches,
    /// Every service-worker registration, the URL as the driver passed
    /// it — a relative string would appear here as the bare string a
    /// browser would misresolve against the page.
    serviceWorkers,
    /// How many times this window closed itself — the popup half of the
    /// oauth flow ends with exactly one.
    get closes() {
      return closes.length;
    },
    /// The page the driver mounts into. Its width is what core lays out
    /// against, which is the only thing about it that is not furniture.
    mountPoint(width = 480) {
      const into = document.createElement("div");
      into.clientWidth = width;
      document.body.appendChild(into);
      return into;
    },
    /// A whole file, served: the markup a generator wrote is parsed and
    /// becomes this page, `<html>` attributes and all. A driver that
    /// boots over a page it already published mounts into elements the
    /// *file* wrote, not into a bare div — and what survives that
    /// handover is only a question you can ask of a document that was
    /// parsed rather than assembled.
    ///
    /// The one thing it does not do is run the page's own scripts: the
    /// boot call is the scenario's, because a scenario has to hold the
    /// nodes from before the mount to say anything about after it.
    openPage(html) {
      const parsed = parseHtml(document, html);
      const root = parsed.querySelector("html") ?? parsed;
      for (const { name, value } of root.attributes ?? []) {
        document.documentElement.setAttribute(name, value);
      }
      const body = root.querySelector("body") ?? root;
      // The body's own attributes and not only its children. It carried
      // a class for three revisions, saying whether anything of the
      // driver's stood below the screen, and the reserve was selected on
      // it; the assertion now is that a generated page's body carries
      // *nothing*, which needs the attributes read just the same.
      document.body.attrs = new Map();
      for (const { name, value } of body.attributes ?? []) document.body.setAttribute(name, value);
      document.body.childNodes = [];
      for (const child of [...body.childNodes]) document.body.appendChild(child);
      return document.body;
    },
    /// A press, through the document: the element carrying this label
    /// is found, a click is dispatched on it, and everything after that
    /// is the driver's — which is the point, because the alternative is
    /// calling an export and skipping the half under test.
    press(label) {
      const button = document.body
        .querySelectorAll("button")
        .find((el) => el.textContent.includes(label));
      if (!button) throw new Error(`web_browser.mjs: no button labelled "${label}"`);
      button.dispatchEvent(new PageEvent("click"));
    },
    /// A message from another window, exactly as posted: the origin and
    /// the source are the scenario's to state, because which ones are
    /// accepted is the security property under test.
    postToPage({ data, origin = location.origin, source = null }) {
      target.dispatchEvent(Object.assign(new PageEvent("message"), { data, origin, source }));
    },
    /// The reader typing a fragment, or pressing Back onto one. The URL
    /// as it stood when the event fired is returned, because the
    /// driver's own listeners may move the address bar again before
    /// the scenario looks (a fragment the router cannot honor is put
    /// back the way it was).
    hashChange(hash) {
      location.hash = hash;
      const href = location.href;
      target.dispatchEvent(new PageEvent("hashchange"));
      return href;
    },
    /// The reader changing their browser's language after the page
    /// loaded. `navigator.language` moves first and the event follows,
    /// which is the order a browser does it in — a driver that read the
    /// old value would see the old value.
    languageChange(tag) {
      globals.navigator.language = tag;
      target.dispatchEvent(new PageEvent("languagechange"));
    },
    /// Microtasks the driver queued (`queueMicrotask`, a promise's
    /// `then`) run when the stack unwinds; node's own timers are
    /// untouched by the fake clock, so this is a real turn of its loop.
    async settle() {
      await new Promise((resolve) => setImmediate(resolve));
    },
  };
}

export class PageEvent {
  constructor(type) {
    this.type = type;
    this.defaultPrevented = false;
    this.target = null;
  }

  preventDefault() {
    this.defaultPrevented = true;
  }
}

export { Storage };
