// The stub's browser half: pick the reader's locale out of the bundled
// set and go to that locale's copy of this page. `Bundle.resolve`
// transcribed — exact tag (case and `-`/`_` ignored), then bare language
// in bundle order, then the fallback the bundle names.
//
// Every line's argument lives at document.zig's `localeStub` and is
// deliberately not repeated here: these bytes are written *inline* into
// every stub page, so a paragraph in this file is a paragraph on every
// page. tests/locale_stub.mjs is what holds it to `L.resolve`.
function nokreLocaleStub(c) {
  const norm = (t) => t.replace(/[A-Z]/g, (u) => u.toLowerCase()).replace(/-/g, "_");
  const language = (t) => t.split("_")[0];
  const want = norm(navigator.language || "");
  let i = c.tags.findIndex((t) => norm(t) === want);
  if (i < 0) {
    const lang = language(want);
    i = c.tags.findIndex((t) => language(norm(t)) === lang);
  }
  if (i < 0) i = c.fallback;
  const to = new URL(c.hrefs[i], location.href);
  if (!to.search) to.search = location.search;
  if (!to.hash) to.hash = location.hash;
  if (to.href !== location.href) location.replace(to.href);
}
