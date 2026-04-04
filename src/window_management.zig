const std = @import("std");
const mem = std.mem;
const wayland = @import("wayland");
const linux = std.os.linux;
const meta = std.meta;

const wl = wayland.client.wl;
const rwm = wayland.client.river;

const utils = @import("utils.zig");
const helpers = @import("helpers.zig");
const keybinds = @import("keybinds.zig");
const point_binds = @import("pointer_binds.zig");
const commands = @import("commands.zig");
const Animations = @import("animations.zig");

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

const Config = @import("config.zig");
const HyprIPC = @import("hyprIPC.zig");
const Inotify = @import("inotify.zig");

const log = std.log.scoped(.window_management);

pub fn listen(iface: *rwm.WindowManagerV1, event: rwm.WindowManagerV1.Event, ctx: *Context) void {
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

            log.info("registered window with id {}", .{win.getId()});
        },
        .output => |args| {
            log.info("registerd output with id {}", .{args.id.getId()});
            Output.init(ctx, args.id) catch |e| {
                log.err("failed to init output with error {}", .{e});
            };
        },
        .seat => |args| {
            log.info("registerd seat with id {}", .{args.id.getId()});
            ctx.seats.put(ctx.gpa, args.id, .{
                .seat = null,
            }) catch return;
            Seat.setup(args.id, ctx) catch |err|
                log.err("{} when trying to apply config for seat {}", .{ err, args.id.getId() });

            args.id.setListener(*Context, Seat.listener, ctx);
            keybinds.registerAll(ctx, args.id) catch |err|
                log.err("{} when trying to register keybinds for seat {}", .{ err, args.id.getId() });
            point_binds.register(ctx, args.id) catch |err|
                log.err("{} when trying to register pointbinds for seat {}", .{ err, args.id.getId() });
        },
        .session_locked => {
            ctx.locked = true;
        },
        .session_unlocked => {
            ctx.locked = false;
        },
        .manage_start => {
            manage(ctx) catch |err| log.err("manage failed with error {}", .{err});
            iface.manageFinish();
        },
        .render_start => {
            render(ctx) catch |err| log.err("render failed with error {}", .{err});
            iface.renderFinish();
        },
        .unavailable => {
            log.info("Window Management unavailable", .{});
            ctx.running = false;
        },
    }
}

fn apply_tiler(ctx: *Context, curr_time: i64) !void {
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

        // this stays until I figure out a better way of doing this
        out_data.shell_out.setDefault();

        for (ws.floating.keys()) |w| {
            const wd = ctx.wins.getPtr(w) orelse continue;
            if (!wd.float) {
                try ws.addWindow(.{ .gpa = ctx.gpa, .focus = focus }, w);
                _ = ws.floating.swapRemove(w);
            }
        }

        for (ws.windows.keys()) |w| {
            const wd = ctx.wins.getPtr(w) orelse continue;
            if (wd.float) {
                try ws.floating.put(ctx.gpa, w, {});
                ws.rmWindow(.{ .gpa = ctx.gpa, .focus = focus }, w);
            }
        }

        ws.manage(.{ .gpa = ctx.gpa, .focus = focus }, out_data.getArea(), &ctx.manage_states);

        if (out_data.overlay) |_ows| {
            const ows = try Workspace.get(ctx, _ows);
            ows.manage(.{ .gpa = ctx.gpa, .focus = focus }, out_data.getArea().scale(0.95), &ctx.manage_states);
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

        const man_state = ctx.manage_states.getPtr(w) orelse {
            log.err("failed to manage window {}", .{w.getId()});
            continue;
        };

        if (@reduce(.Or, man_state.dims.dim < @as(utils.Vec2, @splat(0)))) man_state.show = false;

        wd.setPos(ctx.anims, man_state.dims.pos, curr_time);
        wd.setSize(man_state.dims.dim, curr_time);
    }
}

fn manage_ws(ctx: *Context, ws: *Workspace, out: *rwm.OutputV1, t: i64) void {
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
            .fullscreen = true,
        });
        win.useSsd();
        win.setTiled(.{
            .top = true,
            .left = true,
            .right = true,
            .bottom = true,
        });
    }

    for (ws.floating.keys()) |win| {
        const col: utils.Color = .gray;
        const wd = ctx.wins.getPtr(win) orelse continue;

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

        if (wd.parent) |p| {
            const paren = ctx.wins.get(p) orelse continue;
            if (meta.activeTag(wd.pos) != .static)
            wd.setPos(
                ctx.anims,
                paren.pos.get(ctx.anims, t) + (paren.size - wd.size) / @as(utils.Vec2, @splat(2)),
                t,
            );
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
            .top = false,
            .left = false,
            .right = false,
            .bottom = false,
        });
    }
}

fn manage(ctx: *Context) !void {
    // register new windows
    for (ctx.should_open.items) |win| {
        try Window.assign(ctx, win);
        try ctx.manage_states.put(ctx.gpa, win, .{});
    }
    ctx.should_open.clearAndFree(ctx.gpa);

    const curr_time = std.time.microTimestamp();

    try apply_tiler(ctx, curr_time);

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
            if (seat_data.pointer_op) |_| break :window_warp;

            if (seat_data.warp_to_window) |w| {
                const wd = ctx.wins.get(w) orelse {
                    seat_data.warp_to_window = null;
                    break :window_warp;
                };

                const size = wd.goal_size.get(ctx.anims, curr_time);
                const pos = wd.pos.get(ctx.anims, curr_time);
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
        if (ctx.wins.contains(w)) w.close();
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

    // manage size and position
    var wins = ctx.wins.iterator();
    while (wins.next()) |_w| {
        const win = _w.key_ptr.*;
        const wd = _w.value_ptr;

        switch (wd.active_resize) {
            .yes, .no => {},
            .soon => {
                wd.active_resize = .yes;
                win.informResizeStart();
            },
            .was => {
                wd.active_resize = .no;
                win.informResizeEnd();
            },
        }

        const goal = &wd.goal_size;
        const max = @max(goal.max(), wd.size, @as(utils.Vec2, @splat(0)));

        if (goal.done(ctx.anims, curr_time) or Seat.anyPointerOp(ctx)) {
            goal.staticify();
            const ts = @max(goal.get(ctx.anims, curr_time), @as(utils.Vec2, @splat(0)));
            win.proposeDimensions(ts[0], ts[1]);
        } else if (@reduce(.Or, wd.size < max)) {
            win.proposeDimensions(max[0], max[1]);
        }

        if (wd.pos.done(ctx.anims, curr_time) or Seat.anyPointerOp(ctx)) {
            wd.pos.staticify();
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

        const tp = wd.pos.get(ctx.anims, curr_time);
        const size: utils.Vec2 = @max(wd.goal_size.get(ctx.anims, curr_time), @as(utils.Vec2, @splat(0)));

        wd.node.setPosition(tp[0], tp[1]);
        w.setContentClipBox(0, 0, size[0], size[1]);
        wd.node.placeTop();

        if (meta.activeTag(wd.pos) == .transit) ctx.dirty = true;
        if (meta.activeTag(wd.goal_size) == .transit) ctx.dirty = true;
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
            const wd = ctx.wins.getPtr(w) orelse continue;
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
