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
//! Unknown keys are ignored and missing or mistyped keys take their defaults,
//! so a damaged file never stops a terminal from starting.

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
        var o: Options = .{};
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

test "defaults for an empty file" {
    var p = try Options.parse(std.testing.allocator, "", null);
    defer p.deinit();
    try std.testing.expectEqualStrings(schemes.default_scheme, p.options.color_scheme);
    try std.testing.expectEqual(@as(u32, 10_000), p.options.scrollback_lines);
    try std.testing.expect(p.options.osc52);
}

test "keys are read and clamped" {
    var p = try Options.parse(std.testing.allocator,
        \\color-scheme = "solarized-dark"
        \\cursor-style = "Bar"
        \\scrollback-lines = 99999999
        \\osc52 = false
        \\command = "/bin/sh"
        \\unknown = 1
    , null);
    defer p.deinit();
    try std.testing.expectEqualStrings("solarized-dark", p.options.color_scheme);
    try std.testing.expectEqual(CursorStyle.bar, p.options.cursor);
    try std.testing.expectEqual(@as(u32, max_scrollback_lines), p.options.scrollback_lines);
    try std.testing.expect(!p.options.osc52);
    try std.testing.expectEqualStrings("/bin/sh", p.options.command);
}

test "mistyped keys keep their defaults" {
    var p = try Options.parse(std.testing.allocator, "osc52 = \"yes\"\nscrollback-lines = \"many\"\n", null);
    defer p.deinit();
    try std.testing.expect(p.options.osc52);
    try std.testing.expectEqual(@as(u32, 10_000), p.options.scrollback_lines);
}

test "malformed TOML is an error the caller can handle" {
    try std.testing.expectError(error.Syntax, Options.parse(std.testing.allocator, "this is = = bad", null));
}
