// SPDX-License-Identifier: LGPL-2.0-or-later
//! Colour schemes, shared by dkde-term and DKConsole.

const std = @import("std");

pub const Scheme = struct {
    background: u24,
    foreground: u24,
    /// The 16 ANSI colours: normal 0-7, bright 8-15.
    ansi: [16]u24,
};

pub const default_scheme = "campbell";

const campbell: Scheme = .{
    .background = 0x0C0C0C,
    .foreground = 0xCCCCCC,
    .ansi = .{
        0x0C0C0C, 0xC50F1F, 0x13A10E, 0xC19C00, 0x0037DA, 0x881798, 0x3A96DD, 0xCCCCCC,
        0x767676, 0xE74856, 0x16C60C, 0xF9F1A5, 0x3B78FF, 0xB4009E, 0x61D6D6, 0xF2F2F2,
    },
};

const one_half_dark: Scheme = .{
    .background = 0x282C34,
    .foreground = 0xDCDFE4,
    .ansi = .{
        0x282C34, 0xE06C75, 0x98C379, 0xE5C07B, 0x61AFEF, 0xC678DD, 0x56B6C2, 0xDCDFE4,
        0x5A6374, 0xE06C75, 0x98C379, 0xE5C07B, 0x61AFEF, 0xC678DD, 0x56B6C2, 0xDCDFE4,
    },
};

const solarized_ansi = [16]u24{
    0x073642, 0xDC322F, 0x859900, 0xB58900, 0x268BD2, 0xD33682, 0x2AA198, 0xEEE8D5,
    0x002B36, 0xCB4B16, 0x586E75, 0x657B83, 0x839496, 0x6C71C4, 0x93A1A1, 0xFDF6E3,
};

const solarized_dark: Scheme = .{ .background = 0x002B36, .foreground = 0x839496, .ansi = solarized_ansi };
const solarized_light: Scheme = .{ .background = 0xFDF6E3, .foreground = 0x657B83, .ansi = solarized_ansi };

/// Looks a scheme up by name; unknown names give the default.
pub fn scheme(name: []const u8) Scheme {
    if (std.ascii.eqlIgnoreCase(name, "one-half-dark")) return one_half_dark;
    if (std.ascii.eqlIgnoreCase(name, "solarized-dark")) return solarized_dark;
    if (std.ascii.eqlIgnoreCase(name, "solarized-light")) return solarized_light;
    return campbell;
}

pub const names = [_][]const u8{ "campbell", "one-half-dark", "solarized-dark", "solarized-light" };

test "each name gives its own scheme, in any case, and others give the default" {
    // Background, foreground, and ANSI 1 (red), 8 and 15.
    const want = [names.len]struct { []const u8, [5]u24 }{
        .{ "campbell", .{ 0x0C0C0C, 0xCCCCCC, 0xC50F1F, 0x767676, 0xF2F2F2 } },
        .{ "one-half-dark", .{ 0x282C34, 0xDCDFE4, 0xE06C75, 0x5A6374, 0xDCDFE4 } },
        .{ "solarized-dark", .{ 0x002B36, 0x839496, 0xDC322F, 0x002B36, 0xFDF6E3 } },
        .{ "solarized-light", .{ 0xFDF6E3, 0x657B83, 0xDC322F, 0x002B36, 0xFDF6E3 } },
    };
    for (names, want) |name, entry| {
        try std.testing.expectEqualStrings(entry[0], name);
        var upper: [32]u8 = undefined;
        for ([_][]const u8{ name, std.ascii.upperString(&upper, name) }) |spelling| {
            const s = scheme(spelling);
            try std.testing.expectEqual(entry[1], [5]u24{ s.background, s.foreground, s.ansi[1], s.ansi[8], s.ansi[15] });
        }
    }
    try std.testing.expectEqualStrings("campbell", default_scheme);
    try std.testing.expectEqual(scheme(default_scheme), scheme("nope"));
    try std.testing.expectEqual(scheme(default_scheme), scheme(""));
}
