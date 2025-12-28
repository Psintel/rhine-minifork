const std = @import("std");
const wayland = @import("wayland");
const mem = std.mem;
const meta = std.meta;

const wl = wayland.client.wl;
const rwm = wayland.client.river;

const utils = @import("utils.zig");
const Context = @import("context.zig");
const Tiler = @import("tiler.zig");
const xkb = @cImport(@cInclude("xkbcommon/xkbcommon-keysyms.h"));
pub const Sym = u32;

pub const Trigger = fn (b: *rwm.XkbBindingV1, event: rwm.XkbBindingV1.Event, ctx: *Context) void;

const log = std.log.scoped(.keybinds);

const BindData = struct {
    seat: *rwm.SeatV1,
};

pub var bindDatas: utils.WLHashMap(rwm.XkbBindingV1, BindData) = .empty;

fn simplify(ns: type) type {
    const d = meta.declarations(ns);

    var E: [d.len]std.builtin.Type.EnumField = undefined;
    var i = 0;

    inline for (d) |decl| {
        @setEvalBranchQuota(100000);
        if (mem.startsWith(u8, decl.name, "XKB_KEY_")) {
            E[i] = .{ .name = decl.name[8..], .value = @field(xkb, decl.name) };
            i += 1;
        }
    }

    const t: std.builtin.Type = .{ .@"enum" = .{
        .tag_type = u32,
        .decls = &.{},
        .is_exhaustive = false,
        .fields = E[0..i],
    } };

    return @Type(t);
}

pub const Bind = struct {
    mods: rwm.SeatV1.Modifiers,
    key: Sym,
    trigger: *const Trigger,
};

const binds = [_]Bind{
    .{
        .mods = .{ .mod1 = true },
        .key = xkb.XKB_KEY_q,
        .trigger = kill,
    },
} ++ directionals(
    .{ .mod1 = true },
    .{ xkb.XKB_KEY_h, xkb.XKB_KEY_j, xkb.XKB_KEY_k, xkb.XKB_KEY_l },
    focusDir,
) ++ directionals(
    .{ .mod1 = true, .shift = true },
    .{ xkb.XKB_KEY_h, xkb.XKB_KEY_j, xkb.XKB_KEY_k, xkb.XKB_KEY_l },
    moveDir,
) ++ directionals(
    .{ .mod1 = true },
    .{ xkb.XKB_KEY_Left, xkb.XKB_KEY_Down, xkb.XKB_KEY_Up, xkb.XKB_KEY_Right },
    focusDir,
) ++ directionals(
    .{ .mod1 = true, .shift = true },
    .{ xkb.XKB_KEY_Left, xkb.XKB_KEY_Down, xkb.XKB_KEY_Up, xkb.XKB_KEY_Right },
    moveDir,
);

pub fn register(ctx: *Context, seat: *rwm.SeatV1) !void {
    const sc = ctx.seats.getPtr(seat).?;
    log.info("registering keybinds for seat {}", .{seat.getId()});

    for (binds) |b| {
        const nb = try ctx.bind.getXkbBinding(seat, b.key, b.mods);
        try sc.binds.append(ctx.alloc, nb);
        try bindDatas.put(ctx.alloc, nb, .{
            .seat = seat,
        });
        nb.setListener(*Context, b.trigger, ctx);
    }
}

fn kill(b: *rwm.XkbBindingV1, event: rwm.XkbBindingV1.Event, ctx: *Context) void {
    const dat = bindDatas.get(b).?;

    switch (event) {
        .pressed => {
            if (ctx.seats.get(dat.seat).?.focus) |w| {
                ctx.shouldClose.append(ctx.alloc, w) catch return;
                log.info("marked window {} for closure", .{w.getId()});
            }
        },
        .released => {},
    }
}

pub fn focusDir(comptime dir: Tiler.Dir) Trigger {
    return struct {
        pub fn focus(b: *rwm.XkbBindingV1, event: rwm.XkbBindingV1.Event, ctx: *Context) void {
            log.info("trying to shift focus rightward", .{});
            const dat = bindDatas.get(b).?;
            const sdat = ctx.seats.getPtr(dat.seat).?;

            switch (event) {
                .pressed => {
                    var tc: Tiler.TileContext = .{
                        .focus = sdat.focus,
                        .gpa = ctx.alloc,
                        .winData = ctx.wins,
                    };
                    if (ctx.workspaces[0].getWindow(&tc, dir)) |w| {
                        sdat.focus = w;
                        log.info("focus  window {}", .{w.getId()});
                    }
                },
                .released => {},
            }
        }
    }.focus;
}

pub fn moveDir(comptime dir: Tiler.Dir) Trigger {
    return struct {
        pub fn move(b: *rwm.XkbBindingV1, event: rwm.XkbBindingV1.Event, ctx: *Context) void {
            const dat = bindDatas.get(b).?;
            const sdat = ctx.seats.getPtr(dat.seat).?;

            switch (event) {
                .pressed => {
                    var tc: Tiler.TileContext = .{
                        .focus = sdat.focus,
                        .gpa = ctx.alloc,
                        .winData = ctx.wins,
                    };
                    ctx.workspaces[0].move(&tc, dir);
                    sdat.ignore_next = true;
                    ctx.wm.manageDirty();
                },
                .released => {},
            }
        }
    }.move;
}

fn directionals(mods: rwm.SeatV1.Modifiers, keys: [4]u32, f: fn (comptime Tiler.Dir) Trigger) [4]Bind {
    const dirs: [4]Tiler.Dir = .{ .Left, .Down, .Up, .Right };
    var out: [4]Bind = undefined;
    for (keys, dirs, &out) |k, d, *b| {
        b.* = .{
            .key = k,
            .mods = mods,
            .trigger = f(d),
        };
    }
    return out;
}
