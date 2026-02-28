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
    if (out_data.overlay) |ows| return ows;
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

    if (layt == null) log.err("invalid layout {?s} for workspace {}", .{ layout, id });

    const tiler = try Layouts.new(
        ctx.gpa,
        layt orelse .bsp,
    );

    errdefer Layouts.delete(ctx.gpa, tiler);

    try ctx.workspaces.put(ctx.gpa, id, .{ .tiler = tiler });

    return ctx.workspaces.getPtr(id).?;
}

pub fn addWindow(self: *@This(), ctx: *Tiler.TileContext, win: *rwm.WindowV1) !void {
    try self.tiler.vtable.add(self.tiler.context, ctx, win);
    try self.windows.put(ctx.gpa, win, {});
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

    Layouts.delete(ctx.gpa, self.tiler);

    self.windows.deinit(ctx.gpa);
}

pub fn byWindow(ctx: *Context, win: *rwm.WindowV1) ?WS {
    var iter = ctx.workspaces.iterator();
    while (iter.next()) |_ws| {
        const ws = _ws.key_ptr.*;
        const ws_data = _ws.value_ptr;
        if (ws_data.windows.contains(win) or ws_data.floating.contains(win)) return ws;
    }
    return null;
}

pub fn bySeat(ctx: *Context, seat: *rwm.SeatV1) ?WS {
    const seat_data = ctx.seats.get(seat).?;

    if (seat_data.focus) |f| return byWindow(ctx, f);

    const out = Output.byPointer(ctx, seat_data.pointer_pos) orelse return null;
    const out_data = ctx.outs.get(out).?;
    return out_data.workspace;
}
