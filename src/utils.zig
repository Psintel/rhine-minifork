const std = @import("std");
const math = std.math;
const meta = std.meta;

pub const Vec2 = @Vector(2, i32);
pub const Vec2f = @Vector(2, f32);

pub fn Lerp(comptime period: i64) type {
    return union(enum) {
        pub const time_period = period;

        static: Vec2,
        transit: struct {
            from: Vec2,
            to: Vec2,
            start: i64,

            pub fn timeGet(self: @This(), t: i64) Vec2 {
                const d: f32 = @floatFromInt(t - self.start);
                const p: f32 = @floatFromInt(period);
                return ilerp(self.from, self.to, @min(d / p, 1.0));
            }
        },

        pub fn get(self: @This(), progtime: i64) Vec2 {
            return switch (self) {
                .static => |v| v,
                .transit => |trans| trans.timeGet(progtime),
            };
        }

        pub fn done(self: @This(), progtime: i64) bool {
            return switch (self) {
                .static => true,
                .transit => |t| progtime - t.start >= period,
            };
        }

        pub fn end(self: @This()) Vec2 {
            return switch (self) {
                .static => |s| s,
                .transit => |t| t.to,
            };
        }

        pub fn staticify(self: *@This()) void {
            switch (self.*) {
                .static => {},
                .transit => |t| self.* = .{ .static = t.to },
            }
        }
    };
}

pub fn int2Float(v: Vec2) Vec2f {
    return @floatFromInt(v);
}

pub fn float2Int(v: Vec2f) Vec2 {
    return @intFromFloat(v);
}

pub fn ilerp(fst: Vec2, snd: Vec2, prog: f32) Vec2 {
    return float2Int(flerp(int2Float(fst), int2Float(snd), prog));
}

pub fn flerp(fst: Vec2f, snd: Vec2f, _prog: f32) Vec2f {
    const prog: Vec2f = @splat(_prog);
    return math.lerp(fst, snd, prog);
}


pub const Rect2 = struct {
    pos: Vec2,
    dim: Vec2,

    pub const unit: @This() = .{
        .pos = @splat(0),
        .dim = @splat(1 << 16),
    };

    pub fn inside(self: @This(), pos: Vec2) bool {
        const near = self.pos;
        const far = self.pos + self.dim;

        return near[0] <= pos[0] and pos[0] < far[0] and
            near[1] <= pos[1] and pos[1] < far[1];
    }
};

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

    pub const gray: @This() = .{
        .r = 0x2000_0000,
        .g = 0x2000_0000,
        .b = 0x2000_0000,
        .a = 0xFFFF_FFFF,
    };
};

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
