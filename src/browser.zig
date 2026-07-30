const std = @import("std");
const builtin = @import("builtin");

/// Browser families supported by discovery and explicit selection.
pub const Browser = enum {
    chrome,
    firefox,
    edge,
    safari,
    chromium,
    opera,
    brave,
    vivaldi,
    epic,
    yandex,
};

pub const LaunchOptions = struct {
    browser: Browser,
    /// Full path or PATH-resolvable executable name. Null uses discovery.
    executable: ?[]const u8 = null,
    /// Additional arguments inserted before the browser URL argument.
    arguments: []const []const u8 = &.{},
};

pub const WindowSize = struct {
    width: u32,
    height: u32,
};

pub const WindowPosition = struct {
    x: i32,
    y: i32,
};

pub const WindowControls = struct {
    kiosk: bool = false,
    high_contrast: bool = true,
    size: ?WindowSize = null,
    position: ?WindowPosition = null,
    profile_directory: ?[]const u8 = null,
    proxy_server: ?[]const u8 = null,

    pub fn validate(self: WindowControls) !void {
        if (self.size) |size|
            if (size.width == 0 or size.height == 0)
                return error.InvalidWindowSize;
        if (self.profile_directory) |directory| {
            if (directory.len == 0 or
                std.mem.indexOfScalar(u8, directory, 0) != null)
            {
                return error.InvalidBrowserProfile;
            }
            if (!std.unicode.utf8ValidateSlice(directory))
                return error.InvalidUtf8;
        }
        if (self.proxy_server) |proxy| {
            if (proxy.len == 0 or std.mem.indexOfScalar(u8, proxy, 0) != null)
                return error.InvalidBrowserProxy;
            if (!std.unicode.utf8ValidateSlice(proxy))
                return error.InvalidUtf8;
        }
    }

    pub fn validateFor(self: WindowControls, selected: Browser) !void {
        try self.validate();
        switch (selected) {
            .safari => {
                if (self.profile_directory != null)
                    return error.UnsupportedBrowserProfile;
                if (self.proxy_server != null)
                    return error.UnsupportedBrowserProxy;
                if (!self.high_contrast)
                    return error.UnsupportedBrowserHighContrast;
                if (self.isActive()) return error.UnsupportedBrowserControl;
            },
            .firefox => {
                if (self.proxy_server != null)
                    return error.UnsupportedBrowserProxy;
                if (!self.high_contrast)
                    return error.UnsupportedBrowserHighContrast;
                if (self.position != null)
                    return error.UnsupportedBrowserControl;
            },
            else => {},
        }
    }

    pub fn isActive(self: WindowControls) bool {
        return self.kiosk or
            !self.high_contrast or
            self.size != null or
            self.position != null or
            self.profile_directory != null or
            self.proxy_server != null;
    }
};

/// PID on POSIX and a process handle on Windows.
pub const ProcessId = std.process.Child.Id;

/// Return the numeric ID of the current backend process, which is the parent
/// of browsers launched directly by this package.
pub fn parentProcessId() !u32 {
    return switch (builtin.os.tag) {
        .windows => std.os.windows.GetCurrentProcessId(),
        .linux => @intCast(std.os.linux.getpid()),
        .plan9 => std.os.plan9.getpid(),
        else => if (builtin.link_libc)
            @intCast(std.c.getpid())
        else
            error.UnsupportedPlatform,
    };
}

/// Open a non-empty URL with the operating system's default handler.
pub fn openUrl(
    gpa: std.mem.Allocator,
    io: std.Io,
    url: []const u8,
) !void {
    if (url.len == 0) return error.InvalidUrl;
    const argv: []const []const u8 = switch (builtin.os.tag) {
        .windows => &.{ "explorer.exe", url },
        .macos => &.{ "open", url },
        else => &.{ "xdg-open", url },
    };
    if (!try commandSucceeds(gpa, io, argv))
        return error.BrowserOpenFailed;
}

/// Return whether a browser is registered or available as an executable.
pub fn browserExists(
    gpa: std.mem.Allocator,
    io: std.Io,
    selected: Browser,
) !bool {
    const executable = try resolveExecutable(gpa, io, selected) orelse
        return false;
    gpa.free(executable);
    return true;
}

/// Return the first available browser in the platform preference order.
pub fn bestBrowser(
    gpa: std.mem.Allocator,
    io: std.Io,
) !?Browser {
    for (preferredBrowsers()) |selected|
        if (try browserExists(gpa, io, selected)) return selected;
    return null;
}

pub fn launch(
    gpa: std.mem.Allocator,
    io: std.Io,
    url: []const u8,
    options: LaunchOptions,
    controls: WindowControls,
) !std.process.Child {
    if (url.len == 0) return error.InvalidUrl;
    if (options.executable) |executable|
        if (executable.len == 0) return error.InvalidBrowserExecutable;
    try controls.validateFor(options.browser);

    const discovered = if (options.executable == null)
        try resolveExecutable(gpa, io, options.browser) orelse
            return error.BrowserNotFound
    else
        null;
    defer if (discovered) |executable| gpa.free(executable);
    const executable = options.executable orelse discovered.?;

    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(gpa);
    try argv.append(gpa, executable);
    try argv.appendSlice(gpa, options.arguments);
    const profile_argument = if (controls.profile_directory) |directory|
        switch (options.browser) {
            .firefox, .safari => null,
            else => try std.fmt.allocPrint(
                gpa,
                "--user-data-dir={s}",
                .{directory},
            ),
        }
    else
        null;
    defer if (profile_argument) |argument| gpa.free(argument);
    if (controls.profile_directory) |directory| switch (options.browser) {
        .firefox => try argv.appendSlice(gpa, &.{ "--profile", directory }),
        .safari => unreachable,
        else => try argv.append(gpa, profile_argument.?),
    };
    const proxy_argument = if (controls.proxy_server) |proxy|
        try std.fmt.allocPrint(gpa, "--proxy-server={s}", .{proxy})
    else
        null;
    defer if (proxy_argument) |argument| gpa.free(argument);
    if (proxy_argument) |argument| try argv.append(gpa, argument);
    if (!controls.high_contrast)
        try argv.append(gpa, "--disable-features=ForcedColors");
    if (controls.kiosk) try argv.append(gpa, switch (options.browser) {
        .firefox => "-kiosk",
        else => "--kiosk",
    });
    var size_buffer: [48]u8 = undefined;
    if (controls.size) |size| switch (options.browser) {
        .firefox => {
            try argv.appendSlice(gpa, &.{
                "-width",
                try std.fmt.bufPrint(&size_buffer, "{d}", .{size.width}),
                "-height",
                try std.fmt.bufPrint(size_buffer[24..], "{d}", .{size.height}),
            });
        },
        else => try argv.append(
            gpa,
            try std.fmt.bufPrint(
                &size_buffer,
                "--window-size={d},{d}",
                .{ size.width, size.height },
            ),
        ),
    };
    var position_buffer: [64]u8 = undefined;
    if (controls.position) |position| try argv.append(
        gpa,
        try std.fmt.bufPrint(
            &position_buffer,
            "--window-position={d},{d}",
            .{ position.x, position.y },
        ),
    );
    const app_url = switch (options.browser) {
        .firefox, .safari => null,
        else => try std.fmt.allocPrint(gpa, "--app={s}", .{url}),
    };
    defer if (app_url) |argument| gpa.free(argument);
    switch (options.browser) {
        .firefox => {
            try argv.append(gpa, "-new-window");
            try argv.append(gpa, url);
        },
        .safari => try argv.append(gpa, url),
        else => try argv.append(gpa, app_url.?),
    }

    return std.process.spawn(io, .{
        .argv = argv.items,
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    });
}

fn commandSucceeds(
    gpa: std.mem.Allocator,
    io: std.Io,
    argv: []const []const u8,
) !bool {
    const result = std.process.run(gpa, io, .{
        .argv = argv,
    }) catch |err| switch (err) {
        error.FileNotFound, error.AccessDenied, error.InvalidExe => return false,
        else => return err,
    };
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);
    return switch (result.term) {
        .exited => |code| code == 0,
        else => false,
    };
}

fn resolveExecutable(
    gpa: std.mem.Allocator,
    io: std.Io,
    selected: Browser,
) !?[]u8 {
    return switch (builtin.os.tag) {
        .windows => resolveWindowsExecutable(gpa, io, selected),
        .macos => resolveMacosExecutable(gpa, io, selected),
        else => for (linuxExecutables(selected)) |executable| {
            if (try commandSucceeds(gpa, io, &.{ executable, "--version" }))
                break try gpa.dupe(u8, executable);
        } else null,
    };
}

fn resolveWindowsExecutable(
    gpa: std.mem.Allocator,
    io: std.Io,
    selected: Browser,
) !?[]u8 {
    const executable = windowsExecutable(selected);
    if (try commandValue(gpa, io, &.{ "where.exe", executable }, null)) |path| return path;
    // ponytail: Chrome and Chromium share chrome.exe on Windows; inspect
    // installation metadata if standalone Chromium detection becomes needed.
    if (selected == .chromium) return null;

    var key_buffer: [160]u8 = undefined;
    for ([_][]const u8{ "HKCU", "HKLM" }) |root| {
        const key = try std.fmt.bufPrint(
            &key_buffer,
            "{s}\\Software\\Microsoft\\Windows\\CurrentVersion\\" ++
                "App Paths\\{s}",
            .{ root, executable },
        );
        if (try commandValue(gpa, io, &.{
            "reg.exe",
            "query",
            key,
            "/ve",
        }, "REG_SZ")) |path| return path;
    }
    return null;
}

fn resolveMacosExecutable(
    gpa: std.mem.Allocator,
    io: std.Io,
    selected: Browser,
) !?[]u8 {
    for ([_][]const u8{ "/Applications", "/System/Applications" }) |root| {
        const path = try std.fmt.allocPrint(
            gpa,
            "{s}/{s}.app/Contents/MacOS/{s}",
            .{
                root,
                macosApplication(selected),
                macosExecutable(selected),
            },
        );
        std.Io.Dir.accessAbsolute(io, path, .{ .execute = true }) catch |err| {
            gpa.free(path);
            switch (err) {
                error.FileNotFound,
                error.NotDir,
                error.AccessDenied,
                error.PermissionDenied,
                => continue,
                else => return err,
            }
        };
        return path;
    }
    return null;
}

fn commandValue(
    gpa: std.mem.Allocator,
    io: std.Io,
    argv: []const []const u8,
    marker: ?[]const u8,
) !?[]u8 {
    const result = std.process.run(gpa, io, .{
        .argv = argv,
        .stdout_limit = .limited(64 << 10),
        .stderr_limit = .limited(64 << 10),
    }) catch |err| switch (err) {
        error.FileNotFound, error.AccessDenied, error.InvalidExe => return null,
        else => return err,
    };
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);
    switch (result.term) {
        .exited => |code| if (code != 0) return null,
        else => return null,
    }
    const value = parseCommandValue(result.stdout, marker) orelse return null;
    return gpa.dupe(u8, value);
}

fn parseCommandValue(
    output: []const u8,
    marker: ?[]const u8,
) ?[]const u8 {
    const value = if (marker) |needle| blk: {
        const start = std.mem.indexOf(u8, output, needle) orelse
            return null;
        break :blk output[start + needle.len ..];
    } else blk: {
        var lines = std.mem.tokenizeAny(u8, output, "\r\n");
        break :blk lines.next() orelse return null;
    };
    const trimmed = std.mem.trim(u8, value, " \t\r\n\"");
    if (trimmed.len == 0) return null;
    return trimmed;
}

fn windowsExecutable(selected: Browser) []const u8 {
    return switch (selected) {
        .chrome => "chrome.exe",
        .firefox => "firefox.exe",
        .edge => "msedge.exe",
        .safari => "Safari.exe",
        .chromium => "chromium.exe",
        .opera => "opera.exe",
        .brave => "brave.exe",
        .vivaldi => "vivaldi.exe",
        .epic => "epic.exe",
        .yandex => "browser.exe",
    };
}

fn macosApplication(selected: Browser) []const u8 {
    return switch (selected) {
        .chrome => "Google Chrome",
        .firefox => "Firefox",
        .edge => "Microsoft Edge",
        .safari => "Safari",
        .chromium => "Chromium",
        .opera => "Opera",
        .brave => "Brave Browser",
        .vivaldi => "Vivaldi",
        .epic => "Epic",
        .yandex => "Yandex",
    };
}

fn macosExecutable(selected: Browser) []const u8 {
    return switch (selected) {
        .firefox => "firefox",
        else => macosApplication(selected),
    };
}

fn linuxExecutables(selected: Browser) []const []const u8 {
    return switch (selected) {
        .chrome => &.{ "google-chrome", "google-chrome-stable" },
        .firefox => &.{"firefox"},
        .edge => &.{
            "microsoft-edge-stable",
            "microsoft-edge-beta",
            "microsoft-edge-dev",
        },
        .safari => &.{},
        .chromium => &.{ "chromium-browser", "chromium" },
        .opera => &.{"opera"},
        .brave => &.{
            "brave",
            "brave-browser",
            "brave-browser-stable",
            "brave-browser-nightly",
            "brave-browser-beta",
        },
        .vivaldi => &.{ "vivaldi", "vivaldi-stable", "vivaldi-snapshot" },
        .epic => &.{"epic"},
        .yandex => &.{"yandex-browser"},
    };
}

fn preferredBrowsers() []const Browser {
    return switch (builtin.os.tag) {
        .windows => &.{
            .chrome,
            .edge,
            .epic,
            .vivaldi,
            .brave,
            .firefox,
            .yandex,
            .chromium,
            .opera,
            .safari,
        },
        else => &.{
            .chrome,
            .edge,
            .chromium,
            .epic,
            .vivaldi,
            .brave,
            .firefox,
            .yandex,
            .opera,
            .safari,
        },
    };
}

test "window controls validate browser support" {
    try (WindowControls{
        .kiosk = true,
        .size = .{ .width = 1280, .height = 720 },
        .position = .{ .x = -200, .y = 40 },
        .profile_directory = "profiles/main",
        .proxy_server = "socks5://127.0.0.1:1080",
        .high_contrast = false,
    }).validateFor(.chromium);
    try (WindowControls{
        .kiosk = true,
        .size = .{ .width = 1280, .height = 720 },
        .profile_directory = "profiles/firefox",
    }).validateFor(.firefox);
    try (WindowControls{}).validateFor(.safari);
    try std.testing.expectError(
        error.UnsupportedBrowserControl,
        (WindowControls{ .position = .{ .x = 0, .y = 0 } })
            .validateFor(.firefox),
    );
    try std.testing.expectError(
        error.UnsupportedBrowserControl,
        (WindowControls{ .kiosk = true }).validateFor(.safari),
    );
    try std.testing.expectError(
        error.UnsupportedBrowserProfile,
        (WindowControls{ .profile_directory = "profiles/safari" })
            .validateFor(.safari),
    );
    try std.testing.expectError(
        error.UnsupportedBrowserProxy,
        (WindowControls{ .proxy_server = "http://127.0.0.1:8080" })
            .validateFor(.firefox),
    );
    try std.testing.expectError(
        error.UnsupportedBrowserProxy,
        (WindowControls{ .proxy_server = "http://127.0.0.1:8080" })
            .validateFor(.safari),
    );
    try std.testing.expectError(
        error.UnsupportedBrowserHighContrast,
        (WindowControls{ .high_contrast = false }).validateFor(.firefox),
    );
    try std.testing.expectError(
        error.UnsupportedBrowserHighContrast,
        (WindowControls{ .high_contrast = false }).validateFor(.safari),
    );
    try std.testing.expect(
        (WindowControls{ .high_contrast = false }).isActive(),
    );
    try std.testing.expectError(
        error.InvalidWindowSize,
        (WindowControls{ .size = .{ .width = 0, .height = 720 } })
            .validateFor(.chromium),
    );
    try std.testing.expectError(
        error.InvalidBrowserProfile,
        (WindowControls{ .profile_directory = "" }).validate(),
    );
    try std.testing.expectError(
        error.InvalidBrowserProxy,
        (WindowControls{ .proxy_server = "http://host\x00:8080" })
            .validate(),
    );
    const invalid_utf8 = &[_]u8{0xff};
    try std.testing.expectError(
        error.InvalidUtf8,
        (WindowControls{ .profile_directory = invalid_utf8 }).validate(),
    );
    try std.testing.expectError(
        error.InvalidUtf8,
        (WindowControls{ .proxy_server = invalid_utf8 }).validate(),
    );
}

test "parent process ID identifies the backend process" {
    const actual = try parentProcessId();
    try std.testing.expect(actual != 0);
    if (builtin.os.tag == .linux)
        try std.testing.expectEqual(
            @as(u32, @intCast(std.os.linux.getpid())),
            actual,
        );
}

test "browser candidates and preference order cover every browser" {
    try std.testing.expectError(
        error.InvalidUrl,
        openUrl(std.testing.allocator, std.testing.io, ""),
    );
    try std.testing.expectEqualStrings(
        "chrome.exe",
        windowsExecutable(.chrome),
    );
    try std.testing.expectEqualStrings(
        "Google Chrome",
        macosApplication(.chrome),
    );
    try std.testing.expectEqualStrings("firefox", macosExecutable(.firefox));
    try std.testing.expectEqualStrings(
        "google-chrome",
        linuxExecutables(.chrome)[0],
    );
    try std.testing.expectEqualStrings(
        "C:\\Browser\\browser.exe",
        parseCommandValue(
            "key\r\n  (Default)  REG_SZ  C:\\Browser\\browser.exe\r\n",
            "REG_SZ",
        ).?,
    );
    try std.testing.expectEqualStrings(
        "/usr/bin/browser",
        parseCommandValue("/usr/bin/browser\r\n", null).?,
    );

    var seen: std.EnumSet(Browser) = .initEmpty();
    for (preferredBrowsers()) |selected| {
        try std.testing.expect(!seen.contains(selected));
        seen.insert(selected);
    }
    try std.testing.expectEqual(
        std.meta.fields(Browser).len,
        seen.count(),
    );
    try std.testing.expectEqual(Browser.chrome, preferredBrowsers()[0]);

    if (builtin.os.tag == .linux) {
        try std.testing.expect(try commandSucceeds(
            std.testing.allocator,
            std.testing.io,
            &.{"/bin/true"},
        ));
        try std.testing.expect(!try commandSucceeds(
            std.testing.allocator,
            std.testing.io,
            &.{"/bin/false"},
        ));
        try std.testing.expect(!try commandSucceeds(
            std.testing.allocator,
            std.testing.io,
            &.{"/definitely/missing/browser"},
        ));
        if (try bestBrowser(std.testing.allocator, std.testing.io)) |selected|
            try std.testing.expect(try browserExists(
                std.testing.allocator,
                std.testing.io,
                selected,
            ));
    }
}
