const std = @import("std");
const wayland = @import("wayland");
const mem = std.mem;
const math = std.math;
const meta = std.meta;

const wl = wayland.client.wl;
const rwm = wayland.client.river;

const utils = @import("../utils.zig");
const Window = @import("../window.zig");
const Output = @import("../output.zig");
const Seat = @import("../seat.zig");
const Workspace = @import("../workspace.zig");
const Tiler = @import("../tiler.zig");
const Context = @import("../context.zig");
const Config = @import("../config.zig");

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
    swapAllSplits,
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
                if (b.right.parent(win)) |res| return res;
                return null;
            },
        }
    }

    pub fn tileParent(self: *@This(), child: *@This()) ?*@This() {
        switch (self.*) {
            .Leaf => return null,
            .Branch => |b| {
                if (b.left == child or b.right == child) {
                    return self;
                }

                if (b.left.tileParent(child)) |res| return res;
                if (b.right.tileParent(child)) |res| return res;
                return null;
            },
        }
    }

    // get next tile in direction `dir`
    pub fn getDir(self: *@This(), win: Tiler.WT, dir: Tiler.Dir) union(enum) {
        success: *subTile,
        not_found: void,
        escalate: utils.Rect2f,
    } {
        switch (self.*) {
            .Leaf => |w| {
                if (w == win) return .{ .escalate = .unit };
            },
            .Branch => |b| {
                switch (b.left.getDir(win, dir)) {
                    .success => |succ| return .{ .success = succ },
                    .not_found => {},
                    .escalate => |rect| {
                        const fac: utils.Vec2f = switch (b.direction) {
                            .V => .{ b.ratio, 1 },
                            .H => .{ 1, b.ratio },
                        };
                        const l = utils.Rect2f{ .pos = rect.pos * fac, .dim = rect.dim * fac };
                        if ((b.direction == .V and dir == .Right) or
                            (b.direction == .H and dir == .Down))
                        {
                            _, const r = subDivide(.unit, b.direction, b.ratio);
                            const target, _ = b.right.findClosest(dir, r, l);
                            return .{ .success = target };
                        } else {
                            return .{ .escalate = l };
                        }
                    },
                }
                switch (b.right.getDir(win, dir)) {
                    .success => |succ| return .{ .success = succ },
                    .not_found => {},
                    .escalate => |rect| {
                        const fac: utils.Vec2f = switch (b.direction) {
                            .V => .{ 1 - b.ratio, 1 },
                            .H => .{ 1, 1 - b.ratio },
                        };
                        const off: utils.Vec2f = switch (b.direction) {
                            .V => .{ b.ratio, 0 },
                            .H => .{ 0, b.ratio },
                        };
                        const r: utils.Rect2f = .{ .pos = rect.pos * fac + off, .dim = rect.dim * fac };
                        if ((b.direction == .V and dir == .Left) or
                            (b.direction == .H and dir == .Up))
                        {
                            const l, _ = subDivide(.unit, b.direction, b.ratio);
                            const target, _ = b.left.findClosest(dir, l, r);
                            return .{ .success = target };
                        } else {
                            return .{ .escalate = r };
                        }
                    },
                }
            },
        }
        return .{ .not_found = {} };
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
            .Leaf => return 1,
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

    pub fn findClosest(self: *@This(), dir: Tiler.Dir, remaining: utils.Rect2f, rect: utils.Rect2f) struct { *@This(), utils.Rect2f } {
        switch (self.*) {
            .Leaf => return .{ self, remaining },
            .Branch => |b| {
                const lr, const rr = subDivide(remaining, b.direction, b.ratio);
                switch (b.direction) {
                    .V => switch (dir) {
                        .Right => return b.left.findClosest(dir, lr, rect),
                        .Left => return b.right.findClosest(dir, rr, rect),
                        .Up, .Down => {
                            const l = b.left.findClosest(dir, lr, rect);
                            const r = b.right.findClosest(dir, rr, rect);
                            _, const lrec = l;
                            _, const rrec = r;

                            const li = utils.intersect(f32, .{ lrec.pos[0], lrec.pos[0] + lrec.dim[0] }, .{ rect.pos[0], rect.pos[0] + rect.dim[0] });
                            const ri = utils.intersect(f32, .{ rrec.pos[0], rrec.pos[0] + rrec.dim[0] }, .{ rect.pos[0], rect.pos[0] + rect.dim[0] });

                            if (li >= ri) return l;
                            return r;
                        },
                    },
                    .H => switch (dir) {
                        .Down => return b.left.findClosest(dir, lr, rect),
                        .Up => return b.right.findClosest(dir, rr, rect),
                        .Left, .Right => {
                            const l = b.left.findClosest(dir, lr, rect);
                            const r = b.right.findClosest(dir, rr, rect);
                            _, const lrec = l;
                            _, const rrec = r;

                            const li = utils.intersect(f32, .{ lrec.pos[1], lrec.pos[1] + lrec.dim[1] }, .{ rect.pos[1], rect.pos[1] + rect.dim[1] });
                            const ri = utils.intersect(f32, .{ rrec.pos[1], rrec.pos[1] + rrec.dim[1] }, .{ rect.pos[1], rect.pos[1] + rect.dim[1] });

                            if (li > ri) return l;
                            return r;
                        },
                    },
                }
            },
        }
    }

    fn doMove(
        win: Tiler.WT,
        par: *@This(),
        target: *@This(),
        dir: Tiler.Dir,
        from: utils.Rect2f,
        to: utils.Rect2f,
        tarOr: Mode,
    ) void {
        const tarval = target.*;
        const source, const aux =
            if (meta.eql(par.Branch.left.*, .{ .Leaf = win }))
                .{ par.Branch.left, par.Branch.right }
            else if (meta.eql(par.Branch.right.*, .{ .Leaf = win }))
                .{ par.Branch.right, par.Branch.left }
            else
                unreachable;

        log.info("from: {}, to: {}", .{ from, to });
        const branch = order: {
            if (aux == target) {
                break :order subTile{ .Branch = .{
                    .left = par.Branch.right,
                    .right = par.Branch.left,
                    .direction = par.Branch.direction,
                } };
            }

            switch (tarOr) {
                .H => {
                    switch (dir) {
                        .Right => break :order subTile{ .Branch = .{
                            .left = source,
                            .right = aux,
                            .direction = .V,
                        } },
                        .Left => break :order subTile{ .Branch = .{
                            .right = source,
                            .left = aux,
                            .direction = .V,
                        } },
                        .Up, .Down => break :order if (from.pos[0] < to.pos[0] + to.dim[0] / 2)
                            subTile{ .Branch = .{
                                .left = source,
                                .right = aux,
                                .direction = .V,
                            } }
                        else
                            subTile{ .Branch = .{
                                .right = source,
                                .left = aux,
                                .direction = .V,
                            } },
                    }
                },
                .V => switch (dir) {
                    .Down => break :order subTile{ .Branch = .{
                        .left = source,
                        .right = aux,
                        .direction = .H,
                    } },
                    .Up => break :order subTile{ .Branch = .{
                        .right = source,
                        .left = aux,
                        .direction = .H,
                    } },
                    .Left, .Right => break :order if (from.pos[1] < to.pos[1] + to.dim[1] / 2)
                        subTile{ .Branch = .{
                            .left = source,
                            .right = aux,
                            .direction = .H,
                        } }
                    else
                        subTile{ .Branch = .{
                            .right = source,
                            .left = aux,
                            .direction = .H,
                        } },
                },
            }
        };

        target.* = branch;
        par.* = aux.*;
        aux.* = tarval;
    }

    pub fn moveDir(self: *@This(), win: Tiler.WT, dir: Tiler.Dir) union(enum) {
        success: void,
        not_found: void,
        escalate: utils.Rect2f,
    } {
        switch (self.*) {
            .Leaf => |w| {
                if (w == win) return .{ .escalate = .unit };
            },
            .Branch => |b| {
                switch (b.left.moveDir(win, dir)) {
                    .success => return .{ .success = {} },
                    .not_found => {},
                    .escalate => |rect| {
                        const fac: utils.Vec2f = switch (b.direction) {
                            .V => .{ b.ratio, 1 },
                            .H => .{ 1, b.ratio },
                        };
                        const l = utils.Rect2f{ .pos = rect.pos * fac, .dim = rect.dim * fac };
                        if ((b.direction == .V and dir == .Right) or
                            (b.direction == .H and dir == .Down))
                        {
                            _, const r = subDivide(.unit, b.direction, b.ratio);
                            const target, const tarec = b.right.findClosest(dir, r, l);
                            const tarpar = self.tileParent(target).?;
                            doMove(win, self.parent(win).?, target, dir, l, tarec, tarpar.Branch.direction);
                            return .{ .success = {} };
                        } else {
                            return .{ .escalate = l };
                        }
                    },
                }
                switch (b.right.moveDir(win, dir)) {
                    .success => return .{ .success = {} },
                    .not_found => {},
                    .escalate => |rect| {
                        const fac: utils.Vec2f = switch (b.direction) {
                            .V => .{ 1 - b.ratio, 1 },
                            .H => .{ 1, 1 - b.ratio },
                        };
                        const off: utils.Vec2f = switch (b.direction) {
                            .V => .{ b.ratio, 0 },
                            .H => .{ 0, b.ratio },
                        };
                        const r: utils.Rect2f = .{ .pos = rect.pos * fac + off, .dim = rect.dim * fac };
                        if ((b.direction == .V and dir == .Left) or
                            (b.direction == .H and dir == .Up))
                        {
                            const l, _ = subDivide(.unit, b.direction, b.ratio);
                            const target, const tarec = b.left.findClosest(dir, l, r);
                            const tarpar = self.tileParent(target).?;
                            doMove(win, self.parent(win).?, target, dir, r, tarec, tarpar.Branch.direction);
                            return .{ .success = {} };
                        } else {
                            return .{ .escalate = r };
                        }
                    },
                }
            },
        }
        return .{ .not_found = {} };
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

    switch (tree.getDir(win, dir)) {
        .success => |res| return res.Leaf,
        else => return null,
    }
}

pub fn move(self: *@This(), ctx: Tiler.TileContext, dir: Tiler.Dir) Tiler.MoveResult {
    const tree = &(self.tree orelse return .{ .done = {} });
    const focus = ctx.focus orelse return .{ .done = {}};

    switch (tree.moveDir(focus, dir)) {
        .escalate => |r| return .{ .escalate = r },
        else => return .{ .done = {} },
    }
}

pub fn setSize(self: *@This(), ctx: Tiler.TileContext, size: utils.Vec2f, anchor: Tiler.Anchor) void {
    if (size[0] < 0 or size[1] < 0) return;
    const tree = &(self.tree orelse return);
    const win = ctx.focus orelse return;

    _ = tree.setSize(win, size, anchor, .unit);
}

fn swapAllSplits(self: *subTile) void {
    switch (self.*) {
        .Leaf => {},
        .Branch => |*b| {
            b.direction = b.direction.other();
            swapAllSplits(b.left);
            swapAllSplits(b.right);
        },
    }
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
        .swapAllSplits => swapAllSplits(tree),
    }
}

pub fn loadConfig(self: *@This(), config: Config) Config.Error!void {
    self.config = try config.parseT(Conf);
}
