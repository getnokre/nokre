//! PKCE (RFC 7636) and the `state` guard — the two values every
//! native-app flow needs and neither provider will generate for you.
//! Pure helpers over `std.crypto`, no service state and no linking: an
//! app that builds its authorize URL by hand can still use them, and an
//! app that never signs in never analyzes them.
//!
//! The determinism carve-out, stated once (docs/internals/oauth.md):
//! `docs/internals/contributing.md` forbids randomness *in core*,
//! because it breaks the pixel model. A service is not core, and a
//! verifier without cryptographic randomness is not a verifier. What
//! keeps tests byte-stable instead is the seed: under `zig test` these
//! read the app's oauth mock, so a screen that renders an authorize URL
//! renders the same one every run.

const std = @import("std");
const builtin = @import("builtin");
const app_mod = @import("../../core/app.zig");

const App = app_mod.App;
const is_wasm = builtin.cpu.arch == .wasm32;
const b64 = std.base64.url_safe_no_pad.Encoder;

/// 32 random bytes, base64url without padding: 43 characters, which is
/// RFC 7636 §4.1's minimum and the length every provider documents.
/// Not a knob — a shorter verifier is weaker for nothing, and a longer
/// one is the same security with more ways to trip a provider's parser.
pub const verifier_bytes = 43;
pub const VerifierBuf = [verifier_bytes]u8;

/// SHA-256 is 32 bytes, so the challenge is the same 43 characters.
pub const challenge_bytes = 43;
pub const ChallengeBuf = [challenge_bytes]u8;

/// 16 random bytes — a CSRF guard, not a key.
pub const state_bytes = 22;
pub const StateBuf = [state_bytes]u8;

/// The `code_challenge_method` value. `plain` exists in the RFC and is
/// not offered here: it is the mode that provides no protection at all
/// on a platform where another app can read the redirect, which is
/// exactly the platform this service runs on.
pub const method = "S256";

/// A fresh code verifier. Keep it — the token exchange sends it, and it
/// is the only thing proving the exchange comes from the app that
/// started the flow.
pub fn verifier(app: *const App, buf: *VerifierBuf) []const u8 {
    if (comptime builtin.is_test) return seeded(buf, app.services.oauth.state.?.verifier);
    var raw: [32]u8 = undefined;
    fill(&raw);
    return b64.encode(buf, &raw);
}

/// The challenge to put in the authorize URL: base64url(SHA-256(v)).
pub fn challenge(v: []const u8, buf: *ChallengeBuf) []const u8 {
    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(v, &digest, .{});
    return b64.encode(buf, &digest);
}

/// A fresh `state` value: put it in the authorize URL and compare it to
/// the callback's before touching the code. nokre does not compare it
/// for you — what a mismatch means is the app's (drop it, log it, sign
/// the user out), and a framework that silently swallowed one would
/// hide the attack it exists to reveal.
pub fn state(app: *const App, buf: *StateBuf) []const u8 {
    if (comptime builtin.is_test) return seeded(buf, app.services.oauth.state.?.state_seed);
    var raw: [16]u8 = undefined;
    fill(&raw);
    return b64.encode(buf, &raw);
}

/// The seed, copied into the caller's buffer so the returned slice has
/// the same lifetime under both roofs. A seed longer than the buffer is
/// truncated — the buffer widths above are the contract, and a test
/// that seeds past them is asserting on a value no release build could
/// produce.
fn seeded(buf: []u8, seed: []const u8) []const u8 {
    const n = @min(seed.len, buf.len);
    @memcpy(buf[0..n], seed[0..n]);
    return buf[0..n];
}

// The wasm gap the plan named rather than discovering at link time:
// `std.crypto.random` on `freestanding` has no `getrandom` to reach, so
// the web leg routes to `crypto.getRandomValues` through services.js
// (both instances implement it — the browser's CSPRNG is synchronous on
// the main thread and in a Worker alike). Referenced only from this
// file's random path, so a build that never mints a verifier never
// names the import.
extern fn nokre_oauth_js_random(ptr: [*]u8, len: usize) void;

fn fill(dest: []u8) void {
    if (comptime is_wasm) {
        nokre_oauth_js_random(dest.ptr, dest.len);
    } else {
        std.crypto.random.bytes(dest);
    }
}
