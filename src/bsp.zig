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
const pad = gap + border;

pub const Commands = enum(u32) {
    ChangeSplit,
};

fn scale(i: i32, f: f32) i32 {
    return @intFromFloat(@as(f32, @floatFromInt(i)) * f);
}

pub fn splitDim(v: utils.Vec2, OR: subTile.Mode, ratio: f32) utils.Vec2 {
    return switch (OR) {
        .V => .{
            .x = scale(v.x, ratio),
            .y = v.y,
        },
        .H => .{
            .x = v.x,
            .y = scale(v.y, ratio),
        },
    };
}

fn subDivide(r: utils.Rect2, OR: subTile.Mode, ratio: f32) meta.Tuple(&.{ utils.Rect2, utils.Rect2 }) {
    const split = splitDim(r.dim, OR, ratio);
    const lp = r.pos;
    const rp: utils.Vec2 = switch (OR) {
        .V => .{
            .x = r.pos.x + split.x,
            .y = r.pos.y,
        },
        .H => .{
            .x = r.pos.x,
            .y = r.pos.y + split.y,
        },
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
        if (dir == .Left and bounds.pos.x + bounds.dim.x <= descender.pos.x) return null;
        if (dir == .Right and descender.pos.x + descender.dim.x <= bounds.pos.x) return null;
        if (dir == .Up and bounds.pos.y + bounds.dim.y <= descender.pos.y) return null;
        if (dir == .Down and descender.pos.y + descender.dim.y <= bounds.pos.y) return null;

        if (dir == .Left or dir == .Right) {
            if (descender.pos.y + descender.dim.y <= bounds.pos.y) return null;
            if (descender.pos.y >= bounds.pos.y + bounds.dim.y) return null;
        } else {
            if (descender.pos.x + descender.dim.x <= bounds.pos.x) return null;
            if (descender.pos.x >= bounds.pos.x + bounds.dim.x) return null;
        }

        switch (t.*) {
            .Leaf => |_| {
                if (dir == .Up and descender.pos.y + descender.dim.y > bounds.pos.y) return null;
                if (dir == .Down and descender.pos.y < bounds.pos.y + bounds.dim.y) return null;
                if (dir == .Right and descender.pos.x < bounds.pos.x + bounds.dim.x) return null;
                if (dir == .Left and descender.pos.x + descender.dim.x > bounds.pos.x) return null;
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

    pub fn manage(self: *@This(), size: utils.Vec2, ctx: *Tiler.TileContext, out: *ManageMap) Tiler.Error!void {
        switch (self.*) {
            .Leaf => |w| {
                out.put(ctx.gpa, w, .{
                    .size = size.sub(.fromScalar(2 * pad)),
                    .state = .normal,
                    .border = if (w == ctx.focus) .blue else .gray,
                }) catch return error.OutOfMemory;
            },
            .Branch => |b| {
                const ds: utils.Vec2 = splitDim(size, b.direction, b.ratio);

                try b.left.manage(ds, ctx, out);
                try b.right.manage(ds, ctx, out);
            },
        }
    }

    pub fn render(self: *@This(), ctx: *Tiler.TileContext, rect: utils.Rect2, out: *RenderMap) Tiler.Error!void {
        switch (self.*) {
            .Leaf => |w| {
                out.put(ctx.gpa, w, .{
                    .show = true,
                    .position = rect.pos.add(.fromScalar(pad)),
                }) catch return error.OutOfMemory;
            },
            .Branch => |b| {
                const l, const r = subDivide(rect, b.direction, b.ratio);

                try b.left.render(ctx, l, out);
                try b.right.render(ctx, r, out);
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
            .V => cur.x < target.pos.x + @divTrunc(target.dim.x, 2),
            .H => cur.y < target.pos.y + @divTrunc(target.dim.y, 2),
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

pub fn manage(self: *@This(), ctx: *Tiler.TileContext, bound: utils.Rect2) Tiler.Error!ManageMap {
    const tree = &(self.tree orelse return .empty);

    var out: ManageMap = .empty;
    errdefer out.clearAndFree(ctx.gpa);

    try out.ensureTotalCapacity(ctx.gpa, tree.count());
    try tree.manage(bound.dim, ctx, &out);

    return out;
}

pub fn render(self: *@This(), ctx: *Tiler.TileContext, bound: utils.Rect2) Tiler.Error!RenderMap{
    const tree = &(self.tree orelse return .empty);
    var out: RenderMap = .empty;
    errdefer out.clearAndFree(ctx.gpa);

    try out.ensureTotalCapacity(ctx.gpa, tree.count());
    try tree.render(ctx, bound, &out);

    return out;
}

pub fn getWindow(self: *@This(), ctx: *Tiler.TileContext, dir: Tiler.Dir) ?WT {
    const tree = &(self.tree orelse return null);
    const win = ctx.focus orelse return null;
    const origin: utils.Rect2 = .{ .pos = .{ .x = 0, .y = 0 }, .dim = .{ .x = 1 << 16, .y = 1 << 16 } };
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
    switch(op) {
        .ChangeSplit => {
            const f = ctx.focus orelse return;
            const n = tree.parent(f) orelse return;
            n.Branch.direction = n.Branch.direction.other();
        }
    }
}
