const std = @import("std");
const wayland = @import("wayland");

const mem = std.mem;
const meta = std.meta;
const time = std.time;

const wl = wayland.client.wl;
const wp = wayland.client.wp;
const rwm = wayland.client.river;

const Context = @import("context.zig");
const utils = @import("utils.zig");
const Window = @import("window.zig");
const Workspace = @import("workspace.zig");
const Tilable = @import("tilable.zig");
const Tiler = @import("tiler.zig");
const Output = @import("output.zig");

const log = std.log.scoped(.pointer_ops);

const State = enum {
    start,
    during,
    end,
};

const StartError = error{StartError};

const ops = .{
    .move = move,
    .resize = resize,
    .xkill = xkill,
};

pub const OpType = meta.FieldEnum(@TypeOf(ops));
const InteractionType = enum { hold, toggle };

pub const PointerOp = struct {
    context: *anyopaque,
    start: *const fn (*anyopaque, *Context, utils.Vec2) StartError!void,
    update: *const fn (*anyopaque, *Context, utils.Vec2) void,
    end: *const fn (*anyopaque, *Context, utils.Vec2) void,

    state: State = .start,
    delta: utils.Vec2 = @splat(0),
    shape: wp.CursorShapeDeviceV1.Shape = .default,
};

pub fn startOp(ctx: *Context, seat: *rwm.SeatV1, op_type: OpType) !void {
    const seat_data = ctx.seats.getPtr(seat).?;
    if (seat_data.pointer_op != null) return;

    switch (op_type) {
        inline else => |o| {
            const T = @field(ops, @tagName(o));
            const ct = ctx.gpa.create(T.Ctx) catch return;
            seat_data.pointer_op = .{
                .context = @ptrCast(ct),
                .start = T.start,
                .update = T.update,
                .end = T.end,
                .shape = if (@hasDecl(T, "shape")) T.shape else .default,
            };
        },
    }
}

comptime {
    for (meta.fieldNames(@TypeOf(ops))) |f| {
        const pre = "pointer operation of type " ++ f ++ ": ";
        const T = @field(ops, f);
        if (!@hasDecl(T, "Ctx")) {
            @compileError(pre ++ "must contain a declaration \"Ctx\"");
        }
        if (@TypeOf(T.Ctx) != type) @compileError(pre ++ "Ctx must be a type");
    }
}

const move = struct {
    const Ctx = struct {
        win: *rwm.WindowV1,
        start: utils.Vec2,
        pos: utils.Vec2,
    };
    pub const interaction_type: InteractionType = .hold;
    pub const shape: wp.CursorShapeDeviceV1.Shape = .move;

    fn start(_ct: *anyopaque, ctx: *Context, pos: utils.Vec2) StartError!void {
        const ct: *Ctx = @ptrCast(@alignCast(_ct));
        errdefer ctx.gpa.destroy(ct);

        const win = Window.byPointer(ctx, pos) orelse return error.StartError;

        ct.* = .{
            .win = win,
            .start = ctx.wins.get(win).?.pos.current(ctx.anims),
            .pos = pos,
        };
    }

    fn update(_ct: *anyopaque, ctx: *Context, delta: utils.Vec2) void {
        const ct: *Ctx = @ptrCast(@alignCast(_ct));
        const win_data = ctx.wins.getPtr(ct.win) orelse return;

        win_data.pos = .{ .static = ct.start + delta };
    }

    fn end(_ct: ?*anyopaque, ctx: *Context, final: utils.Vec2) void {
        const ct: *Ctx = @ptrCast(@alignCast(_ct));
        defer ctx.gpa.destroy(ct);

        const ws = Workspace.byWindow(ctx, ct.win) orelse return;
        const ws_data = ctx.workspaces.getPtr(ws) orelse return;

        const end_pos = ct.pos + final;

        const to_ws = Workspace.byPointer(ctx, end_pos) orelse return;
        const to_ws_data = ctx.workspaces.getPtr(to_ws) orelse return;

        // floating case
        if (ws_data.floating.swapRemove(ct.win)) {
            to_ws_data.floating.put(ctx.gpa, ct.win, {}) catch ctx.orphan(ct.win);
            return;
        }

        // tiling case
        if (!ws_data.windows.contains(ct.win)) return;

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
    pub const Ctx = struct {
        win: *rwm.WindowV1,
        start: utils.Vec2,
        anchor: Tiler.Anchor,
        win_pos: utils.Vec2,
    };

    pub const interaction_type: InteractionType = .hold;
    pub const shape: wp.CursorShapeDeviceV1.Shape = .all_scroll;

    fn start(_ct: *anyopaque, ctx: *Context, pos: utils.Vec2) StartError!void {
        const ct: *Ctx = @ptrCast(@alignCast(_ct));
        errdefer ctx.gpa.destroy(ct);

        const win = Window.byPointer(ctx, pos) orelse return error.StartError;
        const win_data = ctx.wins.getPtr(win) orelse return error.StartError;
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

        if (win_data.float) return win_data.active_resize.on();

        if (Workspace.byWindow(ctx, win)) |ws| {
            const ws_data = ctx.workspaces.getPtr(ws) orelse return;
            for (ws_data.windows.keys()) |w| {
                const wd = ctx.wins.getPtr(w) orelse continue;
                wd.active_resize.on();
            }
        }
    }

    fn update(_ct: *anyopaque, ctx: *Context, delta: utils.Vec2) void {
        const ct: *Ctx = @ptrCast(@alignCast(_ct));
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
            win_data.goal_size = .{ .static = @max(new_size, @as(utils.Vec2, @splat(1))) };
        } else {
            const ws = out_data.workspace;
            const ws_data = ctx.workspaces.getPtr(ws) orelse return;
            const goal: utils.Vec2f = @floatFromInt(new_size);
            const out_size: utils.Vec2f = @floatFromInt(out_data.size.?);
            ws_data.setSize(.{
                .gpa = ctx.gpa,
                .focus = ct.win,
            }, goal / out_size, ct.anchor);
        }
    }

    fn end(_ct: ?*anyopaque, ctx: *Context, _: utils.Vec2) void {
        const ct: *Ctx = @ptrCast(@alignCast(_ct));
        defer ctx.gpa.destroy(ct);
        const win_data = ctx.wins.getPtr(ct.win) orelse return;

        if (win_data.float) return win_data.active_resize.off();

        if (Workspace.byWindow(ctx, ct.win)) |ws| {
            const ws_data = ctx.workspaces.getPtr(ws) orelse return;
            for (ws_data.windows.keys()) |w| {
                const wd = ctx.wins.getPtr(w) orelse continue;
                wd.active_resize.on();
            }
        }
    }
};

const xkill = struct {
    pub const Ctx = struct {
        start: utils.Vec2,
    };
    pub const interaction_type: InteractionType = .toggle;
    pub const shape: wp.CursorShapeDeviceV1.Shape = .context_menu;

    fn start(_ct: ?*anyopaque, ctx: *Context, pos: utils.Vec2) StartError!void {
        const ptr = _ct orelse return error.StartError;
        const ct: *Ctx = @ptrCast(@alignCast(ptr));
        errdefer ctx.gpa.destroy(ct);

        ct.* = .{
            .start = pos,
        };
    }

    fn update(_: ?*anyopaque, _: *Context, _: utils.Vec2) void {}

    fn end(_ct: ?*anyopaque, ctx: *Context, delta: utils.Vec2) void {
        const ptr = _ct orelse return;
        const ct: *Ctx = @ptrCast(@alignCast(ptr));
        defer ctx.gpa.destroy(ct);

        const win = Window.byPointer(ctx, ct.start + delta) orelse return;
        ctx.should_close.append(ctx.gpa, win) catch |e|
            log.err("failed to mark {} for closure: {}", .{ win.getId(), e });
    }
};
