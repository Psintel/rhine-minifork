const std = @import("std");
const wayland = @import("wayland");

const mem = std.mem;
const meta = std.meta;
const time = std.time;

const wl = wayland.client.wl;
const rwm = wayland.client.river;

const Context = @import("context.zig");
const utils = @import("utils.zig");
const Window = @import("window.zig");
const Workspace = @import("workspace.zig");
const Tilable = @import("tilable.zig");
const Tiler = @import("tiler.zig");
const Output = @import("output.zig");
const Config = @import("config.zig");
const keybind = @import("keybinds.zig");
const commands = @import("commands.zig");

// see linux/input-event-codes.h
// TODO: maybe generate this at comptime
const Button = enum(u32) {
    Left = 0x110,
    Right = 0x111,
    Middle = 0x112,
    Side = 0x113,
    Extra = 0x114,
    Forward = 0x115,
    Back = 0x116,
    Task = 0x117,

    pub fn toInt(self: @This()) u32 {
        return @intFromEnum(self);
    }
};

const log = std.log.scoped(.pointer_gestures);

pub const Bind = struct {
    mods: keybind.Mods,
    button: Button,
    cmd: commands.Command,

    pub fn fromEntry(entry: Config.Entry) !@This() {
        var args = entry.iterate();

        const mods = try keybind.Mods.parse(args.next() orelse return error.NoMod);

        const button = args.next() orelse return error.NoButton;
        const btnval = meta.stringToEnum(Button, button) orelse {
            log.err("invalid button {s}", .{button});
            return error.InvalidBTN;
        };

        return .{
            .mods = mods,
            .button = btnval,
            .cmd = try .fromArg(&args),
        };
    }
};

const BindData = struct {
    seat: *rwm.SeatV1,
    cmd: commands.Command,
};

pub var bindDatas: utils.WLHashMap(rwm.PointerBindingV1, BindData) = .empty;

pub fn listener(bind: *rwm.PointerBindingV1, event: rwm.PointerBindingV1.Event, ctx: *Context) void {
    const dat = bindDatas.get(bind) orelse return;

    switch (event) {
        .pressed => {
            ctx.commands_queue.addNoFail(ctx.gpa, dat.seat, dat.cmd);
            ctx.dirty = true;
        },
        .released => {},
    }
}

pub fn register(ctx: *Context, seat: *rwm.SeatV1) !void {
    const conf = try ctx.config.getList("pointer_binds");

    log.info("registering pointer bindings for seat {}", .{seat.getId()});

    for (conf) |entry| {
        const b = Bind.fromEntry(entry) catch |e| {
            log.err("error parsing keybind : {}", .{e});
            continue;
        };

        registerBind(ctx, seat, b) catch |e| {
            log.err("failed to register keybind {}: {}", .{ b, e });
            continue;
        };
    }
}

fn registerBind(ctx: *Context, seat: *rwm.SeatV1, b: Bind) !void {
    const sc = ctx.seats.getPtr(seat).?;
    const nb = try seat.getPointerBinding(b.button.toInt(), b.mods.toSeatMods());
    errdefer nb.destroy();
    try sc.pointer_binds.append(ctx.gpa, nb);
    errdefer _ = sc.binds.pop();
    try bindDatas.put(ctx.gpa, nb, .{
        .seat = seat,
        .cmd = b.cmd,
    });
    nb.setListener(*Context, listener, ctx);
}

pub fn unregister(ctx: *Context, seat: *rwm.SeatV1) void {
    const seat_data = ctx.seats.getPtr(seat).?;
    for (seat_data.pointer_binds.items) |bind| {
        bind.destroy();
        _ = bindDatas.swapRemove(bind);
    }

    seat_data.pointer_binds.clearAndFree(ctx.gpa);
    if (bindDatas.entries.len == 0) bindDatas.clearAndFree(ctx.gpa);
}
