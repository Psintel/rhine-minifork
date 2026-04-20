const std = @import("std");
const mem = std.mem;
const wayland = @import("wayland");
const utils = @import("utils.zig");

const wl = wayland.client.wl;
const wp = wayland.client.wp;
const rwm = wayland.client.river;

const Context = @import("context.zig");
const Output = @import("output.zig");
const Window = @import("window.zig");
const Workspace = @import("workspace.zig");

const log = std.log.scoped(.pointer);

cursor_shape: *wp.CursorShapeDeviceV1,

pub fn init(ctx: *Context, ptr: *wl.Pointer) !void {
    errdefer ptr.release();
    const shape = try ctx.cursor_shape.getPointer(ptr);
    errdefer shape.destroy();
    try ctx.pointers.put(ctx.gpa, ptr, .{ .cursor_shape = shape });
}

pub fn deinit(self: @This()) void {
    self.cursor_shape.destroy();
}
