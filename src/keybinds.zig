const std = @import("std");
const wayland = @import("wayland");
const tributary = @import("tributary");
const mem = std.mem;
const meta = std.meta;
const posix = std.posix;

const wl = wayland.client.wl;
const rwm = wayland.client.river;

const utils = tributary.utils;
const helpers = @import("helpers.zig");
const command = @import("commands.zig");

const Context = @import("context.zig");
const Tiler = @import("tiler.zig");
const Window = @import("window.zig");
const Workspace = @import("workspace.zig");
const Output = @import("output.zig");
const Config = tributary.Config;

pub const Sym = u32;

const syms: std.StaticStringMap(Sym) = .initComptime(kvs: {
    const xkb = @import("keysysms");
    const T = struct { []const u8, Sym };

    var out: []const T = &.{};
    @setEvalBranchQuota(1000_000);

    for (meta.declarations(xkb)) |f| {
        if (!mem.startsWith(u8, f.name, "XKB_KEY_")) continue;

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

pub const Mods = struct {
    shift: bool = false,
    ctrl: bool = false,
    mod1: bool = false,
    mod3: bool = false,
    mod4: bool = false,
    mod5: bool = false,

    pub fn toSeatMods(self: @This()) rwm.SeatV1.Modifiers {
        var out = rwm.SeatV1.Modifiers{};
        inline for (comptime meta.fieldNames(@This())) |f| {
            @field(out, f) = @field(self, f);
        }
        return out;
    }

    pub fn parse(str: []const u8) !@This() {
        var iter = std.mem.tokenizeScalar(u8, str, '+');
        var mods = @This(){};

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

        return mods;
    }
};

pub const Bind = struct {
    mods: Mods,
    key: Sym,
    cmd: command.Command,

    pub fn fromEntry(entry: Config.Entry) !@This() {
        var args = entry.iterate();

        const mods = try Mods.parse(args.next() orelse return error.NoMod);

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
            ctx.commands_queue.addNoFail(ctx.gpa, ctx.io, dat.seat, dat.cmd);
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
    const nb = try ctx.bind.getXkbBinding(seat, b.key, b.mods.toSeatMods());
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
