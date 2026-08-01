// The compute half: one more instance of the same module, in a Worker,
// running one actor (docs/internals/workers.md).
//
// It never boots an app and never touches a document — a compute
// instance is the app's code with none of the app around it. What it
// answers to is two exports: `nokre_worker_boot`, once, and
// `nokre_worker_handle`, per frame.

import { silentHooks } from "./services.js";

let nk = null;
let closed = false;
const inbox = [];

// Frames buffer and drain on a self-posted task — the same task source
// a Worker message arrives on, so the drain lands *behind* every
// already-queued frame and `nokre_worker_js_pending` sees a burst
// before the first handler runs. Mid-frame arrivals stay invisible
// until the next boundary, which is the best-effort line workers.md
// draws.
const channel = new MessageChannel();
let draining = false;
channel.port1.onmessage = drain;

const memory = () => new Uint8Array(nk.memory.buffer);

self.onmessage = async (e) => {
  const msg = e.data;
  if (msg.t === "init") return boot(msg);
  if (msg.t === "frame") {
    inbox.push(new Uint8Array(msg.buf));
    schedule();
  }
};

async function boot(msg) {
  try {
    const hooks = {
      ...silentHooks(),
      // The reply leg. A copy, then a transfer: the bytes outlive this
      // call and a subarray would carry the whole heap across with it.
      nokre_worker_js_reply: (ptr, len) => {
        const copy = memory().slice(ptr, ptr + len);
        postMessage({ t: "reply", buf: copy.buffer }, [copy.buffer]);
      },
      nokre_worker_js_pending: () => inbox.length,
      nokre_worker_js_close: () => {
        closed = true;
      },
      // PKCE's randomness (services/oauth/pkce.zig): an actor is the
      // app's code, so it may mint a verifier too, and a verifier
      // without cryptographic randomness is not a verifier. A Worker
      // has the same synchronous CSPRNG the window has.
      nokre_oauth_js_random: (ptr, len) => {
        crypto.getRandomValues(memory().subarray(ptr, ptr + len));
      },
      // The clock (docs/services.md), for pkce's reason again: an actor
      // is the app's code, so it may stamp what it computes, and a
      // Worker's `Date.now()` is the page's.
      nokre_clock_js_now: () => Date.now(),
    };
    const source = await WebAssembly.instantiateStreaming(fetch(msg.wasm), { env: hooks });
    nk = source.instance.exports;
    if (!nk.nokre_worker_boot(msg.index)) throw new Error("nokre_worker_boot failed");
  } catch (err) {
    postMessage({ t: "died", message: String(err?.message ?? err) });
    self.close();
    return;
  }
  drain(); // frames that raced the async boot
}

function schedule() {
  if (!nk || closed || draining) return;
  draining = true;
  channel.port2.postMessage(0);
}

function drain() {
  draining = false;
  while (inbox.length && !closed) {
    const frame = inbox.shift();
    const ptr = nk.nokre_worker_scratch(frame.length);
    if (!ptr) continue;
    memory().set(frame, ptr);
    nk.nokre_worker_handle(ptr, frame.length);
  }
  if (closed) self.close();
}
