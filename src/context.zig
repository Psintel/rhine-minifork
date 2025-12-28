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

// protocols
wm: *rwm.WindowManagerV1,
shell: *rwm.LayerShellV1,
bind: *rwm.XkbBindingsV1,

// state info
running: bool = true,
locked: bool = false,
workspaces: [1]Workspace,

last_active: ?*rwm.SeatV1 = null, // last seat with activity

alloc: mem.Allocator,

wins: utils.WLHashMap(rwm.WindowV1, Window) = .empty,
outs: utils.WLHashMap(rwm.OutputV1, Output) = .empty,
seats: utils.WLHashMap(rwm.SeatV1, Seat) = .empty,

shouldClose: std.ArrayList(*rwm.WindowV1) = .empty,
dirty: bool = false,

pub fn deinit(self: *@This()) void {
    var wins = self.wins.iterator();
    while (wins.next()) |w| {
        w.value_ptr.deinit(self, w.key_ptr.*);
    }

    var outs = self.outs.iterator();
    while (outs.next()) |o| {
        o.value_ptr.deinit(self, o.key_ptr.*);
    }

    var seats = self.seats.iterator();
    while (seats.next()) |s| {
        s.value_ptr.deinit(self, s.key_ptr.*);
    }

    for (&self.workspaces) |*w| {
        w.deinit(self);
    }

    self.wins.deinit(self.alloc);
    self.outs.deinit(self.alloc);
    self.seats.deinit(self.alloc);
}
