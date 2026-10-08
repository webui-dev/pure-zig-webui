const std = @import("std");
const webui = @import("webui");

/// Must match `server.port` in web/vite.config.ts.
const dev_server = "http://localhost:5173/";

fn greet(call: *webui.Call, _: ?*anyopaque) !void {
    var buffer: [256]u8 = undefined;
    try call.reply(try std.fmt.bufPrint(&buffer, "Hello, {s}! Greetings from Zig.", .{
        try call.string(0),
    }));
}

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const dev = for (args[1..]) |arg| {
        if (std.mem.eql(u8, arg, "--dev")) break true;
    } else false;

    var app = webui.App.init(init.gpa, .{});
    defer app.deinit();
    const window = try app.createWindow(.{ .content = if (dev)
        .{ .dev_server = dev_server }
    else
        .{ .directory = "web/dist" } });
    try window.bind(init.io, "greet", greet, null);

    var running = try app.start(init.io);
    defer running.stop() catch {};
    window.open(init.io, &running) catch |err| {
        std.log.warn("could not open a browser: {}", .{err});
        return;
    };
    try running.wait();
}
