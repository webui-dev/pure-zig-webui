const std = @import("std");
const webui = @import("webui");
const Context = struct { window: webui.Window, running: *webui.Running };
fn replace(call: *webui.Call, data: ?*anyopaque) !void {
    const context: *Context = @ptrCast(@alignCast(data.?));
    _ = try context.window.setContent(context.running, .{ .html = "<!doctype html><title>Replaced</title><h1>Content replaced without restarting the server</h1><script src='webui.js'></script>" });
    _ = call;
}
pub fn main(init: std.process.Init) !void {
    var app = webui.App.init(init.gpa, .{});
    defer app.deinit();
    const window = try app.createWindow(.{ .content = .{ .html = "<!doctype html><title>Dynamic content</title><button onclick=\"webui.call('replace').catch(()=>{})\">Replace content</button><script src='webui.js'></script>" } });
    var running: webui.Running = undefined;
    var context: Context = .{ .window = window, .running = &running };
    try window.bind(init.io, "replace", replace, &context);
    running = try app.start(init.io);
    defer running.stop() catch {};
    window.open(init.io, &running) catch |err| {
        std.log.warn("browser unavailable: {}", .{err});
        return;
    };
    _ = window.waitForConnection(init.io, .fromSeconds(15)) catch |err| {
        std.log.warn("browser did not connect: {}", .{err});
        return;
    };
    try running.wait();
}
