const std = @import("std");
const wayland = @import("wayland");
const mem = std.mem;
const math = std.math;
const meta = std.meta;

const wl = wayland.client.wl;
const rwm = wayland.client.river;

const utils = @import("utils.zig");
const Window = @import("window.zig");
const Output = @import("output.zig");
const Seat = @import("seat.zig");
const Workspace = @import("workspace.zig");
const Tiler = @import("tiler.zig");
const Context = @import("context.zig");
const Config = @import("config.zig");

const WT = Tiler.WT;
const ManageMap = Tiler.ManageMap;
const RenderMap = Tiler.RenderMap;

const log = std.log.scoped(.bsp);

tree: ?subTile = null,
tiler: Tiler.tiler(@This()) = .{},
config: Conf = .{},

const Conf = struct {
    gaps: u31 = 3,
    split_override: ?utils.Vec2f = null,
};

pub const Command = enum(u32) {
    changeSplit,
};

pub fn splitDim(v: utils.Vec2f, OR: subTile.Mode, ratio: f32) utils.Vec2f {
    const fac: utils.Vec2f = switch (OR) {
        .V => .{ ratio, 1 },
        .H => .{ 1, ratio },
    };
    return v * fac;
}

fn subDivide(r: utils.Rect2f, OR: subTile.Mode, ratio: f32) meta.Tuple(&.{ utils.Rect2f, utils.Rect2f }) {
    const lsplit = splitDim(r.dim, OR, ratio);
    const rsplit = splitDim(r.dim, OR, 1 - ratio);
    const lp = r.pos;
    const rp: utils.Vec2f = switch (OR) {
        .V => .{ r.pos[0] + lsplit[0], r.pos[1] },
        .H => .{ r.pos[0], r.pos[1] + lsplit[1] },
    };

    return .{ .{ .pos = lp, .dim = lsplit }, .{ .pos = rp, .dim = rsplit } };
}

const subTile = union(enum) {
    const Mode = enum {
        V, // [|]
        H, // [-]

        pub fn other(self: @This()) @This() {
            return switch (self) {
                .V => .H,
                .H => .V,
            };
        }
    };

    Leaf: WT,
    Branch: struct {
        left: *subTile,
        right: *subTile,
        ratio: f32 = 0.5,
        direction: Mode,
    },

    pub fn parent(self: *@This(), win: WT) ?*@This() {
        switch (self.*) {
            .Leaf => return null,
            .Branch => |b| {
                if (meta.eql(b.left.*, subTile{ .Leaf = win }) or meta.eql(b.right.*, subTile{ .Leaf = win })) {
                    return self;
                }

                if (b.left.parent(win)) |res| return res;

                return b.right.parent(win);
            },
        }
    }

    // get next tile in direction `dir`
    pub fn getDir(t: *subTile, bounds: utils.Rect2f, descender: utils.Rect2f, dir: Tiler.Dir) ?*subTile {
        if (dir == .Left and bounds.pos[0] + bounds.dim[0] <= descender.pos[0]) return null;
        if (dir == .Right and descender.pos[0] + descender.dim[0] <= bounds.pos[0]) return null;
        if (dir == .Up and bounds.pos[1] + bounds.dim[1] <= descender.pos[1]) return null;
        if (dir == .Down and descender.pos[1] + descender.dim[1] <= bounds.pos[1]) return null;

        if (dir == .Left or dir == .Right) {
            if (descender.pos[1] + descender.dim[1] <= bounds.pos[1]) return null;
            if (descender.pos[1] >= bounds.pos[1] + bounds.dim[1]) return null;
        } else {
            if (descender.pos[0] + descender.dim[0] <= bounds.pos[0]) return null;
            if (descender.pos[0] >= bounds.pos[0] + bounds.dim[0]) return null;
        }

        switch (t.*) {
            .Leaf => |_| {
                if (dir == .Up and descender.pos[1] + descender.dim[1] > bounds.pos[1]) return null;
                if (dir == .Down and descender.pos[1] < bounds.pos[1] + bounds.dim[1]) return null;
                if (dir == .Right and descender.pos[0] < bounds.pos[0] + bounds.dim[0]) return null;
                if (dir == .Left and descender.pos[0] + descender.dim[0] > bounds.pos[0]) return null;
                return t;
            },
            .Branch => |b| {
                const l, const r = subDivide(descender, b.direction, b.ratio);
                switch (b.direction) {
                    .V => {
                        if (dir == .Left) {
                            if (b.right.getDir(bounds, r, dir)) |w| return w;
                            return b.left.getDir(bounds, l, dir);
                        } else {
                            if (b.left.getDir(bounds, l, dir)) |w| return w;
                            return b.right.getDir(bounds, r, dir);
                        }
                    },
                    .H => {
                        if (b.left.getDir(bounds, l, dir)) |w| {
                            return w;
                        } else {
                            return b.right.getDir(bounds, r, dir);
                        }
                    },
                }
            },
        }
    }

    pub fn find(self: *@This(), win: WT) ?*@This() {
        switch (self.*) {
            .Leaf => |w| {
                if (w == win) return self else return null;
            },
            .Branch => |b| {
                if (b.left.find(win)) |res| {
                    return res;
                } else {
                    return b.right.find(win);
                }
            },
        }
    }

    pub fn count(self: *@This()) usize {
        switch (self.*) {
            .Leaf => |_| return 1,
            .Branch => |b| return b.left.count() + b.right.count(),
        }
    }

    pub fn remove(self: *@This(), gpa: mem.Allocator, win: WT) ?*@This() {
        switch (self.*) {
            .Leaf => return null,
            .Branch => |b| {
                const left = b.left;
                const right = b.right;

                if (meta.activeTag(left.*) == .Leaf and left.Leaf == win) {
                    self.* = right.*;
                    gpa.destroy(right);
                    return left;
                }

                if (meta.activeTag(right.*) == .Leaf and right.Leaf == win) {
                    self.* = left.*;
                    gpa.destroy(left);
                    return right;
                }

                if (left.remove(gpa, win)) |r| return r;
                return right.remove(gpa, win);
            },
        }
    }

    pub fn dirSplit(self: *@This(), win: WT, dir: Tiler.Dir) ?*@This() {
        switch (self.*) {
            .Leaf => return null,
            .Branch => |b| {
                if (b.left.dirSplit(win, dir)) |ls| return ls;
                if (b.right.dirSplit(win, dir)) |ls| return ls;
                if (b.left.find(win)) |_| switch (b.direction) {
                    .V => return if (dir == .Right) self else null,
                    .H => return if (dir == .Down) self else null,
                } else if (b.right.find(win)) |_| switch (b.direction) {
                    .V => return if (dir == .Left) self else null,
                    .H => return if (dir == .Up) self else null,
                } else return null;
            },
        }
    }

    pub fn setSize(
        self: *@This(),
        target: WT,
        size: utils.Vec2f,
        anchor: Tiler.Anchor,
        rect: utils.Rect2f,
    ) ?utils.Vec2f {
        const space = rect.dim;
        switch (self.*) {
            .Leaf => |w| return if (w == target) size else null,
            .Branch => |*b| {
                const epsilon = 0.0005; // <- magic constant;
                const l, const r = subDivide(rect, b.direction, b.ratio);

                if (b.left.setSize(target, size, anchor, l)) |ls| switch (b.direction) {
                    .V => switch (anchor.h) {
                        .left => {
                            b.ratio = @min(ls[0] / space[0], 0.95);
                            return .{ space[0], ls[1] };
                        },
                        .right => {
                            if (rect.pos[0] < epsilon) return .{ space[0], ls[1] };
                            const rat = 1 - b.ratio;
                            const nw = @min(space[0] * rat + ls[0], 1);
                            b.ratio = @min(ls[0] / nw, 0.95);
                            return .{ nw, ls[1] };
                        },
                    },
                    .H => switch (anchor.v) {
                        .top => {
                            b.ratio = @min(ls[1] / space[1], 0.95);
                            return .{ ls[0], space[1] };
                        },
                        .bottom => {
                            if (rect.pos[1] < epsilon) return .{ ls[0], space[1] };
                            const rat = 1 - b.ratio;
                            const nh = @min(space[1] * rat + ls[1], 1);
                            b.ratio = @min(ls[1] / nh, 0.95);
                            return .{ ls[0], nh };
                        },
                    },
                };

                if (b.right.setSize(target, size, anchor, r)) |rs| switch (b.direction) {
                    .V => switch (anchor.h) {
                        .right => {
                            b.ratio = 1 - @min(rs[0] / space[0], 0.95);
                            return .{ space[0], rs[1] };
                        },
                        .left => {
                            if (rect.pos[0] + rect.dim[0] > 1 - epsilon) return .{ space[0], rs[1] };
                            const rat = b.ratio;
                            const nw = @min(space[0] * rat + rs[0], 1);
                            b.ratio = 1 - @min(rs[0] / nw, 0.95);
                            return .{ nw, rs[1] };
                        },
                    },
                    .H => switch (anchor.v) {
                        .bottom => {
                            b.ratio = 1 - @min(rs[1] / space[1], 0.95);
                            return .{ rs[0], space[1] };
                        },
                        .top => {
                            if (rect.pos[1] + rect.dim[1] > 1 - epsilon) return .{ rs[0], space[1] };
                            const rat = b.ratio;
                            const nh = @min(space[1] * rat + rs[1], 1);
                            b.ratio = 1 - @min(rs[1] / nh, 0.95);
                            return .{ rs[0], space[1] * rat + rs[1] };
                        },
                    },
                };

                return null;
            },
        }
    }

    pub fn subRect(self: @This(), start: utils.Rect2f, target: @This()) ?utils.Rect2f {
        if (meta.eql(self, target)) return start;
        switch (self) {
            .Leaf => return null,
            .Branch => |b| {
                const l, const r = subDivide(start, b.direction, b.ratio);
                if (b.left.subRect(l, target)) |ls| return ls;
                if (b.right.subRect(r, target)) |rs| return rs;
                return null;
            },
        }
    }

    pub fn Wrect(self: @This(), start: utils.Rect2f, win: WT) ?utils.Rect2f {
        switch (self) {
            .Leaf => |w| {
                if (win == w)
                    return start
                else
                    return null;
            },
            .Branch => |b| {
                const l, const r = subDivide(start, b.direction, b.ratio);
                if (b.left.Wrect(l, win)) |ls| {
                    return ls;
                }
                if (b.right.Wrect(r, win)) |rs| {
                    return rs;
                }
                return null;
            },
        }
    }

    pub fn manage(self: *@This(), conf: Conf, ctx: Tiler.TileContext, rect: utils.Rect2f, out: *ManageMap) void {
        switch (self.*) {
            .Leaf => |w| {
                if (out.contains(w)) {
                    const irect = utils.Rect2{ .dim = @intFromFloat(rect.dim), .pos = @intFromFloat(rect.pos) };
                    const s = irect.dim - @as(utils.Vec2, @splat(2 * conf.gaps));
                    out.putAssumeCapacity(w, .{
                        .show = true,
                        .dims = .{
                            .pos = irect.pos + @as(utils.Vec2, @splat(conf.gaps)),
                            .dim = s,
                        },
                        .state = .normal,
                        .border = if (w == ctx.focus) .blue else .gray,
                    });
                }
            },
            .Branch => |b| {
                const l, const r = subDivide(rect, b.direction, b.ratio);

                b.left.manage(conf, ctx, l, out);
                b.right.manage(conf, ctx, r, out);
            },
        }
    }
};

pub fn add(self: *@This(), ctx: Tiler.TileContext, win: WT) Tiler.Error!void {
    log.info("adding window {} to the tree", .{win.getId()});

    const tree = &(self.tree orelse {
        self.tree = .{ .Leaf = win };
        return;
    });

    const l = try ctx.gpa.create(subTile);
    const r = try ctx.gpa.create(subTile);

    const p: ?*subTile, const n = ins: {
        if (ctx.focus) |f| {
            if (tree.parent(f)) |found| {
                break :ins .{ found, found.find(f).? };
            }

            if (tree.find(f)) |found| {
                break :ins .{ null, found };
            }
        }

        var t = tree;
        var p: ?*subTile = null;
        while (meta.activeTag(t.*) == .Branch) {
            p = t;
            t = t.Branch.left;
        }

        break :ins .{ p, t };
    };

    const target = tree.Wrect(.unit, n.Leaf).?;

    const d = if (p) |par| par.Branch.direction.other() else .V;

    l.* = n.*;
    r.* = .{
        .Leaf = win,
    };
    n.* = .{
        .Branch = .{
            .left = l,
            .right = r,
            .direction = d,
        },
    };

    // smart splitting (as seen in hyprland for example)
    if (self.config.split_override orelse ctx.cursorPos) |cur| {
        log.info("adding with cursor pos {}", .{cur});
        log.info("target: {}, {}", .{ target.pos, target.dim });
        const cond = cur < target.pos + (target.dim / @as(utils.Vec2f, @splat(2)));
        if (switch (d) {
            .V => cond[0],
            .H => cond[1],
        }) {
            const t = n.Branch.left;
            n.Branch.left = n.Branch.right;
            n.Branch.right = t;
        }
    }
}

pub fn remove(self: *@This(), ctx: Tiler.TileContext, win: WT) void {
    const tree = &(self.tree orelse return);
    const rem = tree.remove(ctx.gpa, win);

    if (rem) |r|
        ctx.gpa.destroy(r)
    else if (meta.activeTag(tree.*) == .Leaf and tree.Leaf == win) {
        self.tree = null;
    }
}

pub fn manage(self: *@This(), ctx: Tiler.TileContext, bound: utils.Rect2, wins: *ManageMap) void {
    const tree = &(self.tree orelse return);
    const fbound = utils.Rect2f{ .dim = @floatFromInt(bound.dim), .pos = @floatFromInt(bound.pos) };

    tree.manage(self.config, ctx, fbound, wins);
}

pub fn getWindow(self: *@This(), ctx: Tiler.TileContext, dir: Tiler.Dir) ?WT {
    const tree = &(self.tree orelse return null);
    const win = ctx.focus orelse return null;
    const wrec = tree.Wrect(.unit, win) orelse return null;

    if (tree.getDir(wrec, .unit, dir)) |res|
        return res.Leaf
    else
        return null;
}

pub fn move(self: *@This(), ctx: Tiler.TileContext, dir: Tiler.Dir) void {
    const tree = &(self.tree orelse return);
    const win = ctx.focus orelse return;
    const wrec = tree.Wrect(.unit, win) orelse return;
    const par = tree.parent(win) orelse return;

    std.debug.assert(meta.activeTag(par.*) == .Branch);

    if (tree.getDir(wrec, .unit, dir)) |res| {
        const target = res.*;
        const tpar = tree.parent(target.Leaf).?;

        const pard = par.Branch.direction;

        if (par == tpar) {
            const t = par.Branch.left;
            par.Branch.left = par.Branch.right;
            par.Branch.right = t;
            return;
        }

        const new_split = tpar.Branch.direction.other();

        const wbr = if (meta.eql(par.Branch.left.*, .{ .Leaf = win })) par.Branch.left else par.Branch.right;
        const aux_ptr = if (meta.eql(par.Branch.left.*, .{ .Leaf = win })) par.Branch.right else par.Branch.left;

        // try to move new window to a predictable position;
        // TODO: still a bit scuffed, but it handles most easy cases
        const l, const r = lr: {
            const b = par.*.Branch;
            if (pard == new_split) {
                if (switch (new_split) {
                    .V => dir == .Up or dir == .Down,
                    .H => dir == .Left or dir == .Right,
                })
                    break :lr .{ b.left, b.right }
                else
                    break :lr .{ b.right, b.left };
            } else {
                if (dir == .Up or dir == .Left)
                    break :lr .{ aux_ptr, wbr }
                else
                    break :lr .{ wbr, aux_ptr };
            }
        };

        res.* = .{ .Branch = .{
            .direction = new_split,
            .ratio = 0.5,
            .left = l,
            .right = r,
        } };
        par.* = aux_ptr.*;
        aux_ptr.* = target;
    }
}

pub fn setSize(self: *@This(), ctx: Tiler.TileContext, size: utils.Vec2f, anchor: Tiler.Anchor) void {
    if (size[0] < 0 or size[1] < 0) return;
    const tree = &(self.tree orelse return);
    const win = ctx.focus orelse return;

    _ = tree.setSize(win, size, anchor, .unit);
}

pub fn command(self: *@This(), ctx: Tiler.TileContext, cmd: Tiler.Command) Tiler.Error!void {
    const tree = &(self.tree orelse return);
    const op: Command = std.enums.fromInt(Command, cmd.command) orelse return error.InvalidCommand;
    switch (op) {
        .changeSplit => {
            const f = ctx.focus orelse return;
            const n = tree.parent(f) orelse return;
            n.Branch.direction = n.Branch.direction.other();
        },
    }
}

pub fn loadConfig(self: *@This(), config: Config) Config.Error!void {
    self.config = try config.parseT(Conf);
}
