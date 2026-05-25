const wayland = @import("wayland");
const wl = wayland.client.wl;

const std = @import("std");
const math = std.math;
const meta = std.meta;
const mem = std.mem;
const fmt = std.fmt;
const posix = std.posix;

pub const Vec2 = Vec2T(i32);
pub const Vec2f = Vec2T(f32);
pub const Rect2 = Rect2T(i32);
pub const Rect2f = Rect2T(f32);

pub const Dir = enum {
    Left,
    Right,
    Up,
    Down,
};

pub const Transaction = enum {
    no,
    soon,
    yes,
    was,

    pub fn toggle(self: *@This()) void {
        switch (self.*) {
            .no => self.* = .soon,
            .yes => self.* = .was,
            .soon => self.* = .no,
            .was => self.* = .yes,
        }
    }

    pub fn off(self: *@This()) void {
        switch (self.*) {
            .yes => self.* = .was,
            .soon => self.* = .no,
            .no, .was => {},
        }
    }

    pub fn on(self: *@This()) void {
        switch (self.*) {
            .no => self.* = .soon,
            .was => self.* = .yes,
            .yes, .soon => {},
        }
    }

    pub fn isOn(self: @This()) bool {
        return switch (self) {
            .yes, .soon => true,
            .no, .was => false,
        };
    }
};

fn Vec2T(T: type) type {
    return @Vector(2, T);
}

pub fn int2Float(v: Vec2) Vec2f {
    return @floatFromInt(v);
}

pub fn float2Int(v: Vec2f) Vec2 {
    return @intFromFloat(v);
}

fn Rect2T(T: type) type {
    const inf = @typeInfo(T);
    const inf_t = std.meta.activeTag(inf);
    return struct {
        pos: Vec2T(T),
        dim: Vec2T(T),

        pub const unit: @This() = .{
            .pos = @splat(0),
            .dim = switch (inf_t) {
                .int => @splat(1 << 16),
                .float => @splat(1),
                else => @compileError("Rect2T doesn't support non-ints or floats"),
            },
        };

        pub fn constrain(self: @This(), pos: Vec2T(T)) Vec2T(T) {
            return @min(self.pos + self.dim, @max(self.pos, pos));
        }

        pub fn bumpCenter(self: @This(), dir: Dir, off: T) Vec2T(T) {
            return switch (dir) {
                .Left => .{ self.pos[0] - off, self.pos[1] + self.dim[1] / 2 },
                .Right => .{ self.pos[0] + self.dim[0] + off, self.pos[1] + self.dim[1] / 2 },
                .Up => .{ self.pos[0] + self.dim[0] / 2, self.pos[1] - off },
                .Down => .{ self.pos[0] + self.dim[0] / 2, self.pos[1] + self.dim[1] + off },
            };
        }

        pub fn inside(self: @This(), pos: Vec2T(T)) bool {
            const near = self.pos;
            const far = self.pos + self.dim;

            return near[0] <= pos[0] and pos[0] < far[0] and
                near[1] <= pos[1] and pos[1] < far[1];
        }

        pub fn distance(self: @This(), other: @This()) Vec2T(T) {
            const d = @select(
                T,
                self.pos < other.pos,
                self.pos + self.dim - other.pos,
                other.pos + other.dim - self.pos,
            );
            return @max(d, @as(Vec2T(T), @splat(0)));
        }

        pub fn shift(self: @This(), offset: Vec2T(T)) @This() {
            return .{
                .pos = self.pos + offset,
                .dim = self.dim,
            };
        }

        pub fn pad(self: @This(), padding: T) @This() {
            return .{
                .pos = self.pos - @as(Vec2T(T), @splat(padding)),
                .dim = self.dim + @as(Vec2T(T), @splat(2 * padding)),
            };
        }

        pub fn intersect(self: @This(), other: @This()) @This() {
            const left = @max(self.pos, other.pos);
            const right = @min(self.pos + self.dim, other.pos + other.dim);
            return .{
                .pos = left,
                .dim = @max(right - left, Vec2T(T){ 0, 0 }),
            };
        }

        pub fn scale(self: @This(), fac: f32) @This() {
            switch (inf_t) {
                .int => {
                    var dim: Vec2f = @floatFromInt(self.dim);
                    dim *= @splat(fac);
                    var pd = int2Float(self.dim) - dim;
                    pd /= @splat(2);
                    return .{
                        .pos = @intFromFloat(int2Float(self.pos) + pd),
                        .dim = @intFromFloat(dim),
                    };
                },
                .float => {
                    var dim = self.dim;
                    dim *= @splat(fac);
                    var pd = self.dim - dim;
                    pd /= @splat(2);
                    return .{
                        .pos = self.pos + pd,
                        .dim = dim,
                    };
                },
                else => @compileError("Rect2T doesn't support non-ints or floats"),
            }
        }
    };
}

pub fn relToAbs(frame: Rect2, rel: Vec2f) Vec2 {
    const rp = float2Int(int2Float(frame.dim) * rel);
    return rp + frame.pos;
}

pub fn absToRel(frame: Rect2, rel: Vec2) Vec2f {
    const rp = int2Float(rel - frame.pos);
    return rp / int2Float(frame.dim);
}

pub fn overlap(T: type, a: struct { T, T }, b: struct { T, T }) struct { T, T } {
    return .{ @max(a[0], b[0]), @min(a[1], b[1]) };
}

pub fn interval(T: type, a: struct { T, T }) T {
    if (a[0] >= a[1]) return 0;
    return a[1] - a[0];
}

pub fn intersect(T: type, a: struct { T, T }, b: struct { T, T }) T {
    return interval(T, overlap(T, a, b));
}

pub const Color = struct {
    r: u32,
    g: u32,
    b: u32,
    a: u32,

    pub const blue: @This() = .{ // #4793cc
        .r = 0x4700_0000,
        .g = 0x9300_0000,
        .b = 0xCC00_0000,
        .a = 0xFFFF_FFFF,
    };

    pub const green: @This() = .{ // #47cc93
        .r = 0x4700_0000,
        .g = 0xCC00_0000,
        .b = 0x9300_0000,
        .a = 0xFFFF_FFFF,
    };

    pub const gray: @This() = .{
        .r = 0x2000_0000,
        .g = 0x2000_0000,
        .b = 0x2000_0000,
        .a = 0xFFFF_FFFF,
    };
};

pub fn checkIface(glob: @TypeOf(@as(wl.Registry.Event, undefined).global), iface: type, version: u32) ?u32 {
    if (mem.orderZ(u8, glob.interface, iface.interface.name) == .eq) {
        // fail if we can't satisfy our version
        if (glob.version < version) {
            std.process.fatal(
                "only have version {} of interface {s} when at least {} is required",
                .{ glob.version, glob.interface, version },
            );
        }
        return glob.name;
    }

    return null;
}

pub fn handleIface(reg: *wl.Registry, glob: @TypeOf(@as(wl.Registry.Event, undefined).global), iface: type, version: u32) ?*iface {
    if (checkIface(glob, iface, version)) |n| return reg.bind(n, iface, version) catch null;
    return null;
}

pub fn IdHashMap(K: type, V: type) type {
    return std.ArrayHashMapUnmanaged(K, V, struct {
        pub fn hash(_: @This(), k: K) u32 {
            return k.getId();
        }
        pub fn eql(_: @This(), k1: K, k2: K, _: usize) bool {
            return meta.eql(k1, k2);
        }
    }, false);
}

pub fn WLHashMap(IFace: type, container: type) type {
    const T = *IFace;
    return IdHashMap(T, container);
}

pub fn maybe(I: type, O: type, v: ?I, f: fn (I) ?O) ?O {
    if (v) |rv|
        return f(rv)
    else
        return null;
}

pub fn WlGlobal(global: type, container: type) type {
    return struct {
        map: std.AutoArrayHashMapUnmanaged(u32, *global) = .empty,
        data: WLHashMap(global, container) = .empty,

        pub fn get(self: *const @This(), id: u32) ?container {
            if (self.map.get(id)) |glob| return self.data.get(glob);
            return null;
        }

        pub fn getPtr(self: *@This(), id: u32) ?*container {
            if (self.map.get(id)) |glob| return self.data.getPtr(glob);
            return null;
        }

        pub fn deinit(self: @This(), gpa: mem.Allocator) void {
            for (self.data.values()) |s| s.deinit(gpa);
            for (self.wl_seats.map.values()) |s| s.destroy();
            self.data.deinit(gpa);
            self.map.deinit(gpa);
        }
    };
}

pub fn pipe(flags: posix.O) ![2]posix.fd_t {
    var out: [2]posix.fd_t = undefined;
    if (posix.system.pipe2(&out, flags) != 0) return error.Error;

    return out;
}

pub fn MemIter(T: type) type {
    return struct {
        iters: []const []T,
        big: usize = 0,
        small: usize = 0,

        pub fn init(iter: []const []T) @This() {
            return .{ .iters = iter };
        }

        pub fn reset(self: *@This()) void {
            self.big = 0;
            self.small = 0;
        }

        pub fn next(self: *@This()) ?T {
            var arr = self.iters[self.big];
            while (self.small >= arr.len) {
                self.small = 0;
                self.big += 1;
                if (self.big >= self.iters.len) return null;
                arr = self.iters[self.big];
            }

            const ind = self.small;
            self.small += 1;

            return arr[ind];
        }
    };
}

pub fn memIter(T: type, iter: []const []T) MemIter(T) {
    return .init(iter);
}

test {
    const a = Rect2{ .pos = .{ 0, 0 }, .dim = .{ 20, 20 } };
    const b = Rect2{ .pos = .{ 25, 25 }, .dim = .{ 100, 100 } };

    std.debug.print("{}\n", .{a.intersect(b)});
}

test "iter" {
    var a = [_]u8{ 1, 2, 3, 4 };
    var b = [_]u8{ 5, 6, 7, 8 };

    var iter = memIter(u8, &.{ &a, &b });

    while (iter.next()) |n| {
        std.debug.print("{}, ", .{n});
    }
    std.debug.print("\n", .{});
}
