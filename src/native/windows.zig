const std = @import("std");
const types = @import("types.zig");

// ABI source: Microsoft's Microsoft.Web.WebView2 1.0.2903.40 NuGet package,
// build/native/include/WebView2.h (C vtables, not the C++ declaration order).
// https://api.nuget.org/v3-flatcontainer/microsoft.web.webview2/1.0.2903.40/microsoft.web.webview2.1.0.2903.40.nupkg
// Win32 declarations: microsoft/win32metadata, RecompiledIdlHeaders/um/WinUser.h.
const GUID = std.os.windows.GUID;
const HRESULT = i32;
const HWND = *anyopaque;
const RECT = extern struct { left: i32 = 0, top: i32 = 0, right: i32 = 0, bottom: i32 = 0 };
const POINT = extern struct { x: i32 = 0, y: i32 = 0 };
const Color = extern struct { a: u8, r: u8, g: u8, b: u8 };
const Token = extern struct { value: i64 = 0 };
const iid_unknown = GUID.parse("{00000000-0000-0000-c000-000000000046}");
const iid_environment_callback = GUID.parse("{4e8a3389-c9d8-4bd2-b6b5-124fee6cc14d}");
const iid_controller_callback = GUID.parse("{6c4819f3-c9b7-4260-8127-c9f5bde7f68c}");
const iid_close_callback = GUID.parse("{57213f19-00e6-49fa-8e07-898ea01ecbd2}"); // WebMessageReceived
const iid_script_callback = GUID.parse("{b99369f3-9b11-47b5-bc6f-8e7895fcea17}");
const iid_controller2 = GUID.parse("{c979903e-d4ca-4228-92eb-47ee3fa96eab}");

const close_message = "pure-zig-webui:close-request";
const close_script = blk: {
    @setEvalBranchQuota(10_000);
    break :blk std.unicode.utf8ToUtf16LeStringLiteral(
        "(()=>{if(window!==window.top)return;const post=window.chrome.webview.postMessage.bind(window.chrome.webview);" ++
            "Object.defineProperty(window,'close',{value:()=>post('" ++ close_message ++ "'),writable:false,configurable:false});" ++
            "Object.defineProperty(window,'__zigWebuiNativeClose',{value:window.close});})();",
    );
};
// Every HWND on an STA is pumped together. Keep a mutation-safe cursor instead
// of retaining a next pointer across application callbacks which can destroy it.
threadlocal var live_windows: ?*Backend = null;
threadlocal var close_cursor: ?*Backend = null;
threadlocal var draining_closes: bool = false;

const Com = extern struct {
    vtable: [*]const *const anyopaque,

    fn method(self: *Com, comptime slot: usize, comptime F: type) F {
        return @ptrCast(self.vtable[slot]);
    }
    fn retain(self: *Com) void {
        _ = self.method(1, *const fn (*Com) callconv(.winapi) u32)(self);
    }
    fn release(self: *Com) void {
        _ = self.method(2, *const fn (*Com) callconv(.winapi) u32)(self);
    }
    fn closeController(self: *Com) HRESULT {
        return self.method(24, *const fn (*Com) callconv(.winapi) HRESULT)(self);
    }
};

fn check(hr: HRESULT) !void {
    if (hr >= 0) return;
    return switch (@as(u32, @bitCast(hr))) {
        0x80070002, 0x8007007e => error.NativeRuntimeNotFound,
        0x80070005 => error.NativeAccessDenied,
        0x80004002 => error.UnsupportedNativeOperation,
        else => error.NativeOperationFailed,
    };
}

// Completion objects are independent of Backend and its allocator. WebView2
// retains them according to COM rules. Timeout detaches our reference, never
// frees a runtime-owned callback. Late controller success is explicitly Closed.
// The loader stays referenced until every callback and Backend releases it;
// runtime COM implementation code lives in the separately loaded runtime DLL.
const Loader = struct {
    module: *anyopaque,
    refs: std.atomic.Value(u32) = .init(1),

    fn retain(self: *Loader) void {
        _ = self.refs.fetchAdd(1, .monotonic);
    }
    fn release(self: *Loader) void {
        if (self.refs.fetchSub(1, .acq_rel) != 1) return;
        _ = FreeLibrary(self.module);
        std.heap.page_allocator.destroy(self);
    }
};

const Completion = struct {
    vtable: *const Vtable = &vtable_value,
    refs: std.atomic.Value(u32) = .init(1),
    loader: *Loader,
    controller: bool,
    abandoned: bool = false,
    done: bool = false,
    status: HRESULT = 0,
    result: ?*Com = null,

    const Vtable = extern struct {
        query: *const fn (*Completion, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
        add_ref: *const fn (*Completion) callconv(.winapi) u32,
        release: *const fn (*Completion) callconv(.winapi) u32,
        invoke: *const fn (*Completion, HRESULT, ?*Com) callconv(.winapi) HRESULT,
    };
    const vtable_value: Vtable = .{ .query = query, .add_ref = addRef, .release = release, .invoke = invoke };

    fn create(loader: *Loader, controller: bool) !*Completion {
        const self = try std.heap.page_allocator.create(Completion);
        loader.retain();
        self.* = .{ .loader = loader, .controller = controller };
        return self;
    }
    fn query(self: *Completion, iid: *const GUID, out: *?*anyopaque) callconv(.winapi) HRESULT {
        out.* = null;
        const own = if (self.controller) iid_controller_callback else iid_environment_callback;
        if (!std.mem.eql(u8, std.mem.asBytes(iid), std.mem.asBytes(&own)) and
            !std.mem.eql(u8, std.mem.asBytes(iid), std.mem.asBytes(&iid_unknown)))
            return @bitCast(@as(u32, 0x80004002));
        out.* = self;
        _ = addRef(self);
        return 0;
    }
    fn addRef(self: *Completion) callconv(.winapi) u32 {
        return self.refs.fetchAdd(1, .monotonic) + 1;
    }
    fn release(self: *Completion) callconv(.winapi) u32 {
        const remaining = self.refs.fetchSub(1, .acq_rel) - 1;
        if (remaining == 0) {
            if (self.result) |result| {
                if (self.controller) _ = result.closeController();
                result.release();
            }
            self.loader.release();
            std.heap.page_allocator.destroy(self);
        }
        return remaining;
    }
    fn invoke(self: *Completion, status: HRESULT, result: ?*Com) callconv(.winapi) HRESULT {
        if (self.abandoned or self.done) {
            if (self.controller) {
                if (result) |controller| _ = controller.closeController();
            }
            return 0;
        }
        self.status = status;
        if (result) |value| {
            value.retain();
            self.result = value;
        }
        self.done = true;
        return 0;
    }
    fn detach(self: *Completion) void {
        self.abandoned = true;
        _ = release(self);
    }
};

// Document-start registration must finish before Navigate. The runtime can
// complete after timeout: this object never borrows Backend or its allocator.
const ScriptCompletion = struct {
    vtable: *const Vtable = &vtable_value,
    refs: std.atomic.Value(u32) = .init(1),
    loader: *Loader,
    done: bool = false,
    status: HRESULT = 0,
    const Vtable = extern struct {
        query: *const fn (*ScriptCompletion, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
        add_ref: *const fn (*ScriptCompletion) callconv(.winapi) u32,
        release: *const fn (*ScriptCompletion) callconv(.winapi) u32,
        invoke: *const fn (*ScriptCompletion, HRESULT, ?[*:0]const u16) callconv(.winapi) HRESULT,
    };
    const vtable_value: Vtable = .{ .query = query, .add_ref = addRef, .release = release, .invoke = invoke };
    fn query(self: *ScriptCompletion, iid: *const GUID, out: *?*anyopaque) callconv(.winapi) HRESULT {
        out.* = null;
        if (!std.mem.eql(u8, std.mem.asBytes(iid), std.mem.asBytes(&iid_script_callback)) and
            !std.mem.eql(u8, std.mem.asBytes(iid), std.mem.asBytes(&iid_unknown)))
            return @bitCast(@as(u32, 0x80004002));
        out.* = self;
        _ = addRef(self);
        return 0;
    }
    fn addRef(self: *ScriptCompletion) callconv(.winapi) u32 {
        return self.refs.fetchAdd(1, .monotonic) + 1;
    }
    fn release(self: *ScriptCompletion) callconv(.winapi) u32 {
        const remaining = self.refs.fetchSub(1, .acq_rel) - 1;
        if (remaining == 0) {
            self.loader.release();
            std.heap.page_allocator.destroy(self);
        }
        return remaining;
    }
    fn invoke(self: *ScriptCompletion, status: HRESULT, _: ?[*:0]const u16) callconv(.winapi) HRESULT {
        self.status = status;
        self.done = true;
        return 0;
    }
};

const CloseCallback = struct {
    vtable: *const Vtable = &vtable_value,
    refs: std.atomic.Value(u32) = .init(1),
    owner: ?*Backend,
    const Vtable = extern struct {
        query: *const fn (*CloseCallback, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
        add_ref: *const fn (*CloseCallback) callconv(.winapi) u32,
        release: *const fn (*CloseCallback) callconv(.winapi) u32,
        invoke: *const fn (*CloseCallback, ?*Com, ?*Com) callconv(.winapi) HRESULT,
    };
    const vtable_value: Vtable = .{ .query = query, .add_ref = addRef, .release = release, .invoke = invoke };
    fn query(self: *CloseCallback, iid: *const GUID, out: *?*anyopaque) callconv(.winapi) HRESULT {
        out.* = null;
        if (!std.mem.eql(u8, std.mem.asBytes(iid), std.mem.asBytes(&iid_close_callback)) and
            !std.mem.eql(u8, std.mem.asBytes(iid), std.mem.asBytes(&iid_unknown)))
            return @bitCast(@as(u32, 0x80004002));
        out.* = self;
        _ = addRef(self);
        return 0;
    }
    fn addRef(self: *CloseCallback) callconv(.winapi) u32 {
        return self.refs.fetchAdd(1, .monotonic) + 1;
    }
    fn release(self: *CloseCallback) callconv(.winapi) u32 {
        const remaining = self.refs.fetchSub(1, .acq_rel) - 1;
        if (remaining == 0) std.heap.page_allocator.destroy(self);
        return remaining;
    }
    fn invoke(self: *CloseCallback, _: ?*Com, args: ?*Com) callconv(.winapi) HRESULT {
        const owner = self.owner orelse return 0;
        if (owner.closed) return 0;
        const message_args = args orelse return 0;
        var text: ?[*:0]u16 = null;
        const status = message_args.method(5, *const fn (*Com, *?[*:0]u16) callconv(.winapi) HRESULT)(message_args, &text);
        defer if (text) |value| CoTaskMemFree(value);
        if (status < 0) return 0; // Other application messages need not be strings.
        const value = text orelse return 0;
        // Fixed command only, with bounded comparison and no URL/code evaluation.
        for (close_message, 0..) |character, index| {
            if (value[index] != character) return 0;
        }
        if (value[close_message.len] == 0) owner.close_requested = true;
        return 0;
    }
};

pub const Backend = struct {
    gpa: std.mem.Allocator,
    loader: ?*Loader = null,
    com_initialized: bool = false,
    instance: ?*anyopaque = null,
    class_atom: u16 = 0,
    hwnd: ?HWND = null,
    controller: ?*Com = null,
    webview: ?*Com = null,
    close_callback: ?*CloseCallback = null,
    close_token: ?Token = null,
    close_handler: ?types.CloseHandler,
    user_data: ?*anyopaque,
    close_requested: bool = false,
    closed: bool = false,
    event_error: ?anyerror = null,
    minimum: ?types.Size,
    resizable: bool,
    frameless: bool,
    kiosk: bool = false,
    transparent: bool = false,
    placement: WINDOWPLACEMENT = .{},
    previous: ?*Backend = null,
    next: ?*Backend = null,
    registered: bool = false,

    pub fn create(gpa: std.mem.Allocator, io: std.Io, url: [:0]const u8, options: types.Options) !*Backend {
        const self = try gpa.create(Backend);
        self.* = .{
            .gpa = gpa,
            .close_handler = options.close_handler,
            .user_data = options.user_data,
            .minimum = options.minimum_size,
            .resizable = options.resizable,
            .frameless = options.frameless,
            .transparent = options.transparent,
        };
        errdefer self.destroy();
        self.next = live_windows;
        if (live_windows) |head| head.previous = self;
        live_windows = self;
        self.registered = true;
        const init = CoInitializeEx(null, 2); // COINIT_APARTMENTTHREADED
        if (@as(u32, @bitCast(init)) == 0x80010106) return error.NativeApartmentRequired;
        try check(init);
        self.com_initialized = true; // S_FALSE also requires CoUninitialize.
        const loader_name = try std.unicode.utf8ToUtf16LeAllocZ(gpa, options.webview2_loader orelse "WebView2Loader.dll");
        defer gpa.free(loader_name);
        const module = LoadLibraryW(loader_name.ptr) orelse return error.NativeRuntimeNotFound;
        const loader = std.heap.page_allocator.create(Loader) catch |err| {
            _ = FreeLibrary(module);
            return err;
        };
        loader.* = .{ .module = module };
        self.loader = loader;
        const create_environment: *const fn (?[*:0]const u16, ?[*:0]const u16, ?*Com, *Completion) callconv(.winapi) HRESULT =
            @ptrCast(GetProcAddress(module, "CreateCoreWebView2EnvironmentWithOptions") orelse return error.NativeRuntimeNotFound);
        self.instance = GetModuleHandleW(null) orelse return error.NativeInitializationFailed;
        var class_buffer: [64]u8 = undefined;
        const class_name = try std.fmt.bufPrint(&class_buffer, "PureZigWebUI-{x}", .{@intFromPtr(self)});
        const class_wide = try std.unicode.utf8ToUtf16LeAllocZ(gpa, class_name);
        defer gpa.free(class_wide);
        const wc: WNDCLASSEXW = .{
            .wnd_proc = windowProc,
            .instance = self.instance,
            .cursor = LoadCursorW(null, @ptrFromInt(32512)), // IDC_ARROW
            .background = null, // WM_ERASEBKGND paints only opaque hosts.
            .class_name = class_wide.ptr,
        };
        self.class_atom = RegisterClassExW(&wc);
        if (self.class_atom == 0) return error.NativeInitializationFailed;
        const title = try std.unicode.utf8ToUtf16LeAllocZ(gpa, options.title);
        defer gpa.free(title);
        const outer = try self.outerSize(options.size);
        const initial = options.position orelse types.Position{ .x = std.math.minInt(i32), .y = std.math.minInt(i32) };
        self.hwnd = CreateWindowExW(if (options.transparent) 0x00200000 else 0, @ptrFromInt(self.class_atom), title.ptr, self.style(), initial.x, initial.y, outer.x, outer.y, null, null, self.instance, self) orelse return error.NativeWindowCreationFailed;
        const profile = if (options.profile_directory) |path| try std.unicode.utf8ToUtf16LeAllocZ(gpa, path) else null;
        defer if (profile) |path| gpa.free(path);
        const start = std.Io.Clock.awake.now(io);
        const environment_completion = try Completion.create(loader, false);
        defer environment_completion.detach();
        try check(create_environment(null, if (profile) |path| path.ptr else null, null, environment_completion));
        const environment = try self.awaitCompletion(io, start, environment_completion);
        defer environment.release();
        const controller_completion = try Completion.create(loader, true);
        defer controller_completion.detach();
        try check(environment.method(3, *const fn (*Com, HWND, *Completion) callconv(.winapi) HRESULT)(environment, try self.window(), controller_completion));
        self.controller = try self.awaitCompletion(io, start, controller_completion);
        const controller = self.controller.?;
        try check(controller.method(25, *const fn (*Com, *?*Com) callconv(.winapi) HRESULT)(controller, &self.webview));
        const webview = self.webview orelse return error.NativeInitializationFailed;
        var settings: ?*Com = null;
        try check(webview.method(3, *const fn (*Com, *?*Com) callconv(.winapi) HRESULT)(webview, &settings));
        const script_settings = settings orelse return error.NativeInitializationFailed;
        defer script_settings.release();
        try check(script_settings.method(4, *const fn (*Com, i32) callconv(.winapi) HRESULT)(script_settings, 1));
        try check(script_settings.method(6, *const fn (*Com, i32) callconv(.winapi) HRESULT)(script_settings, 1));
        self.close_callback = try std.heap.page_allocator.create(CloseCallback);
        self.close_callback.?.* = .{ .owner = self };
        var token: Token = .{};
        try check(webview.method(34, *const fn (*Com, *CloseCallback, *Token) callconv(.winapi) HRESULT)(webview, self.close_callback.?, &token));
        self.close_token = token;
        // WindowCloseRequested is too late to guarantee veto or repeat requests;
        // Chromium can also refuse native window.close after history navigation.
        // Replace it before page scripts run, without marking the page closed.
        const script_completion = try std.heap.page_allocator.create(ScriptCompletion);
        loader.retain();
        script_completion.* = .{ .loader = loader };
        defer _ = ScriptCompletion.release(script_completion);
        try check(webview.method(27, *const fn (*Com, [*:0]const u16, *ScriptCompletion) callconv(.winapi) HRESULT)(webview, close_script, script_completion));
        while (!script_completion.done) {
            if (!(try self.pump())) return error.NativeWindowClosed;
            if (start.durationTo(std.Io.Clock.awake.now(io)).toMilliseconds() >= 15_000)
                return error.NativeInitializationTimeout;
            if (!script_completion.done) try std.Io.sleep(io, .fromMilliseconds(1), .awake);
        }
        try check(script_completion.status);
        try self.resizeController();
        if (options.transparent) try self.setTransparent(true);
        if (options.center) try self.center();
        if (options.kiosk) try self.setKiosk(true);
        try self.navigate(url);
        try self.setVisible(!options.hidden);
        return self;
    }

    fn awaitCompletion(self: *Backend, io: std.Io, start: std.Io.Timestamp, completion: *Completion) !*Com {
        while (!completion.done) {
            if (!(try self.pump())) return error.NativeWindowClosed;
            if (start.durationTo(std.Io.Clock.awake.now(io)).toMilliseconds() >= 15_000)
                return error.NativeInitializationTimeout;
            if (!completion.done) try std.Io.sleep(io, .fromMilliseconds(1), .awake);
        }
        try check(completion.status);
        const result = completion.result orelse return error.NativeInitializationFailed;
        completion.result = null; // transfer the callback's retained reference
        return result;
    }

    pub fn destroy(self: *Backend) void {
        if (self.registered) {
            if (close_cursor == self) close_cursor = self.next;
            if (self.previous) |previous| previous.next = self.next else live_windows = self.next;
            if (self.next) |next| next.previous = self.previous;
            self.registered = false;
        }
        self.releaseWebView();
        if (self.hwnd) |hwnd| {
            // No WndProc may retain self beyond DestroyWindow.
            _ = setWindowLongPtr(hwnd, -21, 0);
            _ = DestroyWindow(hwnd);
            self.hwnd = null;
        }
        if (self.class_atom != 0) _ = UnregisterClassW(@ptrFromInt(self.class_atom), self.instance);
        // Apartment teardown may synchronously release/invoke abandoned creation
        // callbacks. They own their own allocation and loader reference.
        if (self.com_initialized) CoUninitialize();
        if (self.loader) |loader| loader.release();
        self.gpa.destroy(self);
    }

    fn releaseWebView(self: *Backend) void {
        if (self.close_callback) |callback| callback.owner = null;
        if (self.webview) |webview| {
            if (self.close_token) |token| {
                _ = webview.method(35, *const fn (*Com, Token) callconv(.winapi) HRESULT)(webview, token);
                self.close_token = null;
            }
        }
        if (self.controller) |controller| _ = controller.closeController();
        if (self.webview) |webview| webview.release();
        self.webview = null;
        if (self.controller) |controller| controller.release();
        self.controller = null;
        if (self.close_callback) |callback| _ = CloseCallback.release(callback);
        self.close_callback = null;
    }

    pub fn pump(self: *Backend) !bool {
        // Drain all thread windows, but bound each pass under an input flood.
        // Leave WM_QUIT to the embedding application's own loop.
        var message: MSG = undefined;
        for (0..256) |_| {
            if (PeekMessageW(&message, null, 0, 0, 0) == 0) break;
            if (message.message == 0x12) return error.NativeApplicationQuit;
            if (PeekMessageW(&message, null, 0, 0, 1) == 0) break;
            _ = TranslateMessage(&message);
            _ = DispatchMessageW(&message);
        }
        if (!draining_closes) {
            draining_closes = true;
            defer draining_closes = false;
            close_cursor = live_windows;
            defer close_cursor = null;
            while (close_cursor) |owner| {
                close_cursor = owner.next;
                if (owner.close_requested and !owner.closed) {
                    owner.close_requested = false;
                    const allow = if (owner.close_handler) |handler| handler(owner.user_data) else true;
                    if (allow) owner.close() catch |err| {
                        owner.event_error = err;
                    };
                }
                if (owner.closed) owner.releaseWebView();
            }
        }
        if (self.event_error) |err| {
            self.event_error = null;
            return err;
        }
        return !self.closed;
    }

    pub fn close(self: *Backend) !void {
        if (self.closed) return;
        self.releaseWebView();
        if (self.hwnd) |hwnd| {
            if (DestroyWindow(hwnd) == 0) return error.NativeOperationFailed;
        }
        self.hwnd = null;
        self.closed = true;
    }
    fn window(self: *Backend) !HWND {
        return self.hwnd orelse error.NativeWindowClosed;
    }
    fn style(self: *const Backend) u32 {
        if (self.kiosk or self.frameless) return 0x80000000 | 0x02000000 | 0x04000000; // POPUP, CLIPCHILDREN, CLIPSIBLINGS
        return 0x00c80000 | 0x00020000 | 0x02000000 | 0x04000000 |
            @as(u32, if (self.resizable) 0x00050000 else 0); // caption, system menu, minimize, size/maximize
    }
    fn outerSize(self: *const Backend, size: types.Size) !POINT {
        var rect: RECT = .{ .right = @intCast(size.width), .bottom = @intCast(size.height) };
        if (AdjustWindowRectEx(&rect, self.style(), 0, 0) == 0) return error.NativeOperationFailed;
        const width = @as(i64, rect.right) - rect.left;
        const height = @as(i64, rect.bottom) - rect.top;
        if (width > std.math.maxInt(i32) or height > std.math.maxInt(i32)) return error.InvalidWindowSize;
        return .{ .x = @intCast(width), .y = @intCast(height) };
    }
    fn resizeController(self: *Backend) !void {
        const controller = self.controller orelse return;
        var rect: RECT = .{};
        if (GetClientRect(try self.window(), &rect) == 0) return error.NativeOperationFailed;
        try check(controller.method(6, *const fn (*Com, RECT) callconv(.winapi) HRESULT)(controller, rect));
    }
    pub fn setTitle(self: *Backend, title: [:0]const u8) !void {
        const hwnd = try self.window();
        const text = try std.unicode.utf8ToUtf16LeAllocZ(self.gpa, title);
        defer self.gpa.free(text);
        if (SetWindowTextW(hwnd, text.ptr) == 0) return error.NativeOperationFailed;
    }
    pub fn navigate(self: *Backend, url: [:0]const u8) !void {
        _ = try self.window();
        const webview = self.webview orelse return error.NativeWindowClosed;
        const text = try std.unicode.utf8ToUtf16LeAllocZ(self.gpa, url);
        defer self.gpa.free(text);
        try check(webview.method(5, *const fn (*Com, [*:0]const u16) callconv(.winapi) HRESULT)(webview, text.ptr));
    }
    pub fn setSize(self: *Backend, value: types.Size) !void {
        const hwnd = try self.window();
        if (self.kiosk) return error.UnsupportedNativeOperation;
        if (self.minimum) |minimum| {
            if (value.width < minimum.width or value.height < minimum.height)
                return error.InvalidMinimumSize;
        }
        const size = try self.outerSize(value);
        if (SetWindowPos(hwnd, null, 0, 0, size.x, size.y, 0x16) == 0) return error.NativeOperationFailed;
        try self.resizeController();
    }
    pub fn setPosition(self: *Backend, value: types.Position) !void {
        const hwnd = try self.window();
        if (self.kiosk) return error.UnsupportedNativeOperation;
        if (SetWindowPos(hwnd, null, value.x, value.y, 0, 0, 0x15) == 0) return error.NativeOperationFailed;
    }
    fn monitor(self: *Backend) !MONITORINFO {
        const display = MonitorFromWindow(try self.window(), 2) orelse return error.NativeDisplayUnavailable;
        var info: MONITORINFO = .{};
        if (GetMonitorInfoW(display, &info) == 0) return error.NativeDisplayUnavailable;
        return info;
    }
    pub fn center(self: *Backend) !void {
        const info = try self.monitor();
        var rect: RECT = .{};
        if (GetWindowRect(try self.window(), &rect) == 0) return error.NativeOperationFailed;
        try self.setPosition(.{
            .x = @intCast(@as(i64, info.work.left) + @divTrunc(@as(i64, info.work.right) - info.work.left - (@as(i64, rect.right) - rect.left), 2)),
            .y = @intCast(@as(i64, info.work.top) + @divTrunc(@as(i64, info.work.bottom) - info.work.top - (@as(i64, rect.bottom) - rect.top), 2)),
        });
    }
    pub fn setMinimumSize(self: *Backend, value: types.Size) !void {
        _ = try self.window();
        _ = try self.outerSize(value);
        const current = try self.geometry();
        if (!self.kiosk and (current.size.width < value.width or current.size.height < value.height))
            try self.setSize(.{ .width = @max(current.size.width, value.width), .height = @max(current.size.height, value.height) });
        self.minimum = value;
    }
    fn applyStyle(self: *Backend) !void {
        const hwnd = try self.window();
        const old: usize = @bitCast(getWindowLongPtr(hwnd, -16));
        // Own only POPUP/CAPTION/SYSMENU/THICKFRAME/MINIMIZEBOX/MAXIMIZEBOX.
        // Preserve show state, visibility, disabled state and embedding flags.
        const owned: usize = 0x80cf0000;
        const updated = (old & ~owned) | (@as(usize, self.style()) & owned);
        SetLastError(0);
        if (setWindowLongPtr(hwnd, -16, @bitCast(updated)) == 0 and GetLastError() != 0)
            return error.NativeOperationFailed;
        if (SetWindowPos(hwnd, null, 0, 0, 0, 0, 0x37) == 0) return error.NativeOperationFailed;
    }
    pub fn setResizable(self: *Backend, value: bool) !void {
        _ = try self.window();
        const old = self.resizable;
        self.resizable = value;
        self.applyStyle() catch |err| {
            self.resizable = old;
            return err;
        };
    }
    pub fn setFrameless(self: *Backend, value: bool) !void {
        _ = try self.window();
        const old = self.frameless;
        self.frameless = value;
        self.applyStyle() catch |err| {
            self.frameless = old;
            return err;
        };
    }
    pub fn setTransparent(self: *Backend, value: bool) !void {
        const hwnd = try self.window();
        const controller = self.controller orelse return error.NativeWindowClosed;
        var result: ?*Com = null;
        // Controller2 extends all 26 base slots; color put is slot 27, not
        // a method of ICoreWebView2 or the base controller.
        try check(controller.method(0, *const fn (*Com, *const GUID, *?*Com) callconv(.winapi) HRESULT)(controller, &iid_controller2, &result));
        const controller2 = result orelse return error.UnsupportedNativeOperation;
        defer controller2.release();
        // Match upstream's WS_EX_NOREDIRECTIONBITMAP host: WebView2's
        // composition visual supplies pixels, not an opaque GDI backing bitmap.
        // https://github.com/webui-dev/webui/blob/main/src/webui.c
        // https://learn.microsoft.com/en-us/windows/win32/winmsg/extended-window-styles
        // Unlike LWA_COLORKEY, this preserves opaque black and antialiased content.
        if (value) {
            var enabled: i32 = 0;
            try check(DwmIsCompositionEnabled(&enabled));
            if (enabled == 0) return error.UnsupportedNativeOperation;
        }
        const old: usize = @bitCast(getWindowLongPtr(hwnd, -20));
        const no_redirection: usize = 0x00200000;
        const updated = if (value) old | no_redirection else old & ~no_redirection;
        SetLastError(0);
        if (setWindowLongPtr(hwnd, -20, @bitCast(updated)) == 0 and GetLastError() != 0)
            return error.NativeOperationFailed;
        errdefer {
            _ = setWindowLongPtr(hwnd, -20, @bitCast(old));
            _ = SetWindowPos(hwnd, null, 0, 0, 0, 0, 0x37);
        }
        if (SetWindowPos(hwnd, null, 0, 0, 0, 0, 0x37) == 0) return error.NativeOperationFailed;
        try check(controller2.method(27, *const fn (*Com, Color) callconv(.winapi) HRESULT)(controller2, .{ .a = if (value) 0 else 255, .r = 255, .g = 255, .b = 255 }));
        self.transparent = value;
        _ = InvalidateRect(hwnd, null, 1);
    }
    pub fn setVisible(self: *Backend, value: bool) !void {
        const hwnd = try self.window();
        if (self.controller) |controller|
            try check(controller.method(4, *const fn (*Com, i32) callconv(.winapi) HRESULT)(controller, @intFromBool(value)));
        _ = ShowWindow(hwnd, if (value) 5 else 0);
    }
    pub fn setKiosk(self: *Backend, value: bool) !void {
        const hwnd = try self.window();
        if (self.kiosk == value) return;
        const info = try self.monitor();
        if (value) {
            if (GetWindowPlacement(hwnd, &self.placement) == 0) return error.NativeOperationFailed;
            self.kiosk = true;
            errdefer {
                self.kiosk = false;
                self.applyStyle() catch {};
            }
            try self.applyStyle();
            if (SetWindowPos(hwnd, @ptrFromInt(std.math.maxInt(usize)), info.screen.left, info.screen.top, info.screen.right - info.screen.left, info.screen.bottom - info.screen.top, 0x30) == 0)
                return error.NativeOperationFailed;
        } else {
            self.kiosk = false;
            errdefer {
                self.kiosk = true;
                self.applyStyle() catch {};
            }
            try self.applyStyle();
            if (SetWindowPos(hwnd, @ptrFromInt(std.math.maxInt(usize) - 1), 0, 0, 0, 0, 0x33) == 0)
                return error.NativeOperationFailed;
            if (SetWindowPlacement(hwnd, &self.placement) == 0) return error.NativeOperationFailed;
        }
        try self.resizeController();
    }
    pub fn minimize(self: *Backend) !void {
        _ = ShowWindow(try self.window(), 6);
    }
    pub fn maximize(self: *Backend) !void {
        _ = ShowWindow(try self.window(), 3);
    }
    pub fn restore(self: *Backend) !void {
        if (self.kiosk) try self.setKiosk(false);
        _ = ShowWindow(try self.window(), 9);
    }
    pub fn focus(self: *Backend) !void {
        const hwnd = try self.window();
        if (SetForegroundWindow(hwnd) == 0) return error.NativeFocusDenied;
        _ = SetFocus(hwnd);
        if (self.controller) |controller|
            try check(controller.method(12, *const fn (*Com, i32) callconv(.winapi) HRESULT)(controller, 0));
    }
    pub fn geometry(self: *Backend) !types.Geometry {
        const hwnd = try self.window();
        var outer: RECT = .{};
        var client: RECT = .{};
        if (GetWindowRect(hwnd, &outer) == 0 or GetClientRect(hwnd, &client) == 0) return error.NativeOperationFailed;
        return .{ .position = .{ .x = outer.left, .y = outer.top }, .size = .{ .width = @intCast(client.right - client.left), .height = @intCast(client.bottom - client.top) } };
    }
    pub fn handle(self: *Backend) !types.Handle {
        return .{ .win32 = try self.window() };
    }
    pub fn setCloseHandler(self: *Backend, handler: ?types.CloseHandler, user_data: ?*anyopaque) void {
        self.close_handler = handler;
        self.user_data = user_data;
    }
};

fn windowProc(hwnd: HWND, message: u32, wparam: usize, lparam: isize) callconv(.winapi) isize {
    if (message == 0x81) { // WM_NCCREATE
        const creation: *const CREATESTRUCTW = @ptrFromInt(@as(usize, @bitCast(lparam)));
        const owner: *Backend = @ptrCast(@alignCast(creation.param.?));
        owner.hwnd = hwnd;
        SetLastError(0);
        if (setWindowLongPtr(hwnd, -21, @bitCast(@intFromPtr(owner))) == 0 and GetLastError() != 0) return 0;
        return 1;
    }
    const address = getWindowLongPtr(hwnd, -21);
    if (address != 0) {
        const self: *Backend = @ptrFromInt(@as(usize, @bitCast(address)));
        switch (message) {
            0x14 => { // WM_ERASEBKGND: transparent host has no GDI surface.
                if (self.transparent) return 1;
                var rect: RECT = .{};
                if (GetClientRect(hwnd, &rect) == 0) return 0;
                return @intFromBool(FillRect(@ptrFromInt(wparam), &rect, @ptrFromInt(6)) != 0);
            },
            0x31e => if (self.transparent) { // WM_DWMCOMPOSITIONCHANGED
                var enabled: i32 = 0;
                check(DwmIsCompositionEnabled(&enabled)) catch |err| {
                    self.event_error = err;
                    return 0;
                };
                if (enabled == 0) self.event_error = error.UnsupportedNativeOperation;
            },
            0x10 => {
                self.close_requested = true;
                return 0;
            }, // WM_CLOSE: defer outside callback stack
            0x82 => { // WM_NCDESTROY, including externally destroyed borrowed HWND
                _ = setWindowLongPtr(hwnd, -21, 0);
                self.hwnd = null;
                self.closed = true;
            },
            0x05 => self.resizeController() catch |err| {
                self.event_error = err;
            },
            0x03 => if (self.controller) |controller| {
                check(controller.method(23, *const fn (*Com) callconv(.winapi) HRESULT)(controller)) catch |err| {
                    self.event_error = err;
                };
            },
            0x24 => if (self.minimum) |minimum| { // WM_GETMINMAXINFO, outer track size
                if (!self.kiosk) {
                    const size = self.outerSize(minimum) catch |err| {
                        self.event_error = err;
                        return 0;
                    };
                    const info: *MINMAXINFO = @ptrFromInt(@as(usize, @bitCast(lparam)));
                    info.min_track = size;
                    return 0;
                }
            },
            else => {},
        }
    }
    return DefWindowProcW(hwnd, message, wparam, lparam);
}

const WNDCLASSEXW = extern struct {
    size: u32 = @sizeOf(WNDCLASSEXW),
    style: u32 = 0,
    wnd_proc: *const fn (HWND, u32, usize, isize) callconv(.winapi) isize,
    class_extra: i32 = 0,
    window_extra: i32 = 0,
    instance: ?*anyopaque,
    icon: ?*anyopaque = null,
    cursor: ?*anyopaque,
    background: ?*anyopaque,
    menu_name: ?[*:0]const u16 = null,
    class_name: [*:0]const u16,
    small_icon: ?*anyopaque = null,
};
const CREATESTRUCTW = extern struct {
    param: ?*anyopaque,
    instance: ?*anyopaque,
    menu: ?*anyopaque,
    parent: ?HWND,
    cy: i32,
    cx: i32,
    y: i32,
    x: i32,
    style: i32,
    name: ?[*:0]const u16,
    class_name: ?[*:0]const u16,
    ex_style: u32,
};
const MSG = extern struct { hwnd: ?HWND, message: u32, wparam: usize, lparam: isize, time: u32, point: POINT };
const MINMAXINFO = extern struct { reserved: POINT, max_size: POINT, max_position: POINT, min_track: POINT, max_track: POINT };
const MONITORINFO = extern struct { size: u32 = @sizeOf(MONITORINFO), screen: RECT = .{}, work: RECT = .{}, flags: u32 = 0 };
const WINDOWPLACEMENT = extern struct {
    length: u32 = @sizeOf(WINDOWPLACEMENT),
    flags: u32 = 0,
    show: u32 = 0,
    min: POINT = .{},
    max: POINT = .{},
    normal: RECT = .{},
};
fn getWindowLongPtr(hwnd: HWND, index: i32) isize {
    return if (@sizeOf(usize) == 8) GetWindowLongPtrW(hwnd, index) else GetWindowLongW(hwnd, index);
}
fn setWindowLongPtr(hwnd: HWND, index: i32, value: isize) isize {
    return if (@sizeOf(usize) == 8) SetWindowLongPtrW(hwnd, index, value) else SetWindowLongW(hwnd, index, @intCast(value));
}
extern "ole32" fn CoInitializeEx(?*anyopaque, u32) callconv(.winapi) HRESULT;
extern "ole32" fn CoUninitialize() callconv(.winapi) void;
extern "ole32" fn CoTaskMemFree(?*anyopaque) callconv(.winapi) void;
extern "dwmapi" fn DwmIsCompositionEnabled(*i32) callconv(.winapi) HRESULT;
extern "kernel32" fn LoadLibraryW([*:0]const u16) callconv(.winapi) ?*anyopaque;
extern "kernel32" fn FreeLibrary(*anyopaque) callconv(.winapi) i32;
extern "kernel32" fn GetProcAddress(*anyopaque, [*:0]const u8) callconv(.winapi) ?*const anyopaque;
extern "kernel32" fn GetModuleHandleW(?[*:0]const u16) callconv(.winapi) ?*anyopaque;
extern "kernel32" fn GetLastError() callconv(.winapi) u32;
extern "kernel32" fn SetLastError(u32) callconv(.winapi) void;
extern "user32" fn RegisterClassExW(*const WNDCLASSEXW) callconv(.winapi) u16;
extern "user32" fn UnregisterClassW([*:0]const u16, ?*anyopaque) callconv(.winapi) i32;
extern "user32" fn LoadCursorW(?*anyopaque, [*:0]const u16) callconv(.winapi) ?*anyopaque;
extern "user32" fn CreateWindowExW(u32, [*:0]const u16, [*:0]const u16, u32, i32, i32, i32, i32, ?HWND, ?*anyopaque, ?*anyopaque, ?*anyopaque) callconv(.winapi) ?HWND;
extern "user32" fn DestroyWindow(HWND) callconv(.winapi) i32;
extern "user32" fn DefWindowProcW(HWND, u32, usize, isize) callconv(.winapi) isize;
extern "user32" fn GetWindowLongPtrW(HWND, i32) callconv(.winapi) isize;
extern "user32" fn SetWindowLongPtrW(HWND, i32, isize) callconv(.winapi) isize;
extern "user32" fn GetWindowLongW(HWND, i32) callconv(.winapi) i32;
extern "user32" fn SetWindowLongW(HWND, i32, i32) callconv(.winapi) i32;
extern "user32" fn PeekMessageW(*MSG, ?HWND, u32, u32, u32) callconv(.winapi) i32;
extern "user32" fn TranslateMessage(*const MSG) callconv(.winapi) i32;
extern "user32" fn DispatchMessageW(*const MSG) callconv(.winapi) isize;
extern "user32" fn AdjustWindowRectEx(*RECT, u32, i32, u32) callconv(.winapi) i32;
extern "user32" fn GetClientRect(HWND, *RECT) callconv(.winapi) i32;
extern "user32" fn GetWindowRect(HWND, *RECT) callconv(.winapi) i32;
extern "user32" fn SetWindowPos(HWND, ?HWND, i32, i32, i32, i32, u32) callconv(.winapi) i32;
extern "user32" fn SetWindowTextW(HWND, [*:0]const u16) callconv(.winapi) i32;
extern "user32" fn ShowWindow(HWND, i32) callconv(.winapi) i32;
extern "user32" fn MonitorFromWindow(HWND, u32) callconv(.winapi) ?*anyopaque;
extern "user32" fn GetMonitorInfoW(*anyopaque, *MONITORINFO) callconv(.winapi) i32;
extern "user32" fn GetWindowPlacement(HWND, *WINDOWPLACEMENT) callconv(.winapi) i32;
extern "user32" fn SetWindowPlacement(HWND, *const WINDOWPLACEMENT) callconv(.winapi) i32;
extern "user32" fn SetForegroundWindow(HWND) callconv(.winapi) i32;
extern "user32" fn SetFocus(HWND) callconv(.winapi) ?HWND;
extern "user32" fn InvalidateRect(HWND, ?*const RECT, i32) callconv(.winapi) i32;
extern "user32" fn FillRect(*anyopaque, *const RECT, *anyopaque) callconv(.winapi) i32;
