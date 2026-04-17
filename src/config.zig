const std = @import("std");
const mem = std.mem;
const meta = std.meta;
const fmt = std.fmt;

const Config = @This();

values: std.StringHashMapUnmanaged(Value),

pub const Error = error{
    ParseError,
    TooFewArgs,
};

pub const Entry = struct {
    args: []const u8,

    pub fn splits(self: Entry, index: usize, comptime n: usize) std.meta.Tuple(.{Entry} ** n) {
        var out: [n]Entry = undefined;
        var iter = mem.tokenizeScalar(u8, self.args[index], " ");
        var i = 0;

        while (iter.next()) |e| : (i += 1) {
            out[i] = .{ .content = e };
        }

        std.debug.assert(i == n);

        return out;
    }

    pub fn argList(self: Entry, comptime n: usize) ![n][]const u8 {
        var iter = self.iterate();
        var out: [n][]const u8 = undefined;

        var i: usize = 0;

        while (iter.next()) |s| {
            if (i >= n) return error.ParseError;
            out[i] = s;
            i += 1;
        }
        if (i < n) return error.ParseError;

        return out;
    }

    pub fn argAlloc(self: Entry, gpa: mem.Allocator) ![][]const u8 {
        var iter = self.iterate();
        var out: std.ArrayList([]const u8) = .empty;
        errdefer {
            for (out.items) |e| gpa.free(e);
            out.deinit(gpa);
        }

        while (iter.next()) |s| {
            try out.append(gpa, s);
        }

        return out.toOwnedSlice(gpa);
    }

    pub const Iterator = struct {
        iter: mem.SplitIterator(u8, .scalar),

        pub fn next(self: *@This()) ?[]const u8 {
            const nextval = self.iter.next() orelse return null;
            return mem.trim(u8, nextval, &std.ascii.whitespace);
        }

        pub fn nextAssume(self: *@This()) ![]const u8 {
            return self.next() orelse error.TooFewArgs;
        }
    };

    pub fn iterate(self: Entry) Iterator {
        return .{
            .iter = mem.splitScalar(u8, self.args, ','),
        };
    }

    pub fn parseT(self: Entry, T: type) Error!T {
        if (meta.hasFn(T, "parse")) return T.parse(self);

        switch (@typeInfo(T)) {
            .array => |a| {
                const l = try self.argList(a.len);
                var out: T = undefined;
                for (l, &out) |str, *entry| entry.* = try parseSingle(str, a.child);
                return out;
            },
            .vector => |v| {
                const l = try self.argList(v.len);
                var out: T = undefined;
                for (l, 0..) |str, i| out[i] = try parseSingle(str, v.child);
                return out;
            },
            else => {
                return parseSingle(self.args, T);
            },
        }
    }

    fn parseSingle(str: []const u8, T: type) Error!T {
        switch (@typeInfo(T)) {
            .int => {
                return fmt.parseInt(T, str, 0) catch error.ParseError;
            },
            .float => {
                return fmt.parseFloat(T, str) catch error.ParseError;
            },
            .@"enum" => {
                return meta.stringToEnum(T, str) orelse error.ParseError;
            },
            .bool => {
                const trimmed = mem.trim(u8, str, &std.ascii.whitespace);
                if (mem.eql(u8, trimmed, "true")) return true;
                if (mem.eql(u8, trimmed, "false")) return false;
                return error.ParseError;
            },
            else => @compileError(fmt.comptimePrint("cannot parse type {} from string", .{T})),
        }
    }

    pub fn deinit(self: @This(), allocator: mem.Allocator) void {
        allocator.free(self.args);
    }
};

pub const Value = union(enum) {
    config: *Config,
    args: Entry,
    list: []Entry,

    pub fn parseT(self: Value, T: type) Error!T {
        return switch (self) {
            .config => |c| c.parseT(T),
            .args => |e| e.parseT(T),
            .list => |l| parseListT(l, T),
        };
    }

    fn parseListT(list: []Entry, T: type) Error!T {
        _ = list;
        unreachable;
    }

    pub fn merge(self: *Value, other: Value, gpa: mem.Allocator) !void {
        if (meta.activeTag(self.*) != meta.activeTag(other)) return error.ParseError;
        switch (self.*) {
            .config => |c| {
                var iter = other.config.values.iterator();
                while (iter.next()) |n| {
                    const key = n.key_ptr.*;
                    const val = n.value_ptr.*;
                    if (c.values.getPtr(key)) |old| {
                        try old.merge(val, gpa);
                    } else {
                        try c.values.put(gpa, key, val);
                    }
                }
            },
            .list => |l| {
                const new = Value{ .list = try mem.concat(gpa, Entry, &.{ l, other.list }) };
                errdefer new.deinit();
                self.deinit(gpa);
                self.* = new;
            },

            .args => return error.ParseError,
        }
    }

    pub fn deinit(self: Value, allocator: std.mem.Allocator) void {
        switch (self) {
            .args => |e| {
                e.deinit(allocator);
            },
            .config => |c| {
                c.deinit(allocator);
                allocator.destroy(c);
            },
            .list => |l| {
                for (l) |e| e.deinit(allocator);
                allocator.free(l);
            },
        }
    }
};

pub fn deinit(self: *Config, allocator: mem.Allocator) void {
    var iter = self.values.iterator();
    while (iter.next()) |pair| {
        const key = pair.key_ptr.*;
        const val = pair.value_ptr;
        allocator.free(key);
        val.deinit(allocator);
    }

    self.values.deinit(allocator);
}

fn discardWS(reader: *std.Io.Reader) !void {
    wait: switch (try reader.peekByte()) {
        ' ', '\t' => {
            reader.toss(1);
            continue :wait try reader.peekByte();
        },
        else => return,
    }
}

fn discardWSNL(reader: *std.Io.Reader) !void {
    wait: switch (try reader.peekByte()) {
        ' ', '\t', '\n' => {
            reader.toss(1);
            continue :wait try reader.peekByte();
        },
        else => return,
    }
}

fn consume(reader: *std.Io.Reader, char: u8) !bool {
    if (try reader.peekByte() != char) return false;

    reader.toss(1);

    return true;
}

pub fn parseEntry(allocator: mem.Allocator, reader: *std.Io.Reader) !Entry {
    const b = try reader.takeDelimiter('\n') orelse &.{};
    const uncommented = mem.sliceTo(b, '#');
    const trimmed = mem.trim(u8, uncommented, &std.ascii.whitespace);
    return .{ .args = try allocator.dupe(u8, trimmed) };
}

fn parseList(allocator: mem.Allocator, reader: *std.Io.Reader) ![]Entry {
    var out: std.ArrayList(Entry) = .empty;
    errdefer {
        for (out.items) |o| o.deinit(allocator);
        out.deinit(allocator);
    }
    while (true) {
        discardWSNL(reader) catch |e| switch (e) {
            error.EndOfStream => break,
            else => return e,
        };

        switch (try reader.peekByte()) {
            ']' => break,
            '#' => {
                _ = try reader.discardDelimiterInclusive('\n');
                continue;
            },
            else => {},
        }

        try out.append(allocator, try parseEntry(allocator, reader));
    }

    return out.toOwnedSlice(allocator);
}

pub fn parse(allocator: mem.Allocator, reader: *std.io.Reader) !Config {
    var out: Config = .{ .values = .empty };
    errdefer out.deinit(allocator);

    while (true) {
        discardWSNL(reader) catch |e| switch (e) {
            error.EndOfStream => return out,
            else => return e,
        };

        switch (try reader.peekByte()) {
            '}' => return out,
            '#' => {
                _ = try reader.discardDelimiterInclusive('\n');
                continue;
            },
            else => {},
        }

        const _key = try reader.takeDelimiterExclusive(' ');
        const key = try allocator.dupe(u8, _key);

        try discardWS(reader);

        var val: Value = undefined;
        switch (try reader.peekByte()) {
            '[' => {
                _ = try consume(reader, '[');
                const es = try parseList(allocator, reader);
                errdefer {
                    for (es) |e| e.deinit(allocator);
                    allocator.free(es);
                }
                if (!try consume(reader, ']')) return error.ParseError;
                val = .{ .list = es };
            },
            '{' => {
                _ = try consume(reader, '{');
                const c = try allocator.create(Config);
                errdefer allocator.destroy(c);
                c.* = try parse(allocator, reader);
                errdefer c.deinit(allocator);
                if (!try consume(reader, '}')) return error.ParseError;
                val = .{ .config = c };
            },
            else => {
                val = .{ .args = try parseEntry(allocator, reader) };
            },
        }
        errdefer val.deinit(allocator);

        if (out.values.getPtr(key)) |v| {
            try v.merge(val, allocator);
            val.deinit(allocator);
        } else {
            try out.values.put(allocator, key, val);
        }
    }
}

pub fn serialize(conf: Config, writer: *std.Io.Writer) !void {
    var iter = conf.values.iterator();

    while (iter.next()) |_kv| {
        const key = _kv.key_ptr.*;
        const val = _kv.value_ptr.*;

        try writer.print("{s} ", .{key});

        switch (val) {
            .args => |e| {
                try writer.print("{s}\n", .{e.args});
            },
            .config => |subconf| {
                try writer.print("{{\n", .{});
                try serialize(subconf.*, writer);
                try writer.print("}}\n", .{});
            },
            .list => |ls| {
                try writer.print("[\n", .{});
                for (ls) |entry| try writer.print("{s}\n", .{entry.args});
                try writer.print("]\n", .{});
            },
        }
    }
}

pub fn sub(self: Config, key: []const u8) !Config {
    const val = self.values.get(key) orelse return .{ .values = .empty };

    if (std.meta.activeTag(val) != .config) return error.NotSub;

    return val.config.*;
}

pub fn get(self: Config, key: []const u8) ?Value {
    return self.values.get(key);
}

pub fn getArgs(self: Config, key: []const u8) !?Entry {
    const val = self.values.get(key) orelse return null;

    if (std.meta.activeTag(val) != .args) return error.NotArg;

    return val.args;
}

pub fn getList(self: Config, key: []const u8) ![]Entry {
    const val = self.values.get(key) orelse return &.{};

    if (std.meta.activeTag(val) != .list) return error.NotList;

    return val.list;
}

pub fn getTup(self: Config, key: []const u8, comptime n: usize) !?[n][]const u8 {
    const val = self.values.get(key) orelse return null;

    if (std.meta.activeTag(val) != .args) return error.NotArg;

    const entry = val.args;

    return entry.argList(n);
}

pub fn getSole(self: Config, key: []const u8) !?[]const u8 {
    const val = self.values.get(key) orelse return null;

    if (std.meta.activeTag(val) != .args) return error.NotArg;
    const entry = val.args;

    return (try entry.argList(1))[0];
}

pub fn parseT(self: Config, T: type) Error!T {
    if (meta.hasFn(T, "parse")) return T.parse(self);

    const str = switch (@typeInfo(T)) {
        .@"struct" => |pl| pl,
        else => return error.ParseError,
        // else => @compileError(fmt.comptimePrint("cannot parse top-level config into non-struct type {}", .{T})),
    };

    if (str.is_tuple) @compileError("cannot parse config block into tuple");

    var out: T = undefined;

    inline for (str.fields) |field| {
        const val = self.get(field.name);
        switch (@typeInfo(field.type)) {
            .optional => |o| {
                @field(out, field.name) = if (val) |v| try v.parseT(o.child) else null;
            },
            else => {
                @field(out, field.name) = if (val) |v|
                    try v.parseT(field.type)
                else if (field.default_value_ptr) |v|
                    @as(*const field.type, @ptrCast(@alignCast(v))).*
                else
                    return error.NoDefaultValue;
            },
        }
    }

    return out;
}
