const std = @import("std");
const browser = @import("../browser.zig");

pub const Size = browser.WindowSize;
pub const Position = browser.WindowPosition;

/// Content size and outer-window position in toolkit logical coordinates.
pub const Geometry = struct {
    position: Position,
    size: Size,
};

/// Borrowed native window, invalid after native close or owner destruction.
pub const Handle = union(enum) {
    cocoa: *anyopaque,
    gtk: *anyopaque,
    win32: *anyopaque,
};

/// Called on the UI thread. Return true to allow a user/JavaScript close.
/// Programmatic Window.close() bypasses this veto.
pub const CloseHandler = *const fn (?*anyopaque) bool;

pub const Options = struct {
    title: []const u8 = "WebUI",
    size: Size = .{ .width = 800, .height = 600 },
    position: ?Position = null,
    minimum_size: ?Size = null,
    resizable: bool = true,
    frameless: bool = false,
    transparent: bool = false,
    hidden: bool = false,
    kiosk: bool = false,
    center: bool = false,
    profile_directory: ?[]const u8 = null,
    webview2_loader: ?[]const u8 = null,
    close_handler: ?CloseHandler = null,
    user_data: ?*anyopaque = null,
    max_pending_tasks: usize = 64,

    pub fn validate(self: Options) !void {
        try validateText(self.title);
        try validateSize(self.size);
        if (self.minimum_size) |minimum| {
            try validateSize(minimum);
            if (minimum.width > self.size.width or minimum.height > self.size.height)
                return error.InvalidMinimumSize;
        }
        if (self.center and self.position != null) return error.ConflictingWindowPlacement;
        if (self.max_pending_tasks == 0) return error.InvalidTaskLimit;
        for ([_]?[]const u8{ self.profile_directory, self.webview2_loader }) |path| {
            if (path) |value| {
                if (value.len == 0) return error.InvalidNativePath;
                try validateText(value);
            }
        }
    }
};

pub fn validateText(value: []const u8) !void {
    if (std.mem.indexOfScalar(u8, value, 0) != null) return error.InvalidNativeText;
    if (!std.unicode.utf8ValidateSlice(value)) return error.InvalidUtf8;
}

pub fn validateSize(value: Size) !void {
    if (value.width == 0 or value.height == 0 or
        value.width > std.math.maxInt(i32) or value.height > std.math.maxInt(i32))
        return error.InvalidWindowSize;
}

test "native options reject unsafe sizes and contradictory placement" {
    try (Options{ .position = .{ .x = -100, .y = 0 } }).validate();
    try std.testing.expectError(error.InvalidWindowSize, (Options{ .size = .{ .width = 0, .height = 1 } }).validate());
    try std.testing.expectError(error.InvalidWindowSize, validateSize(.{ .width = std.math.maxInt(u32), .height = 1 }));
    try std.testing.expectError(error.InvalidMinimumSize, (Options{ .minimum_size = .{ .width = 801, .height = 600 } }).validate());
    try std.testing.expectError(error.ConflictingWindowPlacement, (Options{ .center = true, .position = .{ .x = 0, .y = 0 } }).validate());
    try std.testing.expectError(error.InvalidNativeText, (Options{ .title = "bad\x00title" }).validate());
    try std.testing.expectError(error.InvalidUtf8, (Options{ .title = "\xff" }).validate());
    try std.testing.expectError(error.InvalidTaskLimit, (Options{ .max_pending_tasks = 0 }).validate());
}
