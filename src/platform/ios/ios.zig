//! iOS over the shared C shell: c_shell.Runner with the UIAccessibility
//! (VoiceOver) adapter and the Skia frame source. Unlike macOS there is
//! no AccessKit library here — shell.m maps the same flattened snapshot
//! straight onto UIAccessibility, and the software keyboard is driven
//! by the shared `wants_text_input` callback.

const c_shell = @import("../c_shell.zig");
const skia_frame = @import("../skia_frame.zig");
const accesskit = @import("../../a11y/accesskit.zig");

pub const run = c_shell.Runner(accesskit.Ios, skia_frame.install).run;
