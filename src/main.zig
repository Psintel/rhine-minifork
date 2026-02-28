const std = @import("std");
const mem = std.mem;
const wayland = @import("wayland");
const linux = std.os.linux;

const wl = wayland.client.wl;
const rwm = wayland.client.river;

const utils = @import("utils.zig");
const helpers = @import("helpers.zig");
const keybinds = @import("keybinds.zig");
const point_binds = @import("pointer_binds.zig");
const commands = @import("commands.zig");

pub const std_options: std.Options = .{
    .log_level = .info,
};

const Window = @import("window.zig");
const Output = @import("output.zig");
const Seat = @import("seat.zig");
const Context = @import("context.zig");
const Workspace = @import("workspace.zig");
const Tiler = @import("tiler.zig");
const Layouts = @import("layouts.zig");

const LibInput = @import("input/libinput.zig");
const Config = @import("config.zig");
const HyprIPC = @import("hyprIPC.zig");
const Inotify = @import("inotify.zig");

const log = std.log;

const Registry = struct {
    wm: ?*rwm.WindowManagerV1 = null,
    shell: ?*rwm.LayerShellV1 = null,
    bindings: ?*rwm.XkbBindingsV1 = null,

    pub fn register(registry: *wl.Registry, event: wl.Registry.Event, context: *@This()) void {
        switch (event) {
            .global => |global| {
                if (mem.orderZ(u8, global.interface, rwm.WindowManagerV1.interface.name) == .eq) {
                    context.wm = registry.bind(global.name, rwm.WindowManagerV1, 3) catch return;
                    std.log.info("registered window manager interface with version {}", .{global.version});
                } else if (mem.orderZ(u8, global.interface, rwm.LayerShellV1.interface.name) == .eq) {
                    context.shell = registry.bind(global.name, rwm.LayerShellV1, 1) catch return;
                    std.log.info("registered layer shell interface with version {}", .{global.version});
                } else if (mem.orderZ(u8, global.interface, rwm.XkbBindingsV1.interface.name) == .eq) {
                    context.bindings = registry.bind(global.name, rwm.XkbBindingsV1, 1) catch return;
                    std.log.info("registered xkb bindings interface with version {}", .{global.version});
                } else {
                    log.info("not registering interface {s}", .{global.interface});
                }
            },
            .global_remove => {},
        }
    }
};

fn listen(iface: *rwm.WindowManagerV1, event: rwm.WindowManagerV1.Event, ctx: *Context) void {
    switch (event) {
        .finished => {
            ctx.running = false;
            iface.destroy();
        },
        .window => |args| {
            const win = args.id;
            const data: Window = Window.init(ctx, win) catch return;

            ctx.wins.put(ctx.gpa, win, data) catch |e| {
                log.err("failed to create window context {}", .{e});
                return;
            };
            win.setListener(*Context, Window.listener, ctx);

            ctx.should_open.append(ctx.gpa, win) catch return;

            std.log.info("registered window with id {}", .{win.getId()});
        },
        .output => |args| {
            std.log.info("registerd output with id {}", .{args.id.getId()});
            Output.init(ctx, args.id) catch |e| {
                std.log.err("failed to init output with error {}", .{e});
            };
        },
        .seat => |args| {
            std.log.info("registerd seat with id {}", .{args.id.getId()});
            ctx.seats.put(ctx.gpa, args.id, .{
                .seat = null,
            }) catch return;
            args.id.setListener(*Context, Seat.listener, ctx);
            keybinds.register(ctx, args.id) catch |err|
                std.log.err("{} when trying to register keybinds for seat {}", .{ err, args.id.getId() });
            point_binds.register(ctx, args.id) catch |err|
                std.log.err("{} when trying to register pointbinds for seat {}", .{ err, args.id.getId() });
        },
        .session_locked => {
            ctx.locked = true;
        },
        .session_unlocked => {
            ctx.locked = false;
        },
        .manage_start => {
            manage(ctx) catch |err| std.log.err("manage failed with error {}", .{err});
            iface.manageFinish();
        },
        .render_start => {
            render(ctx) catch |err| std.log.err("render failed with error {}", .{err});
            iface.renderFinish();
        },
        .unavailable => {
            std.log.info("Window Management unavailable", .{});
            ctx.running = false;
        },
    }
}

fn apply_tiler(ctx: *Context) !void {
    var states = ctx.manage_states.iterator();
    while (states.next()) |rs| {
        rs.value_ptr.show = false;
    }

    // update workspace manage state from tiler
    var outs = ctx.outs.iterator();
    while (outs.next()) |_out| {
        const out_data = _out.value_ptr;
        const ws = ctx.workspaces.getPtr(out_data.workspace).?;
        const seat = if (ctx.last_active) |s| ctx.seats.getPtr(s) else null;
        const focus = if (seat) |s| s.focus else null;

        if (focus) |f| {
            if (!ctx.wins.contains(f)) seat.?.focus = null;
        }


        var tctx: Tiler.TileContext = .{
            .focus = focus,
            .gpa = ctx.gpa,
        };

        for (ws.floating.keys()) |w| {
            const wd = ctx.wins.getPtr(w) orelse continue;
            if (!wd.float) {
                try ws.addWindow(&tctx, w);
                _ = ws.floating.swapRemove(w);
            }
        }

        for (ws.windows.keys()) |w| {
            const wd = ctx.wins.getPtr(w) orelse continue;
            if (wd.float) {
                try ws.floating.put(ctx.gpa, w, {});
                ws.rmWindow(&tctx, w);
            }

        }

        ws.manage(&tctx, out_data.getArea(), &ctx.manage_states);

        if (out_data.overlay) |_ows| {
            const ows = try Workspace.get(ctx, _ows);
            ows.manage(&tctx, out_data.getArea().scale(0.95), &ctx.manage_states);
            for (ows.windows.keys()) |win| {
                const data = ctx.manage_states.getPtr(win) orelse continue;
                data.dims = data.dims.scale(0.95);
            }
        }

        for (ws.floating.keys()) |w| {
            const ms = ctx.manage_states.getPtr(w) orelse continue;
            ms.show = true;
        }
    }

    var wins = ctx.wins.iterator();
    while (wins.next()) |_w| {
        const w = _w.key_ptr.*;
        const wd = _w.value_ptr;

        if (wd.float) continue;

        const man_state = ctx.manage_states.get(w) orelse {
            log.err("failed to manage window {}", .{w.getId()});
            continue;
        };

        wd.setPos(man_state.dims.pos, null);
    }
}

fn manage_ws(ctx: *Context, ws: *Workspace, out: *rwm.OutputV1, curr_time: i64) void {
    for (ws.windows.keys()) |win| {
        const wd = ctx.wins.getPtr(win) orelse continue;
        const man_state = ctx.manage_states.get(win) orelse {
            log.err("failed to manage window {}", .{win.getId()});
            ctx.orphan(win);
            continue;
        };

        if (!man_state.show) continue;

        switch (wd.fullscreen) {
            .no, .yes => {},
            .soon => {
                win.fullscreen(out);
                win.informFullscreen();
                wd.fullscreen = .yes;
            },
            .was => {
                win.exitFullscreen();
                win.informNotFullscreen();
                wd.fullscreen = .no;
            },
        }

        var col = man_state.border;
        for (ctx.seats.values(), 0..) |s, i| {
            if (win == s.focus) {
                if (i == 1)
                    col = .green;
            }
        }

        win.setBorders(
            .{ .top = true, .bottom = true, .left = true, .right = true },
            2,
            col.r,
            col.g,
            col.b,
            col.a,
        );

        win.setCapabilities(.{
            .window_menu = false,
            .maximize = false,
            .minimize = false,
            .fullscreen = false,
        });
        win.useSsd();
        win.setTiled(.{
            .top = true,
            .left = true,
            .right = true,
            .bottom = true,
        });

        if (wd.setSize(man_state.dims.dim, curr_time))
            win.informResizeStart();

        const goal = &wd.goal_size;
        const ts = @max(goal.get(curr_time), @as(utils.Vec2, @splat(0)));

        win.proposeDimensions(ts[0], ts[1]);

        if (goal.done(curr_time)) {
            win.informResizeEnd();
            goal.staticify();
        } else {
            ctx.dirty = true;
        }
    }

    for (ws.floating.keys()) |win| {
        const wd = ctx.wins.getPtr(win) orelse continue;
        const col: utils.Color = .gray;

        win.setBorders(
            .{ .top = true, .bottom = true, .left = true, .right = true },
            2,
            col.r,
            col.g,
            col.b,
            col.a,
        );

        win.setCapabilities(.{
            .window_menu = false,
            .maximize = false,
            .minimize = false,
            .fullscreen = false,
        });
        win.useSsd();
        win.setTiled(.{
            .top = false,
            .left = false,
            .right = false,
            .bottom = false,
        });

        const goal = &wd.goal_size;
        const ts = goal.get(curr_time);
        switch (goal.*) {
            .transit => win.informResizeStart(),
            .static => win.informResizeEnd(),
        }

        win.proposeDimensions(ts[0], ts[1]);

        if (!goal.done(curr_time)) {
            ctx.dirty = true;
        } else {
            goal.staticify();
        }
    }
}

fn manage(ctx: *Context) !void {
    // register new windows
    for (ctx.should_open.items) |win| {
        try Window.assign(ctx, win);
        try ctx.manage_states.put(ctx.gpa, win, .{});
    }
    ctx.should_open.clearAndFree(ctx.gpa);

    try apply_tiler(ctx);

    const curr_time = std.time.microTimestamp();
    // make sure out internal seat data is in-sync
    // with what the compositor knows
    var seats = ctx.seats.iterator();
    while (seats.next()) |_seat| {
        const seat = _seat.key_ptr.*;
        const seat_data = _seat.value_ptr;

        if (ctx.locked) {
            for (seat_data.binds.items) |b| b.disable();
            for (seat_data.pointer_binds.items) |b| b.disable();
        } else {
            for (seat_data.binds.items) |b| b.enable();
            for (seat_data.pointer_binds.items) |b| b.enable();
        }

        if (seat_data.pointer_op) |*op| {
            op: switch (op.state) {
                .start => {
                    op.start(op.context, ctx, seat_data.pointer_pos) catch {
                        log.err("failed to start pointer op", .{});
                        seat_data.pointer_op = null;
                        break :op;
                    };
                    seat.opStartPointer();
                    op.state = .during;
                },
                .during => {
                    op.update(op.context, ctx, op.delta);
                },
                .end => {
                    seat.opEnd();
                    op.end(op.context, ctx, op.delta);
                    seat_data.pointer_op = null;
                },
            }
        }

        window_warp: {
            if (seat_data.warp_to_window) |w| {
                const wd = ctx.wins.get(w) orelse {
                    seat_data.warp_to_window = null;
                    break :window_warp;
                };

                const size = wd.goal_size.get(curr_time);
                const pos = wd.pos.get(curr_time);
                const two: utils.Vec2 = @splat(2);

                const center = pos + size / two;
                seat.pointerWarp(center[0], center[1]);

                if (std.meta.activeTag(wd.pos) == .static)
                    seat_data.warp_to_window = null;
            }
        }

        if (seat_data.focus) |w| {
            if (!ctx.wins.contains(w)) {
                seat_data.focus = null;
                continue;
            }

            seat.focusWindow(w);
        } else {
            seat.clearFocus();
        }
    }

    for (ctx.should_close.items) |w| {
        _ = ctx.manage_states.swapRemove(w);
        w.close();
    }
    ctx.should_close.clearAndFree(ctx.gpa);

    // apply window management

    var outs = ctx.outs.iterator();
    while (outs.next()) |_out| {
        const out = _out.key_ptr.*;
        const out_data = _out.value_ptr;

        const ws = try Workspace.get(ctx, out_data.workspace);
        manage_ws(ctx, ws, out, curr_time);

        // manage overlay
        if (out_data.overlay) |_overlay| {
            const overlay = try Workspace.get(ctx, _overlay);
            manage_ws(ctx, overlay, out, curr_time);
        }
    }
}

fn render(ctx: *Context) !void {
    const wins = ctx.wins.entries.len;
    if (wins == 0) return;
    const curr_time = std.time.microTimestamp();

    var windows = ctx.wins.iterator();
    while (windows.next()) |_w| {
        const w = _w.key_ptr.*;
        const wd = _w.value_ptr;

        const man_state = ctx.manage_states.get(w) orelse continue;

        if (man_state.show) {
            w.show();
        } else {
            w.hide();
            continue;
        }

        const tp = wd.pos.get(curr_time);
        wd.node.setPosition(tp[0], tp[1]);
        wd.node.placeTop();

        if (!wd.pos.done(curr_time)) {
            ctx.dirty = true;
        } else {
            wd.pos.staticify();
        }
    }

    // put focus on top
    var seats = ctx.seats.iterator();
    while (seats.next()) |_seat| {
        // const seat = _seat.key_ptr.*;
        const seat_data = _seat.value_ptr;

        if (seat_data.focus) |f| {
            const f_data = ctx.wins.get(f).?;
            f_data.node.placeTop();
        }
    }

    var outs = ctx.outs.iterator();
    while (outs.next()) |out| {
        const ws = out.value_ptr.workspace;
        const wsd = ctx.workspaces.get(ws).?;

        // put float on top
        for (wsd.floating.keys()) |w| {
            const wd = ctx.wins.getPtr(w).?;
            wd.node.placeTop();
        }

        // overlay on top
        if (out.value_ptr.overlay) |ov| {
            const ov_data = try Workspace.get(ctx, ov);
            for (ov_data.windows.keys()) |win| {
                const wind = ctx.wins.get(win).?;
                wind.node.placeTop();
            }
            for (ov_data.floating.keys()) |win| {
                const wind = ctx.wins.get(win).?;
                wind.node.placeTop();
            }
        }
    }
}

fn unwrapIFace(iface: anytype) !@TypeOf(iface.?) {
    const Tinfo = @typeInfo(@TypeOf(iface));
    const Top = @typeInfo(Tinfo.optional.child);
    const T = Top.pointer.child;

    return iface orelse {
        std.log.err("compositor does not seem to support interface {s}", .{T.interface.name});
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

    defer if (gpa.deinit() == .leak) std.log.err("got a memory leak", .{});

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
    var writer = std.fs.File.stderr().writer(&.{});

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

    const ipc = try HyprIPC.init(&ctx);
    defer ipc.deinit(&ctx);
    const t = try std.Thread.spawn(.{}, HyprIPC.run, .{ ipc, &ctx });
    t.detach();

    try ctx.config.serialize(&writer.interface);

    try ctx.workspaces.put(ctx.gpa, 0, .{
        .tiler = try Layouts.new(ctx.gpa, .bsp),
    });

    defer ctx.deinit();

    ctx.wm.setListener(*Context, listen, &ctx);
    try ctx.loadEnv();
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
                try ctx.reload();
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
