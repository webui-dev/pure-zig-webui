const std = @import("std");
const webui = @import("webui");
pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len != 3) {
        std.debug.print("Usage: public-tls <certificate.pem> <private-key.pem>\nProvide a trusted certificate for the host clients will visit; none is generated.\n", .{});
        return;
    }
    const certificate = try std.Io.Dir.cwd().readFileAlloc(init.io, args[1], init.gpa, .limited(1 << 20));
    defer init.gpa.free(certificate);
    const private_key = try std.Io.Dir.cwd().readFileAlloc(init.io, args[2], init.gpa, .limited(1 << 20));
    defer init.gpa.free(private_key);
    var app = webui.App.init(init.gpa, .{
        .address = "0.0.0.0",
        .port = 8443,
        .public = true,
        .use_cookies = true,
        .tls = .{ .certificate_pem = certificate, .private_key_pem = private_key },
    });
    defer app.deinit();
    const window = try app.createWindow(.{ .content = .{ .html = "<!doctype html><title>Caller-provided TLS</title><h1>Pure Zig WebUI over TLS</h1><script src='webui.js'></script>" } });
    var running = try app.start(init.io);
    defer running.stop() catch {};
    const url = try window.url(&running, init.gpa);
    defer init.gpa.free(url);
    std.debug.print("Listening: {s}\nUse your certificate's hostname instead of the wildcard listen address. Treat the capability URL as a secret.\n", .{url});
    try running.wait();
}
