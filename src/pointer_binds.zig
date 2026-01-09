const std = @import("std");
const wayland = @import("wayland");

const meta = std.meta;
const time = std.time;

const wl = wayland.client.wl;
const rwm = wayland.client.river;

const Context = @import("context.zig");
const utils = @import("utils.zig");
const Workspace = @import("workspace.zig");
const Tilable = @import("tilable.zig");
const Tiler = @import("tiler.zig");
const Output = @import("output.zig");

const BTNs = @cImport(@cInclude("linux/input-event-codes.h"));

const log = std.log.scoped(.pointer_gestures);

pub const Trigger = fn (b: *rwm.PointerBindingV1, event: rwm.PointerBindingV1.Event, ctx: *Context) void;
pub const Button = u32;

const State = enum {
    start,
    during,
    end,
};

pub const PointerOp = struct {
    context: ?*anyopaque,
    start: *const fn (?*anyopaque, *Context) void,
    update: *const fn (?*anyopaque, *Context, utils.Vec2) void,
    end: *const fn (?*anyopaque, *Context) void,

    state: State = .start,
    delta: utils.Vec2 = @splat(0),
};

pub const Bind = struct {
    mods: rwm.SeatV1.Modifiers,
    button: Button,
    trigger: *const Trigger,
};

const BindData = struct {
    seat: *rwm.SeatV1,
};

pub var bindDatas: utils.WLHashMap(rwm.PointerBindingV1, BindData) = .empty;

const binds = [_]Bind{
    .{
        .mods = .{ .mod1 = true },
        .button = BTNs.BTN_LEFT,
        .trigger = move.listener,
    },
};

const move = struct {
    const Ctx = struct {
        win: *rwm.WindowV1,
        start: utils.Vec2,
    };

    pub fn listener(bind: *rwm.PointerBindingV1, event: rwm.PointerBindingV1.Event, ctx: *Context) void {
        const seat = bindDatas.get(bind).?.seat;
        const seat_data = ctx.seats.getPtr(seat).?;

        switch (event) {
            .pressed => {
                const win = seat_data.focus orelse return;

                if (seat_data.pointer_op != null) return;

                const ct = ctx.gpa.create(Ctx) catch return;
                ct.win = win;
                ct.start = ctx.wins.get(win).?.pos.get(std.time.microTimestamp());

                seat_data.pointer_op = .{
                    .context = @ptrCast(ct),
                    .start = start,
                    .update = update,
                    .end = end,
                };
            },
            .released => {},
        }
    }

    fn start(_: ?*anyopaque, _: *Context) void {}

    fn update(_win: ?*anyopaque, ctx: *Context, delta: utils.Vec2) void {
        const ptr = _win orelse return;
        const ct: *Ctx = @alignCast(@ptrCast(ptr));
        const win_data = ctx.wins.getPtr(ct.win) orelse return;

        win_data.pos = .{ .static = ct.start + delta };
    }

    fn end(_win: ?*anyopaque, ctx: *Context) void {
        const ptr = _win orelse return;
        const ct: *Ctx = @alignCast(@ptrCast(ptr));
        // const win_data = ctx.wins.getPtr(ct.win) orelse return;


        ctx.gpa.destroy(ct);
    }
};

pub fn register(ctx: *Context, seat: *rwm.SeatV1) !void {
    const sc = ctx.seats.getPtr(seat).?;
    log.info("registering keybinds for seat {}", .{seat.getId()});

    for (binds) |b| {
        const nb = try seat.getPointerBinding(b.button, b.mods);
        try sc.pointer_binds.append(ctx.gpa, nb);
        try bindDatas.put(ctx.gpa, nb, .{
            .seat = seat,
        });
        nb.setListener(*Context, b.trigger, ctx);
    }
}
