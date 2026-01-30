const std = @import("std");
const wayland = @import("wayland");
const mem = std.mem;
const meta = std.meta;
const posix = std.posix;

const wl = wayland.client.wl;
const rwm = wayland.client.river;

const utils = @import("utils.zig");
const Context = @import("context.zig");
const Tiler = @import("tiler.zig");
const Window = @import("window.zig");
const Workspace = @import("workspace.zig");
const Output = @import("output.zig");
const Config = @import("config.zig");

const bsp = @import("bsp.zig");

const xkb = @cImport(@cInclude("xkbcommon/xkbcommon-keysyms.h"));
pub const Sym = u32;

pub const Trigger = fn (b: *rwm.XkbBindingV1, event: rwm.XkbBindingV1.Event, ctx: *Context) void;

const log = std.log.scoped(.keybinds);

const BindData = struct {
    seat: *rwm.SeatV1,
};

var bindDatas: utils.WLHashMap(rwm.XkbBindingV1, BindData) = .empty;

pub const Bind = struct {
    mods: rwm.SeatV1.Modifiers,
    key: Sym,
    trigger: *const Trigger,

    pub fn fromEntry(entry: Config.Entry) !@This() {
        var iter = std.mem.tokenizeScalar(u8, entry.args[0], '+');
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
            } else {
                return error.ParseError;
            }
        }

        var buf: [20]u8 = @splat(0);
        const key = try std.fmt.bufPrint(&buf, "XKB_KEY_{s}", .{entry.args[1]});

        return .{
            .key = key,
            .mods = mods,
        };
    }
};

const binds = [_]Bind{
    .{
        .mods = .{ .mod4 = true },
        .key = xkb.XKB_KEY_q,
        .trigger = kill,
    },
    .{
        .mods = .{ .mod4 = true },
        .key = xkb.XKB_KEY_d,
        .trigger = launch(&.{"fuzzel"}),
    },
    .{
        .mods = .{ .mod4 = true },
        .key = xkb.XKB_KEY_Return,
        .trigger = launch(&.{"foot"}),
    },
    .{
        .mods = .{ .mod4 = true },
        .key = xkb.XKB_KEY_s,
        .trigger = changeSplit,
    },
    .{
        .mods = .{ .mod4 = true },
        .key = xkb.XKB_KEY_f,
        .trigger = toggleFullscreen,
    },
    .{
        .mods = .{ .mod4 = true },
        .key = xkb.XKB_KEY_Tab,
        .trigger = toggleWorkspace,
    },
} ++ directionals(
    .{ .mod4 = true },
    .{ xkb.XKB_KEY_h, xkb.XKB_KEY_j, xkb.XKB_KEY_k, xkb.XKB_KEY_l },
    focusDir,
) ++ directionals(
    .{ .mod4 = true, .shift = true },
    .{ xkb.XKB_KEY_h, xkb.XKB_KEY_j, xkb.XKB_KEY_k, xkb.XKB_KEY_l },
    moveDir,
) ++ directionals(
    .{ .mod4 = true },
    .{ xkb.XKB_KEY_Left, xkb.XKB_KEY_Down, xkb.XKB_KEY_Up, xkb.XKB_KEY_Right },
    focusDir,
) ++ directionals(
    .{ .mod4 = true, .shift = true },
    .{ xkb.XKB_KEY_Left, xkb.XKB_KEY_Down, xkb.XKB_KEY_Up, xkb.XKB_KEY_Right },
    moveDir,
) ++ numbers(
    .{ .mod4 = true },
    changeWorkspace,
) ++ numbers(
    .{ .mod4 = true, .shift = true },
    moveToWorkspace,
);

pub fn register(ctx: *Context, seat: *rwm.SeatV1) !void {
    const sc = ctx.seats.getPtr(seat).?;
    // const conf = try ctx.config.getList("keybinds");
    // _ = conf;

    log.info("registering keybinds for seat {}", .{seat.getId()});

    for (binds) |b| {
        const nb = try ctx.bind.getXkbBinding(seat, b.key, b.mods);
        try sc.binds.append(ctx.gpa, nb);
        try bindDatas.put(ctx.gpa, nb, .{
            .seat = seat,
        });
        nb.setListener(*Context, b.trigger, ctx);
    }
}

pub fn unregister(ctx: *Context, seat: *rwm.SeatV1) void {
    for (ctx.seats.get(seat).?.binds.items) |b| {
        _ = bindDatas.swapRemove(b);
    }

    if (bindDatas.entries.len == 0) bindDatas.clearAndFree(ctx.gpa);
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

fn numbers(mods: rwm.SeatV1.Modifiers, f: fn (comptime i32) Trigger) [10]Bind {
    var out: [10]Bind = undefined;
    for (&out, 0..) |*b, i| {
        b.* = .{
            .mods = mods,
            .key = @field(xkb, std.fmt.comptimePrint("XKB_KEY_{}", .{(i + 1) % 10})),
            .trigger = f(i),
        };
    }

    return out;
}

fn kill(b: *rwm.XkbBindingV1, event: rwm.XkbBindingV1.Event, ctx: *Context) void {
    const dat = bindDatas.get(b).?;

    switch (event) {
        .pressed => {
            if (ctx.seats.get(dat.seat).?.focus) |w| {
                ctx.should_close.append(ctx.gpa, w) catch return;
                log.info("marked window {} for closure", .{w.getId()});
            }
        },
        .released => {},
        .stop_repeat => {},
    }
}

fn focusDir(comptime dir: Tiler.Dir) Trigger {
    return struct {
        pub fn focus(b: *rwm.XkbBindingV1, event: rwm.XkbBindingV1.Event, ctx: *Context) void {
            const data = bindDatas.get(b).?;
            const seat_data = ctx.seats.getPtr(data.seat).?;
            const win = seat_data.focus orelse return;
            const ws_id = Window.getWorkspace(ctx, win) orelse return;
            const ws = ctx.workspaces.getPtr(ws_id).?;

            switch (event) {
                .pressed => {
                    var tc: Tiler.TileContext = .{
                        .focus = seat_data.focus,
                        .gpa = ctx.gpa,
                    };
                    if (ws.getWindow(&tc, dir)) |w| {
                        seat_data.focus = w;
                        seat_data.warp_to_window = w;
                        log.info("focus  window {}", .{w.getId()});
                    }
                },
                .released => {},
                .stop_repeat => {},
            }
        }
    }.focus;
}

fn moveDir(comptime dir: Tiler.Dir) Trigger {
    return struct {
        pub fn move(b: *rwm.XkbBindingV1, event: rwm.XkbBindingV1.Event, ctx: *Context) void {
            const data = bindDatas.get(b).?;
            const seat_data = ctx.seats.getPtr(data.seat).?;
            const win = seat_data.focus orelse return;
            // const win_data = ctx.wins.get(win).?;
            const ws_id = Window.getWorkspace(ctx, win) orelse return;
            const ws = ctx.workspaces.getPtr(ws_id).?;

            switch (event) {
                .pressed => {
                    var tc: Tiler.TileContext = .{
                        .focus = win,
                        .gpa = ctx.gpa,
                    };
                    ws.move(&tc, dir);
                    seat_data.warp_to_window = win;
                    ctx.wm.manageDirty();
                },
                .released => {},
                .stop_repeat => {},
            }
        }
    }.move;
}

fn launch(comptime command: [:null]const ?[*:0]const u8) Trigger {
    return struct {
        pub fn launch(_: *rwm.XkbBindingV1, event: rwm.XkbBindingV1.Event, ctx: *Context) void {
            switch (event) {
                .pressed => {
                    var buf: [0x80000]u8 = @splat(0); // look if your env is more than 80 KiB I cannot help you
                    var fb: std.heap.FixedBufferAllocator = .init(&buf);
                    const alloc = fb.allocator();
                    const env = std.process.createEnvironFromMap(alloc, &ctx.child_env, .{}) catch |e| {
                        log.err("failed to spawn {?s}: {}", .{ command[0], e });
                        return;
                    };
                    const pid = std.posix.fork() catch {
                        log.err("fork failed for command {*}", .{command});
                        return;
                    };
                    const args: [*:null]const ?[*:0]const u8 = .{ "/bin/sh", "-c" } ++ command;
                    if (pid == 0) {
                        _ = posix.setsid() catch posix.exit(1);
                        const sig_dfl = posix.Sigaction{
                            .handler = .{ .handler = posix.SIG.DFL },
                            .mask = posix.sigemptyset(),
                            .flags = 0,
                        };
                        posix.sigaction(posix.SIG.PIPE, &sig_dfl, null);
                        posix.execveZ("/bin/sh", args, env) catch posix.exit(1);
                    }
                },
                .released => {},
                .stop_repeat => {},
            }
        }
    }.launch;
}

fn changeSplit(b: *rwm.XkbBindingV1, event: rwm.XkbBindingV1.Event, ctx: *Context) void {
    switch (event) {
        .pressed => {
            const data = bindDatas.get(b).?;
            const seat_data = ctx.seats.getPtr(data.seat).?;
            const win = seat_data.focus orelse return;
            const ws_id = Window.getWorkspace(ctx, win) orelse return;
            const ws = ctx.workspaces.getPtr(ws_id).?;

            var tc: Tiler.TileContext = .{
                .focus = win,
                .gpa = ctx.gpa,
            };

            ws.command(&tc, .{ .command = @intFromEnum(bsp.Commands.ChangeSplit) }) catch |e| {
                log.err("changesplit failed with {}", .{e});
                return;
            };
        },
        .released => {},
        .stop_repeat => {},
    }
}

fn changeWorkspace(comptime target: Workspace.WS) Trigger {
    return struct {
        pub fn change(b: *rwm.XkbBindingV1, event: rwm.XkbBindingV1.Event, ctx: *Context) void {
            switch (event) {
                .pressed => { // TODO: determine output based on focus too
                    const data = bindDatas.get(b).?;
                    const seat_data = ctx.seats.getPtr(data.seat).?;

                    const out = Output.byPointer(ctx, seat_data.pointer_pos) orelse return;
                    const out_data = ctx.outs.getPtr(out).?;

                    const w = Workspace.get(ctx, target) catch |e| {
                        log.err("failed to switch to workspace {} with error {}", .{ target, e });
                        return;
                    };

                    log.info("switching to workspace {}", .{target});

                    if (Workspace.getOutput(ctx, target) == null) {
                        out_data.setWorkspace(ctx, target);
                    }

                    seat_data.focus = if (w.windows.entries.len > 0) w.windows.keys()[0] else null;
                    seat_data.warp_to_window = seat_data.focus;

                    ctx.dirty = true;
                },
                .released => {},
                .stop_repeat => {},
            }
        }
    }.change;
}

fn moveToWorkspace(comptime target: Workspace.WS) Trigger {
    return struct {
        pub fn change(b: *rwm.XkbBindingV1, event: rwm.XkbBindingV1.Event, ctx: *Context) void {
            switch (event) {
                .pressed => {
                    const data = bindDatas.get(b).?;
                    const seat_data = ctx.seats.getPtr(data.seat).?;

                    const focus = seat_data.focus orelse return;
                    const source = Window.getWorkspace(ctx, focus) orelse return;

                    if (source == target) return;

                    const out = Output.byPointer(ctx, seat_data.pointer_pos) orelse return;
                    const out_data = ctx.outs.getPtr(out).?;

                    const w = Workspace.get(ctx, target) catch |e| {
                        log.err("failed to switch to workspace {} with error {}", .{ target, e });
                        return;
                    };

                    log.info("switching to workspace {}", .{target});

                    if (Workspace.getOutput(ctx, target) == null) {
                        out_data.setWorkspace(ctx, target);
                    }

                    const s = ctx.workspaces.getPtr(source).?;
                    var tc: Tiler.TileContext = .{
                        .cursorPos = seat_data.pointer_pos,
                        .focus = seat_data.focus,
                        .gpa = ctx.gpa,
                    };

                    s.rmWindow(&tc, focus);
                    w.addWindow(&tc, focus) catch |e| {
                        log.err("error adding window {} to workspace {}: {}", .{ focus.getId(), target, e });
                    };

                    ctx.dirty = true;
                },
                .released => {},
                .stop_repeat => {},
            }
        }
    }.change;
}

pub fn toggleFullscreen(b: *rwm.XkbBindingV1, event: rwm.XkbBindingV1.Event, ctx: *Context) void {
    switch (event) {
        .pressed => {
            const data = bindDatas.get(b).?;
            const seat_data = ctx.seats.getPtr(data.seat).?;

            const focus = seat_data.focus orelse return;

            const win_data = ctx.wins.getPtr(focus) orelse return;

            win_data.fullscreen.toggle();

            ctx.dirty = true;
        },
        .released => {},
        .stop_repeat => {},
    }
}

pub fn toggleWorkspace(b: *rwm.XkbBindingV1, event: rwm.XkbBindingV1.Event, ctx: *Context) void {
    switch (event) {
        .pressed => {
            log.info("toggle keybinds", .{});
            const data = bindDatas.get(b).?;
            const seat_data = ctx.seats.getPtr(data.seat).?;

            const out = if (seat_data.focus) |w| focus: {
                const ws = Workspace.byWindow(ctx, w) orelse return;

                break :focus Output.byWorkspace(ctx, ws) orelse return;
            } else Output.byPointer(ctx, seat_data.pointer_pos) orelse return;

            const out_data = ctx.outs.getPtr(out) orelse return;

            const old = out_data.last_workspace orelse return;
            out_data.setWorkspace(ctx, old);

            ctx.dirty = true;
        },
        .released => {},
        .stop_repeat => {},
    }
}
