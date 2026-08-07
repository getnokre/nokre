// The boot a generated page runs: the same `App` over the same route
// table, landing on the file it wrote (dom-edition.md, "Live over a
// generated page").
//
// **It is a file for the reason packaging.zig's boot.js is one.** An
// inline `<script>` is what `script-src 'self'` exists to refuse, and a
// static site cannot hash its way out of one — every page's block
// carries its own route and its own locale, so a policy would have to
// name as many hashes as there are pages, and a header cannot. What
// differs per page is *data*, not code: this file is the code, once, and
// the `application/json` block beside it is the data. A browser does not
// execute a data block, so the policy never has to admit one.
//
// A module, so `mount` is a static import of the sibling the page just
// published beside it — the file name `live.js` is spelled here and
// checked against `driver_files.entry` at comptime, the way the class
// names live.js writes are (class_names.zig).
import { mount } from "./live.js";

// Spread, and only the two elements overridden. The block *is* the
// option set `mount` takes, written by document.zig out of one struct —
// so an option added on one side reaches the other with nothing here to
// update, and no second list of names can drift. The mounts travel as
// ids because a document is text: they are the driver's own names, the
// same two the markup above used.
const config = JSON.parse(document.querySelector('script[data-nokre="boot"]').textContent);
await mount({
  ...config,
  into: document.getElementById(config.into),
  content: document.getElementById(config.content),
});
