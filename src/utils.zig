const std = @import("std");
const math = std.math;
const meta = std.meta;

pub const Vec2 = TVec2(i32);
pub const Vec2f = TVec2(f32);

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

        pub fn staticify(self: *@This()) void {
            switch (self.*) {
                .static => {},
                .transit => |t| self.* = .{ .static = t.to },
            }
        }
    };
}

pub fn int2Float(v: Vec2) Vec2f {
    return .{
        .x = @floatFromInt(v.x),
        .y = @floatFromInt(v.y),
    };
}

pub fn float2Int(v: Vec2f) Vec2 {
    return .{
        .x = @intFromFloat(v.x),
        .y = @intFromFloat(v.y),
    };
}

pub fn ilerp(fst: Vec2, snd: Vec2, prog: f32) Vec2 {
    return float2Int(flerp(int2Float(fst), int2Float(snd), prog));
}

pub fn flerp(fst: Vec2f, snd: Vec2f, prog: f32) Vec2f {
    return .{
        .x = math.lerp(fst.x, snd.x, prog),
        .y = math.lerp(fst.y, snd.y, prog),
    };
}

pub fn TVec2(T: type) type {
    return struct {
        x: T,
        y: T,

        pub fn add(self: @This(), other: @This()) @This() {
            return .{
                .x = self.x + other.x,
                .y = self.y + other.y,
            };
        }

        pub fn sub(self: @This(), other: @This()) @This() {
            return .{
                .x = self.x - other.x,
                .y = self.y - other.y,
            };
        }

        pub fn elmul(self: @This(), other: @This()) @This() {
            return .{
                .x = self.x * other.x,
                .y = self.y * other.y,
            };
        }

        pub fn eldivT(self: @This(), other: @This()) @This() {
            return .{
                .x = @divTrunc(self.x, other.x),
                .y = @divTrunc(self.y, other.y),
            };
        }

        pub fn fromScalar(s: T) @This() {
            return .{
                .x = s,
                .y = s,
            };
        }

        pub fn scale(self: @This(), scaler: T) @This() {
            return .{
                .x = self.x * scaler,
                .y = self.y * scaler,
            };
        }
    };
}

pub const Rect2 = struct {
    pos: Vec2,
    dim: Vec2,

    pub const unit: @This() = .{
        .pos = .{ .x = 0, .y = 0 },
        .dim = .{ .x = 1 << 16, .y = 1 << 16 },
    };
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

pub fn WLHashMap(IFace: type, container: type) type {
    const T = *IFace;
    return std.ArrayHashMapUnmanaged(T, container, struct {
        pub fn hash(_: @This(), win: T) u32 {
            return win.getId();
        }
        pub fn eql(_: @This(), w1: T, w2: T, _: usize) bool {
            return w1 == w2;
        }
    }, false);
}

pub fn maybe(I: type, O: type, v: ?I, f: fn (I) ?O) ?O {
    if (v) |rv|
        return f(rv)
    else
        return null;
}
