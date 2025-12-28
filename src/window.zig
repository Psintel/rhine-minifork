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

const log = std.log.scoped(.window);

win: *rwm.WindowV1,
node: *rwm.NodeV1,

workspace: u32,

app_id: ?[:0]const u8 = null,
size: utils.Vec2 = undefined,

tilable: Tilable.embed(@This()) = .{},

// will we keep those?
pos: utils.Lerp(1) = .{ .static = .{ .x = 0, .y = 0 } },
goal_size: utils.Lerp(1) = .{ .static = .{ .x = 0, .y = 0 } },

pub fn init(ctx: *Context, win: *rwm.WindowV1) !@This() {
    const output = ctx.outs.entries.get(0); // XXX: fix this
    const ws = output.value.workspace;
    const seat = if (ctx.last_active) |l| ctx.seats.get(l) else null;

    var cursor: ?utils.Vec2 = null;

    if (seat) |s| {
        cursor = s.pointer_pos.sub(output.value.position.?).elmul(utils.Rect2.unit.dim).eldivT(output.value.size.?);
    }

    var tctx: Tiler.TileContext = .{
        .winData = ctx.wins,
        .focus = if (seat) |s| s.focus else null,
        .cursorPos = cursor,
        .gpa = ctx.alloc,
    };
    try ctx.workspaces[ws].addWindow(&tctx, win);
    return .{
        .win = win,
        .node = try win.getNode(),
        .workspace = ws,
    };
}

pub fn deinit(self: *const @This(), ctx: *Context, win: *rwm.WindowV1) void {
    self.node.destroy();

    const ws = &ctx.workspaces[self.workspace];

    var tctx: Tiler.TileContext = .{
        .winData = ctx.wins,
        .focus = null, // TODO: fix this
        .gpa = ctx.alloc,
    };

    ws.rmWindow(&tctx, win);
}

pub fn listener(win: *rwm.WindowV1, e: rwm.WindowV1.Event, ctx: *Context) void {
    const win_data = ctx.wins.getPtr(win).?;

    switch (e) {
        .closed => {
            const full = ctx.wins.fetchSwapRemove(win).?;
            full.value.deinit(ctx, full.key);
            full.key.destroy();
            log.info("closed window with id {}", .{win.getId()});
        },
        .app_id => |app_id| {
            win_data.app_id = std.mem.sliceTo(app_id.app_id, 0);
            log.info("{} has app_id {?s}", .{win.getId(), win_data.app_id});
        },
        .dimensions => |d| {
            win_data.size = .{
                .x = d.width,
                .y = d.height,
            };
        },
        .parent => {
            std.debug.assert(false);
        },
        else => {
            log.warn("lmao! can't actually handle event {s}", .{@tagName(e)});
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

    // self.win.proposeDimensions(new.x, new.y);
}

pub fn getSize(self: *@This()) utils.Vec2 {
    return self.size;
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
