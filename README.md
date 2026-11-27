# dkterm

DKTermCore: the terminal engine shared by the terminal programs in the DKDE family
(`dkde-term`, DKConsole). Zig 0.17.1. The specification is `ai/SPECS.md`.

It holds what does not depend on a window or a display:

| Module | What it does |
|---|---|
| `termcore.pty` | spawn a program on a pseudo-terminal, resize it, read and write it |
| `termcore.keymap` | Linux evdev codes, or GTK hardware keycodes, to libghostty-vt keys (libghostty-vt does the encoding) |
| `termcore.schemes` | colour schemes (`campbell`, `one-half-dark`, `solarized-dark`, `solarized-light`) |
| `termcore.glue` | libghostty-vt colour and palette setup for a scheme |
| `termcore.options` | optional: the frontend-neutral settings read from TOML with toml-zig |

Terminal state and escape-sequence parsing come from libghostty-vt (Ghostty), which this package
builds once and re-exports as the module `ghostty-vt`, so every consumer uses the same instance.

```zig
// build.zig.zon:  .dkterm = .{ .url = "...", .hash = "..." },
// build.zig:
const dkterm = b.dependency("dkterm", .{ .target = target, .optimize = optimize });
mod.addImport("termcore", dkterm.module("termcore"));
mod.addImport("ghostty-vt", dkterm.module("ghostty-vt"));
```

`-Dsimd=false` builds libghostty-vt without its C++ SIMD helpers (what a rescue console wants).
libghostty-vt is built in the mode you build in, so a `ReleaseSafe` build has safety checks in the
parser of untrusted output too (on one x86_64 machine they cost 6-13% of parsing speed). A Debug
build compiles it in `ReleaseSafe`: in Debug it checks itself on every linefeed.

## Running a program on a pseudo-terminal

The caller owns the event loop. `Pty.fd` is the master, non-blocking, to put in a `poll`.

```zig
const Pty = termcore.pty.Pty;
var pty = try Pty.spawn(gpa, .{ .path = "/bin/sh", .argv = &.{"sh"}, .env = &.{"TERM=xterm-256color"},
    .size = .{ .cols = 80, .rows = 24 } });
defer pty.deinit();
var outbox: termcore.pty.Outbox = .{};
defer outbox.deinit(gpa);

// Input: queue each message whole, then write what the terminal takes now.
try outbox.queue(gpa, &.{ "ls", "\r" });
try outbox.flush(gpa, &pty);
// While outbox.pending(), also poll for POLLOUT and flush again.

// Output, when fd is readable:
const n = pty.readSome(&buf) catch |err| switch (err) {
    error.HungUp => ..., // not necessarily the end; see below
    error.ReadFailed => ...,
};
if (pty.poll()) |exit| ... // .exited, .signaled or .unknown
```

- `spawn` fails, and starts nothing, if the child cannot take the terminal (`ChildSetupFailed`),
  enter `cwd` (`BadWorkingDirectory`) or run the program (`ExecFailed`). `failure_errno` receives
  the system's error number.
- The child gets the terminal as descriptors 0-2, default signal handling and an empty signal mask.
  Descriptors this process has open are not passed on.
- `Outbox` never drops input: `queue` takes all of a message or returns `OutboxFull` (8 MiB by
  default). `Pty.write` is the unbuffered form and returns how much was taken. Keep reading output
  while input waits.
- `error.HungUp` means nothing has the terminal open now. A running child can open it again, so end
  the session when `poll` reports an exit. Until then `fd` stays ready: wait a little before polling
  it again.
- `deinit` hangs up the terminal and sends SIGHUP and SIGTERM. A child still running after
  `Pty.grace_ms` (500 ms) is killed with its process group. It returns in bounded time.

## Settings

`termcore.options.Options.parse(gpa, toml_text, diag)` reads these top-level keys; anything else is
ignored and a missing or mistyped key keeps its default:

```toml
color-scheme = "campbell"
cursor-style = "block"       # block, bar or underline
scrollback-lines = 10000     # at most 1,000,000
osc52 = true
copy-on-select = true
command = ""                 # empty: the user's login shell
directory = ""
```

A frontend with defaults of its own reads the same keys with `Options.fromTableOver(table, base)`.
Text that is not valid TOML is an error, which the frontend handles.

Frontend-only settings (fonts, opacity, tabs, padding) belong to the frontend.

## Stability

No API or ABI stability is promised yet (see `ai/SPECS.md`); `CHANGELOG.md` lists what changed.
`zig build test` runs the tests. Some start real programs and need Linux, `/bin/sh`, `cat` and `stty`.

Release tarballs: `dkterm-VERSION.tar.gz` is the source (dependencies are fetched by `zig build`);
`dkterm-VERSION-vendored.tar.gz` also holds every dependency in `zig-pkg/`, so it builds with no
network (`zig build --system zig-pkg`). Each dependency there keeps its own license.

## License

Copyright (c) 2026 Dakota James Owen Keeler.

dkterm is free software under the GNU Library General Public License, version 2
or (at your option) any later version (`LGPL-2.0-or-later`). It comes with no
warranty. See `LICENSE`. Releases made before this change were published
under the MIT License.

libghostty-vt (Ghostty), which dkterm builds and re-exports, keeps its MIT License.
