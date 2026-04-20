const std = @import("std");
const Build = std.Build;

const Scanner = @import("wayland").Scanner;

pub fn build(b: *Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const tween = b.dependency("mr_tween", .{
        .optimize = optimize,
        .target = target,
    });

    const scanner = Scanner.create(b, .{});

    const wayland = b.createModule(.{
        .root_source_file = scanner.result,
        .target = target,
        .optimize = optimize,
        .strip = b.option(bool, "strip", "strip executable"),
    });

    scanner.addSystemProtocol("staging/cursor-shape/cursor-shape-v1.xml");
    scanner.addSystemProtocol("stable/tablet/tablet-v2.xml");

    const river_protos = rproto: {
        const pkg_config_exe = b.graph.env_map.get("PKG_CONFIG") orelse "pkg-config";
        var code: u8 = undefined;
        const protos_path = b.runAllowFail(&[_][]const u8{
            pkg_config_exe,
            "river-protocols",
            "--variable=pkgdatadir",
        }, &code, .Ignore) catch return error.RiverProtosNotFound;
        break :rproto std.mem.trim(u8, protos_path, &std.ascii.whitespace);
    };

    inline for ([_][]const u8{
        "river-window-management-v1.xml",
        "river-layer-shell-v1.xml",
        "river-xkb-bindings-v1.xml",
    }) |proto| {
        scanner.addCustomProtocol(.{ .cwd_relative = b.pathJoin(&.{ river_protos , "stable", proto}) });
    }

    scanner.generate("wl_seat", 4);
    scanner.generate("wl_output", 4);
    scanner.generate("wl_compositor", 4);
    scanner.generate("river_window_manager_v1", 4);
    scanner.generate("river_layer_shell_v1", 1);
    scanner.generate("river_xkb_bindings_v1", 2);
    scanner.generate("wp_cursor_shape_manager_v1", 1);

    const exe = b.addExecutable(.{
        .name = "rhine",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    exe.root_module.addImport("tween", tween.module("mr_tween"));
    exe.root_module.addImport("wayland", wayland);
    exe.linkLibC();
    exe.linkSystemLibrary("wayland-client");

    b.installArtifact(exe);
    b.installFile("rhine.desktop", "share/wayland-sessions/rhine.desktop");
    const run_cmd = b.addRunArtifact(exe);

    run_cmd.step.dependOn(b.getInstallStep());

    const screen = b.option(u32, "wayland", "sets the WAYLAND_DISPLAY env variable to wayland-[wayland]") orelse 1;
    run_cmd.setEnvironmentVariable("WAYLAND_DISPLAY", b.fmt("wayland-{}", .{screen}));

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);
}
