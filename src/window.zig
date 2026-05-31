const std = @import("std");
const wayland = @import("wayland");
const tributary = @import("tributary");

const mem = std.mem;
const meta = std.meta;
const time = std.time;

const wl = wayland.client.wl;
const rwm = wayland.client.river;

const Context = @import("context.zig");
const utils = tributary.utils;
const Workspace = @import("workspace.zig");
const Tilable = @import("tilable.zig");
const Tiler = @import("tiler.zig");
const Output = @import("output.zig");
const Window = @import("window.zig");
const Rules = @import("rules.zig");
const Animations = @import("animations.zig");
const Io = std.Io;

const clock = Animations.clock;

const log = std.log.scoped(.window);

node: *rwm.NodeV1,

app_id: ?[]const u8 = null,
title: ?[]const u8 = null,
size: utils.Vec2 = @splat(1),
float: bool = false, // is this window floating
parent: ?*rwm.WindowV1 = null,
fullscreen: utils.Transaction = .no,
unreliable_pid: ?i32 = null,
identifier: [32]u8 = @splat(0),

// will we keep those?
pos: Animations.Lerp(.move) = .{ .static = @splat(0) },
goal_size: Animations.Lerp(.resize) = .{ .static = @splat(0) },
active_resize: utils.Transaction = .no,

// initialize window
pub fn init(_: *Context, win: *rwm.WindowV1) !@This() {
    return .{
        .node = try win.getNode(),
    };
}

// assign window to workspace and do other setup
// window rules will go here in the future
// assumes that a window context object already exists
pub fn assign(ctx: *Context, win: *rwm.WindowV1) !void {
    const self = ctx.wins.getPtr(win).?;

    const seat = if (ctx.last_active) |s| ctx.seats.get(s) else null;
    var ws: ?Workspace.WS = null;

    if (ctx.restore.relations.get(self.identifier)) |data| {
        ws = data.workspace;
        _ = ctx.restore.relations.swapRemove(self.identifier);
    }

    const rules = try ctx.config.getList("windowrules");

    for (rules) |rule| {
        const wr = rule.parseT(Rules.WindowRule) catch |err| {
            log.err("failed to parse window rule \"{s}\" with {}", .{ rule.args, err });
            continue;
        };
        if (!wr.match.match(self.app_id orelse "")) continue;
        switch (wr.rule) {
            .float => self.float = true,
            .nofloat => self.float = false,
            .workspace => |_ws| ws = _ws,
        }
    }

    if (ws == null)
        ws = ws: {
            if (seat) |s| {
                if (Workspace.byPointer(ctx, s.pointer_pos)) |pt| break :ws pt;
                if (s.focus) |f| if (Workspace.byWindow(ctx, f)) |fc| break :ws fc;
            }

            break :ws Workspace.getFirst(ctx);
        };

    const cursor = if (seat) |s| Output.relPos(ctx, s.pointer_pos) else null;

    const ws_data: *Workspace = try .get(ctx, ws.?);

    if (self.float) {
        if (self.parent) |p| {
            const mics = clock.now(ctx.io);
            const paren = ctx.wins.getPtr(p).?;
            self.setPos(
                ctx.anims,
                paren.pos.get(ctx.anims, mics) + (paren.size - self.size) / @as(utils.Vec2, @splat(2)),
                mics,
            );
            // self.setPos(paren.pos.get(mics), mics);
        }

        try ws_data.floating.put(ctx.gpa, win, {});
    } else {
        try ws_data.addWindow(.{
            .gpa = ctx.gpa,
            .focus = if (seat) |s| s.focus else null,
            .cursorPos = cursor,
        }, win);
    }
}

pub fn deinit(self: *const @This(), ctx: *Context, win: *rwm.WindowV1) void {
    self.node.destroy();

    _ = ctx.manage_states.swapRemove(win);

    if (self.app_id) |appid| ctx.gpa.free(appid);
    if (self.title) |title| ctx.gpa.free(title);

    const ws = Workspace.byWindow(ctx, win) orelse {
        log.err("window {} does not have a workspace", .{win});
        return;
    };

    const ws_data = ctx.workspaces.getPtr(ws).?;

    if (!ws_data.floating.swapRemove(win)) {
        ws_data.rmWindow(.{ .gpa = ctx.gpa }, win);
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
            const _old = win_data.app_id;
            if (std.mem.sliceTo(app_id.app_id, 0)) |new| {
                win_data.app_id = ctx.gpa.dupe(u8, new) catch return;
                if (_old) |old| ctx.gpa.free(old);
                log.info("{} has app_id {?s}", .{ win.getId(), win_data.app_id });
            }
        },
        .dimensions => |d| {
            win_data.size = .{ d.width, d.height };
            if (d.width > 0 and d.height > 0)
                if (win_data.float)
                    win_data.setSize(win_data.size, Animations.clock.now(ctx.io));
        },
        .parent => |p| {
            if (p.parent) |parent| {
                log.info("window {} has parent {}", .{ win.getId(), parent });
                win_data.parent = p.parent;
            }
            win_data.float = true;
        },
        .dimensions_hint => |h| {
            log.info("window {} hints dimensions from {}, {} to {}, {}", .{
                win.getId(),
                h.min_width,
                h.min_height,
                h.max_width,
                h.max_height,
            });
            if (h.min_height == h.max_height and h.min_width == h.max_width and h.min_height != 0 and h.min_width != 0) {
                win_data.size = .{ h.max_width, h.max_height };
                log.info("window {} set to floating", .{win.getId()});
                win_data.float = true;
            }
        },
        .fullscreen_requested => {
            win_data.fullscreen.on();
        },
        .exit_fullscreen_requested => {
            win_data.fullscreen.off();
        },
        .title => |t| {
            const _old = win_data.title;
            if (std.mem.sliceTo(t.title, 0)) |new| {
                win_data.title = ctx.gpa.dupe(u8, new) catch return;
                if (_old) |old| ctx.gpa.free(old);
            }
        },
        .unreliable_pid => |pid| {
            win_data.unreliable_pid = pid.unreliable_pid;
        },
        .identifier => |id| {
            const slice = mem.sliceTo(id.identifier, 0);
            std.debug.assert(slice.len <= 32);
            @memcpy(&win_data.identifier, slice);
        },
        else => {
            log.warn("lmao! can't actually handle event {s}", .{@tagName(event)});
        },
    }
}

pub fn goalRect(self: *@This()) utils.Rect2 {
    return .{ .pos = self.pos.end(), .dim = self.goal_size.end() };
}

pub fn setSize(self: *@This(), new: utils.Vec2, now: Io.Timestamp) void {
    if (@reduce(.Or, new < @as(utils.Vec2, @splat(0)))) return;

    if (meta.eql(new, self.goal_size.end())) return;

    self.goal_size = .{ .transit = .{
        .from = self.size,
        .to = new,
        .start = now,
    } };
}

pub fn setPos(self: *@This(), anims: Animations, new: utils.Vec2, now: Io.Timestamp) void {
    if (meta.eql(new, self.pos.end())) return;

    self.pos = .{
        .transit = .{
            .from = self.pos.get(anims, now),
            .to = new,
            .start = now,
        },
    };
}

pub fn getWorkspace(ctx: *Context, win: *rwm.WindowV1) ?Workspace.WS {
    var iter = ctx.workspaces.iterator();

    while (iter.next()) |ws| {
        if (ws.value_ptr.windows.contains(win)) return ws.key_ptr.*;
        if (ws.value_ptr.floating.contains(win)) return ws.key_ptr.*;
    }

    return null;
}

pub fn byPointer(ctx: *Context, pos: utils.Vec2) ?*rwm.WindowV1 {
    const ws = Workspace.byPointer(ctx, pos) orelse return null;
    const ws_data = ctx.workspaces.get(ws).?;

    for (ws_data.floating.keys()) |win| {
        const win_data = ctx.wins.get(win).?;
        const rec: utils.Rect2 = .{
            .dim = win_data.size,
            .pos = win_data.pos.current(ctx.anims, ctx.io),
        };
        if (rec.inside(pos)) return win;
    }

    for (ws_data.windows.keys()) |win| {
        const win_data = ctx.wins.get(win).?;
        const rec: utils.Rect2 = .{
            .dim = win_data.goal_size.current(ctx.anims, ctx.io),
            .pos = win_data.pos.current(ctx.anims, ctx.io),
        };
        if (rec.inside(pos)) return win;
    }

    return null;
}
