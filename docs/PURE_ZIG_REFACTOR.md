# zig-webui Pure Zig Refactor Plan

## Goal

Rebuild zig-webui from a Zig wrapper around the WebUI C library into a WebUI
implementation written in Zig:

- Do not compile or link the WebUI C library or CivetWeb.
- Use Linsang for HTTP, WebSocket, and TLS.
- Implement the WebUI protocol, window state, bindings, browser launching, and
  resource routing in Zig.
- Allow breaking Zig API changes without preserving the C ABI shape.
- Support external browsers first. Evaluate native WebViews later as a
  separate module.

Here, pure Zig means the core package and its dependencies contain no bundled
C, C++, or Objective-C implementation. Calling the operating system through
the Zig standard library and launching an installed browser remain in scope.

## Current Rewrite Status

Status snapshot: 2026-09-09.

The external-browser core is now implemented in Zig on top of pinned Linsang.
The legacy wrapper, C API, compatibility files, and examples have been
deleted.

| Area | Status |
|---|---|
| Server and security | HTTP, WebSocket, TLS, loopback/public policy, capabilities, upgrade-bound Origin/cookie authorization, bounded authentication/liveness, and protocol limits are implemented. |
| Browser bridge | Runtime bindings and events with `ADD_ID` replay, typed arguments/replies, bounded FIFO or concurrent handlers, deferred replies, total-deadline evaluation, raw data, navigation, high contrast, bounded `MULTI`, multiple clients, keepalive, reconnect, and status UI are implemented. |
| Content and lifecycle | HTML, directories, custom handlers, external URLs, runtime content replacement, default directories, favicons, directory monitoring, Deno/Node.js/Bun script interpretation, logging, and deterministic shutdown are implemented. |
| Browser integration | Centring, app-mode window launching through browser discovery with managed per-browser profiles and Chromium default arguments, OS URL opening as the fallback, explicit browser selection, custom executables and argv, persistent initial/runtime size and position, kiosk and headless modes, Chromium forced-color control, caller-managed and deletable managed profile directories, Chromium-family proxy rules, Windows external-browser focus, backend and direct-child process IDs, replacement, and shutdown cleanup are implemented. |
| Native integration | Optional Zig-only WKWebView, GTK3/WebKitGTK 4.1 and Win32/WebView2 backends implement native controls, UI-thread dispatch, close veto/history-safe JavaScript close, multiwindow pumping, and borrowed handles. Actual runtime gates pass on all three platforms. |
| Current validation | Linux CI: 54/54 core tests and 15/15 bridge tests. Native smoke passes on Linux/macOS/Windows; Linux missing-display and Windows missing-loader checks pass. All five cross-target builds pass. Protocol fuzzing completed 101,191 executions without failure; hardened Linsang passes all 107 Linux tests. |

The pure Zig rewrite is complete against this ledger: every capability has a
concrete implementation or an intentional Zig-native replacement, and the
required runtime/build gates have passed. The package remains experimental;
capability completion is not a production-readiness or bug-free guarantee.
The coverage ledger below is the authoritative method-level list.

## Original Baseline

| Component | Status |
|---|---|
| Original zig-webui | `webui.zig` was about 1,334 lines and `c.zig` about 1,188 lines; most code forwarded the C API |
| Capability reference | WebUI `2.5.0-beta.4` at `337a183cea0a9c5daee16acb77eed2d5443bbbb0` |
| Upstream WebUI | Its core is the roughly 14,500-line `src/webui.c`, mixing protocol, server, browser, WebView, and process management |
| Browser bridge | About 1,006 lines of TypeScript using the 8-byte WebUI binary header |
| Linsang | Zig 0.16 with HTTP/1.1, WebSocket, static files, TLS, and connection lifecycle support |
| Linsang validation | All 101 tests pass at `3b50417e3ddb7a0651a8dd8b7154f26c4d4e5608` |

[Linsang issue #1](https://github.com/jinzhongjia/Linsang/issues/1) added a
reference-counted `WebSocketPeer`, immediate cross-task sends, safe send/close
races, and synchronous access to the actual `port = 0` address through
`Running.address`.

## Product Boundaries

### Complete capability parity target

- Cover every user-visible capability in upstream WebUI `2.5.0-beta.4` at
  commit `337a183cea0a9c5daee16acb77eed2d5443bbbb0`.
- Use Zig-native ownership, errors, names, and types instead of copying C
  signatures.
- Treat the API coverage ledger as the completion contract. Every entry must
  end as implemented or as an explicit Zig standard-library replacement.

### Required for the first release

- One application managing multiple windows.
- Embedded HTML, static directories, and external URLs.
- An automatically served browser bridge.
- Zig bindings with string, number, boolean, and binary arguments.
- JavaScript-to-Zig calls with results.
- Zig-to-JavaScript calls for one client or broadcasts, with results and
  timeouts.
- Connected, disconnected, click, and navigation events.
- Default-browser launching and explicit or automatic ports.
- Loopback listening by default; public listening must be explicit.
- Deterministic shutdown of listeners, clients, windows, and tasks.

### Permanent non-goals

- A C API, `src/c.zig`, extern struct ABI, or interface compatibility APIs.
- Zig 0.14 or 0.15 compatibility. Zig 0.16 is the baseline.
- Automatic self-signed certificate generation.

### Native platform boundaries

Native window APIs live in `webui.native`, never in a bundled C implementation.
All operations run on the UI owner thread; bounded dispatch connects worker
callbacks to that thread. Linux uses dynamically loaded GTK3/WebKitGTK 4.1,
Windows uses an installed WebView2 runtime/loader, and macOS uses system
AppKit/WebKit frameworks. Missing dependencies return explicit errors.

Upstream's transparent native windows are implemented on Windows and composited
X11. Public macOS WKWebView APIs do not offer that capability, and upstream's
macOS adapter does not implement it either. Wayland coordinate queries/moves and
arbitrary macOS native profile paths return explicit unsupported errors.

## Do Not Translate `webui.c` Line by Line

Zig or Linsang directly replaces these upstream components:

| Upstream implementation | Replacement |
|---|---|
| CivetWeb HTTP/WebSocket/TLS | Linsang |
| malloc/free/ptr_list | Zig allocators and explicit ownership |
| Global `WEBUI_MAX_IDS` arrays | Dynamic window and client state owned by `App` |
| pthread/Win32 mutexes and conditions | `std.Io` tasks and limited synchronization |
| MIME, base64, path, and random helpers | Zig standard library or Linsang |
| One server and port per window | One server per `App`, routed by window capability |
| C ABI events and manual value decoding | Zig `Call` and `Event` types |

Only WebUI-specific behavior needs a Zig implementation:

- bridge packet parsing and encoding;
- token and capability validation;
- window, client, and binding state;
- request and response correlation;
- browser discovery and launching;
- embedded HTML, directory, and custom response routing.

## Protocol Strategy

The rewrite keeps the existing WebUI bridge behavior and 8-byte header so
the front end and back end do not change simultaneously:

```text
0      signature  0xDD
1..4   token      little-endian u32
5..6   request id little-endian u16
7      command
8..    payload
```

Support `CHECK_TK`, `CALL_FUNC`, `CLICK`, `JS`, `JS_QUICK`, `NAVIGATION`,
`CLOSE`, `SEND_RAW`, and `MULTI`. The bridge splits browser-to-Zig protocol
packets at 65,500 bytes; Zig strictly validates the announced total length,
reassembles chunks per authenticated client, and applies the configured
WebSocket message limit to the complete packet.

`CHECK_TK` carries the 128-bit window capability in its payload. Successful
authentication permanently associates that WebSocket connection with one
window.

Commit the distributable JavaScript bridge as a repository asset. Building
zig-webui must not require Node, npm, or esbuild. Preserve upstream MIT
licensing and attribution. A second protocol version can be considered after
the protocol is stable; it is not a prerequisite for the pure Zig refactor.
The current plan does not include a WASM bridge.

Public network mode cannot rely only on the legacy 32-bit token. The legacy
protocol may remain loopback-only initially. Public mode requires a
high-entropy URL capability, Origin validation, and explicit TLS configuration.

## Proposed API Shape

Center the API on ownership and lifecycle instead of mirroring C handles:

```zig
var app = webui.App.init(gpa, .{});
defer app.deinit();

const window = try app.createWindow(.{
    .content = .{ .html = @embedFile("index.html") },
});
try window.bind(io, "sum", sum, null);

var running = try app.start(io);
defer running.stop() catch {};

try window.open(io, &running);
try running.wait();
```

`window.open()` discovers the best installed browser and launches it as a
standalone app window with a managed profile. Use
`window.openWithBrowser(&running, options)` when explicit browser selection, a
custom executable, or additional argv is required.

Start with one explicit type-erased handler signature:

```zig
fn sum(call: *webui.Call, user_data: ?*anyopaque) !void {
    _ = user_data;
    try call.replyInt(try call.int(0) + try call.int(1));
}
```

The core has only four objects:

- `App`: allocator, Linsang server, window state, and shutdown.
- `Window`: lightweight handle referencing an `App` and window ID.
- `Client`: safely retained connection handle for single-client sends.
- `Call`: arguments, client, and one response for the current invocation.

Automatic adaptation of arbitrary Zig function signatures is a convenience
layer to reconsider only after the core works.

## Minimal Module Layout

```text
src/
  root.zig       public exports
  app.zig        App, Window, Client, routing, bindings, and lifecycle
  protocol.zig   WebUI packet parsing and encoding
  browser.zig    browser discovery and launching through std.process
  bridge.js      browser bridge embedded at build time
```

Keep tests beside their modules. Split `app.zig` only when it develops a clear
independent responsibility.

## Implementation Phases

### 0. Linsang prerequisites (complete)

- `WebSocketPeer` can cross task boundaries with paired `clone` and `deinit`.
- `sendText` and `sendBinary` write immediately and serialize concurrent sends.
- Send/close races return `Closed` or `Canceled` without use-after-free or
  deadlock.
- `Running.address` contains the actual listening port when `start` returns.
- Plaintext and TLS use identical send semantics.

Acceptance: all 101 tests pass at `3b50417`.

### 1. Minimal vertical slice (complete)

- Pin `build.zig.zon` to the Linsang commit.
- Remove the WebUI artifact and `linkLibrary` from `build.zig`.
- Add one `App`, one server, one window, and automatic port selection.
- Serve embedded HTML and the bridge.
- Implement token validation, connection handling, one Zig binding, and its
  response.
- Open the default browser through `std.process`.

Acceptance: the minimal example passed a real Chromium JavaScript-to-Zig call
and clean shutdown; `zig build test` passes; the build graph contains no C.

### 2. Bidirectional calls (complete)

- Implemented single-client `Window.eval` with request IDs.
- Implemented results, JavaScript errors, timeouts, and disconnect cleanup.
- Implemented `Client.run` and broadcast `Window.run` with `JS_QUICK` for
  fire-and-forget JavaScript.
- Implemented stable `Client` handles and targeted `Client.eval`.
- Implemented targeted navigation, close, and raw binary operations.
- Implemented broadcast `Window.evalAll` in the multi-client work.

Acceptance: the call-js-from-zig example passes, and an idle connection
immediately receives Zig-initiated messages. Complete.

### 3. Resources, multiple clients, and events (complete)

- Implemented `.html` and `.directory` content.
- Implemented buffered custom resource handlers using Linsang `Request` and
  `Response` directly.
- Implemented `.external_url`; `Window.bridgeUrl` gives caller-owned pages the
  capability-scoped bridge, which connects back to the script's origin.
- Implemented multiple windows with isolated capability-based routes.
- Implemented a bounded collection of stable `Client` handles; one client is
  the default and `WindowOptions.max_clients` explicitly enables more.
- Implemented a bounded pending-eval table keyed by client and request ID.
- Implemented `Window` navigation, close, raw-data, and evaluation broadcasts.
- Implemented one `Window.onEvent` handler for connected, disconnected, click,
  and intercepted navigation events.

Acceptance: integration tests cover isolated resources, multiple windows,
multiple clients, external bridge routing, lifecycle events, click and
navigation events, and disconnect cleanup. Complete.

### 4. Browser and security completion

- Start with the operating system URL opener.
- Add explicit Chromium or Firefox app-window, kiosk, and sizing flags only
  when required.
- Pass every command as argv without shell interpolation.
- Listen on loopback by default.
- Require a high-entropy capability, Origin validation, and connection,
  message, and call limits for public listening.
- Accept caller-provided TLS certificates; never silently create self-signed
  certificates.

Acceptance: Linux runtime tests and Windows/macOS cross-builds pass; malformed
protocol input never panics.

### 5. Delete the old implementation and publish a breaking release

- Deleted `src/c.zig`, `src/webui.zig`, `src/tests.zig`, both compatibility
  tuple files, and the legacy examples.
- Retain the pure Zig minimal example.
- Document only the new API and lifecycle in the README.
- Publish a new major or alpha release. Naming can be decided then and does not
  block implementation.

## Old API Migration

| Old API | New direction |
|---|---|
| `webui.newWindow()` | `app.createWindow(options)` |
| `window.show(content)` | Set initial content and call `window.open()`; use `window.setContent()` while running. |
| `window.bind()` / `binding()` | `window.bind(io, name, handler, user_data)` |
| `Event.get*At()` | `Call.string/int/float/bool/bytes(index)` |
| `Event.return*()` | `Call.reply*()` |
| `window.run()` | `Window.eval()` |
| `Event.runClient()` | `Call.client.eval()` |
| `setRootFolder()` | Initial `.directory` content or runtime `Window.setContent()`. |
| `setDefaultRootFolder()` | `App.Options.default_directory` and an omitted window `content`. |
| `setIcon()` / `setIconFile()` | `Window.setIcon()` / `Window.setIconFile()`. |
| Global `setConfig()` | `App.Options` or `Window.Options` |
| `wait()` / `clean()` | `Running.wait()` / `App.deinit()` |
| `malloc/free/memcpy/encode/decode` | Zig allocators and standard library |
| `interface*` | Delete |
| `newWindowWithId()` | Delete; `App` owns IDs |

## Upstream WebUI API Coverage Ledger

This ledger tracks upstream WebUI `2.5.0-beta.4` at commit
`337a183cea0a9c5daee16acb77eed2d5443bbbb0`. Upstream C names are identifiers
for traceability, not a commitment to reproduce the C API shape in Zig.
Coverage is determined only from `src/root.zig` and its reachable pure Zig
modules. Deleted legacy wrapper, test, and example files do not count as
implementations.

### Native and Browser Window Capabilities

Native implementation entries below require the platform runtime gates in
addition to compilation. Native API options/geometry are independent of
external-browser launch flags.

| Upstream API | Zig implementation |
|---|---|
| `webui_set_kiosk()` | `App.WindowOptions.kiosk` for supported external browsers; `native.Window.setKiosk()` for native windows. |
| `webui_set_hide()` | `App.WindowOptions.hide` for headless external browsers; `native.Options.hidden` and `native.Window.setVisible()` for native windows. |
| `webui_minimize()`, `webui_maximize()` | `native.Window.minimize()`, `maximize()`, and `restore()`. |
| `webui_set_resizable()`, `webui_set_minimum_size()` | `native.Options` and `native.Window.setResizable()` / `setMinimumSize()`. |
| `webui_set_frameless()`, `webui_set_transparent()` | Native options and setters. Windows transparency configures both host composition and WebView background; X11 requires RGBA/compositing. macOS transparency is explicitly unsupported, as upstream's native adapter does not implement it. |
| `webui_show_wv()`, `webui_set_close_handler_wv()` | `native.Window.open()` plus `setCloseHandler()`. User/JavaScript close can be vetoed before destroying the page; `native.Window.close()` force-closes. |
| `webui_get_hwnd()`, `webui_win32_get_hwnd()` | `native.Window.handle()` returns a borrowed tagged Cocoa/Gtk/Win32 handle, invalid after close/deinit. |

### Browser Bridge APIs

The browser-side `webui` object implements `call()`, `isConnected()`,
`setLogging()`, `encode()`, `decode()`, `setEventCallback()`, `event`,
`isHighContrast()`, and `allowNavigation()`. Encoding delegates to `btoa()`
and `atob()`, while high-contrast detection uses native browser media
queries. The upstream bridge's `callCore()` method remains an internal
implementation detail.
`Window.bind(io, ...)` and `Window.onEvent(io, ...)` support synchronized
runtime replacement. Registration replay precedes `CONNECTED`; safe names also
expose `webui.<binding>()`, without overwriting core or prototype properties.

Call correlation reserves IDs 1–65,535 until completion, send failure, or
disconnect. Allocation skips outstanding IDs on wrap and rejects only the new
call when exhausted, instead of overwriting an earlier promise as upstream can.
Backend evaluation IDs are also quarantined after timeout/cancellation until a
late result or disconnect releases them. Exhaustion returns an explicit error;
late results cannot resolve unrelated requests after wrap.
The bridge retries transport loss after 500ms and reauthenticates each socket,
with a five-second connection/authentication deadline. Authenticated text
`ping`/`pong` exchanges run every 20 seconds with a ten-second reply deadline.
All other client text is rejected, and heartbeat traffic does not disturb
binary `MULTI` reassembly. Pending calls reject without replay on loss; old
socket messages and asynchronous evaluation results cannot cross sessions.
Authentication denial, protocol/policy failures, backend close, and page unload
stop retries. A nonblocking loss banner is suppressed when the application
installs its own event callback. Reconnect does not extend `Running.wait()`'s
1.5-second grace period or survive a changed backend capability.

### Intentional Zig Replacements

The following upstream methods are covered by the current Zig design and are
not implementation gaps:

| Upstream API | Zig replacement |
|---|---|
| `webui_new_window()`, `webui_new_window_id()`, `webui_get_new_window_id()` | `App.createWindow()` and application-owned IDs. |
| `webui_show()`, `webui_start_server()`, `webui_get_url()` | Initial `Content`, runtime `Window.setContent()`, `App.start()`, `Window.open()`, and `Window.url()`. `Window.open()` launches the best installed browser in app mode and falls back to the OS URL handler, matching upstream `webui_show()` with `AnyBrowser`. |
| `webui_show_client()` | `Client.show()` replaces the window content and navigates only the selected client. |
| `webui_is_shown()` | `Window.isShown()` reports whether the window has at least one connected browser client. |
| `webui_set_center()` | `App.WindowOptions.center` and `Window.setCenter()` centre the window on the primary display. Upstream reads the monitor geometry natively, which needs GDK on Linux; the browser computes the coordinates instead, so centring applies once a client connects rather than at launch. Centring and an explicit position clear each other. |
| `webui_focus()` | `Window.focus()` restores and focuses the visible top-level window belonging to the retained browser child on Windows. Missing children, invalid process handles, unavailable windows, and rejected foreground requests return explicit errors; Linux and macOS return `error.UnsupportedPlatform` instead of silently doing nothing. |
| `webui_delete_profile()`, `webui_delete_all_profiles()` | `Window.deleteProfile()`, `deleteManagedProfile()`, and `deleteAllManagedProfiles()` remove generated profile directories only. A window configured with `.profile_directory` returns `error.CallerManagedProfile`; caller-owned directories are never deleted. |
| `webui_set_size()`, `webui_set_position()` | `App.WindowOptions.size` and `.position` set initial geometry. `Window.setSize()` and `Window.setPosition()` persist updates, notify connected clients, replay the latest geometry to later clients, and affect subsequent explicit browser launches. |
| `webui_set_high_contrast()`, `webui_is_high_contrast()` | `App.WindowOptions.high_contrast` controls Chromium forced-color support with explicit unsupported-browser errors. Browser-side `webui.isHighContrast()` uses native forced-color and contrast media queries without external programs. |
| `webui_open_url()` | `openUrl()` safely passes a non-empty URL as one argument to the platform default opener. |
| `webui_get_best_browser()`, `webui_browser_exist()` | `bestBrowser()` and `browserExists()` discover registered or executable browser candidates through the public `Browser` enum. |
| `webui_show_browser()`, `webui_set_browser_folder()`, `webui_set_custom_parameters()` | `Window.openWithBrowser()` accepts a `BrowserLaunchOptions` value with an explicit browser, optional full executable path, and additional argv. An empty argv applies the Chromium default arguments; a non-empty argv replaces them, matching upstream `custom_parameters`. |
| `webui_get_child_process_id()` | `Window.openWithBrowser()` returns the retained direct child's `BrowserProcessId`; `Window.browserProcessId()` retrieves it later. |
| `webui_get_parent_process_id()` | Root-level `parentProcessId()` returns the current Zig backend's numeric process ID without a redundant window argument. Unsupported process targets return an explicit error. |
| `webui_set_default_root_folder()` | `App.Options.default_directory` supplies directory content to windows created without explicit content. |
| `webui_set_runtime()` | `App.WindowOptions.runtime` selects Deno, Node.js, or Bun for served `.js` and `.ts` files, including `index.ts`/`index.js` directory resolution. The interpreter is spawned as argv rather than through a shell. Unlike upstream's empty `200`, unavailable executables answer `503`, timeouts `504`, and output-limit violations or unsuccessful exits `502`; failed stdout and diagnostics are never served. |
| `webui_set_config(folder_monitor)` | `App.Options.folder_monitor_interval` enables portable recursive directory polling and reloads the affected window's connected clients. |
| `webui_set_icon()`, `webui_set_icon_file()` | `Window.setIcon()` copies inline data and MIME type; `Window.setIconFile()` loads a supported image file as the window favicon. |
| `webui_set_profile()` | Caller-managed browser profiles remain supported. Default Chromium processes use distinct per-window capability leaves under managed family roots, preventing cross-window process handoff. Replacement stops/reaps the previous child before launch; explicit deletion never removes a caller profile. |
| `webui_set_proxy()` | `App.WindowOptions.proxy_server` is copied and passed as one Chromium-family `--proxy-server` argument. Unsupported browsers return an explicit error. |
| `webui_wait()`, `webui_wait_async()` | `Running.wait()` used directly or through `std.Io` concurrency. Matching upstream `WEBUI_RELOAD_TIMEOUT`, a disconnect that was not requested by a backend `close` gets a 1.5-second reconnect grace period before the wait ends, so reloads and navigations survive. |
| `webui_close()`, `webui_destroy()`, `webui_exit()`, `webui_clean()` | `Window.close()`, `Running.stop()`, and `App.deinit()`. |
| `webui_set_context()`, `webui_get_context()` | Binding and event-handler `user_data`. |
| `webui_bind()` | `Window.bind(io, name, handler, user_data)` supports explicit calls, DOM clicks, and runtime replacement. `Window.onEvent(io, handler, user_data)` updates event handling. `CMD_ADD_ID` pushes new registrations and authentication replays current state; in-flight work keeps its handler snapshot. |
| `webui_get_count()`, `webui_get_size()`, `webui_get_size_at()` | `Call.arguments.len` and `Call.bytes(index).len`. |
| `webui_get_string()`, `webui_get_string_at()`, `webui_get_int()`, `webui_get_int_at()`, `webui_get_float()`, `webui_get_float_at()`, `webui_get_bool()`, `webui_get_bool_at()` | `Call.string()`, `Call.int()`, `Call.float()`, and `Call.boolean()`. |
| `webui_return_string()`, `webui_return_int()`, `webui_return_float()`, `webui_return_bool()` | `Call.reply()`, `Call.replyInt()`, `Call.replyFloat()`, and `Call.replyBool()`. |
| `webui_set_config(asynchronous_response)` | `Call.deferReply()` transfers the response to a bounded, owned, one-shot `PendingReply`. |
| `webui_set_config(ui_event_blocking)`, `webui_set_event_blocking()` | `WindowOptions.event_mode` and `Window.setEventMode()` select serial or bounded concurrent binding and event execution. |
| `webui_set_config(show_wait_connection)`, `webui_set_timeout()` | `Window.open()` remains non-blocking; callers explicitly compose it with `Window.waitForConnection(io, timeout)`. |
| `webui_run()`, `webui_script()` | `Window.run()` and `Window.eval()`. |
| `webui_run_client()`, `webui_script_client()` | `Client.run()` and `Client.eval()`. |
| `webui_close_client()`, `webui_navigate_client()`, `webui_send_raw_client()` | `Client.close()`, `Client.navigate()`, and `Client.sendRaw()`. |
| `webui_navigate()`, `webui_send_raw()` | `Window.navigate()` and `Window.sendRaw()`. |
| `webui_set_config(multi_client)` | `WindowOptions.max_clients`. |
| `webui_set_config(use_cookies)` | `App.Options.use_cookies` adds a per-window, path-scoped `HttpOnly` authorization cookie while retaining capability URLs and protocol authentication. Matching upstream, a single-client window is locked to the first client that receives the cookie: later cookieless content requests answer `403` and cookieless WebSocket upgrades are refused. Multi-client windows hand the cookie to every client and never block. |
| `webui_set_logger()` | `App.Options.logger` and `logger_user_data`; messages use `std.log.Level` and fall back to `std.log` when no callback is set. |
| `webui_set_public()` | `App.Options.public` permits non-loopback listening only with TLS; Origin and explicit connection and protocol limits are enforced. |
| `webui_set_tls_certificate()` | `App.Options.tls` accepts caller-provided PEM certificate and private-key bytes. |
| `webui_set_port()`, `webui_get_port()`, `webui_get_free_port()` | `App.Options.port`, including `0` for automatic selection, and the running window URL. |
| `webui_set_root_folder()`, `webui_set_file_handler()`, `webui_set_file_handler_window()`, `webui_return_http()` | Initial or runtime `.directory` and `.custom` content through `Content`, `Window.setContent()`, and `Response`. |
| `webui_get_mime_type()` | Linsang resource handling. |
| `webui_encode()`, `webui_decode()`, `webui_malloc()`, `webui_free()`, `webui_memcpy()` | Zig standard library and allocators. |
| `webui_get_last_error_number()`, `webui_get_last_error_message()` | Zig error unions. |
| `webui_interface_*()` | Permanently omitted with the C ABI compatibility layer. |

## Capability Parity Implementation Order

Each work package must add its focused unit or integration checks and update
the coverage ledger in the same commit.

### Network trust boundary

- Add explicit loopback and public listening modes.
- Implement caller-provided TLS certificate and private-key configuration.
- Validate WebSocket Origin values.
- Add connection, unauthenticated connection, WebSocket message, binding
  name, call payload, argument, script, and pending-call limits.
- Implement optional cookie authorization without weakening capability URLs.

This completes the behavior represented by `webui_set_public()`,
`webui_set_tls_certificate()`, and `webui_set_config(use_cookies)`.

### Calls, bindings, and browser bridge (complete)

- Implements the public bridge methods listed above, authenticated keepalive,
  reconnection, connection-loss UI, synchronized runtime bindings and replay.
- Preserves string, number, boolean, and `Uint8Array` call arguments.
- Implements bounded `MULTI` fragmentation for large browser-to-Zig calls and
  JavaScript results, including strict length parsing and per-client cleanup.

Typed argument/return methods, runtime `webui_bind()` updates, and `CMD_ADD_ID`
are implemented and covered by integration and bridge regressions.

### Handler and event lifecycle (complete)

Implements asynchronous replies, bounded FIFO serial or independent concurrent
handlers, connection waiting, and logging. The receiver never executes user
handlers inline, so a serial handler may evaluate JavaScript on its own client.

### Dynamic content and client state (complete)

This completes `webui_show()`, `webui_show_client()`, `webui_is_shown()`,
the dynamic root and file-handler methods, `webui_set_default_root_folder()`,
`webui_set_icon()`, and `webui_set_icon_file()`.

### Managed browser launch (complete)

Browser discovery, default URL opening, explicit browser selection, custom
executable paths and argv, the process-wide backend identifier, per-window
direct child identifiers, replacement, and shutdown cleanup are implemented.

This completes the browser discovery, selection, custom-parameter, and direct
child tracking methods in the ledger.

### Browser window controls

- Initial kiosk, hide, size, and position options generate direct browser argv
  with explicit validation and unsupported-browser errors. Runtime size and
  position persist and use the existing quick-script protocol.
- Profile directories and proxy rules are copied into window state and passed
  as individual browser argv entries. Chromium-family browsers support both;
  Firefox supports profiles; Safari supports neither.
- Chromium can explicitly disable forced-color support; the browser bridge
  detects active high-contrast media preferences.
- Windows external-browser focus enumerates visible top-level windows owned by
  the retained browser child, restores a minimized match, and requests the
  foreground. Other platforms return `error.UnsupportedPlatform`.
- Native options/setters implement minimize, maximize, resizable, minimum size,
  geometry, frameless, visible and transparent behavior through the optional
  platform adapters; explicit platform limitations are listed above.

### File monitoring (complete)

Portable recursive directory polling reloads only the clients of a changed
directory window and follows runtime content replacements.

This completes `webui_set_config(folder_monitor)`.

### Server-side runtimes

- Run served JavaScript and TypeScript through explicitly selected Deno,
  Node.js, or Bun executables.
- Keep runtime execution disabled by default and pass commands as argv.
- Return explicit interpreter failure responses: `503` for unavailable
  executables, `504` for timeout, and `502` for output limits or unsuccessful
  exits. Keep diagnostics in the logger, not the HTTP body. This deliberately
  improves upstream's misleading empty-success behavior.

This completes `webui_set_runtime()`.

### Native WebViews

- `src/native.zig` owns the public UI-thread facade and bounded dispatch queue.
- `src/native/{macos,linux,windows}.zig` implements system framework ABIs without
  bundled C, C++, or Objective-C.
- Close interception uses document-start native messaging so veto and navigation
  history remain valid; one toolkit pump services other windows too.
- Reentrant destruction during callbacks is rejected. COM late completions and
  native delegate/signal ownership have explicit cleanup.

This implements `webui_show_wv()`, `webui_set_close_handler_wv()`, and native
handles. A separate ABI/ownership review was performed for every platform;
the public API stays Zig-native, and runtime verification remains mandatory.

### Parity closure

- All ledger rows now have a concrete implementation or intentional replacement.
- Retained examples cover bindings, dynamic content, public TLS, managed
  browsers, runtimes, and native WebViews.
- `zig build fuzz --fuzz=100K`, real browser/native scenarios, leak checks, and
  the five-target builds form the release gate; CI installs optional runtimes
  rather than treating executable absence as coverage.

## Tests and Completion Criteria

Keep at least one direct test for every non-trivial parser. The final gate is:

```text
zig build test
zig build test-bridge
zig build fuzz --fuzz=100K
zig build test-native -Dnative=true
zig build -Dtarget=x86_64-linux
zig build -Dtarget=aarch64-linux
zig build -Dtarget=x86_64-windows
zig build -Dtarget=x86_64-macos
zig build -Dtarget=aarch64-macos
```

- Protocol tests cover every command, truncated packets, invalid lengths,
  invalid tokens, and unknown commands.
- `zig build test` skips browser bridge tests with a warning when Node is
  unavailable; `zig build test-bridge` requires Node for CI and release gates.
- Node's built-in test runner covers browser bridge command behavior without
  npm dependencies.
- Integration tests cover HTTP content, WebSocket handshake, JavaScript-to-Zig,
  Zig-to-JavaScript, disconnect, and shutdown.
- Integration tests cover fragmented browser calls across multiple WebSocket
  messages and verify the reassembled argument and reply.
- Fuzz input never panics or reads out of bounds. Messages and pending calls
  have explicit limits.
- `rg 'webui_new|pub extern fn webui_' src` returns no results.
- The build graph contains only the Zig standard library and pinned Linsang,
  with no WebUI or CivetWeb artifact.
- Core integration tests leak no memory under the debug allocator.

## Main Risks

1. **Linsang peer lifecycle:** The required primitive exists. zig-webui must
   pair `clone` and `deinit` and must not retain `*Connection`.
2. **Strict bridge protocol lengths:** The Zig parser must treat WebSocket data
   as untrusted and must not copy C's NUL-scanning behavior.
3. **Cross-platform browser behavior:** Guarantee URL opening first, then add
   platform-specific app-window flags.
4. **Native platform dependencies:** Optional adapters require real system
   frameworks/runtimes. Missing support is an explicit result, not a browser
   fallback or successful no-op. Never close a validation gate with only a
   cross-build or a skipped test.

## Completion Evidence

Completion snapshot: 2026-09-09.

[The final platform gate](https://github.com/webui-dev/pure-zig-webui/actions/runs/34342120131)
passed every job: Ubuntu 24.04, macOS 15, Windows Server 2022, and the
five-target cross-build matrix.

| Gate | Evidence |
|---|---|
| Core and bridge | Linux CI runs all 54 core tests with no skips and all 15 Node bridge tests. Node, Deno, and Bun are installed rather than accepted as skipped coverage. |
| Native runtime | Real WKWebView, GTK/WebKitGTK and WebView2 execute bridge calls, runtime binding/event updates, geometry and controls, UI-thread dispatch, close veto after navigation, multiwindow close, and clean shutdown. |
| Dependency absence | Linux without a display and Windows with a nonexistent WebView2 loader return documented unavailable errors and shut down cleanly. |
| Native rendering | The Windows gate captures the actual native window, checks its initial caption, and closes it through the OS. The rendered page and connected bridge were visually confirmed from the artifact. macOS pixel capture was unavailable on the local host; its actual window/JavaScript/control smoke passed locally and in CI. |
| Protocol robustness | `zig build fuzz --fuzz=100000` completed 101,191 executions without failure; deterministic malformed-input coverage is also part of normal tests. |
| Cross-target builds | `x86_64-linux`, `aarch64-linux`, `x86_64-windows`, `x86_64-macos`, and `aarch64-macos` all pass. Optional Windows and GNU/Linux native examples also cross-compile. |
| Ownership and isolation | Regression gates cover OOM cleanup, upgrade-bound authorization, server authentication expiry, handler cancellation, managed child/profile isolation, eval send deadlines and late-ID quarantine. Browser smoke also confirmed capacity recovery and clean reconnect shutdown. |
| Pure-source boundary | No legacy `webui_new`/C-wrapper exports remain. Default builds have no GUI linkage; optional adapters use Zig declarations for installed system APIs only. |

Linsang is pinned to `db11eb05e897e4dccdab701e110dc8a6948cb690`.
[Upstream PR #3](https://github.com/jinzhongjia/Linsang/pull/3) contains the
required authorization-context, deadline, canonical-path, immutable TLS-reader,
and concurrency fixes. That exact revision is already consumed and verified;
building this repository does not depend on the PR being merged first.

The permanent exclusions remain unchanged: no C ABI compatibility layer, no
old-Zig compatibility code, and no automatic self-signed certificate. Platform
limitations above are explicit results, not silent fallbacks.
