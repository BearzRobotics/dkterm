// SPDX-License-Identifier: LGPL-2.0-or-later
//! Pseudo-terminal plumbing without GLib (SPEC.md 4.3): a new PTY, a child
//! started with `fork`/`execve` on the slave side, `TIOCSWINSZ` for resize.
//! The child gets the terminal as descriptors 0-2 and nothing else that this
//! process has open.
//! Everything used exists in both glibc and musl.
//!
//! The caller owns the event loop: `fd()` is the master, already
//! non-blocking, to put in a `poll`.

const std = @import("std");

pub const Size = struct { cols: u16, rows: u16, cell_w: u16 = 0, cell_h: u16 = 0 };

const Winsize = extern struct { ws_row: u16, ws_col: u16, ws_xpixel: u16, ws_ypixel: u16 };

extern fn posix_openpt(flags: c_int) c_int;
extern fn grantpt(fd: c_int) c_int;
extern fn unlockpt(fd: c_int) c_int;
extern fn ptsname_r(fd: c_int, buf: [*]u8, len: usize) c_int;
extern fn open(path: [*:0]const u8, flags: c_int, ...) c_int;
extern fn getdtablesize() c_int;
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
extern fn pipe2(fds: *[2]c_int, flags: c_int) c_int;
extern fn signal(sig: c_int, handler: usize) usize;
extern fn sigprocmask(how: c_int, set: *const [16]u64, old: ?*[16]u64) c_int;
extern fn chdir(path: [*:0]const u8) c_int;
extern fn __errno_location() *c_int;

const TIOCSWINSZ: c_ulong = 0x5414;
const TIOCSCTTY: c_ulong = 0x540E;
const F_GETFL = 3;
const F_SETFL = 4;
const F_SETFD = 2;
const F_DUPFD_CLOEXEC = 1030;
const FD_CLOEXEC = 1;
const O_NONBLOCK = 0o4000;
const O_RDWR = 2;
const O_NOCTTY = 0o400;
const O_CLOEXEC = 0o2000000;
const EAGAIN = 11;
const EINTR = 4;
const ECHILD = 10;
const WNOHANG = 1;
const SIG_DFL = 0;
const SIG_SETMASK = 2;
const SIGHUP = 1;
const SIGKILL = 9;
const SIGTERM = 15;
const SIGCONT = 18;

fn errno() c_int {
    return __errno_location().*;
}

pub const Pty = struct {
    master: c_int,
    /// The child, or 0 once it has been reaped.
    pid: c_int,
    /// How it ended, once it has.
    ended: ?Exit = null,

    pub const SpawnOptions = struct {
        /// Absolute path of the program; there is no PATH search.
        path: [:0]const u8,
        /// argv, including argv[0].
        argv: []const [:0]const u8,
        /// The whole environment, each "NAME=value".
        env: []const [:0]const u8,
        size: Size,
        /// Where the program starts. `spawn` fails if it cannot go there.
        cwd: ?[:0]const u8 = null,
        /// If `spawn` fails in the child, receives the system's error number.
        failure_errno: ?*c_int = null,
    };

    pub const Error = error{
        OpenPtyFailed,
        ForkFailed,
        OutOfMemory,
        /// The child could not take the terminal as its own.
        ChildSetupFailed,
        /// `SpawnOptions.cwd` could not be entered.
        BadWorkingDirectory,
        /// The program could not be run.
        ExecFailed,
    };

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
        if (!openPair(&master, &slave, winsize(opts.size))) return error.OpenPtyFailed;
        const descriptor_limit = getdtablesize();
        // With a standard descriptor closed in this process, openpty hands out
        // its number, which the child is about to overwrite.
        if (!liftAboveStdio(&master) or !liftAboveStdio(&slave)) {
            _ = close(master);
            _ = close(slave);
            return error.OpenPtyFailed;
        }
        const flags = fcntl(master, F_GETFL);
        // A child that fails before it runs the program says why on this pipe.
        var report: [2]c_int = undefined;
        if (flags < 0 or fcntl(master, F_SETFL, flags | @as(c_int, O_NONBLOCK)) != 0 or pipe2(&report, O_CLOEXEC) != 0) {
            _ = close(master);
            _ = close(slave);
            return error.OpenPtyFailed;
        }
        if (!liftAboveStdio(&report[0]) or !liftAboveStdio(&report[1])) {
            _ = close(report[0]);
            _ = close(report[1]);
            _ = close(master);
            _ = close(slave);
            return error.OpenPtyFailed;
        }

        const pid = fork();
        if (pid < 0) {
            _ = close(report[0]);
            _ = close(report[1]);
            _ = close(master);
            _ = close(slave);
            return error.ForkFailed;
        }
        if (pid == 0) {
            resetSignals();
            if (setsid() < 0 or ioctl(slave, TIOCSCTTY, @as(c_int, 0)) != 0 or
                dup2(slave, 0) < 0 or dup2(slave, 1) < 0 or dup2(slave, 2) < 0)
                childFailed(report[1], .setup);
            _ = close(slave);
            _ = close(master);
            closeOnExecFrom3(descriptor_limit);
            if (opts.cwd) |c| if (chdir(c.ptr) != 0) childFailed(report[1], .cwd);
            _ = execve(opts.path.ptr, argv.ptr, envp.ptr);
            childFailed(report[1], .exec);
        }
        _ = close(slave);
        _ = close(report[1]);
        defer _ = close(report[0]);
        if (readFailure(report[0])) |failure| {
            _ = close(master);
            while (waitpid(pid, null, 0) < 0 and errno() == EINTR) {}
            if (opts.failure_errno) |out| out.* = failure.code;
            return switch (failure.stage) {
                .setup => error.ChildSetupFailed,
                .cwd => error.BadWorkingDirectory,
                .exec => error.ExecFailed,
            };
        }
        return .{ .master = master, .pid = pid };
    }

    /// Opens a new pseudo-terminal. Both sides are close-on-exec from the
    /// start (openpty cannot do that), so a program another thread starts
    /// meanwhile does not get them.
    fn openPair(master: *c_int, slave: *c_int, ws: Winsize) bool {
        const flags: c_int = O_RDWR | O_NOCTTY | O_CLOEXEC;
        const m = posix_openpt(flags);
        if (m < 0) return false;
        var name: [64]u8 = undefined;
        if (grantpt(m) != 0 or unlockpt(m) != 0 or ptsname_r(m, &name, name.len) != 0) {
            _ = close(m);
            return false;
        }
        const s = open(@ptrCast(&name), flags);
        if (s < 0) {
            _ = close(m);
            return false;
        }
        if (ioctl(s, TIOCSWINSZ, &ws) != 0) {
            _ = close(m);
            _ = close(s);
            return false;
        }
        master.* = m;
        slave.* = s;
        return true;
    }

    /// In the child: execve keeps ignored signals and the blocked mask, and
    /// a program that inherits them may not answer Ctrl-C. Async-signal-safe.
    fn resetSignals() void {
        var sig: c_int = 1;
        // SIGKILL, SIGSTOP and the ones libc keeps for itself just refuse.
        while (sig <= 64) : (sig += 1) _ = signal(sig, SIG_DFL);
        // All zero is the empty set; 128 bytes is sigset_t in glibc and musl.
        const none: [16]u64 = @splat(0);
        _ = sigprocmask(SIG_SETMASK, &none, null);
    }

    /// In the child: leaves it nothing of the parent's but the terminal. The
    /// descriptors are marked, not closed, so the report pipe lasts until
    /// execve. Async-signal-safe.
    fn closeOnExecFrom3(limit: c_int) void {
        const linux = std.os.linux;
        const r = linux.close_range(3, std.math.maxInt(i32), .{ .UNSHARE = false, .CLOEXEC = true });
        if (linux.errno(r) == .SUCCESS) return;
        // Kernels before 5.11.
        var n: c_int = 3;
        while (n < @min(limit, 65536)) : (n += 1) _ = fcntl(n, F_SETFD, @as(c_int, FD_CLOEXEC));
    }

    const Failure = extern struct {
        stage: enum(c_int) { setup, cwd, exec },
        code: c_int,
    };

    /// In the child: reports the failure and ends it. Async-signal-safe.
    fn childFailed(pipe: c_int, stage: @FieldType(Failure, "stage")) noreturn {
        const failure: Failure = .{ .stage = stage, .code = errno() };
        _ = sys_write(pipe, std.mem.asBytes(&failure), @sizeOf(Failure));
        _exit(127);
    }

    /// What the child reported, or null once the pipe closes without a report.
    fn readFailure(pipe: c_int) ?Failure {
        var failure: Failure = undefined;
        while (true) {
            // A report is written at once and is far below PIPE_BUF.
            const n = read(pipe, std.mem.asBytes(&failure), @sizeOf(Failure));
            if (n == @sizeOf(Failure)) return failure;
            if (n >= 0 or errno() != EINTR) return null;
        }
    }

    /// Moves `descriptor` to 3 or higher, close-on-exec.
    fn liftAboveStdio(descriptor: *c_int) bool {
        if (descriptor.* > 2) return fcntl(descriptor.*, F_SETFD, @as(c_int, FD_CLOEXEC)) == 0;
        const moved = fcntl(descriptor.*, F_DUPFD_CLOEXEC, @as(c_int, 3));
        if (moved < 0) return false;
        _ = close(descriptor.*);
        descriptor.* = moved;
        return true;
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

    /// How the child ended.
    pub const Exit = union(enum) {
        /// It exited with this status.
        exited: u8,
        /// This signal killed it.
        signaled: u8,
        /// It is gone and the status with it: something else reaped it, or
        /// this process ignores SIGCHLD.
        unknown,

        fn decode(status: c_int) Exit {
            const bits: u32 = @bitCast(status);
            const sig: u8 = @intCast(bits & 0x7F);
            return if (sig == 0) .{ .exited = @truncate(bits >> 8) } else .{ .signaled = sig };
        }
    };

    /// How the child ended, or null while it runs. Reaps it; later calls
    /// give the same answer.
    pub fn poll(self: *Pty) ?Exit {
        if (self.pid <= 0) return self.ended orelse .unknown;
        var status: c_int = 0;
        while (true) {
            const r = waitpid(self.pid, &status, WNOHANG);
            if (r == 0) return null;
            if (r > 0) break;
            switch (errno()) {
                EINTR => continue,
                ECHILD => return self.reaped(.unknown),
                // No news; the child is not forgotten on an unexplained error.
                else => return null,
            }
        }
        return self.reaped(.decode(status));
    }

    fn reaped(self: *Pty, exit: Exit) Exit {
        self.pid = 0;
        self.ended = exit;
        return exit;
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
