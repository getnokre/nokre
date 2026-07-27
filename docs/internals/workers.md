# Workers

How the `worker` service in [../services.md](../services.md) is wired:
how a nokre app offloads heavy synchronous computation without giving
up the one-loop model. The consumer-facing API — the worker struct,
`spawn`/`send`/`retire`, `Outbox`, and `Bytes` — lives there; this doc
is the design and the per-platform delivery. The pure heart is
[src/workers/workers.zig](../../src/workers/workers.zig) (codec,
registry, framing, delivery) with the codec in
[codec.zig](../../src/workers/codec.zig), the native transport in
[thread.zig](../../src/workers/thread.zig), the web transport in
[post.zig](../../src/workers/post.zig) +
[services.js](../../src/render/dom/services.js)/[live-worker.js](../../src/render/dom/live-worker.js),
and the contract tests in
[workers_test.zig](../../src/workers/workers_test.zig). The kitchen
sink's "Workers" section is the live demo on every platform.

## The problem

App code runs entirely inside the UI thread's loop: an `Action` that
takes 200ms freezes taps, keys, and paint for 200ms. "An app at rest
costs zero CPU" has a sibling under load: the UI thread does nothing but
dispatch and paint. Indexing, search, parsing, media crunching — any
heavy synchronous work — needs another thread, and on the web another
wasm instance, without breaking what makes nokre nokre: app code that
never sees a thread, shells that stay dumb, and e2e tests that are
faithful by construction.

## The model: an app without a screen

The app's loop turns input events into state changes. A worker's loop
turns **messages** into **replies**. Same shape, no screen:

- The app sends typed messages; the worker handles them **one at a
  time, in order**, in its own single-threaded loop.
- The worker sends typed replies; they are delivered **on the UI
  thread, in order**, to a handler that is an `Action` in shape —
  ctx + function pointer, mutate state, `invalidate()`.
- **Nothing is shared.** Every message is serialized and copied across.
  On the web the two sides are separate wasm memories, so this is
  physics; native honors the same semantics on purpose.
- A worker at rest is parked at zero CPU and runs only downstream of a
  message — no timers, no self-wake. The reply stream is a causal
  function of the message stream.

The guarantee this buys, stated once and defended everywhere: **app
code never takes a lock and never runs off the UI thread.** Handlers,
actions, layout, and rendering interleave on one thread; worker state
needs no synchronization because only its own loop touches it. There is
no data race an app author can write.

Replies are deliberately *not* core `Event`s: `Event` is the input
vocabulary and core stays ignorant of threads (`zig build test` on a
bare toolchain must keep passing). A reply is app data arriving in app
code — its precedent is `Action`, not `tap`.

## Guarantees

1. **In order, exactly once**, both directions, per worker. No global
   order across workers.
2. **One message at a time.** A worker is single-threaded; its state
   needs no locks.
3. **Handlers run on the UI thread only**, between input events. App
   code remains single-threaded, full stop.
4. **Values, not references.** `send` copies at the call; a delivered
   message's slices are valid only for the handler call (arena-backed
   or views into the frame — the consumer obligation is the same). Or
   ownership moves whole: a transferred `Bytes` is reachable from
   exactly one side at any moment.
5. **Causality.** A worker runs only downstream of a message — no
   timers, no self-wake, no spontaneous replies. Given deterministic
   worker code, the reply *content* is a pure function of the message
   stream; the one nondeterminism is *when* replies interleave with
   input, and the testing story below puts exactly that under test
   control.
6. **Failure is a message.** `handle` returning an error drops that
   message, reports a `Fault` to spawn's optional `on_fault`, and the
   worker lives on. A dead worker (web OOM or trap; a native panic
   aborts the process like any other) is `Fault.died` and the handle is
   retired. No exceptions crossing threads, no poisoned locks.

## Messages

Message and reply types are checked at comptime by the codec. Allowed:
integers, bools, enums, floats, structs, arrays, optionals, tagged
unions, `[]const T` slices of allowed types — recursively — and
`h.workers.Bytes`, the transferable blob above.
Forbidden, with a curated compile error naming the offending field
path: pointers, untagged unions, error types, functions, `anyopaque`.
(Floats may cross — the transport copies bits, which is deterministic;
whether the *computation* behind them is cross-platform-deterministic
is the app's affair, and core stays integer regardless.)

The wire format is an internal detail — little-endian, u32 tags and
lengths — and is allowed to change freely, because both ends of every
channel are compiled from the same source in the same artifact. Same
artifact means **no schema-evolution problem, ever**: the codec never
meets bytes from another version of itself.

## One artifact per thread

There is no separate worker build. Native threads share the process
image by definition; on the web the app boots on the main thread
(live.js, `nokre_dom_boot`) and `spawn` starts a `Worker` on
live-worker.js that instantiates the **same wasm module** and enters it
at `nokre_worker_boot(index)` instead — the same artifact through a
different door. The
browser caches module compilation; each instance pays only its own
heap.

This is why `nokreWorkers` exists and lives in the root module: a
function pointer cannot cross a postMessage boundary, but an index into
a comptime tuple that both sides compiled identically can. Spawning
serializes "worker #1"; the fresh instance looks up the same tuple in
its own copy of the code. The declaration also closes the set — like
routes, what the app can spawn is legible in one place.

## Platform transports

The pure module (`src/workers/workers.zig`: codec, queues, registry,
handles — unit-tested with no dependencies) sits over a transport
chosen per app: all mutable service state — the slot table, the
delivery queue, the wake hook, and the inline/platform mode — is one
heap-pinned `Runtime` owned by the App (`app.runtime`, created at
`App.init`, torn down first at `App.deinit`). Handles and tickets
carry their runtime pointer, so two apps in one process have disjoint
worker services by construction — the architecture rule in
[architecture.md](architecture.md). The transports:

| Transport | Where | Send | Wake for delivery |
| --- | --- | --- | --- |
| inline | unit tests + harness (`Runtime.mode = .inline_pump`, the test-build default) | direct enqueue, no threads | tests pump explicitly |
| thread | native | mutex FIFO + condvar (parked at rest) | hop a pump call to the main thread |
| post | web | serialized buffer, **transferred** (one copy total) | postMessage is already a wake |

A test that wants real threads flips its own app to
`app.runtime.mode = .platform` — per-app state, so it is not a
cross-test hazard. The one process-level exemption is the
`std.Io.Threaded` backend serving the thread transport's futexes:
refcounted behind a spin-guard in `thread.zig`, created by the first
worker and torn down by the last, so leak-checked test binaries end
clean and two apps spawning from two threads cannot race its init.

- **Native.** `spawn` is one `std.Thread` per worker — a worker is a
  thread you can see, not a pool you tune. The only native-side need is
  the main-thread hop for delivery: on Apple platforms
  `dispatch_async_f(dispatch_get_main_queue(), …)` — an extern call,
  no `.m` file; on Windows the shell lends its message loop —
  `nokre_shell_post_main` posts the pump to the window procedure as a
  `WM_APP` message (the HWND is published atomically at `on_ready`,
  which also drains anything a boot-spawned worker queued before the
  window existed); Linux implements the same hook as the poll loop's
  wake eventfd, and Android as a pipe on the main thread's ALooper.
  The pump drains the reply queue, decodes, invokes handlers, then
  issues one `nokre_shell_request_frame` if anything invalidated.
- **Web.** The app runs on the main thread; `spawn` starts a sibling
  `Worker` on live-worker.js, which instantiates the same wasm module
  and calls `nokre_worker_boot(index)` instead of `nokre_dom_boot`.
  Each incoming message
  is `nokre_worker_handle(ptr, len)`; replies go out through a
  services.js
  import and land in the app instance as `nokre_worker_deliver`, which
  drains, decodes, and falls into the same repaint path every other
  message takes.

The delivery queue has one other customer: the http service parks
**one-shot slots** in the same table — same generation checks, wake,
pump, and shutdown — so a network response crosses to the UI thread on
exactly this machinery and no second cross-thread structure exists
([http.md](http.md)).

## Testing

The harness spawns workers inline: real `init`/`handle`/`deinit`, no
threads. `t.settleWorkers()` runs every queued message and delivers
every queued reply, to quiescence. Because delivery is explicit, a test
*is* an interleaving: send a query, type three more characters, then
settle — that's the race, reproduced exactly, every run. Async flows become
deterministic e2e tests by construction, the same trade the rest of the
testing story makes. Goldens are untouched: workers cannot reach the
tree, so pixels still come only from UI-thread code.

## Refusals

Like the rest of nokre, these are guarantees, not gaps:

- **No shared memory** — including SharedArrayBuffer + emscripten
  pthreads on web. That road requires COOP/COEP headers (breaking
  "serve `zig-out/web/` from any static host") and reintroduces the data
  races the model exists to delete. Copying
  is the price; the transferred buffer on web makes it one copy.
- **No futures, no await.** A future is a place to block, and blocking
  the UI thread is the disease this service treats. One control-flow
  style: events in, events out.
- **No thread pool, no work stealing.** Scheduling nondeterminism plus
  tuning knobs. Want parallelism? Spawn N workers and fan out — the
  concurrency is visible in the code that owns it.
- **No forced kill.** Native cannot safely kill a thread, so parity
  says nobody can; `interrupted()` is the cancellation contract. A
  worker that ignores it during long work has a bug, like an `Action`
  that loops forever — and so does one that yields *silently*: it is
  true for any waiting message, not only a newer version of the same
  job, so the app can be left waiting on a result no one will ever
  send. Reply on the way out.
- **No worker timers or self-wakes.** Replies stay causal and a worker
  at rest stays free — the no-ticker rule, kept on both sides of the
  boundary.
- **No IO in the contract.** Workers are compute actors. Native worker
  code may of course use `std` like any app code, but nokre adds no
  fetch/file affordances here; IO belongs to the app and its services
  (the `http` service, [http.md](http.md)).

## Deferred, not refused

Each returns only with its own argument: coalescing sends (newest
message replaces a queued unprocessed one — `interrupted()` covers the
known cases), worker-to-worker channels (today the app mediates, which
keeps the topology legible), and delivery priorities.
