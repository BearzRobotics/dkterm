// SPDX-License-Identifier: LGPL-2.0-or-later
//! Tests that run real programs on a pseudo-terminal. They need /bin/sh and
//! stty.

const std = @import("std");
const Pty = @import("pty.zig").Pty;
const Outbox = @import("pty.zig").Outbox;

const testing = std.testing;

const PollFd = extern struct { fd: c_int, events: c_short, revents: c_short };
extern fn poll(fds: [*]PollFd, n: c_ulong, timeout: c_int) c_int;

const size = @import("pty.zig").Size{ .cols = 80, .rows = 24 };

fn spawnSh(script: [:0]const u8, extra: struct { cwd: ?[:0]const u8 = null }) !Pty {
    return Pty.spawn(testing.allocator, .{
        .path = "/bin/sh",
        .argv = &.{ "sh", "-c", script },
        .env = &.{ "PATH=/usr/bin:/bin", "MARK=from-env" },
        .size = size,
        .cwd = extra.cwd,
    });
}

/// What the child writes, up to `needle`. Fails after about 5 s without it.
const Output = struct {
    buf: [8192]u8 = undefined,
    len: usize = 0,

    fn until(self: *Output, p: *Pty, needle: []const u8) !void {
        var tries: usize = 0;
        while (std.mem.indexOf(u8, self.text(), needle) == null) : (tries += 1) {
            if (tries == 100 or self.len == self.buf.len) break;
            var fds = [1]PollFd{.{ .fd = p.fd(), .events = 1, .revents = 0 }};
            _ = poll(&fds, 1, 50);
            self.len += p.readSome(self.buf[self.len..]) orelse break;
        }
        if (std.mem.indexOf(u8, self.text(), needle) == null) {
            std.debug.print("expected \"{s}\" in \"{s}\"\n", .{ needle, self.text() });
            return error.OutputMissing;
        }
    }

    fn text(self: *const Output) []const u8 {
        return self.buf[0..self.len];
    }
};

fn expectOutput(script: [:0]const u8, needle: []const u8) !void {
    var p = try spawnSh(script, .{});
    defer p.deinit();
    var out: Output = .{};
    try out.until(&p, needle);
}

test "a child's output arrives on the master" {
    try expectOutput("echo hello", "hello");
}

test "the child gets the environment, the window size and a controlling terminal" {
    try expectOutput("echo \"$MARK\"", "from-env");
    try expectOutput("stty size", "24 80");
    // Only a process with a controlling terminal can open /dev/tty.
    try expectOutput("echo via-tty >/dev/tty", "via-tty");
}

test "the child starts in the requested directory" {
    var p = try spawnSh("pwd", .{ .cwd = "/proc" });
    defer p.deinit();
    var out: Output = .{};
    try out.until(&p, "/proc");
}

test "resize reaches the child" {
    var p = try spawnSh("echo ready; read line; stty size", .{});
    defer p.deinit();
    var out: Output = .{};
    try out.until(&p, "ready");
    p.resize(.{ .cols = 100, .rows = 30 });
    _ = try p.write("\n");
    try out.until(&p, "30 100");
}

test "input reaches the child and its exit is seen" {
    var p = try spawnSh("read line; echo \"got:$line\"; exit 3", .{});
    defer p.deinit();
    _ = try p.write("abc\n");
    var out: Output = .{};
    try out.until(&p, "got:abc");
    var tries: usize = 0;
    const status = while (tries < 200) : (tries += 1) {
        if (p.poll()) |status| break status;
        _ = poll(undefined, 0, 10);
    } else return error.ChildDidNotExit;
    try testing.expectEqual(@as(u32, 3 << 8), status);
}

test "a large message reaches a child that starts reading late, whole" {
    const gpa = testing.allocator;
    var p = try spawnSh("stty raw -echo; echo ready; sleep 0.3; head -c 1048589 | wc -c", .{});
    defer p.deinit();
    var out: Output = .{};
    try out.until(&p, "ready");

    const body = try gpa.alloc(u8, 1024 * 1024);
    defer gpa.free(body);
    @memset(body, 'x');
    var box: Outbox = .{};
    defer box.deinit(gpa);
    try box.queue(gpa, &.{ "\x1b[200~", body, "\x1b[201~" });
    try box.flush(gpa, &p);
    try testing.expect(box.pending()); // the terminal cannot take it at once
    try box.queue(gpa, &.{"!"});

    var tries: usize = 0;
    while (box.pending()) : (tries += 1) {
        if (tries == 100_000) return error.NotFlushed;
        var fds = [1]PollFd{.{ .fd = p.fd(), .events = 4, .revents = 0 }};
        _ = poll(&fds, 1, 100);
        try box.flush(gpa, &p);
    }
    try out.until(&p, "1048589");
}

test "a full outbox refuses the whole message" {
    const gpa = testing.allocator;
    var box: Outbox = .{ .limit = 8 };
    defer box.deinit(gpa);
    try box.queue(gpa, &.{"abcd"});
    try testing.expectError(error.OutboxFull, box.queue(gpa, &.{ "ef", "ghi" }));
    try testing.expectEqualStrings("abcd", box.bytes.items);
    try box.queue(gpa, &.{ "ef", "gh" });
    try testing.expectEqualStrings("abcdefgh", box.bytes.items);
    box.clear(gpa);
    try testing.expect(!box.pending());
}

fn nowMs() i64 {
    var t: std.os.linux.timespec = undefined;
    _ = std.os.linux.clock_gettime(.MONOTONIC, &t);
    return @as(i64, t.sec) * 1000 + @divTrunc(@as(i64, t.nsec), 1_000_000);
}

extern fn kill(pid: c_int, sig: c_int) c_int;

test "deinit ends a child that ignores SIGHUP and SIGTERM" {
    var p = try spawnSh("trap '' HUP TERM; echo ready; while :; do sleep 1; done", .{});
    var out: Output = .{};
    out.until(&p, "ready") catch |err| {
        p.deinit();
        return err;
    };
    const pid = p.pid;
    const began = nowMs();
    p.deinit();
    try testing.expect(nowMs() - began < 3000);
    // Reaped, not merely signalled.
    try testing.expectEqual(@as(c_int, -1), kill(pid, 0));
}

test "deinit is quick for a child that obeys" {
    var p = try spawnSh("echo ready; read line", .{});
    var out: Output = .{};
    out.until(&p, "ready") catch |err| {
        p.deinit();
        return err;
    };
    const began = nowMs();
    p.deinit();
    try testing.expect(nowMs() - began < Pty.grace_ms);
}

extern fn close(fd: c_int) c_int;
extern fn dup2(old: c_int, new: c_int) c_int;
extern fn fcntl(fd: c_int, cmd: c_int, ...) c_int;

test "the child has stdin, stdout and stderr when the parent has them closed" {
    const F_DUPFD_CLOEXEC = 1030;
    var fd: c_int = 0;
    while (fd <= 2) : (fd += 1) {
        const saved = fcntl(fd, F_DUPFD_CLOEXEC, @as(c_int, 100));
        if (saved < 0) return error.SkipZigTest;
        _ = close(fd);
        const spawned = spawnSh(
            "for n in 0 1 2; do [ -e /proc/$$/fd/$n ] || exit 1; done; echo all-open",
            .{},
        );
        // The master must not sit on a standard descriptor. It is closed here,
        // before the restore below would silently replace it.
        var misplaced = false;
        var result = spawned;
        if (result) |*live| {
            if (live.fd() <= 2) {
                live.deinit();
                misplaced = true;
            }
        } else |_| {}
        // Restored before anything can fail: the test runner uses them.
        _ = dup2(saved, fd);
        _ = close(saved);
        try testing.expect(!misplaced);
        var p = try result;
        defer p.deinit();
        var out: Output = .{};
        try out.until(&p, "all-open");
    }
}

test "a directory that cannot be entered fails the spawn" {
    var code: c_int = 0;
    try testing.expectError(error.BadWorkingDirectory, Pty.spawn(testing.allocator, .{
        .path = "/bin/sh",
        .argv = &.{ "sh", "-c", "pwd" },
        .env = &.{},
        .size = size,
        .cwd = "/nonexistent-dir-xyz",
        .failure_errno = &code,
    }));
    try testing.expectEqual(@backingInt(std.os.linux.E.NOENT), code);
}

test "a program that cannot be run fails the spawn" {
    var code: c_int = 0;
    const cases = [_]struct { path: [:0]const u8, errno: std.os.linux.E }{
        .{ .path = "/nonexistent", .errno = .NOENT },
        .{ .path = "/etc/hostname", .errno = .ACCES }, // not executable
    };
    for (cases) |case| {
        try testing.expectError(error.ExecFailed, Pty.spawn(testing.allocator, .{
            .path = case.path,
            .argv = &.{case.path},
            .env = &.{},
            .size = size,
            .failure_errno = &code,
        }));
        try testing.expectEqual(@backingInt(case.errno), code);
    }
}
