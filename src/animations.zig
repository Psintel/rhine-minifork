const std = @import("std");
const wayland = @import("wayland");
const mem = std.mem;
const math = std.math;
const meta = std.meta;
const fmt = std.fmt;

const wl = wayland.client.wl;
const rwm = wayland.client.river;

const utils = @import("utils.zig");
const Window = @import("window.zig");
const Output = @import("output.zig");
const Seat = @import("seat.zig");
const Workspace = @import("workspace.zig");
const Rules = @import("rules.zig");
const Config = @import("config.zig");
const commands = @import("commands.zig");
const Context = @import("context.zig");

const keybinds = @import("keybinds.zig");
const pointerbinds = @import("pointer_binds.zig");

const tween = @import("tween");
const interp = tween.interp;
const ease = tween.ease;

const log = std.log.scoped(.animations);

const Io = std.Io;
const Clock = Io.Clock;

pub const clock: Clock = .awake;

const Vec2 = utils.Vec2;
const Vec2f = utils.Vec2f;

pub const AnimationType = enum {
    move,
    resize,
    workspace,
};

pub const Animation = struct {
    easing: Easing,
    duration: Io.Duration,
};

const Animations = @This();

animations: std.EnumArray(AnimationType, Animation) = .initFill(.{
    .duration = .fromMicroseconds(300_000),
    .easing = .{ .fun = .{ .elasticOut = .{
        .amplitude = 0.5,
    } } },
}),

pub const Easing = struct {
    const Inner = ez: {
        const Type = std.builtin.Type;

        const data = struct {
            name: []const u8,
            params: []const Type.Fn.Param,
        };
        var want: []const data = &.{};
        for (meta.declarations(ease)) |dec| {
            const ft = switch (@typeInfo(@TypeOf(@field(ease, dec.name)))) {
                .@"fn" => |f| f,
                else => continue,
            };
            const params = ft.params;
            if (params.len < 1 or params.len > 2 or !params[0].is_generic) continue;
            if (params.len == 2 and params[1].is_generic) continue;
            want = want ++ .{data{ .name = dec.name, .params = params }};
        }

        const TagI = meta.Int(.unsigned, math.log2_int_ceil(usize, want.len));

        var efields: [want.len][]const u8 = undefined;
        var evals: [want.len]TagI = undefined;
        var utypes: [want.len]type = undefined;
        var uattrs: [want.len]Type.UnionField.Attributes = undefined;

        for (want, 0..) |dec, i| {
            efields[i] = dec.name;
            evals[i] = i;
            utypes[i] = if (dec.params.len == 2) dec.params[1].type orelse void else void;
            uattrs[i] = .{ .@"align" = @alignOf(utypes[i]) };
        }

        const E = @Enum(TagI, .exhaustive, &efields, &evals);
        break :ez @Union(.auto, E, &efields, &utypes, &uattrs);
    };
    fun: Inner,

    pub fn apply(self: @This(), prog: f32) f32 {
        switch (self.fun) {
            inline else => |p, t| {
                const n = @tagName(t);
                return if (@TypeOf(p) == void)
                    @field(ease, n)(prog)
                else
                    @field(ease, n)(prog, p);
            },
        }
    }

    pub fn parse(entry: Config.Entry) !@This() {
        var iter = entry.iterate();
        const T = meta.Tag(Inner);
        const tag = meta.stringToEnum(T, iter.next() orelse return error.NoType) orelse return error.ParsingError;
        switch (tag) {
            inline else => |t| {
                const FT = @FieldType(Inner, @tagName(t));
                if (FT == void)
                    return .{ .fun = @unionInit(Inner, @tagName(t), {}) };

                // TODO: throw error if we're left with uninitialized fields
                var mod: FT = undefined;

                inline for (comptime meta.fields(FT)) |f| {
                    if (f.default_value_ptr) |dv|
                        @field(mod, f.name) = @as(*const f.type, @ptrCast(@alignCast(dv))).*;
                }

                while (iter.next()) |arg| {
                    var tokens = mem.tokenizeScalar(u8, arg, '=');
                    const name = tokens.next() orelse return error.ParsingError;
                    const opt_arg = tokens.next() orelse return error.NoArg;
                    inline for (comptime meta.fieldNames(FT)) |f| {
                        if (mem.eql(u8, f, name)) {
                            const FFT = @FieldType(FT, f);

                            @field(mod, f) = switch (@typeInfo(FFT)) {
                                .int => try fmt.parseInt(FFT, opt_arg, 0),
                                .float => try fmt.parseFloat(FFT, opt_arg),
                                inline else => @compileError("unsupported type"),
                            };
                        }
                    }
                }

                return .{ .fun = @unionInit(Inner, @tagName(t), mod) };
            },
        }
    }
};

pub fn Lerp(kind: AnimationType) type {
    return union(enum) {
        static: Vec2,
        transit: struct {
            from: Vec2,
            to: Vec2,
            start: Io.Timestamp,

            pub fn timeGet(self: @This(), anims: Animations, t: Io.Timestamp) Vec2 {
                const info = anims.animations.get(kind);
                const endTime = self.start.addDuration(info.duration).withClock(clock);
                if (info.duration.toMicroseconds() == 0 or endTime.compare(.lte, t.withClock(clock))) return self.to;
                const d: f32 = @floatFromInt(self.start.durationTo(t).toMicroseconds());
                const p: f32 = @floatFromInt(info.duration.toMicroseconds());
                return ilerp(self.from, self.to, interp.clamp01(d / p), info.easing);
            }
        },

        pub fn max(self: @This()) Vec2 {
            return switch (self) {
                .static => |v| v,
                .transit => |t| @max(t.from, t.to),
            };
        }

        pub fn current(self: @This(), anims: Animations, io: Io) Vec2 {
            return self.get(anims, clock.now(io));
        }

        pub fn get(self: @This(), anims: Animations, time: Io.Timestamp) Vec2 {
            return switch (self) {
                .static => |v| v,
                .transit => |trans| trans.timeGet(anims, time),
            };
        }

        pub fn done(self: @This(), anims: Animations, ts: Io.Timestamp) bool {
            const info = anims.animations.get(kind);
            return switch (self) {
                .static => true,
                .transit => |t| t.start.addDuration(info.duration).withClock(clock).compare(.lte, ts.withClock(clock)),
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

fn ilerp(fst: Vec2, snd: Vec2, prog: f32, e: Easing) Vec2 {
    return @intFromFloat(flerp(@floatFromInt(fst), @floatFromInt(snd), prog, e));
}

fn flerp(fst: Vec2f, snd: Vec2f, prog: f32, e: Easing) Vec2f {
    return interp.lerp(fst, snd, e.apply(prog));
}

pub fn load(cfg: *const Config) !@This() {
    const anims = try cfg.sub("animations");
    var out: @This() = .{};

    for (std.enums.values(AnimationType)) |atype| {
        const afield = out.animations.getPtr(atype);
        const data = try anims.sub(@tagName(atype));
        if (try data.getSole("duration")) |dur| afield.duration = .fromMicroseconds(try fmt.parseInt(u63, dur, 0));
        if (try data.getArgs("easing")) |ez| afield.easing = try .parse(ez);
    }

    return out;
}
