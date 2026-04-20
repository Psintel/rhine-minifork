const std = @import("std");
const mem = std.mem;
const meta = std.meta;
const wayland = @import("wayland");
const log = std.log.scoped(.output);

const wl = wayland.client.wl;
const rwm = wayland.client.river;

const utils = @import("utils.zig");
const Context = @import("context.zig");
const Workspace = @import("workspace.zig");
const Output = @This();

position: ?utils.Vec2 = null,
size: ?utils.Vec2 = null,
exclusive_area: ?utils.Rect2 = null,
workspace: Workspace.WS,
last_workspace: ?Workspace.WS = null,

overlay: ?Workspace.WS = null,
shell_out: *rwm.LayerShellOutputV1,

pub const Wl = struct {
    global: u32,
    ready: bool = false, // data only valid to read if this is true
    geometry: struct {
        pos: utils.Vec2,
        pdim: utils.Vec2,
        subpx: wl.Output.Subpixel,
        trafo: wl.Output.Transform,
    } = undefined,
    mode: struct {
        dim: utils.Vec2,
        refresh: i32,
    } = undefined,
    name: ?[]u8 = null,
    model: ?[]u8 = null,
    make: ?[]u8 = null,
    description: ?[]u8 = null,
    scale: i32 = 1,

    pub fn listener(out: *wl.Output, e: wl.Output.Event, ctx: *Context) void {
        const data = ctx.wl_outs.data.getPtr(out) orelse return;
        data.ready = false;
        switch (e) {
            .name => |n| {
                if (data.name) |nm| ctx.gpa.free(nm);
                data.name = ctx.gpa.dupe(u8, mem.sliceTo(n.name, 0)) catch return;
            },
            .description => |desc| {
                if (data.description) |ds| ctx.gpa.free(ds);
                data.description = ctx.gpa.dupe(u8, mem.sliceTo(desc.description, 0)) catch return;
            },
            .mode => |m| {
                data.mode = .{
                    .dim = .{ m.width, m.height },
                    .refresh = m.refresh,
                };
            },
            .geometry => |geo| {
                data.geometry = .{
                    .pos = .{ geo.x, geo.y },
                    .pdim = .{ geo.physical_width, geo.physical_height },
                    .subpx = geo.subpixel,
                    .trafo = geo.transform,
                };

                if (data.make) |mk| ctx.gpa.free(mk);
                data.make = ctx.gpa.dupe(u8, mem.sliceTo(geo.make, 0)) catch return;

                if (data.model) |md| ctx.gpa.free(md);
                data.model = ctx.gpa.dupe(u8, mem.sliceTo(geo.model, 0)) catch return;
            },
            .scale => |s| {
                data.scale = s.factor;
            },
            .done => data.ready = true,
        }
    }

    pub fn deinit(self: @This(), gpa: mem.Allocator) void {
        if (self.name) |nm| gpa.free(nm);
        if (self.model) |md| gpa.free(md);
        if (self.make) |mk| gpa.free(mk);
        if (self.description) |desc| gpa.free(desc);
    }
};

pub fn init(ctx: *Context, out: *rwm.OutputV1) !void {
    const shell = try ctx.shell.getOutput(out);
    errdefer shell.destroy();

    try ctx.shell_outs.put(ctx.gpa, shell, out);
    errdefer _ = ctx.shell_outs.swapRemove(shell);

    try ctx.outs.put(ctx.gpa, out, .{
        .workspace = Workspace.getFirst(ctx),
        .shell_out = shell,
    });

    shell.setListener(*Context, shellListener, ctx);
    out.setListener(*Context, Output.listener, ctx);
}

pub fn listener(out: *rwm.OutputV1, e: rwm.OutputV1.Event, ctx: *Context) void {
    const data: *@This() = ctx.outs.getPtr(out).?;

    switch (e) {
        .dimensions => |dim| {
            data.size = .{
                dim.width,
                dim.height,
            };
            ctx.dirty = true;
        },
        .position => |pos| {
            data.position = .{
                pos.x,
                pos.y,
            };
            ctx.dirty = true;
        },
        .removed => {
            deinit(ctx, out);
            ctx.dirty = true;
        },
        else => {
            log.warn("lmao! can't actually handle event {s}", .{@tagName(e)});
        },
    }
}

pub fn shellListener(shell: *rwm.LayerShellOutputV1, event: rwm.LayerShellOutputV1.Event, ctx: *Context) void {
    const out = ctx.shell_outs.get(shell) orelse return;
    const out_data = ctx.outs.getPtr(out) orelse return;
    switch (event) {
        .non_exclusive_area => |area| {
            out_data.exclusive_area = .{ .pos = .{
                area.x,
                area.y,
            }, .dim = .{
                area.width,
                area.height,
            } };

            log.info("set non_exclusive area to {}", .{out_data.exclusive_area.?});
        },
    }
}

pub fn getArea(self: @This()) utils.Rect2 {
    return self.exclusive_area orelse .{
        .pos = self.position.?,
        .dim = self.size.?,
    };
}

pub fn bySeat(ctx: *Context, seat: *rwm.SeatV1) ?*rwm.OutputV1 {
    const seat_data = ctx.seats.get(seat) orelse return null;

    if (seat_data.focus) |f| {
        const _ws = Workspace.byWindow(ctx, f);
        if (_ws) |ws| if (byWorkspace(ctx, ws)) |o| return o;
    }

    return byPointer(ctx, seat_data.pointer_pos);
}

pub fn byPointer(ctx: *Context, pos: utils.Vec2) ?*rwm.OutputV1 {
    var iter = ctx.outs.iterator();
    while (iter.next()) |o| {
        const r: utils.Rect2 = .{ .dim = o.value_ptr.size.?, .pos = o.value_ptr.position.? };
        if (r.inside(pos)) {
            return o.key_ptr.*;
        }
    }

    return null;
}

pub fn byWorkspace(ctx: *Context, ws: Workspace.WS) ?*rwm.OutputV1 {
    var iter = ctx.outs.iterator();

    while (iter.next()) |_out| {
        const out = _out.key_ptr.*;
        const out_data = _out.value_ptr;

        if (out_data.workspace == ws) return out;
        if (out_data.overlay == ws) return out;
    }

    return null;
}

pub fn byWindow(ctx: *Context, win: *rwm.WindowV1) ?*rwm.OutputV1 {
    const ws = Workspace.byWindow(ctx, win) orelse return null;
    return byWorkspace(ctx, ws);
}

pub fn relPos(ctx: *Context, pos: utils.Vec2) ?utils.Vec2f {
    const out = byPointer(ctx, pos) orelse return null;
    const out_data = ctx.outs.get(out) orelse return null;
    var cursor: utils.Vec2f = @floatFromInt(pos - out_data.position.?);
    cursor /= @floatFromInt(out_data.size.?);
    return cursor;
}

// may fail or succeed
pub fn setWorkspace(self: *Output, ctx: *Context, ws: Workspace.WS) void {
    log.info("switching to workspace {}", .{ws});

    if (Workspace.getOutput(ctx, ws)) |_| return;

    self.last_workspace = self.workspace;
    self.workspace = ws;
}

pub fn deinit(ctx: *Context, out: *rwm.OutputV1) void {
    const self = ctx.outs.getPtr(out).?;
    const shell = self.shell_out;
    _ = ctx.shell_outs.swapRemove(shell);
    shell.destroy();
    _ = ctx.outs.swapRemove(out);
    out.destroy();
}
