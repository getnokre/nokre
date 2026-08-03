//! The native extern surface: four nokre_ss_* verbs (secure_store.h,
//! implemented in macos.m, windows.c, linux.c and — over JNI —
//! android.c, or in dev.c when a build declares the dev file store,
//! which build.zig swaps in behind this same file) and the
//! code→error mapping. Policy stays out — validation, caps, and the
//! entry-count line all ran in secure_store.zig before any call lands
//! here; this file's one job beyond ferrying is list's determinism:
//! the OS enumerates in whatever order it likes, Zig sorts.

const std = @import("std");
const options = @import("nokre_secure_store_options");
const secure_store = @import("secure_store.zig");

const ValueBuf = secure_store.ValueBuf;
const ListBuf = secure_store.ListBuf;
const max_key_bytes = secure_store.max_key_bytes;
const max_entries = secure_store.max_entries;

const ns = options.namespace;

// Mirrors NOKRE_SS_* in secure_store.h.
const ok = 0;
const absent = 1;

extern fn nokre_ss_get(ns_ptr: [*]const u8, ns_len: usize, key: [*]const u8, key_len: usize, value_buf: [*]u8, value_len: *usize) i32;
extern fn nokre_ss_set(ns_ptr: [*]const u8, ns_len: usize, key: [*]const u8, key_len: usize, value: [*]const u8, value_len: usize) i32;
extern fn nokre_ss_delete(ns_ptr: [*]const u8, ns_len: usize, key: [*]const u8, key_len: usize) i32;
extern fn nokre_ss_list(ns_ptr: [*]const u8, ns_len: usize, list_buf: [*]u8, list_cap: usize) i32;

pub fn get(key: []const u8, buf: *ValueBuf) error{Unavailable}!?[]const u8 {
    // In/out: capacity in, stored length out. An external writer's
    // oversized blob comes back as UNAVAILABLE, never truncated —
    // the native side refuses to hallucinate it into the contract.
    var value_len: usize = buf.len;
    const rc = nokre_ss_get(ns.ptr, ns.len, key.ptr, key.len, buf, &value_len);
    if (rc == absent) return null;
    if (rc != ok) return error.Unavailable;
    return buf[0..value_len];
}

pub fn set(key: []const u8, value: []const u8) error{Unavailable}!void {
    if (nokre_ss_set(ns.ptr, ns.len, key.ptr, key.len, value.ptr, value.len) != ok)
        return error.Unavailable;
}

pub fn delete(key: []const u8) error{Unavailable}!void {
    const rc = nokre_ss_delete(ns.ptr, ns.len, key.ptr, key.len);
    // Deleting an absent key is the postcondition already met.
    if (rc != ok and rc != absent) return error.Unavailable;
}

pub fn list(buf: *ListBuf) error{Unavailable}![]const []const u8 {
    // Twice max_entries of scratch (66 KiB, this frame only): sort must
    // see everything before truncating, or "the first max_entries in
    // sorted order" would depend on OS enumeration order. Our own
    // writes can never exceed max_entries, so the doubling is headroom
    // against external writers; past it the subset is unspecified — the
    // OS itself cannot make that deterministic.
    const scratch_entries = 2 * max_entries;
    var scratch: [scratch_entries * (1 + max_key_bytes)]u8 = undefined;
    const rc = nokre_ss_list(ns.ptr, ns.len, &scratch, scratch.len);
    if (rc < 0) return error.Unavailable;

    var found: [scratch_entries][]const u8 = undefined;
    var n: usize = 0;
    var off: usize = 0;
    // The C side caps the packing by scratch BYTES, not by entry count
    // (macos.m's list_once), so `rc` can exceed `scratch_entries` when the
    // keys are short — thousands of two-byte keys fit the byte budget.
    // `found` is entry-indexed, so this walk must stop at whichever
    // limit lands first; trusting `rc` alone would let any process
    // writing short keys under the namespace overflow this frame's
    // stack. The byte bounds also hold even against an `rc` that lies
    // about the packing outright.
    for (0..@intCast(rc)) |_| {
        if (n == found.len or off >= scratch.len) break;
        const key_len: usize = scratch[off];
        if (key_len > scratch.len - off - 1) break;
        const key = scratch[off + 1 ..][0..key_len];
        off += 1 + key_len;
        // External writers can park out-of-contract keys in our
        // namespace; the service refuses to list what get() could
        // never be asked for.
        if (!secure_store.validKey(key)) continue;
        found[n] = key;
        n += 1;
    }
    std.mem.sort([]const u8, found[0..n], {}, keyLessThan);

    const kept = @min(n, max_entries);
    var bytes_off: usize = 0;
    for (found[0..kept], 0..) |key, i| {
        @memcpy(buf.bytes[bytes_off..][0..key.len], key);
        buf.slices[i] = buf.bytes[bytes_off..][0..key.len];
        bytes_off += key.len;
    }
    return buf.slices[0..kept];
}

fn keyLessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}
