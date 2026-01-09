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

const WT = Tiler.WT;
const ManageMap = Tiler.ManageMap;
const RenderMap = Tiler.RenderMap;

const log = std.log.scoped(.bsp);

const border = 2;
const gap = 1;
const pad: utils.Vec2 = @splat(gap + border);

pub const Commands = enum(u32) {
    ChangeSplit,
};

fn scale(i: i32, f: f32) i32 {
    return @intFromFloat(@as(f32, @floatFromInt(i)) * f);
}

fn vscale(i: utils.Vec2, f: utils.Vec2f) utils.Vec2 {
    return @intFromFloat(@as(utils.Vec2f, @floatFromInt(i)) * f);
}

pub fn splitDim(v: utils.Vec2, OR: subTile.Mode, ratio: f32) utils.Vec2 {
    const fac: utils.Vec2f = switch (OR) {
        .V => .{ ratio, 1 },
        .H => .{ 1, ratio },
    };

    return vscale(v, fac);
}

fn subDivide(r: utils.Rect2, OR: subTile.Mode, ratio: f32) meta.Tuple(&.{ utils.Rect2, utils.Rect2 }) {
    const split = splitDim(r.dim, OR, ratio);
    const lp = r.pos;
    const rp: utils.Vec2 = switch (OR) {
        .V => .{ r.pos[0] + split[0], r.pos[1] },
        .H => .{ r.pos[0], r.pos[1] + split[1] },
    };

    return .{ .{ .pos = lp, .dim = split }, .{ .pos = rp, .dim = split } };
}

const subTile = union(enum) {
    const Mode = enum {
        V,
        H,

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
    pub fn getDir(t: *subTile, bounds: utils.Rect2, descender: utils.Rect2, dir: Tiler.Dir) ?*subTile {
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

    pub fn Wrect(self: @This(), start: utils.Rect2, win: WT) ?utils.Rect2 {
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

    pub fn manage(self: *@This(), ctx: *Tiler.TileContext, rect: utils.Rect2, out: *ManageMap) void {
        switch (self.*) {
            .Leaf => |w| {
                if (out.contains(w)) {
                    const s = rect.dim - @as(utils.Vec2, @splat(2)) * pad;
                    out.putAssumeCapacity(w, .{
                        .show = true,
                        .position = rect.pos + pad,
                        .size = s,
                        .state = .normal,
                        .border = if (w == ctx.focus) .blue else .gray,
                    });
                }
            },
            .Branch => |b| {
                const l, const r = subDivide(rect, b.direction, b.ratio);

                b.left.manage(ctx, l, out);
                b.right.manage(ctx, r, out);
            },
        }
    }
};

tree: ?subTile = null,
tiler: Tiler.tiler(@This()) = .{},

pub fn add(self: *@This(), ctx: *Tiler.TileContext, win: WT) Tiler.Error!void {
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
    if (ctx.cursorPos) |cur| {
        log.info("adding with cursor pos {}", .{cur});
        if (switch (d) {
            .V => cur[0] < target.pos[0] + @divTrunc(target.dim[0], 2),
            .H => cur[1] < target.pos[1] + @divTrunc(target.dim[1], 2),
        }) {
            const t = n.Branch.left;
            n.Branch.left = n.Branch.right;
            n.Branch.right = t;
        }
    }
}

pub fn remove(self: *@This(), ctx: *Tiler.TileContext, win: WT) void {
    const tree = &(self.tree orelse return);
    const rem = tree.remove(ctx.gpa, win);

    if (rem) |r|
        ctx.gpa.destroy(r)
    else if (meta.activeTag(tree.*) == .Leaf and tree.Leaf == win) {
        self.tree = null;
    }
}

pub fn manage(self: *@This(), ctx: *Tiler.TileContext, bound: utils.Rect2, wins: *ManageMap) void {
    const tree = &(self.tree orelse return);

    tree.manage(ctx, bound, wins);
}

pub fn getWindow(self: *@This(), ctx: *Tiler.TileContext, dir: Tiler.Dir) ?WT {
    const tree = &(self.tree orelse return null);
    const win = ctx.focus orelse return null;
    const origin: utils.Rect2 = .unit;
    const wrec = tree.Wrect(origin, win) orelse return null;

    if (tree.getDir(wrec, origin, dir)) |res|
        return res.Leaf
    else
        return null;
}

pub fn move(self: *@This(), ctx: *Tiler.TileContext, dir: Tiler.Dir) void {
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

        // if (pard == new_split) {
        //     res.* = parent_data;
        // } else {
        //     const t = res.Branch.left;
        //     res.Branch.left = res.Branch.right;
        //     res.Branch.right = t;
        // }
    }
}

pub fn command(self: *@This(), ctx: *Tiler.TileContext, cmd: Tiler.Command) Tiler.Error!void {
    const tree = &(self.tree orelse return);
    const op: Commands = std.enums.fromInt(Commands, cmd.command) orelse return error.InvalidCommand;
    switch (op) {
        .ChangeSplit => {
            const f = ctx.focus orelse return;
            const n = tree.parent(f) orelse return;
            n.Branch.direction = n.Branch.direction.other();
        },
    }
}
