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
const Window = @import("window.zig");
const Rules = @import("rules.zig");

const log = std.log.scoped(.window);

win: *rwm.WindowV1,
node: *rwm.NodeV1,

workspace: ?Workspace.WS = null,

app_id: ?[:0]const u8 = null,
size: utils.Vec2 = @splat(0),
float: bool = false, // is this window floating
parent: ?*rwm.WindowV1 = null,
fullscreen: enum {
    no,
    soon,
    yes,
    was,

    pub fn toggle(self: *@This()) void {
        switch (self.*) {
            .no => self.* = .soon,
            .yes => self.* = .was,
            .soon, .was => {},
        }
    }
} = .no,

// will we keep those?
pos: utils.Lerp(100_000) = .{ .static = @splat(0) },
goal_size: utils.Lerp(100_000) = .{ .static = @splat(0) },

// initialize window
pub fn init(_: *Context, win: *rwm.WindowV1) !@This() {
    return .{
        .win = win,
        .node = try win.getNode(),
        .workspace = null,
    };
}

// assign window to workspace and do other setup
// window rules will go here in the future
// assumes that a window context object already exists
pub fn assign(ctx: *Context, win: *rwm.WindowV1) !void {
    const self = ctx.wins.getPtr(win).?;

    const seat = if (ctx.last_active) |s| ctx.seats.get(s) else null;
    var ws: ?Workspace.WS = null;

    const rules = try ctx.config.getList("windowrules");

    for (rules) |rule| {
        const wr: Rules.WindowRule = try .fromEntry(rule);
        if (!wr.match.match(self.app_id orelse "")) continue;
        switch (wr.rule) {
            .float => self.float = true,
            .workspace => |_ws| ws = _ws,
        }
    }

    if (ws == null)
        ws = (if (seat) |s| Workspace.byPointer(ctx, s.pointer_pos) else null) orelse Workspace.getFirst(ctx);

    const cursor = if (seat) |s| Output.relPos(ctx, s.pointer_pos) else null;

    const ws_data: *Workspace = try .get(ctx, ws.?);

    self.workspace = ws;

    if (self.float) {
        if (self.parent) |p| {
            const mics = std.time.microTimestamp();
            const paren = ctx.wins.getPtr(p).?;
            // self.setPos(paren.pos.get(mics) + (paren.size - self.size) / @as(utils.Vec2, @splat(2)), mics);
            self.setPos(paren.pos.get(mics), mics);
        }

        try ws_data.floating.put(ctx.gpa, win, {});
    } else {
        var tctx: Tiler.TileContext = .{
            .focus = if (seat) |s| s.focus else null,
            .cursorPos = cursor,
            .gpa = ctx.gpa,
        };

        try ws_data.addWindow(&tctx, win);
    }
}

pub fn deinit(self: *const @This(), ctx: *Context, win: *rwm.WindowV1) void {
    self.node.destroy();

    const ws = self.workspace orelse return;
    const ws_data = ctx.workspaces.getPtr(ws).?;

    if (self.float) {
        _ = ws_data.floating.swapRemove(win);
    } else {
        var tctx: Tiler.TileContext = .{
            .focus = null, // TODO: fix this
            .gpa = ctx.gpa,
        };

        ws_data.rmWindow(&tctx, win);
    }
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
            win_data.size = .{ d.width, d.height };
        },
        .parent => |p| {
            log.info("window {} has parent {}", .{ win.getId(), p.parent.?.getId() });
            win_data.parent = p.parent;
            win_data.float = true;
        },
        .dimensions_hint => |_| {
            // if (h.min_height == h.max_height and h.min_width == h.max_width) {
            //     win_data.size = .{h.max_width, h.max_height};
            //     log.info("window {} set to floating", .{win.getId()});
            //     // win_data.float = true;
            // } else {
            //     // win_data.float = false;
            // }
        },
        else => {
            log.warn("lmao! can't actually handle event {s}", .{@tagName(event)});
        },
    }
}

pub fn setSize(self: *@This(), new: utils.Vec2, _now: ?i64) void {
    const now = _now orelse time.microTimestamp();

    if (meta.eql(new, self.goal_size.end())) return;

    self.goal_size = .{ .transit = .{
        .from = self.size,
        .to = new,
        .start = now,
    } };
}

pub fn setPos(self: *@This(), new: utils.Vec2, _now: ?i64) void {
    const now = _now orelse time.microTimestamp();

    if (meta.eql(new, self.pos.end())) return;

    self.pos = .{
        .transit = .{
            .from = self.pos.get(now),
            .to = new,
            .start = now,
        },
    };
}

pub fn getWorkspace(ctx: *Context, win: *rwm.WindowV1) ?Workspace.WS {
    var iter = ctx.workspaces.iterator();

    while (iter.next()) |ws| {
        if (ws.value_ptr.windows.contains(win)) return ws.key_ptr.*;
    }

    return null;
}
