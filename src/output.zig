const std = @import("std");
const wayland = @import("wayland");

const wl = wayland.client.wl;
const rwm = wayland.client.river;

const utils = @import("utils.zig");
const Context = @import("context.zig");
const Workspace = @import("workspace.zig");

position: ?utils.Vec2 = null,
size: ?utils.Vec2 = null,
workspace: Workspace.WS,

pub fn listener(out: *rwm.OutputV1, e: rwm.OutputV1.Event, ctx: *Context) void {
    const log = std.log.scoped(.output);
    const data: *@This() = ctx.outs.getPtr(out).?;

    switch (e) {
        .dimensions => |dim| {
            data.size = .{
                .x = dim.width,
                .y = dim.height,
            };
        },
        .position => |pos| {
            data.position = .{
                .x = pos.x,
                .y = pos.y,
            };
        },
        else => {
            log.warn("lmao! can't actually handle event {s}", .{@tagName(e)});
        },
    }
}

pub fn deinit(self: *@This(), ctx: *Context, out: *rwm.OutputV1) void {
    _ = out; // autofix
    _ = self; // autofix
    _ = ctx; // autofix
}
