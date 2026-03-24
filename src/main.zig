const std = @import("std");
const mem = std.mem;
const linux = std.os.linux;
const meta = std.meta;
const log = std.log;

const wayland = @import("wayland");
const wl = wayland.client.wl;
const rwm = wayland.client.river;

const commands = @import("commands.zig");
const helpers = @import("helpers.zig");
const window_managment = @import("window_management.zig");

const Config = @import("config.zig");
const Context = @import("context.zig");
const HyprIPC = @import("hyprIPC.zig");
const Inotify = @import("inotify.zig");
const Layouts = @import("layouts.zig");

pub const std_options: std.Options = .{
    .log_level = .info,
};

const Registry = struct {
    wm: ?*rwm.WindowManagerV1 = null,
    shell: ?*rwm.LayerShellV1 = null,
    bindings: ?*rwm.XkbBindingsV1 = null,

    pub fn register(registry: *wl.Registry, event: wl.Registry.Event, context: *@This()) void {
        switch (event) {
            .global => |global| {
                if (mem.orderZ(u8, global.interface, rwm.WindowManagerV1.interface.name) == .eq) {
                    context.wm = registry.bind(global.name, rwm.WindowManagerV1, 4) catch return;
                    log.info("registered window manager interface with version {}", .{global.version});
                } else if (mem.orderZ(u8, global.interface, rwm.LayerShellV1.interface.name) == .eq) {
                    context.shell = registry.bind(global.name, rwm.LayerShellV1, 1) catch return;
                    log.info("registered layer shell interface with version {}", .{global.version});
                } else if (mem.orderZ(u8, global.interface, rwm.XkbBindingsV1.interface.name) == .eq) {
                    context.bindings = registry.bind(global.name, rwm.XkbBindingsV1, 1) catch return;
                    log.info("registered xkb bindings interface with version {}", .{global.version});
                } else {
                    log.info("not registering interface {s}", .{global.interface});
                }
            },
            .global_remove => {},
        }
    }
};

fn unwrapIFace(iface: anytype) !@TypeOf(iface.?) {
    const Tinfo = @typeInfo(@TypeOf(iface));
    const Top = @typeInfo(Tinfo.optional.child);
    const T = Top.pointer.child;

    return iface orelse {
        log.err("compositor does not seem to support interface {s}", .{T.interface.name});
        return error.ProtocolNotFound;
    };
}

pub fn main() !void {
    var gpa = std.heap.DebugAllocator(.{
        .stack_trace_frames = 1000,
        .retain_metadata = true,
        .safety = true,
        // .verbose_log = true,
        .enable_memory_limit = true,
    }).init;

    gpa.requested_memory_limit = 1_000_000;

    defer if (gpa.deinit() == .leak) log.err("got a memory leak", .{});

    const alloc = gpa.allocator();

    const config_path = path: {
        const home = std.posix.getenv("HOME").?;
        const xdg_config_home = std.posix.getenv("XDG_CONFIG_HOME");
        const cfile = try if (xdg_config_home) |xdg|
            std.fmt.allocPrint(alloc, "{s}/river/config.rh", .{xdg})
        else
            std.fmt.allocPrint(alloc, "{s}/.config/river/config.rh", .{home});
        break :path cfile;
    };
    defer alloc.free(config_path);

    const config = try std.fs.cwd().openFile(config_path, .{});
    var inotify: Inotify = try .init(.{ .nonblock = true });
    defer inotify.deinit();

    const wid = try inotify.watch(config_path, .{ .MODIFY = true });

    var buffer: [0x100]u8 = undefined;
    var reader_object = config.reader(&buffer);

    const display = try wl.Display.connect(null);
    defer display.disconnect();
    const registry = try display.getRegistry();
    defer registry.destroy();

    const read, const write = try std.posix.pipe2(.{ .NONBLOCK = true });

    const event_read = std.fs.File{ .handle = read };
    defer event_read.close();
    var event_reader = event_read.reader(&.{});

    const events: std.fs.File = .{ .handle = write };
    defer events.close();

    var pollfds = [_]linux.pollfd{
        .{
            .events = linux.POLL.IN,
            .fd = display.getFd(),
            .revents = undefined,
        },
        .{
            .events = linux.POLL.IN,
            .fd = read,
            .revents = undefined,
        },
        .{
            .events = linux.POLL.IN,
            .fd = inotify.inot_file.handle,
            .revents = undefined,
        },
    };

    var reg: Registry = .{};
    registry.setListener(*Registry, Registry.register, &reg);

    if (display.roundtrip() != .SUCCESS) return error.RoundTripFailed;

    var ctx: Context = .{
        .gpa = alloc,
        .child_env = try std.process.getEnvMap(alloc),
        .wm = try unwrapIFace(reg.wm),
        .bind = try unwrapIFace(reg.bindings),
        .shell = try unwrapIFace(reg.shell),
        .config = try Config.parse(alloc, &reader_object.interface),
        .events = events,
    };
    defer ctx.deinit();

    const ipc = try HyprIPC.init(&ctx);
    defer ipc.deinit(&ctx);
    const t = try std.Thread.spawn(.{}, HyprIPC.run, .{ ipc, &ctx });
    t.detach();

    try ctx.workspaces.put(ctx.gpa, 0, .{
        .tiler = try Layouts.new(ctx.gpa, .bsp),
    });

    ctx.wm.setListener(*Context, window_managment.listen, &ctx);
    try ctx.reload();
    helpers.startup(&ctx);

    while (ctx.running) {
        {
            var reload_conf = false;
            while (try inotify.nextEvent()) |e| {
                if (e.wd == wid) reload_conf = true;
            }

            if (reload_conf) {
                log.info("reloading config :D", .{});
                try reader_object.seekTo(0);
                const nc = Config.parse(alloc, &reader_object.interface) catch |e| {
                    log.err("failure reloading config: {}", .{e});
                    continue;
                };
                // try nc.serialize(&writer.interface);
                ctx.config.deinit(alloc);
                ctx.config = nc;
                ctx.dirty = true;
                ctx.reload() catch |e| {
                    log.err("failed to reload config: {}", .{e});
                };
            }
        }

        {
            ctx.commands_queue.mutex.lock();
            defer ctx.commands_queue.mutex.unlock();
            while (ctx.commands_queue.list.pop()) |n| {
                const cmd: *commands.QueueItem = @fieldParentPtr("link", n);
                defer ctx.gpa.destroy(cmd);
                try cmd.command.dispatch(&ctx, cmd.seat);
            }
        }

        if (ctx.dirty) {
            ctx.dirty = false;
            ctx.wm.manageDirty();
        }

        if (display.flush() != .SUCCESS) return error.FlushError;

        _ = try std.posix.poll(&pollfds, -1);
        _ = event_reader.interface.discard(.unlimited) catch |e| switch (e) {
            error.ReadFailed => {},
            else => log.err("error on discard: {}", .{e}),
        };

        if (display.prepareRead()) {
            if (display.readEvents() != .SUCCESS)
                return error.ReadEvent;
        }

        if (display.dispatchPending() != .SUCCESS) return error.DispatchError;
    }
}
