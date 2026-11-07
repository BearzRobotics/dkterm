DKTermCore — Specification
Status: Draft 0.1 — proposed extraction contract, not a claim of implemented functionality.

Engineering foundation: ai/AGENT.md in this repository. Where that document is unavailable, its requirements remain to be incorporated rather than invented.
1. Purpose
DKTermCore is a reusable, frontend-independent Zig terminal engine. Its initial consumers are DKTerm (a graphical Wayland terminal) and DKConsole (a standalone Linux virtual-terminal console). Neither consumer owns the engine, and DKTermCore must not depend on DKDE, DKTerm, or DKConsole.

The initial codebase is a copy of the former DKDE termcore. Extraction is not evidence that the API is stable or that every function belongs in the library.
2. Vision and principles
1. Independence: terminal state and protocol handling do not depend on a windowing toolkit, display server, compositor, or login manager.
2. Small, explicit interfaces: frontends provide input, rendering, transport, and platform-specific services.
3. Correctness: preserve terminal protocol behavior and byte-stream semantics across consumers.
4. Portability: support musl and glibc on Linux; avoid libc-specific extensions.
5. Honest maturity: both Zig and the upstream terminal engine are evolving; API and ABI stability are not promised yet.
3. Scope
3.1 In scope
- Initialize, own, resize, reset, and release terminal state through libghostty-vt.
- Accept PTY output as byte streams and expose changed terminal state to a frontend.
- Encode keys, text, mouse input, focus changes, and paste according to negotiated terminal modes.
- Expose screen cells, cursor, scrollback, selection-related data, and relevant terminal events as supported by the pinned engine.
- Provide a shared PTY/process adapter where code is genuinely identical between consumers, without forcing consumers to use it.
- Define frontend-neutral configuration structures and color schemes.
- Provide deterministic tests and a small headless test harness.
3.2 Out of scope
- GTK, GLib, GIO, Pango, Cairo, Wayland, labwc, DRM/KMS, evdev, fonts, and drawing.
- Login, PAM, getty replacement, seat/device permissions, session management, and service supervision.
- Desktop clipboard implementation, notifications, tabs, panes, windows, menus, and application preferences UI.
- Distribution-specific packaging and DKDE theme or global configuration policy.
4. Consumers and dependency rules
DKTerm (Wayland / GTK) ──────┐
                             ├──> DKTermCore ──> libghostty-vt
DKConsole (Linux VT) ────────┘
- DKTerm may also use DKDE's UI toolkit; DKConsole must not.
- DKTermCore imports neither consumer and no DKDE common module.
- libghostty-vt is an upstream dependency, pinned to an exact revision compatible with the chosen Zig compiler.
- Platform adapters must be isolated from the terminal engine. If PTY handling becomes Linux-specific, keep it in a separate optional module.
5. Public API design
Define a narrow Zig module API around these conceptual operations (names to be settled against actual code):
- Terminal.init(allocator, options) / deinit()
- feed(bytes) and resize(columns, rows)
- screen() / damage() / cursor() / scrollback()
- encodeKey(event) / encodeMouse(event) / encodePaste(bytes)
- pollEvents() or an explicit callback/event queue for title, bell, clipboard requests, hyperlinks, and mode changes
These are interface goals, not existing signatures. The terminal engine must not call a GTK widget or directly manipulate a Linux console. Document ownership and lifetime for returned slices, callback reentrancy, allocator behavior, and thread confinement before declaring an API usable externally.
5.1 PTY boundary
The engine processes terminal data; a PTY adapter owns spawning, file descriptors, signals, terminal size updates, and child exit status. Keep the adapter optional so other programs can feed recorded data, network streams, or tests without spawning a process.
5.2 Configuration
Use TOML for project-level configuration conventions, but do not force the terminal engine to read application configuration files. Consumers parse their own configuration and pass typed options to DKTermCore. A standalone TOML loader, if offered, must be optional and must not pull in DKDE dependencies.
5.3 Rendering contract
Expose a frontend-neutral view of cells, styles, colors, cursor, selection, and dirty regions. DKTerm renders with its graphical stack; DKConsole renders using its own console backend. Neither renderer belongs in DKTermCore.
5.4 Terminal color policy
NO_COLOR is a convention for programs that produce output, so a terminal engine applies it differently from a command-line tool.
- Faithful rendering: DKTermCore, DKTerm and DKConsole MUST render the SGR color and style sequences they receive exactly as sent. They MUST NOT strip, remap, or desaturate application colors because NO_COLOR is set in their own environment; deciding whether to emit color is the application's job.
- Child environment (DECISION TO CONFIRM): the PTY adapter passes the environment to child processes unmodified, so NO_COLOR is neither added nor removed. A consumer MAY offer an explicit user setting that exports or unsets NO_COLOR for children; it is a typed option passed to the engine, never implied.
- Terminal identification: the value of TERM given to children describes the terminal's real capabilities and MUST NOT be "dumb".
- Color schemes (the terminal's own palette, section 3.1) are presentation settings and are not affected by NO_COLOR.
- DKTerm and DKConsole's own command-line interfaces, diagnostics and any text they print themselves MUST follow the common rules:
- Reference policy: Core Utils SPEC §5.4 (~/de/core-utils/ai/SPECS.md). The rules below restate what this project must implement; if the two ever differ, resolve the difference deliberately rather than letting them drift.
- NO_COLOR: when the NO_COLOR environment variable is set to a non-empty string (any value, including "0"), color MUST NOT be added by default. An empty value is treated as unset. (Convention: https://no-color.org; wording paraphrased from memory, to be checked against the site at the next review.)
- Precedence, highest first: an explicit option (--color=always forces color, --color=never forbids it); configuration; NO_COLOR; automatic detection. Automatic detection enables color only when the output stream is a terminal and TERM is not "dumb".
- The decision is made per output stream: stderr is judged by whether stderr is a terminal, independently of stdout.
- NO_COLOR removes color only, as the convention says. Text styles that are not colors (bold, faint, italic, underline, reverse) are not affected by NO_COLOR and follow terminal detection. "Color" means any SGR parameter that sets a foreground or background color (30-37, 38, 39, 40-47, 48, 49, 90-97, 100-107). An explicit --color=never disables every SGR sequence, color and styles alike, because it is the explicit request for plain output (project decision, as bat does); TERM=dumb and a non-terminal stream under auto also get none. Where a tool uses color to tell things apart (for example gray for secondary text) it falls back to a non-color style such as faint when only color is off. Non-escape decorations such as line numbers and grids are controlled by their own options, not by NO_COLOR.
- Tests: each part that can emit SGR sequences needs tests for NO_COLOR set, set to empty, TERM=dumb, and overridden by an explicit option, with a terminal on the output stream.
- Engine tests (section 9) SHOULD include a headless case showing that colored input produces colored cells with NO_COLOR set in the environment.
6. Zig and C interoperability
- Primary distribution: Zig module, compiled as part of the consuming Zig application's build graph.
- C interoperability: a separately built, optional C ABI wrapper may be added when the Zig API is mature enough to specify opaque handles, ownership, errors, versioning, and callbacks.
- Current policy: no stable Zig API or C ABI guarantee. Any C wrapper is experimental until explicitly versioned and documented.
- Do not require a shared library or a C ABI when a Zig consumer imports the module.
7. Portability and dependencies
- Build and test for x86_64-linux-musl and x86_64-linux-gnu.
- Avoid glibc-only APIs and hardcoded dynamic loader paths.
- Keep runtime dependencies limited to the pinned terminal engine, Zig standard library, and any explicitly documented optional PTY/system interfaces.
- Use zig build as the canonical build entry point and pin an exact Zig version in build.zig.zon.
- No requirement for systemd, logind, D-Bus, GTK, or Wayland.
8. Reliability and security
- Treat PTY output as untrusted input; malformed escape sequences must not crash the consumer.
- Limit allocations, scrollback growth, sequence lengths, and event queues through explicit policies.
- Surface OSC 52 clipboard writes and OSC 8 links as requests, not automatic privileged actions; consumers decide whether to honor them.
- Never execute terminal escape sequences as shell commands.
- Ensure resize, child termination, partial writes, and interrupted reads are handled without corrupting terminal state.
9. Testing and acceptance
Unit tests
- Terminal creation, resize, reset, and teardown.
- UTF-8 and malformed byte streams; wrapping, wide cells, combining marks, alternate screen, and scroll regions.
- Key and mouse encoding, bracketed paste, synchronized output, and relevant OSC/CSI behavior supported by the pinned upstream version.
- Repeated initialization and destruction, bounded memory use, and error paths.
Integration tests
- Headless playback of captured terminal streams with expected screen snapshots.
- PTY smoke test using a simple child process, including resize and exit.
- DKTerm and DKConsole integration tests run in their own repositories.
- Compile and link checks on both musl and glibc.
Acceptance
DKTermCore is independently buildable and testable, neither consumer's source tree is needed, and both consumers can import the same pinned revision without private DKDE headers or modules.
10. Repository structure (proposed)
dktermcore/
├── ai/AGENT.md
├── SPEC.md
├── README.md
├── LICENSE
├── build.zig
├── build.zig.zon
├── src/
│   ├── root.zig
│   ├── terminal.zig
│   ├── input.zig
│   ├── events.zig
│   ├── colors.zig
│   └── pty/             # optional platform adapter
├── tests/
└── examples/
    └── headless.zig
This is a target organization, not a demand to rename existing files before functionality is verified.
11. Migration plan
1. Inventory the copied termcore source and classify each file as engine, optional PTY adapter, frontend code, or configuration glue.
2. Remove imports of DKDE common and application-specific paths.
3. Add a standalone build.zig, pinned build.zig.zon, public root module, and headless tests.
4. Move frontend-specific code back to DKTerm or DKConsole, preserving behavior.
5. Make DKTerm consume DKTermCore through its Zig dependency graph.
6. Make DKConsole consume the same library independently.
7. Remove the old DKDE in-tree copy only after both consumers build and pass regression tests.
8. Document upstream update procedure and explicitly track breaking API changes.
12. Versioning and maturity
Initial status: experimental / unstable. Pin exact commits in consumers. Semantic versioning and a stable C ABI are future decisions, not implied by an early version number. Changes to upstream libghostty-vt or Zig may require coordinated updates.
13. Deferred work
- Stable public Zig API and independently versioned C ABI.
- Standalone shared-library distribution for non-Zig applications.
- Advanced image/graphics protocols where supported upstream.
- Cross-platform PTY adapters beyond Linux.
- Performance benchmarks with published targets based on real measurements.
14. Open decisions
1. Confirm the exact Zig and libghostty-vt revisions used by the extracted copy.
2. Determine which copied PTY, INI, and color-scheme code is truly frontend-neutral.
3. Decide whether the optional PTY adapter is in the initial release or a separate package.
4. Define event ownership, error propagation, and thread-affinity rules from the actual implementation.
5. Choose concrete benchmarks after establishing baseline measurements.