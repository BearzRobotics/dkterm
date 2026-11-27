# Changelog

## 0.2.0

### License
dkterm is now under **LGPL-2.0-or-later**. Releases up to 0.1.1 were published under the MIT
License. libghostty-vt keeps its MIT License.

### API changes (all in `termcore.pty` unless noted)

| Was | Now |
|---|---|
| `Pty.writeAll(data)` | `Pty.write(data)` returns how much was taken; `Outbox` queues the rest |
| `readSome` returns `?usize` | returns `ReadError!usize`: `error.HungUp` (not necessarily final) or `error.ReadFailed` |
| `poll` returns `?u32`, a raw wait status | returns `?Pty.Exit`: `.exited`, `.signaled` or `.unknown` |
| `spawn` succeeds even when the program cannot run | new errors `ExecFailed`, `ChildSetupFailed`, `BadWorkingDirectory`; new `SpawnOptions.failure_errno` |
| a bad `cwd` runs the program where the caller is | `spawn` fails |

Added: `options.Options.fromTableOver`, for a frontend with its own defaults.

### Fixed
- Large input, such as a paste, was silently cut short when the program was slow to read it.
- `deinit` could block forever on a program that ignored SIGTERM.
- The program could lose stdin, stdout or stderr if the caller had one closed.
- It inherited the caller's open descriptors, ignored signals and blocked signals.
- `poll` reported a successful exit on later calls and when the status was lost.
- Reading into an empty buffer reported the terminal closed.
- F13-F24, the Japanese keys, keypad `=` and comma, and the copy, paste, media, browser and system
  keys had no mapping.
- The documentation of `glue.terminalColors` led to freeing the palette twice.
- Other comments and documentation that did not match the code.

### Build
libghostty-vt is built in your optimize mode instead of always `ReleaseFast`, so safe builds check
the parser of untrusted output. Debug builds compile it in `ReleaseSafe`.

### Tests
Every public function is now compiled by the tests, and they check what the child process receives,
the whole key table, every color scheme and every option. Before, 16 deliberate breakages all passed.
