//! AppKit/WKWebView backend. Every entry point and delegate runs on the main
//! thread; the public wrapper enforces that rule (create also checks it).
//!
//! ABI references: the installed macOS SDK's objc/{message,runtime,objc}.h,
//! AppKit/{NSWindow,NSApplication,NSScreen,NSView}.h and WebKit/WK*.h.
//! CGFloat is double on both supported 64-bit targets. x86_64 NSRect returns
//! use objc_msgSend_stret; ARM64 uses ordinary typed objc_msgSend, including
//! its homogeneous floating-point aggregate return convention.
const std = @import("std");
const builtin = @import("builtin");
const types = @import("types.zig");

const Id = ?*anyopaque;
const Sel = *opaque {};
const ObjcBool = if (builtin.cpu.arch == .aarch64) bool else i8;
const Point = extern struct { x: f64, y: f64 };
const Size = extern struct { width: f64, height: f64 };
const Rect = extern struct { origin: Point, size: Size };
const Imp = *const fn () callconv(.c) void;

extern "objc" fn objc_getClass(name: [*:0]const u8) Id;
extern "objc" fn sel_registerName(name: [*:0]const u8) Sel;
extern "objc" fn objc_allocateClassPair(superclass: Id, name: [*:0]const u8, extra: usize) Id;
extern "objc" fn objc_registerClassPair(class: Id) void;
extern "objc" fn objc_disposeClassPair(class: Id) void;
extern "objc" fn class_addIvar(class: Id, name: [*:0]const u8, size: usize, alignment: u8, encoding: [*:0]const u8) ObjcBool;
extern "objc" fn class_addMethod(class: Id, selector: Sel, implementation: Imp, encoding: [*:0]const u8) ObjcBool;
extern "objc" fn object_setInstanceVariable(object: Id, name: [*:0]const u8, value: Id) Id;
extern "objc" fn object_getInstanceVariable(object: Id, name: [*:0]const u8, value: *Id) Id;
extern "objc" fn objc_msgSend() void;
extern "objc" fn objc_msgSend_stret() void;
extern "c" fn pthread_main_np() c_int;
extern var NSDefaultRunLoopMode: Id;

fn yes(value: bool) ObjcBool {
    return if (ObjcBool == bool) value else @intFromBool(value);
}
fn truth(value: ObjcBool) bool {
    return if (ObjcBool == bool) value else value != 0;
}
fn send0(comptime R: type, object: Id, name: [*:0]const u8) R {
    const function: *const fn (Id, Sel) callconv(.c) R = @ptrCast(&objc_msgSend);
    return function(object, sel_registerName(name));
}
fn send1(comptime R: type, object: Id, name: [*:0]const u8, comptime A: type, a: A) R {
    const function: *const fn (Id, Sel, A) callconv(.c) R = @ptrCast(&objc_msgSend);
    return function(object, sel_registerName(name), a);
}
fn send2(comptime R: type, object: Id, name: [*:0]const u8, comptime A: type, a: A, comptime B: type, b: B) R {
    const function: *const fn (Id, Sel, A, B) callconv(.c) R = @ptrCast(&objc_msgSend);
    return function(object, sel_registerName(name), a, b);
}
fn send3(comptime R: type, object: Id, name: [*:0]const u8, comptime A: type, a: A, comptime B: type, b: B, comptime C: type, c: C) R {
    const function: *const fn (Id, Sel, A, B, C) callconv(.c) R = @ptrCast(&objc_msgSend);
    return function(object, sel_registerName(name), a, b, c);
}
fn send4(comptime R: type, object: Id, name: [*:0]const u8, comptime A: type, a: A, comptime B: type, b: B, comptime C: type, c: C, comptime D: type, d: D) R {
    const function: *const fn (Id, Sel, A, B, C, D) callconv(.c) R = @ptrCast(&objc_msgSend);
    return function(object, sel_registerName(name), a, b, c, d);
}
fn rect0(object: Id, name: [*:0]const u8) Rect {
    if (builtin.cpu.arch == .x86_64) {
        var result: Rect = undefined;
        const function: *const fn (*Rect, Id, Sel) callconv(.c) void = @ptrCast(&objc_msgSend_stret);
        function(&result, object, sel_registerName(name));
        return result;
    }
    return send0(Rect, object, name);
}
fn rect1(object: Id, name: [*:0]const u8, argument: Rect) Rect {
    if (builtin.cpu.arch == .x86_64) {
        var result: Rect = undefined;
        const function: *const fn (*Rect, Id, Sel, Rect) callconv(.c) void = @ptrCast(&objc_msgSend_stret);
        function(&result, object, sel_registerName(name), argument);
        return result;
    }
    return send1(Rect, object, name, Rect, argument);
}
fn release(object: Id) void {
    send0(void, object, "release");
}
fn pool() Id {
    return send0(Id, send0(Id, objc_getClass("NSAutoreleasePool"), "alloc"), "init");
}
fn drain(object: Id) void {
    send0(void, object, "drain");
}
fn string(value: []const u8) !*anyopaque {
    // init copies the bytes. The caller owns this +1 NSString.
    return send3(Id, send0(Id, objc_getClass("NSString"), "alloc"), "initWithBytes:length:encoding:", [*]const u8, value.ptr, usize, value.len, usize, 4) orelse error.InvalidNativeText;
}
fn nativeSize(value: types.Size) Size {
    return .{ .width = @floatFromInt(value.width), .height = @floatFromInt(value.height) };
}

// Registered classes intentionally live for the process lifetime, like normal
// Objective-C classes. Registration is serialized by the main-thread rule.
// No per-instance state is stored on a class or on the NSApplication singleton.
var delegate_class: Id = null;
var window_class: Id = null;
var application_launched = false;
const context_ivar = "pureZigWebUIContext";
const close_message_name = "pureZigWebUIClose";
const close_message_body = "close";
const close_script =
    \\(() => {
    \\    const handler = window.webkit.messageHandlers.pureZigWebUIClose;
    \\    const post = handler.postMessage.bind(handler);
    \\    Object.defineProperty(window, "close", {
    \\        value: () => post("close"),
    \\        writable: false,
    \\        configurable: false
    \\    });
    \\    Object.defineProperty(window, "__zigWebuiNativeClose", { value: window.close });
    \\})();
;
// AppKit's run loop services every window. Keep accepted script requests on
// their owning window, then drain all of them after the native callbacks return.
var live_windows: ?*Backend = null;

fn registerClasses() !void {
    if (delegate_class == null) {
        const parent = objc_getClass("NSObject") orelse return error.NativeRuntimeNotFound;
        const class = objc_allocateClassPair(parent, "PureZigWebUIDelegate_1", 0) orelse return error.NativeInitializationFailed;
        errdefer objc_disposeClassPair(class);
        if (!truth(class_addIvar(class, context_ivar, @sizeOf(*Backend), @intCast(@ctz(@as(usize, @alignOf(*Backend)))), "^v")) or
            !truth(class_addMethod(class, sel_registerName("windowShouldClose:"), @ptrCast(&windowShouldClose), if (ObjcBool == bool) "B@:@" else "c@:@")) or
            !truth(class_addMethod(class, sel_registerName("windowWillClose:"), @ptrCast(&windowWillClose), "v@:@")) or
            !truth(class_addMethod(class, sel_registerName("webViewDidClose:"), @ptrCast(&webViewDidClose), "v@:@")) or
            !truth(class_addMethod(class, sel_registerName("userContentController:didReceiveScriptMessage:"), @ptrCast(&didReceiveScriptMessage), "v@:@@")))
            return error.NativeInitializationFailed;
        objc_registerClassPair(class);
        delegate_class = class;
    }
    if (window_class == null) {
        const parent = objc_getClass("NSWindow") orelse return error.NativeRuntimeNotFound;
        const class = objc_allocateClassPair(parent, "PureZigWebUIWindow_1", 0) orelse return error.NativeInitializationFailed;
        errdefer objc_disposeClassPair(class);
        // Borderless NSWindow otherwise refuses keyboard focus.
        if (!truth(class_addMethod(class, sel_registerName("canBecomeKeyWindow"), @ptrCast(&canBecomeKeyWindow), if (ObjcBool == bool) "B@:" else "c@:")) or
            !truth(class_addMethod(class, sel_registerName("canBecomeMainWindow"), @ptrCast(&canBecomeKeyWindow), if (ObjcBool == bool) "B@:" else "c@:")))
            return error.NativeInitializationFailed;
        objc_registerClassPair(class);
        window_class = class;
    }
}
fn context(delegate: Id) ?*Backend {
    var pointer: Id = null;
    _ = object_getInstanceVariable(delegate, context_ivar, &pointer);
    return if (pointer) |value| @ptrCast(@alignCast(value)) else null;
}
fn canBecomeKeyWindow(_: Id, _: Sel) callconv(.c) ObjcBool {
    return yes(true);
}
fn windowShouldClose(delegate: Id, _: Sel, _: Id) callconv(.c) ObjcBool {
    const self = context(delegate) orelse return yes(true);
    return yes(self.allowUserClose());
}
fn windowWillClose(delegate: Id, _: Sel, _: Id) callconv(.c) void {
    if (context(delegate)) |self| {
        self.closed = true;
        self.pending_close = false;
    }
}
fn webViewDidClose(delegate: Id, _: Sel, webview: Id) callconv(.c) void {
    const self = context(delegate) orelse return;
    if (self.closed or webview != self.webview) return;
    // This is completion, not a veto point: WebKit has already closed the page.
    // The document-start override below handles ordinary JS close requests.
    self.pending_close = true;
}
fn didReceiveScriptMessage(delegate: Id, _: Sel, controller: Id, message: Id) callconv(.c) void {
    const self = context(delegate) orelse return;
    if (self.closed or self.pending_close or controller != self.content_controller or
        send0(Id, message, "webView") != self.webview) return;
    const frame = send0(Id, message, "frameInfo") orelse return;
    if (!truth(send0(ObjcBool, frame, "isMainFrame"))) return;
    const name = send0(Id, message, "name") orelse return;
    if (send0(usize, name, "length") != close_message_name.len or
        !truth(send1(ObjcBool, name, "isEqualToString:", Id, self.message_name))) return;
    const body = send0(Id, message, "body") orelse return;
    // Do not stringify or copy arbitrary JS data. Only the fixed scalar request
    // is accepted, with a length check before bounded NSString comparison.
    if (!truth(send1(ObjcBool, body, "isKindOfClass:", Id, objc_getClass("NSString"))) or
        send0(usize, body, "length") != close_message_body.len or
        !truth(send1(ObjcBool, body, "isEqualToString:", Id, self.message_body))) return;
    if (self.allowUserClose()) self.pending_close = true;
    // No native teardown while WebKit is invoking this delegate. The wrapper's
    // per-State callback-depth guard also rejects deinit from the user handler.
}

pub const Backend = struct {
    gpa: std.mem.Allocator,
    // +1 ownership: window, webview, delegate, content controller and message
    // strings. The controller retains the script delegate until explicit removal.
    // NSWindow retains its content view; both UI delegates are non-owning.
    // NSApplication is a borrowed process singleton and is never terminated.
    app: Id,
    window: Id = null,
    webview: Id = null,
    delegate: Id = null,
    content_controller: Id = null,
    message_name: Id = null,
    message_body: Id = null,
    previous: ?*Backend = null,
    next: ?*Backend = null,
    pending_close: bool = false,
    closed: bool = false,
    in_close_handler: bool = false,
    close_handler: ?types.CloseHandler,
    user_data: ?*anyopaque,
    resizable: bool,
    frameless: bool,
    kiosk: bool = false,
    kiosk_frame: Rect = undefined,
    kiosk_level: isize = 0,
    minimum_size: types.Size = .{ .width = 1, .height = 1 },

    pub fn create(gpa: std.mem.Allocator, io: std.Io, url: [:0]const u8, options: types.Options) !*Backend {
        _ = io; // No asynchronous initialization or waiting: loadRequest starts navigation.
        if (pthread_main_np() == 0) return error.NativeMainThreadRequired;
        if (options.profile_directory != null) return error.UnsupportedNativeProfile;
        if (options.webview2_loader != null) return error.UnsupportedNativeLoader;
        // WKWebView has no public macOS drawsBackground/opaque setter. Its
        // underPageBackgroundColor changes overscroll, not page compositing.
        if (options.transparent) return error.UnsupportedNativeControl;
        const autorelease_pool = pool();
        defer drain(autorelease_pool);
        if (objc_getClass("WKWebView") == null or objc_getClass("NSApplication") == null)
            return error.NativeRuntimeNotFound;
        const app = send0(Id, objc_getClass("NSApplication"), "sharedApplication") orelse return error.NativeInitializationFailed;
        if (send0(Id, objc_getClass("NSScreen"), "mainScreen") == null)
            return error.NativeDisplayUnavailable;
        try registerClasses();
        if (!application_launched) {
            if (!truth(send1(ObjcBool, app, "setActivationPolicy:", isize, 0)))
                return error.NativeInitializationFailed;
            send0(void, app, "finishLaunching");
            application_launched = true;
        }
        const self = try gpa.create(Backend);
        self.* = .{
            .gpa = gpa,
            .app = app,
            .close_handler = options.close_handler,
            .user_data = options.user_data,
            .resizable = options.resizable,
            .frameless = options.frameless,
        };
        errdefer self.destroy();
        self.delegate = send0(Id, send0(Id, delegate_class, "alloc"), "init") orelse return error.NativeInitializationFailed;
        if (object_setInstanceVariable(self.delegate, context_ivar, self) == null)
            return error.NativeInitializationFailed;
        const frame: Rect = .{ .origin = .{ .x = 0, .y = 0 }, .size = nativeSize(options.size) };
        self.window = send4(Id, send0(Id, window_class, "alloc"), "initWithContentRect:styleMask:backing:defer:", Rect, frame, usize, self.style(), usize, 2, ObjcBool, yes(false)) orelse return error.NativeInitializationFailed;
        // A close removes this window, but must not release our owning ref.
        send1(void, self.window, "setReleasedWhenClosed:", ObjcBool, yes(false));
        send1(void, self.window, "setDelegate:", Id, self.delegate);
        // Suppress AppKit automatic tab grouping across independent WebUI windows.
        if (truth(send1(ObjcBool, self.window, "respondsToSelector:", Sel, sel_registerName("setTabbingMode:"))))
            send1(void, self.window, "setTabbingMode:", isize, 2);
        const configuration = send0(Id, send0(Id, objc_getClass("WKWebViewConfiguration"), "alloc"), "init") orelse return error.NativeInitializationFailed;
        defer release(configuration);
        const preferences = send0(Id, configuration, "preferences") orelse return error.NativeInitializationFailed;
        send1(void, preferences, "setJavaScriptEnabled:", ObjcBool, yes(true));
        send1(void, preferences, "setJavaScriptCanOpenWindowsAutomatically:", ObjcBool, yes(true));
        self.content_controller = send0(Id, send0(Id, objc_getClass("WKUserContentController"), "alloc"), "init") orelse return error.NativeInitializationFailed;
        self.message_name = try string(close_message_name);
        self.message_body = try string(close_message_body);
        send2(void, self.content_controller, "addScriptMessageHandler:name:", Id, self.delegate, Id, self.message_name);
        const source = try string(close_script);
        defer release(source);
        // AtDocumentStart = 0; the page-world replacement runs on every main
        // frame navigation, before page JS can capture WebKit's history-gated
        // close implementation. A veto never invokes that implementation.
        const script = send3(Id, send0(Id, objc_getClass("WKUserScript"), "alloc"), "initWithSource:injectionTime:forMainFrameOnly:", Id, source, isize, 0, ObjcBool, yes(true)) orelse return error.NativeInitializationFailed;
        defer release(script);
        send1(void, self.content_controller, "addUserScript:", Id, script);
        send1(void, configuration, "setUserContentController:", Id, self.content_controller);
        self.webview = send2(Id, send0(Id, objc_getClass("WKWebView"), "alloc"), "initWithFrame:configuration:", Rect, frame, Id, configuration) orelse return error.NativeInitializationFailed;
        send1(void, self.webview, "setUIDelegate:", Id, self.delegate);
        send1(void, self.webview, "setAutoresizingMask:", usize, 2 | 16);
        send1(void, self.window, "setContentView:", Id, self.webview);
        const title = try string(options.title);
        defer release(title);
        send1(void, self.window, "setTitle:", Id, title);
        if (options.minimum_size) |minimum| try self.setMinimumSize(minimum);
        if (options.position) |position| try self.setPosition(position);
        if (options.center) try self.center();
        if (options.kiosk) try self.setKiosk(true);
        try self.navigate(url);
        if (!options.hidden) try self.setVisible(true);
        self.next = live_windows;
        if (live_windows) |first| first.previous = self;
        live_windows = self;
        return self;
    }

    pub fn destroy(self: *Backend) void {
        const autorelease_pool = pool();
        defer drain(autorelease_pool);
        if (self.previous) |previous| {
            previous.next = self.next;
        } else if (live_windows == self) {
            live_windows = self.next;
        }
        if (self.next) |next| next.previous = self.previous;
        // Invalidate first: queued WebKit messages may still retain the delegate,
        // but can no longer reach Backend. Remove the handler's strong delegate
        // reference before releasing the controller/webview and our owning refs.
        if (self.delegate != null)
            _ = object_setInstanceVariable(self.delegate, context_ivar, null);
        if (self.message_name != null)
            send1(void, self.content_controller, "removeScriptMessageHandlerForName:", Id, self.message_name);
        send0(void, self.content_controller, "removeAllUserScripts");
        send1(void, self.window, "setDelegate:", Id, null);
        send1(void, self.webview, "setUIDelegate:", Id, null);
        send0(void, self.webview, "stopLoading");
        if (self.window != null and !self.closed) send0(void, self.window, "close");
        send1(void, self.window, "setContentView:", Id, null);
        release(self.webview);
        release(self.content_controller);
        release(self.message_body);
        release(self.message_name);
        release(self.window);
        release(self.delegate);
        self.gpa.destroy(self);
    }

    pub fn pump(self: *Backend) !bool {
        const autorelease_pool = pool();
        defer drain(autorelease_pool);
        const deadline = send0(Id, objc_getClass("NSDate"), "distantPast");
        // Process timers, WebKit IPC and dispatch sources even without NSEvents.
        const loop = send0(Id, objc_getClass("NSRunLoop"), "currentRunLoop");
        _ = send2(ObjcBool, loop, "runMode:beforeDate:", Id, NSDefaultRunLoopMode, Id, deadline);
        // Bounded drain prevents a busy mouse/event producer starving std.Io.
        // sendEvent serves all AppKit windows, never just this instance.
        for (0..256) |_| {
            const event = send4(Id, self.app, "nextEventMatchingMask:untilDate:inMode:dequeue:", usize, std.math.maxInt(usize), Id, deadline, Id, NSDefaultRunLoopMode, ObjcBool, yes(true)) orelse break;
            send1(void, self.app, "sendEvent:", Id, event);
        }
        send0(void, self.app, "updateWindows");
        var current = live_windows;
        while (current) |window| : (current = window.next) {
            if (window.pending_close and !window.in_close_handler)
                try window.close();
        }
        return !self.closed;
    }

    fn requireOpen(self: *Backend) !void {
        if (self.closed) return error.NativeWindowClosed;
    }
    fn allowUserClose(self: *Backend) bool {
        if (self.closed or self.pending_close or self.in_close_handler) return false;
        self.in_close_handler = true;
        defer self.in_close_handler = false;
        const allowed = if (self.close_handler) |handler| handler(self.user_data) else true;
        return allowed and !self.closed;
    }
    fn style(self: *Backend) usize {
        if (self.kiosk) return 0;
        return (if (self.frameless) @as(usize, 0) else @as(usize, 1 | 2 | 4)) | (if (self.resizable) @as(usize, 8) else @as(usize, 0));
    }
    fn updateStyle(self: *Backend) void {
        // Style changes may replace the frame view. Preserve content dimensions
        // and outer origin, and reassert our webview as content after the change.
        const frame = rect0(self.window, "frame");
        const content = rect1(self.window, "contentRectForFrameRect:", frame);
        send1(void, self.window, "setStyleMask:", usize, self.style());
        send1(void, self.window, "setContentView:", Id, self.webview);
        send1(void, self.window, "setContentSize:", Size, content.size);
        send1(void, self.window, "setFrameOrigin:", Point, frame.origin);
    }

    pub fn close(self: *Backend) !void {
        if (self.closed) return;
        const autorelease_pool = pool();
        defer drain(autorelease_pool);
        // -close deliberately bypasses -windowShouldClose: unlike performClose:.
        send0(void, self.window, "close");
        self.closed = true;
        self.pending_close = false;
    }
    pub fn setTitle(self: *Backend, title: [:0]const u8) !void {
        try self.requireOpen();
        const autorelease_pool = pool();
        defer drain(autorelease_pool);
        const text = try string(title);
        defer release(text);
        send1(void, self.window, "setTitle:", Id, text);
    }
    pub fn navigate(self: *Backend, url: [:0]const u8) !void {
        try self.requireOpen();
        const autorelease_pool = pool();
        defer drain(autorelease_pool);
        const text = try string(url);
        defer release(text);
        const address = send1(Id, objc_getClass("NSURL"), "URLWithString:", Id, text) orelse return error.InvalidNativeUrl;
        const request = send1(Id, objc_getClass("NSURLRequest"), "requestWithURL:", Id, address) orelse return error.InvalidNativeUrl;
        _ = send1(Id, self.webview, "loadRequest:", Id, request) orelse return error.NativeNavigationFailed;
    }
    pub fn setSize(self: *Backend, value: types.Size) !void {
        try self.requireOpen();
        if (self.kiosk) return error.UnsupportedNativeControl;
        if (value.width < self.minimum_size.width or value.height < self.minimum_size.height)
            return error.InvalidMinimumSize;
        const autorelease_pool = pool();
        defer drain(autorelease_pool);
        send1(void, self.window, "setContentSize:", Size, nativeSize(value));
    }
    pub fn setPosition(self: *Backend, value: types.Position) !void {
        try self.requireOpen();
        if (self.kiosk) return error.UnsupportedNativeControl;
        const autorelease_pool = pool();
        defer drain(autorelease_pool);
        // Native Cocoa logical coordinates: lower-left outer frame origin.
        // Signed positions allow displays left of/below the primary screen.
        send1(void, self.window, "setFrameOrigin:", Point, .{ .x = @floatFromInt(value.x), .y = @floatFromInt(value.y) });
    }
    pub fn center(self: *Backend) !void {
        try self.requireOpen();
        if (self.kiosk) return error.UnsupportedNativeControl;
        const autorelease_pool = pool();
        defer drain(autorelease_pool);
        const screen = send0(Id, self.window, "screen") orelse send0(Id, objc_getClass("NSScreen"), "mainScreen") orelse return error.NativeDisplayUnavailable;
        const visible = rect0(screen, "visibleFrame");
        const frame = rect0(self.window, "frame");
        send1(void, self.window, "setFrameOrigin:", Point, .{
            .x = visible.origin.x + (visible.size.width - frame.size.width) / 2,
            .y = visible.origin.y + (visible.size.height - frame.size.height) / 2,
        });
    }
    pub fn setMinimumSize(self: *Backend, value: types.Size) !void {
        try self.requireOpen();
        if (self.kiosk) return error.UnsupportedNativeControl;
        const autorelease_pool = pool();
        defer drain(autorelease_pool);
        self.minimum_size = value;
        send1(void, self.window, "setContentMinSize:", Size, nativeSize(value));
        const current = rect1(self.window, "contentRectForFrameRect:", rect0(self.window, "frame"));
        const minimum = nativeSize(value);
        if (current.size.width < minimum.width or current.size.height < minimum.height)
            send1(void, self.window, "setContentSize:", Size, .{ .width = @max(current.size.width, minimum.width), .height = @max(current.size.height, minimum.height) });
    }
    pub fn setResizable(self: *Backend, value: bool) !void {
        try self.requireOpen();
        if (self.kiosk) return error.UnsupportedNativeControl;
        const autorelease_pool = pool();
        defer drain(autorelease_pool);
        self.resizable = value;
        self.updateStyle();
    }
    pub fn setFrameless(self: *Backend, value: bool) !void {
        try self.requireOpen();
        if (self.kiosk) return error.UnsupportedNativeControl;
        const autorelease_pool = pool();
        defer drain(autorelease_pool);
        self.frameless = value;
        self.updateStyle();
    }
    pub fn setTransparent(self: *Backend, value: bool) !void {
        try self.requireOpen();
        if (value) return error.UnsupportedNativeControl;
        // Opaque is the only supported WKWebView compositing mode.
    }
    pub fn setVisible(self: *Backend, value: bool) !void {
        try self.requireOpen();
        const autorelease_pool = pool();
        defer drain(autorelease_pool);
        if (value) {
            send1(void, self.window, "makeKeyAndOrderFront:", Id, null);
            send1(void, self.app, "activateIgnoringOtherApps:", ObjcBool, yes(true));
        } else {
            send1(void, self.window, "orderOut:", Id, null);
        }
    }
    pub fn setKiosk(self: *Backend, value: bool) !void {
        try self.requireOpen();
        if (self.kiosk == value) return;
        const autorelease_pool = pool();
        defer drain(autorelease_pool);
        if (value) {
            const screen = send0(Id, self.window, "screen") orelse send0(Id, objc_getClass("NSScreen"), "mainScreen") orelse return error.NativeDisplayUnavailable;
            const full_frame = rect0(screen, "frame");
            self.kiosk_frame = rect0(self.window, "frame");
            self.kiosk_level = send0(isize, self.window, "level");
            self.kiosk = true;
            send1(void, self.window, "setStyleMask:", usize, self.style());
            // NSMainMenuWindowLevel + 1, from NSWindow.h/CGWindowLevel.h.
            // Per-window presentation: no app-wide menu/Dock changes or quit.
            send1(void, self.window, "setLevel:", isize, 25);
            send2(void, self.window, "setFrame:display:", Rect, full_frame, ObjcBool, yes(true));
        } else {
            self.kiosk = false;
            send1(void, self.window, "setLevel:", isize, self.kiosk_level);
            send1(void, self.window, "setStyleMask:", usize, self.style());
            send2(void, self.window, "setFrame:display:", Rect, self.kiosk_frame, ObjcBool, yes(true));
        }
    }
    pub fn minimize(self: *Backend) !void {
        try self.requireOpen();
        if (self.kiosk) return error.UnsupportedNativeControl;
        const autorelease_pool = pool();
        defer drain(autorelease_pool);
        send1(void, self.window, "miniaturize:", Id, null);
    }
    pub fn maximize(self: *Backend) !void {
        try self.requireOpen();
        if (self.kiosk) return;
        if (!self.resizable) return error.UnsupportedNativeControl;
        const autorelease_pool = pool();
        defer drain(autorelease_pool);
        if (truth(send0(ObjcBool, self.window, "isMiniaturized")))
            send1(void, self.window, "deminiaturize:", Id, null);
        if (!truth(send0(ObjcBool, self.window, "isZoomed")))
            send1(void, self.window, "zoom:", Id, null);
    }
    pub fn restore(self: *Backend) !void {
        try self.requireOpen();
        const autorelease_pool = pool();
        defer drain(autorelease_pool);
        if (self.kiosk) try self.setKiosk(false);
        if (truth(send0(ObjcBool, self.window, "isMiniaturized")))
            send1(void, self.window, "deminiaturize:", Id, null);
        if (truth(send0(ObjcBool, self.window, "isZoomed")))
            send1(void, self.window, "zoom:", Id, null);
    }
    pub fn focus(self: *Backend) !void {
        try self.requireOpen();
        const autorelease_pool = pool();
        defer drain(autorelease_pool);
        if (truth(send0(ObjcBool, self.window, "isMiniaturized")))
            send1(void, self.window, "deminiaturize:", Id, null);
        send1(void, self.window, "makeKeyAndOrderFront:", Id, null);
        _ = send1(ObjcBool, self.window, "makeFirstResponder:", Id, self.webview);
        send1(void, self.app, "activateIgnoringOtherApps:", ObjcBool, yes(true));
    }
    pub fn geometry(self: *Backend) !types.Geometry {
        try self.requireOpen();
        const autorelease_pool = pool();
        defer drain(autorelease_pool);
        const frame = rect0(self.window, "frame");
        const content = rect1(self.window, "contentRectForFrameRect:", frame);
        // User moves/resizes and display scaling can produce fractional values.
        // Reject native values outside the public representation, never trap.
        return .{
            .position = .{ .x = try coordinate(frame.origin.x), .y = try coordinate(frame.origin.y) },
            .size = .{ .width = try dimension(content.size.width), .height = try dimension(content.size.height) },
        };
    }
    pub fn handle(self: *Backend) !types.Handle {
        try self.requireOpen();
        return .{ .cocoa = self.window.? };
    }
    pub fn setCloseHandler(self: *Backend, handler: ?types.CloseHandler, user_data: ?*anyopaque) void {
        self.close_handler = handler;
        self.user_data = user_data;
    }
};

fn coordinate(value: f64) !i32 {
    const rounded = @round(value);
    if (!std.math.isFinite(rounded) or rounded < -2147483648.0 or rounded > 2147483647.0)
        return error.NativeGeometryOutOfRange;
    return @intFromFloat(rounded);
}
fn dimension(value: f64) !u32 {
    const rounded = @round(value);
    if (!std.math.isFinite(rounded) or rounded < 1 or rounded > 2147483647.0)
        return error.NativeGeometryOutOfRange;
    return @intFromFloat(rounded);
}
