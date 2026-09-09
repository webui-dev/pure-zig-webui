const std = @import("std");
const webui = @import("webui");
pub fn main(init: std.process.Init) !void {
    const probe = std.process.run(init.gpa, init.io, .{
        .argv = &.{ "node", "--version" },
        .stdout_limit = .limited(4096),
        .stderr_limit = .limited(4096),
        .timeout = .{ .duration = .{ .clock = .awake, .raw = .fromSeconds(5) } },
    }) catch |err| {
        std.log.warn("Node.js unavailable: {}", .{err});
        return;
    };
    defer init.gpa.free(probe.stdout);
    defer init.gpa.free(probe.stderr);
    switch (probe.term) {
        .exited => |code| if (code != 0) {
            std.log.warn("Node.js version probe failed", .{});
            return;
        },
        else => return error.RuntimeUnavailable,
    }
    var app = webui.App.init(init.gpa, .{});
    defer app.deinit();
    const window = try app.createWindow(.{ .content = .{ .directory = "examples/runtime/public" }, .runtime = .node_js });
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
