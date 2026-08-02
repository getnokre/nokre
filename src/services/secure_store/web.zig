//! The web backend: a static in-wasm table is the store, sessionStorage
//! is only its shadow. Reads never leave wasm; writes mutate the table
//! synchronously (the table is the truth the app reads back), then
//! mirror out best-effort through the nokre_ss_mirror_* imports,
//! implemented in render/dom/services.js — which owns the sessionStorage
//! schema, so both directions of the shadow share one home. Seeding runs
//! the other way at boot: live.js scans every "nokre.ss." key
//! (services.js's seedSecureStore) and pours them through the seed
//! exports below strictly before nokre_dom_boot — so a boot-time get
//! inside the first build answers synchronously, no handshake.
//! Every outcome here is a pure function of arguments + prior calls;
//! error.Unavailable never occurs on the web — stated posture
//! (docs/services.md), not a bug.

const std = @import("std");
const options = @import("nokre_secure_store_options");
const secure_store = @import("secure_store.zig");

const ValueBuf = secure_store.ValueBuf;
const ListBuf = secure_store.ListBuf;
const max_key_bytes = secure_store.max_key_bytes;
const max_value_bytes = secure_store.max_value_bytes;
const max_entries = secure_store.max_entries;

// The browser-storage key is "nokre.ss." + pkg_id + "/" + key — "/"
// is outside both the key charset and reverse-DNS ids, so namespaces
// can never alias (com.a vs com.a.b); Windows TargetName uses the
// same join. This file only ever sees the suffix after "nokre.ss.".
const prefix = options.namespace ++ "/";

// Implemented by services.js: writes sessionStorage inside try/catch —
// a blocked or full storage drops the mirror write with one warn, and
// only reload-survival is lost, which was never in the sync contract.
extern fn nokre_ss_mirror_set(k_ptr: [*]const u8, k_len: usize, v_ptr: [*]const u8, v_len: usize) void;
extern fn nokre_ss_mirror_del(k_ptr: [*]const u8, k_len: usize) void;

// One wasm instance is one app, so the table is per-App by
// construction — zero cross-app module state. 256 × (128 + 2560)
// ≈ 673 KiB of linear memory (.bss, so nothing in the download), the
// price of a store that answers synchronously *and* keeps answering
// when sessionStorage is blocked — the table is the truth, the shadow
// is optional, which is why the web leg has no Unavailable. Present
// only when linked, because only linked builds analyze this file.
const Entry = struct {
    key_len: u8,
    value_len: u16,
    key: [max_key_bytes]u8,
    value: [max_value_bytes]u8,

    fn keySlice(self: *const Entry) []const u8 {
        return self.key[0..self.key_len];
    }
};

var table: [max_entries]Entry = undefined;
var table_len: usize = 0;

pub fn get(key: []const u8, buf: *ValueBuf) ?[]const u8 {
    const i = find(key) orelse return null;
    const v = table[i].value[0..table[i].value_len];
    @memcpy(buf[0..v.len], v);
    return buf[0..v.len];
}

pub fn set(key: []const u8, value: []const u8) void {
    put(key, value);
    var full: [full_key_cap]u8 = undefined;
    const k = fullKey(&full, key);
    nokre_ss_mirror_set(k.ptr, k.len, value.ptr, value.len);
}

pub fn delete(key: []const u8) void {
    if (find(key)) |i| {
        table_len -= 1;
        table[i] = table[table_len];
    }
    // Mirror unconditionally: the promise is the postcondition ("no
    // such entry"), and an unconditional removeItem means the boot
    // snapshot can never resurrect what the table dropped.
    var full: [full_key_cap]u8 = undefined;
    const k = fullKey(&full, key);
    nokre_ss_mirror_del(k.ptr, k.len);
}

pub fn list(buf: *ListBuf) []const []const u8 {
    var off: usize = 0;
    for (0..table_len) |i| {
        const k = table[i].keySlice();
        @memcpy(buf.bytes[off..][0..k.len], k);
        buf.slices[i] = buf.bytes[off..][0..k.len];
        off += k.len;
    }
    // The table is append-ordered (delete swaps the tail in); the
    // sorted view the contract promises is produced here, like the
    // native leg's.
    std.mem.sort([]const u8, buf.slices[0..table_len], {}, keyLessThan);
    return buf.slices[0..table_len];
}

// secure_store.zig's StoreFull line consults these before a write.
pub fn contains(key: []const u8) bool {
    return find(key) != null;
}

pub fn count() usize {
    return table_len;
}

// ---- seeding (live.js, after instantiation, strictly before nokre_dom_boot) ----

// One entry's ferry: full key + value. An in-contract entry of this
// app's always fits; anything larger is by construction foreign or
// out of contract, and returning null tells the JS side to skip it.
const seed_scratch_cap = prefix.len + max_key_bytes + max_value_bytes;
var seed_scratch: [seed_scratch_cap]u8 = undefined;

comptime {
    // Reached from secure_store.zig's linked force block — nothing
    // else references this file — so unlinked wasm builds ship no
    // secure exports and services.js's `nokre_ss_seed` check skips
    // seeding entirely. Belt and braces: gate here too.
    if (options.linked) {
        @export(&nokreSsSeedScratch, .{ .name = "nokre_ss_seed_scratch" });
        @export(&nokreSsSeed, .{ .name = "nokre_ss_seed" });
    }
}

fn nokreSsSeedScratch(total_len: usize) callconv(.c) ?[*]u8 {
    if (total_len > seed_scratch.len) return null;
    return &seed_scratch;
}

fn nokreSsSeed(k_len: usize, v_len: usize) callconv(.c) void {
    if (k_len + v_len > seed_scratch.len) return; // never our ferry's
    const full = seed_scratch[0..k_len];
    const value = seed_scratch[k_len..][0..v_len];
    // The JS side is namespace-agnostic — it cannot know pkg_id before
    // wasm boots — so the filter to this app's entries lives here.
    if (!std.mem.startsWith(u8, full, prefix)) return;
    const key = full[prefix.len..];
    // sessionStorage is same-origin-writable: out-of-contract entries
    // are dropped at the door, the same refusal as native list's.
    if (!secure_store.validKey(key)) return;
    if (value.len > max_value_bytes) return;
    if (find(key) != null or table_len == max_entries) return;
    put(key, value);
}

// ---- table internals ----

fn find(key: []const u8) ?usize {
    for (0..table_len) |i| {
        if (std.mem.eql(u8, table[i].keySlice(), key)) return i;
    }
    return null;
}

/// Table write only — set() adds the mirror, seeding must not (the
/// entry just came from it).
fn put(key: []const u8, value: []const u8) void {
    const i = find(key) orelse blk: {
        // StoreFull ran in secure_store.zig; seeding checked its own cap.
        std.debug.assert(table_len < max_entries);
        table[table_len].key_len = @intCast(key.len);
        @memcpy(table[table_len].key[0..key.len], key);
        table_len += 1;
        break :blk table_len - 1;
    };
    table[i].value_len = @intCast(value.len);
    @memcpy(table[i].value[0..value.len], value);
}

const full_key_cap = prefix.len + max_key_bytes;

fn fullKey(buf: *[full_key_cap]u8, key: []const u8) []const u8 {
    @memcpy(buf[0..prefix.len], prefix);
    @memcpy(buf[prefix.len..][0..key.len], key);
    return buf[0 .. prefix.len + key.len];
}

fn keyLessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}
