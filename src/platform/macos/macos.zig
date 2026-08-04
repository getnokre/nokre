//! macOS over the shared C shell: c_shell.Runner with the AccessKit
//! (VoiceOver) adapter and the Skia frame source. Single window by
//! design; everything event-shaped lives in c_shell.zig and shell.m.

const c_shell = @import("../c_shell.zig");
const skia_frame = @import("../skia_frame.zig");
const accesskit = @import("../../a11y/accesskit.zig");

pub const run = c_shell.Runner(accesskit.Macos, skia_frame.install).run;
