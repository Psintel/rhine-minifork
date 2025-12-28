const std = @import("std");
const mem = std.mem;
const wayland = @import("wayland");

const wl = wayland.client.wl;
const rwm = wayland.client.river;

const utils = @import("utils.zig");
const keybinds = @import("keybinds.zig");

pub const std_options: std.Options = .{
    .log_level = .info,
};

const Window = @import("window.zig");
const Output = @import("output.zig");
const Seat = @import("seat.zig");
const Context = @import("context.zig");
const Workspace = @import("workspace.zig");
const Tiler = @import("tiler.zig");

const Registry = struct {
    wm: ?*rwm.WindowManagerV1 = null,
    shell: ?*rwm.LayerShellV1 = null,
    bindings: ?*rwm.XkbBindingsV1 = null,

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
                }
            },
            .global_remove => {},
        }
    }
};

fn listen(iface: *rwm.WindowManagerV1, e: rwm.WindowManagerV1.Event, ctx: *Context) void {
    switch (e) {
        .finished => {
            ctx.running = false;
            iface.destroy();
        },
        .window => |args| {
            const win = args.id;
            std.log.info("registered window with id {}", .{win.getId()});
            const data: Window = Window.init(ctx, win) catch return;
            ctx.wins.put(ctx.alloc, win, data) catch return;
            win.setListener(*Context, Window.listener, ctx);
        },
        .output => |args| {
            std.log.info("registerd output with id {}", .{args.id.getId()});
            ctx.outs.put(ctx.alloc, args.id, .{ .workspace = 0 }) catch return;
            args.id.setListener(*Context, Output.listener, ctx);
        },
        .seat => |args| {
            std.log.info("registerd seat with id {}", .{args.id.getId()});
            ctx.seats.put(ctx.alloc, args.id, .{
                .seat = null,
            }) catch return;
            args.id.setListener(*Context, Seat.listener, ctx);
            keybinds.register(ctx, args.id) catch |err|
                std.log.err("{} when trying to register keybinds for seat {}", .{ err, args.id.getId() });
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
    std.log.info("manage event", .{});
    const curr_time = std.time.microTimestamp();

    var seats = ctx.seats.iterator();

    // make sure out internal idea of focus is in-sync
    // with what the compositor knows
    while (seats.next()) |seat| {
        if (ctx.locked) {
            std.log.info("disabling keybinds for seat {}", .{seat.key_ptr.*.getId()});
            for (seat.value_ptr.binds.items) |b| {
                b.disable();
            }
        } else {
            std.log.info("enabling keybinds for seat {}", .{seat.key_ptr.*.getId()});
            for (seat.value_ptr.binds.items) |b| {
                b.enable();
            }
        }

        if (seat.value_ptr.focus) |w| {
            if (!ctx.wins.contains(w)) {
                seat.value_ptr.focus = null;
                continue;
            }

            seat.key_ptr.*.focusWindow(w);
        } else {
            seat.key_ptr.*.clearFocus();
        }
    }

    std.log.info("iterating windows", .{});
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
        win.proposeDimensions(ts.x, ts.y);

        if (!goal.done(curr_time)) {
            ctx.dirty = true;
        } else {
            goal.staticify();
        }
    }

    std.log.info("iterating outputs", .{});

    var outs = ctx.outs.iterator();
    while (outs.next()) |out| {
        const ws = &ctx.workspaces[out.value_ptr.workspace];
        const seat = if (ctx.last_active) |s| ctx.seats.get(s) else null;
        const focus = if (seat) |s| s.focus else null;

        var tctx: Tiler.TileContext = .{
            .winData = ctx.wins,
            .focus = focus,
            .gpa = ctx.alloc,
        };
        try ws.manage(&tctx, .{
            .dim = out.value_ptr.size.?,
            .pos = out.value_ptr.position.?,
        });
    }

    for (ctx.shouldClose.items) |w| {
        w.close();
    }

    ctx.shouldClose.clearAndFree(ctx.alloc);
}

fn render(ctx: *Context) !void {
    std.log.info("render event", .{});
    const wins = ctx.wins.entries.len;
    if (wins == 0) return;
    const curr_time = std.time.microTimestamp();
    std.log.info("curr_time: {}", .{curr_time});

    var outs = ctx.outs.iterator();

    while (outs.next()) |out| {
        const ws = &ctx.workspaces[out.value_ptr.workspace];
        const seat = if (ctx.last_active) |s| ctx.seats.get(s) else null;
        const focus = if (seat) |s| s.focus else null;
        var tctx: Tiler.TileContext = .{
            .winData = ctx.wins,
            .focus = focus,
            .gpa = ctx.alloc,
        };
        try ws.render(&tctx, .{
            .pos = out.value_ptr.position.?,
            .dim = out.value_ptr.size.?,
        });
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
    var gpa = std.heap.GeneralPurposeAllocator(.{}).init;
    defer if (gpa.deinit() == .leak) std.log.err("got a memory leak", .{});

    const display = try wl.Display.connect(null);
    defer display.disconnect();
    const registry = try display.getRegistry();
    defer registry.destroy();

    var reg: Registry = .{};
    registry.setListener(*Registry, Registry.register, &reg);

    if (display.roundtrip() != .SUCCESS) return error.RoundTripFailed;

    var bsp: @import("bsp.zig") = .{};

    var ctx: Context = .{
        .alloc = gpa.allocator(),
        .wm = try unwrapIFace(reg.wm),
        .bind = try unwrapIFace(reg.bindings),
        .shell = try unwrapIFace(reg.shell),
        .workspaces = .{.{
            .tiler = bsp.tiler.get(),
            .id = 0,
        }},
    };
    defer ctx.deinit();

    ctx.wm.setListener(*Context, listen, &ctx);

    while (ctx.running) {
        if (display.roundtrip() != .SUCCESS) return error.DispatchError;
        if (ctx.dirty) {
            ctx.dirty = false;
            ctx.wm.manageDirty();
            std.log.info("dirty state", .{});
        }
    }
}
