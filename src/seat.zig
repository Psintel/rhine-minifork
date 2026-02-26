const std = @import("std");
const wayland = @import("wayland");
const utils = @import("utils.zig");

const wl = wayland.client.wl;
const rwm = wayland.client.river;

const Context = @import("context.zig");
const Output = @import("output.zig");
const Window = @import("window.zig");
const Workspace = @import("workspace.zig");
const keybinds = @import("keybinds.zig");
const pointerbinds = @import("pointer_binds.zig");

const log = std.log.scoped(.seat);

seat: ?u32, // unsure what this is supposed to be
focus: ?*rwm.WindowV1 = null,
pointer_pos: utils.Vec2 = @splat(0),

binds: std.ArrayListUnmanaged(*rwm.XkbBindingV1) = .empty,

pointer_binds: std.ArrayList(*rwm.PointerBindingV1) = .empty,

// warp pointer to focus in next manage
warp_to_window: ?*rwm.WindowV1 = null,

pointer_op: ?pointerbinds.PointerOp = null,

pub fn listener(seat: *rwm.SeatV1, e: rwm.SeatV1.Event, ctx: *Context) void {
    const seat_data = ctx.seats.getPtr(seat).?;

    ctx.last_active = seat;

    switch (e) {
        .wl_seat => |wl_seat| {
            std.log.info("associating seat with seat", .{});
            const mod = ctx.seats.getPtr(seat).?;
            mod.seat = wl_seat.name;
        },
        .window_interaction => |win| {
            if (win.window) |w| {
                log.info("window {} has been interacted with by {}", .{ w.getId(), seat.getId() });
                seat_data.focus = w;
            }
        },
        .pointer_enter => |win| {
            if (win.window) |w| {


                const ws = Workspace.byWindow(ctx, w) orelse {
                    log.err("seat {}: pointer entered window {} without workspace", .{seat.getId(), w.getId()});
                    return;
                };

                const out = Output.byWorkspace(ctx, ws) orelse {
                    log.err("seat {}: pointer entered window {} shown on no output", .{seat.getId(), w.getId()});
                    return;
                };

                const out_data = ctx.outs.getPtr(out) orelse return;

                // don't focus non-overlay windows when overlay is active
                if (out_data.overlay != null and out_data.overlay != ws) return;

                seat_data.focus = w;
            }
        },
        .pointer_leave => {},
        .pointer_position => |pos| {
            seat_data.pointer_pos = .{ pos.x, pos.y };
        },
        .removed => {
            seat_data.deinit(ctx, seat);
        },
        .op_delta => |d| {
            if (seat_data.pointer_op) |*op| {
                op.delta = .{ d.dx, d.dy };
            }
        },
        .op_release => {
            if (seat_data.pointer_op) |*op| {
                op.state = .end;
            }
        },
        else => {
            log.warn("lmao! can't actually handle event {s}", .{@tagName(e)});
        },
    }
}

pub fn deinit(_: *@This(), ctx: *Context, seat: *rwm.SeatV1) void {
    keybinds.unregister(ctx, seat);
    pointerbinds.unregister(ctx, seat);
}
