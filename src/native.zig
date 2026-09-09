//! Optional native WebViews. All window operations run on the creating UI
//! thread; worker tasks use dispatch(). Link platform GUI frameworks only when
//! this module's window APIs are used. External-browser users need no GUI SDK.
const std = @import("std");
const builtin = @import("builtin");
const app = @import("app.zig");
const types = @import("native/types.zig");

pub const Options = types.Options;
pub const Size = types.Size;
pub const Position = types.Position;
pub const Geometry = types.Geometry;
pub const Handle = types.Handle;
pub const CloseHandler = types.CloseHandler;

const supported = switch (builtin.os.tag) {
    .macos, .linux, .windows => true,
    else => false,
};
const Backend = switch (builtin.os.tag) {
    .macos => @import("native/macos.zig").Backend,
    .linux => @import("native/linux.zig").Backend,
    .windows => @import("native/windows.zig").Backend,
    else => void,
};

pub const Task = *const fn (Window, ?*anyopaque) anyerror!void;
const QueuedTask = struct { callback: Task, user_data: ?*anyopaque };
const State = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    owner: std.Thread.Id,
    backend: *Backend,
    tasks: []QueuedTask,
    head: usize = 0,
    count: usize = 0,
    mutex: std.Io.Mutex = .init,
    closed: std.atomic.Value(bool) = .init(false),
    polling: bool = false,
    callback_depth: usize = 0,
    close_handler: ?CloseHandler,
    user_data: ?*anyopaque,
    minimum_size: ?Size = null,

    fn markClosed(self: *State) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.closed.store(true, .release);
        self.count = 0;
    }
};

/// Owned native window. Do not duplicate ownership or destroy it from a
/// callback. Join dispatch producers before deinit; queued user_data is borrowed
/// until its callback runs, or until close/deinit cancels the queue.
pub const Window = struct {
    state: *State,

    /// Host an existing capability-scoped WebUI window without launching a browser.
    pub fn open(gpa: std.mem.Allocator, io: std.Io, window: app.Window, running: *const app.Running, options: Options) !Window {
        const url = try window.url(running, gpa);
        defer gpa.free(url);
        return init(gpa, io, url, options);
    }

    /// Host an HTTP(S) URL. No certificate or Origin exceptions are installed.
    pub fn init(gpa: std.mem.Allocator, io: std.Io, url: []const u8, options: Options) !Window {
        if (!supported) return error.UnsupportedPlatform;
        try options.validate();
        try validateUrl(url);
        if (builtin.os.tag == .macos and pthread_main_np() == 0) return error.WrongThread;
        const state = try gpa.create(State);
        errdefer gpa.destroy(state);
        const tasks = try gpa.alloc(QueuedTask, options.max_pending_tasks);
        errdefer gpa.free(tasks);
        const terminated = try gpa.dupeZ(u8, url);
        defer gpa.free(terminated);
        state.* = .{
            .gpa = gpa,
            .io = io,
            .owner = std.Thread.getCurrentId(),
            .backend = undefined,
            .tasks = tasks,
            .close_handler = options.close_handler,
            .user_data = options.user_data,
            .minimum_size = options.minimum_size,
        };
        var backend_options = options;
        backend_options.close_handler = closeRequested;
        backend_options.user_data = state;
        state.backend = try Backend.create(gpa, io, terminated, backend_options);
        return .{ .state = state };
    }

    /// Destroy on the UI owner thread, outside poll/run callbacks.
    pub fn deinit(self: *Window) !void {
        try self.checkOwner();
        if (self.state.polling or self.state.callback_depth != 0)
            return error.ReentrantNativeOperation;
        const state = self.state;
        state.markClosed();
        if (supported) state.backend.destroy();
        state.gpa.free(state.tasks);
        state.gpa.destroy(state);
        self.* = undefined;
    }

    fn checkOwner(self: Window) !void {
        if (!supported) return error.UnsupportedPlatform;
        if (self.state.owner != std.Thread.getCurrentId()) return error.WrongThread;
    }

    fn checkOpen(self: Window) !void {
        try self.checkOwner();
        if (self.state.closed.load(.acquire)) return error.NativeWindowClosed;
    }

    pub fn isClosed(self: Window) bool {
        return self.state.closed.load(.acquire);
    }

    /// Thread-safe bounded submission. A successful enqueue does not guarantee
    /// execution if the window closes; caller retains ownership of user_data.
    pub fn dispatch(self: Window, callback: Task, user_data: ?*anyopaque) !void {
        const state = self.state;
        state.mutex.lockUncancelable(state.io);
        defer state.mutex.unlock(state.io);
        if (state.closed.load(.acquire)) return error.NativeWindowClosed;
        if (state.count == state.tasks.len) return error.NativeTaskQueueFull;
        state.tasks[(state.head + state.count) % state.tasks.len] = .{ .callback = callback, .user_data = user_data };
        state.count += 1;
    }

    /// Drain one bounded task batch and native events without blocking.
    pub fn poll(self: Window) !bool {
        try self.checkOwner();
        const state = self.state;
        if (state.closed.load(.acquire)) return false;
        if (state.polling or state.callback_depth != 0)
            return error.ReentrantNativeOperation;
        state.polling = true;
        defer state.polling = false;
        state.mutex.lockUncancelable(state.io);
        const count = state.count;
        state.mutex.unlock(state.io);
        for (0..count) |_| {
            state.mutex.lockUncancelable(state.io);
            if (state.closed.load(.acquire) or state.count == 0) {
                state.mutex.unlock(state.io);
                break;
            }
            const queued = state.tasks[state.head];
            state.head = (state.head + 1) % state.tasks.len;
            state.count -= 1;
            state.mutex.unlock(state.io);
            try queued.callback(self, queued.user_data);
        }
        if (state.closed.load(.acquire)) return false;
        if (supported and !try state.backend.pump()) {
            state.markClosed();
            return false;
        }
        return true;
    }

    /// Run on the UI owner thread while std.Io worker tasks serve the backend.
    /// The caller still owns Running.stop() and App.deinit().
    pub fn run(self: Window) !void {
        while (try self.poll()) try std.Io.sleep(self.state.io, .fromMilliseconds(10), .awake);
    }

    pub fn close(self: Window) !void {
        try self.checkOwner();
        if (self.isClosed()) return;
        if (supported) try self.state.backend.close();
        self.state.markClosed();
    }

    pub fn setTitle(self: Window, value: []const u8) !void {
        try self.checkOpen();
        try types.validateText(value);
        const terminated = try self.state.gpa.dupeZ(u8, value);
        defer self.state.gpa.free(terminated);
        if (supported) try self.state.backend.setTitle(terminated);
    }

    pub fn navigate(self: Window, value: []const u8) !void {
        try self.checkOpen();
        try validateUrl(value);
        const terminated = try self.state.gpa.dupeZ(u8, value);
        defer self.state.gpa.free(terminated);
        if (supported) try self.state.backend.navigate(terminated);
    }

    pub fn setSize(self: Window, value: Size) !void {
        try self.checkOpen();
        try types.validateSize(value);
        if (self.state.minimum_size) |minimum|
            if (value.width < minimum.width or value.height < minimum.height)
                return error.InvalidWindowSize;
        if (supported) try self.state.backend.setSize(value);
    }

    pub fn setPosition(self: Window, value: Position) !void {
        try self.checkOpen();
        if (supported) try self.state.backend.setPosition(value);
    }

    pub fn center(self: Window) !void {
        try self.checkOpen();
        if (supported) try self.state.backend.center();
    }

    pub fn setMinimumSize(self: Window, value: Size) !void {
        try self.checkOpen();
        try types.validateSize(value);
        if (supported) try self.state.backend.setMinimumSize(value);
        self.state.minimum_size = value;
    }

    pub fn setResizable(self: Window, value: bool) !void {
        try self.checkOpen();
        if (supported) try self.state.backend.setResizable(value);
    }

    pub fn setFrameless(self: Window, value: bool) !void {
        try self.checkOpen();
        if (supported) try self.state.backend.setFrameless(value);
    }

    pub fn setTransparent(self: Window, value: bool) !void {
        try self.checkOpen();
        if (supported) try self.state.backend.setTransparent(value);
    }

    pub fn setVisible(self: Window, value: bool) !void {
        try self.checkOpen();
        if (supported) try self.state.backend.setVisible(value);
    }

    pub fn setKiosk(self: Window, value: bool) !void {
        try self.checkOpen();
        if (supported) try self.state.backend.setKiosk(value);
    }

    pub fn minimize(self: Window) !void {
        try self.checkOpen();
        if (supported) try self.state.backend.minimize();
    }

    pub fn maximize(self: Window) !void {
        try self.checkOpen();
        if (supported) try self.state.backend.maximize();
    }

    pub fn restore(self: Window) !void {
        try self.checkOpen();
        if (supported) try self.state.backend.restore();
    }

    pub fn focus(self: Window) !void {
        try self.checkOpen();
        if (supported) try self.state.backend.focus();
    }

    pub fn geometry(self: Window) !Geometry {
        try self.checkOpen();
        if (supported) return self.state.backend.geometry();
        return error.UnsupportedPlatform;
    }

    pub fn handle(self: Window) !Handle {
        try self.checkOpen();
        if (supported) return self.state.backend.handle();
        return error.UnsupportedPlatform;
    }

    pub fn setCloseHandler(self: Window, handler: ?CloseHandler, user_data: ?*anyopaque) !void {
        try self.checkOpen();
        self.state.close_handler = handler;
        self.state.user_data = user_data;
    }
};

fn closeRequested(user_data: ?*anyopaque) bool {
    const state: *State = @ptrCast(@alignCast(user_data.?));
    state.callback_depth += 1;
    defer state.callback_depth -= 1;
    const allowed = if (state.close_handler) |handler| handler(state.user_data) else true;
    if (allowed) state.markClosed();
    return allowed;
}

fn validateUrl(value: []const u8) !void {
    try types.validateText(value);
    const parsed = std.Uri.parse(value) catch return error.InvalidUrl;
    if (parsed.host == null or
        !(std.ascii.eqlIgnoreCase(parsed.scheme, "http") or std.ascii.eqlIgnoreCase(parsed.scheme, "https")))
        return error.InvalidUrl;
}

extern "c" fn pthread_main_np() c_int;

test "native navigation only accepts valid HTTP origins" {
    try validateUrl("http://127.0.0.1:8080/capability/");
    try std.testing.expectError(error.InvalidUrl, validateUrl("javascript:alert(1)"));
    try std.testing.expectError(error.InvalidUrl, validateUrl("file:///tmp/page.html"));
    try std.testing.expectError(error.InvalidNativeText, validateUrl("https://example.com/\x00hidden"));
}
