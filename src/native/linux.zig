const std = @import("std");
const types = @import("types.zig");

// ABI references: docs.gtk.org/{gtk3,gdk3,gobject} and
// webkitgtk.org/reference/webkit2gtk/stable (GTK3 / libsoup3 API 4.1).
const Object = *anyopaque;
const Callback = *const fn () callconv(.c) void;
const GeometryHints = extern struct {
    min_width: c_int = 0,
    min_height: c_int = 0,
    max_width: c_int = 0,
    max_height: c_int = 0,
    base_width: c_int = 0,
    base_height: c_int = 0,
    width_inc: c_int = 0,
    height_inc: c_int = 0,
    min_aspect: f64 = 0,
    max_aspect: f64 = 0,
    win_gravity: c_int = 0,
};
const Rgba = extern struct { red: f64, green: f64, blue: f64, alpha: f64 };
const Rectangle = extern struct { x: c_int, y: c_int, width: c_int, height: c_int };
const close_channel = "pureZigWebUIClose";
const close_script_source =
    \\(() => {
    \\    const post = window.webkit.messageHandlers.pureZigWebUIClose.postMessage.bind(
    \\        window.webkit.messageHandlers.pureZigWebUIClose);
    \\    Object.defineProperty(window, "close", {
    \\        value: () => post(true), writable: false, configurable: false
    \\    });
    \\    Object.defineProperty(window, "__zigWebuiNativeClose", { value: window.close });
    \\})();
;

const Api = struct {
    gtk_init_check: *const fn (?*c_int, ?*?[*:null]?[*:0]u8) callconv(.c) c_int,
    gtk_window_new: *const fn (c_int) callconv(.c) ?Object,
    gtk_widget_destroy: *const fn (Object) callconv(.c) void,
    gtk_widget_show_all: *const fn (Object) callconv(.c) void,
    gtk_widget_hide: *const fn (Object) callconv(.c) void,
    gtk_widget_get_screen: *const fn (Object) callconv(.c) ?Object,
    gtk_widget_get_display: *const fn (Object) callconv(.c) ?Object,
    gtk_widget_set_visual: *const fn (Object, ?Object) callconv(.c) void,
    gtk_widget_set_app_paintable: *const fn (Object, c_int) callconv(.c) void,
    gtk_widget_queue_draw: *const fn (Object) callconv(.c) void,
    gtk_widget_grab_focus: *const fn (Object) callconv(.c) void,
    gtk_widget_get_allocated_width: *const fn (Object) callconv(.c) c_int,
    gtk_widget_get_allocated_height: *const fn (Object) callconv(.c) c_int,
    gtk_widget_get_realized: *const fn (Object) callconv(.c) c_int,
    gtk_widget_get_mapped: *const fn (Object) callconv(.c) c_int,
    gtk_widget_get_window: *const fn (Object) callconv(.c) ?Object,
    gtk_container_add: *const fn (Object, Object) callconv(.c) void,
    gtk_window_set_title: *const fn (Object, [*:0]const u8) callconv(.c) void,
    gtk_window_set_default_size: *const fn (Object, c_int, c_int) callconv(.c) void,
    gtk_window_resize: *const fn (Object, c_int, c_int) callconv(.c) void,
    gtk_window_move: *const fn (Object, c_int, c_int) callconv(.c) void,
    gtk_window_get_position: *const fn (Object, *c_int, *c_int) callconv(.c) void,
    gtk_window_get_size: *const fn (Object, *c_int, *c_int) callconv(.c) void,
    gtk_window_set_position: *const fn (Object, c_int) callconv(.c) void,
    gtk_window_set_geometry_hints: *const fn (Object, ?Object, *const GeometryHints, c_int) callconv(.c) void,
    gtk_window_set_resizable: *const fn (Object, c_int) callconv(.c) void,
    gtk_window_set_decorated: *const fn (Object, c_int) callconv(.c) void,
    gtk_window_fullscreen: *const fn (Object) callconv(.c) void,
    gtk_window_unfullscreen: *const fn (Object) callconv(.c) void,
    gtk_window_iconify: *const fn (Object) callconv(.c) void,
    gtk_window_deiconify: *const fn (Object) callconv(.c) void,
    gtk_window_maximize: *const fn (Object) callconv(.c) void,
    gtk_window_unmaximize: *const fn (Object) callconv(.c) void,
    gtk_window_present: *const fn (Object) callconv(.c) void,
    gdk_screen_get_rgba_visual: *const fn (Object) callconv(.c) ?Object,
    gdk_screen_is_composited: *const fn (Object) callconv(.c) c_int,
    gdk_display_get_monitor_at_window: *const fn (Object, Object) callconv(.c) ?Object,
    gdk_monitor_get_workarea: *const fn (Object, *Rectangle) callconv(.c) void,
    gdk_window_get_frame_extents: *const fn (Object, *Rectangle) callconv(.c) void,
    g_type_check_instance_is_a: *const fn (Object, usize) callconv(.c) c_int,
    g_object_ref: *const fn (Object) callconv(.c) Object,
    g_object_ref_sink: *const fn (Object) callconv(.c) Object,
    g_object_unref: *const fn (Object) callconv(.c) void,
    g_signal_connect_data: *const fn (Object, [*:0]const u8, Callback, ?Object, ?*const fn (?Object, Object) callconv(.c) void, c_int) callconv(.c) c_ulong,
    g_signal_handler_is_connected: *const fn (Object, c_ulong) callconv(.c) c_int,
    g_signal_handler_disconnect: *const fn (Object, c_ulong) callconv(.c) void,
    g_main_context_iteration: *const fn (?Object, c_int) callconv(.c) c_int,
    cairo_save: *const fn (Object) callconv(.c) void,
    cairo_restore: *const fn (Object) callconv(.c) void,
    cairo_set_operator: *const fn (Object, c_int) callconv(.c) void,
    cairo_set_source_rgba: *const fn (Object, f64, f64, f64, f64) callconv(.c) void,
    cairo_paint: *const fn (Object) callconv(.c) void,
    webkit_website_data_manager_new: *const fn ([*:0]const u8, ...) callconv(.c) ?Object,
    webkit_web_context_new: *const fn () callconv(.c) ?Object,
    webkit_web_context_new_with_website_data_manager: *const fn (Object) callconv(.c) ?Object,
    webkit_web_context_get_cookie_manager: *const fn (Object) callconv(.c) ?Object,
    webkit_cookie_manager_set_persistent_storage: *const fn (Object, [*:0]const u8, c_int) callconv(.c) void,
    webkit_web_view_new_with_context: *const fn (Object) callconv(.c) ?Object,
    webkit_web_view_get_settings: *const fn (Object) callconv(.c) ?Object,
    webkit_settings_set_enable_javascript: *const fn (Object, c_int) callconv(.c) void,
    webkit_web_view_load_uri: *const fn (Object, [*:0]const u8) callconv(.c) void,
    webkit_web_view_stop_loading: *const fn (Object) callconv(.c) void,
    webkit_web_view_set_background_color: *const fn (Object, *const Rgba) callconv(.c) void,
    webkit_web_view_get_user_content_manager: *const fn (Object) callconv(.c) ?Object,
    webkit_user_content_manager_register_script_message_handler: *const fn (Object, [*:0]const u8) callconv(.c) c_int,
    webkit_user_content_manager_unregister_script_message_handler: *const fn (Object, [*:0]const u8) callconv(.c) void,
    webkit_user_content_manager_add_script: *const fn (Object, Object) callconv(.c) void,
    webkit_user_content_manager_remove_script: *const fn (Object, Object) callconv(.c) void,
    webkit_user_script_new: *const fn ([*:0]const u8, c_int, c_int, ?[*:null]const ?[*:0]const u8, ?[*:null]const ?[*:0]const u8) callconv(.c) ?Object,
    webkit_user_script_unref: *const fn (Object) callconv(.c) void,
    webkit_javascript_result_get_js_value: *const fn (Object) callconv(.c) ?Object,
    jsc_value_is_boolean: *const fn (Object) callconv(.c) c_int,
    jsc_value_to_boolean: *const fn (Object) callconv(.c) c_int,

    fn load(gtk: *std.DynLib, webkit: *std.DynLib) !Api {
        var api: Api = undefined;
        inline for (@typeInfo(Api).@"struct".fields) |field| {
            const library = if (comptime std.mem.startsWith(u8, field.name, "webkit_") or std.mem.startsWith(u8, field.name, "jsc_")) webkit else gtk;
            @field(api, field.name) = library.lookup(field.type, field.name ++ "\x00") orelse {
                std.log.err("native Linux runtime lacks symbol {s}", .{field.name});
                return error.NativeRuntimeSymbolMissing;
            };
        }
        return api;
    }
};

// GType registration and toolkit process globals outlive every individual window.
// Unmapping their code on the last window's dlclose would leave dangling GType
// class callbacks and GLib sources. NODELETE pins code, not our library handles:
// every successful open below still has exactly one matching close.
fn openLibrary(name: [:0]const u8) !std.DynLib {
    var library = std.DynLib.openZ(name) catch {
        std.log.err("native Linux runtime could not load {s}", .{name});
        return error.NativeRuntimeNotFound;
    };
    errdefer library.close();
    const pin = std.c.dlopen(name, .{ .NOW = true, .NOLOAD = true, .NODELETE = true }) orelse
        return error.NativeRuntimeInitializationFailed;
    _ = std.c.dlclose(pin);
    return library;
}

// GTK cannot be reinitialized on another thread after its last window closes.
// Keep this process-wide reservation for the lifetime of the initialized toolkit.
var gtk_owner: std.atomic.Value(std.Thread.Id) = .init(0);
// GTK dispatches all windows through one context. Pending closes belong to that
// same owner thread, not to whichever Backend happens to be pumping it.
var pending_close: ?*Backend = null;

pub const Backend = struct {
    gpa: std.mem.Allocator,
    gtk: std.DynLib,
    webkit: std.DynLib,
    api: Api,
    window: ?Object = null,
    view: ?Object = null,
    context: ?Object = null,
    content_manager: ?Object = null,
    close_script: ?Object = null,
    message_signal: c_ulong = 0,
    message_registered: bool = false,
    window_signals: [3]c_ulong = .{ 0, 0, 0 },
    view_signals: [1]c_ulong = .{0},
    close_handler: ?types.CloseHandler,
    user_data: ?*anyopaque,
    closed: bool = false,
    close_requested: bool = false,
    next_pending_close: ?*Backend = null,
    deciding_close: bool = false,
    process_failed: bool = false,
    transparent: bool = false,
    rgba_visual: bool = false,
    x11: bool = false,
    minimum_size: ?types.Size = null,

    pub fn create(gpa: std.mem.Allocator, io: std.Io, url: [:0]const u8, options: types.Options) !*Backend {
        if (options.webview2_loader != null) return error.UnsupportedNativeControl;
        var gtk = try openLibrary("libgtk-3.so.0");
        errdefer gtk.close();
        var webkit = try openLibrary("libwebkit2gtk-4.1.so.0");
        errdefer webkit.close();
        const api = try Api.load(&gtk, &webkit);
        const thread = std.Thread.getCurrentId();
        if (gtk_owner.cmpxchgStrong(0, thread, .acq_rel, .acquire)) |owner| {
            if (owner != thread) return error.NativeWrongThread;
        }
        // Unlike gtk_init(), gtk_init_check never exits the host on no display.
        if (api.gtk_init_check(null, null) == 0) return error.NativeDisplayUnavailable;
        const self = try gpa.create(Backend);
        errdefer gpa.destroy(self);
        self.* = .{ .gpa = gpa, .gtk = gtk, .webkit = webkit, .api = api, .close_handler = options.close_handler, .user_data = options.user_data };
        errdefer self.releaseObjects();

        const window = api.gtk_window_new(0) orelse return error.NativeInitializationFailed;
        // GtkWindow's initial reference belongs to GTK's toplevel list. Hold a
        // separate reference so the pointer survives an external destroy signal.
        self.window = api.g_object_ref(window);
        const display = api.gtk_widget_get_display(window) orelse return error.NativeDisplayUnavailable;
        if (gtk.lookup(*const fn () callconv(.c) usize, "gdk_x11_display_get_type")) |x11_type|
            self.x11 = api.g_type_check_instance_is_a(display, x11_type()) != 0;
        if (!self.x11 and (options.position != null or options.center)) return error.UnsupportedNativeControl;
        const screen = api.gtk_widget_get_screen(window) orelse return error.NativeDisplayUnavailable;
        if (api.gdk_screen_get_rgba_visual(screen)) |visual| {
            // Select an alpha visual before realization, including initially
            // opaque windows, so later transparency changes need no recreation.
            api.gtk_widget_set_visual(window, visual);
            self.rgba_visual = true;
        }

        if (options.profile_directory) |path| {
            try std.Io.Dir.cwd().createDirPath(io, path);
            const data = try gpa.dupeZ(u8, path);
            defer gpa.free(data);
            const cache = try std.fmt.allocPrintSentinel(gpa, "{s}/cache", .{path}, 0);
            defer gpa.free(cache);
            const manager = api.webkit_website_data_manager_new("base-data-directory", data.ptr, @as([*:0]const u8, "base-cache-directory"), cache.ptr, @as(?*anyopaque, null)) orelse return error.NativeInitializationFailed;
            defer api.g_object_unref(manager);
            self.context = api.webkit_web_context_new_with_website_data_manager(manager) orelse return error.NativeInitializationFailed;
            const cookies = api.webkit_web_context_get_cookie_manager(self.context.?) orelse return error.NativeInitializationFailed;
            const cookie_path = try std.fmt.allocPrintSentinel(gpa, "{s}/cookies.sqlite", .{path}, 0);
            defer gpa.free(cookie_path);
            api.webkit_cookie_manager_set_persistent_storage(cookies, cookie_path.ptr, 1);
        } else {
            self.context = api.webkit_web_context_new() orelse return error.NativeInitializationFailed;
        }
        const view = api.webkit_web_view_new_with_context(self.context.?) orelse return error.NativeInitializationFailed;
        // Sink the floating GtkWidget ref; the container acquires its own ref.
        self.view = api.g_object_ref_sink(view);
        api.gtk_container_add(window, view);
        const settings = api.webkit_web_view_get_settings(view) orelse return error.NativeInitializationFailed;
        api.webkit_settings_set_enable_javascript(settings, 1);
        // WebCore marks a page closing before emitting WebView::close, and its
        // built-in window.close also rejects ordinary windows with history.
        // Intercept at document start instead: veto never closes the DOM page.
        const content_manager = api.webkit_web_view_get_user_content_manager(view) orelse return error.NativeInitializationFailed;
        self.content_manager = api.g_object_ref(content_manager);
        self.message_signal = try self.connect(content_manager, "script-message-received::" ++ close_channel, @ptrCast(&scriptMessage));
        if (api.webkit_user_content_manager_register_script_message_handler(content_manager, close_channel) == 0)
            return error.NativeInitializationFailed;
        self.message_registered = true;
        // WEBKIT_USER_CONTENT_INJECT_TOP_FRAME, DOCUMENT_START. The manager
        // installs the script for every navigation; BFCache retains the override.
        self.close_script = api.webkit_user_script_new(close_script_source, 1, 0, null, null) orelse return error.NativeInitializationFailed;
        api.webkit_user_content_manager_add_script(content_manager, self.close_script.?);

        self.window_signals[0] = try self.connect(window, "delete-event", @ptrCast(&deleteEvent));
        self.window_signals[1] = try self.connect(window, "destroy", @ptrCast(&destroyed));
        self.window_signals[2] = try self.connect(window, "draw", @ptrCast(&draw));
        self.view_signals[0] = try self.connect(view, "web-process-terminated", @ptrCast(&processTerminated));

        // GTK/WebKit setters copy strings synchronously; no borrowed Options
        // slices or URL buffers are retained in this backend.
        const title = try gpa.dupeZ(u8, options.title);
        defer gpa.free(title);
        api.gtk_window_set_title(window, title);
        api.gtk_window_set_default_size(window, @intCast(options.size.width), @intCast(options.size.height));
        if (options.minimum_size) |minimum| try self.setMinimumSize(minimum);
        try self.setResizable(options.resizable);
        try self.setFrameless(options.frameless);
        try self.setTransparent(options.transparent);
        if (options.position) |position| try self.setPosition(position);
        if (options.center) try self.center();
        if (options.kiosk) try self.setKiosk(true);
        api.webkit_web_view_load_uri(view, url);
        if (!options.hidden) api.gtk_widget_show_all(window);
        return self;
    }

    pub fn destroy(self: *Backend) void {
        self.releaseObjects();
        self.webkit.close();
        self.gtk.close();
        self.gpa.destroy(self);
    }

    fn releaseObjects(self: *Backend) void {
        self.removePendingClose();
        if (self.content_manager) |manager| {
            self.disconnect(manager, self.message_signal);
            self.message_signal = 0;
            if (self.message_registered) {
                self.api.webkit_user_content_manager_unregister_script_message_handler(manager, close_channel);
                self.message_registered = false;
            }
            if (self.close_script) |script| {
                self.api.webkit_user_content_manager_remove_script(manager, script);
                self.api.webkit_user_script_unref(script);
                self.close_script = null;
            }
            self.api.g_object_unref(manager);
            self.content_manager = null;
        }
        if (self.view) |view| {
            for (self.view_signals) |signal| self.disconnect(view, signal);
            self.view_signals = .{0};
            // A retained GtkWidget pointer can already have been disposed by
            // gtk_widget_destroy; only call WebKit methods before that point.
            if (!self.closed) self.api.webkit_web_view_stop_loading(view);
        }
        if (self.window) |window| {
            for (self.window_signals) |signal| self.disconnect(window, signal);
            self.window_signals = .{ 0, 0, 0 };
            if (!self.closed) self.api.gtk_widget_destroy(window);
            self.closed = true;
            self.api.g_object_unref(window);
            self.window = null;
        }
        if (self.view) |view| {
            self.api.g_object_unref(view);
            self.view = null;
        }
        if (self.context) |context| {
            self.api.g_object_unref(context);
            self.context = null;
        }
    }

    pub fn pump(self: *Backend) !bool {
        // Bound each drain: a continuously ready GLib source must not starve
        // the host's std.Io work. Iteration(false) never waits for more events.
        var remaining: usize = 64;
        while (remaining != 0) : (remaining -= 1) {
            if (self.api.g_main_context_iteration(null, 0) == 0) break;
        }
        while (pending_close) |backend| try backend.close();
        if (self.closed) return false;
        if (self.process_failed) return error.NativeWebProcessTerminated;
        return true;
    }

    pub fn close(self: *Backend) !void {
        if (self.closed) {
            self.removePendingClose();
            return;
        }
        if (self.deciding_close) {
            self.queueClose();
            return;
        }
        self.closed = true;
        self.removePendingClose();
        if (self.view) |view| self.api.webkit_web_view_stop_loading(view);
        if (self.window) |window| self.api.gtk_widget_destroy(window);
    }

    fn liveWindow(self: *Backend) !Object {
        if (self.closed or self.close_requested) return error.NativeWindowClosed;
        return self.window orelse error.NativeWindowClosed;
    }

    pub fn setTitle(self: *Backend, title: [:0]const u8) !void {
        self.api.gtk_window_set_title(try self.liveWindow(), title);
    }

    pub fn navigate(self: *Backend, url: [:0]const u8) !void {
        _ = try self.liveWindow();
        self.process_failed = false;
        self.api.webkit_web_view_load_uri(self.view.?, url);
    }

    pub fn setSize(self: *Backend, value: types.Size) !void {
        const window = try self.liveWindow();
        if (self.minimum_size) |minimum| {
            if (value.width < minimum.width or value.height < minimum.height) return error.InvalidWindowSize;
        }
        self.api.gtk_window_set_default_size(window, @intCast(value.width), @intCast(value.height));
        self.api.gtk_window_resize(window, @intCast(value.width), @intCast(value.height));
    }

    pub fn setPosition(self: *Backend, value: types.Position) !void {
        const window = try self.liveWindow();
        if (!self.x11) return error.UnsupportedNativeControl;
        self.api.gtk_window_set_position(window, 0); // GTK_WIN_POS_NONE
        self.api.gtk_window_move(window, value.x, value.y);
    }

    pub fn center(self: *Backend) !void {
        const window = try self.liveWindow();
        if (!self.x11) return error.UnsupportedNativeControl;
        if (self.api.gtk_widget_get_mapped(window) == 0) {
            self.api.gtk_window_set_position(window, 1); // GTK_WIN_POS_CENTER at first map
            return;
        }
        const display = self.api.gtk_widget_get_display(window) orelse return error.NativeDisplayUnavailable;
        const native_window = self.api.gtk_widget_get_window(window) orelse return error.NativeGeometryUnavailable;
        const monitor = self.api.gdk_display_get_monitor_at_window(display, native_window) orelse return error.NativeGeometryUnavailable;
        var workarea: Rectangle = undefined;
        var frame: Rectangle = undefined;
        self.api.gdk_monitor_get_workarea(monitor, &workarea);
        self.api.gdk_window_get_frame_extents(native_window, &frame);
        if (workarea.width <= 0 or workarea.height <= 0 or frame.width <= 0 or frame.height <= 0)
            return error.NativeGeometryUnavailable;
        // Both rectangles use logical root coordinates, including WM borders.
        // Widen before arithmetic for negative multi-monitor desktop origins.
        const x = @as(i64, workarea.x) + @divTrunc(@as(i64, workarea.width) - frame.width, 2);
        const y = @as(i64, workarea.y) + @divTrunc(@as(i64, workarea.height) - frame.height, 2);
        const position_x = std.math.cast(c_int, x) orelse return error.NativeGeometryUnavailable;
        const position_y = std.math.cast(c_int, y) orelse return error.NativeGeometryUnavailable;
        self.api.gtk_window_set_position(window, 0); // GTK_WIN_POS_NONE
        self.api.gtk_window_move(window, position_x, position_y);
    }

    pub fn setMinimumSize(self: *Backend, value: types.Size) !void {
        const window = try self.liveWindow();
        const hints: GeometryHints = .{ .min_width = @intCast(value.width), .min_height = @intCast(value.height) };
        self.api.gtk_window_set_geometry_hints(window, self.view, &hints, 1 << 1); // GDK_HINT_MIN_SIZE
        self.minimum_size = value;
    }

    pub fn setResizable(self: *Backend, value: bool) !void {
        self.api.gtk_window_set_resizable(try self.liveWindow(), @intFromBool(value));
    }

    pub fn setFrameless(self: *Backend, value: bool) !void {
        self.api.gtk_window_set_decorated(try self.liveWindow(), @intFromBool(!value));
    }

    pub fn setTransparent(self: *Backend, value: bool) !void {
        const window = try self.liveWindow();
        if (value) {
            const screen = self.api.gtk_widget_get_screen(window) orelse return error.NativeDisplayUnavailable;
            if (!self.rgba_visual or self.api.gdk_screen_is_composited(screen) == 0) return error.UnsupportedNativeControl;
        }
        self.transparent = value;
        self.api.gtk_widget_set_app_paintable(window, @intFromBool(value));
        const color: Rgba = if (value)
            .{ .red = 0, .green = 0, .blue = 0, .alpha = 0 }
        else
            .{ .red = 1, .green = 1, .blue = 1, .alpha = 1 };
        self.api.webkit_web_view_set_background_color(self.view.?, &color);
        self.api.gtk_widget_queue_draw(window);
    }

    pub fn setVisible(self: *Backend, value: bool) !void {
        const window = try self.liveWindow();
        if (value) self.api.gtk_widget_show_all(window) else self.api.gtk_widget_hide(window);
    }

    pub fn setKiosk(self: *Backend, value: bool) !void {
        const window = try self.liveWindow();
        if (value) self.api.gtk_window_fullscreen(window) else self.api.gtk_window_unfullscreen(window);
    }

    pub fn minimize(self: *Backend) !void {
        self.api.gtk_window_iconify(try self.liveWindow());
    }

    pub fn maximize(self: *Backend) !void {
        self.api.gtk_window_maximize(try self.liveWindow());
    }

    pub fn restore(self: *Backend) !void {
        const window = try self.liveWindow();
        self.api.gtk_window_unfullscreen(window);
        self.api.gtk_window_unmaximize(window);
        self.api.gtk_window_deiconify(window);
    }

    pub fn focus(self: *Backend) !void {
        self.api.gtk_window_present(try self.liveWindow());
        self.api.gtk_widget_grab_focus(self.view.?);
    }

    pub fn geometry(self: *Backend) !types.Geometry {
        const window = try self.liveWindow();
        // Wayland's gtk_window_get_position always returns dummy (0,0).
        // Geometry has no optional position, so report unsupported, not fiction.
        if (!self.x11) return error.UnsupportedNativeControl;
        var x: c_int = 0;
        var y: c_int = 0;
        var width: c_int = 0;
        var height: c_int = 0;
        self.api.gtk_window_get_position(window, &x, &y);
        if (self.api.gtk_widget_get_realized(self.view.?) != 0) {
            width = self.api.gtk_widget_get_allocated_width(self.view.?);
            height = self.api.gtk_widget_get_allocated_height(self.view.?);
        } else {
            self.api.gtk_window_get_size(window, &width, &height);
        }
        if (width <= 0 or height <= 0) return error.NativeGeometryUnavailable;
        return .{ .position = .{ .x = x, .y = y }, .size = .{ .width = @intCast(width), .height = @intCast(height) } };
    }

    pub fn handle(self: *Backend) !types.Handle {
        return .{ .gtk = try self.liveWindow() };
    }

    pub fn setCloseHandler(self: *Backend, handler: ?types.CloseHandler, user_data: ?*anyopaque) void {
        self.close_handler = handler;
        self.user_data = user_data;
    }

    fn connect(self: *Backend, object: Object, signal: [*:0]const u8, callback: Callback) !c_ulong {
        const id = self.api.g_signal_connect_data(object, signal, callback, self, null, 0);
        if (id == 0) return error.NativeInitializationFailed;
        return id;
    }

    fn disconnect(self: *Backend, object: Object, id: c_ulong) void {
        if (id != 0 and self.api.g_signal_handler_is_connected(object, id) != 0)
            self.api.g_signal_handler_disconnect(object, id);
    }

    fn queueClose(self: *Backend) void {
        if (self.closed or self.close_requested) return;
        self.close_requested = true;
        self.next_pending_close = pending_close;
        pending_close = self;
    }

    fn removePendingClose(self: *Backend) void {
        if (!self.close_requested) return;
        var link = &pending_close;
        while (link.*) |backend| {
            if (backend == self) {
                link.* = self.next_pending_close;
                break;
            }
            link = &backend.next_pending_close;
        }
        self.close_requested = false;
        self.next_pending_close = null;
    }

    fn requestClose(self: *Backend) void {
        if (self.closed or self.close_requested or self.deciding_close) return;
        self.deciding_close = true;
        const allow = if (self.close_handler) |handler| handler(self.user_data) else true;
        self.deciding_close = false;
        if (allow) self.queueClose();
    }

    fn deleteEvent(_: Object, _: Object, data: ?Object) callconv(.c) c_int {
        const self: *Backend = @ptrCast(@alignCast(data.?));
        self.requestClose();
        return 1; // Any Backend's pump destroys accepted requests after emission.
    }

    fn scriptMessage(_: Object, result: Object, data: ?Object) callconv(.c) void {
        const self: *Backend = @ptrCast(@alignCast(data.?));
        const value = self.api.webkit_javascript_result_get_js_value(result) orelse return;
        // This channel has only one fixed operation, not an evaluator. GTK's
        // message signal has no frame metadata; injection itself is top-only.
        if (self.api.jsc_value_is_boolean(value) == 0 or self.api.jsc_value_to_boolean(value) == 0) return;
        self.requestClose();
    }

    fn destroyed(_: Object, data: ?Object) callconv(.c) void {
        const self: *Backend = @ptrCast(@alignCast(data.?));
        self.closed = true;
        self.removePendingClose();
    }

    fn processTerminated(_: Object, _: c_int, data: ?Object) callconv(.c) void {
        const self: *Backend = @ptrCast(@alignCast(data.?));
        self.process_failed = true;
    }

    fn draw(_: Object, cr: Object, data: ?Object) callconv(.c) c_int {
        const self: *Backend = @ptrCast(@alignCast(data.?));
        if (self.transparent) {
            self.api.cairo_save(cr);
            self.api.cairo_set_operator(cr, 1); // CAIRO_OPERATOR_SOURCE
            self.api.cairo_set_source_rgba(cr, 0, 0, 0, 0);
            self.api.cairo_paint(cr);
            self.api.cairo_restore(cr);
        }
        return 0; // Continue GTK's draw so the WebKit child is painted.
    }
};
