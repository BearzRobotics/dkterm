// SPDX-License-Identifier: LGPL-2.0-or-later
//! libghostty-vt setup shared by the programs that host a terminal.

const std = @import("std");
const vt = @import("ghostty-vt");
const schemes = @import("schemes.zig");

pub fn rgb(value: u24) vt.color.RGB {
    return .{ .r = @truncate(value >> 16), .g = @truncate(value >> 8), .b = @truncate(value) };
}

/// The default palette with the scheme's 16 ANSI colours in front.
pub fn palette(scheme: schemes.Scheme) vt.color.Palette {
    var p = vt.color.default;
    for (scheme.ansi, 0..) |c, i| p[i] = rgb(c);
    return p;
}

/// Terminal colours for a scheme: foreground, background, and the 16 ANSI
/// colours in the palette.
///
/// `colors.palette` holds an allocation. A `vt.Terminal.init` that succeeds
/// takes it over, and `Terminal.deinit` frees it: do not free it again. If
/// the colours never get that far, free it with `colors.palette.deinit`,
/// which an `errdefer` around `Terminal.init` does:
///
///     var colors = try glue.terminalColors(gpa, scheme);
///     errdefer colors.palette.deinit(gpa);
///     var term = try vt.Terminal.init(io, gpa, .{ ..., .colors = colors });
pub fn terminalColors(allocator: std.mem.Allocator, scheme: schemes.Scheme) !vt.Terminal.Colors {
    return .{
        .background = .init(rgb(scheme.background)),
        .foreground = .init(rgb(scheme.foreground)),
        .cursor = .unset,
        .palette = try .init(allocator, palette(scheme)),
    };
}

test "a scheme's colours go into the palette" {
    const scheme = schemes.scheme(schemes.default_scheme);
    try std.testing.expectEqual(vt.color.RGB{ .r = 0x12, .g = 0x34, .b = 0x56 }, rgb(0x123456));
    const p = palette(scheme);
    for (scheme.ansi, 0..) |c, i| try std.testing.expectEqual(rgb(c), p[i]);
    for (scheme.ansi.len..p.len) |i| try std.testing.expectEqual(vt.color.default[i], p[i]);
}

test "the palette belongs to the terminal once it is initialised" {
    // The testing allocator reports a leak or a second free.
    const gpa = std.testing.allocator;
    const colors = try terminalColors(gpa, schemes.scheme(schemes.default_scheme));
    var term = try vt.Terminal.init(std.testing.io, gpa, .{ .cols = 10, .rows = 2, .colors = colors });
    term.deinit(gpa);
}

test "the palette is the caller's when no terminal takes it" {
    const gpa = std.testing.allocator;
    var colors = try terminalColors(gpa, schemes.scheme(schemes.default_scheme));
    colors.palette.deinit(gpa);
}
