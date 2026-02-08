const std = @import("std");
const mem = std.mem;

const Config = @This();

values: std.StringHashMapUnmanaged(Value),

pub const Entry = struct {
    args: [][]u8,

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

    pub fn deinit(self: @This(), allocator: mem.Allocator) void {
        for (self.args) |a| allocator.free(a);
        allocator.free(self.args);
    }
};

pub const Value = union(enum) {
    config: *Config,
    args: Entry,
    list: []Entry,

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

fn parseEntry(allocator: mem.Allocator, reader: *std.Io.Reader) !Entry {
    const b = try reader.takeDelimiterExclusive('\n');
    var iter = mem.splitScalar(u8, b, ',');
    var entries: std.ArrayList([]u8) = .empty;
    errdefer {
        for (entries.items) |e| allocator.free(e);
        entries.deinit(allocator);
    }

    while (iter.next()) |s| {
        const trimmed = mem.trim(u8, s, " \t");
        try entries.append(allocator, try allocator.dupe(u8, trimmed));
    }

    _ = try consume(reader, '\n');

    return .{ .args = try entries.toOwnedSlice(allocator) };
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
                errdefer c.deinit(allocator);
                c.* = try parse(allocator, reader);
                if (!try consume(reader, '}')) return error.ParseError;
                val = .{ .config = c };
            },
            else => {
                val = .{ .args = try parseEntry(allocator, reader) };
            },
        }
        errdefer val.deinit(allocator);

        // TODO: decide if I want to do differently
        if (out.values.contains(key)) return error.ParseError;
        try out.values.put(allocator, key, val);
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
                for (e.args) |a| try writer.print("{s}, ", .{a});
                try writer.print("\n", .{});
            },
            .config => |subconf| {
                try writer.print("{{\n", .{});
                try serialize(subconf.*, writer);
                try writer.print("}}\n", .{});
            },
            .list => |ls| {
                try writer.print("[\n", .{});
                for (ls) |entry| {
                    for (entry.args) |a| try writer.print("{s}, ", .{a});
                    try writer.print("\n", .{});
                }
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

pub fn getTup(self: Config, key: []const u8, comptime n: usize) !?[n][]u8 {
    const val = self.values.get(key) orelse return null;

    if (std.meta.activeTag(val) != .args) return error.NotArg;

    const entry = val.args;

    if (entry.args.len != n) return error.wrongLength;

    var out: [n][]u8 = undefined;

    for (entry.args, &out) |a, *o| o.* = a;

    return out;
}

pub fn getSole(self: Config, key: []const u8) !?[]u8 {
    const val = self.values.get(key) orelse return null;

    if (std.meta.activeTag(val) != .args) return error.NotArg;
    const entry = val.args;

    if (entry.args.len != 1) return error.TooMany;

    return entry.args[0];
}
