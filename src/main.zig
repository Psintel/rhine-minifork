const std = @import("std");
const mem = std.mem;
const linux = std.os.linux;
const posix = std.posix;
const meta = std.meta;
const log = std.log;

const wayland = @import("wayland");
const wl = wayland.client.wl;
const rwm = wayland.client.river;
const wp = wayland.client.wp;

const tributary = @import("tributary");

const commands = @import("commands.zig");
const helpers = @import("helpers.zig");
const window_managment = @import("window_management.zig");
const utils = tributary.utils;

const Config = tributary.Config;
const Context = @import("context.zig");
const HyprIPC = @import("hyprIPC.zig");
const Inotify = tributary.inotify;
const SignalListener = tributary.signals;
const Layouts = @import("layouts.zig");
const Seat = @import("seat.zig");
const Notify = tributary.Notify;
const Restore = @import("restore.zig");

pub const std_options: std.Options = .{
    .log_level = .info,
};

const Registry = struct {
    gpa: mem.Allocator,
    wm: ?*rwm.WindowManagerV1 = null,
    shell: ?*rwm.LayerShellV1 = null,
    bindings: ?*rwm.XkbBindingsV1 = null,
    cursor_shape: ?*wp.CursorShapeManagerV1 = null,
    seats: std.AutoArrayHashMapUnmanaged(u32, void) = .empty,
    outs: std.AutoArrayHashMapUnmanaged(u32, void) = .empty,

    pub fn listener(registry: *wl.Registry, event: wl.Registry.Event, context: *@This()) void {
        switch (event) {
            .global => |global| {
                if (utils.handleIface(registry, global, rwm.WindowManagerV1, 4)) |wm| {
                    context.wm = wm;
                    log.info("registered window manager interface with version {}", .{global.version});
                } else if (utils.handleIface(registry, global, rwm.LayerShellV1, 1)) |ls| {
                    context.shell = ls;
                    log.info("registered layer shell interface with version {}", .{global.version});
                } else if (utils.handleIface(registry, global, rwm.XkbBindingsV1, 2)) |xkb| {
                    context.bindings = xkb;
                    log.info("registered xkb bindings interface with version {}", .{global.version});
                } else if (utils.handleIface(registry, global, wp.CursorShapeManagerV1, 1)) |cursor| {
                    context.cursor_shape = cursor;
                    log.info("registered cursor shape interface with version {}", .{global.version});
                } else if (utils.checkIface(global, wl.Seat, 4)) |seat| {
                    context.seats.put(context.gpa, seat, {}) catch return;
                    log.info("remembering seat with version {}", .{global.version});
                } else if (utils.checkIface(global, wl.Output, 4)) |out| {
                    context.outs.put(context.gpa, out, {}) catch return;
                    log.info("remembering out with version {}", .{global.version});
                } else {
                    log.debug("not registering interface {s}", .{global.interface});
                }
            },
            .global_remove => |gr| {
                if (context.seats.swapRemove(gr.name)) {
                    log.info("removed seat {}", .{gr.name});
                } else if (context.outs.swapRemove(gr.name)) {
                    log.info("removed out {}", .{gr.name});
                } else {
                    log.debug("ignored global removal of: {}", .{gr.name});
                }
            },
        }
    }
};

const RegUnion = union(enum) {
    reg: *Registry,
    ctx: *Context,

    pub fn listener(reg: *wl.Registry, event: wl.Registry.Event, un: *@This()) void {
        switch (un.*) {
            .reg => |r| Registry.listener(reg, event, r),
            .ctx => |c| Context.regListener(reg, event, c),
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

pub fn main(init: std.process.Init) !void {
    const alloc = init.gpa;
    const io = init.io;
    const home = init.environ_map.get("HOME").?;
    const cwd = std.Io.Dir.cwd();

    const config_path = path: {
        const xdg_config_home = init.environ_map.get("XDG_CONFIG_HOME");
        const cfile = try if (xdg_config_home) |xdg|
            std.fmt.allocPrint(alloc, "{s}/river/config.rh", .{xdg})
        else
            std.fmt.allocPrint(alloc, "{s}/.config/river/config.rh", .{home});
        break :path cfile;
    };
    defer alloc.free(config_path);

    const config = try cwd.openFile(init.io, config_path, .{});

    var inotify: Inotify = try .init(.{ .nonblock = true });
    defer inotify.deinit(io);

    const wid = try inotify.watch(config_path, .{ .MODIFY = true });

    const signal_listener: SignalListener = try .init(.{
        .CHLD = true,
        .ALRM = true,
        .HUP = true,
        .INT = true,
        .IO = true,
        .KILL = true,
        .PIPE = true,
        .PROF = true,
        .PWR = true,
        .STKFLT = true,
        .TERM = true,
        .USR1 = true,
        .USR2 = true,
        .VTALRM = true,
    }, .{ .NONBLOCK = true });
    defer signal_listener.deinit(io);

    const restorePath = try std.fmt.allocPrint(alloc, "{s}/.cache/rhine.restore", .{home});
    defer alloc.free(restorePath);

    var restore = cwd.openFile(io, restorePath, .{ .mode = .read_write }) catch |e|
        switch (e) {
            error.FileNotFound => try cwd.createFile(io, restorePath, .{ .read = true }),
            else => return e,
        };
    defer restore.close(io);
    var restore_buf: [5 * Restore.buf_size]u8 = undefined;
    var restore_reader = restore.reader(io, &restore_buf);

    var buffer: [0x100]u8 = undefined;
    var reader_object = config.reader(io, &buffer);

    try Notify.init();
    defer Notify.deinit();

    const display = try wl.Display.connect(null);
    defer display.disconnect();
    const registry = try display.getRegistry();
    defer registry.destroy();

    const read, const write = try utils.pipe(.{ .NONBLOCK = true });

    const event_read = std.Io.File{ .handle = read, .flags = .{ .nonblocking = false } };
    defer event_read.close(io);
    var event_reader = event_read.reader(io, &.{});

    const events: std.Io.File = .{ .handle = write, .flags = .{ .nonblocking = false } };
    defer events.close(io);

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
        .{
            .events = linux.POLL.IN,
            .fd = signal_listener.file.handle,
            .revents = undefined,
        },
    };

    var reg: Registry = .{ .gpa = alloc };
    var regU: RegUnion = .{ .reg = &reg };

    registry.setListener(*RegUnion, RegUnion.listener, &regU);

    if (display.roundtrip() != .SUCCESS) return error.RoundTripFailed;

    var queue_buf: [100]HyprIPC.HyprEvent = undefined;

    var ctx: Context = .{
        .gpa = alloc,
        .io = io,
        .child_env = init.environ_map,
        .wm = try unwrapIFace(reg.wm),
        .bind = try unwrapIFace(reg.bindings),
        .shell = try unwrapIFace(reg.shell),
        .cursor_shape = try unwrapIFace(reg.cursor_shape),
        .config = Config.parse(alloc, &reader_object.interface) catch |e| {
            Notify.send(.{
                .summary = "failed to start rhine",
                .body =
                \\failed to load the initial configuration file.
                \\this is most likely due to a missing or invalid config
                ,
                .duration = 0,
                .urgency = .Critical,
            }) catch {};
            std.process.fatal(
                \\failed to load the initial configuration file: {}.
                \\this is most likely due to a missing or invalid config
            , .{e});
        },
        .events = events,
        .ipcChannel = .init(&queue_buf),
        .restore = Restore.deserialize(&restore_reader.interface, alloc) catch |e| res: {
            log.err("failed to read restore info {}", .{e});
            break :res .empty;
        },
    };
    defer ctx.deinit();
    regU = .{ .ctx = &ctx };
    for (reg.seats.keys()) |_seat| try ctx.bindSeat(registry, _seat);
    for (reg.outs.keys()) |_out| try ctx.bindOut(registry, _out);

    const ipc = try HyprIPC.init(&ctx);
    defer ipc.deinit(&ctx);
    const t = try std.Thread.spawn(.{}, HyprIPC.sock1Worker, .{ ipc, &ctx });
    t.detach();
    var fut = try io.concurrent(HyprIPC.sock2Worker, .{ ipc, io, &ctx, &ctx.ipcChannel });
    defer fut.cancel(io) catch |e| log.err("sock2Worker failed with {}", .{e});

    ctx.wm.setListener(*Context, window_managment.listen, &ctx);
    try ctx.reload();
    helpers.startup(&ctx);

    while (ctx.running) {
        while (try signal_listener.readSignal(io)) |sig| {
            switch (@as(std.posix.SIG, @enumFromInt(sig.signo))) {
                .CHLD => {
                    var a: u32 = undefined;
                    _ = linux.waitpid(@intCast(sig.pid), &a, linux.W.NOHANG);
                },
                else => |s| {
                    posix.sigprocmask(posix.SIG.SETMASK, &posix.sigemptyset(), null);

                    var restore_writer = restore.writer(io, &restore_buf);
                    var res: Restore = Restore.fromCtx(&ctx) catch |e| {
                        log.err("failed to collect restore data {}", .{e});
                        return e;
                    };
                    defer res.deinit(ctx.gpa);

                    res.serialize(&restore_writer.interface) catch |e| {
                        log.err("failed to write restore data {}", .{e});
                        return e;
                    };

                    log.info("wrote restore info successfully :)", .{});
                    try std.posix.raise(s);
                },
            }
        }

        {
            var reload_conf = false;
            while (try inotify.nextEvent(io)) |e| {
                if (e.wd == wid) reload_conf = true;
            }

            if (reload_conf) {
                log.info("reloading config :D", .{});
                try reader_object.seekTo(0);
                const nc = Config.parse(alloc, &reader_object.interface) catch |e| {
                    Notify.send(.{
                        .summary = "failure reloading config",
                        .urgency = .Critical,
                    }) catch |ne| log.err("failed to send notification {}", .{ne});
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
            try ctx.commands_queue.mutex.lock(io);
            defer ctx.commands_queue.mutex.unlock(io);
            while (ctx.commands_queue.list.pop()) |n| {
                const cmd: *commands.QueueItem = @fieldParentPtr("link", n);
                defer ctx.gpa.destroy(cmd);
                cmd.command.dispatch(&ctx, cmd.seat) catch |e| {
                    log.err("command dispatch failed with {}", .{e});
                };
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

        if (display.dispatchPending() != .SUCCESS) return error.Dispatch;
    }
}
