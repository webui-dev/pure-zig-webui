const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const webui = b.dependency("zig_webui", .{
        .target = target,
        .optimize = optimize,
    }).module("webui");

    const exe = b.addExecutable(.{
        .name = "__NAME__",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "webui", .module = webui }},
        }),
    });
    b.installArtifact(exe);

    // `zig build run` builds the frontend into web/dist and serves it.
    const run = b.addRunArtifact(exe);
    run.setCwd(b.path("."));
    run.addPassthruArgs();
    if (b.findProgram(.{ .names = &.{"npm"} })) |npm| {
        const web = b.addSystemCommand(&.{ npm, "run", "build" });
        web.setCwd(b.path("web"));
        b.step("web", "Build the frontend into web/dist").dependOn(&web.step);
        run.step.dependOn(&web.step);
    } else {
        run.step.dependOn(&b.addFail("npm is required to build the frontend").step);
    }
    b.step("run", "Build the frontend and run the app").dependOn(&run.step);

    // `zig build dev` opens the Vite dev server started by `npm run dev`.
    const dev = b.addRunArtifact(exe);
    dev.setCwd(b.path("."));
    dev.addArg("--dev");
    dev.addPassthruArgs();
    b.step("dev", "Run the app against the Vite dev server (hot reload)").dependOn(&dev.step);
}
