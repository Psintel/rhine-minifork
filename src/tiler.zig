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
const Layouts = @import("layouts.zig");
const Config = @import("config.zig");

const Tiler = @This();

vtable: *const VTable,
context: ?*anyopaque,
tag: Layouts.LayoutType,

pub const WT = *rwm.WindowV1;
pub const ManageMap = utils.WLHashMap(rwm.WindowV1, TileState);

pub const TileContext = struct {
    focus: ?WT = null,
    cursorPos: ?utils.Vec2f = null,
    gpa: mem.Allocator,
};

pub const Anchor = struct {
    v: enum { top, bottom },
    h: enum { left, right },
};

pub const TileState = struct {
    show: bool = false, // show the window
    dims: utils.Rect2 = .{
        .dim = @splat(0),
        .pos = @splat(0),
    },
};

// custom tiler-specific commands
pub const Command = struct {
    command: u32,
    payload: ?*anyopaque = null,
};

pub const Error = error{
    TileError,
    InvalidCommand,
} || mem.Allocator.Error;

pub const MoveResult = union(enum) {
    // we did a successful move (the tiler is allowed to lie)
    done: void,
    // we want to move the window beyond workspace bounds
    // this means that the window will get removed from the
    // current workspace and moved to another one
    // the payload is the dimensions and position of the window
    // in the current workspace
    escalate: utils.Rect2f,
};

pub const VTable = struct {
    // takes workspace (including the anyopaque context pointer) and returns a slice of window positions.
    add: *const fn (?*anyopaque, TileContext, WT) Error!void,
    // every added window must be removed to fully deinitialize
    remove: *const fn (?*anyopaque, TileContext, WT) void,
    // upate the ManageMap structure. all tiler-tracked windows are guaranteed to be available
    manage: *const fn (?*anyopaque, TileContext, bound: utils.Rect2, *ManageMap) void,

    // these two center on the focus from context (since that is an arg, it's easily mockable)
    // getWindow is used for focus shift
    getWindow: *const fn (?*anyopaque, TileContext, utils.Dir) ?WT,
    move: *const fn (?*anyopaque, TileContext, utils.Dir) MoveResult,

    // set the size of the focused window
    setSize: *const fn (?*anyopaque, TileContext, utils.Vec2f, Anchor) void,
    // reload config values
    loadConfig: *const fn (?*anyopaque, Config) Config.Error!void,
    // run a layout-specific command
    command: *const fn (?*anyopaque, TileContext, Command) Error!void,
};

// for embedding a Vtable builder into a state tiler
pub fn tiler(T: type) type {
    return struct {
        const vt = VTable{
            .add = add_impl,
            .remove = remove_impl,
            .manage = manage_impl,
            .getWindow = get_impl,
            .move = move_impl,
            .setSize = setSize_impl,
            .loadConfig = loadConfig_impl,
            .command = command_impl,
        };

        fn add_impl(data: ?*anyopaque, ctx: TileContext, win: WT) Error!void {
            const parent: *T = @ptrCast(@alignCast(data.?));
            return parent.add(ctx, win);
        }

        fn remove_impl(data: ?*anyopaque, ctx: TileContext, win: WT) void {
            const parent: *T = @ptrCast(@alignCast(data.?));
            return parent.remove(ctx, win);
        }

        fn manage_impl(data: ?*anyopaque, ctx: TileContext, bound: utils.Rect2, man: *ManageMap) void {
            const parent: *T = @ptrCast(@alignCast(data.?));
            return parent.manage(ctx, bound, man);
        }

        fn move_impl(data: ?*anyopaque, ctx: TileContext, d: utils.Dir) MoveResult {
            const parent: *T = @ptrCast(@alignCast(data.?));
            return parent.move(ctx, d);
        }

        fn get_impl(data: ?*anyopaque, ctx: TileContext, d: utils.Dir) ?WT {
            const parent: *T = @ptrCast(@alignCast(data.?));
            return parent.getWindow(ctx, d);
        }

        fn setSize_impl(data: ?*anyopaque, ctx: TileContext, size: utils.Vec2f, anchor: Anchor) void {
            if (!@hasDecl(T, "setSize")) return;
            const parent: *T = @ptrCast(@alignCast(data.?));
            parent.setSize(ctx, size, anchor);
        }

        fn loadConfig_impl(data: ?*anyopaque, conf: Config) !void {
            if (!@hasDecl(T, "loadConfig")) return;
            const parent: *T = @ptrCast(@alignCast(data.?));
            return parent.loadConfig(conf);
        }

        fn command_impl(data: ?*anyopaque, ctx: TileContext, cmd: Command) Error!void {
            if (!@hasDecl(T, "command")) return;
            const parent: *T = @ptrCast(@alignCast(data.?));
            return parent.command(ctx, cmd);
        }

        pub fn get(self: *@This(), tag: Layouts.LayoutType) Tiler {
            const parent: *T = @alignCast(@fieldParentPtr("tiler", self));
            return .{
                .vtable = &vt,
                .context = parent,
                .tag = tag,
            };
        }
    };
}
