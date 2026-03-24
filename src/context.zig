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

// state info
running: bool = true,
locked: bool = false,
child_env: std.process.EnvMap,

// global state
wins: utils.WLHashMap(rwm.WindowV1, Window) = .empty,
outs: utils.WLHashMap(rwm.OutputV1, Output) = .empty,
seats: utils.WLHashMap(rwm.SeatV1, Seat) = .empty,
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
    self.wins.clearAndFree(self.gpa);

    var outs = self.outs.iterator();
    while (outs.next()) |o| {
        Output.deinit(self, o.key_ptr.*);
    }
    self.outs.clearAndFree(self.gpa);

    var seats = self.seats.iterator();
    while (seats.next()) |s| {
        s.value_ptr.deinit(self, s.key_ptr.*);
    }
    self.seats.clearAndFree(self.gpa);

    for (self.workspaces.values()) |*w| {
        w.deinit(self);
    }

    self.manage_states.clearAndFree(self.gpa);

    self.workspaces.clearAndFree(self.gpa);

    self.wins.deinit(self.gpa);
    self.outs.deinit(self.gpa);
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

pub fn reload(self: *@This()) !void {
    self.anims = try Animations.load(&self.config);

    for (self.seats.keys()) |seat| {
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
