# Repository Guidelines

## Source of Truth

- Read `README.md` and `docs/PURE_ZIG_REFACTOR.md` before changing behavior.
- Treat the capability coverage ledger in `docs/PURE_ZIG_REFACTOR.md` as the
  completion contract.
- Update the README and coverage ledger in the same change when public
  behavior or capability status changes.

## Toolchain and Scope

- Use Zig 0.16.0. Do not add compatibility code for Zig 0.15 or older.
- Keep the core implementation pure Zig. Do not compile or link WebUI,
  CivetWeb, or bundled C, C++, or Objective-C code.
- Use only the Zig standard library and the pinned Linsang dependency unless a
  new dependency is explicitly justified.
- Keep the public API Zig-native; do not recreate the old C ABI.
- Prioritize external-browser support. Keep native WebViews in a separate,
  optional module if they are added.

## Implementation Rules

- Implement complete end-to-end behavior, not placeholders or silent partial
  support. Report unsupported platform behavior through an explicit result.
- Reuse the existing module layout: public exports in `src/root.zig`, protocol
  code in `src/protocol.zig`, browser process code in `src/browser.zig`, and
  application lifecycle and routing in `src/app.zig`.
- Keep tests beside the Zig module they exercise. Keep browser bridge tests in
  `src/bridge.test.js`.
- Prefer Zig standard-library facilities and pass child-process arguments as
  argv. Never invoke a shell or interpolate user input into commands.
- Preserve explicit ownership and deterministic cleanup. Pair every retained
  resource, task, connection, and child process with shutdown and deinit logic.
- Treat network and protocol data as untrusted. Validate lengths, UTF-8,
  capabilities, origins, limits, paths, and state transitions before use.
- Listen on loopback by default. Non-loopback listening requires explicit
  public mode, caller-provided TLS, origin checks, and bounded resource limits.
- Never generate or silently accept a self-signed certificate.

## External Programs

- Building and using the library must not require Node, npm, esbuild, an
  installed browser, or a server-side JavaScript runtime.
- Probe an optional executable before relying on it. Missing, inaccessible, or
  invalid executables must return a documented error or unavailable result;
  they must not panic, hang, leak resources, or break unrelated features.
- Examples must log a useful warning and shut down cleanly when a browser or
  URL opener is unavailable.
- Tests that genuinely require an optional executable must detect its absence
  and skip only that test with a clear reason. CI and release validation must
  install the executable and run those tests rather than accepting a skip.
- Put timeouts on external-process and browser-dependent tests. Always
  terminate and reap children during replacement, failure, and shutdown.
- Node-based bridge tests must use Node's built-in test runner only; do not add
  npm dependencies or require Node to build the package.

## Testing Requirements

- Every functional change must include a focused unit or integration test in
  the same change.
- Every non-trivial parser needs at least one direct test. Cover valid input,
  truncation, malformed lengths, invalid values, unknown commands, and limits.
- Cover both success and failure paths for external programs, including the
  executable-not-found case.
- Integration tests must cleanly exercise HTTP, WebSocket, bridge calls,
  disconnects, cancellation, and deterministic shutdown where relevant.
- Use `std.testing.allocator` for core tests and leave no leaks.
- Run the smallest relevant test while developing, then run:

```sh
zig build test
zig build
```

- Before declaring parity or preparing a release, also run:

```sh
zig build -Dtarget=x86_64-linux
zig build -Dtarget=aarch64-linux
zig build -Dtarget=x86_64-windows
zig build -Dtarget=x86_64-macos
zig build -Dtarget=aarch64-macos
rg 'webui_new|pub extern fn webui_' src
```

- Do not mark a capability complete when required tests were skipped.

## Commit Messages

- Follow Conventional Commits: `<type>(<scope>): <subject>`.
- Write commit messages in English.
- Do not include any LLM-related information in commits.
- Split large changes into separate commits by distinct purpose.
