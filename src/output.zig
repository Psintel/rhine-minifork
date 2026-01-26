const std = @import("std");
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

// special overlay workspace TODO:implement
overlay: ?Workspace.WS = null,

shell_out: *rwm.LayerShellOutputV1,

pub fn init(ctx: *Context, out: *rwm.OutputV1) !void {
    const shell = try ctx.shell.getOutput(out);
    errdefer shell.destroy();

    try ctx.outs.put(ctx.gpa, out, .{
        .workspace = Workspace.getFirst(ctx),
        .shell_out = undefined,
    });

    const self = ctx.outs.getPtr(out).?;

    shell.setListener(*Output, shellListener, self);
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
            // since we are tiling screenspace, a resize dirties the manage state
            ctx.dirty = true;
        },
        .position => |pos| {
            data.position = .{
                pos.x,
                pos.y,
            };
        },
        .removed => {
            deinit(ctx, out);
        },
        else => {
            log.warn("lmao! can't actually handle event {s}", .{@tagName(e)});
        },
    }
}

pub fn shellListener(_: *rwm.LayerShellOutputV1, event: rwm.LayerShellOutputV1.Event, data: *Output) void {
    switch (event) {
        .non_exclusive_area => |area| {
            data.exclusive_area = .{ .pos = .{
                area.x,
                area.y,
            }, .dim = .{
                area.width,
                area.height,
            } };
        },
    }
}

pub fn getArea(self: @This()) utils.Rect2 {
    return self.exclusive_area orelse .{
        .pos = self.position.?,
        .dim = self.size.?,
    };
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
    }

    return null;
}

pub fn relPos(ctx: *Context, pos: utils.Vec2) ?utils.Vec2 {
    const out = byPointer(ctx, pos) orelse return null;
    const out_data = ctx.outs.get(out) orelse return null;
    const cursor = (pos - out_data.position.?) * utils.Rect2.unit.dim / out_data.size.?;
    return cursor;
}

pub fn deinit(ctx: *Context, out: *rwm.OutputV1) void {
    // const self = ctx.outs.getPtr(out).?;
    // const shell = self.shell_out;
    // shell.destroy(); // this segfaults.. why?
    _ = ctx.outs.swapRemove(out);
    out.destroy();
}
