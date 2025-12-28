const std = @import("std");
const wayland = @import("wayland");
const mem = std.mem;

const wl = wayland.client.wl;
const rwm = wayland.client.river;

const utils = @import("utils.zig");
const Window = @import("window.zig");
const Output = @import("output.zig");
const Seat = @import("seat.zig");
const Workspace = @import("workspace.zig");

const Tilable = @This();

pub const VTable = struct {
    getSize: *const fn (*anyopaque) utils.Vec2,
    setSize: *const fn (*anyopaque, utils.Vec2) void,
    setPos: *const fn (*anyopaque, utils.Vec2) void,
};

vt: *const VTable,
parent: *anyopaque,

pub fn embed(T: type) type {
    return struct {
        const vt: VTable = .{
            .setSize = set_size_impl,
            .getSize = get_size_impl,
            .setPos = set_pos_impl,
        };

        fn set_size_impl(ptr: *anyopaque, new: utils.Vec2) void {
            const self: *T = @ptrCast(@alignCast(ptr));
            self.setSize(new);
        }
        fn get_size_impl(ptr: *anyopaque) utils.Vec2 {
            const self: *T = @ptrCast(@alignCast(ptr));
            return self.getSize();
        }

        fn set_pos_impl(ptr: *anyopaque, new: utils.Vec2) void {
            const self: *T = @ptrCast(@alignCast(ptr));
            self.setPos(new);
        }

        pub fn get(self: *@This()) Tilable {
            const parent: *T = @fieldParentPtr("tilable", self);
            return .{
                .parent = parent,
                .vt = &vt,
            };
        }
    };
}
