const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const linsang = b.dependency("linsang", .{
        .target = target,
        .optimize = optimize,
    }).module("Linsang");

    const webui = b.addModule("webui", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "Linsang", .module = linsang }},
    });

    const tests = b.addTest(.{ .root_module = webui });
    const test_step = b.step("test", "Run unit and integration tests");
    test_step.dependOn(&b.addRunArtifact(tests).step);

    const fuzz_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/protocol.zig"),
            .target = target,
            .optimize = .ReleaseFast,
        }),
        .filters = &.{"protocol parsers tolerate arbitrary input"},
    });
    b.step("fuzz", "Fuzz bounded WebUI protocol parsers").dependOn(&b.addRunArtifact(fuzz_tests).step);

    const bridge_test_step = b.step(
        "test-bridge",
        "Run browser bridge tests (requires Node.js)",
    );
    if (b.findProgram(&.{"node"}, &.{}) catch null) |node| {
        const bridge_tests = b.addSystemCommand(&.{ node, "--test" });
        bridge_tests.addFileArg(b.path("src/bridge.test.js"));
        test_step.dependOn(&bridge_tests.step);
        bridge_test_step.dependOn(&bridge_tests.step);
    } else {
        std.log.warn("Node.js not found; skipping browser bridge tests", .{});
        bridge_test_step.dependOn(&b.addFail(
            "Node.js is required to run browser bridge tests",
        ).step);
    }

    const minimal = b.addExecutable(.{
        .name = "minimal",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/minimal/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "webui", .module = webui }},
        }),
    });
    b.installArtifact(minimal);

    const run = b.addRunArtifact(minimal);
    run.step.dependOn(b.getInstallStep());
    const run_step = b.step("run", "Run the minimal example");
    run_step.dependOn(&run.step);

    for ([_][]const u8{ "bindings", "dynamic-content", "managed-browser", "runtime", "public-tls" }) |name| {
        const example = b.addExecutable(.{
            .name = name,
            .root_module = b.createModule(.{
                .root_source_file = b.path(b.fmt("examples/{s}/main.zig", .{name})),
                .target = target,
                .optimize = optimize,
                .imports = &.{.{ .name = "webui", .module = webui }},
            }),
        });
        b.installArtifact(example);
        const command = b.addRunArtifact(example);
        if (b.args) |args| command.addArgs(args);
        b.step(b.fmt("run-{s}", .{name}), b.fmt("Run {s} example", .{name})).dependOn(&command.step);
    }

    const native_enabled = b.option(bool, "native", "Build the optional native WebView example") orelse false;
    const native_test = b.step("test-native", "Run actual native WebView smoke (requires -Dnative=true)");
    if (native_enabled) {
        const native_module = b.createModule(.{
            .root_source_file = b.path("examples/native/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = target.result.os.tag != .windows,
            .imports = &.{.{ .name = "webui", .module = webui }},
        });
        switch (target.result.os.tag) {
            .macos => {
                native_module.linkSystemLibrary("objc", .{ .needed = true });
                native_module.linkFramework("Foundation", .{ .needed = true });
                native_module.linkFramework("AppKit", .{ .needed = true });
                native_module.linkFramework("WebKit", .{ .needed = true });
            },
            .windows => for ([_][]const u8{ "user32", "gdi32", "ole32", "kernel32", "dwmapi" }) |library|
                native_module.linkSystemLibrary(library, .{}),
            .linux => {},
            else => {},
        }
        const native_example = b.addExecutable(.{ .name = "native", .root_module = native_module });
        b.installArtifact(native_example);
        const native_run = b.addRunArtifact(native_example);
        if (b.args) |args| native_run.addArgs(args);
        b.step("run-native", "Run optional native WebView example").dependOn(&native_run.step);
        const smoke = b.addRunArtifact(native_example);
        smoke.addArg("--smoke");
        if (b.args) |args| smoke.addArgs(args);
        native_test.dependOn(&smoke.step);
    } else {
        native_test.dependOn(&b.addFail("Use -Dnative=true and install the platform WebView runtime").step);
    }
}
