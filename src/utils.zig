const std = @import("std");
const math = std.math;
const meta = std.meta;
const mem = std.mem;
const fmt = std.fmt;
const Animations = @import("animations.zig");

pub const Vec2 = @Vector(2, i32);
pub const Vec2f = @Vector(2, f32);


pub fn int2Float(v: Vec2) Vec2f {
    return @floatFromInt(v);
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

    pub fn scale(self: @This(), fac: f32) @This() {
        var dim: Vec2f = @floatFromInt(self.dim);
        dim *= @splat(fac);
        var pd = int2Float(self.dim) - dim;
        pd /= @splat(2);
        return .{
            .pos = @intFromFloat(int2Float(self.pos) + pd),
            .dim = @intFromFloat(dim),
        };
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
