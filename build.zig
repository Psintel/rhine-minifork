const std = @import("std");
const Build = std.Build;

const Scanner = @import("wayland").Scanner;

fn haveSysProtos(b: *Build) bool {
    const pkg_config_exe = b.graph.env_map.get("PKG_CONFIG") orelse "pkg-config";
    var code: u8 = undefined;
    _ = b.runAllowFail(&[_][]const u8{
        pkg_config_exe,
        "river-protocols",
        "--variable=pkgdatadir",
    }, &code, .Ignore) catch return false;
    return true;
}

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

    inline for ([_][]const u8{
        // window management
        "river-window-management-v1.xml",
        "river-layer-shell-v1.xml",
        "river-xkb-bindings-v1.xml",
        // input stuff
        "river-input-management-v1.xml",
        "river-libinput-config-v1.xml",
        "river-xkb-config-v1.xml",
    }) |proto| {
            scanner.addSystemProtocol("../river-protocols/stable/" ++ proto);
    }

    scanner.generate("wl_seat", 4);
    scanner.generate("wl_output", 4);
    // scanner.generate("xdg_wm_base", 3);
    // scanner.generate("ext_session_lock_manager_v1", 1);

    scanner.generate("river_window_manager_v1", 4);
    scanner.generate("river_layer_shell_v1", 1);
    scanner.generate("river_xkb_bindings_v1", 2);

    scanner.generate("river_input_manager_v1", 1);
    scanner.generate("river_libinput_config_v1", 1);
    scanner.generate("river_xkb_config_v1", 1);
    scanner.generate("wp_cursor_shape_manager_v1", 1);

    const docs_obj = b.addObject(.{
        .name = "wayland",
        .root_module = wayland,
    });

    const doc_cmd = b.addSystemCommand(&.{
        "python",
        "-m",
        "http.server",
        "8080",
        "--bind",
        "127.0.0.1",
        "--directory",
    });

    doc_cmd.addDirectoryArg(docs_obj.getEmittedDocs());

    b.step("show-wayland", "Show docs for generated wayland bindings").dependOn(&doc_cmd.step);

    const install_docs = b.addInstallDirectory(.{
        .install_dir = .prefix,
        .install_subdir = "docs", // will also be the main namespace in the docs
        .source_dir = docs_obj.getEmittedDocs(),
    });

    b.step("docs", "Build docs").dependOn(&install_docs.step);

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
