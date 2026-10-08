# zig-webui

> [!WARNING]
> Experimental and not yet released. APIs may change, and it is not suitable
> for production use.

zig-webui is a Zig-native reimplementation of [WebUI](https://github.com/webui-dev/webui):
build desktop apps with a Zig backend and an HTML/JavaScript frontend that runs
in an installed browser or an optional native WebView.

- **Pure Zig.** It does not compile or link the WebUI C library, CivetWeb, or any
  bundled C, C++, or Objective-C. [Linsang](https://github.com/jinzhongjia/Linsang)
  provides HTTP, WebSocket, and TLS.
- **Upstream parity.** It covers the WebUI `2.5.0-beta.4` capabilities with a
  Zig-native API, including upstream's window, bridge, and presentation
  behavior. The [capability ledger](docs/PURE_ZIG_REFACTOR.md) maps every
  upstream API and lists no open semantic gaps.
- **Any browser or native.** App-mode windows in Chrome, Edge, Firefox, and other
  installed browsers, or WKWebView, WebKitGTK, and WebView2 through system APIs.
- **Modern frontends.** A TypeScript SDK with React, Vue, and Solid bindings,
  app templates, and Vite hot reload.
- **Safe by default.** Loopback-only, per-window capability URLs and tokens,
  Origin checks, bounded resources, and explicit errors instead of silent
  fallbacks.

## Contents

- [Requirements](#requirements)
- [Install](#install)
- [Quick start](#quick-start)
- [Frontend apps (TypeScript, React, Vue, Solid)](#frontend-apps)
- [Guide](#guide)
- [Native WebViews](#native-webviews)
- [Development](#development)

## Requirements

- Zig **0.17.0**.
- At runtime, an installed browser. Chromium-family browsers support every
  window control. Without a known browser, the OS default URL handler opens a
  normal tab.
- Optional: Node.js for the TypeScript SDK, the app templates, and the bridge
  tests. Building and using the Zig package never needs Node or npm.
- Optional native WebViews: macOS WebKit, Linux GTK3 with WebKitGTK 4.1, or the
  Windows WebView2 Runtime.

## Install

```sh
zig fetch --save=zig_webui git+https://github.com/webui-dev/pure-zig-webui
```

```zig
// build.zig
const webui = b.dependency("zig_webui", .{
    .target = target,
    .optimize = optimize,
}).module("webui");

const exe = b.addExecutable(.{
    .name = "app",
    .root_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "webui", .module = webui }},
    }),
});
```

Native WebViews also need system linkage; see
[Native WebViews](#native-webviews).

## Quick start

```zig
const std = @import("std");
const webui = @import("webui");

const html =
    \\<!doctype html>
    \\<button onclick="webui.call('greet', 'Zig').then(alert)">Greet</button>
    \\<script src="webui.js"></script>
;

fn greet(call: *webui.Call, _: ?*anyopaque) !void {
    var buffer: [64]u8 = undefined;
    try call.reply(try std.fmt.bufPrint(&buffer, "Hello, {s}!", .{try call.string(0)}));
}

pub fn main(init: std.process.Init) !void {
    var app = webui.App.init(init.gpa, .{});
    defer app.deinit();
    const window = try app.createWindow(.{ .content = .{ .html = html } });
    try window.bind(init.io, "greet", greet, null);

    var running = try app.start(init.io);
    defer running.stop() catch {};
    try window.open(init.io, &running); // best installed browser, app mode
    try running.wait(); // returns once every window has closed
}
```

The page loads the bridge from `webui.js`, relative to the window's
capability URL, and calls Zig with `webui.call(name, ...args)`. Replies are
strings. Every bound name is also available as `webui.<name>(...)`.

## Frontend apps

The `sdk/` directory holds the `zig-webui` TypeScript SDK. It is not published to
npm yet; apps depend on this checkout by path.

Scaffold a Zig app with a React, Vue, or Solid frontend:

```sh
cd sdk && npm install                              # builds the SDK once
npm run create -- ../../my-app --template react    # or vue, solid
cd ../../my-app/web && npm install && cd ..
zig build run                                      # build web/dist and open it
```

For hot reload, run `npm run dev` in `web/`, then `zig build dev` in the
project root. The generated Zig host uses `.content = .{ .dev_server =
"http://localhost:5173/" }`. The browser receives the bridge URL in the
`#webui-bridge=` fragment, which never reaches the dev server. The SDK reads
it, removes it from the address bar, and keeps it for reloads.

| Import | API |
|---|---|
| `zig-webui` | `call`, typed `bindings<T>()`, `loadBridge`, `getBridge`, `isConnected`, `subscribe` |
| `zig-webui/react` | `useConnected()`, `useBridge()` |
| `zig-webui/vue` | `useConnected()`, `useBridge()` (read-only refs) |
| `zig-webui/solid` | `createConnected()`, `createBridge()` (signals) |

```ts
// Import the SDK before your router so it takes the dev-server fragment first.
import { bindings } from "zig-webui";

const zig = bindings<{ greet: [name: string] }>();
const reply = await zig.greet("Zig");
```

The SDK finds the bridge in this order:

1. a `webui.js` the page already includes;
2. the `dev_server` fragment or session storage;
3. the capability path of a page that zig-webui serves.

Built `web/dist` apps therefore need no script tag. Observing connection state
replaces the bridge's built-in connection-loss banner, so render your own.

## Guide

### Window content

Set `.content` in `App.WindowOptions`, or replace it later.

| Content | Use |
|---|---|
| `.html = "..."` | Embedded HTML, copied into the window. |
| `.directory = "path"` | Static files. A directory request redirects to `index.html`, `index.htm`, `index.ts`, or `index.js`. |
| `.custom = .{ .handler = f }` | Your handler answers each request with borrowed `webui.Request`/`webui.Response`. An empty `404` declines a path; the server then probes `index.*` below it. |
| `.site = .{ .html, .handler, .directory, .entry }` | Upstream's composition, resolved in this order: handler, virtual-index probing, `html`, then `directory`. `entry` redirects the root to a page. |
| `.external_url = "https://..."` | A page served elsewhere. It must load `Window.bridgeUrl()`, and its Origin is accepted for this window. |
| `.dev_server = "http://localhost:5173/"` | Like `.external_url`, but the bridge URL is passed in the URL fragment for the SDK. |

To change content at runtime:

- `Window.setContent()` installs new content and navigates every client.
- `Client.show()` navigates one client.
- `Window.installContent()` swaps content without navigating; external
  content needs `setContent()`.

`App.Options.default_directory` serves windows created without content.
`App.Options.folder_monitor_interval` reloads a window's clients when its
directory tree changes.

`Window.setIcon()` and `Window.setIconFile()` set the favicon. Without one,
`favicon.ico` and `favicon.svg` fall back to a readable file of that name in
the content, then to a built-in icon.

Set `.runtime = .deno`, `.node_js`, or `.bun` to run served `.js` and `.ts`
files in an external interpreter and return their stdout. The interpreter runs
as argv with a 30-second limit and bounded output. A missing interpreter
answers `503`, a timeout `504`, and a failed run `502`.

### Calling Zig from JavaScript

`Window.bind(io, name, handler, user_data)` registers a binding. Bindings can
be added or replaced while the app runs; connected pages receive them at once.

- **Arguments:** `Call.string(i)`, `int(i)`, `float(i)`, `boolean(i)`, and
  `bytes(i)`.
- **Replies:** `reply()`, `replyInt()`, `replyFloat()`, and `replyBool()`.
- **Later replies:** `Call.deferReply()` returns an owned `PendingReply`;
  complete it once, or `deinit()` it to abandon it.
- **Clicks:** an element whose `id` matches a binding also calls it on click.
  Clicks have no arguments, and their replies are ignored.
- **Metadata:** `Call.name`, `Call.origin` (`.call` or `.click`), and
  `Call.cookies` with `cookie(name)`.

`Window.onEvent(io, handler, user_data)` receives `.connected`,
`.disconnected`, `.click`, and `.navigation` events. While it is installed,
link and script navigations are intercepted and sent to the handler;
`event.client.navigate()` continues them.

Handlers run on a bounded worker queue: FIFO per window by default, or
`Window.setEventMode(.concurrent)`. `Running.stop()` cancels and joins them.

### Calling JavaScript from Zig

- `Window.eval(io, script, buffer, timeout)` waits for a client and returns
  `.value` or `.javascript_error`.
- `Window.evalAll()` returns owned per-client results; call `deinit()` on them.
- `Window.run()` and `Client.run()` send fire-and-forget scripts.
- `navigate()`, `close()`, and `sendRaw()` act on a window or on one client.

Evaluations have a total deadline, and results from an old connection never
reach a new one.

### Lifecycle

```zig
var running = try app.start(io);
defer running.stop() catch {};
try window.open(io, &running);
try running.wait();
```

`Running.wait()` returns once no window is active. After its last client
leaves, a window gets a 1.5-second reconnect grace, so reloads and
`setContent()` survive. `Window.close()` ends a window at once.

Before the first connection, windows wait up to `App.Options.startup_timeout`
(15 seconds). `Running.requestExit()` closes every page and ends the wait,
like `webui_exit()`. `App.createWindow()` and `App.destroyWindow()` also work
while the app runs, including from handlers.

### Browser windows

- `Window.open()` launches the best installed browser as an app window.
- `Window.openWithBrowser(&running, .{ .browser = .firefox })` picks a browser;
  `.executable` and `.arguments` override the path and the default arguments.
- `bestBrowser()` and `browserExists()` query the installed browsers.
- `openUrl()` opens any URL with the OS handler.

| `App.WindowOptions` | Effect |
|---|---|
| `.size`, `.position`, `.center` | Initial geometry; change it later with `Window.setSize()`, `setPosition()`, and `setCenter()`. |
| `.kiosk`, `.hide` | Kiosk or headless browser. |
| `.high_contrast = false` | Disables forced colors (Chromium flag, Firefox profile). |
| `.profile_directory` | A caller-owned profile, never modified. Otherwise each window gets a managed profile; `Window.deleteProfile()` removes it. |
| `.proxy_server` | Chromium-family proxy rule. |
| `.max_clients` | Allow more than one client per window. |

Firefox windows get a generated app-mode profile that hides the toolbars, like
upstream. A browser that cannot honor an option returns an explicit error,
such as `error.UnsupportedBrowserControl`, instead of ignoring it. Each window
retains its launched browser; `Running.stop()` kills and reaps it.
`Window.focus()` raises it on Windows.

### Browser bridge

The bridge (`webui.js`, written in TypeScript in `src/bridge.ts`) behaves like
upstream's:

- **Reconnect:** it retries lost connections after 500 ms and authenticates
  every new socket within 5 seconds. Pending calls are rejected and never
  replayed.
- **Heartbeat:** text `ping` every 20 seconds, with a 10-second `pong` deadline.
- **Status banner:** shown after a lost or rejected connection, unless the page
  installs `webui.setEventCallback()`.
- **Page API:** `webui.call()`, `isConnected()`, `setLogging()`, `encode()`,
  `decode()`, `isHighContrast()`, and `allowNavigation()`.
- **Presentation, as upstream:**
  - F5 reloads only while logging is on. Logging is on by default in Debug
    builds.
  - Page context menus are suppressed except on `<input>` elements.
  - WebView2 DevTools are enabled only in Debug builds.

### Security

- The server listens on loopback by default. Each window has a random
  capability path and token, and WebSocket upgrades must pass an Origin check.
- `App.Options.use_cookies` adds path-scoped `HttpOnly` cookie authorization
  and locks a single-client window to its first client.
- `App.Options.limits` bounds connections, messages, calls, arguments,
  bindings, events, and scripts.
- Non-loopback listening requires `.public = true` and caller-provided TLS. A
  self-signed certificate is never generated.

```zig
var app = webui.App.init(gpa, .{
    .address = "0.0.0.0",
    .public = true,
    .use_cookies = true,
    .tls = .{
        .certificate_pem = @embedFile("certificate.pem"),
        .private_key_pem = @embedFile("private-key.pem"),
    },
});
```

## Native WebViews

`webui.native` hosts a window in WKWebView (macOS), WebKitGTK 4.1 (Linux), or
WebView2 (Windows) through system APIs. It is separate from browser launching,
and a normal `zig build` links no GUI libraries.

```zig
var view = try webui.native.Window.open(gpa, io, window, &running, .{
    .title = "My App",
    .size = .{ .width = 900, .height = 600 },
});
defer view.deinit() catch {};
try view.run(); // UI thread; std.Io workers serve the backend
```

Link the platform libraries in your `build.zig` when you use it:

```zig
const module = exe.root_module;
switch (target.result.os.tag) {
    .macos => {
        module.link_libc = true;
        module.linkSystemLibrary("objc", .{});
        for ([_][]const u8{ "Foundation", "AppKit", "WebKit" }) |framework|
            module.linkFramework(framework, .{});
    },
    .linux => module.link_libc = true, // GTK3 and WebKitGTK load at runtime
    .windows => for ([_][]const u8{ "user32", "gdi32", "ole32", "kernel32", "dwmapi" }) |library|
        module.linkSystemLibrary(library, .{}),
    else => {},
}
```

**Threading.** Create and operate native windows on their UI thread: the main
thread on macOS, and one GTK thread on Linux. Pump them with `view.run()` or
`view.poll()`; do not call `Running.wait()` on the UI thread. Use
`view.dispatch()` from worker threads.

**Controls.** `setSize`, `setPosition`, `center`, `setMinimumSize`,
`setResizable`, `setFrameless`, `setTransparent`, `setVisible`, `setKiosk`,
`minimize`, `maximize`, `restore`, `focus`, `geometry()`, and `handle()`.

**Window behavior.**

- **Titles:** page titles become the window title, unless
  `follow_page_title = false`.
- **Closing:** `setCloseHandler()` can veto user and JavaScript closes;
  `view.close()` always closes.
- **Navigation:** `navigation_handler` (or `setNavigationHandler()`) decides
  every page, frame, and redirect navigation inside the engine.
- **DevTools:** `devToolsEnabled()` reports the engine state.

**Frameless dragging.** `dragRegion()` reports how each backend marks drag
areas. To support every backend, declare all three properties:

```css
.titlebar { --webui-app-region: drag; app-region: drag; -webkit-app-region: drag; }
.titlebar button { --webui-app-region: no-drag; app-region: no-drag; -webkit-app-region: no-drag; }
```

**Platform limits.**

- **macOS:** no transparent pages and no custom profile directories; both return
  errors, as in upstream.
- **Linux:** position, centering, and geometry need X11. Transparency needs an
  RGBA visual and a compositor. A missing runtime or display returns an error.
- **Windows:** needs the WebView2 Runtime and the matching `WebView2Loader.dll`,
  through `Options.webview2_loader` or normal DLL discovery. Nothing is
  downloaded.

## Development

```sh
zig build                  # library and examples
zig build test             # core tests, plus bridge tests when Node is installed
zig build test-bridge      # bridge tests; requires Node
zig build fuzz --fuzz=100K # protocol parser fuzzing
zig build run              # minimal example
zig build run-bindings     # also: run-dynamic-content, run-managed-browser,
                           # run-runtime, run-public-tls -- cert.pem key.pem
zig build run-native -Dnative=true
zig build test-native -Dnative=true   # actual native WebView smoke
```

SDK and bridge source:

```sh
cd sdk
npm install
npm run check          # type-check the SDK, scaffolder, and bridge
npm test               # SDK tests on Node's built-in runner
npm run build:bridge   # regenerate src/bridge.js from src/bridge.ts
```

`src/bridge.js` is generated and committed. Edit `src/bridge.ts`, and CI
rejects a stale copy.

CI runs on Linux, macOS, and Windows. It installs Node, Deno, and Bun, then:

- runs the core, bridge, and SDK tests;
- builds a scaffolded app for each template;
- runs the native WebView smoke tests with real pointer input;
- cross-builds `x86_64-linux`, `aarch64-linux`, `x86_64-windows`,
  `x86_64-macos`, and `aarch64-macos`.

More documentation:

- [Capability ledger](docs/PURE_ZIG_REFACTOR.md): upstream API mapping,
  validation evidence, and risks.
- [Upstream logic audit](docs/UPSTREAM_LOGIC_AUDIT.md): source comparison with
  upstream WebUI.
- [AGENTS.md](AGENTS.md): contribution and testing rules.

## License

MIT
