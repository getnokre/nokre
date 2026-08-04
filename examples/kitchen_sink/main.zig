//! Every nokre element on two screens, wired with real interactions.
//! This is the manual QA surface and the golden-test subject.
const std = @import("std");
const builtin = @import("builtin");
const h = @import("nokre");

const State = struct {
    app: *h.App = undefined,
    status_id: h.NodeId = .invalid,
    http_result_id: h.NodeId = .invalid,
    name_value: [128]u8 = undefined,
    name_len: usize = 0,
    // Two jobs the user can start independently get a worker each. One
    // worker is one inbox worked in order, so sharing it would put the
    // second job behind the first — and make the first yield to it
    // (`interrupted()` is true for anything queued). Fan-out is nokre's
    // answer to parallelism, and it is visible right here in the code
    // that owns it (docs/internals/workers.md).
    //
    // Each job owns the nodes that report it, too. They run at the same
    // time, so one shared meter would have two writers and show whoever
    // wrote last — a bar that jumps to 100% because the *other* job
    // finished is worse than no bar.
    primes: ?h.workers.Handle(Primes) = null,
    primes_button_id: h.NodeId = .invalid,
    primes_meter_id: h.NodeId = .invalid,
    primes_result_id: h.NodeId = .invalid,
    hasher: ?h.workers.Handle(Hasher) = null,
    hash_button_id: h.NodeId = .invalid,
    hash_result_id: h.NodeId = .invalid,
    // One in-flight request each. A reply names its request twice: the
    // `tag` echoes whatever identity the caller packed in, and the ctx
    // is whatever state the callback needs. These jobs carry per-request
    // *state* (whose button to give back), so the ctx does the work and
    // the tag stays 0 — a caller with shared state and many requests
    // would lean the other way.
    example_job: HttpJob = .{},
    nowhere_job: HttpJob = .{},
    // The server-backed switch and the value it is asking for. A switch
    // reports what the server holds, so the wanted value lives here
    // until the reply lands rather than on the control itself.
    notify_toggle_id: h.NodeId = .invalid,
    notify_wanted: bool = false,
    l10n_count: i64 = 1,
    l10n_text_id: h.NodeId = .invalid,
    l10n_items_id: h.NodeId = .invalid,
};

/// A request and the button that started it, together — what a result
/// callback needs to answer "whose reply is this?".
const HttpJob = struct {
    state: *State = undefined,
    button_id: h.NodeId = .invalid,
};

/// ARB catalogs compiled at comptime (docs/localization.md): the first
/// source is the template; Russian is here because its four plural
/// forms prove the CLDR validation is real, not en-shaped.
const L = h.l10n.Bundle(&.{
    @embedFile("l10n/sink_en.arb"),
    @embedFile("l10n/sink_fa.arb"),
    @embedFile("l10n/sink_ru.arb"),
});

/// Heavy synchronous compute belongs on a worker
/// (docs/internals/workers.md). Trial division on purpose: the point of
/// the demo is the freeze that doesn't happen.
/// Two jobs, two roles. Folding both into one role would put unrelated
/// arms in one `Reply` — and then the reply handler could only guess
/// which job answered, because `on_reply` is handed no worker identity
/// (workers.zig `SpawnOptions`). Separate roles make the answer a type:
/// a `Hasher.Reply` can only have come from the hasher.
const Primes = struct {
    pub const Msg = union(enum) {
        count_below: u64,
    };
    pub const Reply = union(enum) {
        progress: u8,
        counted: struct { below: u64, count: u64 },
        /// The count stopped early and sent no result — the worker is
        /// retiring, or a newer count superseded this one. Yielding
        /// silently would leave the app waiting on a reply that is never
        /// coming: `interrupted()` ends the work, so something has to
        /// say the work ended.
        abandoned,
    };

    pub fn init(_: std.mem.Allocator) !Primes {
        return .{};
    }
    pub fn deinit(_: *Primes) void {}

    pub fn handle(_: *Primes, msg: Msg, out: *h.workers.Outbox(Reply)) !void {
        switch (msg) {
            .count_below => |limit| {
                var count: u64 = 0;
                var next_report: u64 = 0;
                var n: u64 = 2;
                while (n < limit) : (n += 1) {
                    if (isPrime(n)) count += 1;
                    if (n >= next_report) {
                        // Stop when this count has stopped mattering:
                        // the app is retiring the worker (quitting must
                        // not wait on 20M trial divisions — shutdown
                        // joins this thread), or a newer count is
                        // queued, which makes this one stale before it
                        // exists. Never the *other* job — that has its
                        // own worker. Yield with a word, not in silence:
                        // whoever is waiting on the result is entitled
                        // to hear that none is coming.
                        if (out.interrupted()) return out.send(.abandoned);
                        try out.send(.{ .progress = @intCast(n * 100 / limit) });
                        next_report += limit / 20;
                    }
                }
                try out.send(.{ .counted = .{ .below = limit, .count = count } });
            },
        }
    }

    fn isPrime(n: u64) bool {
        if (n < 4) return n >= 2;
        if (n % 2 == 0) return false;
        var d: u64 = 3;
        while (d * d <= n) : (d += 2) {
            if (n % d == 0) return false;
        }
        return true;
    }
};

/// The other job: one message in, one reply out, no progress to report
/// and nothing to interrupt — which is why it is a role of its own and
/// not another arm on `Primes`.
const Hasher = struct {
    pub const Msg = union(enum) {
        /// The zero-copy handoff: the app moves this buffer here whole
        /// (no copy on native), and gets the very same one moved back.
        hash: h.workers.Bytes,
    };
    pub const Reply = union(enum) {
        hashed: struct { len: u64, digest: u64, payload: h.workers.Bytes },
    };

    pub fn init(_: std.mem.Allocator) !Hasher {
        return .{};
    }
    pub fn deinit(_: *Hasher) void {}

    pub fn handle(_: *Hasher, msg: Msg, out: *h.workers.Outbox(Reply)) !void {
        switch (msg) {
            .hash => |blob| {
                // FNV-1a — integer math, deterministic on every platform.
                var digest: u64 = 0xcbf29ce484222325;
                for (blob.view()) |byte| {
                    digest ^= byte;
                    digest *%= 0x100000001b3;
                }
                const kept = blob.take();
                try out.send(.{ .hashed = .{ .len = kept.len, .digest = digest, .payload = .adopt(kept) } });
            },
        }
    }
};

/// The closed worker set — the role routes play for screens. Root-level
/// so every thread's copy of the artifact finds the code from a wire id.
pub const nokreWorkers = .{ Primes, Hasher };

fn setText(state: *State, id: h.NodeId, comptime fmt: []const u8, args: anytype) void {
    var buf: [224]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, fmt, args) catch return;
    state.app.tree.setContent(id, msg) catch return;
    state.app.invalidate();
}

fn setStatus(state: *State, comptime fmt: []const u8, args: anytype) void {
    setText(state, state.status_id, fmt, args);
}

/// The button that started the job wears the `…` until its own reply
/// lands: pressed, working, and not to be pressed again. Only that
/// button — every job here reports itself, whether it is a worker or a
/// request.
fn setRunning(state: *State, pressed: h.NodeId, running: bool) void {
    const el = state.app.tree.get(pressed) orelse return;
    el.button.in_progress = running;
    // A percentage describes work in flight; when the work ends there is
    // nothing left for it to describe, and leaving one behind is a state
    // the audit fails on (`malformed_progress`) precisely because a
    // meter measuring nothing is worse than no meter.
    if (!running) el.button.progress_percent = null;
    state.app.invalidate();
}

fn setMeter(state: *State, id: h.NodeId, value: i32) void {
    const el = state.app.tree.get(id) orelse return;
    el.meter.value = value;
    state.app.invalidate();
}

/// One reading, two renderings: the number goes into the button that
/// started the work *and* into the standalone `meter` under it, on
/// purpose — a compact state inside the control, and the full-width bar
/// with words beside it, from the same source. The hash button gets
/// neither call: it reports no progress, and would rather say nothing
/// than invent a bar.
fn setCountProgress(state: *State, pct: u8) void {
    if (state.app.tree.get(state.primes_button_id)) |el| el.button.progress_percent = pct;
    if (state.app.tree.get(state.primes_meter_id)) |el| el.meter.value = pct;
    state.app.invalidate();
}

/// A notice whose description carries the result, for the jobs long
/// enough that the presser may have scrolled or navigated away.
fn notifyDone(state: *State, title: []const u8, comptime fmt: []const u8, args: anytype) void {
    var buf: [160]u8 = undefined;
    const desc = std.fmt.bufPrint(&buf, fmt, args) catch return;
    // Quiet: finished work is news to collect, not an interruption —
    // the presser already left the button behind.
    state.app.notify(.{
        .title = title,
        .description = desc,
        .route = "home",
        .icon = .circle_check,
    }) catch {};
}

fn save(state: *State) void {
    setStatus(state, "Saved.", .{});
}

// The sink links no services, so the sign-in buttons demonstrate the
// button, not the flow: a real app starts the oauth service here.
fn appleSignIn(state: *State) void {
    setStatus(state, "A real app would start the Apple flow here (docs/services.md).", .{});
}

fn googleSignIn(state: *State) void {
    setStatus(state, "A real app would start the Google flow here (docs/services.md).", .{});
}

/// A server-backed switch: the flip is a *request*, not a fact, so the
/// handler puts the value back where it found it and lets the track
/// stand down for `…` until the answer arrives. Nothing else on the row
/// changes and nothing beside it appears — this is the shape a status
/// line and a submit button used to stand in for.
fn toggleNotify(state: *State, checked: bool) void {
    const el = state.app.tree.get(state.notify_toggle_id) orelse return;
    el.toggle.on = !checked; // what the server still says
    el.toggle.in_progress = true;
    state.notify_wanted = checked;
    _ = h.services.http.request(.{
        .app = state.app,
        .url = "https://example.com/",
        .ctx = state,
        .on_result = onNotifyResult,
    }) catch {
        el.toggle.in_progress = false;
        setStatus(state, "Could not reach notification settings.", .{});
        return;
    };
    setStatus(state, "Turning notifications {s}…", .{if (checked) "on" else "off"});
    state.app.invalidate();
}

/// Both legs clear it, for the reason `onHttpResult` states: a switch
/// released only when the request succeeds is a switch stuck at `…` the
/// first time the network isn't there — and it is the one control on the
/// row that cannot be pressed to recover.
fn onNotifyResult(ctx: ?*anyopaque, _: u64, result: h.services.http.Result) void {
    const state: *State = @ptrCast(@alignCast(ctx.?));
    const el = state.app.tree.get(state.notify_toggle_id) orelse return;
    el.toggle.in_progress = false;
    switch (result) {
        // The value moves now, on the server's word and not on the tap.
        .response => {
            el.toggle.on = state.notify_wanted;
            setStatus(state, "Notifications {s}.", .{if (state.notify_wanted) "on" else "off"});
        },
        .failure => |f| setStatus(state, "Notification settings unchanged: {s}.", .{f.name}),
    }
    state.app.invalidate();
}

fn editName(state: *State, value: []const u8) void {
    state.name_len = @min(value.len, state.name_value.len);
    @memcpy(state.name_value[0..state.name_len], value[0..state.name_len]);
}

fn submitName(state: *State) void {
    setStatus(state, "Hello, {s}!", .{state.name_value[0..state.name_len]});
}

const delivery_options = [_][]const u8{ "Email", "SMS", "None" };

fn selectDelivery(state: *State, selected: usize) void {
    setStatus(state, "Delivery via {s}.", .{delivery_options[selected]});
}

const language_options = [_][]const u8{ "English", "Deutsch", "Français", "العربية" };

fn selectLanguage(state: *State, selected: usize) void {
    setStatus(state, "Language: {s}.", .{language_options[selected]});
}

// Long enough that its picker gains the framework's filter field.
const country_options = [_][]const u8{
    "Argentina", "Australia", "Austria", "Brazil", "Canada", "Denmark",
    "Germany",   "Iceland",   "Ireland", "Japan",  "Mexico", "Norway",
    "Portugal",  "Spain",     "Sweden",
    "Türkiye",
};

fn selectCountry(state: *State, selected: usize) void {
    setStatus(state, "Country: {s}.", .{country_options[selected]});
}

fn applyScheme(state: *State, scheme: h.Scheme) void {
    state.app.setScheme(scheme);
    setStatus(state, "Appearance: {s}.", .{@tagName(scheme)});
}

fn selectScheme(state: *State, selected: usize) void {
    applyScheme(state, switch (selected) {
        0 => h.Scheme.light,
        1 => h.Scheme.dark,
        else => h.Scheme.auto,
    });
}

fn showSheet(state: *State) void {
    const app = state.app;
    const sheet = app.presentSheet("Sheet demo") catch return;
    app.tree.append(sheet, .{ .text = .{ .content = "A modal bottom sheet. Everything behind is inert; Esc or a tap outside dismisses it and focus returns where it was." } }) catch return;
    app.tree.append(sheet, .{ .toggle = .{ .label = "A choice inside the sheet" } }) catch return;
}

fn notifySaved(state: *State) void {
    // Quiet: it joins the inbox behind the nav pane's indicator.
    state.app.notify(.{
        .title = "Settings saved",
        .description = "This notice stays until dismissed or minimized.",
        .route = "home",
        .icon = .circle_check,
    }) catch return;
}

fn notifySync(state: *State) void {
    // Important: it interrupts as the banner.
    state.app.notify(.{
        .title = "Sync failed",
        .description = "Changes are kept locally. Open to review them.",
        .route = "details",
        .icon = .cloud_off,
        .important = true,
    }) catch return;
}

fn countPrimes(state: *State) void {
    const worker = ensurePrimes(state) orelse return;
    worker.send(.{ .count_below = 20_000_000 }) catch return;
    setRunning(state, state.primes_button_id, true);
    setCountProgress(state, 0);
    setStatus(state, "Counting primes below 20,000,000…", .{});
    setText(state, state.primes_result_id, "Counting primes below 20,000,000…", .{});
}

/// Only the count reaches these nodes; the hash has its own. The status
/// line is the exception on purpose — it is the app's "last thing that
/// happened" log, and both jobs are entitled to write to it.
fn onPrimesReply(ctx: ?*anyopaque, reply: Primes.Reply) void {
    const state: *State = @ptrCast(@alignCast(ctx.?));
    switch (reply) {
        .progress => |pct| {
            setStatus(state, "Counting primes… {d}%", .{pct});
            setCountProgress(state, pct);
        },
        // The work ended without a result. Every path that ends the job
        // has to reach the button, not just the one that succeeds —
        // clearing `in_progress` only on success strands it at `…`
        // forever the first time a job yields.
        .abandoned => {
            setRunning(state, state.primes_button_id, false);
            setMeter(state, state.primes_meter_id, 0);
            setStatus(state, "Count stopped before it finished.", .{});
            setText(state, state.primes_result_id, "Count stopped before it finished.", .{});
        },
        .counted => |c| {
            setRunning(state, state.primes_button_id, false);
            setMeter(state, state.primes_meter_id, 100);
            setStatus(state, "{d} primes below {d}.", .{ c.count, c.below });
            setText(state, state.primes_result_id, "{d} primes below {d}.", .{ c.count, c.below });
            notifyDone(state, "Primes counted", "{d} primes below {d}.", .{ c.count, c.below });
        },
    }
}

fn ensurePrimes(state: *State) ?h.workers.Handle(Primes) {
    if (state.primes) |w| return w;
    const w = h.workers.spawn(Primes, .{
        .app = state.app,
        .ctx = state,
        .on_reply = onPrimesReply,
    }) catch return null;
    state.primes = w;
    return w;
}

fn hashPayload(state: *State) void {
    const worker = ensureHasher(state) orelse return;
    const size: usize = 32 * 1024 * 1024;
    const blob = state.app.gpa.alloc(u8, size) catch return;
    for (blob, 0..) |*b, i| b.* = @truncate(i *% 31 +% 7);
    worker.send(.{ .hash = .adopt(blob) }) catch {
        // Nothing moved on a failed send; the buffer is still ours.
        state.app.gpa.free(blob);
        return;
    };
    setRunning(state, state.hash_button_id, true);
    setStatus(state, "Hashing 32 MB on the worker…", .{});
    setText(state, state.hash_result_id, "Hashing 32 MB on the worker…", .{});
}

/// No meter here: the hash reports no progress, and a bar that sits at
/// zero and then jumps to full is an invention, not a measurement. The
/// `…` on the button is the honest signal, which is the whole point of
/// it.
fn onHashReply(ctx: ?*anyopaque, reply: Hasher.Reply) void {
    const state: *State = @ptrCast(@alignCast(ctx.?));
    switch (reply) {
        .hashed => |hd| {
            setRunning(state, state.hash_button_id, false);
            // Ownership came back with the reply; the free is ours.
            state.app.gpa.free(hd.payload.take());
            setStatus(state, "FNV-1a of {d} MB: {x:0>16} — buffer moved there and back.", .{ hd.len >> 20, hd.digest });
            setText(state, state.hash_result_id, "FNV-1a of {d} MB: {x:0>16} — buffer moved there and back.", .{ hd.len >> 20, hd.digest });
            notifyDone(state, "Payload hashed", "FNV-1a of {d} MB: {x:0>16}.", .{ hd.len >> 20, hd.digest });
        },
    }
}

fn ensureHasher(state: *State) ?h.workers.Handle(Hasher) {
    if (state.hasher) |w| return w;
    const w = h.workers.spawn(Hasher, .{
        .app = state.app,
        .ctx = state,
        .on_reply = onHashReply,
    }) catch return null;
    state.hasher = w;
    return w;
}

// Native language names, not translations: a reader lost in the wrong
// locale must be able to find their own.
const l10n_locale_options = [_][]const u8{ "English", "فارسی", "Русский" };

/// The chosen locale is App state (`App.setLocale`), not a State field:
/// one live fact, read wherever a catalog call needs the enum back.
fn chosenLocale(state: *const State) L.Locale {
    return L.resolve(state.app.locale());
}

fn refreshL10n(state: *State) void {
    const loc = chosenLocale(state);
    state.app.tree.setContent(state.l10n_text_id, L.tr(loc, .l10nGreeting)) catch return;
    var buf: [128]u8 = undefined;
    const items = L.fmt(&buf, loc, .l10nItems, .{ .count = state.l10n_count }) catch return;
    state.app.tree.setContent(state.l10n_items_id, items) catch return;
    state.app.invalidate();
}

fn selectL10nLocale(state: *State, selected: usize) void {
    const loc: L.Locale = switch (selected) {
        0 => .en,
        1 => .fa,
        else => .ru,
    };
    state.app.setLocale(L.tag(loc)) catch {};
    // Mirror the chrome to match the locale — Persian flips it, the
    // others keep it left-to-right (see docs/localization.md).
    state.app.setDirection(L.dir(loc));
    refreshL10n(state);
}

fn addL10nItem(state: *State) void {
    state.l10n_count += 1;
    refreshL10n(state);
}

fn removeL10nItem(state: *State) void {
    if (state.l10n_count > 0) state.l10n_count -= 1;
    refreshL10n(state);
}

/// A request is work a press started, so its button says so exactly as
/// the workers' do — and with no percentage, because HTTP here reports
/// none: `…` is the whole truth about a request in flight.
fn startRequest(job: *HttpJob, url: []const u8, comptime said: []const u8) void {
    const state = job.state;
    _ = h.services.http.request(.{
        .app = state.app,
        .url = url,
        // The job, not the app state: the result callback is handed only
        // this, and it has to know whose button to give back.
        .ctx = job,
        .on_result = onHttpResult,
    }) catch return;
    setRunning(state, job.button_id, true);
    setStatus(state, said, .{});
    setText(state, state.http_result_id, said, .{});
}

fn fetchExample(state: *State) void {
    startRequest(&state.example_job, "https://example.com/", "GET example.com…");
}

fn fetchNowhere(state: *State) void {
    // .invalid can never resolve (RFC 2606): the failure leg of the demo
    // works without needing the network to be down.
    startRequest(&state.nowhere_job, "https://nokre.invalid/", "GET nokre.invalid…");
}

/// The body's opening bytes, printable ASCII only: enough to recognize
/// the page by eye, without trusting network bytes to be valid UTF-8
/// or to fit the line (over-long unbroken words overflow, by design).
fn asciiPreview(bytes: []const u8, buf: []u8) []const u8 {
    const n = @min(bytes.len, buf.len);
    for (bytes[0..n], buf[0..n]) |b, *out| {
        out.* = if (b >= 0x20 and b < 0x7f) b else ' ';
    }
    return buf[0..n];
}

fn onHttpResult(ctx: ?*anyopaque, _: u64, result: h.services.http.Result) void {
    const job: *HttpJob = @ptrCast(@alignCast(ctx.?));
    const state = job.state;
    // Before the switch, so *both* legs clear it. The failure leg is the
    // one that matters: a button released only when the request succeeds
    // is a button stuck at `…` the first time the network isn't there —
    // and "GET nowhere" fails every time, on purpose.
    setRunning(state, job.button_id, false);
    switch (result) {
        .response => |r| {
            setStatus(state, "HTTP {d}: {d} bytes, {d} headers.", .{ r.status, r.body.view().len, r.headers.len });
            var preview_buf: [96]u8 = undefined;
            const preview = asciiPreview(r.body.view(), &preview_buf);
            setText(state, state.http_result_id, "HTTP {d}: {d} bytes, {d} headers. Body: {s}…", .{ r.status, r.body.view().len, r.headers.len, preview });
        },
        .failure => |f| {
            setStatus(state, "HTTP failed: {s}.", .{f.name});
            setText(state, state.http_result_id, "HTTP failed: {s}.", .{f.name});
        },
    }
}

fn buildHome(ctx: ?*anyopaque, app: *h.App) !void {
    const state: *State = @ptrCast(@alignCast(ctx.?));
    const tree = &app.tree;
    const root = tree.rootId();

    try tree.append(root, .{ .heading = .{ .level = .h1, .spans = &.{
        .{ .text = "Kitchen " },
        .{ .text = "Sink", .strong = true },
    } } });
    try tree.append(root, .{ .text = .{ .content = "Every element nokre has. There is no hover, no animation, no color — and nothing to configure." } });
    state.status_id = try tree.appendId(root, .{ .text = .{ .content = "Ready.", .style = .{ .scale = .small, .ink = .dark } } });
    try tree.append(root, .{ .divider = .{} });

    try tree.append(root, .{ .heading = .{ .content = "Type", .level = .h2 } });
    try tree.append(root, .{ .heading = .{ .content = "Subheading (h3)", .level = .h3 } });
    try tree.append(root, .{ .text = .{ .content = "Body prose wraps greedily at word boundaries and never hyphenates." } });
    try tree.append(root, .{ .text = .{ .content = "const answer = 42; // mono", .style = .{ .family = .mono } } });
    try tree.append(root, .{ .text = .{ .spans = &.{
        .{ .text = "Inline spans: " },
        .{ .text = "strong", .strong = true },
        .{ .text = ", " },
        .{ .text = "emphasis", .emphasis = true },
        .{ .text = ", and " },
        .{ .text = "code", .code = true },
        .{ .text = ", and " },
        .{ .text = "strike", .strike = true },
        .{ .text = " — one text node to assistive tech, so the words must read correctly without any of it." },
    } } });
    try tree.append(root, .{ .text = .{ .spans = &.{
        .{ .text = "A span with a route is an inline " },
        .{ .text = "link", .route = "details" },
        .{ .text = ": underlined, its own tab stop, and announced as a link — the one carve-out from the rule that spans are invisible." },
    } } });

    try tree.append(root, .{ .heading = .{ .content = "Deeper levels (h4, h5, h6)", .level = .h4 } });
    try tree.append(root, .{ .heading = .{ .content = "Every level is bold (h5)", .level = .h5 } });
    try tree.append(root, .{ .heading = .{ .content = "Weight, not size, separates these (h6)", .level = .h6 } });

    try tree.append(root, .{ .heading = .{ .content = "Lists", .level = .h3 } });
    const steps = try tree.appendId(root, .{ .list = .{ .ordered = true, .start = 9 } });
    for ([_][]const u8{
        "Ordinals are derived from the list, never authored.",
        "The marker column is sized for the widest one, so the words line up even when the count reaches double digits.",
        "Nesting is capped at three levels.",
    }) |line| {
        const step = try tree.appendId(steps, .{ .list_item = .{} });
        try tree.append(step, .{ .text = .{ .content = line } });
    }
    const bullets = try tree.appendId(root, .{ .list = .{} });
    const bullet = try tree.appendId(bullets, .{ .list_item = .{} });
    try tree.append(bullet, .{ .text = .{ .content = "Unordered items take the bullet at every depth —" } });
    const nested = try tree.appendId(bullet, .{ .list = .{} });
    const nested_item = try tree.appendId(nested, .{ .list_item = .{} });
    try tree.append(nested_item, .{ .text = .{ .content = "the indent is what carries the depth." } });

    try tree.append(root, .{ .heading = .{ .content = "Blockquote", .level = .h3 } });
    const quote = try tree.appendId(root, .{ .blockquote = .{} });
    try tree.append(quote, .{ .text = .{ .content = "A 1px rule on the leading edge and an indent. The rule is a drawn edge, so nothing bleeds across it." } });
    try tree.append(quote, .{ .text = .{ .content = "\u{2014} the attribution is words inside the quote, not a field on it", .style = .{ .scale = .small, .ink = .dark } } });

    try tree.append(root, .{ .heading = .{ .content = "Code block", .level = .h3 } });
    try tree.append(root, .{ .text = .{ .content = "Verbatim: whitespace preserved, never reflowed. A block wider than the page scrolls sideways — arrows when focused, a horizontal drag anywhere on it.", .style = .{ .scale = .small, .ink = .dark } } });
    try tree.append(root, .{ .code_block = .{
        .content =
        \\const std = @import("std");
        \\
        \\pub fn main() !void {
        \\    // This line is deliberately far too wide for any phone, so the block has something to scroll.
        \\    std.debug.print("nokre\n", .{});
        \\}
        ,
    } });

    try tree.append(root, .{ .heading = .{ .content = "Icons", .level = .h3 } });
    try tree.append(root, .{ .text = .{ .content = "Named Lucide glyphs, sized like text. Unlabeled ones are decorative; labeled ones read as images.", .style = .{ .scale = .small, .ink = .dark } } });
    const icon_row = try tree.appendId(root, .{ .stack = .{ .axis = .horizontal } });
    try tree.append(icon_row, .{ .icon = .{ .name = .accessibility, .label = "Accessibility" } });
    try tree.append(icon_row, .{ .icon = .{ .name = .activity } });
    try tree.append(icon_row, .{ .icon = .{ .name = .airplay, .scale = .h3 } });
    try tree.append(icon_row, .{ .icon = .{ .name = .alarm_clock_check, .scale = .h2, .ink = .dark } });
    try tree.append(icon_row, .{ .icon = .{ .name = .air_vent, .scale = .h1 } });

    const box = try tree.appendId(root, .{ .box = .{} });
    try tree.append(box, .{ .text = .{ .content = "A box: 1px border, 12px padding. Boxes group; they do not decorate." } });

    try tree.append(root, .{ .heading = .{ .content = "Badges", .level = .h3 } });
    const badge_row = try tree.appendId(root, .{ .stack = .{ .axis = .horizontal } });
    try tree.append(badge_row, .{ .badge = .{ .label = "Active" } });
    try tree.append(badge_row, .{ .badge = .{ .label = "Owner" } });
    try tree.append(badge_row, .{ .badge = .{ .label = "3 pending" } });

    try tree.append(root, .{ .heading = .{ .content = "Meter", .level = .h3 } });
    try tree.append(root, .{ .meter = .{ .label = "12 of 30 days", .value = 12, .max = 30 } });

    try tree.append(root, .{ .heading = .{ .content = "QR code", .level = .h3 } });
    try tree.append(root, .{ .qr = .{ .label = "Invite link", .value = "https://example.com/invite/XKCD-1234" } });

    try tree.append(root, .{ .heading = .{ .content = "Form", .level = .h2 } });
    try tree.append(root, .{ .text_input = .{
        .label = "Your name",
        .placeholder = "Type, then press Enter",
        .on_change = .bind(editName, state),
        .on_submit = .bind(submitName, state),
    } });
    try tree.append(root, .{ .text_input = .{
        .label = "Passphrase",
        .placeholder = "Obscured as you type",
        .obscured = true,
    } });
    state.notify_toggle_id = try tree.appendId(root, .{ .toggle = .{
        .label = "Notify me",
        .on_toggle = .bind(toggleNotify, state),
    } });
    try tree.append(root, .{ .checkbox = .{
        .label = "I agree to the terms",
    } });
    try tree.append(root, .{ .radio_group = .{
        .label = "Delivery",
        .options = &delivery_options,
        .on_select = .bind(selectDelivery, state),
    } });
    try tree.append(root, .{ .select = .{
        .label = "Language",
        .options = &language_options,
        .on_select = .bind(selectLanguage, state),
    } });
    try tree.append(root, .{ .select = .{
        .label = "Country",
        .options = &country_options,
        .on_select = .bind(selectCountry, state),
    } });
    try tree.append(root, .{ .text_area = .{
        .label = "Notes",
        .placeholder = "Anything else? Enter adds a line; the field grows.",
    } });
    try tree.append(root, .{ .copyable = .{
        .label = "Recovery code",
        .value = "XKCD-1234-QRST",
    } });

    // Nothing here asks for it: a row of actions that runs out of width
    // folds its tail behind "More" on its own. Narrow the window until
    // this one does.
    try tree.append(root, .{ .text = .{ .content = "A row of actions folds when it runs out of width: the last one still fully visible becomes More, and the sheet it opens holds it and everything after it. Narrow the window to watch it happen.", .style = .{ .scale = .small, .ink = .dark } } });
    const row_stack = try tree.appendId(root, .{ .stack = .{ .axis = .horizontal } });
    try tree.append(row_stack, .{ .button = .{ .label = "Save", .on_press = .bind(save, state) } });
    try tree.append(row_stack, .{ .button = .{ .label = "Cancel", .form = .{ .secondary = null } } });
    try tree.append(row_stack, .{ .button = .{ .label = "Add reminder", .form = .{ .filled = .alarm_clock_plus } } });
    try tree.append(row_stack, .{ .button = .{ .label = "Disabled", .disabled = true } });
    try tree.append(row_stack, .{ .link = .{ .label = "More details", .route = "details" } });

    try tree.append(root, .{ .text = .{ .content = "Icon-only buttons: a named glyph on the 24px target, label announced.", .style = .{ .scale = .small, .ink = .dark } } });
    const pager_row = try tree.appendId(root, .{ .stack = .{ .axis = .horizontal } });
    try tree.append(pager_row, .{ .button = .{ .label = "Previous month", .form = .{ .glyph = .chevron_left } } });
    try tree.append(pager_row, .{ .text = .{ .content = "March" } });
    try tree.append(pager_row, .{ .button = .{ .label = "Next month", .form = .{ .glyph = .chevron_right } } });

    try tree.append(root, .{ .heading = .{ .content = "Vendor sign-in", .level = .h3 } });
    // `provider` is rendering only — the sink links no services, and a
    // real flow would build its authorize URL and call the oauth
    // service from `on_press` (docs/services.md). The words are the
    // app's to supply, from the vendor's published strings. Google's G
    // is the one colored thing nokre ever draws; it is the renderer's,
    // and there is no way to ask for color anywhere else.
    try tree.append(root, .{ .text = .{ .content = "Conforming vendor buttons: the mark is nokre's to draw, the words are yours. Apple's flips black/white with the appearance; Google's G keeps the vendor's colors on either theme.", .style = .{ .scale = .small, .ink = .dark } } });
    try tree.append(root, .{ .button = .{
        .label = "Sign in with Apple",
        .form = .{ .provider = .apple },
        .on_press = .bind(appleSignIn, state),
    } });
    try tree.append(root, .{ .button = .{
        .label = "Sign in with Google",
        .form = .{ .provider = .google },
        .on_press = .bind(googleSignIn, state),
    } });

    try tree.append(root, .{ .heading = .{ .content = "Tiles", .level = .h2 } });
    const tiles = try tree.appendId(root, .{ .tile_group = .{
        .description = "Row-shaped actions: a route tile navigates and carries a chevron, an action tile presses like a button. A description under the group wraps at the group width.",
    } });
    try tree.append(tiles, .{ .tile = .{
        .label = "More details",
        .detail = "A route tile: navigates, chevron and all",
        .route = "details",
    } });
    try tree.append(tiles, .{ .tile = .{
        .label = "Save",
        .on_press = .bind(save, state),
    } });

    try tree.append(root, .{ .heading = .{ .content = "Layers", .level = .h2 } });
    const layer_stack = try tree.appendId(root, .{ .stack = .{ .axis = .horizontal } });
    try tree.append(layer_stack, .{ .button = .{ .label = "Open sheet", .on_press = .bind(showSheet, state) } });
    try tree.append(layer_stack, .{ .button = .{ .label = "Notify quietly", .on_press = .bind(notifySaved, state) } });
    try tree.append(layer_stack, .{ .button = .{ .label = "Notify important", .on_press = .bind(notifySync, state) } });

    try tree.append(root, .{ .heading = .{ .content = "Workers", .level = .h2 } });
    try tree.append(root, .{ .text = .{ .content = "Heavy synchronous compute runs on a worker: messages out, replies back on the UI thread. Press, then keep scrolling — nothing freezes, and a notice carries the result in case you wandered off. Two jobs, two worker roles, two report lines: press both and they run side by side, neither waiting on nor cancelling the other. The count reports a percentage, so its button fills as it goes; the hash reports none, so its button says `…` and nothing it cannot know.", .style = .{ .scale = .small, .ink = .dark } } });
    // Each job reports into its own nodes, right under its own button:
    // two workers running at once cannot share one bar and one line
    // without lying about which of them the numbers belong to.
    state.primes_button_id = try tree.appendId(root, .{ .button = .{ .label = "Count primes", .on_press = .bind(countPrimes, state) } });
    // The same reading, rendered both ways on purpose: compact inside
    // the control, and full width with words beside it.
    state.primes_meter_id = try tree.appendId(root, .{ .meter = .{ .label = "Prime count progress", .value = 0, .max = 100 } });
    state.primes_result_id = try tree.appendId(root, .{ .text = .{ .content = "No count has run yet.", .style = .{ .scale = .small, .ink = .dark } } });
    state.hash_button_id = try tree.appendId(root, .{ .button = .{ .label = "Hash 32 MB", .on_press = .bind(hashPayload, state) } });
    state.hash_result_id = try tree.appendId(root, .{ .text = .{ .content = "No hash has run yet.", .style = .{ .scale = .small, .ink = .dark } } });

    try tree.append(root, .{ .heading = .{ .content = "HTTP", .level = .h2 } });
    try tree.append(root, .{ .text = .{ .content = "One request out from a tap; exactly one result back on the UI thread, in the same delivery lane as worker replies. The result lands below; the second button aims at a host that cannot exist. Both wear `…` while their request is out — with no percentage, because HTTP reports none — and the failing one gives its button back too.", .style = .{ .scale = .small, .ink = .dark } } });
    const http_row = try tree.appendId(root, .{ .stack = .{ .axis = .horizontal } });
    // Each button hands its own job to the request, and the job carries
    // the button back to the result.
    state.example_job = .{ .state = state, .button_id = try tree.appendId(http_row, .{ .button = .{ .label = "GET example.com", .on_press = .bind(fetchExample, state) } }) };
    state.nowhere_job = .{ .state = state, .button_id = try tree.appendId(http_row, .{ .button = .{ .label = "GET nowhere", .on_press = .bind(fetchNowhere, state) } }) };
    state.http_result_id = try tree.appendId(root, .{ .text = .{ .content = "No request has run yet.", .style = .{ .family = .mono, .scale = .small, .ink = .dark } } });

    try tree.append(root, .{ .heading = .{ .content = "Localization", .level = .h2 } });
    try tree.append(root, .{ .text = .{ .content = "ARB catalogs, compiled — no codegen, no runtime parsing. Every locale must translate every key, and plural forms are validated per locale: the Russian entry below would not build without all four of its forms.", .style = .{ .scale = .small, .ink = .dark } } });
    try tree.append(root, .{ .segmented = .{
        .label = "Catalog locale",
        .options = &l10n_locale_options,
        .selected = switch (chosenLocale(state)) {
            .en => 0,
            .fa => 1,
            .ru => 2,
        },
        .on_select = .bind(selectL10nLocale, state),
    } });
    state.l10n_text_id = try tree.appendId(root, .{ .text = .{ .content = L.tr(chosenLocale(state), .l10nGreeting) } });
    var l10n_buf: [128]u8 = undefined;
    const l10n_items = try L.fmt(&l10n_buf, chosenLocale(state), .l10nItems, .{ .count = state.l10n_count });
    state.l10n_items_id = try tree.appendId(root, .{ .text = .{ .content = l10n_items } });
    const l10n_row = try tree.appendId(root, .{ .stack = .{ .axis = .horizontal } });
    try tree.append(l10n_row, .{ .button = .{ .label = "Add item", .on_press = .bind(addL10nItem, state) } });
    try tree.append(l10n_row, .{ .button = .{ .label = "Remove item", .on_press = .bind(removeL10nItem, state) } });

    try tree.append(root, .{ .heading = .{ .content = "Appearance", .level = .h2 } });
    try tree.append(root, .{ .segmented = .{
        .label = "Appearance",
        .options = &.{ "Light", "Dark", "Automatic" },
        .selected = switch (app.scheme) {
            .light => 0,
            .dark => 1,
            .auto => 2,
        },
        .on_select = .bind(selectScheme, state),
    } });
    try tree.append(root, .{ .heading = .{ .content = "Overflow", .level = .h2 } });
    try tree.append(root, .{ .text = .{ .content = "A track wider than the screen scrolls to follow the selection.", .style = .{ .scale = .small, .ink = .dark } } });
    try tree.append(root, .{ .segmented = .{
        .label = "Month",
        .options = &.{ "January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December" },
    } });

    try tree.append(root, .{ .heading = .{ .content = "Shades", .level = .h2 } });
    try tree.append(root, .{ .text = .{ .content = "All thirteen grays, g0 to g12. The middle one is the 50-50 gray.", .style = .{ .scale = .small, .ink = .dark } } });
    const shade_row = try tree.appendId(root, .{ .stack = .{ .axis = .horizontal, .gap = 0 } });
    // The ramp is only readable whole — a swatch pushed off the right
    // edge takes one end of the scale with it — so the size comes from
    // the width instead of a constant. A swatch hugs its content, so
    // padding is the only knob: divide the row among the shades, less
    // an allowance for the whitespace glyph that gives each swatch its
    // line-box height (a space is not the same width in every font).
    // The floor keeps the narrowest phone's swatches distinguishable;
    // the cap keeps a desktop window a band, not thirteen slabs.
    // `setViewport` rebuilds, so a resize re-sizes them.
    const shades = @typeInfo(h.Gray).@"enum".fields;
    const row_w = app.viewport.w - 2 * 16; // the root stack's content width
    const swatch_pad = std.math.clamp(@divTrunc(@divTrunc(row_w, @as(i32, shades.len)) - 8, 2), 4, 16);
    inline for (shades) |f| {
        const swatch = try tree.appendId(shade_row, .{ .box = .{ .fill = @field(h.Gray, f.name), .border = false, .padding = swatch_pad } });
        try tree.append(swatch, .{ .text = .{ .content = " ", .style = .{ .scale = .small } } });
    }

    try tree.append(root, .{ .heading = .{ .content = "Table", .level = .h2 } });
    const table = try tree.appendId(root, .{ .table = .{} });
    const header = try tree.appendId(table, .{ .row = .{ .header = true } });
    for ([_][]const u8{ "Element", "Focusable" }) |label| {
        const cell = try tree.appendId(header, .{ .cell = .{} });
        try tree.append(cell, .{ .text = .{ .content = label } });
    }
    const rows = [_][2][]const u8{
        .{ "button", "yes" },
        .{ "text", "no" },
        .{ "scroll region", "yes" },
    };
    for (rows) |r| {
        const row = try tree.appendId(table, .{ .row = .{} });
        for (r) |cell_text| {
            const cell = try tree.appendId(row, .{ .cell = .{} });
            try tree.append(cell, .{ .text = .{ .content = cell_text } });
        }
    }

    try tree.append(root, .{ .heading = .{ .content = "Scroll", .level = .h2 } });
    // Not a round 120: that edge would land exactly on a line boundary
    // and the region would read as complete. 140 cuts line 5 mid-glyph
    // — the visible cut is the scrollability affordance.
    const scroll = try tree.appendId(root, .{ .scroll_region = .{ .height = 140 } });
    for (0..12) |i| {
        var buf: [32]u8 = undefined;
        const line = try std.fmt.bufPrint(&buf, "Scrollable line {d}", .{i + 1});
        try tree.append(scroll, .{ .text = .{ .content = line } });
    }
}

fn buildDetails(_: ?*anyopaque, app: *h.App) !void {
    const tree = &app.tree;
    const root = tree.rootId();
    try tree.append(root, .{ .heading = .{ .content = "Details", .level = .h1 } });
    try tree.append(root, .{ .text = .{ .content = "A second screen. Navigation is a stack; there are no transitions. The nav below is app chrome: it survives every route change." } });
    try tree.append(root, .{ .link = .{ .label = "Back home", .route = "home" } });

    // A parameterized screen (docs/routing.md): the reference carries the
    // id, so the two tiles below lead to two different screens through
    // one route. On the web each is its own address — `#ticket~2938`.
    try tree.append(root, .{ .heading = .{ .content = "Route arguments", .level = .h2 } });
    const group = try tree.appendId(root, .{ .tile_group = .{ .description = "Same route, different screens" } });
    for ([_]u32{ 2938, 4471 }) |id| {
        var ref: [16]u8 = undefined;
        var label: [24]u8 = undefined;
        try tree.append(group, .{ .tile = .{
            .label = try std.fmt.bufPrint(&label, "Ticket {d}", .{id}),
            .route = try std.fmt.bufPrint(&ref, "ticket~{d}", .{id}),
        } });
    }
}

/// Reads its own identity rather than app state — which is what lets the
/// entry underneath stay a *different* ticket when this one is popped.
fn buildTicket(_: ?*anyopaque, app: *h.App) !void {
    const tree = &app.tree;
    const root = tree.rootId();
    var title: [24]u8 = undefined;
    const id = app.routeArg(0) orelse "?";
    try tree.append(root, .{ .heading = .{
        .content = try std.fmt.bufPrint(&title, "Ticket {s}", .{id}),
        .level = .h1,
    } });
    try tree.append(root, .{ .text = .{ .content = "One route, one builder, one argument. The stack entry owns that argument, so popping back to a sibling ticket still knows which one it was." } });
}

/// Shaped like content fetched at runtime rather than written here: it
/// opens at `##`, jumps to `####`, and carries syntax the subset does
/// not cover. Nothing below is special-cased — `append` parses it and
/// hands back ordinary elements.
const terms_markdown =
    \\## Terms of Service
    \\
    \\Effective **today**. This whole screen is one `document` element:
    \\a label and a Markdown source, parsed at `append` and expanded into
    \\the same elements everything else on the [home screen](home) uses.
    \\
    \\#### What the subset covers
    \\
    \\1. Headings, rebased onto a gapless outline — this document starts
    \\   at `##` and jumps to `####`, and reads as h1 then h2.
    \\2. Paragraphs, **strong**, *emphasis*, ~~struck~~, and `code`.
    \\3. Lists, ordered and not:
    \\   - nested up to three levels
    \\   - deeper levels flatten rather than fail
    \\
    \\> Block quotes carry an attribution in words, not a field.
    \\> — nobody in particular
    \\
    \\```
    \\// Verbatim: whitespace preserved, never reflowed, and this line is
    \\// deliberately long enough that the block scrolls sideways.
    \\const doc = .{ .label = "Terms", .source = body };
    \\```
    \\
    \\| Construct | Becomes |
    \\| --- | --- |
    \\| `# ` | a heading |
    \\| `> ` | a block quote |
    \\
    \\---
    \\
    \\#### What it does not
    \\
    \\Everything else degrades to its literal source text, markers and
    \\all — ![an image](photo.png), <b>inline html</b>, and an external
    \\address like [support](mailto:help@example.com). Every byte
    \\survives exactly once, which is what makes it safe to point this at
    \\bytes nobody reviewed.
;

fn buildTerms(_: ?*anyopaque, app: *h.App) !void {
    try app.tree.append(app.tree.rootId(), .{ .document = .{
        .label = "Terms of Service",
        .source = terms_markdown,
    } });
}

const routes = [_]h.RouteDef{
    .{ .name = "home", .title = .{ .fixed = "Home" }, .build = buildHome },
    .{ .name = "details", .title = .{ .fixed = "Details" }, .build = buildDetails },
    .{ .name = "ticket", .title = .{ .fixed = "Ticket" }, .args = 1, .build = buildTicket },
    .{ .name = "terms", .title = .{ .fixed = "Terms of Service" }, .build = buildTerms },
};

// A destination is a route and a glyph: what it is called comes from
// the route table above, so the nav and the screen cannot disagree.
// The third title is long on purpose — these three fit a row on a
// desktop window and do not on a phone, so the one build demonstrates
// both nav shapes: the row, and the collapsed chip with its section
// picker (docs/elements.md#navigation-chrome).
const nav_items = [_]h.Destination{
    .{ .route = "home", .icon = .house },
    .{ .route = "details", .icon = .list },
    .{ .route = "terms", .icon = .scale },
};

const is_wasm = builtin.cpu.arch == .wasm32;
const is_android = builtin.abi.isAndroid();

// Emit the Android shell's nokre_* exports: main never touches nokre
// there (the Activity boots the app through them instead), so nothing
// else pulls the shell into the build. The web has the same problem and
// nokre forces it there itself, because on that platform *which* shell
// is a build-time declaration — the canvas one or the DOM edition's
// live driver (docs/internals/dom-edition.md), and an example has no
// business choosing.
comptime {
    if (is_android) _ = h.platform.backend;
    // The web's exports are nokre's to emit — which shell or edition
    // they belong to is a build-time declaration there, not a decision
    // an example makes. What an app still owes is the reference itself:
    // `main` never runs on the web, so without this nothing pulls the
    // library into the build at all.
    if (is_wasm) _ = h;
}

pub fn main() if (is_wasm) void else anyerror!void {
    if (comptime is_wasm) {
        // The browser never calls main — nokre_boot builds the app via
        // nokreWebBuild below — but zig's start code still wraps main
        // on wasm, and a void return keeps its error-logging io (not
        // freestanding-safe) out of the build.
        return;
    } else {
        // DebugAllocator's leak reports symbolize stack traces, which iOS
        // cannot link (see `panic` below); the shell never returns there
        // anyway, so leak checking has nothing to report.
        if (builtin.os.tag == .ios) return run(std.heap.c_allocator);
        var gpa_state: std.heap.DebugAllocator(.{}) = .init;
        defer _ = gpa_state.deinit();
        return run(gpa_state.allocator());
    }
}

fn run(gpa: std.mem.Allocator) !void {
    var state = State{};
    var app = try h.App.init(gpa, .{
        .viewport = .{ .w = 560, .h = 720 },
        .routes = &routes,
        .ctx = &state,
    });
    defer app.deinit();
    state.app = &app;
    try app.setNav(&nav_items);
    try app.navigate("home");

    try h.platform.run(&app, .{ .title = "nokre — kitchen sink" });
}

/// Android entry: the OS owns the event loop, so the JNI shell builds
/// the app from nokre_android_boot (src/platform/android/android.zig)
/// instead of `main`, which never runs there — the web bargain with an
/// Activity in place of the browser.
pub fn nokreAndroidBuild(gpa: std.mem.Allocator) !*h.App {
    return nokreWebBuild(gpa);
}

/// Web entry: the browser owns the event loop, so the wasm shell builds
/// the app from nokre_boot (src/platform/web/web.zig) instead of `main`,
/// which never runs there. Everything lives on the heap — no enclosing
/// stack frame outlives this call.
pub fn nokreWebBuild(gpa: std.mem.Allocator) !*h.App {
    const state = try gpa.create(State);
    errdefer gpa.destroy(state);
    state.* = .{};
    const app = try gpa.create(h.App);
    errdefer gpa.destroy(app);
    app.* = try h.App.init(gpa, .{
        .viewport = .{ .w = 560, .h = 720 },
        .routes = &routes,
        .ctx = state,
    });
    state.app = app;
    try app.setNav(&nav_items);
    try app.navigate("home");
    return app;
}

// Panic symbolication walks dyld with an API the iOS SDK no longer
// exposes to the linker; keep panics plain there. On wasm even
// simple_panic's stderr lock drags in OS-threaded io — trap instead;
// the browser console shows the wasm stack.
pub const panic = if (is_wasm)
    std.debug.no_panic
else if (builtin.os.tag == .ios)
    std.debug.simple_panic
else
    std.debug.FullPanic(std.debug.defaultPanic);
