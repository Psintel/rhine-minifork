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

const log = std.log.scoped(.window);

win: *rwm.WindowV1,
node: *rwm.NodeV1,

workspace: Workspace.WS,

app_id: ?[:0]const u8 = null,
size: utils.Vec2 = undefined,

// will we keep those?
pos: utils.Lerp(100_000) = .{ .static = .{ .x = 0, .y = 0 } },
goal_size: utils.Lerp(100_000) = .{ .static = .{ .x = 0, .y = 0 } },

pub fn init(ctx: *Context, win: *rwm.WindowV1) !@This() {
    const seat = if (ctx.last_active) |s| ctx.seats.get(s) else null;
    var cursor: ?utils.Vec2 = null;
    const ws = ws: {
        if (seat) |s| {
            const pos = s.pointer_pos;

            const out = Output.byPointer(ctx, pos) orelse break :ws null;
            const out_data = ctx.outs.get(out).?;
            cursor = pos.sub(out_data.position.?).elmul( utils.Rect2.unit.dim ).eldivT(out_data.size.?);
            break :ws out_data.workspace;
        }

        break :ws null;
    } orelse Workspace.getFirst(ctx);


    var tctx: Tiler.TileContext = .{
        .focus = if (seat) |s| s.focus else null,
        .cursorPos = cursor,
        .gpa = ctx.gpa,
    };

    try ctx.workspaces.getPtr(ws).?.addWindow(&tctx, win);

    return .{
        .win = win,
        .node = try win.getNode(),
        .workspace = ws,
    };
}

pub fn deinit(self: *const @This(), ctx: *Context, win: *rwm.WindowV1) void {
    self.node.destroy();

    const ws = ctx.workspaces.getPtr(self.workspace).?;

    var tctx: Tiler.TileContext = .{
        .focus = null, // TODO: fix this
        .gpa = ctx.gpa,
    };

    ws.rmWindow(&tctx, win);
}

pub fn listener(win: *rwm.WindowV1, event: rwm.WindowV1.Event, ctx: *Context) void {
    const win_data = ctx.wins.getPtr(win).?;

    switch (event) {
        .closed => {
            const full = ctx.wins.fetchSwapRemove(win).?;
            full.value.deinit(ctx, full.key);
            full.key.destroy();
            log.info("closed window with id {}", .{win.getId()});
        },
        .app_id => |app_id| {
            win_data.app_id = std.mem.sliceTo(app_id.app_id, 0);
            log.info("{} has app_id {?s}", .{ win.getId(), win_data.app_id });
        },
        .dimensions => |d| {
            win_data.size = .{
                .x = d.width,
                .y = d.height,
            };
        },
        .parent => {
            @panic("parents are not allowed");
        },
        else => {
            log.warn("lmao! can't actually handle event {s}", .{@tagName(event)});
        },
    }
}

pub fn setSize(self: *@This(), new: utils.Vec2) void {
    switch (self.goal_size) {
        .transit => return,
        .static => |s| {
            if (meta.eql(new, s)) return;

            self.goal_size = .{ .transit = .{
                .from = s,
                .to = new,
                .start = time.microTimestamp(),
            } };
        },
    }
}

pub fn setPos(self: *@This(), new: utils.Vec2) void {
    switch (self.pos) {
        .transit => return,
        .static => |s| {
            if (meta.eql(s, new)) return;
            self.pos = .{ .transit = .{
                .from = s,
                .to = new,
                .start = time.microTimestamp(),
            } };
        },
    }
}

pub fn getWorkspace(ctx: *Context, win: *rwm.WindowV1) ?Workspace.WS {
    var iter = ctx.workspaces.iterator();

    while (iter.next()) |ws| {
        if (ws.value_ptr.windows.contains(win)) return ws.key_ptr.*;
    }

    return null;
}
