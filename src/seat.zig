const std = @import("std");
const mem = std.mem;
const wayland = @import("wayland");
const utils = @import("utils.zig");

const wl = wayland.client.wl;
const wp = wayland.client.wp;
const rwm = wayland.client.river;

const Context = @import("context.zig");
const Output = @import("output.zig");
const Window = @import("window.zig");
const Pointer = @import("pointer.zig");
const Workspace = @import("workspace.zig");
const Config = @import("config.zig");
const keybinds = @import("keybinds.zig");
const pointerbinds = @import("pointer_binds.zig");
const pointer_operations = @import("pointer_ops.zig");

const log = std.log.scoped(.seat);

pub const Wl = struct {
    const Caps = struct {
        pointer: ?*wl.Pointer = null,
        keyboard: bool = false,
        touch: bool = false,
    };

    global: u32,
    name: ?[]const u8 = null,
    capabilities: Caps = .{},

    pub fn listener(seat: *wl.Seat, e: wl.Seat.Event, ctx: *Context) void {
        const data = ctx.wl_seats.data.getPtr(seat) orelse return;
        switch (e) {
            .capabilities => |c| {
                if (c.capabilities.pointer) {
                    if (data.capabilities.pointer == null) {
                        const ptr = seat.getPointer() catch return;
                        Pointer.init(ctx, ptr) catch return;
                        data.capabilities.pointer = ptr;
                    }
                } else {
                    if (data.capabilities.pointer) |pt| {
                        if (ctx.pointers.fetchSwapRemove(pt)) |ptr_data| ptr_data.value.deinit();
                        pt.release();
                    }
                    data.capabilities.pointer = null;
                }

                data.capabilities.keyboard = c.capabilities.keyboard;
                data.capabilities.touch = c.capabilities.touch;
            },
            .name => |n| data.name = ctx.gpa.dupe(u8, std.mem.sliceTo(n.name, 0)) catch null,
        }
    }

    pub fn deinit(self: Wl, gpa: mem.Allocator) void {
        if (self.name) |n| gpa.free(n);
    }
};

seat: ?u32 = null,
focus: ?*rwm.WindowV1 = null,
pointer_pos: utils.Vec2 = @splat(0),

binds: std.ArrayListUnmanaged(*rwm.XkbBindingV1) = .empty,
pointer_binds: std.ArrayList(*rwm.PointerBindingV1) = .empty,

// warp pointer to focus in next manage
warp_to_window: ?*rwm.WindowV1 = null,
pointer_op: ?pointer_operations.PointerOp = null,

pub fn listener(seat: *rwm.SeatV1, e: rwm.SeatV1.Event, ctx: *Context) void {
    const seat_data = ctx.seats.getPtr(seat).?;

    ctx.last_active = seat;

    switch (e) {
        .wl_seat => |wl_seat| {
            std.log.info("associating seat with seat", .{});
            seat_data.seat = wl_seat.name;
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
                    log.err("seat {}: pointer entered window {} without workspace", .{ seat.getId(), w.getId() });
                    return;
                };

                const out = Output.byWorkspace(ctx, ws) orelse {
                    log.err("seat {}: pointer entered window {} shown on no output", .{ seat.getId(), w.getId() });
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
            } else {
                seat.opEnd();
            }
        },
        .op_release => {
            if (seat_data.pointer_op) |*op| {
                op.state = .end;
            } else {
                seat.opEnd();
            }
        },
        else => {
            log.warn("lmao! can't actually handle event {s}", .{@tagName(e)});
        },
    }
}

pub fn byFocus(ctx: *Context, win: *rwm.WindowV1) ?*rwm.SeatV1 {
    var iter = ctx.seats.iterator();
    while (iter.next()) |_seat| {
        const seat = _seat.key_ptr.*;
        const seat_data = _seat.value_ptr;

        if (seat_data.focus == win) return seat;
    }

    return null;
}

pub fn setup(seat: *rwm.SeatV1, ctx: *Context) !void {
    const xcursor = try ctx.config.sub("xcursor");
    const name = if (try xcursor.getArgs("theme")) |a| a.args else ctx.child_env.get("XCURSOR_THEME");
    const size = if (try xcursor.getArgs("size")) |s| s.args else ctx.child_env.get("XCURSOR_SIZE");

    if (name) |n| if (size) |s| {
        var buff: [0xff]u8 = @splat(0);
        var fb = std.heap.FixedBufferAllocator.init(&buff);
        const theme = try fb.allocator().dupeZ(u8, n);
        log.info("{}: set cursor theme to {s}, {s}", .{ seat.getId(), n, s });
        seat.setXcursorTheme(theme, try std.fmt.parseInt(u32, s, 0));
    };
}

pub fn anyPointerOp(ctx: *Context) bool {
    for (ctx.seats.values()) |s| {
        if (s.pointer_op) |_| return true;
    }
    return false;
}

pub fn deinit(_: *@This(), ctx: *Context, seat: *rwm.SeatV1) void {
    keybinds.unregister(ctx, seat);
    pointerbinds.unregister(ctx, seat);
}
