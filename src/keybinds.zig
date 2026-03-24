const std = @import("std");
const wayland = @import("wayland");
const mem = std.mem;
const meta = std.meta;
const posix = std.posix;

const wl = wayland.client.wl;
const rwm = wayland.client.river;

const utils = @import("utils.zig");
const helpers = @import("helpers.zig");
const command = @import("commands.zig");

const Context = @import("context.zig");
const Tiler = @import("tiler.zig");
const Window = @import("window.zig");
const Workspace = @import("workspace.zig");
const Output = @import("output.zig");
const Config = @import("config.zig");

const bsp = @import("bsp.zig");

const xkb = @cImport(@cInclude("xkbcommon/xkbcommon-keysyms.h"));
pub const Sym = u32;

const syms: std.StaticStringMap(Sym) = .initComptime(kvs: {
    const T = meta.Tuple(&.{ []const u8, Sym });

    var out: []const T = &.{};
    @setEvalBranchQuota(1000_000);

    for (meta.declarations(xkb)) |f| {
        if (f.name.len < 8 or !mem.eql(u8, f.name[0..8], "XKB_KEY_")) continue;

        const new: T = .{
            f.name[8..],
            @intCast(@field(xkb, f.name)),
        };

        out = out ++ .{new};
    }

    break :kvs out;
});

const log = std.log.scoped(.keybinds);

const BindData = struct {
    seat: *rwm.SeatV1,
    cmd: command.Command,
};

var bindDatas: utils.WLHashMap(rwm.XkbBindingV1, BindData) = .empty;

pub const Bind = struct {
    mods: rwm.SeatV1.Modifiers,
    key: Sym,
    cmd: command.Command,

    pub fn fromEntry(entry: Config.Entry) !@This() {
        var args = entry.iterate();

        var iter = std.mem.tokenizeScalar(u8, args.next() orelse return error.NoMod, '+');
        var mods = rwm.SeatV1.Modifiers{};

        while (iter.next()) |m| {
            if (mem.eql(u8, m, "alt")) {
                mods.mod1 = true;
            } else if (mem.eql(u8, m, "super")) {
                mods.mod4 = true;
            } else if (mem.eql(u8, m, "ctrl")) {
                mods.ctrl = true;
            } else if (mem.eql(u8, m, "shift")) {
                mods.shift = true;
            } else if (mem.eql(u8, m, "none")) {
                // do nothing
            } else {
                return error.ParseError;
            }
        }

        const key = args.next() orelse return error.NoKey;
        const keyval = syms.get(key) orelse {
            log.err("invalid keysym {s}", .{key});
            return error.InvalidKey;
        };

        return .{
            .key = keyval,
            .mods = mods,
            .cmd = try .fromArg(&args),
        };
    }
};
pub fn trigger(b: *rwm.XkbBindingV1, event: rwm.XkbBindingV1.Event, ctx: *Context) void {
    const dat = bindDatas.get(b).?;
    switch (event) {
        .pressed => {
            ctx.commands_queue.addNoFail(ctx.gpa, dat.seat, dat.cmd);
        },
        .released => {},
        .stop_repeat => {},
    }
}

pub fn registerAll(ctx: *Context, seat: *rwm.SeatV1) !void {
    const conf = try ctx.config.getList("keybinds");

    log.info("registering keybinds for seat {}", .{seat.getId()});

    for (conf) |entry| {
        const b = Bind.fromEntry(entry) catch |e| {
            log.err("error parsing keybind : {}", .{ e});
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
    const nb = try ctx.bind.getXkbBinding(seat, b.key, b.mods);
    errdefer nb.destroy();
    try sc.binds.append(ctx.gpa, nb);
    errdefer _ = sc.binds.pop();
    try bindDatas.put(ctx.gpa, nb, .{
        .seat = seat,
        .cmd = b.cmd,
    });
    nb.setListener(*Context, trigger, ctx);
}

pub fn unregister(ctx: *Context, seat: *rwm.SeatV1) void {
    const seat_data = ctx.seats.getPtr(seat).?;
    for (seat_data.binds.items) |b| {
        b.destroy();
        _ = bindDatas.swapRemove(b);
    }

    seat_data.binds.clearAndFree(ctx.gpa);
    if (bindDatas.entries.len == 0) bindDatas.clearAndFree(ctx.gpa);
}
