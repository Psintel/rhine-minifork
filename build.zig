const std = @import("std");
const Build = std.Build;

const Scanner = @import("wayland").Scanner;

pub fn build(b: *Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const river = b.dependency("river", .{});
    const protos = river.path("protocol");

    const scanner = Scanner.create(b, .{});

    const wayland = b.createModule(.{
        .root_source_file = scanner.result,
        .target = target,
        .optimize = optimize,
        .strip = b.option(bool, "strip", "strip executable"),
    });

    // scanner.addSystemProtocol("stable/xdg-shell/xdg-shell.xml");
    // scanner.addSystemProtocol("staging/ext-session-lock/ext-session-lock-v1.xml");
    scanner.addCustomProtocol(protos.path(b, "river-window-management-v1.xml"));
    scanner.addCustomProtocol(protos.path(b, "river-layer-shell-v1.xml"));
    scanner.addCustomProtocol(protos.path(b, "river-xkb-bindings-v1.xml"));
    scanner.addCustomProtocol(protos.path(b, "river-input-management-v1.xml"));
    scanner.addCustomProtocol(protos.path(b, "river-libinput-config-v1.xml"));
    // scanner.addCustomProtocol(protos.path(b, "river-window-management-v1.xml"));

    // Pass the maximum version implemented by your wayland server or client.
    // Requests, events, enums, etc. from newer versions will not be generated,
    // ensuring forwards compatibility with newer protocol xml.
    // This will also generate code for interfaces created using the provided
    // global interface, in this example wl_keyboard, wl_pointer, xdg_surface,
    // xdg_toplevel, etc. would be generated as well.
    scanner.generate("wl_seat", 4);
    scanner.generate("wl_output", 4);
    // scanner.generate("xdg_wm_base", 3);
    // scanner.generate("ext_session_lock_manager_v1", 1);
    scanner.generate("river_window_manager_v1", 3);
    scanner.generate("river_layer_shell_v1", 1);
    scanner.generate("river_xkb_bindings_v1", 2);
    scanner.generate("river_input_manager_v1", 1);
    scanner.generate("river_libinput_config_v1", 1);

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
