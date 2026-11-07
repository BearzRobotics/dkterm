# dkterm

DKTermCore: the terminal engine shared by the terminal programs in the DKDE family
(`dkde-term`, DKConsole). Zig 0.17.1. The specification is `ai/SPECS.md`.

It holds what does not depend on a window or a display:

| Module | What it does |
|---|---|
| `termcore.pty` | spawn a program on a pseudo-terminal, resize it, read and write it |
| `termcore.keymap` | key events (GDK-style key values or evdev codes) to terminal input |
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
Debug builds still compile libghostty-vt in ReleaseFast: in Debug it checks itself on every linefeed.

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

Frontend-only settings (fonts, opacity, tabs, padding) belong to the frontend.

## Stability

No API or ABI stability is promised yet (see `ai/SPECS.md`). `zig build test` runs the tests.
