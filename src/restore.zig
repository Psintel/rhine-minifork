const std = @import("std");
const mem = std.mem;
const wayland = @import("wayland");

const rwm = wayland.client.river;

const Workspace = @import("workspace.zig");
const Context = @import("context.zig");

pub const buf_size = @sizeOf(Win.Id) + @sizeOf(Win.Data) + @sizeOf(Out.Data);

pub const Win = struct {
    pub const name = @typeName(Win);
    pub const Id = [32]u8;
    pub const Data = extern struct {
        workspace: Workspace.WS,
        float: bool,
    };
};

pub const Out = struct {
    pub const name = @typeName(Out);
    pub const Data = packed struct {
        workspace: Workspace.WS,
    };
};

pub const empty: @This() = .{ .outs = .empty, .relations = .empty };

outs: std.array_hash_map.String(Out.Data),
relations: std.array_hash_map.Auto(Win.Id, Win.Data),

pub fn deserialize(reader: *std.Io.Reader, gpa: std.mem.Allocator) !@This() {
    var out: @This() = .empty;
    errdefer out.deinit(gpa);

    const outsec = try reader.takeArray(Out.name.len);
    if (!mem.eql(u8, outsec, Out.name)) return error.Invalid;
    const out_len = try reader.takeInt(u64, .native);
    for (0..@intCast(out_len)) |_| {
        const len = try reader.takeInt(u32, .native);
        const name = try reader.readAlloc(gpa, len);
        errdefer gpa.free(name);
        const data = try reader.takeStruct(Out.Data, .native);
        if (out.outs.contains(name)) return error.Invalid;
        try out.outs.put(gpa, name, data);
    }

    const winsec = try reader.takeArray(Win.name.len);
    if (!mem.eql(u8, winsec, Win.name)) return error.Invalid;

    const win_len = try reader.takeInt(u64, .native);
    for (0..@intCast(win_len)) |_| {
        const arr = try reader.takeArray(32);
        var id: Win.Id = @splat(0);
        @memcpy(&id, arr);

        const data = try reader.takeStruct(Win.Data, .native);
        try out.relations.put(gpa, id, data);
    }

    return out;
}

pub fn serialize(self: @This(), writer: *std.Io.Writer) !void {
    try writer.writeAll(Out.name);
    try writer.writeInt(u64, @intCast(self.outs.entries.len), .native);

    var out_iter = self.outs.iterator();
    while (out_iter.next()) |kv| {
        const name = kv.key_ptr.*;
        const data = kv.value_ptr.*;

        try writer.writeInt(u32, @intCast(name.len), .native);

        try writer.writeAll(name);
        try writer.writeStruct(data, .native);
    }

    try writer.writeAll(Win.name);
    try writer.writeInt(u64, @intCast(self.relations.entries.len), .native);

    var rel_iter = self.relations.iterator();
    while (rel_iter.next()) |kv| {
        const id = kv.key_ptr.*;
        const data = kv.value_ptr.*;

        try writer.writeAll(&id);
        try writer.writeStruct(data, .native);
    }

    try writer.flush();
}

pub fn fromCtx(ctx: *const Context) !@This() {
    var out: @This() = .empty;
    errdefer out.deinit(ctx.gpa);

    var out_iter = ctx.outs.iterator();
    while (out_iter.next()) |kv| {
        const out_data = kv.value_ptr;
        const glob = out_data.wl_out orelse continue;
        const wl_out = ctx.wl_outs.map.get(glob) orelse continue;
        const wl_data = ctx.wl_outs.data.get(wl_out) orelse continue;
        const _name = wl_data.name orelse continue;
        const name = try ctx.gpa.dupe(u8, _name);
        errdefer ctx.gpa.free(name);

        try out.outs.put(ctx.gpa, name, .{ .workspace = out_data.workspace });
    }

    var win_iter = ctx.wins.iterator();

    while (win_iter.next()) |kv| {
        const win = kv.key_ptr.*;
        const win_data = kv.value_ptr.*;

        const ws = Workspace.byWindow(ctx, win) orelse continue;

        const data: Win.Data = .{
            .workspace = ws,
            .float = win_data.float,
        };

        try out.relations.put(ctx.gpa, win_data.identifier, data);
    }

    return out;
}

pub fn deinit(self: *@This(), alloc: std.mem.Allocator) void {
    self.relations.deinit(alloc);
    for (self.outs.keys()) |k| alloc.free(k); // free hashmap keys
    self.outs.deinit(alloc);
}
