// The stub's browser half: pick the reader's locale out of the bundled
// set and go to that locale's copy of this page. `Bundle.resolve`
// transcribed — exact tag (case and `-`/`_` ignored), then bare language
// in bundle order, then the fallback the bundle names.
//
// Every line's argument lives at document.zig's `localeStub` and is
// deliberately not repeated here. tests/locale_stub.mjs is what holds it
// to `L.resolve`.
//
// **A file a site serves, and a classic script.** It used to be written
// *inline* into every stub, which is what `script-src 'self'` exists to
// refuse — and a site with a stub per page cannot hash its way out, so
// the whole policy went to `'unsafe-inline'` for a script that is the
// library's own on every one of them. What differs per page is *data*,
// and the data is in the `application/json` block the emitter writes
// above this tag: a browser does not execute a data block, so no policy
// ever has to admit one. Classic and not a module because a module is
// deferred, and everything under this script is a page the reader is
// not meant to see.
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

nokreLocaleStub(JSON.parse(document.querySelector('script[data-nokre="locale"]').textContent));
