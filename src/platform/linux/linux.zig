//! Desktop Linux (Wayland) over the shared C shell: c_shell.Runner with
//! the AccessKit (AT-SPI — Orca) adapter and the Skia frame source.
//! Single window by design; everything event-shaped lives in
//! c_shell.zig and shell.c. The two Wayland-only legs — consuming
//! RunOptions.app_id and lending the event loop back for worker
//! wakes — are the Runner's comptime branches, not this file's.

const c_shell = @import("../c_shell.zig");
const skia_frame = @import("../skia_frame.zig");
const accesskit = @import("../../a11y/accesskit.zig");

pub const run = c_shell.Runner(accesskit.Unix, skia_frame.install).run;
