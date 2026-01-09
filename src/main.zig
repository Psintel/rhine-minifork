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

const log = std.log;

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
                    context.wm = registry.bind(global.name, rwm.WindowManagerV1, 2) catch return;
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

fn manage(ctx: *Context) !void {
    // register new windows
    for (ctx.should_open.items) |win| {
        try Window.assign(ctx, win);
    }

    ctx.should_open.clearAndFree(ctx.gpa);

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
            switch(op.state) {
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

    var it = ctx.wins.iterator();
    while (it.next()) |w| {
        const win = w.key_ptr.*;
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

        const goal = &w.value_ptr.goal_size;

        const ts = goal.get(curr_time);
        switch (goal.*) {
            .transit => win.informResizeStart(),
            .static => win.informResizeEnd(),
        }
        win.proposeDimensions(ts.x, ts.y);

        if (!goal.done(curr_time)) {
            ctx.dirty = true;
        } else {
            goal.staticify();
        }
    }

    var outs = ctx.outs.iterator();
    while (outs.next()) |out| {
        const ws = ctx.workspaces.getPtr(out.value_ptr.workspace).?;
        const seat = if (ctx.last_active) |s| ctx.seats.get(s) else null;
        const focus = if (seat) |s| s.focus else null;

        var tctx: Tiler.TileContext = .{
            .focus = focus,
            .gpa = ctx.gpa,
        };
        var manages = try ws.manage(&tctx, out.value_ptr.getArea());
        defer manages.clearAndFree(ctx.gpa);

        for (ws.windows.keys()) |w| {
            const wd = ctx.wins.getPtr(w).?;
            const manageState = manages.get(w) orelse {
                log.err("workspace {} failed to manage window {}", .{ out.value_ptr.workspace, w.getId() });
                continue;
            };

            wd.setSize(manageState.size, curr_time);

            const col = manageState.border;
            w.setBorders(
                .{ .top = true, .bottom = true, .left = true, .right = true },
                2,
                col.r,
                col.g,
                col.b,
                col.a,
            );
        }
    }

    for (ctx.shouldClose.items) |w| {
        w.close();
    }

    ctx.shouldClose.clearAndFree(ctx.gpa);
}

fn render(ctx: *Context) !void {
    const wins = ctx.wins.entries.len;
    if (wins == 0) return;
    const curr_time = std.time.microTimestamp();

    for (ctx.wins.keys()) |w| {
        w.hide();
    }

    var outs = ctx.outs.iterator();
    while (outs.next()) |out| {
        const ws = ctx.workspaces.getPtr(out.value_ptr.workspace).?;
        const seat = if (ctx.last_active) |s| ctx.seats.get(s) else null;
        const focus = if (seat) |s| s.focus else null;
        var tctx: Tiler.TileContext = .{
            .focus = focus,
            .gpa = ctx.gpa,
        };
        var renders = try ws.render(&tctx, out.value_ptr.getArea());
        defer renders.clearAndFree(ctx.gpa);

        for (ws.windows.keys()) |w| {
            const wd = ctx.wins.getPtr(w).?;
            const renderState = renders.get(w) orelse {
                log.err("workspace {} failed to render window {}", .{ out.value_ptr.workspace, w.getId() });
                continue;
            };

            if (renderState.show) {
                w.show();
            } else {
                w.hide();
            }

            wd.setPos(renderState.position, curr_time);
        }

        if (focus) |f| ctx.wins.get(f).?.node.placeTop();

        for (ws.floating.keys()) |w| {
            const wd = ctx.wins.getPtr(w).?;

            wd.node.placeTop();
            w.show();
        }
    }

    var windows = ctx.wins.iterator();
    while (windows.next()) |w| {
        const pos = &w.value_ptr.pos;
        const tp = pos.get(curr_time);

        w.value_ptr.node.setPosition(tp.x, tp.y);

        if (!pos.done(curr_time)) {
            ctx.dirty = true;
        } else {
            pos.staticify();
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
        .verbose_log = true,
        .enable_memory_limit = true,
    }).init;

    gpa.requested_memory_limit = 1_000_000;

    defer if (gpa.deinit() == .leak) std.log.err("got a memory leak", .{});

    const alloc = gpa.allocator();

    const display = try wl.Display.connect(null);
    defer display.disconnect();
    const registry = try display.getRegistry();
    defer registry.destroy();

    var reg: Registry = .{};
    registry.setListener(*Registry, Registry.register, &reg);

    if (display.roundtrip() != .SUCCESS) return error.RoundTripFailed;

    var ctx: Context = .{
        .gpa = alloc,
        .wm = try unwrapIFace(reg.wm),
        .bind = try unwrapIFace(reg.bindings),
        .shell = try unwrapIFace(reg.shell),
        .input_management = .{
            .manager = try unwrapIFace(reg.input_manager),
            .libinput = try unwrapIFace(reg.input_config),
            .gpa = alloc,
        },
    };

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
