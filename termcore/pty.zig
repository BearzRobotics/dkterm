// SPDX-License-Identifier: LGPL-2.0-or-later
//! Pseudo-terminal plumbing without GLib (SPEC.md 4.3): `openpty`, a child
//! started with `fork`/`execve` on the slave side, `TIOCSWINSZ` for resize.
//! Everything used exists in both glibc and musl.
//!
//! The caller owns the event loop: `fd()` is the master, already
//! non-blocking, to put in a `poll`.

const std = @import("std");

pub const Size = struct { cols: u16, rows: u16, cell_w: u16 = 0, cell_h: u16 = 0 };

const Winsize = extern struct { ws_row: u16, ws_col: u16, ws_xpixel: u16, ws_ypixel: u16 };

extern fn openpty(amaster: *c_int, aslave: *c_int, name: ?[*]u8, termp: ?*const anyopaque, winp: ?*const Winsize) c_int;
extern fn ioctl(fd: c_int, request: c_ulong, ...) c_int;
extern fn fork() c_int;
extern fn setsid() c_int;
extern fn dup2(old: c_int, new: c_int) c_int;
extern fn close(fd: c_int) c_int;
extern fn fcntl(fd: c_int, cmd: c_int, ...) c_int;
extern fn read(fd: c_int, buf: [*]u8, count: usize) isize;
const sys_write = @extern(*const fn (fd: c_int, buf: [*]const u8, count: usize) callconv(.c) isize, .{ .name = "write" });
extern fn execve(path: [*:0]const u8, argv: [*:null]const ?[*:0]const u8, envp: [*:null]const ?[*:0]const u8) c_int;
extern fn _exit(status: c_int) noreturn;
extern fn waitpid(pid: c_int, status: ?*c_int, options: c_int) c_int;
extern fn kill(pid: c_int, sig: c_int) c_int;
const sys_poll = @extern(*const fn (fds: *allowzero anyopaque, n: c_ulong, timeout: c_int) callconv(.c) c_int, .{ .name = "poll" });
extern fn chdir(path: [*:0]const u8) c_int;
extern fn __errno_location() *c_int;

const TIOCSWINSZ: c_ulong = 0x5414;
const TIOCSCTTY: c_ulong = 0x540E;
const F_GETFL = 3;
const F_SETFL = 4;
const F_SETFD = 2;
const FD_CLOEXEC = 1;
const O_NONBLOCK = 0o4000;
const EAGAIN = 11;
const EINTR = 4;
const WNOHANG = 1;
const SIGHUP = 1;
const SIGKILL = 9;
const SIGTERM = 15;
const SIGCONT = 18;

fn errno() c_int {
    return __errno_location().*;
}

pub const Pty = struct {
    master: c_int,
    pid: c_int,

    pub const SpawnOptions = struct {
        /// Absolute path of the program; there is no PATH search.
        path: [:0]const u8,
        /// argv, including argv[0].
        argv: []const [:0]const u8,
        /// The whole environment, each "NAME=value".
        env: []const [:0]const u8,
        size: Size,
        cwd: ?[:0]const u8 = null,
    };

    pub const Error = error{ OpenPtyFailed, ForkFailed, OutOfMemory };

    pub fn spawn(allocator: std.mem.Allocator, opts: SpawnOptions) Error!Pty {
        // Everything the child needs is built before the fork: after it, only
        // async-signal-safe calls are allowed.
        const argv = try allocator.allocSentinel(?[*:0]const u8, opts.argv.len, null);
        defer allocator.free(argv);
        for (opts.argv, 0..) |a, i| argv[i] = a.ptr;
        const envp = try allocator.allocSentinel(?[*:0]const u8, opts.env.len, null);
        defer allocator.free(envp);
        for (opts.env, 0..) |e, i| envp[i] = e.ptr;

        var master: c_int = undefined;
        var slave: c_int = undefined;
        const ws = winsize(opts.size);
        if (openpty(&master, &slave, null, null, &ws) != 0) return error.OpenPtyFailed;
        _ = fcntl(master, F_SETFD, @as(c_int, FD_CLOEXEC));
        _ = fcntl(master, F_SETFL, fcntl(master, F_GETFL) | @as(c_int, O_NONBLOCK));

        const pid = fork();
        if (pid < 0) {
            _ = close(master);
            _ = close(slave);
            return error.ForkFailed;
        }
        if (pid == 0) {
            _ = setsid();
            _ = ioctl(slave, TIOCSCTTY, @as(c_int, 0));
            _ = dup2(slave, 0);
            _ = dup2(slave, 1);
            _ = dup2(slave, 2);
            if (slave > 2) _ = close(slave);
            _ = close(master);
            if (opts.cwd) |c| _ = chdir(c.ptr);
            _ = execve(opts.path.ptr, argv.ptr, envp.ptr);
            _exit(127);
        }
        _ = close(slave);
        return .{ .master = master, .pid = pid };
    }

    fn winsize(s: Size) Winsize {
        return .{ .ws_row = s.rows, .ws_col = s.cols, .ws_xpixel = s.cols *| s.cell_w, .ws_ypixel = s.rows *| s.cell_h };
    }

    pub fn fd(self: *const Pty) c_int {
        return self.master;
    }

    pub fn resize(self: *const Pty, size: Size) void {
        const ws = winsize(size);
        _ = ioctl(self.master, TIOCSWINSZ, &ws);
    }

    /// Read what the child wrote. Returns 0 when nothing is waiting, and null
    /// when the child side is closed.
    pub fn readSome(self: *const Pty, buf: []u8) ?usize {
        while (true) {
            const n = read(self.master, buf.ptr, buf.len);
            if (n > 0) return @intCast(n);
            if (n == 0) return null;
            switch (errno()) {
                EINTR => continue,
                EAGAIN => return 0,
                else => return null, // EIO: the slave side closed
            }
        }
    }

    pub const WriteError = error{WriteFailed};

    /// Writes as much of `data` as the terminal takes without waiting, and
    /// returns how much that was: 0 when the child is not reading. A paste or
    /// anything else that must arrive whole belongs in an `Outbox`.
    pub fn write(self: *const Pty, data: []const u8) WriteError!usize {
        var done: usize = 0;
        while (done < data.len) {
            const n = sys_write(self.master, data[done..].ptr, data.len - done);
            if (n > 0) {
                done += @intCast(n);
                continue;
            }
            if (n == 0) break;
            switch (errno()) {
                EINTR => continue,
                EAGAIN => break,
                else => return error.WriteFailed,
            }
        }
        return done;
    }

    /// The exit status if the child has ended, else null. Reaps it.
    pub fn poll(self: *Pty) ?u32 {
        if (self.pid <= 0) return 0;
        var status: c_int = 0;
        const r = waitpid(self.pid, &status, WNOHANG);
        if (r == 0) return null;
        self.pid = 0;
        return @bitCast(status);
    }

    /// How long `deinit` lets the child end on its own before killing it.
    pub const grace_ms = 500;

    /// Asks the child to end. Does not wait.
    pub fn terminate(self: *Pty) void {
        if (self.pid > 0) {
            _ = kill(self.pid, SIGHUP);
            _ = kill(self.pid, SIGTERM);
            _ = kill(self.pid, SIGCONT); // in case it was stopped
        }
    }

    /// Hangs up the terminal and ends the child: it has `grace_ms` to leave,
    /// then it and its process group are killed. Returns in bounded time.
    pub fn deinit(self: *Pty) void {
        // Closing first hangs up the terminal, which reaches the foreground
        // processes as well as the child.
        _ = close(self.master);
        if (self.pid > 0) {
            self.terminate();
            if (!self.reapWithin(grace_ms)) {
                _ = kill(-self.pid, SIGKILL);
                _ = kill(self.pid, SIGKILL);
                // A process stuck in the kernel cannot be waited out; it is
                // left for the parent's exit.
                _ = self.reapWithin(1000);
            }
        }
        self.* = .{ .master = -1, .pid = 0 };
    }

    fn reapWithin(self: *Pty, ms: u32) bool {
        const step_ms = 5;
        var waited: u32 = 0;
        while (true) : (waited += step_ms) {
            if (self.poll() != null) return true;
            if (waited >= ms) return false;
            _ = sys_poll(@ptrFromInt(0), 0, step_ms);
        }
    }
};

/// Input waiting for a child that is not reading yet. Nothing queued is
/// dropped: `queue` takes all of a message or refuses all of it.
///
/// Call `queue`, then `flush`. While `pending`, ask `poll` for POLLOUT on
/// `Pty.fd` and call `flush` again when it is ready. Keep reading the child's
/// output meanwhile; a child blocked on output reads no input.
pub const Outbox = struct {
    bytes: std.ArrayList(u8) = .empty,
    /// How much of `bytes` has been written already.
    sent: usize = 0,
    /// The most that may wait at once.
    limit: usize = default_limit,

    pub const default_limit = 8 * 1024 * 1024;
    /// Storage larger than this is given back once the queue is empty.
    const keep_capacity = 64 * 1024;

    pub const QueueError = error{ OutboxFull, OutOfMemory };

    pub fn deinit(self: *Outbox, gpa: std.mem.Allocator) void {
        self.wipe();
        self.bytes.deinit(gpa);
        self.* = undefined;
    }

    pub fn pending(self: *const Outbox) bool {
        return self.sent < self.bytes.items.len;
    }

    /// Appends `parts`, in order, as one message.
    pub fn queue(self: *Outbox, gpa: std.mem.Allocator, parts: []const []const u8) QueueError!void {
        var total: usize = 0;
        for (parts) |part| total = std.math.add(usize, total, part.len) catch return error.OutboxFull;
        const waiting = self.bytes.items.len - self.sent;
        if (total > self.limit -| waiting) return error.OutboxFull;
        if (self.sent > 0) {
            std.mem.copyForwards(u8, self.bytes.items[0..waiting], self.bytes.items[self.sent..]);
            std.crypto.secureZero(u8, self.bytes.items[waiting..]);
            self.bytes.items.len = waiting;
            self.sent = 0;
        }
        // Grow by hand, so that no unwiped copy of typed input is left behind.
        const needed = waiting + total;
        if (needed > self.bytes.capacity) {
            var larger: std.ArrayList(u8) = .empty;
            try larger.ensureTotalCapacity(gpa, @max(needed, self.bytes.capacity * 2));
            larger.appendSliceAssumeCapacity(self.bytes.items);
            std.crypto.secureZero(u8, self.bytes.items);
            self.bytes.deinit(gpa);
            self.bytes = larger;
        }
        for (parts) |part| self.bytes.appendSliceAssumeCapacity(part);
    }

    /// Writes what the terminal will take now. On an error the queue is left
    /// as it was; use `clear` when the session is over.
    pub fn flush(self: *Outbox, gpa: std.mem.Allocator, pty: *const Pty) Pty.WriteError!void {
        self.sent += try pty.write(self.bytes.items[self.sent..]);
        if (!self.pending()) self.clear(gpa);
    }

    /// Discards what is waiting. Input can hold passwords, so it is wiped.
    pub fn clear(self: *Outbox, gpa: std.mem.Allocator) void {
        self.wipe();
        if (self.bytes.capacity > keep_capacity)
            self.bytes.clearAndFree(gpa)
        else
            self.bytes.clearRetainingCapacity();
        self.sent = 0;
    }

    fn wipe(self: *Outbox) void {
        std.crypto.secureZero(u8, self.bytes.items);
    }
};
