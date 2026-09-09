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

fn smoke(io: std.Io, first: *Page, second: *Page) !void {
    const a = first.native.?;
    const b = second.native.?;
    try pumpUntil(io, a, first, null);
    try pumpUntil(io, a, second, null);
    try evaluate(io, a, first.window, "return await webui.call('ready')", "Connected to Zig");
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
    try a.minimize();
    _ = try a.poll();
    try a.restore();
    try a.maximize();
    _ = try a.poll();
    try a.restore();
    try a.setKiosk(true);
    _ = try a.poll();
    try a.setKiosk(false);
    try a.setVisible(false);
    try a.setVisible(true);
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
    try a.close();
    if (try a.poll()) return error.NativeForceCloseFailed;
    std.debug.print("NATIVE SMOKE PASS: bridge, geometry, controls, dispatch, veto, history, multiwindow close\n", .{});
}

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    var is_smoke = false;
    var expect_unavailable = false;
    var options: webui.native.Options = .{ .title = "Pure Zig native WebView" };
    var index: usize = 1;
    while (index < args.len) : (index += 1) {
        if (std.mem.eql(u8, args[index], "--smoke")) is_smoke = true else if (std.mem.eql(u8, args[index], "--expect-unavailable")) {
            expect_unavailable = true;
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
        var second_view = try webui.native.Window.open(init.gpa, init.io, second.window, &running, options);
        defer second_view.deinit() catch |err| std.log.err("native cleanup: {}", .{err});
        second.native = second_view;
        try smoke(init.io, &first, &second);
    } else {
        try first_view.run();
    }
}
