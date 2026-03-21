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

pub const Button = u32;

const State = enum {
    start,
    during,
    end,
};

const StartError = error{StartError};

const ops = .{
    .move = move,
    .resize = resize,
};

pub const OpType = meta.FieldEnum(@TypeOf(ops));

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
    op_type: OpType,
};

const BindData = struct {
    seat: *rwm.SeatV1,
    op_type: OpType,
};

pub var bindDatas: utils.WLHashMap(rwm.PointerBindingV1, BindData) = .empty;

const binds = [_]Bind{ .{
    .mods = .{ .mod4 = true },
    .button = BTNs.BTN_LEFT,
    .op_type = .move,
}, .{
    .mods = .{ .mod4 = true, .shift = true },
    .button = BTNs.BTN_LEFT,
    .op_type = .resize,
} };

pub fn listener(bind: *rwm.PointerBindingV1, event: rwm.PointerBindingV1.Event, ctx: *Context) void {
    const dat = bindDatas.get(bind) orelse return;
    const seat = dat.seat;
    const seat_data = ctx.seats.getPtr(seat).?;
    const op = dat.op_type;

    switch (event) {
        .pressed => {
            if (seat_data.pointer_op != null) return;

            switch (op) {
                inline else => |o| {
                    const T = @field(ops, @tagName(o));
                    const ct = ctx.gpa.create(T.Ctx) catch return;
                    seat_data.pointer_op = .{
                        .context = @ptrCast(ct),
                        .start = T.start,
                        .update = T.update,
                        .end = T.end,
                    };
                },
            }
        },
        .released => {},
    }
}

const move = struct {
    const Ctx = struct {
        win: *rwm.WindowV1,
        start: utils.Vec2,
        pos: utils.Vec2,
    };

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

        const end_pos = ct.pos + final;

        const to_ws = Workspace.byPointer(ctx, end_pos) orelse return;
        const to_ws_data = ctx.workspaces.getPtr(to_ws) orelse return;

        if (ws_data.floating.contains(ct.win) or !ws_data.windows.contains(ct.win)) return;
        var tc: Tiler.TileContext = .{
            .gpa = ctx.gpa,
            .cursorPos = Output.relPos(ctx, end_pos),
        };

        ws_data.rmWindow(tc, ct.win);
        tc.focus = Window.byPointer(ctx, end_pos);
        to_ws_data.addWindow(tc, ct.win) catch {
            log.err("couldn't reinsert window {}", .{ct.win.getId()});
            _ = ws_data.windows.swapRemove(ct.win);
            ctx.orphan(ct.win);
        };
    }
};

const resize = struct {
    const Ctx = struct {
        win: *rwm.WindowV1,
        start: utils.Vec2,
        anchor: Tiler.Anchor,
        win_pos: utils.Vec2,
    };

    fn start(_win: ?*anyopaque, ctx: *Context, pos: utils.Vec2) StartError!void {
        const ptr = _win orelse return error.StartError;
        const ct: *Ctx = @ptrCast(@alignCast(ptr));
        errdefer ctx.gpa.destroy(ct);

        const win = Window.byPointer(ctx, pos) orelse return error.StartError;
        const win_data = ctx.wins.get(win) orelse return error.StartError;
        const win_pos = win_data.pos.get(ctx.anims, std.time.milliTimestamp());
        const dir = pos - win_pos - win_data.size / @as(utils.Vec2, @splat(2));

        ct.* = .{
            .win = win,
            .start = win_data.size,
            .win_pos = win_pos,
            .anchor = .{
                .h = if (dir[0] >= 0) .left else .right,
                .v = if (dir[1] >= 0) .top else .bottom,
            },
        };
        log.info("starting resize op", .{});
    }

    fn update(_win: ?*anyopaque, ctx: *Context, delta: utils.Vec2) void {
        const ptr = _win orelse return;
        const ct: *Ctx = @ptrCast(@alignCast(ptr));
        const win_data = ctx.wins.getPtr(ct.win) orelse return;
        const out = Output.byWindow(ctx, ct.win) orelse return;
        const out_data = ctx.outs.getPtr(out) orelse return;
        const dir = utils.Vec2{
            if (ct.anchor.h == .left) 1 else -1,
            if (ct.anchor.v == .top) 1 else -1,
        };

        const new_size = ct.start + dir * delta;

        if (win_data.float) {
            log.info("resizing floating win", .{});
            const mpos: utils.Vec2 = .{
                if (ct.anchor.h == .right) 1 else 0,
                if (ct.anchor.v == .bottom) 1 else 0,
            };
            win_data.pos = .{ .static = ct.win_pos + mpos * delta };
            win_data.size = @max(new_size, @as(utils.Vec2, @splat(1)));
        } else {
            const ws = out_data.workspace;
            const ws_data = ctx.workspaces.getPtr(ws) orelse return;
            const goal: utils.Vec2f = @floatFromInt(new_size);
            const out_size: utils.Vec2f = @floatFromInt(out_data.size.?);
            win_data.goal_size = .{ .static = new_size };
            ws_data.setSize(.{
                .gpa = ctx.gpa,
                .focus = ct.win,
            }, goal / out_size, ct.anchor);
        }
    }

    fn end(_win: ?*anyopaque, ctx: *Context, _: utils.Vec2) void {
        const ptr = _win orelse return;
        const ct: *Ctx = @ptrCast(@alignCast(ptr));
        defer ctx.gpa.destroy(ct);
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
            .op_type = b.op_type,
        });
        nb.setListener(*Context, listener, ctx);
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
