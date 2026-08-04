//! Windows over the shared C shell: c_shell.Runner with the AccessKit
//! (UIA — Narrator, NVDA, JAWS) adapter and the Skia frame source.
//! Single window by design; everything event-shaped lives in
//! c_shell.zig and shell.c.

const c_shell = @import("../c_shell.zig");
const skia_frame = @import("../skia_frame.zig");
const accesskit = @import("../../a11y/accesskit.zig");

pub const run = c_shell.Runner(accesskit.Windows, skia_frame.install).run;
