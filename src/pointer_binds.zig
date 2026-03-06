const std = @import("std");
const wayland = @import("wayland");

const meta = std.meta;
const time = std.time;

const wl = wayland.client.wl;
const rwm = wayland.client.river;

const Context = @import("context.zig");
const utils = @import("utils.zig");
const Window = @import("window.zig");
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

const StartError = error{StartError};

pub const PointerOp = struct {
    context: ?*anyopaque,
    start: *const fn (?*anyopaque, *Context, utils.Vec2) StartError!void,
    update: *const fn (?*anyopaque, *Context, utils.Vec2) void,
    end: *const fn (?*anyopaque, *Context, utils.Vec2) void,

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
        .mods = .{ .mod4 = true },
        .button = BTNs.BTN_LEFT,
        .trigger = move.listener,
    },
};

const move = struct {
    const Ctx = struct {
        win: *rwm.WindowV1,
        start: utils.Vec2,
        pos: utils.Vec2,
    };

    pub fn listener(bind: *rwm.PointerBindingV1, event: rwm.PointerBindingV1.Event, ctx: *Context) void {
        const dat = bindDatas.get(bind) orelse return;
        const seat = dat.seat;
        const seat_data = ctx.seats.getPtr(seat).?;

        switch (event) {
            .pressed => {
                if (seat_data.pointer_op != null) return;

                const ct = ctx.gpa.create(Ctx) catch return;
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

    fn start(_win: ?*anyopaque, ctx: *Context, pos: utils.Vec2) StartError!void {
        const ptr = _win orelse return error.StartError;
        const ct: *Ctx = @ptrCast(@alignCast(ptr));
        errdefer ctx.gpa.destroy(ct);

        const win = Window.byPointer(ctx, pos) orelse return error.StartError;

        ct.* = .{
            .win = win,
            .start = ctx.wins.get(win).?.pos.current(ctx.anims),
            .pos = pos,
        };
    }

    fn update(_win: ?*anyopaque, ctx: *Context, delta: utils.Vec2) void {
        const ptr = _win orelse return;
        const ct: *Ctx = @ptrCast(@alignCast(ptr));
        const win_data = ctx.wins.getPtr(ct.win) orelse return;

        win_data.pos = .{ .static = ct.start + delta };
    }

    fn end(_win: ?*anyopaque, ctx: *Context, final: utils.Vec2) void {
        const ptr = _win orelse return;
        const ct: *Ctx = @ptrCast(@alignCast(ptr));
        defer ctx.gpa.destroy(ct);

        // XXX: this is not multi-monitor aware
        const ws = Workspace.byWindow(ctx, ct.win) orelse return;
        const ws_data = ctx.workspaces.getPtr(ws) orelse return;
        const out = Output.byWorkspace(ctx, ws) orelse return;
        const out_data = ctx.outs.get(out).?;

        if (ws_data.floating.contains(ct.win) or !ws_data.windows.contains(ct.win)) return;
        var tc: Tiler.TileContext = .{
            .gpa = ctx.gpa,
            .cursorPos = (ct.pos + final - out_data.position.?) * utils.Rect2.unit.dim / out_data.size.?,
        };

        ws_data.rmWindow(tc, ct.win);
        tc.focus = Window.byPointer(ctx, ct.pos + final);
        ws_data.addWindow(tc, ct.win) catch {
            log.err("couldn't reinsert window {}", .{ct.win.getId()});
            _ = ws_data.windows.swapRemove(ct.win);
            ctx.orphan(ct.win);
        };
    }
};

pub fn register(ctx: *Context, seat: *rwm.SeatV1) !void {
    const sc = ctx.seats.getPtr(seat).?;
    log.info("registering pointer binds for seat {}", .{seat.getId()});

    for (binds) |b| {
        const nb = try seat.getPointerBinding(b.button, b.mods);
        try sc.pointer_binds.append(ctx.gpa, nb);
        try bindDatas.put(ctx.gpa, nb, .{
            .seat = seat,
        });
        nb.setListener(*Context, b.trigger, ctx);
    }
}

pub fn unregister(ctx: *Context, seat: *rwm.SeatV1) void {
    const seat_data = ctx.seats.getPtr(seat).?;
    for (seat_data.pointer_binds.items) |bind| {
        bind.destroy();
        _ = bindDatas.swapRemove(bind);
    }

    seat_data.pointer_binds.clearAndFree(ctx.gpa);
    if (bindDatas.entries.len == 0) bindDatas.clearAndFree(ctx.gpa);
}
