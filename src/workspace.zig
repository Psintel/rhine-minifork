const std = @import("std");
const wayland = @import("wayland");
const mem = std.mem;
const log = std.log.scoped(.Workspace);

const wl = wayland.client.wl;
const rwm = wayland.client.river;

const utils = @import("utils.zig");
const Window = @import("window.zig");
const Output = @import("output.zig");
const Context = @import("context.zig");
const Seat = @import("seat.zig");
const Tiler = @import("tiler.zig");
const Tilable = @import("tilable.zig");

const Layouts = @import("layouts.zig");

const Workspace = @This();

pub const WS = i32;

windows: utils.WLHashMap(rwm.WindowV1, void) = .empty,
tiler: Tiler,

// floating windows are not dealt with by the tiler but just naively overlaid
// more complex floating behaviour should go into a custom tiler
floating: utils.WLHashMap(rwm.WindowV1, void) = .empty,

pub fn getFirst(ctx: *Context) WS {
    var start: WS = 0;

    while (getOutput(ctx, start)) |_| start += 1;

    _ = get(ctx, start) catch |e| {
        log.err("failed creating workspace {} with {}", .{ start, e });
        return -1;
    };

    return start;
}

pub fn getOutput(ctx: *Context, ws: WS) ?*rwm.OutputV1 {
    var iter = ctx.outs.iterator();
    while (iter.next()) |o| {
        if (o.value_ptr.workspace == ws) return o.key_ptr.*;
    }

    return null;
}

pub fn byPointer(ctx: *Context, pos: utils.Vec2) ?WS {
    const out = Output.byPointer(ctx, pos) orelse return null;
    const out_data = ctx.outs.get(out).?;
    return out_data.workspace;
}

pub fn get(ctx: *Context, id: WS) !*Workspace {
    var buf: [20]u8 = undefined;
    if (ctx.workspaces.getPtr(id)) |ws| {
        return ws;
    }

    const layoutcfg = try ctx.config.sub("layout");
    const wskey = try std.fmt.bufPrint(&buf, "{}", .{id});
    const layout = try layoutcfg.getSole(wskey) orelse try layoutcfg.getSole("*");

    const layt: ?Layouts.LayoutTypes = if (layout) |l|
        std.meta.stringToEnum(Layouts.LayoutTypes, l)
    else
        null;

    if (layt == null) log.err("invalid layout {?s} for workspace {}", .{layout, id});

    try ctx.workspaces.put(ctx.gpa, id, .{ .tiler = try Layouts.new(
        ctx.gpa,
        layt orelse .bsp,
    ) });

    return ctx.workspaces.getPtr(id).?;
}

pub fn addWindow(self: *@This(), ctx: *Tiler.TileContext, win: *rwm.WindowV1) !void {
    try self.windows.put(ctx.gpa, win, {});
    try self.tiler.vtable.add(self.tiler.context, ctx, win);
}

pub fn rmWindow(self: *@This(), ctx: *Tiler.TileContext, win: *rwm.WindowV1) void {
    if (self.windows.swapRemove(win))
        self.tiler.vtable.remove(self.tiler.context, ctx, win);
}

pub fn manage(self: *@This(), ctx: *Tiler.TileContext, bounds: utils.Rect2, man: *Tiler.ManageMap) void {
    return self.tiler.vtable.manage(self.tiler.context, ctx, bounds, man);
}

pub fn getWindow(self: *@This(), ctx: *Tiler.TileContext, dir: Tiler.Dir) ?*rwm.WindowV1 {
    return self.tiler.vtable.getWindow(self.tiler.context, ctx, dir);
}

pub fn move(self: *@This(), ctx: *Tiler.TileContext, dir: Tiler.Dir) void {
    return self.tiler.vtable.move(self.tiler.context, ctx, dir);
}

pub fn command(self: *@This(), ctx: *Tiler.TileContext, cmd: Tiler.Command) Tiler.Error!void {
    return self.tiler.vtable.command(self.tiler.context, ctx, cmd);
}

pub fn deinit(self: *@This(), ctx: *Context) void {
    var tctx: Tiler.TileContext = .{
        .focus = null,
        .gpa = ctx.gpa,
    };

    for (self.windows.keys()) |w| {
        self.tiler.vtable.remove(self.tiler.context, &tctx, w);
    }

    self.windows.deinit(ctx.gpa);
}
