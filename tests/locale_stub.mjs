// The locale stub's own gate: `node tests/locale_stub.mjs <page> <table>`,
// which `zig build test` runs (build.zig's addLocaleStubCheck).
//
// The stub is the one page nokre writes where a decision the library
// owns is transcribed into JavaScript: `Bundle.resolve` cannot be called
// from a page that loads no wasm, so locale_stub.js repeats it. This
// file is what keeps the repeat honest — for every device tag in the
// table, the *page's own* script is executed against a browser that
// reports that tag, and where it navigates is compared with the answer
// `L.resolve` gave in Zig (tests/locale_stub.zig wrote both files).
//
// So nothing here states what the right locale is. The Zig side states
// it, the page decides it, and this compares them.

import assert from "node:assert/strict";
import fs from "node:fs/promises";
import vm from "node:vm";

const [pagePath, tablePath] = process.argv.slice(2);
if (!pagePath || !tablePath) {
  console.error("usage: node tests/locale_stub.mjs <page.html> <table.json>");
  process.exit(2);
}

const page = await fs.readFile(pagePath, "utf8");
const table = JSON.parse(await fs.readFile(tablePath, "utf8"));

// The script as the browser gets it: the bytes between the tags, not a
// re-import of the source file. A stub whose emitter mangled the data,
// or wrote the call wrong, fails here.
const opened = page.indexOf("<script>");
const closed = page.indexOf("</script>", opened);
assert.ok(opened !== -1 && closed !== -1, "the stub carries no script");
const script = page.slice(opened + "<script>".length, closed);

const origin = "https://nokre.test";

/// One load of the stub: a browser reporting `language`, standing at
/// `at`. Returns where the page sent it, or null if it stayed.
function load(language, at) {
  const url = new URL(at);
  let went = null;
  const location = {
    href: url.href,
    search: url.search,
    hash: url.hash,
    replace(to) {
      went = to;
    },
  };
  vm.runInNewContext(script, { navigator: { language }, location, URL });
  return went;
}

// ---- the resolution, against the bundle's own answers ----------------

for (const { language, href } of table.cases) {
  const went = load(language, `${origin}/docs/`);
  assert.equal(
    went,
    origin + href,
    `a browser reporting ${JSON.stringify(language)} was sent to ${went}, ` +
      `where L.resolve says ${origin + href}`,
  );
}

// ---- and the pass a small bundle cannot reach -----------------------
//
// `resolve`'s middle pass is bare language **in bundle order**, and with
// no two locales sharing a language it has one candidate — so a
// transcription that scanned backwards, or that preferred the bare tag,
// would pass every assertion above. The branch is only tested if the
// bundle can pose the question, and that is asserted here rather than
// assumed: a bundle that stopped posing it fails loudly instead of
// leaving the one line most likely to drift uncovered.

const norm = (t) => t.replace(/[A-Z]/g, (u) => u.toLowerCase()).replace(/-/g, "_");
const language = (t) => norm(t).split("_")[0];
const exact = (t) => table.tags.some((u) => norm(u) === norm(t));

const contested = table.cases.find(
  (c) =>
    !exact(c.language) &&
    table.tags.filter((t) => language(t) === language(c.language)).length > 1,
);
assert.ok(
  contested,
  "no device tag in the table reaches the bundle-order pass with more than " +
    "one candidate — the branch is untested, whatever the assertions above say",
);

// What Zig answered for it *is* the earliest candidate: the rule stated,
// not just the answer copied. A reordered ARB list that quietly made the
// two candidates equivalent fails here.
const earliest =
  table.hrefs[table.tags.findIndex((t) => language(t) === language(contested.language))];
assert.equal(
  contested.href,
  earliest,
  `L.resolve sent ${JSON.stringify(contested.language)} to ${contested.href}, ` +
    `which is not the earliest bundled locale of that language (${earliest})`,
);

// ---- what the page owes the reader ----------------------------------

// The no-JavaScript half is the document itself: every locale's copy is
// a plain link, so a reader whose script never ran is offered a choice
// rather than left on a blank page.
for (const href of table.hrefs) {
  assert.ok(
    page.includes(`href="${href}"`),
    `no plain link to ${href} behind the script`,
  );
}
for (const tag of table.tags) {
  assert.ok(page.includes(`hreflang="${tag}"`), `no link marked ${tag}`);
}

// The query and the fragment are the reader's. A shared `/docs/#seams`
// has to arrive at `/{locale}/docs/#seams`, or the link lost what it
// named. The destination is the table's, so this cannot drift from the
// bundle either.
assert.equal(
  load(contested.language, `${origin}/docs/?q=1#seams`),
  `${origin}${contested.href}?q=1#seams`,
);

// A stub standing at one of its own choices is a misconfiguration, and
// the answer to it is a page that stands still rather than a browser
// that spins. Once per locale, each at its own address, with a tag that
// resolves there.
for (const href of table.hrefs) {
  const arrives = table.cases.find((c) => c.href === href);
  assert.ok(arrives, `no device tag in the table resolves to ${href}`);
  assert.equal(load(arrives.language, origin + href), null);
}

console.error(
  `locale stub: ${table.cases.length} device tags, ${table.tags.length} locales — all ok`,
);
