const std = @import("std");
const wayland = @import("wayland");
const tributary = @import("tributary");
const mem = std.mem;
const linux = std.os.linux;
const meta = std.meta;
const Io = std.Io;

const wl = wayland.client.wl;
const rwm = wayland.client.river;

const utils = tributary.utils;
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

const Config = tributary.Config;
const HyprIPC = @import("hyprIPC.zig");

const log = std.log.scoped(.window_management);
const clock = Animations.clock;

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

fn apply_tiler(ctx: *Context, curr_time: Io.Timestamp) !void {
    // update workspace manage state from tiler
    var outs = ctx.outs.iterator();
    while (outs.next()) |_out| {
        const out_data = _out.value_ptr;
        const ws = ctx.workspaces.getPtr(out_data.workspace) orelse {
            ctx.dirty = true;
            continue;
        };
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

        ws.manage(
            .{ .gpa = ctx.gpa, .focus = focus },
            out_data.getArea(),
            &ctx.manage_states,
        );

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

fn manage_ws(ctx: *Context, ws: *Workspace, out: *rwm.OutputV1, t: Io.Timestamp) !void {
    const opts = ctx.wm_options;
    var iter = utils.memIter(*rwm.WindowV1, &.{ ws.windows.keys(), ws.floating.keys() });
    while (iter.next()) |win| {
        const wd = ctx.wins.getPtr(win) orelse continue;
        const man_state = ctx.manage_states.get(win) orelse {
            log.err("failed to manage window {}", .{win.getId()});
            ctx.orphan(win);
            continue;
        };

        var col = opts.border.colours.inactive;

        for (ctx.seats.values()) |seat|
            if (seat.focus == win) {
                col = opts.border.colours.focus;
            };

        if (wd.float) {
            // place relative to parent
            if (wd.parent) |p| {
                const paren = ctx.wins.get(p) orelse continue;
                if (meta.activeTag(wd.pos) != .static)
                    wd.setPos(
                        ctx.anims,
                        paren.pos.get(ctx.anims, t) + (paren.size - wd.size) / @as(utils.Vec2, @splat(2)),
                        t,
                    );
            }

            // tell the winsow it's not tiled (for dropshaows and the such)
            win.setTiled(.{
                .top = false,
                .left = false,
                .right = false,
                .bottom = false,
            });
        } else { // tiled
            win.setTiled(.{
                .top = true,
                .left = true,
                .right = true,
                .bottom = true,
            });
        }

        win.setBorders(
            .{ .top = true, .bottom = true, .left = true, .right = true },
            opts.border.width,
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
    }

    for (ws.floating.keys()) |win| {
        const wd = ctx.wins.getPtr(win) orelse continue;
        var col = opts.border.colours.inactive;

        for (ctx.seats.values()) |seat|
            if (seat.focus == win) {
                col = opts.border.colours.focus;
            };

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

        win.setBorders(
            .{ .top = true, .bottom = true, .left = true, .right = true },
            opts.border.width,
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
    errdefer ctx.dirty = true;
    // register new windows
    for (ctx.should_open.items) |win| {
        try Window.assign(ctx, win);
        try ctx.manage_states.put(ctx.gpa, win, .{});
    }
    ctx.should_open.clearAndFree(ctx.gpa);

    // reap workspaces
    var wsiter = ctx.workspaces.iterator();
    while (wsiter.next()) |_ws| {
        const ws = _ws.key_ptr.*;
        const ws_data = _ws.value_ptr;

        // don't delete shown workspaces
        if (Output.byWorkspace(ctx, ws)) |_| continue;
        // don't delete nonempty workspaces
        if (!ws_data.isEmpty()) continue;

        ws_data.deinit(ctx);
        _ = ctx.workspaces.swapRemove(ws);
        wsiter.index -= 1;
        wsiter.len -= 1;
        try ctx.ipcChannel.putOneUncancelable(ctx.io, .{ .destroyworkspace = ws });
        try ctx.ipcChannel.putOneUncancelable(ctx.io, .{ .destroyworkspacev2 = ws });
    }

    const curr_time = clock.now(ctx.io);
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
        cursor: {
            const glob = seat_data.seat orelse break :cursor;
            const wl_seat = ctx.wl_seats.map.get(glob) orelse break :cursor;
            const wl_seat_data = ctx.wl_seats.data.get(wl_seat) orelse break :cursor;
            const pointer = wl_seat_data.capabilities.pointer orelse break :cursor;
            const pointer_data = ctx.pointers.get(pointer) orelse break :cursor;

            // it's ok to give garbage for serial
            pointer_data.cursor_shape.setShape(0, if (seat_data.pointer_op) |op| op.shape else .default);
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

    // set the layer shell default to the output last used by the last active seat
    if (ctx.last_active) |seat| layer_shell_pos: {
        const seat_data = ctx.seats.get(seat) orelse break :layer_shell_pos;
        const out = Output.byPointer(ctx, seat_data.pointer_pos) orelse break :layer_shell_pos;
        const out_data = ctx.outs.get(out) orelse break :layer_shell_pos;
        out_data.shell_out.setDefault();
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
        try manage_ws(ctx, ws, out, curr_time);

        // manage overlay
        if (out_data.overlay) |_overlay| {
            const overlay = try Workspace.get(ctx, _overlay);
            try manage_ws(ctx, overlay, out, curr_time);
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
        // we lose some window space due to borders
        // floating windows are unaffected
        const padding: utils.Vec2 = @splat(if (wd.float) 0 else 2 * ctx.wm_options.border.width);
        const max = @max(goal.max() - padding, wd.size, @as(utils.Vec2, @splat(0)));

        if (goal.done(ctx.anims, curr_time) or Seat.anyPointerOp(ctx)) {
            goal.staticify();
            const ts = @max(goal.get(ctx.anims, curr_time) - padding, @as(utils.Vec2, @splat(0)));
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
    const curr_time = clock.now(ctx.io);

    for (ctx.wins.keys()) |win| win.hide();

    // do workpaces and workspace transitions
    var outs = ctx.outs.iterator();
    while (outs.next()) |out| {
        const outd = out.value_ptr;
        const ws = outd.workspace;

        // render outgoing workspace below active workspace
        if (outd.last_workspace) |prev| if (!outd.ws_pos.done(ctx.anims, curr_time)) {
            render_workspace(
                prev,
                ctx,
                outd.ws_pos.get(ctx.anims, curr_time) - outd.offset(),
                outd.getArea(),
                curr_time,
            );
        };

        // render active workspace
        render_workspace(
            ws,
            ctx,
            outd.ws_pos.get(ctx.anims, curr_time),
            outd.getArea(),
            curr_time,
        );

        // overlay on top
        if (out.value_ptr.overlay) |ov| {
            render_workspace(ov, ctx, @splat(0), outd.getArea(), curr_time);
        }

        if (outd.ws_pos.done(ctx.anims, curr_time)) outd.ws_pos.staticify();
        if (meta.activeTag(outd.ws_pos) == .transit) ctx.dirty = true;
    }
}

fn render_workspace(ws: Workspace.WS, ctx: *Context, offset: utils.Vec2, box: utils.Rect2, curr_time: Io.Timestamp) void {
    const opts = ctx.wm_options;
    const wsd = ctx.workspaces.get(ws) orelse return;

    // floating over non-floating
    var iter = utils.memIter(*rwm.WindowV1, &.{ wsd.windows.keys(), wsd.floating.keys() });

    while (iter.next()) |win| {
        const wd = ctx.wins.get(win) orelse {
            log.err("window {} has no data", .{win});
            continue;
        };
        const man_state = ctx.manage_states.get(win) orelse {
            log.err("window {} has no manage state", .{win});
            continue;
        };

        if (!man_state.show) {
            win.hide();
            continue;
        }

        // space allocated to window
        const rect: utils.Rect2 = .{
            .pos = wd.pos.get(ctx.anims, curr_time) + offset,
            .dim = @max(wd.goal_size.get(ctx.anims, curr_time), @as(utils.Vec2, @splat(0))),
        };

        // space for window contents
        const inner = rect.pad(-@as(i32, opts.border.width)).posDim();
        // how much of the window is visible
        const clip = box.intersect(rect).shift(-inner.pos);

        wd.node.setPosition(inner.pos[0], inner.pos[1]);
        win.setContentClipBox(0, 0, inner.dim[0], inner.dim[1]);
        win.setClipBox(clip.pos[0], clip.pos[1], clip.dim[0], clip.dim[1]);

        if (clip.dim[0] == 0 or clip.dim[1] == 0) {
            win.hide();
        } else {
            win.show();
            wd.node.placeTop();
        }

        if (meta.activeTag(wd.pos) == .transit) ctx.dirty = true;
        if (meta.activeTag(wd.goal_size) == .transit) ctx.dirty = true;
    }

    // put focus on top (if it is in this workspace)
    for (ctx.seats.values()) |seat| {
        if (seat.focus) |f| {
            const focus_data = ctx.wins.get(f) orelse continue;
            if (wsd.windows.contains(f) or wsd.floating.contains(f)) {
                for (wsd.windows.keys()) |w| {
                    const wd = ctx.wins.get(w) orelse continue;
                    focus_data.node.placeAbove(wd.node);
                }

                for (wsd.floating.keys()) |w| {
                    const wd = ctx.wins.get(w) orelse continue;
                    if (focus_data.float)
                        focus_data.node.placeAbove(wd.node)
                    else
                        focus_data.node.placeBelow(wd.node);
                }
            }
        }
    }
}
