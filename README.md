# zig-webui

> [!WARNING]
> This is an experimental project under active development and is not suitable
> for production use.

zig-webui is a Zig-native reimplementation of WebUI. The core does not
compile or link the upstream WebUI C library or CivetWeb.
[Linsang](https://github.com/jinzhongjia/Linsang) provides HTTP and WebSocket
support.

The current phase provides:

- Zig 0.16;
- one `App`, multiple isolated windows, and automatic port selection;
- embedded HTML, static directories, custom resources, external URLs, and a
  built-in JavaScript bridge;
- application-wide default static directories for windows without content;
- optional recursive directory monitoring with per-window browser reloads;
- inline and file-backed per-window favicons;
- runtime content and resource-handler replacement through
  `Window.setContent()`;
- targeted runtime content replacement through `Client.show()`;
- explicit browser connection waiting and timeout through
  `Window.waitForConnection()`;
- window connected/shown state through `Window.isShown()`;
- JavaScript calls to Zig bindings with return values;
- thread-safe runtime binding and event-handler replacement, with client replay;
- typed integer, float, and boolean call arguments and replies;
- owned one-shot delayed binding replies through `Call.deferReply()`;
- window and targeted `Call.client` calls to JavaScript with results, errors,
  timeouts, and stale-client detection;
- targeted client navigation, close, and raw binary delivery;
- bounded multi-client windows through `WindowOptions.max_clients`;
- bounded concurrent evaluations through
  `WindowOptions.max_pending_evals`;
- bounded delayed replies through `WindowOptions.max_pending_replies`;
- explicit connection, WebSocket message, call, argument, binding, event, and
  script limits through `App.Options.limits`;
- automatic browser-to-Zig protocol fragmentation for large calls and
  JavaScript results, bounded by `Limits.max_ws_message_size`;
- window navigation, close, raw-data, and JavaScript broadcasts with
  per-client results;
- targeted and broadcast fire-and-forget JavaScript through `Client.run` and
  `Window.run`;
- connected, disconnected, click, and intercepted navigation events through
  `Window.onEvent`;
- per-window serial or concurrent binding and event execution through
  `Window.setEventMode()`;
- bounded concurrent handlers through `WindowOptions.max_pending_events`;
- caller-provided internal logging through `App.Options.logger`;
- same-origin WebSocket validation for hosted content and external-page Origin
  validation for `.external_url`;
- optional path-scoped `HttpOnly` cookie authorization through
  `App.Options.use_cookies`, locking single-client windows to their first
  client;
- optional Deno, Node.js, or Bun interpretation of served `.js` and `.ts`
  files through `App.WindowOptions.runtime`;
- loopback-only listening by default and caller-provided TLS for explicit
  public listening;
- app-mode window launching through installed-browser discovery, with a
  managed per-browser profile and OS URL opening as the fallback;
- explicit browser launching with custom executable paths and argv;
- per-window kiosk and headless modes plus persistent initial and runtime size
  and position;
- per-window Chromium forced-color control and browser-native high-contrast
  detection;
- per-window browser profile directories with deletable managed profiles,
  and Chromium-family proxy rules;
- per-window browser child identifiers and deterministic process cleanup;
- Windows external-browser focus with explicit errors on unsupported
  platforms and unavailable windows;
- current backend process ID through `parentProcessId()`;
- default-browser launching and deterministic shutdown;
- optional native WKWebView, GTK3/WebKitGTK 4.1, and WebView2 hosting through
  system APIs, with native controls, close veto, and borrowed window handles.

```zig
const std = @import("std");
const webui = @import("webui");

fn hello(call: *webui.Call, _: ?*anyopaque) !void {
    try call.reply("Hello from Zig");
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    var app = webui.App.init(gpa, .{});
    defer app.deinit();
    const window = try app.createWindow(.{
        .content = .{
            .html =
            \\<button onclick="webui.call('hello').then(alert)">Call Zig</button>
            \\<script src="webui.js"></script>
            ,
        },
    });
    try window.bind(io, "hello", hello, null);

    var running = try app.start(io);
    defer running.stop() catch {};
    try window.open(io, &running);

    var result_buffer: [64]u8 = undefined;
    const result = try window.eval(
        io,
        "return 6 * 7",
        &result_buffer,
        .fromSeconds(5),
    );
    switch (result) {
        .value => |value| std.debug.print("JavaScript: {s}\n", .{value}),
        .javascript_error => |message| std.log.err("JavaScript: {s}", .{message}),
    }
    try running.wait();
}
```

```sh
zig build test
zig build
zig build run
```

`zig build test` uses Node's built-in test runner for the browser bridge when
Node is available and otherwise skips those tests with a warning. Building and
using the library does not require Node or npm. CI and release validation
should run `zig build test-bridge`, which fails when Node is unavailable.
`Window.evalAll` returns owned results; call `deinit` on them after consuming
every per-client outcome.

`Running.wait()` returns once every client is gone: a backend `Window.close()`
or `Client.close()` ends it as soon as the last client disconnects, while any
other disconnect — a page reload, a navigation, a closed browser window —
gets a 1.5-second reconnect grace period first, so reloads and
`Window.setContent()` do not stop the application.
Bridge retries do not extend this grace period or restart a stopped backend.
Longer outages can recover only while the application keeps its server running.

`Window.open()` discovers the best installed browser and launches it as a
standalone app window, exactly like `Window.openWithBrowser()` with that
browser. It returns immediately. When no known browser is installed it hands
the URL to the OS default handler, which opens an ordinary tab and therefore
returns `error.ExplicitBrowserRequired` when any window control is active.
Call `Window.waitForConnection(io, timeout)` when startup must wait for a
browser; it returns the first connected `Client`. `Window.eval()` uses the same
total timeout for connection waiting and JavaScript execution.

Call `openUrl(gpa, io, url)` to open any non-empty URL with the OS default
handler. `browserExists(gpa, io, browser)` checks an explicit `Browser`, while
`bestBrowser(gpa, io)` returns the first installed browser in the preferred
platform order or `null`. Discovery probes Windows application registration,
standard macOS application bundles, and executable candidates on other
platforms without opening the selected browser.

`Window.openWithBrowser(&running, options)` launches a selected `Browser`
with an optional full executable path and additional argv. Chromium-family
browsers receive an `--app=` URL argument; Firefox receives `-new-window`.
When `options.arguments` is empty, Chromium-family browsers also receive a set
of default arguments that suppress first-run interstitials, extensions,
background services, translation, sync, and proxies; a non-empty
`options.arguments` replaces those defaults entirely.
The returned `BrowserProcessId`, also available through
`Window.browserProcessId()`, is a PID on POSIX and a process handle on
Windows. Each window retains at most one launched child; launching another
replaces it, and `Running.stop()` kills and reaps every retained child.

`Window.focus(&running)` restores a minimized retained browser window and
brings it to the foreground on Windows. It returns `error.NoManagedBrowser`
before a browser is launched, `error.BrowserProcessUnavailable` for an invalid
child handle, `error.BrowserWindowNotFound` when the child has no visible
top-level window, and `error.BrowserFocusFailed` when Windows refuses the
foreground request. Linux and macOS return `error.UnsupportedPlatform`.

`parentProcessId()` returns the numeric ID of the current Zig backend process,
which is the parent of browsers launched directly by this package. It is
process-wide and does not require a `Window`. Targets without a supported
process-ID API return `error.UnsupportedPlatform`.

Set `.kiosk`, `.hide`, `.size`, or `.position` in `App.WindowOptions` to
control the initial browser window. `.hide` launches the browser headless.
Chromium-family browsers support all four controls. Firefox supports kiosk,
hide, and size but returns `error.UnsupportedBrowserControl` for position;
Safari returns the same error for any of these controls. Width and height must
be non-zero, while positions may be negative for secondary displays. Only the
OS-handler fallback inside `Window.open()` cannot honour these controls, and it
returns `error.ExplicitBrowserRequired` instead of ignoring them.

Set `.high_contrast = false` in `App.WindowOptions` to disable Chromium's
forced-color feature for that window. Firefox and Safari return
`error.UnsupportedBrowserHighContrast` instead of ignoring this setting.
The browser-side `webui.isHighContrast()` detects active forced colors or a
stronger contrast preference through native media queries and requires no
external OS program.

Set `.profile_directory` in `App.WindowOptions` to launch Chromium-family
browsers with `--user-data-dir` or Firefox with `--profile`. Set
`.proxy_server` for Chromium-family browsers to pass one `--proxy-server`
argument without invoking a shell. The app copies both strings. Profile
directories remain caller-managed and are never deleted by zig-webui.
Firefox returns `error.UnsupportedBrowserProxy` for proxy configuration;
Safari returns `error.UnsupportedBrowserProfile` or
`error.UnsupportedBrowserProxy` instead of silently ignoring either option.

Without `.profile_directory`, each Chromium-family window gets an independent
managed profile leaf under its browser-family temporary root, for example
`/tmp/.WebUI/WebUIChromeProfile/<window-capability>`. Different windows no
longer hand their URL to the same browser process. Reopening a window stops and
reaps its previous child before launching the replacement. A failed replacement
leaves no stale child identifier.

`Window.deleteProfile(&running)` stops the retained child and removes only that
window's generated leaf. `managedProfileDirectory(gpa, browser)` returns the
family root; `deleteManagedProfile` and `deleteAllManagedProfiles` remove roots
and all their leaves, so stop every associated browser before using them.
Caller-provided profiles remain caller-owned; `Window.deleteProfile` returns
`error.CallerManagedProfile`. Do not share a caller profile with other live
browser instances; identical configured profiles in one app are rejected with
`error.BrowserProfileInUse`.

`Window.setSize(io, size)` and `Window.setPosition(io, position)` persist new
geometry, return the number of currently notified clients, and replay the
latest values to clients that connect later. Subsequent
`Window.openWithBrowser()` calls use the updated values. Connected external
browsers receive `window.resizeTo()` or `window.moveTo()` requests; browser
security policy may ignore those requests for ordinary tabs.

`Window.setCenter(io)`, and `.center = true` in `App.WindowOptions`, centre
the window on the primary display. Only the browser knows the screen
geometry, so it computes the coordinates itself, which means centring takes
effect once a client connects rather than at launch. Centring and an explicit
position are mutually exclusive: each one clears the other, and setting both
in `App.WindowOptions` returns `error.ConflictingWindowPlacement`.

Serve a directory by setting
`.content = .{ .directory = "path/to/public" }`. The path is opened when the
app starts and closed when it stops. Custom resources receive `webui.Request`
and `webui.Response` directly.

Set `.runtime = .deno`, `.node_js`, or `.bun` in `App.WindowOptions` to run
served `.js` and `.ts` files through an external interpreter instead of
sending them to the browser. A request for a directory resolves `index.ts`
and then `index.js`. The interpreter is spawned as argv, never through a
shell, and receives the script path followed by the raw query string, so a
query can never become a command. Successful standard output is answered as
`200 text/plain` and bounded by `Limits.max_runtime_output`; a run is abandoned
after 30 seconds. Unlike upstream's empty-success fallback, unavailable
interpreters (missing, inaccessible, or invalid executables) answer `503`,
timeouts answer `504`, and output-limit violations or unsuccessful exits answer
`502`. Failed runs never return partial stdout or interpreter diagnostics to
the browser; diagnostics remain in the window logger. Static resources are
unaffected. Resource paths are percent-decoded and validated once before runtime
or static dispatch; encoded script suffixes cannot expose server-side source.
Encoded separators, invalid UTF-8, NUL, and traversal are rejected. Interpreters
reject symlink components and nonregular scripts. The directory tree must remain
trusted: an attacker who can rewrite executable scripts already controls that
interpreter's code and permissions.

Set `App.Options.default_directory` to let windows created without `.content`
inherit one static directory. Explicit window content takes precedence. A
window without either setting returns `error.MissingContent`.

Set `App.Options.folder_monitor_interval` to a positive `std.Io.Duration` to
recursively poll active directory content. A changed tree sends
`location.reload();` to that window's connected clients. Monitoring is
disabled by default and stops with `Running.stop()`.

Use `Window.setIcon(io, data, mime_type)` for in-memory favicon data or
`Window.setIconFile(io, path)` for SVG, PNG, ICO, JPEG, GIF, WebP, or AVIF
files. Embedded HTML receives a relative favicon link automatically.
Directory and custom pages can reference `favicon.ico` relative to the window
capability root.

`Window.setContent(&running, content)` prepares and installs new content, then
navigates every connected client to it and returns the number notified. An
invalid replacement leaves the current content unchanged. If client
notification fails, the prepared replacement remains installed.

`Client.show(&running, content)` installs the same window-wide content but
navigates only the selected client, matching upstream `webui_show_client()`.
Other connected pages are not reloaded; later resource requests use the new
window content.

`Window.onEvent` installs one handler for browser lifecycle, click, and
navigation events. `Event.data` contains the element ID for clicks, the target
URL for navigation, and is empty for connected or disconnected events.
Navigation attempts are intercepted while an event handler is installed; call
`Event.client.navigate` from the handler to continue them. Backend-initiated
navigation bypasses that interception. `Window.bind(io, name, handler, user_data)`
and `Window.onEvent(io, handler, user_data)` work before and during execution.
New registrations reach connected clients through `ADD_ID` and are replayed
before a reconnect's `CONNECTED` event. Existing in-flight handlers retain their
snapshot; keep old `user_data` alive until those invocations have finished.
Non-conflicting binding names also expose `webui.<name>(...)`; core and inherited
properties are never overwritten, and `webui.call(name, ...)` always remains
available.

Handlers use a bounded FIFO worker queue in `.serial` mode, leaving the network
receiver free to process replies and heartbeats. A handler can safely evaluate
JavaScript on its own client. `Window.setEventMode(.concurrent)` starts newly
received work independently. Both modes own queued data, obey
`WindowOptions.max_pending_events`, and are canceled and joined by
`Running.stop()`. Evaluation's total deadline includes connection waiting,
send-lock contention, transmission, and waiting for the JavaScript response.
Sent evaluations that time out or are canceled keep their wire ID reserved until
the late result is discarded or the client disconnects. IDs cannot be reused to
misattribute an old result after 16-bit wrap; exhausting that space returns
`error.EvaluationIdsExhausted`. Tracking is bounded to 8 KiB per evaluated client.

Set `App.Options.logger` and optional `logger_user_data` to receive formatted
internal messages with a `std.log.Level`. The message slice is valid only
during the callback. The callback must be thread-safe when concurrent event
handling is enabled. Without a callback, messages use `std.log`.

`Window.bind(io, "button", ...)` also dispatches clicks from elements with
`id="button"`, including elements added after the bridge loads. DOM click
handlers receive no arguments and their replies are ignored; explicit
`webui.call("button", ...)` remains available.

Binding handlers can transfer an explicit `webui.call()` response beyond the
handler lifetime with `Call.deferReply()`. Complete the owned `PendingReply`
once with `reply()`, `replyInt()`, `replyFloat()`, or `replyBool()`, or call
`deinit()` to abandon it. All pending replies must be completed or abandoned
before `App.deinit()`.

The browser-side `webui` object also provides connection events, runtime
logging, Base64 helpers, navigation control, and native high-contrast media
query detection.

The bridge retries lost transports after 500ms and authenticates every new
connection before enabling calls. Connection establishment and authentication
have a five-second deadline. Authenticated connections send text `ping` every
20 seconds and require `pong` within 10 seconds; missing replies trigger
reconnection. The server accepts only this exact authenticated text heartbeat,
not arbitrary text messages.
The server independently enforces a five-second authentication deadline and a
25-second authenticated idle limit. Temporary client-capacity rejection is
retryable; a stale transport cannot permanently occupy a single-client window.
Protocol authentication is pinned to the window whose HTTP upgrade passed its
Origin and cookie policy.

Disconnects reject outstanding `webui.call()` promises; they are never replayed,
because a binding may already have produced side effects. Results from
JavaScript evaluations started on an old connection cannot reach a replacement
connection. Authentication rejection and protocol/policy failures stop retries,
as do backend close commands and page unloads. Returning from the browser's
back-forward cache reconnects unless the bridge was permanently stopped.

A nonblocking status banner appears after a connection loss persists for one
second, or an initial connection fails to authenticate within five seconds.
Opening a replacement socket does not remove it; successful authentication does.
Authentication or protocol/policy rejection displays a terminal error instead
of claiming to retry. Backend close and page unload remove bridge-owned UI.
Installing `webui.setEventCallback()` suppresses the default banner so the
application can own its connection UI. The callback receives the initial failed
attempt and subsequent connected/disconnected transitions without duplicate
notifications; callback exceptions do not interrupt recovery.

`webui.call()` reserves a nonzero 16-bit request ID until its response arrives,
the send fails, or the connection closes. Allocation skips pending IDs when
wrapping; with all 65,535 IDs occupied, only the new call is rejected and no
packet is sent. A slow deferred reply cannot be overwritten by later calls.

Browser-to-Zig protocol packets of at least 65,500 bytes are sent as ordered
`MULTI` chunks and reassembled per client. The announced total size is strictly
parsed and bounded by `Limits.max_ws_message_size`; incomplete state is released
when the client disconnects.

Use `Client.run` or `Window.run` when JavaScript results and errors are not
needed. These methods use the protocol's `JS_QUICK` command and do not consume
pending evaluation slots.

External pages use `.content = .{ .external_url = "http://..." }`.
`Window.url` returns the external page, while `Window.bridgeUrl` returns the
capability-scoped script URL that the caller-owned page must load. The bridge
connects its WebSocket to the script's origin instead of the page's origin,
and the server accepts the external page's Origin for that window.

Non-loopback listening requires both explicit public mode and TLS:

```zig
var app = webui.App.init(gpa, .{
    .address = "0.0.0.0",
    .public = true,
    .use_cookies = true,
    .tls = .{
        .certificate_pem = @embedFile("certificate.pem"),
        .private_key_pem = @embedFile("private-key.pem"),
    },
    .limits = .{
        .max_connections = 128,
        .max_unauthenticated_connections = 16,
        .max_ws_message_size = 1 << 20,
    },
});
```

The certificate and private key are parsed by `App.start()` and released by
`Running.stop()`. zig-webui never generates a self-signed certificate.

`use_cookies` requires hosted content. Combining it with `.external_url` returns
`error.ExternalUrlCookiesUnsupported` rather than silently weakening Strict
cookies or accepting a cross-site page that cannot authenticate.

## Optional native WebViews

`webui.native` is separate from external-browser launching. It contains only Zig
source and calls installed platform frameworks; it never builds bundled C,
C++, or Objective-C. Normal `zig build` does not link GUI libraries.

```zig
var view = try webui.native.Window.open(gpa, io, window, &running, .{
    .title = "Native WebUI",
    .size = .{ .width = 900, .height = 600 },
    .resizable = true,
});
defer view.deinit() catch {};
try view.run(); // Main/UI thread; std.Io workers serve the WebUI backend.
```

Create and operate windows on their UI owner thread (the main thread on macOS,
one process-wide GTK thread on Linux). Use bounded `view.dispatch(callback,
user_data)` from workers. Do not call `Running.wait()` on the UI thread; pump
with `view.run()` or `view.poll()`, then stop the server. Join dispatch producers
before deinit; queued user data is borrowed until execution or queue cancellation.
Deinit from a native callback or recursive poll returns
`error.ReentrantNativeOperation`.

Native controls are methods of the returned `view`, not browser JavaScript
geometry requests: `setSize`, `setPosition`, `center`, `setMinimumSize`,
`setResizable`, `setFrameless`, `setTransparent`, `setVisible`, `setKiosk`,
`minimize`, `maximize`, `restore`, and `focus`. `geometry()` reports toolkit
logical coordinates: content size and outer-window position (Cocoa uses its
native lower-left origin). `handle()` returns a borrowed tagged Cocoa,
GTK, or Win32 handle, invalid after native close or deinit.

`setCloseHandler(handler, user_data)` handles OS and JavaScript close requests on
the UI thread; return `false` to veto. Document-start native integration keeps a
vetoed page and its bridge alive, including after navigation history changes.
`view.close()` force-closes without invoking that veto. Pumping one window also
services native events and accepted close requests for other windows on its UI
thread.

Platform prerequisites and explicit limits:

- **macOS:** link `objc`, Foundation, AppKit, and WebKit. Public WKWebView APIs do
  not provide transparent page compositing or arbitrary profile directories;
  those options return explicit errors, matching upstream's macOS capability
  boundary rather than using private selectors.
- **Linux:** link system libc and install GTK3 plus WebKitGTK 4.1. Cross-build
  with a GNU target such as `aarch64-linux-gnu`. Libraries are loaded dynamically;
  a missing runtime or display returns an error. Position/centering/geometry
  require X11; transparency requires an RGBA visual and a compositor.
- **Windows:** link `user32`, `gdi32`, `ole32`, `kernel32`, and `dwmapi`; install the
  WebView2 Runtime and provide the architecture-matching `WebView2Loader.dll`
  through `Options.webview2_loader` or normal DLL discovery. No runtime is
  downloaded by the library. Initialization is bounded to 15 seconds; late COM
  callbacks retain safe independent ownership. Transparency requires DWM
  composition and the Controller2 interface.

The build configures this linkage for the native example:

```sh
zig build run-native -Dnative=true
zig build test-native -Dnative=true
# Windows: append -- --loader C:/path/to/WebView2Loader.dll
```

## Examples and validation

Retained examples cover runtime bindings, dynamic content, managed browsers,
interpreter resources, caller-provided public TLS, and native WebViews:
`zig build run-bindings`, `run-dynamic-content`, `run-managed-browser`,
`run-runtime`, and `run-public-tls -- certificate.pem private-key.pem`.
External-browser examples warn and shut down when no browser connects.

`zig build fuzz --fuzz=100K` exercises bounded protocol parsers. CI installs
Node, Deno, and Bun, runs the core and bridge suites, executes native smoke gates
on Linux/macOS/Windows, and cross-builds all five ledger targets.

The [capability ledger](docs/PURE_ZIG_REFACTOR.md#completion-evidence) records the
completed rewrite and exact cross-platform validation evidence. The experimental
warning still applies; no stable release or production-readiness claim is implied.

## License

MIT
