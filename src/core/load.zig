//! The four-phase async-value vocabulary. Pure data, and deliberately
//! nothing else: nokre owns no app state and never reads this enum —
//! it exists because every real consumer declared the same four words
//! (`idle` before the first request, `loading` while one is out,
//! `ready`/`failed` after), and a vocabulary two apps must spell
//! identically to talk to each other's reviewers belongs to the
//! framework's dictionary, not to each app's.
//!
//! What this is *not* is a state machine the framework advances. There
//! is no `Remote(T)`, no generation stamp, no staleness — a phase is a
//! word an app writes and its own screens read (owner decision,
//! 2026-08-04: the vocabulary and the `loadGate` builder idiom in
//! core/cursor.zig, nothing further). Consumers whose lifecycle has
//! more words (an OTP flow's `submitting`, an auth flow's `offline`)
//! keep their own enum; this is only the shape that repeats.

pub const Load = enum { idle, loading, ready, failed };
