const std = @import("std");
const webui = @import("webui");
pub fn main(init: std.process.Init) !void {
    const selected = try webui.bestBrowser(init.gpa, init.io) orelse {
        std.log.warn("no supported browser is installed", .{});
        return;
    };
    var app = webui.App.init(init.gpa, .{});
    defer app.deinit();
    const window = try app.createWindow(.{
        .content = .{ .html = "<!doctype html><title>Managed browser</title><h1>Independent managed browser process</h1><p>The application retains this child's lifetime and private profile.</p><script src='webui.js'></script>" },
        .size = .{ .width = 900, .height = 600 },
        .center = true,
    });
    var running = try app.start(init.io);
    defer running.stop() catch {};
    const child = window.openWithBrowser(&running, .{ .browser = selected }) catch |err| {
        std.log.warn("cannot launch {s}: {}", .{ @tagName(selected), err });
        return;
    };
    std.debug.print("Managed {s} child: {any}\n", .{ @tagName(selected), child });
    _ = window.waitForConnection(init.io, .fromSeconds(15)) catch |err| {
        std.log.warn("browser did not connect: {}", .{err});
        return;
    };
    try running.wait();
}
