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
const Workspace = @import("workspace.zig");

fn noop(_: ?*anyopaque, _: *Context, _: *rwm.WindowV1) void {}

pub const cols = struct {
    pub fn positions(_: ?*anyopaque, ctx: *Context, windows: []*rwm.WindowV1, bounds: utils.Vec2) []utils.Vec2 {
        if (windows.len == 0) return &.{};

        const w = std.math.divFloor(i32, bounds.x, @intCast(windows.len)) catch unreachable;
        const out = ctx.alloc.alloc(utils.Vec2, windows.len) catch return &.{};

        for (windows) |win| {
            win.proposeDimensions(w, bounds.y);
        }

        return out;
    }

    pub fn sizes(_: ?*anyopaque, ctx: *Context, windows: []*rwm.WindowV1, bounds: utils.Vec2) []utils.Vec2 {
        if (windows.len == 0) return &.{};

        const w = std.math.divFloor(i32, bounds.x, @intCast(windows.len)) catch unreachable;
        const out = ctx.alloc.alloc(utils.Vec2, windows.len) catch return &.{};

        for (out) |*win| {
            win.* = .{
                .x = w,
                .y = bounds.y,
            };
        }

        return out;
    }

    const vt: Workspace.Tiler.VTable = .{
        .positions = positions,
        .sizes = sizes,
        .add = noop,
        .remove = noop,
    };

    pub const tiler: Workspace.Tiler = .{
        .context = null,
        .vtable = &vt,
    };
};

pub const rows = struct {
    pub fn positions(_: ?*anyopaque, ctx: *Context, windows: []*rwm.WindowV1, bounds: utils.Vec2) []utils.Vec2 {
        if (windows.len == 0) return &.{};

        const h = std.math.divFloor(i32, bounds.y, @intCast(windows.len)) catch unreachable;
        const out = ctx.alloc.alloc(utils.Vec2, windows.len) catch return &.{};

        for (0.., out) |i, *win| {
            win.* = .{
                .x = 0,
                .y = h * @as(i32, @intCast(i)),
            };
        }

        return out;
    }

    pub fn sizes(_: ?*anyopaque, ctx: *Context, windows: []*rwm.WindowV1, bounds: utils.Vec2) []utils.Vec2 {
        if (windows.len == 0) return &.{};

        const h = std.math.divFloor(i32, bounds.y, @intCast(windows.len)) catch unreachable;
        const out = ctx.alloc.alloc(utils.Vec2, windows.len) catch return &.{};

        for (out) |*win| {
            win.* = .{
                .x = bounds.x,
                .y = h,
            };
        }

        return out;
    }

    const vt: Workspace.Tiler.VTable = .{
        .positions = positions,
        .sizes = sizes,
        .add = noop,
        .remove = noop,
    };

    pub const tiler: Workspace.Tiler = .{
        .context = null,
        .vtable = &vt,
    };
};
