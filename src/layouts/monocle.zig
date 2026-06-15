const std = @import("std");
const wayland = @import("wayland");
const tributary = @import("tributary");
const mem = std.mem;
const math = std.math;
const meta = std.meta;

const wl = wayland.client.wl;
const rwm = wayland.client.river;
const log = std.log.scoped(.monocle);

const utils = tributary.utils;
const Window = @import("../window.zig");
const Output = @import("../output.zig");
const Seat = @import("../seat.zig");
const Workspace = @import("../workspace.zig");
const Tiler = @import("../tiler.zig");
const Context = @import("../context.zig");
const Config = tributary.Config;

const WT = Tiler.WT;
const ManageMap = Tiler.ManageMap;
const TC = Tiler.TileContext;
const Dir = utils.Dir;
const Error = Tiler.Error;

tiler: Tiler.tiler(@This()) = .{},
list: std.DoublyLinkedList = .{},

const Elem = struct {
    w: WT,
    node: std.DoublyLinkedList.Node = .{},
};

pub fn add(self: *@This(), ct: TC, win: WT) Error!void {
    const new = try ct.gpa.create(Elem);
    new.* = .{ .w = win };
    self.list.append(&new.node);
}

pub fn remove(self: *@This(), ct: TC, win: WT) void {
    var node = self.list.first;

    while (node) |n| {
        node = n.next;
        const par: *Elem = @fieldParentPtr("node", n);
        if (par.w != win) continue;
        self.list.remove(n);
        ct.gpa.destroy(par);
        return;
    }
}

pub fn manage(self: *@This(), ct: TC, boundary: utils.Rect2, map: *ManageMap) void {
    const focus = ct.focus orelse f: {
        const n = self.list.first orelse return;
        const par: *Elem = @fieldParentPtr("node", n);
        break :f par.w;
    };

    var node = self.list.first;

    var found: bool = false;

    while (node) |n| {
        node = n.next;
        const par: *Elem = @fieldParentPtr("node", n);
        const man_data = map.getPtr(par.w) orelse continue;
        if (par.w == focus) {
            man_data.* = .{
                .dims = boundary,
                .show = true,
            };
            found = true;
        } else {
            const l = boundary.pos;
            const r = utils.Vec2{ boundary.pos[0] + boundary.dim[0], boundary.pos[1] };

            man_data.* = .{
                .show = true,
                .dims = .{
                    .pos = if (!found) l else r,
                    .dim = .{ 0, boundary.dim[1] },
                },
            };
        }
    }
}

pub fn getWindow(self: *@This(), ct: TC, dir: Dir) ?WT {
    var node = self.list.first;
    while (node) |n| {
        node = n.next;
        const par: *Elem = @fieldParentPtr("node", n);
        if (par.w != ct.focus) continue;

        switch (dir) {
            .Left => {
                const prev = n.prev orelse self.list.last orelse return null;
                const preve: *Elem = @fieldParentPtr("node", prev);
                return preve.w;
            },
            .Right => {
                const next = n.next orelse self.list.first orelse return null;
                const nexte: *Elem = @fieldParentPtr("node", next);
                return nexte.w;
            },
            else => return null,
        }
    }

    return null;
}

pub fn move(self: *@This(), ct: TC, dir: Dir) Tiler.MoveResult {
    var node = self.list.first;
    while (node) |n| {
        node = n.next;
        const par: *Elem = @fieldParentPtr("node", n);
        if (par.w != ct.focus) continue;

        self.list.remove(n);

        switch (dir) {
            .Up, .Down => return .{ .escalate = .unit },
            .Left => {
                if (n.prev) |p| {
                    self.list.insertBefore(p, n);
                } else {
                    self.list.append(n);
                }
            },
            .Right => {
                if (n.prev) |p| {
                    self.list.insertAfter(p, n);
                } else {
                    self.list.prepend(n);
                }
            },
        }

        return .{ .done = {} };
    }

    return .{ .done = {} };
}
