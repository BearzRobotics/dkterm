// SPDX-License-Identifier: LGPL-2.0-or-later
//! Terminal code shared by the terminal frontends (DKTerm, DKConsole).
//! Imports only `std` and libghostty-vt: no GTK, GLib or Pango.

pub const pty = @import("pty.zig");
pub const schemes = @import("schemes.zig");
pub const keymap = @import("keymap.zig");
pub const glue = @import("glue.zig");
/// Optional: reads the frontend-neutral settings from TOML.
pub const options = @import("options.zig");

test {
    // Zig only type-checks what something references. Name every public
    // declaration, so that none can stop compiling unnoticed.
    inline for (.{ pty, pty.Pty, pty.Outbox, schemes, keymap, glue, options, options.Options, options.Parsed }) |namespace| {
        std.testing.refAllDecls(namespace);
    }
    // Test files that nothing else imports.
    _ = @import("pty_test.zig");
}

const std = @import("std");
