// SPDX-License-Identifier: LGPL-2.0-or-later
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // libghostty-vt parses untrusted output, so it gets the caller's safety
    // checks. The exception is Debug: it then also runs integrity checks on
    // every linefeed, which makes a screenful of output take seconds, so a
    // Debug build gets ReleaseSafe.
    // -Dsimd=false leaves out simdutf and highway, which are C++ (a rescue console wants that).
    const simd = b.option(bool, "simd", "Build libghostty-vt with SIMD (C++) helpers (default: true)") orelse true;
    const ghostty = b.dependency("ghostty", .{ .target = target, .optimize = if (optimize == .debug) .safe else optimize, .simd = simd });
    // Consumers that talk to libghostty-vt themselves must use this same instance.
    b.modules.put(b.allocator, b.dupe("ghostty-vt"), ghostty.module("ghostty-vt")) catch @panic("OOM");

    const termcore = b.addModule("termcore", .{
        .root_source_file = b.path("termcore/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    termcore.addImport("ghostty-vt", ghostty.module("ghostty-vt"));
    termcore.addImport("toml", b.dependency("toml", .{ .target = target, .optimize = optimize }).module("toml"));

    const tests = b.addTest(.{ .root_module = termcore });
    b.step("test", "Run the DKTermCore tests").dependOn(&b.addRunArtifact(tests).step);
}
