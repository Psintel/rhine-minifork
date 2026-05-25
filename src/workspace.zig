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
const Config = @import("config.zig");

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

pub fn byOutput(ctx: *Context, out: *rwm.OutputV1) ?WS {
    const out_data = ctx.outs.get(out).?;
    if (out_data.overlay) |ows| return ows;
    return out_data.workspace;
}

pub fn byPointer(ctx: *Context, pos: utils.Vec2) ?WS {
    const out = Output.byPointer(ctx, pos) orelse return null;
    return byOutput(ctx, out);
}

pub fn get(ctx: *Context, id: WS) !*Workspace {
    var buf: [20]u8 = undefined;
    if (ctx.workspaces.getPtr(id)) |ws| {
        return ws;
    }

    const layoutcfg = try ctx.config.sub("layout");
    const wskey = try std.fmt.bufPrint(&buf, "{}", .{id});
    const layout = try layoutcfg.getSole(wskey) orelse try layoutcfg.getSole("*");

    const layt: ?Layouts.LayoutType = if (layout) |l| std.meta.stringToEnum(Layouts.LayoutType, l) else null;

    if (layt == null) log.err("invalid layout {?s} for workspace {}", .{ layout, id });

    const tiler = try Layouts.new(
        ctx.gpa,
        layt orelse .bsp,
    );

    errdefer Layouts.delete(ctx.gpa, tiler);

    try ctx.workspaces.put(ctx.gpa, id, .{ .tiler = tiler });

    const new = ctx.workspaces.getPtr(id).?;

    if (ctx.config.sub("layout_config")) |cf| {
        new.loadConfig(cf) catch |e| {
            log.err("couldn't apply initial config to ws of tag {}: {}", .{ layt orelse .bsp, e });
        };
    } else |e| {
        log.err("invalid key \"layout_config\": {}", .{e});
    }

    try ctx.ipcChannel.putOneUncancelable(ctx.io, .{ .createworkspace = id });
    try ctx.ipcChannel.putOneUncancelable(ctx.io, .{ .createworkspacev2 = id });
    return new;
}

pub fn addWindow(self: *@This(), ctx: Tiler.TileContext, win: *rwm.WindowV1) !void {
    try self.tiler.vtable.add(self.tiler.context, ctx, win);
    try self.windows.put(ctx.gpa, win, {});
}

pub fn rmWindow(self: *@This(), ctx: Tiler.TileContext, win: *rwm.WindowV1) void {
    if (self.windows.swapRemove(win))
        self.tiler.vtable.remove(self.tiler.context, ctx, win);
}

pub fn manage(self: *@This(), ctx: Tiler.TileContext, bounds: utils.Rect2, man: *Tiler.ManageMap) void {
    return self.tiler.vtable.manage(self.tiler.context, ctx, bounds, man);
}

pub fn getWindow(self: *@This(), ctx: Tiler.TileContext, dir: utils.Dir) ?*rwm.WindowV1 {
    return self.tiler.vtable.getWindow(self.tiler.context, ctx, dir);
}

pub fn move(self: *@This(), ctx: Tiler.TileContext, dir: utils.Dir) Tiler.MoveResult {
    return self.tiler.vtable.move(self.tiler.context, ctx, dir);
}

pub fn setSize(self: *@This(), ctx: Tiler.TileContext, size: utils.Vec2f, anchor: Tiler.Anchor) void {
    return self.tiler.vtable.setSize(self.tiler.context, ctx, size, anchor);
}

pub fn loadConfig(self: *@This(), conf: Config) !void {
    const lc = try conf.sub(@tagName(self.tiler.tag));
    return self.tiler.vtable.loadConfig(self.tiler.context, lc);
}

pub fn command(self: *@This(), ctx: Tiler.TileContext, cmd: Tiler.Command) Tiler.Error!void {
    return self.tiler.vtable.command(self.tiler.context, ctx, cmd);
}

pub fn deinit(self: *@This(), ctx: *Context) void {
    for (self.windows.keys()) |w| {
        self.tiler.vtable.remove(self.tiler.context, .{ .gpa = ctx.gpa }, w);
    }

    Layouts.delete(ctx.gpa, self.tiler);

    self.windows.deinit(ctx.gpa);
    self.floating.deinit(ctx.gpa);
}

pub fn byWindow(ctx: *const Context, win: *rwm.WindowV1) ?WS {
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

pub fn setFloating(self: *@This(), ctx: *Context, win: *rwm.WindowV1) !void {
    if (self.floating.contains(win)) return std.debug.assert(!self.windows.contains(win));

    try self.floating.put(ctx.gpa, win, {});
    self.rmWindow(.{ .gpa = ctx.gpa }, win);
}

pub fn setTiling(self: *@This(), ctx: *Context, win: *rwm.WindowV1) !void {
    if (self.windows.contains(win)) return std.debug.assert(!self.floating.contains(win));

    try self.addWindow(.{ .gpa = ctx.gpa }, win);
    _ = self.floating.swapRemove(win);
}

pub fn isEmpty(self: @This()) bool {
    return self.windows.count() == 0 and self.floating.count() == 0;
}

pub fn getNext(ctx: *Context, current: WS) WS {
    var next: ?Workspace.WS = null;
    for (ctx.workspaces.keys()) |ws| {
        if (ws <= current) continue;
        if (ctx.workspaces.get(ws).?.isEmpty()) continue;

        if (next) |n| {
            if (ws < n) {
                next = ws;
            }
        } else {
            next = ws;
        }
    }
    return next orelse current + 1;
}

pub fn getPrevious(ctx: *Context, current: WS) WS {
    var next: ?Workspace.WS = null;
    for (ctx.workspaces.keys()) |ws| {
        if (ws >= current) continue;
        if (ctx.workspaces.get(ws).?.isEmpty()) continue;

        if (next) |n| {
            if (ws > n) {
                next = ws;
            }
        } else {
            next = ws;
        }
    }
    return next orelse current - 1;
}
