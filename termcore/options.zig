// SPDX-License-Identifier: LGPL-2.0-or-later
//! Optional TOML reader for the frontend-neutral terminal settings.
//!
//! The engine does not need it: a frontend can fill `Options` itself. It is
//! here so DKTerm and DKConsole read the same keys the same way. Frontend-only
//! settings (fonts, opacity, tabs, padding, ...) are not read here.
//!
//! ```toml
//! color-scheme = "campbell"
//! cursor-style = "block"       # block, bar or underline
//! scrollback-lines = 10000
//! osc52 = true                 # let programs set the clipboard
//! copy-on-select = true
//! command = ""                 # empty: the user's login shell
//! directory = ""               # empty: the user's home
//! ```
//!
//! In a valid file, unknown keys are ignored and missing or mistyped keys take
//! their defaults. Text that is not valid TOML, a repeated key included, is an
//! error: report it and carry on with `Options{}`, so that a damaged file does
//! not stop a terminal from starting.

const std = @import("std");
const toml = @import("toml");
const schemes = @import("schemes.zig");

pub const CursorStyle = enum { block, bar, underline };

/// The most scrollback a configuration may ask for.
pub const max_scrollback_lines = 1_000_000;

/// Slices point into the document the options were read from.
pub const Options = struct {
    color_scheme: []const u8 = schemes.default_scheme,
    cursor: CursorStyle = .block,
    scrollback_lines: u32 = 10_000,
    osc52: bool = true,
    copy_on_select: bool = true,
    command: []const u8 = "",
    directory: []const u8 = "",

    /// Reads the settings from `table`.
    pub fn fromTable(table: *const toml.Table) Options {
        return fromTableOver(table, .{});
    }

    /// Reads the settings from `table` over `base`: a key that is missing or
    /// mistyped keeps the value it has there. For a frontend with defaults of
    /// its own, or one that also accepts older names for some keys. A
    /// scrollback read from `table` is limited to `max_scrollback_lines`; a
    /// frontend with a lower limit applies it to the result.
    pub fn fromTableOver(table: *const toml.Table, base: Options) Options {
        var o = base;
        if (table.getString("color-scheme")) |s| o.color_scheme = s;
        if (table.getString("cursor-style")) |s| o.cursor = parseCursor(s);
        if (table.getInt("scrollback-lines")) |n| o.scrollback_lines = @intCast(std.math.clamp(n, 0, max_scrollback_lines));
        if (table.getBool("osc52")) |b| o.osc52 = b;
        if (table.getBool("copy-on-select")) |b| o.copy_on_select = b;
        if (table.getString("command")) |s| o.command = s;
        if (table.getString("directory")) |s| o.directory = s;
        return o;
    }

    /// Parses `source` and reads the settings from its top level. The
    /// returned document owns the strings in the options; free it with
    /// `deinit` when the options are no longer used.
    pub fn parse(gpa: std.mem.Allocator, source: []const u8, diag: ?*toml.Diagnostic) toml.ParseError!Parsed {
        const doc = try toml.Document.parse(gpa, source, .{}, diag);
        return .{ .document = doc, .options = fromTable(doc.root) };
    }
};

pub const Parsed = struct {
    document: toml.Document,
    options: Options,

    pub fn deinit(self: *Parsed) void {
        self.document.deinit();
    }
};

pub fn parseCursor(text: []const u8) CursorStyle {
    if (std.ascii.eqlIgnoreCase(text, "bar")) return .bar;
    if (std.ascii.eqlIgnoreCase(text, "underline")) return .underline;
    return .block;
}

fn expectOptions(want: Options, source: []const u8) !void {
    var p = try Options.parse(std.testing.allocator, source, null);
    defer p.deinit();
    inline for (@typeInfo(Options).@"struct".field_names) |name| {
        const got = @field(p.options, name);
        if (@TypeOf(got) == []const u8)
            try std.testing.expectEqualStrings(@field(want, name), got)
        else
            try std.testing.expectEqual(@field(want, name), got);
    }
}

test "defaults for an empty file" {
    try expectOptions(.{
        .color_scheme = "campbell",
        .cursor = .block,
        .scrollback_lines = 10_000,
        .osc52 = true,
        .copy_on_select = true,
        .command = "",
        .directory = "",
    }, "");
}

test "every key is read" {
    try expectOptions(.{
        .color_scheme = "solarized-dark",
        .cursor = .bar,
        .scrollback_lines = 123,
        .osc52 = false,
        .copy_on_select = false,
        .command = "/bin/sh",
        .directory = "/srv",
    },
        \\color-scheme = "solarized-dark"
        \\cursor-style = "Bar"
        \\scrollback-lines = 123
        \\osc52 = false
        \\copy-on-select = false
        \\command = "/bin/sh"
        \\directory = "/srv"
        \\unknown = 1
    );
}

test "scrollback is kept within bounds" {
    try expectOptions(.{ .scrollback_lines = max_scrollback_lines }, "scrollback-lines = 99999999");
    try expectOptions(.{ .scrollback_lines = max_scrollback_lines }, "scrollback-lines = 1000000");
    try expectOptions(.{ .scrollback_lines = 0 }, "scrollback-lines = 0");
    try expectOptions(.{ .scrollback_lines = 0 }, "scrollback-lines = -1");
}

test "cursor styles" {
    try expectOptions(.{ .cursor = .block }, "cursor-style = \"block\"");
    try expectOptions(.{ .cursor = .bar }, "cursor-style = \"bar\"");
    try expectOptions(.{ .cursor = .underline }, "cursor-style = \"UnderLine\"");
    try expectOptions(.{ .cursor = .block }, "cursor-style = \"beam\"");
}

test "mistyped keys keep their defaults" {
    try expectOptions(.{},
        \\color-scheme = 1
        \\cursor-style = true
        \\scrollback-lines = "many"
        \\osc52 = "yes"
        \\copy-on-select = 0
        \\command = false
        \\directory = ["a"]
    );
}

test "malformed TOML is an error the caller can handle" {
    try std.testing.expectError(error.Syntax, Options.parse(std.testing.allocator, "this is = = bad", null));
}

test "a frontend's own defaults stand for what the file does not set" {
    var doc = try toml.Document.parse(std.testing.allocator, "osc52 = true\nscrollback-lines = \"many\"\n", .{}, null);
    defer doc.deinit();
    const o = Options.fromTableOver(doc.root, .{ .osc52 = false, .scrollback_lines = 2000, .color_scheme = "one-half-dark" });
    try std.testing.expect(o.osc52);
    try std.testing.expectEqual(@as(u32, 2000), o.scrollback_lines);
    try std.testing.expectEqualStrings("one-half-dark", o.color_scheme);
}
