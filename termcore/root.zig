//! Terminal code shared by the terminal frontends (DKTerm, DKConsole).
//! Imports only `std` and libghostty-vt: no GTK, GLib or Pango.

pub const pty = @import("pty.zig");
pub const schemes = @import("schemes.zig");
pub const keymap = @import("keymap.zig");
pub const glue = @import("glue.zig");
/// Optional: reads the frontend-neutral settings from TOML.
pub const options = @import("options.zig");

test {
    _ = pty;
    _ = schemes;
    _ = keymap;
    _ = glue;
    _ = options;
}
