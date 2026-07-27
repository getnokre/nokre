# The http service

How the one-API-everywhere contract in [../services.md](../services.md)
is wired. The consumer surface is
[src/services/http/http.zig](../../src/services/http/http.zig); the
native transport is [native.zig](../../src/services/http/native.zig),
the web transport [web.zig](../../src/services/http/web.zig) plus the
fetch glue in [services.js](../../src/render/dom/services.js), and the
contract tests are
[http_test.zig](../../src/services/http/http_test.zig).

## One delivery lane, not two

A response must cross from wherever the transport runs to the UI
thread, in order, exactly once — which is the problem the workers
service already solved. So http does not build a second cross-thread
structure: a request opens a **one-shot delivery slot** in the workers
module (`openOneShot` in
[workers.zig](../../src/workers/workers.zig)) — the same slot table,
generation checks, lock-free queue, platform wake, pump, and shutdown,
with two twists:

- **Exactly one delivery.** The encoded `Result` frame is chased by a
  retired frame, so the slot frees itself right behind its one
  callback. Push order is FIFO order per producer, by the queue's
  contract, so the retire can never overtake the reply.
- **Cancellation is a generation bump.** `handle.cancel()` finalizes
  the slot immediately; anything still in flight fails the generation
  check at the pump and is dropped, frame and body freed. The callback
  provably cannot run again — there is no window where a late response
  sneaks through, because attribution is checked on the UI thread at
  delivery, not at send.

The wire type is the public `Result` itself — status, headers, body —
encoded with the worker codec; the body rides as a `Bytes` attachment,
so on native it moves whole from the request thread to the handler
with zero copies.

## The transports

| Transport | Where | Request | Response |
| --- | --- | --- | --- |
| mock | tests | parks in the app's mock, copies owned | the test's canned answer, delivered on the explicit pump |
| thread | native | one detached `std.Thread` per request, blocking on `std.http.Client` | `deliverOneShot` → queue → wake → pump |
| fetch | web | `nokre_http_js_send` → services.js → fetch on the main thread, beside the wasm instance | scratch → copy → `nokre_http_deliver` → queue → inline pump |

- **Native.** A thread you can see, like a worker — but one-shot and
  *detached*: a socket mid-read cannot be interrupted (the
  no-forced-kill rule), so joining would let a hung server hang
  shutdown. Cancellation and shutdown drop the delivery instead, and
  the thread ends on its own clock. Consequences wired on purpose: the
  `std.Io.Threaded` backend is refcounted (each request thread holds a
  reference until it exits, so the backend always outlives the
  detached threads that use it, and the last release tears it down —
  the exemption architecture.md grants it), each request runs its own
  `std.http.Client` with `keep_alive = false` (nothing pools across a
  detached thread's lifetime), and the response head is copied before
  the body reader invalidates it. Bodies decompress
  (gzip/deflate/zstd) before delivery — the browser decompresses too,
  one outcome. The transport deadline is a second thread you can see:
  a per-request watchdog sleeps out `deadline_seconds`, then claims
  the one delivery if the transfer has not (an atomic claim on the
  shared job — the one-shot slot alone cannot arbitrate two racing
  producers) and delivers `"TimedOut"`. No socket is touched; a
  transfer that finishes late loses the claim exactly the way a
  cancelled one loses the generation check.
- **Web.** fetch runs in services.js on the main thread, right beside
  the wasm instance the app boots on — there is no thread to cross at
  all. The
  landing is the worker-reply three beats: ask wasm for a scratch
  buffer (`nokre_http_scratch`), copy `[headers block][body]` in, call
  `nokre_http_deliver` with the split point — then the shared queue and
  an inline pump, exactly `deliverFromPost`'s shape. Request slices
  are decoded/copied *inside* the `nokre_http_js_send` call (services.js
  slices, never views), because fetch is async and the wasm-side
  borrows end on return. The body is read incrementally off the
  response's reader with `max_body` enforced per chunk — an
  overflowing (or never-ending) body aborts the fetch itself, so a
  rogue server cannot balloon the worker's JS heap while waiting for a
  whole body that never comes; native's `allocRemaining` limit is the
  same line drawn the same way. Cancel aborts the browser-side fetch
  as a courtesy to the network; correctness never depends on it — the
  rejection lands after the generation already bumped. The transport
  deadline rides the same abort: a `setTimeout` (30 s, mirroring
  `deadline_seconds` by hand across the language gap) fires
  `ctrl.abort()`, the fetch rejects, and the one `"FetchFailed"`
  lands — a timeout is a failure reason, and the browser hides those;
  the timer is cleared on every completion path.
- **Mock.** Under `zig test` the transport is the app's mock
  (`app.services.http`, constructed with the app): `request` parks
  owned copies of everything the app sent in *that app's* pending
  list; the test inspects and answers them — oldest-first
  (`fulfill`/`fail`) or by index (`fulfillAt`/`failAt`), which is what
  makes guarantee 2 concrete: the delivery interleaving under test
  control includes the reordering, so the stale-response race is two
  lines. Two apps are two disjoint networks by construction — no
  app-stamping, no filtering; the `onHttp`/`settleHttp` fake server
  ([../testing.md](../testing.md)) is the mock's own handler, so it
  cannot answer anyone else's traffic. `fulfill` honors `max_body`
  the way the real transports do, so the cap is testable. Every ask
  also lands in the mock's journal (method + url, request order,
  surviving fulfill/fail/cancel — `journal()`/`clearJournal()`, the
  harness's `httpJournal()`), the register every journaling mock
  keeps: "these requests, in this order" outlives the answers. The
  parked state dies with the app at `deinit`.

## Guarantees

1. Exactly one `Result` per request, on the UI thread, between events.
2. Completion order across requests, not request order — two requests
   race like they do in production, and only the delivery interleaving
   is under test control.
3. Values, not references: everything is copied at `request`; response
   slices are valid only for the callback; the body is a `Bytes` —
   `take()` moves it out whole.
4. After `cancel`, the callback never runs. Ever.
5. Failure is a value with a stable name. Status codes are data.
6. An app that issues no requests costs nothing: no thread, no Io
   backend, no JS state — the first request pays the setup.
7. A request ends. At most `deadline_seconds` (30) after `request`,
   its `Result` is on its way — `"TimedOut"` natively, the web's
   `"FetchFailed"` — unless the app cancelled first. The mock is the
   deliberate exception: parked requests stay parked, so time never
   becomes a hidden test input ([../services.md](../services.md) for
   the consumer contract).

## Refusals

- **No streaming, no progress.** A response is delivered whole or not
  at all. Streaming reintroduces per-chunk callbacks, backpressure
  knobs, and partial-state UI — and the browser and native stacks
  disagree enough that "equal outcome" would quietly die. `max_body`
  is the memory guarantee that makes whole-delivery safe.
- **No timeout knob.** The deadline exists (guarantee 7) but is not
  configurable: it is transport policy, one number for every request,
  not a per-request surface — and a knob would put a timer's worth of
  nondeterminism in the app's hands, where nokre keeps none. Sooner
  than 30 seconds is what `cancel` is for (a tap is an event; wire it).
- **No futures, no await** — the same disease workers refuse to treat
  with blocking.
- **No request priorities, no connection pooling contract.** The
  browser pools as it pleases; native deliberately doesn't. Pooling
  parity would be a promise the web cannot keep.
- **No cookies/auth magic.** Headers in, headers out; the browser adds
  what it adds (a stated posture difference, not a bug to fix).

## Deferred, not refused

Each returns only with its own argument: proxy support on native
(`std.http.Client` has it; nothing wires environment proxies yet),
upload/download progress (would ride the same lane as more one-shot
frames — but see the streaming refusal), and a shared native
connection pool behind a lock the app never sees.
