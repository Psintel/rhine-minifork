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

        pub fn inside(self: @This(), pos: Vec2T(T)) bool {
            const near = self.pos;
            const far = self.pos + self.dim;

            return near[0] <= pos[0] and pos[0] < far[0] and
                near[1] <= pos[1] and pos[1] < far[1];
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
