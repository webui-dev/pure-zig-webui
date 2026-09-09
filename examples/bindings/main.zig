const std = @import("std");
const webui = @import("webui");
const Context = struct { io: std.Io, window: webui.Window };
fn answer(call: *webui.Call, _: ?*anyopaque) !void {
    try call.replyInt(42);
}
fn install(call: *webui.Call, data: ?*anyopaque) !void {
    const context: *Context = @ptrCast(@alignCast(data.?));
    try context.window.bind(context.io, "answer", answer, null);
    try call.reply("installed");
}
pub fn main(init: std.process.Init) !void {
    var app = webui.App.init(init.gpa, .{});
    defer app.deinit();
    const window = try app.createWindow(.{ .content = .{ .html =
        \\<!doctype html><title>Runtime bindings</title><h1>Runtime bindings</h1>
        \\<button onclick="install()">Install binding and call it</button><output id="result"></output>
        \\<script src="webui.js"></script><script>
        \\async function install() { await webui.call('install'); result.textContent = await webui.answer(); }
        \\</script>
    } });
    var context: Context = .{ .io = init.io, .window = window };
    try window.bind(init.io, "install", install, &context);
    var running = try app.start(init.io);
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
