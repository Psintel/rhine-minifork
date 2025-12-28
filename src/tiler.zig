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
const Tilable = @import("tilable.zig");

const Tiler = @This();

vtable: *const VTable,
context: ?*anyopaque,

pub const TileContext = struct {
    winData: utils.WLHashMap(rwm.WindowV1, Window),
    focus: ?*rwm.WindowV1 = null,
    cursorPos: ?utils.Vec2 = null,
    gpa: mem.Allocator,
};

pub const Dir = enum {
    Left,
    Right,
    Up,
    Down,
};

pub const Error = error{
    TileError,
} || mem.Allocator.Error;

pub const VTable = struct {
    // takes workspace (including the anyopaque context pointer) and returns a slice of window positions.
    // the memory is allocated using alloc and caller owned
    add: *const fn (?*anyopaque, *TileContext, *rwm.WindowV1) Error!void,
    remove: *const fn (?*anyopaque, *TileContext, *rwm.WindowV1) void,
    manage: *const fn (?*anyopaque, *TileContext, bound: utils.Rect2) Error!void,
    render: *const fn (?*anyopaque, *TileContext, bound: utils.Rect2) Error!void,

    // these two center on the focus from context (since that is an arg, it's easily mockable)
    getWindow: *const fn (?*anyopaque, *TileContext, Dir) ?*rwm.WindowV1,
    move: *const fn (?*anyopaque, *TileContext, Dir) void,
};

// for embedding a Vtable builder into a state tiler
pub fn tiler(T: type) type {
    return struct {
        const vt = VTable{
            .add = add_impl,
            .remove = remove_impl,
            .manage = manage_impl,
            .render = render_impl,
            .getWindow = get_impl,
            .move = move_impl,
        };

        fn add_impl(data: ?*anyopaque, ctx: *TileContext, win: *rwm.WindowV1) Error!void {
            const parent: *T = @ptrCast(@alignCast(data.?));
            return parent.add(ctx, win);
        }
        fn remove_impl(data: ?*anyopaque, ctx: *TileContext, win: *rwm.WindowV1) void {
            const parent: *T = @ptrCast(@alignCast(data.?));
            return parent.remove(ctx, win);
        }

        fn manage_impl(data: ?*anyopaque, ctx: *TileContext, bound: utils.Rect2) Error!void {
            const parent: *T = @ptrCast(@alignCast(data.?));
            return parent.manage(ctx, bound);
        }

        fn render_impl(data: ?*anyopaque, ctx: *TileContext, bound: utils.Rect2) Error!void {
            const parent: *T = @ptrCast(@alignCast(data.?));
            return parent.render(ctx, bound);
        }

        fn move_impl(data: ?*anyopaque, ctx: *TileContext, d: Dir) void {
            const parent: *T = @ptrCast(@alignCast(data.?));
            parent.move(ctx, d);
        }

        fn get_impl(data: ?*anyopaque, ctx: *TileContext, d: Dir) ?*rwm.WindowV1 {
            const parent: *T = @ptrCast(@alignCast(data.?));
            return parent.getWindow(ctx, d);
        }

        pub fn get(self: *@This()) Tiler {
            const parent: *T = @alignCast(@fieldParentPtr("tiler", self));
            return .{
                .vtable = &vt,
                .context = parent,
            };
        }
    };
}
