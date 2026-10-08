const std = @import("std");
const builtin = @import("builtin");
const webui = @import("webui");

const Page = struct {
    io: std.Io,
    window: webui.Window,
    native: ?webui.native.Window = null,
    ready: std.atomic.Value(bool) = .init(false),
    runtime_calls: std.atomic.Value(usize) = .init(0),
    runtime_events: std.atomic.Value(usize) = .init(0),
    allow_close: bool = false,
    close_requests: usize = 0,
    reentrant_destroy_rejected: bool = false,
};

const html =
    \\<!doctype html><meta charset="utf-8"><title>Pure Zig native WebView</title>
    \\<style>body{font:18px system-ui;margin:32px}button{padding:8px 16px}</style>
    \\<h1>Pure Zig native WebView</h1><output id="status">Connecting...</output>
    \\<p><button onclick="window.close()">Request native close</button></p>
    \\<script src="webui.js"></script><script>
    \\webui.setEventCallback(async event => {
    \\  if (event === webui.event.CONNECTED)
    \\    document.getElementById('status').textContent = await webui.call('ready');
    \\});
    \\</script>
;

fn ready(call: *webui.Call, data: ?*anyopaque) !void {
    const page: *Page = @ptrCast(@alignCast(data.?));
    page.ready.store(true, .release);
    try call.reply("Connected to Zig");
}

fn runtimeBinding(call: *webui.Call, data: ?*anyopaque) !void {
    const page: *Page = @ptrCast(@alignCast(data.?));
    _ = page.runtime_calls.fetchAdd(1, .acq_rel);
    try call.reply("runtime binding");
}

fn runtimeEvent(event: *const webui.Event, data: ?*anyopaque) !void {
    const page: *Page = @ptrCast(@alignCast(data.?));
    if (event.kind == .click and std.mem.eql(u8, event.data, "runtime-event"))
        _ = page.runtime_events.fetchAdd(1, .acq_rel);
}

fn closeRequested(data: ?*anyopaque) bool {
    const page: *Page = @ptrCast(@alignCast(data.?));
    page.close_requests += 1;
    if (!page.allow_close) {
        if (page.native) |value| {
            var owned = value;
            owned.deinit() catch |err| {
                page.reentrant_destroy_rejected = err == error.ReentrantNativeOperation;
            };
        }
    }
    return page.allow_close;
}

fn pumpUntil(io: std.Io, pump: webui.native.Window, page: *Page, requests: ?usize) !void {
    const deadline: std.Io.Clock.Timestamp = .fromNow(io, .{ .clock = .awake, .raw = .fromSeconds(15) });
    while (true) {
        const done = if (requests) |count| page.close_requests >= count else page.ready.load(.acquire);
        if (done) return;
        if (!try pump.poll()) return error.NativeClosedEarly;
        if (deadline.compare(.lte, .now(io, .awake))) return error.NativeSmokeTimeout;
        try std.Io.sleep(io, .fromMilliseconds(10), .awake);
    }
}

fn expectSize(io: std.Io, view: webui.native.Window, size: webui.native.Size) !void {
    const deadline: std.Io.Clock.Timestamp = .fromNow(io, .{ .clock = .awake, .raw = .fromSeconds(3) });
    while (try view.poll()) {
        const actual = try view.geometry();
        if (actual.size.width == size.width and actual.size.height == size.height) return;
        if (deadline.compare(.lte, .now(io, .awake))) {
            std.log.err("native content size {any}, expected {any}", .{ actual.size, size });
            return error.NativeGeometryMismatch;
        }
        try std.Io.sleep(io, .fromMilliseconds(10), .awake);
    }
    return error.NativeClosedEarly;
}

fn readTitle(view: webui.native.Window, buffer: []u8) ![]const u8 {
    var fixed: std.heap.FixedBufferAllocator = .init(buffer);
    return view.title(fixed.allocator());
}

/// Pump until `view` shows `expected`, bounded like the other smoke waits.
fn expectTitle(io: std.Io, pump: webui.native.Window, view: webui.native.Window, expected: []const u8) !void {
    const deadline: std.Io.Clock.Timestamp = .fromNow(io, .{ .clock = .awake, .raw = .fromSeconds(5) });
    var buffer: [256]u8 = undefined;
    while (try pump.poll()) {
        const actual = try readTitle(view, &buffer);
        if (std.mem.eql(u8, actual, expected)) return;
        if (deadline.compare(.lte, .now(io, .awake))) {
            std.log.err("native title {s}, expected {s}", .{ actual, expected });
            return error.NativeTitleMismatch;
        }
        try std.Io.sleep(io, .fromMilliseconds(10), .awake);
    }
    return error.NativeClosedEarly;
}

/// Pump for a settle period and fail if `view` ever leaves `expected`.
fn expectTitleKept(io: std.Io, pump: webui.native.Window, view: webui.native.Window, expected: []const u8) !void {
    const deadline: std.Io.Clock.Timestamp = .fromNow(io, .{ .clock = .awake, .raw = .fromMilliseconds(500) });
    var buffer: [256]u8 = undefined;
    while (deadline.compare(.gt, .now(io, .awake))) {
        if (!try pump.poll()) return error.NativeClosedEarly;
        const actual = try readTitle(view, &buffer);
        if (!std.mem.eql(u8, actual, expected)) {
            std.log.err("native title changed to {s}, expected {s}", .{ actual, expected });
            return error.NativeTitleChanged;
        }
        try std.Io.sleep(io, .fromMilliseconds(10), .awake);
    }
}

const Evaluation = struct {
    io: std.Io,
    window: webui.Window,
    source: []const u8,
    buffer: [256]u8 = undefined,
    result: ?webui.EvalResult = null,
    failure: ?anyerror = null,
    done: std.atomic.Value(bool) = .init(false),

    fn run(self: *Evaluation) void {
        self.result = self.window.eval(self.io, self.source, &self.buffer, .fromSeconds(5)) catch |err| blk: {
            self.failure = err;
            break :blk null;
        };
        self.done.store(true, .release);
    }
};

fn evaluate(io: std.Io, view: webui.native.Window, window: webui.Window, source: []const u8, expected: []const u8) !void {
    var evaluation: Evaluation = .{ .io = io, .window = window, .source = source };
    var workers: std.Io.Group = .init;
    defer workers.cancel(io);
    try workers.concurrent(io, Evaluation.run, .{&evaluation});
    while (!evaluation.done.load(.acquire)) {
        if (!try view.poll()) return error.NativeClosedEarly;
        try std.Io.sleep(io, .fromMilliseconds(5), .awake);
    }
    try workers.await(io);
    if (evaluation.failure) |failure| return failure;
    const actual = switch (evaluation.result.?) {
        .value => |value| value,
        .javascript_error => |message| {
            std.log.err("native JavaScript: {s}", .{message});
            return error.NativeJavascriptFailed;
        },
    };
    if (!std.mem.eql(u8, actual, expected)) {
        std.log.err("native JavaScript returned {s}, expected {s}", .{ actual, expected });
        return error.NativeUnexpectedResult;
    }
}

const Dispatch = struct {
    view: webui.native.Window,
    submitted: std.atomic.Value(bool) = .init(false),
    applied: bool = false,
    rejected: bool = false,
    failure: ?anyerror = null,

    fn worker(self: *Dispatch) void {
        self.view.setTitle("wrong-thread") catch |err| {
            self.rejected = err == error.WrongThread;
        };
        self.view.dispatch(apply, self) catch |err| {
            self.failure = err;
        };
        self.submitted.store(true, .release);
    }
    fn apply(view: webui.native.Window, data: ?*anyopaque) !void {
        const self: *Dispatch = @ptrCast(@alignCast(data.?));
        try view.setTitle("Pure Zig: owner-thread dispatch passed");
        self.applied = true;
    }
};

const Point = struct { x: i32, y: i32 };

/// Move from `start` by `delta` in steps, holding the primary button when
/// `press` is set.
const Gesture = struct { start: Point, delta: Point, press: bool = true };

const win32 = struct {
    const Rect = extern struct { left: i32 = 0, top: i32 = 0, right: i32 = 0, bottom: i32 = 0 };
    extern "user32" fn mouse_event(flags: u32, dx: u32, dy: u32, data: u32, extra: usize) callconv(.winapi) void;
    extern "user32" fn GetSystemMetrics(index: c_int) callconv(.winapi) c_int;
    extern "user32" fn GetWindowRect(hwnd: *anyopaque, rect: *Rect) callconv(.winapi) c_int;
};

const objc = struct {
    const Bool = if (builtin.cpu.arch == .aarch64) bool else i8;
    extern "objc" fn sel_registerName(name: [*:0]const u8) *anyopaque;
    extern "objc" fn objc_msgSend() void;
};

fn movableByBackground(view: webui.native.Window) !bool {
    const send: *const fn (*anyopaque, *anyopaque) callconv(.c) objc.Bool = @ptrCast(&objc.objc_msgSend);
    const value = send((try view.handle()).cocoa, objc.sel_registerName("isMovableByWindowBackground"));
    return if (objc.Bool == bool) value else value != 0;
}

/// Synthesizes pointer input on a worker: Windows' modal move and size loops
/// run inside the UI thread's message dispatch until the button is released.
const Pointer = struct {
    io: std.Io,
    gesture: Gesture,
    failure: ?anyerror = null,
    done: std.atomic.Value(bool) = .init(false),

    fn run(self: *Pointer) void {
        const result = if (builtin.os.tag == .windows) self.sendInput() else self.xdotool();
        result catch |err| {
            self.failure = err;
        };
        self.done.store(true, .release);
    }

    fn path(self: *const Pointer) [4]Point {
        const start = self.gesture.start;
        const delta = self.gesture.delta;
        return .{
            start,
            .{ .x = start.x + @divTrunc(delta.x, 8), .y = start.y + @divTrunc(delta.y, 8) },
            .{ .x = start.x + @divTrunc(delta.x, 2), .y = start.y + @divTrunc(delta.y, 2) },
            .{ .x = start.x + delta.x, .y = start.y + delta.y },
        };
    }

    fn xdotool(self: *Pointer) !void {
        const points = self.path();
        var text: [points.len][2][16]u8 = undefined;
        var coordinates: [points.len][2][]const u8 = undefined;
        for (points, 0..) |point, index| {
            coordinates[index][0] = try std.fmt.bufPrint(&text[index][0], "{d}", .{point.x});
            coordinates[index][1] = try std.fmt.bufPrint(&text[index][1], "{d}", .{point.y});
        }
        // Pauses let WebKit deliver the press and first move before the
        // remaining motion, matching a person starting a drag. A hover
        // replaces the button commands with zero-length pauses.
        const down: [2][]const u8 = if (self.gesture.press) .{ "mousedown", "1" } else .{ "sleep", "0" };
        const up: [2][]const u8 = if (self.gesture.press) .{ "mouseup", "1" } else .{ "sleep", "0" };
        const argv = [_][]const u8{
            "xdotool",
            "mousemove",
            coordinates[0][0],
            coordinates[0][1],
            "sleep",
            "0.2",
            down[0],
            down[1],
            "sleep",
            "0.2",
            "mousemove",
            coordinates[1][0],
            coordinates[1][1],
            "sleep",
            "0.4",
            "mousemove",
            coordinates[2][0],
            coordinates[2][1],
            "sleep",
            "0.2",
            "mousemove",
            coordinates[3][0],
            coordinates[3][1],
            "sleep",
            "0.4",
            up[0],
            up[1],
            "sleep",
            "0.2",
        };
        try runTool(self.io, &argv);
    }

    fn sendInput(self: *Pointer) !void {
        const width = win32.GetSystemMetrics(0); // SM_CXSCREEN
        const height = win32.GetSystemMetrics(1); // SM_CYSCREEN
        if (width <= 1 or height <= 1) return error.PointerInputUnavailable;
        const points = self.path();
        const pauses = [_]u32{ 200, 400, 200, 400 };
        for (points, pauses, 0..) |point, pause, index| {
            // MOUSEEVENTF_MOVE | MOUSEEVENTF_ABSOLUTE uses 0..65535 per axis.
            const x: u32 = @intCast(@divTrunc(@as(i64, point.x) * 65535, width - 1));
            const y: u32 = @intCast(@divTrunc(@as(i64, point.y) * 65535, height - 1));
            win32.mouse_event(0x0001 | 0x8000, x, y, 0, 0);
            try std.Io.sleep(self.io, .fromMilliseconds(pause), .awake);
            if (index == 0 and self.gesture.press) {
                win32.mouse_event(0x0002, 0, 0, 0, 0); // MOUSEEVENTF_LEFTDOWN
                try std.Io.sleep(self.io, .fromMilliseconds(200), .awake);
            }
        }
        if (self.gesture.press) win32.mouse_event(0x0004, 0, 0, 0, 0); // MOUSEEVENTF_LEFTUP
        try std.Io.sleep(self.io, .fromMilliseconds(200), .awake);
    }
};

fn runTool(io: std.Io, argv: []const []const u8) !void {
    var child = std.process.spawn(io, .{ .argv = argv, .stdin = .ignore, .stdout = .ignore, .stderr = .inherit }) catch |err| switch (err) {
        error.FileNotFound => return error.PointerInputUnavailable,
        else => return err,
    };
    switch (try child.wait(io)) {
        .exited => |code| if (code != 0) return error.PointerInputFailed,
        else => return error.PointerInputFailed,
    }
}

fn pointerInputAvailable(io: std.Io) !bool {
    if (builtin.os.tag != .linux) return builtin.os.tag == .windows;
    runTool(io, &.{ "xdotool", "version" }) catch |err| switch (err) {
        error.PointerInputUnavailable => return false,
        else => return err,
    };
    return true;
}

fn perform(io: std.Io, view: webui.native.Window, gesture: Gesture) !void {
    var pointer: Pointer = .{ .io = io, .gesture = gesture };
    var workers: std.Io.Group = .init;
    defer workers.cancel(io);
    try workers.concurrent(io, Pointer.run, .{&pointer});
    const deadline: std.Io.Clock.Timestamp = .fromNow(io, .{ .clock = .awake, .raw = .fromSeconds(15) });
    while (!pointer.done.load(.acquire)) {
        if (!try view.poll()) return error.NativeClosedEarly;
        if (deadline.compare(.lte, .now(io, .awake))) return error.PointerInputTimeout;
        try std.Io.sleep(io, .fromMilliseconds(5), .awake);
    }
    try workers.await(io);
    if (pointer.failure) |err| return err;
}

/// Pump until `check` accepts the geometry, bounded like the other waits.
fn expectGeometry(io: std.Io, view: webui.native.Window, context: anytype, comptime check: fn (@TypeOf(context), webui.native.Geometry) bool) !webui.native.Geometry {
    const deadline: std.Io.Clock.Timestamp = .fromNow(io, .{ .clock = .awake, .raw = .fromSeconds(5) });
    while (try view.poll()) {
        const actual = try view.geometry();
        if (check(context, actual)) return actual;
        if (deadline.compare(.lte, .now(io, .awake))) {
            std.log.err("native geometry {any} after pointer input from {any}", .{ actual, context });
            return error.NativeInteractionFailed;
        }
        try std.Io.sleep(io, .fromMilliseconds(10), .awake);
    }
    return error.NativeClosedEarly;
}

fn movedEnough(before: webui.native.Geometry, after: webui.native.Geometry) bool {
    // The gesture moves by (80, 60); a drag begins after its first step.
    return after.position.x - before.position.x >= 40 and after.position.y - before.position.y >= 30;
}

fn widenedEnough(before: webui.native.Geometry, after: webui.native.Geometry) bool {
    return after.size.width >= before.size.width + 30;
}

fn rightEdge(view: webui.native.Window, geometry: webui.native.Geometry) !Point {
    const middle = geometry.position.y + @as(i32, @intCast(geometry.size.height / 2));
    if (builtin.os.tag == .windows) {
        // Geometry reports the outer origin and client size; the WS_THICKFRAME
        // sizing border lies outside the client area.
        var rect: win32.Rect = .{};
        if (win32.GetWindowRect((try view.handle()).win32, &rect) == 0) return error.NativeGeometryUnavailable;
        return .{ .x = rect.right - 2, .y = @divTrunc(rect.top + rect.bottom, 2) };
    }
    // A frameless GTK window is its WebView; its edge band is 6 px wide.
    return .{ .x = geometry.position.x + @as(i32, @intCast(geometry.size.width)) - 2, .y = middle };
}

/// Frameless dragging and edge resizing, with real pointer input where the
/// platform allows synthesizing it. Returns whether input was exercised.
fn frameless(io: std.Io, view: webui.native.Window, page: *Page, require_input: bool) !bool {
    try view.setFrameless(true);
    try view.setResizable(true);
    try view.setSize(.{ .width = 640, .height = 420 });
    try expectSize(io, view, .{ .width = 640, .height = 420 });
    if (builtin.os.tag == .macos) {
        // AppKit offers no public input synthesis without Accessibility
        // permission; verify the upstream background-move configuration.
        if (try view.dragRegion() != .window_background) return error.NativeDragRegionMismatch;
        if (!try movableByBackground(view)) return error.NativeFramelessNotMovable;
        try view.setFrameless(false);
        if (try movableByBackground(view)) return error.NativeFramedWindowMovable;
        return false;
    }
    const expected: webui.native.DragRegion = if (builtin.os.tag == .windows) .css_app_region else .webui_property;
    if (try view.dragRegion() != expected) return error.NativeDragRegionMismatch;
    if (!try pointerInputAvailable(io)) {
        if (require_input) return error.PointerInputUnavailable;
        std.debug.print("NATIVE INPUT SKIPPED: xdotool not found; frameless drag and resize not exercised\n", .{});
        try view.setFrameless(false);
        return false;
    }
    try view.setPosition(.{ .x = 160, .y = 120 });
    try view.focus();
    try evaluate(io, view, page.window, "document.documentElement.style.height = '100%'; document.body.style.cssText = 'margin:0;height:100%;--webui-app-region:drag;-webkit-app-region:drag;app-region:drag'; return 'region'", "region");
    const placed = try expectGeometry(io, view, @as(Point, .{ .x = 160, .y = 120 }), struct {
        // Window managers may keep a border on undecorated windows.
        fn check(target: Point, actual: webui.native.Geometry) bool {
            return @abs(actual.position.x - target.x) <= 8 and @abs(actual.position.y - target.y) <= 8;
        }
    }.check);
    const center: Point = .{
        .x = placed.position.x + @as(i32, @intCast(placed.size.width / 2)),
        .y = placed.position.y + @as(i32, @intCast(placed.size.height / 2)),
    };
    if (builtin.os.tag == .linux) {
        // The page controls the drag channel. A forged request without a held
        // primary button must not start a window-manager move.
        try evaluate(io, view, page.window, "window.webkit.messageHandlers.pureZigWebUIDrag.postMessage(true); return 'forged'", "forged");
        try perform(io, view, .{ .start = center, .delta = .{ .x = 80, .y = 60 }, .press = false });
        const hovered = try view.geometry();
        if (hovered.position.x != placed.position.x or hovered.position.y != placed.position.y) {
            std.log.err("native window moved from {any} to {any} without a press", .{ placed, hovered });
            return error.NativeUnrequestedMove;
        }
    }
    try perform(io, view, .{ .start = center, .delta = .{ .x = 80, .y = 60 } });
    const moved = try expectGeometry(io, view, placed, movedEnough);
    try perform(io, view, .{ .start = try rightEdge(view, moved), .delta = .{ .x = 60, .y = 0 } });
    _ = try expectGeometry(io, view, moved, widenedEnough);
    try view.setFrameless(false);
    return true;
}

/// Records page navigations and cancels those whose URL mentions "blocked".
const NavigationLog = struct {
    count: usize = 0,
    kinds: [6]webui.native.NavigationKind = undefined,
    urls: [6][256]u8 = undefined,
    lengths: [6]usize = undefined,

    fn decide(data: ?*anyopaque, request: webui.native.NavigationRequest) bool {
        const log: *NavigationLog = @ptrCast(@alignCast(data.?));
        if (log.count < log.kinds.len) {
            const length = @min(request.url.len, log.urls[log.count].len);
            @memcpy(log.urls[log.count][0..length], request.url[0..length]);
            log.lengths[log.count] = length;
            log.kinds[log.count] = request.kind;
        }
        log.count += 1;
        return std.mem.indexOf(u8, request.url, "blocked") == null;
    }

    fn expect(self: *const NavigationLog, index: usize, kind: webui.native.NavigationKind, suffix: []const u8) !void {
        const url = self.urls[index][0..self.lengths[index]];
        if (self.kinds[index] != kind or !std.mem.endsWith(u8, url, suffix)) {
            std.log.err("native navigation {d} was {s} {s}, expected {s} ...{s}", .{ index, @tagName(self.kinds[index]), url, @tagName(kind), suffix });
            return error.NativeNavigationMisreported;
        }
    }
};

fn pumpFor(io: std.Io, view: webui.native.Window, milliseconds: i64) !void {
    const deadline: std.Io.Clock.Timestamp = .fromNow(io, .{ .clock = .awake, .raw = .fromMilliseconds(milliseconds) });
    while (deadline.compare(.gt, .now(io, .awake))) {
        if (!try view.poll()) return error.NativeClosedEarly;
        try std.Io.sleep(io, .fromMilliseconds(10), .awake);
    }
}

fn awaitNavigations(io: std.Io, view: webui.native.Window, log: *const NavigationLog, count: usize) !void {
    const deadline: std.Io.Clock.Timestamp = .fromNow(io, .{ .clock = .awake, .raw = .fromSeconds(5) });
    while (log.count < count) {
        if (!try view.poll()) return error.NativeClosedEarly;
        if (deadline.compare(.lte, .now(io, .awake))) return error.NativeNavigationNotReported;
        try std.Io.sleep(io, .fromMilliseconds(10), .awake);
    }
}

/// Engine-level navigation decisions, independent of the bridge.
fn navigation(io: std.Io, view: webui.native.Window, page: *Page, url: []const u8) !void {
    var log: NavigationLog = .{};
    try view.setNavigationHandler(NavigationLog.decide, &log);
    defer view.setNavigationHandler(null, null) catch {};
    // Stop the bridge's own interception so the engine sees each navigation.
    try evaluate(io, view, page.window, "webui.allowNavigation(true); window.kept = 'kept'; location.assign('blocked-script'); return 'assigned'", "assigned");
    try awaitNavigations(io, view, &log, 1);
    try evaluate(io, view, page.window, "const a = document.createElement('a'); a.href = 'blocked-link'; document.body.appendChild(a); a.click(); return 'clicked'", "clicked");
    try awaitNavigations(io, view, &log, 2);
    try pumpFor(io, view, 300);
    try evaluate(io, view, page.window, "return window.kept", "kept");
    try log.expect(0, .other, "/blocked-script");
    // WebView2 reports no link or form kinds.
    try log.expect(1, if (builtin.os.tag == .windows) .other else .link, "/blocked-link");
    // favicon.ico answers 302 to favicon.svg; each hop is decided.
    try evaluate(io, view, page.window, "setTimeout(() => location.assign('favicon.ico'), 50); return 'leaving'", "leaving");
    try awaitNavigations(io, view, &log, 4);
    try pumpFor(io, view, 500);
    try log.expect(2, .other, "/favicon.ico");
    try log.expect(3, .other, "/favicon.svg");
    // Host navigations are never reported.
    page.ready.store(false, .release);
    var buffer: [512]u8 = undefined;
    try view.navigate(try std.fmt.bufPrint(&buffer, "{s}?host", .{url}));
    try pumpUntil(io, view, page, null);
    try evaluate(io, view, page.window, "return location.search", "?host");
    if (log.count != 4) {
        std.log.err("native navigation reported {d} requests, expected 4", .{log.count});
        for (0..@min(log.count, log.kinds.len)) |index|
            std.log.err("  {d}: {s} {s}", .{ index, @tagName(log.kinds[index]), log.urls[index][0..log.lengths[index]] });
        return error.NativeNavigationMisreported;
    }
}

/// Time for a window manager to apply one state change.
const settle_ms = 250;

fn smoke(io: std.Io, first: *Page, second: *Page, url: []const u8, require_input: bool) !void {
    const a = first.native.?;
    const b = second.native.?;
    try pumpUntil(io, a, first, null);
    try pumpUntil(io, a, second, null);
    try evaluate(io, a, first.window, "return await webui.call('ready')", "Connected to Zig");
    // Upstream presentation: WebView2 DevTools only in Debug builds, while
    // WKWebView and WebKitGTK keep them off; F5 is blocked unless logging
    // (on in Debug), and context menus are blocked outside inputs.
    if (try a.devToolsEnabled() != (builtin.os.tag == .windows and builtin.mode == .debug))
        return error.NativeDevToolsPolicy;
    try evaluate(io, a, first.window,
        \\const f5 = new KeyboardEvent('keydown', { key: 'F5', bubbles: true, cancelable: true });
        \\document.body.dispatchEvent(f5);
        \\const menu = new MouseEvent('contextmenu', { bubbles: true, cancelable: true });
        \\document.body.dispatchEvent(menu);
        \\const input = document.body.appendChild(document.createElement('input'));
        \\const inputMenu = new MouseEvent('contextmenu', { bubbles: true, cancelable: true });
        \\input.dispatchEvent(inputMenu);
        \\input.remove();
        \\return [f5.defaultPrevented, menu.defaultPrevented, inputMenu.defaultPrevented].join(',');
    , if (builtin.mode == .debug) "false,true,false" else "true,true,false");
    try first.window.bind(io, "late", runtimeBinding, first);
    try evaluate(io, a, first.window, "return await webui.late()", "runtime binding");
    try first.window.onEvent(io, runtimeEvent, first);
    try evaluate(io, a, first.window, "for (const id of ['late','runtime-event']) { const b=document.createElement('button'); b.id=id; document.body.appendChild(b); b.click(); } return 'clicked';", "clicked");
    const registration_deadline: std.Io.Clock.Timestamp = .fromNow(io, .{ .clock = .awake, .raw = .fromSeconds(5) });
    while (first.runtime_calls.load(.acquire) < 2 or first.runtime_events.load(.acquire) < 1) {
        if (!try a.poll()) return error.NativeClosedEarly;
        if (registration_deadline.compare(.lte, .now(io, .awake))) return error.NativeRegistrationFailed;
        try std.Io.sleep(io, .fromMilliseconds(5), .awake);
    }
    if (first.runtime_calls.load(.acquire) != 2 or first.runtime_events.load(.acquire) != 1)
        return error.NativeDuplicateDispatch;
    try a.setSize(.{ .width = 900, .height = 640 });
    try expectSize(io, a, .{ .width = 900, .height = 640 });
    try a.setMinimumSize(.{ .width = 320, .height = 240 });
    if (a.setSize(.{ .width = 319, .height = 240 })) |_| return error.NativeMinimumNotEnforced else |err| if (err != error.InvalidWindowSize) return err;
    try a.setResizable(false);
    try a.setResizable(true);
    try a.setFrameless(true);
    try a.setFrameless(false);
    try a.setPosition(.{ .x = 32, .y = 48 });
    try a.center();
    // X11 window managers apply state requests asynchronously, and GDK
    // applies (un)maximize to a window it considers unmapped only locally.
    // Let each change settle so a later request cannot race an earlier one
    // and leave GTK waiting for a configure reply that never comes.
    try a.minimize();
    try pumpFor(io, a, settle_ms);
    try a.restore();
    try pumpFor(io, a, settle_ms);
    try a.maximize();
    try pumpFor(io, a, settle_ms);
    try a.restore();
    try pumpFor(io, a, settle_ms);
    try a.setKiosk(true);
    try pumpFor(io, a, settle_ms);
    try a.setKiosk(false);
    try pumpFor(io, a, settle_ms);
    try a.setVisible(false);
    try pumpFor(io, a, settle_ms);
    try a.setVisible(true);
    try pumpFor(io, a, settle_ms);
    try a.focus();
    _ = try a.handle();
    if (builtin.os.tag == .macos) {
        if (a.setTransparent(true)) |_| return error.ExpectedUnsupportedTransparency else |err| if (err != error.UnsupportedNativeControl) return err;
    } else {
        try a.setTransparent(true);
        _ = try a.poll();
        try a.setTransparent(false);
    }
    var dispatch: Dispatch = .{ .view = a };
    var workers: std.Io.Group = .init;
    defer workers.cancel(io);
    try workers.concurrent(io, Dispatch.worker, .{&dispatch});
    const deadline: std.Io.Clock.Timestamp = .fromNow(io, .{ .clock = .awake, .raw = .fromSeconds(5) });
    while (!dispatch.submitted.load(.acquire) or !dispatch.applied) {
        if (dispatch.submitted.load(.acquire)) if (dispatch.failure) |err| return err;
        if (!try a.poll()) return error.NativeClosedEarly;
        if (deadline.compare(.lte, .now(io, .awake))) return error.NativeSmokeTimeout;
        try std.Io.sleep(io, .fromMilliseconds(5), .awake);
    }
    try workers.await(io);
    if (!dispatch.rejected) return error.NativeThreadGuardFailed;
    // setTitle applies at once; later page titles replace it while following.
    try expectTitle(io, a, a, "Pure Zig: owner-thread dispatch passed");
    try evaluate(io, a, first.window, "document.title = 'Page title sync'; return 'titled'", "titled");
    try expectTitle(io, a, a, "Page title sync");
    try a.setTitle("Host title");
    try expectTitle(io, a, a, "Host title");
    // WebView2 substitutes its own default for an empty document title.
    if (builtin.os.tag != .windows) {
        try evaluate(io, a, first.window, "document.title = ''; return 'emptied'", "emptied");
        try expectTitleKept(io, a, a, "Host title");
    }
    try evaluate(io, a, first.window, "document.title = 'After empty'; return 'titled'", "titled");
    try expectTitle(io, a, a, "After empty");
    // The second view opened with follow_page_title = false.
    try expectTitle(io, a, b, "Second host title");
    try evaluate(io, a, second.window, "document.title = 'Second page title'; return 'titled'", "titled");
    try expectTitleKept(io, a, b, "Second host title");
    try b.setFollowPageTitle(true);
    try expectTitle(io, a, b, "Second page title");
    try evaluate(io, a, second.window, "history.pushState({},'', '#second'); window.close(); return 'requested'", "requested");
    try pumpUntil(io, a, second, 1);
    if (!second.reentrant_destroy_rejected) return error.NativeCallbackGuardFailed;
    try evaluate(io, a, second.window, "return String(window.closed)", "false");
    _ = try second.window.close(io);
    try pumpUntil(io, a, second, 2);
    try evaluate(io, a, second.window, "return await webui.call('ready')", "Connected to Zig");
    second.allow_close = true;
    _ = try second.window.run(io, "window.close()");
    try pumpUntil(io, a, second, 3);
    // A's event pump must complete B's close, without polling B.
    _ = try a.poll();
    if (b.geometry()) |_| return error.NativeSecondaryCloseFailed else |err| if (err != error.NativeWindowClosed) return err;
    try evaluate(io, a, first.window, "return await webui.call('ready')", "Connected to Zig");
    try navigation(io, a, first, url);
    const interaction = if (try frameless(io, a, first, require_input)) "frameless drag+resize input" else "frameless configuration";
    try a.close();
    if (try a.poll()) return error.NativeForceCloseFailed;
    std.debug.print("NATIVE SMOKE PASS: bridge, presentation, geometry, controls, dispatch, titles, veto, history, navigation, {s}, multiwindow close\n", .{interaction});
}

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    var is_smoke = false;
    var expect_unavailable = false;
    var require_input = false;
    var options: webui.native.Options = .{ .title = "Pure Zig native WebView" };
    var index: usize = 1;
    while (index < args.len) : (index += 1) {
        if (std.mem.eql(u8, args[index], "--smoke")) is_smoke = true else if (std.mem.eql(u8, args[index], "--expect-unavailable")) {
            expect_unavailable = true;
        } else if (std.mem.eql(u8, args[index], "--require-input")) {
            require_input = true;
        } else if (std.mem.eql(u8, args[index], "--loader") and index + 1 < args.len) {
            index += 1;
            options.webview2_loader = args[index];
        } else return error.InvalidArguments;
    }
    var app = webui.App.init(init.gpa, .{});
    defer app.deinit();
    var first: Page = .{ .io = init.io, .window = try app.createWindow(.{ .content = .{ .html = html } }) };
    var second: Page = .{ .io = init.io, .window = try app.createWindow(.{ .content = .{ .html = html } }) };
    try first.window.bind(init.io, "ready", ready, &first);
    try second.window.bind(init.io, "ready", ready, &second);
    var running = try app.start(init.io);
    defer running.stop() catch {};
    options.close_handler = closeRequested;
    options.user_data = &first;
    first.allow_close = !is_smoke;
    var first_view = webui.native.Window.open(init.gpa, init.io, first.window, &running, options) catch |err| {
        if (expect_unavailable and (err == error.NativeRuntimeNotFound or err == error.NativeDisplayUnavailable)) {
            std.debug.print("NATIVE UNAVAILABLE PASS: {}\n", .{err});
            return;
        }
        if (is_smoke or expect_unavailable) return err;
        std.log.warn("native WebView unavailable: {}", .{err});
        return;
    };
    defer first_view.deinit() catch |err| std.log.err("native cleanup: {}", .{err});
    first.native = first_view;
    if (expect_unavailable) return error.ExpectedNativeUnavailable;
    std.debug.print("NATIVE READY\n", .{});
    if (is_smoke) {
        options.user_data = &second;
        options.title = "Second host title";
        options.follow_page_title = false;
        var second_view = try webui.native.Window.open(init.gpa, init.io, second.window, &running, options);
        defer second_view.deinit() catch |err| std.log.err("native cleanup: {}", .{err});
        second.native = second_view;
        const url = try first.window.url(&running, init.gpa);
        defer init.gpa.free(url);
        try smoke(init.io, &first, &second, url, require_input);
    } else {
        try first_view.run();
    }
}
