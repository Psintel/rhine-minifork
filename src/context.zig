const std = @import("std");
const wayland = @import("wayland");
const mem = std.mem;

const wl = wayland.client.wl;
const rwm = wayland.client.river;
const wp = wayland.client.wp;

const utils = @import("utils.zig");
const Window = @import("window.zig");
const Output = @import("output.zig");
const Seat = @import("seat.zig");
const Pointer = @import("pointer.zig");
const Workspace = @import("workspace.zig");
const Rules = @import("rules.zig");
const Config = @import("config.zig");
const commands = @import("commands.zig");
const Tiler = @import("tiler.zig");
const Animations = @import("animations.zig");

const keybinds = @import("keybinds.zig");
const pointerbinds = @import("pointer_binds.zig");

// base allocator
gpa: mem.Allocator,

// protocol interfaces
wm: *rwm.WindowManagerV1,
shell: *rwm.LayerShellV1,
bind: *rwm.XkbBindingsV1,
cursor_shape: *wp.CursorShapeManagerV1,

// state info
running: bool = true,
locked: bool = false,
child_env: std.process.EnvMap,

// global state
wins: utils.WLHashMap(rwm.WindowV1, Window) = .empty,
outs: utils.WLHashMap(rwm.OutputV1, Output) = .empty,
shell_outs: utils.WLHashMap(rwm.LayerShellOutputV1, *rwm.OutputV1) = .empty,
seats: utils.WLHashMap(rwm.SeatV1, Seat) = .empty,
pointers: utils.WLHashMap(wl.Pointer, Pointer) = .empty,
wl_seats: utils.WlGlobal(wl.Seat, Seat.Wl) = .{},
wl_outs: utils.WlGlobal(wl.Output, Output.Wl) = .{},
workspaces: std.AutoArrayHashMapUnmanaged(Workspace.WS, Workspace) = .empty,
config: Config,
rules: std.ArrayList(Rules) = .empty,
commands_queue: commands.Queue = .{},
anims: Animations = .{},

// short-lived state
last_active: ?*rwm.SeatV1 = null, // last seat with activity
dirty: bool = false,

should_close: std.ArrayList(*rwm.WindowV1) = .empty,
should_open: std.ArrayList(*rwm.WindowV1) = .empty, // uninitalized windows
orphans: std.ArrayList(*rwm.WindowV1) = .empty, // initialized windows that need to be reassigned
manage_states: Tiler.ManageMap = .empty,

// weird posix thingy:
events: std.fs.File,

pub fn deinit(self: *@This()) void {
    var wins = self.wins.iterator();
    while (wins.next()) |w| {
        w.value_ptr.deinit(self, w.key_ptr.*);
    }
    self.wins.deinit(self.gpa);

    var outs = self.outs.iterator();
    while (outs.next()) |o| {
        Output.deinit(self, o.key_ptr.*);
    }
    self.outs.deinit(self.gpa);

    var seats = self.seats.iterator();
    while (seats.next()) |s| {
        s.value_ptr.deinit(self, s.key_ptr.*);
    }
    self.seats.deinit(self.gpa);


    for (self.workspaces.values()) |*w| {
        w.deinit(self);
    }

    self.manage_states.clearAndFree(self.gpa);

    self.workspaces.clearAndFree(self.gpa);

    self.wins.deinit(self.gpa);
    self.outs.deinit(self.gpa);
    self.shell_outs.deinit(self.gpa);
    self.seats.deinit(self.gpa);
    self.config.deinit(self.gpa);

    self.should_close.deinit(self.gpa);
    self.should_open.deinit(self.gpa);

    self.child_env.deinit();
}

pub fn loadEnv(self: *@This()) !void {
    const env = try self.config.sub("env");

    var iter = env.values.keyIterator();

    while (iter.next()) |name| {
        const confval = try env.getArgs(name.*) orelse continue;

        const key = try self.gpa.dupe(u8, name.*);
        errdefer self.gpa.free(key);
        const val = try self.gpa.dupe(u8, confval.args);
        errdefer self.gpa.free(val);

        try self.child_env.putMove(key, val);
    }
}

pub fn regListener(reg: *wl.Registry, e: wl.Registry.Event, ctx: *@This()) void {
    switch (e) {
        .global => |glob| {
            if (utils.handleIface(reg, glob, wl.Seat, 4)) |seat| {
                ctx.wl_seats.map.put(ctx.gpa, glob.name, seat) catch return;
                ctx.wl_seats.data.put(ctx.gpa, seat, .{ .global = glob.name }) catch return;
                seat.setListener(*@This(), Seat.Wl.listener, ctx);
            }
        },
        .global_remove => |rem| {
            if (ctx.wl_seats.map.fetchSwapRemove(rem.name)) |kv| {
                const seat = kv.value;
                defer seat.destroy();
                if (ctx.wl_seats.data.fetchSwapRemove(seat)) |data| data.value.deinit(ctx.gpa);
                return;
            }
        },
    }
}

pub fn addSeat(self: *@This(), reg: *wl.Registry, _seat: u32) !void {
    const seat = try reg.bind(_seat, wl.Seat, 4);
    errdefer seat.destroy();
    try self.wl_seats.map.put(self.gpa, _seat, seat);
    errdefer _ = self.wl_seats.map.swapRemove(_seat);
    try self.wl_seats.data.put(self.gpa, seat, .{ .global = _seat });
    seat.setListener(*@This(), Seat.Wl.listener, self);
}

pub fn addOut(self: *@This(), reg: *wl.Registry, _out: u32) !void {
    const out = try reg.bind(_out, wl.Output, 4);
    errdefer out.destroy();
    try self.wl_outs.map.put(self.gpa, _out, out);
    errdefer _ = self.wl_outs.map.swapRemove(_out);
    try self.wl_outs.data.put(self.gpa, out, .{ .global = _out });
    out.setListener(*@This(), Output.Wl.listener, self);
}

pub fn reload(self: *@This()) !void {
    self.anims = try Animations.load(&self.config);

    for (self.seats.keys()) |seat| {
        try Seat.setup(seat, self);
        // reload keybinds
        keybinds.unregister(self, seat);
        try keybinds.registerAll(self, seat);
        // reload pointer binds
        pointerbinds.unregister(self, seat);
        try pointerbinds.register(self, seat);
    }

    const lc = try self.config.sub("layout_config");

    for (self.workspaces.values()) |*ws| {
        try ws.loadConfig(lc);
    }

    try self.loadEnv();
}

// not allowed to fail
pub fn orphan(ctx: *@This(), win: *rwm.WindowV1) void {
    ctx.orphans.append(ctx.gpa, win) catch |er| {
        std.log.err("lost window {} after trying to orphan it: {}", .{ win, er });
    };
}
