const std = @import("std");
const wayland = @import("wayland");
const mem = std.mem;

const wl = wayland.client.wl;
const rwm = wayland.client.river;

const utils = @import("utils.zig");
const Window = @import("window.zig");
const Output = @import("output.zig");
const Context = @import("context.zig");
const Seat = @import("seat.zig");
const Tiler = @import("tiler.zig");
const Tilable = @import("tilable.zig");

const Workspace = @This();

pub const WS = u32;

windows: std.ArrayList(*rwm.WindowV1) = .empty,
tiler: Tiler,
id: WS,

pub fn getId(self: *@This()) u32 {
    return self.id;
}

pub fn addWindow(self: *@This(), ctx: *Tiler.TileContext, win: *rwm.WindowV1) !void {
    try self.windows.append(ctx.gpa, win);
    try self.tiler.vtable.add(self.tiler.context, ctx, win);
}

pub fn rmWindow(self: *@This(), ctx: *Tiler.TileContext, win: *rwm.WindowV1) void {
    var ind: ?usize = null;
    for (0.., self.windows.items) |i, w| {
        if (w == win) ind = i;
    }
    if (ind) |i| _ = self.windows.swapRemove(i);
    self.tiler.vtable.remove(self.tiler.context, ctx, win);
}

pub fn manage(self: *@This(), ctx: *Tiler.TileContext, bounds: utils.Rect2) Tiler.Error!void {
    return self.tiler.vtable.manage(self.tiler.context, ctx, bounds);
}

pub fn render(self: *@This(), ctx: *Tiler.TileContext, bounds: utils.Rect2) Tiler.Error!void {
    return self.tiler.vtable.render(self.tiler.context, ctx, bounds);
}

pub fn getWindow(self: *@This(), ctx: *Tiler.TileContext, dir: Tiler.Dir) ?*rwm.WindowV1 {
    return self.tiler.vtable.getWindow(self.tiler.context, ctx, dir);
}

pub fn move(self: *@This(), ctx: *Tiler.TileContext, dir: Tiler.Dir) void {
    return self.tiler.vtable.move(self.tiler.context, ctx, dir);
}

pub fn deinit(self: *@This(), ctx: *Context) void {
    var tctx: Tiler.TileContext = .{
        .winData = ctx.wins,
        .focus = null,
        .gpa = ctx.alloc,
    };

    for (self.windows.items) |w| {
        self.tiler.vtable.remove(self.tiler.context, &tctx, w);
    }

    self.windows.deinit(ctx.alloc);
}
