const std = @import("std");
const mem = std.mem;
const wayland = @import("wayland");

const wl = wayland.client.wl;
const rwm = wayland.client.river;

const utils = @import("utils.zig");
const keybinds = @import("keybinds.zig");
const point_binds = @import("pointer_binds.zig");

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

const InputManager = @import("input/management.zig");
const LibInput = @import("input/libinput.zig");

const Config = @import("config.zig");

const HyprIPC = @import("hyprIPC.zig");

const log = std.log;

var manage_states: Tiler.ManageMap = .empty;

const Registry = struct {
    wm: ?*rwm.WindowManagerV1 = null,
    shell: ?*rwm.LayerShellV1 = null,
    bindings: ?*rwm.XkbBindingsV1 = null,
    input_manager: ?*rwm.InputManagerV1 = null,
    input_config: ?*rwm.LibinputConfigV1 = null,

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
                } else if (mem.orderZ(u8, global.interface, rwm.InputManagerV1.interface.name) == .eq) {
                    context.input_manager = registry.bind(global.name, rwm.InputManagerV1, 1) catch return;
                    std.log.info("registered input manager interface with version {}", .{global.version});
                } else if (mem.orderZ(u8, global.interface, rwm.LibinputConfigV1.interface.name) == .eq) {
                    context.input_config = registry.bind(global.name, rwm.LibinputConfigV1, 1) catch return;
                    std.log.info("registered libinput config interface with version {}", .{global.version});
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
    var states = manage_states.iterator();
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
        ws.manage(&tctx, out_data.getArea(), &manage_states);

        for (ws.floating.keys()) |w| {
            const ms = manage_states.getPtr(w) orelse continue;
            ms.show = true;
        }
    }

    var wins = ctx.wins.iterator();
    while (wins.next()) |_w| {
        const w = _w.key_ptr.*;
        const wd = _w.value_ptr;

        if (wd.float) continue;

        const man_state = manage_states.get(w) orelse {
            log.err("failed to manage window {}", .{w.getId()});
            continue;
        };

        wd.setPos(man_state.position, null);
        wd.setSize(man_state.size, null);
    }
}

fn manage(ctx: *Context) !void {
    if (ctx.input_management.dirty) {
        try ctx.input_management.applyConfig(ctx.config);
        ctx.input_management.dirty = false;
    }
    
    // register new windows
    for (ctx.should_open.items) |win| {
        try Window.assign(ctx, win);
        try manage_states.put(ctx.gpa, win, .{});
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
            switch (op.state) {
                .start => {
                    op.start(op.context, ctx);
                    seat.opStartPointer();
                    op.state = .during;
                },
                .during => {
                    op.update(op.context, ctx, op.delta);
                },
                .end => {
                    seat.opEnd();
                    op.end(op.context, ctx);
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

    // apply window management

    var outs = ctx.outs.iterator();
    while (outs.next()) |_out| {
        const out = _out.key_ptr.*;
        const out_data = _out.value_ptr;

        const ws = ctx.workspaces.get(out_data.workspace).?;

        for (ws.windows.keys()) |win| {
            const wd = ctx.wins.getPtr(win).?;
            const man_state = manage_states.get(win) orelse continue;

            if (!man_state.show) continue;

            switch(wd.fullscreen) {
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

            const col = man_state.border;

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

        for (ws.floating.keys()) |win| {
            const wd = ctx.wins.getPtr(win).?;
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
                .top = true,
                .left = true,
                .right = true,
                .bottom = true,
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

    for (ctx.should_close.items) |w| {
        w.close();
    }
    ctx.should_close.clearAndFree(ctx.gpa);
}

fn render(ctx: *Context) !void {
    const wins = ctx.wins.entries.len;
    if (wins == 0) return;
    const curr_time = std.time.microTimestamp();

    var windows = ctx.wins.iterator();
    while (windows.next()) |_w| {
        const w = _w.key_ptr.*;
        const wd = _w.value_ptr;

        const man_state = manage_states.get(w) orelse continue;

        if (man_state.show) {
            w.show();
        } else {
            w.hide();
            continue;
        }

        const tp = wd.pos.get(curr_time);
        wd.node.setPosition(tp[0], tp[1]);

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

    // put float on top
    var outs = ctx.outs.iterator();
    while (outs.next()) |out| {
        const ws = out.value_ptr.workspace;
        const wsd = ctx.workspaces.get(ws).?;

        for (wsd.floating.keys()) |w| {
            const wd = ctx.wins.getPtr(w).?;
            wd.node.placeTop();
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

    const config = conf: {
        var pathbuf: [std.posix.PATH_MAX]u8 = @splat(0);
        const home = std.posix.getenv("HOME").?;
        const xdg_config_home = std.posix.getenv("XDG_CONFIG_HOME");
        const cfile = try if (xdg_config_home) |xdg|
            std.fmt.bufPrint(&pathbuf, "{s}/river/config.rh", .{xdg})
        else
            std.fmt.bufPrint(&pathbuf, "{s}/.config/river/config.rh", .{home});

        break :conf try std.fs.cwd().openFile(cfile, .{});
    };

    var buffer: [0x100]u8 = undefined;
    var reader_object = config.reader(&buffer);
    var writer = std.fs.File.stdout().writer(&.{});

    const display = try wl.Display.connect(null);
    defer display.disconnect();
    const registry = try display.getRegistry();
    defer registry.destroy();

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
        .input_management = .{
            .manager = try unwrapIFace(reg.input_manager),
            .libinput = try unwrapIFace(reg.input_config),
            .gpa = alloc,
        },
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
    ctx.input_management.manager.setListener(*InputManager, InputManager.listener, &ctx.input_management);
    ctx.input_management.libinput.setListener(*InputManager, LibInput.listener, &ctx.input_management);

    while (ctx.running) {
        if (ctx.dirty) {
            ctx.dirty = false;
            ctx.wm.manageDirty();
        }

        if (display.dispatch() != .SUCCESS) return error.DispatchError;
    }
}
